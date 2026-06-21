//
//  StdioLSPTransport.swift
//  Calyx
//
//  Production `LSPTransport` that spawns a language server as a child
//  process and shuttles bytes over its stdio pipes.
//
//  Lifecycle:
//    1. `init(...)` only stores the launch description. No process yet.
//    2. The first `send` (or a future `connect()`-style call) spawns the
//       process, wires the stdout `readabilityHandler` to yield bytes
//       into `incoming`, and arms a `terminationHandler` that finishes
//       the stream and flips state to closed.
//    3. `close()` is idempotent: it terminates the process (if running)
//       and closes the pipes.
//
//  Concurrency notes:
//    - `Process` / `Pipe` / `FileHandle` are not `Sendable`. They are
//      kept inside the actor's isolated state and the only callbacks
//      they fire (`readabilityHandler`, `terminationHandler`) capture an
//      `AsyncStream.Continuation` (already `Sendable`) and a small
//      reference type guarded with `@unchecked Sendable` purely so the
//      compiler will let us close over it from a Foundation thread.
//

import Foundation

/// Spawns a language server binary and adapts its stdio to
/// `LSPTransport`.
actor StdioLSPTransport: LSPTransport {

    // MARK: - Launch Description

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let workingDirectory: URL?

    // MARK: - Runtime

    /// Holder for `Process` + `Pipe` so the actor state stays cleanly
    /// typed. Created lazily on first `send`.
    private final class ProcessHandle: @unchecked Sendable {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe) {
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }
    }

    private var handle: ProcessHandle?
    private var isClosed = false

    /// Inbound bytes stream + its continuation.
    nonisolated let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    // MARK: - Init

    init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory

        var capturedContinuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream<Data> { continuation in
            capturedContinuation = continuation
        }
        self.continuation = capturedContinuation
    }

    // MARK: - LSPTransport

    func send(_ data: Data) async throws {
        if isClosed {
            throw LSPClientError.transportClosed
        }
        let h = try ensureSpawned()
        try writeSync(data, to: h.stdinPipe.fileHandleForWriting)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true

        if let h = handle {
            // Detach handlers so Foundation does not keep calling into a
            // half-torn-down state.
            h.stdoutPipe.fileHandleForReading.readabilityHandler = nil
            h.stderrPipe.fileHandleForReading.readabilityHandler = nil
            h.process.terminationHandler = nil

            if h.process.isRunning {
                h.process.terminate()
            }
            try? h.stdinPipe.fileHandleForWriting.close()
            try? h.stdoutPipe.fileHandleForReading.close()
            try? h.stderrPipe.fileHandleForReading.close()
        }
        handle = nil
        continuation.finish()
    }

    // MARK: - Private

    /// Spawn the process on first use. Subsequent calls return the cached handle.
    private func ensureSpawned() throws -> ProcessHandle {
        if let h = handle { return h }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let h = ProcessHandle(
            process: process,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )

        // Wire stdout -> incoming.
        let cont = self.continuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { return }
            cont.yield(chunk)
        }
        // stderr is discarded (production hook point: forward to a logger).
        stderrPipe.fileHandleForReading.readabilityHandler = { _ in }

        // Terminate -> finish incoming stream.
        process.terminationHandler = { _ in
            cont.finish()
        }

        try process.run()
        self.handle = h
        return h
    }

    /// Synchronous write wrapped in a throwing surface. `FileHandle.write(_:)`
    /// will raise an Obj-C exception if the pipe is closed; we therefore
    /// gate writes on `isClosed` and surface POSIX-style errors via
    /// `LSPClientError.transportClosed`.
    private func writeSync(_ data: Data, to fh: FileHandle) throws {
        do {
            try fh.write(contentsOf: data)
        } catch {
            throw LSPClientError.transportClosed
        }
    }
}
