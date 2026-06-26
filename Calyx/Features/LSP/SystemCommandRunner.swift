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

    /// Watchdog deadline (seconds) applied to every `installRun(...)`
    /// call. Install commands such as `ghcup install hls` (which compiles
    /// GHC from source), `brew install` on a cold cache, or
    /// `rustup component add` on a slow network can legitimately run
    /// 30+ minutes. The 600 s `runTimeoutSeconds` watchdog would
    /// terminate them prematurely, so install paths get their own,
    /// much longer wall-clock budget (default 1 hour).
    private static let installTimeoutSeconds: TimeInterval = 3600

    /// Grace period (seconds) between SIGTERM and the follow-up SIGKILL.
    private static let killGraceSeconds: TimeInterval = 5

    init() {}

    // MARK: - PATH / environment augmentation

    // A macOS app launched from Finder/Dock inherits a minimal PATH
    // (typically `/usr/bin:/bin:/usr/sbin:/sbin`) from `launchd`,
    // missing Homebrew, Cargo, npm-global, Go, ghcup, opam, plus any
    // version-manager bin dirs the user exports from `.zshrc` /
    // `.bashrc` (NVM, asdf, pyenv, mise, volta, rbenv, …). Every LSP
    // install / probe done through this runner would therefore fail on
    // a real machine. We re-derive a sensible PATH on each spawn by
    // combining three sources, in priority order:
    //
    //   1. **Login-shell PATH** — `$SHELL -ilc 'echo $PATH'`. Sources
    //      the user's rc files, so it surfaces any directory the user
    //      added from dotfiles, including version-manager bin dirs
    //      that the hardcoded list below cannot anticipate. Cached
    //      once per process lifetime (see `loginShellPATH()`).
    //   2. **Canonical safety net** — the well-known package-manager
    //      bin dirs (Homebrew, Cargo, npm-global, Go, ghcup, opam,
    //      dotnet, system Go). Still appended in case the login shell
    //      is broken / unavailable / doesn't surface them.
    //   3. **Inherited PATH** — `ProcessInfo.processInfo.environment["PATH"]`,
    //      typically the minimal launchd default. Kept at the tail so
    //      `/usr/bin`, `/bin`, etc. remain reachable.
    //
    // Duplicates are removed while preserving the first occurrence's
    // order, so the login shell's view of PATH wins when entries
    // overlap.

    /// Process-lifetime cache for `loginShellPATH()`. Guarded by
    /// `loginShellPATHLock`. We only resolve the login shell once
    /// per process; this matches typical shell rc semantics (no
    /// shell config reload mid-session) and keeps subsequent calls
    /// O(1) — which matters because every spawned child re-builds
    /// PATH via `augmentedPATH()`. The `nonisolated(unsafe)` marker
    /// is sound because every read/write goes through the lock.
    private nonisolated(unsafe) static var loginShellPATHCache: String?
    private nonisolated(unsafe) static var loginShellPATHResolved = false
    private static let loginShellPATHLock = NSLock()

    /// Returns the user's login-shell `$PATH` by spawning
    /// `<shell> -ilc 'echo $PATH'` synchronously and capturing stdout.
    /// `$SHELL` is read from the inherited environment; falls back to
    /// `/bin/zsh` when unset or empty (macOS default since Catalina).
    ///
    /// `-ilc` (interactive + login + command) is required, not `-lc`,
    /// because of how macOS zsh startup files work:
    ///
    ///   * Login-only (`-lc`) sources `/etc/zprofile`, which calls
    ///     `path_helper(8)` and **replaces** the inherited PATH with
    ///     the sysroot default (`/usr/bin:/bin:/usr/sbin:/sbin` plus
    ///     `/etc/paths.d/*`), then sources `~/.zprofile`. It never
    ///     sources `~/.zshrc`.
    ///   * Most users wire version managers (NVM, asdf, pyenv, mise,
    ///     volta, rbenv, …) from `~/.zshrc`, not `~/.zprofile`. With
    ///     `-lc` those bin dirs are silently dropped from the resolved
    ///     PATH and `locate(...)` cannot find tools installed via them.
    ///
    /// Adding `-i` makes zsh interactive, which causes `~/.zshrc` to be
    /// sourced after the login files, restoring the user's full PATH.
    /// bash treats `-i` the same way (sources `~/.bashrc`). When no tty
    /// is attached zsh may emit a `no job control in this shell` notice
    /// to stderr — that is harmless and the stderr pipe below is never
    /// read, so the warning is silently dropped.
    ///
    /// Returns `nil` on spawn failure or non-zero exit. The result is
    /// cached for the rest of the process lifetime.
    static func loginShellPATH() -> String? {
        loginShellPATHLock.lock()
        defer { loginShellPATHLock.unlock() }
        if loginShellPATHResolved {
            return loginShellPATHCache
        }

        let shellEnv = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let shell = shellEnv.isEmpty ? "/bin/zsh" : shellEnv

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "echo $PATH"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        // Detach stdin so the login shell never blocks waiting for
        // input it cannot receive from a GUI-launched parent.
        process.standardInput = FileHandle.nullDevice

        let resolved: String?
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                let trimmed = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                resolved = trimmed.isEmpty ? nil : trimmed
            } else {
                resolved = nil
            }
        } catch {
            resolved = nil
        }

        loginShellPATHCache = resolved
        loginShellPATHResolved = true
        return resolved
    }

    /// Returns a `:`-joined PATH combining (in priority order) the
    /// login-shell PATH, a canonical package-manager safety net, and
    /// the inherited launchd PATH. See the file-level comment above
    /// for the rationale and ordering contract.
    static func augmentedPATH() -> String {
        let home = NSHomeDirectory()
        let opamPath = "\(home)/.opam/default/bin"

        var candidates: [String] = []

        // 1. Login-shell PATH — surfaces version-manager bin dirs the
        //    user wired up from `.zshrc` / `.bashrc` (NVM, asdf, pyenv,
        //    mise, volta, rbenv, …) that the hardcoded list cannot
        //    anticipate. Cached for the rest of the process lifetime.
        //    Entries are kept verbatim (no tilde expansion) because the
        //    login shell is the authoritative source for its own PATH
        //    representation; if it left a `~` unexpanded that's by
        //    design.
        if let loginPATH = loginShellPATH(), !loginPATH.isEmpty {
            candidates.append(contentsOf: loginPATH.split(separator: ":").map(String.init))
        }

        // 2. Canonical safety net — still valuable when the login
        //    shell is broken, unavailable, or just doesn't surface
        //    these (e.g. a stripped-down rc file). Built with literal
        //    `~` prefixes and tilde-expanded below so spawned `which`
        //    / `env` can resolve them.
        var safetyNet: [String] = [
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
            safetyNet.append(opamPath)
        }
        safetyNet.append(contentsOf: [
            "/usr/local/share/dotnet",
            "/usr/local/go/bin",
        ])
        candidates.append(contentsOf: expandUserDirs(safetyNet))

        // 3. Inherited launchd PATH — keeps `/usr/bin`, `/bin`, etc.
        //    reachable. Tail position so login-shell ordering wins.
        if let inherited = ProcessInfo.processInfo.environment["PATH"], !inherited.isEmpty {
            candidates.append(contentsOf: inherited.split(separator: ":").map(String.init))
        }

        // De-duplicate while preserving the first occurrence's order
        // so the login-shell view of PATH wins on overlap.
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(candidates.count)
        for path in candidates where seen.insert(path).inserted {
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
        try await runInternal(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: Self.runTimeoutSeconds
        )
    }

    /// Dedicated entry point for long-running install commands
    /// (`brew install`, `ghcup install hls`, `rustup component add`, …).
    /// Identical semantics to `run(...)` except the wall-clock watchdog
    /// uses `installTimeoutSeconds` (default 1 hour) instead of the
    /// 600 s `runTimeoutSeconds` budget. Probe / version-check / locate
    /// paths should keep using `run(...)`; only the actual install /
    /// prerequisite-install dispatch should call this.
    func installRun(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        try await runInternal(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: Self.installTimeoutSeconds
        )
    }

    /// Shared `Process`-spawning core for `run(...)` and `installRun(...)`.
    /// The only behavioural difference between the two public entry
    /// points is the `timeoutSeconds` value passed in here, so we keep a
    /// single canonical implementation and parameterise the watchdog.
    private func runInternal(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?,
        timeoutSeconds: TimeInterval
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

                // Watchdog: terminate runaway children at `timeoutSeconds`,
                // then SIGKILL 5s later if they still refuse to exit. The
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
                timer.schedule(deadline: .now() + timeoutSeconds)
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
                    stderrStr += "\ncommand timed out after \(Int(timeoutSeconds))s"
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
