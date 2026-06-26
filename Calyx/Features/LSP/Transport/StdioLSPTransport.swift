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
//    3. `close()` is idempotent: it sends SIGTERM and escalates to
//       SIGKILL ~2s later if the child ignored the polite signal.
//    4. Dropping the transport (without `close()`) is also safe: the
//       child-owning state lives inside a reference-typed
//       `ProcessHandle` whose `deinit` unconditionally kills any
//       still-running child.
//
//  Concurrency notes:
//    - `Process` / `Pipe` / `FileHandle` are not `Sendable`. They are
//      kept inside the actor's isolated state and the only callbacks
//      they fire (`readabilityHandler`, `terminationHandler`) capture an
//      `AsyncStream.Continuation` (already `Sendable`) and a small
//      reference type guarded with `@unchecked Sendable` purely so the
//      compiler will let us close over it from a Foundation thread.
//    - Writes to stdin go through a non-blocking POSIX `write(2)` loop
//      on a background queue with an internal deadline so a wedged or
//      non-draining child cannot pin the actor's executor.
//

import Foundation
import Darwin

/// Spawns a language server binary and adapts its stdio to
/// `LSPTransport`.
actor StdioLSPTransport: LSPTransport {

    // MARK: - Launch Description

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let workingDirectory: URL?

    // MARK: - Runtime

    /// Holder for `Process` + `Pipe`. Reference-typed so that the actor
    /// itself doesn't need a `deinit` (actors cannot run async teardown
    /// from `deinit`): when the actor is released, its `handle: ProcessHandle?`
    /// stored property is dropped, the `ProcessHandle` refcount falls to
    /// zero, and `ProcessHandle.deinit` runs unconditionally — which
    /// terminates any orphaned child.
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

        deinit {
            // Detach handlers so Foundation does not keep calling into a
            // half-torn-down state.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil

            // Unconditional kill. If the actor is being torn down without
            // a prior `close()`, this is the safety net that prevents
            // orphaned language-server children (rust-analyzer /
            // sourcekit-lsp can leak GB of RSS otherwise). If the
            // process has already exited, kill(2) returns ESRCH which
            // we ignore.
            if process.isRunning {
                let pid = process.processIdentifier
                if pid > 0 {
                    _ = kill(pid, SIGTERM)
                    _ = kill(pid, SIGKILL)
                }
            }

            // Reap on a background thread so the child does not linger
            // as a zombie in the process table (which would still satisfy
            // `kill(pid, 0)` liveness probes from the host). Capture
            // `process` strongly into the queue so its dispatch source
            // and any pending exit notifications stay alive long enough
            // for waitpid to complete.
            let proc = process
            DispatchQueue.global(qos: .background).async {
                proc.waitUntilExit()
            }

            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }
    }

    /// Bounded ring buffer for the child's recent stderr output. Lives
    /// outside the actor's isolation domain so the Foundation
    /// `readabilityHandler` (which is invoked on a Foundation worker
    /// thread, not on the actor) can append to it without an extra
    /// `Task { await ... }` hop. Thread-safe via `NSLock`.
    private final class StderrRing: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer.reserveCapacity(capacity)
        }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(chunk)
            if buffer.count > capacity {
                let excess = buffer.count - capacity
                buffer.removeFirst(excess)
            }
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    /// Cap of the stderr ring buffer in bytes. The contract documented
    /// by `recentStderr()` is "<= 64KB tail".
    private static let stderrCapacityBytes = 64 * 1024

    /// Deadline used by `writeNonBlocking` so a non-draining child
    /// cannot wedge the actor forever. The test contract is "return
    /// within 5s"; we conservatively give up after 3s.
    private static let writeDeadlineSeconds: TimeInterval = 3.0

    /// Compute a payload-size-aware write deadline for the
    /// `writeNonBlocking` loop. Small frames (typical JSON-RPC
    /// requests, ~hundreds of bytes to a few KiB) keep the legacy
    /// 3-second floor so a wedged child is still detected quickly.
    /// Larger payloads — notably `textDocument/didChange` carrying a
    /// full multi-megabyte content replacement — scale linearly so a
    /// warming-up language server (rust-analyzer / sourcekit-lsp) has
    /// time to drain the macOS ~64 KiB pipe buffer in many cycles
    /// without the transport throwing `transportClosed` and tearing
    /// the session down mid-edit.
    ///
    /// Policy: ~0.5 s per 32 KiB chunk, with a 3 s floor.
    ///   - 1 KiB   → 3.0 s (floor)
    ///   - 192 KiB → 3.0 s (floor)
    ///   - 1 MiB   → ~16 s
    ///   - 10 MiB  → ~160 s
    internal static func computeWriteDeadline(payloadSize: Int) -> TimeInterval {
        max(3.0, ceil(Double(payloadSize) / 32_768.0) * 0.5)
    }

    /// Delay between SIGTERM and the SIGKILL escalation inside
    /// `close()`. Matches the implementation guide.
    private static let sigkillEscalationSeconds: TimeInterval = 2.0

    private var handle: ProcessHandle?
    private var isClosed = false
    private let stderrRing = StderrRing(capacity: StdioLSPTransport.stderrCapacityBytes)

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
        // Note: `await` here yields the actor's executor while the
        // background queue does the actual `write(2)` syscalls. Other
        // actor methods (notably `close()`) can run during the
        // suspension, which is essential for the "send must not wedge
        // the actor" contract.
        try await writeNonBlocking(data, fd: h.stdinPipe.fileHandleForWriting.fileDescriptor)
    }

    /// Returns the most recent <= 64KB of bytes the child has emitted
    /// on stderr, in chronological order. Older bytes are dropped when
    /// the ring buffer is full.
    func recentStderr() async -> Data {
        return stderrRing.snapshot()
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
                // Polite shutdown first.
                h.process.terminate()

                // Belt-and-suspenders: if the child traps/ignores
                // SIGTERM, escalate to SIGKILL after a grace period.
                // The detached task holds `h` strongly for the duration
                // of the escalation window so `ProcessHandle.deinit`
                // doesn't fire concurrently and double-kill.
                let handleRef = h
                let delay = Self.sigkillEscalationSeconds
                Task.detached {
                    try? await Task.sleep(
                        nanoseconds: UInt64(delay * 1_000_000_000)
                    )
                    if handleRef.process.isRunning {
                        let pid = handleRef.process.processIdentifier
                        if pid > 0 {
                            _ = kill(pid, SIGKILL)
                        }
                    }
                    // handleRef released here -> ProcessHandle.deinit
                    // runs (idempotent cleanup; process is already dead
                    // or being reaped).
                }
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
        // `URL(fileURLWithPath:)` resolves relative paths against the
        // current working directory, so a bare binary name like
        // `"rust-analyzer"` would be interpreted as `<cwd>/rust-analyzer`
        // and fail to launch. Route bare names through `/usr/bin/env` so
        // the user's `PATH` is consulted; pass absolute paths straight
        // through.
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        // Always overlay the augmented PATH on the child's environment,
        // even when the caller passed `nil` or supplied a minimal env.
        // A Finder/Dock launch inherits the launchd-minimal PATH
        // (`/usr/bin:/bin:/usr/sbin:/sbin`) which cannot resolve
        // version-manager-installed binaries (NVM, asdf, pyenv, mise,
        // volta, rbenv, …) under the `/usr/bin/env` shim above. The
        // startup bridge already locates these via
        // `SystemCommandRunner.augmentedPATH()`; the transport must use
        // the same PATH or the spawn fails with `env: <name>: No such
        // file or directory` (exit 127). `augmentedEnvironment(base:)`
        // handles both branches: `nil` starts from the host env,
        // non-nil starts from the caller's dict — PATH is always
        // overridden. See `SystemCommandRunner.augmentedPATH()`.
        process.environment = SystemCommandRunner.augmentedEnvironment(base: environment)
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
        // Captured by value (Sendable) -- does NOT retain the actor, so
        // the actor is free to be ARC-released when no callers remain.
        let cont = self.continuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { return }
            cont.yield(chunk)
        }
        // Drain stderr into the bounded ring buffer. We deliberately do
        // NOT forward to the host's standard error: unbounded forwarding
        // can balloon log files and pin memory. Callers that need to
        // inspect the tail use `recentStderr()`.
        let ring = self.stderrRing
        stderrPipe.fileHandleForReading.readabilityHandler = { fh in
            let chunk = fh.availableData
            if chunk.isEmpty { return }
            ring.append(chunk)
        }

        // Terminate -> finish incoming stream.
        process.terminationHandler = { _ in
            cont.finish()
        }

        try process.run()

        // Make stdin writes non-blocking. The pipe's write end is a
        // separate fd from whatever the child reads on, so setting
        // O_NONBLOCK here does not affect the child's read semantics.
        // This lets `writeNonBlocking` loop with EAGAIN handling instead
        // of parking on a full pipe buffer.
        let writeFd = stdinPipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(writeFd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(writeFd, F_SETFL, flags | O_NONBLOCK)
        }

        self.handle = h
        return h
    }

    /// Writes `data` to `fd` using non-blocking `write(2)` on a
    /// background dispatch queue, suspending the caller via a
    /// continuation. Returns when the entire buffer has been accepted
    /// by the kernel, or throws `LSPClientError.transportClosed` if
    /// (a) the fd is closed/erroring or (b) the internal deadline
    /// elapses before the kernel can accept any more bytes (i.e., the
    /// child is not draining stdin).
    ///
    /// Critically, the actor's executor is FREE during the `await` —
    /// no actor method is blocked behind a slow pipe.
    private nonisolated func writeNonBlocking(_ data: Data, fd: Int32) async throws {
        let deadline = Date().addingTimeInterval(Self.computeWriteDeadline(payloadSize: data.count))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let total = data.count
                if total == 0 {
                    cont.resume()
                    return
                }
                var written = 0
                data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
                    guard let base = rawBuf.baseAddress else {
                        cont.resume()
                        return
                    }
                    while written < total {
                        if Date() >= deadline {
                            cont.resume(throwing: LSPClientError.transportClosed)
                            return
                        }
                        let remaining = total - written
                        let n = Darwin.write(fd, base.advanced(by: written), remaining)
                        if n > 0 {
                            written += n
                        } else if n < 0 {
                            let err = errno
                            if err == EAGAIN || err == EWOULDBLOCK {
                                // Kernel buffer full; sleep briefly and
                                // retry. Bounded by the wall-clock
                                // deadline above.
                                Thread.sleep(forTimeInterval: 0.01)
                                continue
                            } else if err == EINTR {
                                continue
                            } else {
                                // EBADF / EPIPE / etc.: pipe closed.
                                cont.resume(throwing: LSPClientError.transportClosed)
                                return
                            }
                        } else {
                            // n == 0: should not happen for a regular
                            // pipe, but be defensive.
                            cont.resume(throwing: LSPClientError.transportClosed)
                            return
                        }
                    }
                    cont.resume()
                }
            }
        }
    }
}
