//
//  SystemCommandRunner.swift
//  Calyx
//
//  Production-side `LSPCommandRunner` that drives `Process` to invoke
//  real binaries. Used by `CalyxMCPServer.startLSP()` to install /
//  locate language servers on the host machine. Tests inject
//  `MockCommandRunner` instead.
//

import Darwin
import Foundation

/// `LSPCommandRunner` backed by `/usr/bin/which` and `/usr/bin/env`.
/// Stateless and Sendable.
struct SystemCommandRunner: LSPCommandRunner {

    /// Conventional exit code used by `timeout(1)` to signal a hard
    /// timeout. Surfaced via `CommandResult.exitCode` when `run(...)`
    /// has to terminate a child that ran longer than the watchdog.
    static let timeoutExitCode: Int32 = 124

    /// Watchdog deadline (seconds) applied to every `run(...)` call.
    /// Past this point the runner sends SIGTERM, then SIGKILL 5s later.
    private static let runTimeoutSeconds: TimeInterval = 600

    /// Grace period (seconds) between SIGTERM and the follow-up SIGKILL.
    private static let killGraceSeconds: TimeInterval = 5

    init() {}

    // MARK: - PATH / environment augmentation

    // A macOS app launched from Finder/Dock inherits a minimal PATH
    // (typically `/usr/bin:/bin:/usr/sbin:/sbin`) from `launchd`,
    // missing Homebrew, Cargo, npm-global, Go, ghcup, opam, etc. Every
    // LSP install / probe done through this runner would therefore fail
    // on a real machine. We re-derive a sensible PATH on each spawn,
    // appending the inherited PATH at the tail so explicit user
    // overrides via `environment:` still win.

    /// Returns a `:`-joined PATH containing the well-known package-
    /// manager bin dirs (Homebrew, Cargo, npm-global, Go, ghcup, opam,
    /// dotnet, system Go) followed by the inherited `PATH`. Order is
    /// preserved; duplicates are removed.
    static func augmentedPATH() -> String {
        let home = NSHomeDirectory()
        let opamPath = "\(home)/.opam/default/bin"

        var candidates: [String] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "\(home)/go/bin",
            "\(home)/.ghcup/bin",
        ]
        // `~/.opam/default/bin` only exists on hosts where the user
        // ran `opam init`; skip it otherwise to keep the PATH lean.
        if FileManager.default.fileExists(atPath: opamPath) {
            candidates.append(opamPath)
        }
        candidates.append(contentsOf: [
            "/usr/local/share/dotnet",
            "/usr/local/go/bin",
        ])

        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            candidates.append(contentsOf: inherited.split(separator: ":").map(String.init))
        }

        let expanded = expandUserDirs(candidates)

        // De-duplicate while preserving order.
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(expanded.count)
        for path in expanded where seen.insert(path).inserted {
            unique.append(path)
        }
        return unique.joined(separator: ":")
    }

    /// Returns a copy of `base` (or the current process environment
    /// when `nil`) with the `PATH` key overridden by `augmentedPATH()`.
    static func augmentedEnvironment(base: [String: String]?) -> [String: String] {
        var env = base ?? ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH()
        return env
    }

    /// Resolves a leading `~` in each path via
    /// `NSString.expandingTildeInPath`. Paths that do not begin with a
    /// tilde pass through unchanged.
    private static func expandUserDirs(_ paths: [String]) -> [String] {
        paths.map { NSString(string: $0).expandingTildeInPath }
    }

    // MARK: - LSPCommandRunner

    func locate(_ executable: String) async -> URL? {
        // Run on a background queue so the actor / Swift Concurrency
        // executor is not parked inside the synchronous
        // `process.waitUntilExit()`. Mirrors the dispatch pattern in
        // `run(...)`. The non-throwing `withCheckedContinuation` is
        // used because the locate contract is "nil on any failure".
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
                process.arguments = [executable]

                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                // Detach stdin so `/usr/bin/which` can never inherit
                // a controlling TTY from the host app.
                process.standardInput = FileHandle.nullDevice
                // Use the augmented PATH so Finder-launched callers
                // can still resolve Homebrew / Cargo / npm binaries.
                process.environment = Self.augmentedEnvironment(base: nil)

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                // `which(1)` prints a single absolute path followed by
                // a newline (or nothing on miss). The total payload is
                // well below the ~16-64KB macOS pipe-buffer limit, so
                // a sequential `readDataToEndOfFile()` after
                // `waitUntilExit()` cannot deadlock here.
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let trimmed = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmed.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: URL(fileURLWithPath: trimmed))
            }
        }
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
                // Always overlay the augmented PATH so Finder-launched
                // callers still find Homebrew / Cargo / npm binaries.
                process.environment = Self.augmentedEnvironment(base: environment)

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                // Detach stdin: never let the child inherit a TTY
                // from the host app process.
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Watchdog: terminate runaway children at 600s, then
                // SIGKILL 5s later if they still refuse to exit. The
                // `TimeoutFlag` is a single-writer (timer handler) /
                // single-reader (post-`waitUntilExit`) boolean guarded
                // by a lock so we don't trip Swift 6 strict-concurrency
                // diagnostics. The flag is only read after the timer
                // has been cancelled (and therefore can no longer fire
                // a new write), so contention is nil in practice.
                final class TimeoutFlag: @unchecked Sendable {
                    private let lock = NSLock()
                    private var fired = false
                    func markFired() {
                        lock.lock(); defer { lock.unlock() }
                        fired = true
                    }
                    func value() -> Bool {
                        lock.lock(); defer { lock.unlock() }
                        return fired
                    }
                }
                let timedOut = TimeoutFlag()
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                timer.schedule(deadline: .now() + Self.runTimeoutSeconds)
                timer.setEventHandler {
                    timedOut.markFired()
                    process.terminate()
                    let pid = process.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGraceSeconds) {
                        if process.isRunning {
                            kill(pid, SIGKILL)
                        }
                    }
                }
                timer.resume()

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
                // Cancel the watchdog before reading its flag so the
                // event handler can no longer mutate it concurrently.
                timer.cancel()

                let didTimeOut = timedOut.value()
                let stdoutStr = String(data: outBox.data, encoding: .utf8) ?? ""
                var stderrStr = String(data: errBox.data, encoding: .utf8) ?? ""
                let exitCode: Int32
                if didTimeOut {
                    exitCode = Self.timeoutExitCode
                    stderrStr += "\ncommand timed out after \(Int(Self.runTimeoutSeconds))s"
                } else {
                    exitCode = process.terminationStatus
                }

                continuation.resume(returning: CommandResult(
                    exitCode: exitCode,
                    stdout: stdoutStr,
                    stderr: stderrStr
                ))
            }
        }
    }
}
