//
//  SystemCommandRunner.swift
//  Calyx
//
//  Production-side `LSPCommandRunner` that drives `Process` to invoke
//  real binaries. Used by `CalyxMCPServer.startLSP()` to install /
//  locate language servers on the host machine. Tests inject
//  `MockCommandRunner` instead.
//

import Foundation

/// `LSPCommandRunner` backed by `/usr/bin/which` and `/usr/bin/env`.
/// Stateless and Sendable.
struct SystemCommandRunner: LSPCommandRunner {

    init() {}

    // MARK: - LSPCommandRunner

    func locate(_ executable: String) async -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        // `which(1)` prints a single absolute path followed by a
        // newline (or nothing on miss). The total payload is well
        // below the ~16-64KB macOS pipe-buffer limit, so a sequential
        // `readDataToEndOfFile()` after `waitUntilExit()` cannot
        // deadlock here. The buffered drain pattern used in `run(...)`
        // is therefore unnecessary for this method.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        // Build / spawn `Process` and perform the blocking
        // `waitUntilExit()` from a background dispatch queue so we do
        // not park a Swift Concurrency executor thread. Mirrors the
        // pattern used by `GitService.run(args:workDir:)`.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
            DispatchQueue.global().async {
                let process = Process()

                // Absolute path → spawn directly. Bare name → defer to
                // `/usr/bin/env` so PATH lookup still resolves the binary.
                if executable.hasPrefix("/") {
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [executable] + arguments
                }

                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }
                if let environment {
                    process.environment = environment
                } else {
                    process.environment = ProcessInfo.processInfo.environment
                }

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stdout/stderr concurrently from dedicated
                // background queues so the child cannot block on a
                // full pipe buffer (~16-64KB on macOS) and deadlock us
                // inside `waitUntilExit()`. `OutputBox` is a reference
                // wrapper so the read closures can mutate captured
                // storage without tripping Swift 6 strict-concurrency
                // diagnostics on mutable captures from `@Sendable`
                // closures. Each box is written exactly once on its
                // own queue and observed only after `group.wait()`
                // synchronises, so `@unchecked Sendable` is sound.
                final class OutputBox: @unchecked Sendable {
                    var data = Data()
                }
                let outBox = OutputBox()
                let errBox = OutputBox()

                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    outBox.data = stdout.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errBox.data = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                process.waitUntilExit()
                group.wait()

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outBox.data, encoding: .utf8) ?? "",
                    stderr: String(data: errBox.data, encoding: .utf8) ?? ""
                ))
            }
        }
    }
}
