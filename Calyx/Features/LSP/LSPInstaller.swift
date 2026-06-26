//
//  LSPInstaller.swift
//  Calyx
//
//  Actor that drives auto-installation of the 15 language servers Calyx
//  ships with. It consults `LSPServerRegistry` for the install recipes
//  and runs commands through an injectable `LSPCommandRunner` so the
//  app (and tests) never have to touch the real shell, `brew`, `npm`,
//  `rustup`, etc.
//
//  Design notes:
//    - All 7 types co-habit this file by design — they form one tight
//      installation subsystem and are easier to reason about together.
//    - `LSPInstaller` is an actor: mutable status / in-flight task
//      tracking are isolated to its actor context. Concurrent calls for
//      the same languageId share the in-flight `Task`, so the install
//      command runs exactly once even under fan-out.
//    - Concurrent calls for *different* languageIds that share the
//      same prerequisite (e.g. typescript + python both bootstrap `npm`
//      via `brew install node`) share a single prerequisite `Task`
//      keyed by the prerequisite's executable name so the shared
//      install command runs exactly once across the fan-out.
//    - Registry command strings are passed through `/bin/sh -c` when
//      they contain shell metacharacters (pipes, redirects, quoting,
//      env interpolation, glob, etc.) so the shell can perform
//      pipeline + quote handling. Plain whitespace-only commands are
//      `exec`'d directly so the runner sees the binary it actually
//      invokes — both forms route through the same `runRegistryCommand`
//      helper for consistency.
//    - When `LSPSettings.autoInstallEnabled` is `false`, `install(...)`
//      short-circuits with an explicit "auto-install disabled in
//      Settings" failure before any task is dispatched. This avoids
//      the legacy behaviour where the deprecated
//      `LSPSettings.confirmationMode(...)` bridge mapped the disabled
//      state onto a rejecting handler and surfaced the misleading
//      `"user declined: ..."` reason even though no user ever saw a
//      prompt.
//    - When the registry entry's `installation.safeToAutoRun` is
//      `false` and the caller requested `.silent`, both the main
//      install and any prerequisite install refuse to run and surface
//      an explicit consent-required failure. This protects unattended
//      callers (e.g. the MCP bridge) from triggering interactive OS
//      dialogs such as `xcode-select --install`.
//    - Failures propagate as `LSPInstallStatus.failed(reason:)`; the
//      installer never silently swallows errors mid-step.
//

import Foundation

// MARK: - CommandResult

/// Captured stdout / stderr / exit code from a single `LSPCommandRunner`
/// invocation. Mirrors what `Process` produces but is `Sendable` and
/// transport-agnostic for testability.
struct CommandResult: Sendable, Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

// MARK: - LSPCommandRunner

/// Abstract executor used by `LSPInstaller`. Production code wires a
/// real `Process`-backed implementation; tests inject `MockCommandRunner`
/// so no real `brew` / `npm` / `rustup` is touched.
protocol LSPCommandRunner: Sendable {
    /// Runs `executable` with `arguments`. The implementation is
    /// expected to throw if the process could not be spawned at all
    /// (vs. a non-zero exit which is reported via `CommandResult`).
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult

    /// Runs a long-running install command (`brew install`,
    /// `ghcup install hls`, `rustup component add`, …). Semantically
    /// identical to `run(...)` except the implementation is free to
    /// apply a longer wall-clock budget — install commands routinely
    /// run 30+ minutes and the standard `run(...)` watchdog would
    /// terminate them prematurely.
    ///
    /// The default implementation simply forwards to `run(...)`, so
    /// test seams (e.g. `MockCommandRunner`) that don't care about the
    /// timeout distinction need not override it. `SystemCommandRunner`
    /// overrides this with its own `installTimeoutSeconds` budget.
    func installRun(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult

    /// Finds `executable` on `PATH`. Returns `nil` when not found.
    /// Equivalent to `which(1)`.
    func locate(_ executable: String) async -> URL?
}

extension LSPCommandRunner {
    /// Default `installRun` forwards to `run(...)`. Mock / test runners
    /// inherit this for free; only `SystemCommandRunner` overrides it
    /// with the longer wall-clock budget.
    func installRun(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        try await run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
    }
}

// MARK: - MockCommandRunner

/// Test seam for `LSPCommandRunner`. Lives in the production module so
/// tests can `@testable import Calyx` and configure it without dragging
/// in test-only infrastructure. Not used by shipping code paths.
actor MockCommandRunner: LSPCommandRunner {

    // Configured locate results: executable name → URL (or explicit nil).
    private var locateResults: [String: URL?] = [:]
    // FIFO queues of run results, keyed by executable name.
    private var runResults: [String: [Result<CommandResult, Error>]] = [:]
    // Ordered record of every `run` invocation (executable + argv).
    private var runHistory: [(executable: String, arguments: [String])] = []
    // Optional hook fired *before* each `run` returns. Used by tests that
    // need to pause execution to inspect intermediate state.
    private var runHook: (@Sendable (String, [String]) async -> Void)?

    init() {}

    // MARK: Configuration (test-facing)

    func setLocateResult(_ executable: String, url: URL?) {
        locateResults[executable] = url
    }

    func enqueueRunResult(_ executable: String, result: Result<CommandResult, Error>) {
        runResults[executable, default: []].append(result)
    }

    func setRunHook(_ hook: (@Sendable (String, [String]) async -> Void)?) {
        runHook = hook
    }

    func history() -> [(executable: String, arguments: [String])] {
        runHistory
    }

    // MARK: LSPCommandRunner

    func locate(_ executable: String) async -> URL? {
        // `locateResults[executable]` is `URL??` — distinguish "never set"
        // from "set to nil".
        if let entry = locateResults[executable] {
            return entry
        }
        return nil
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        // Fire the hook first so tests can hold execution open before
        // the result is delivered.
        if let hook = runHook {
            await hook(executable, arguments)
        }
        runHistory.append((executable: executable, arguments: arguments))

        if var queue = runResults[executable], !queue.isEmpty {
            let next = queue.removeFirst()
            runResults[executable] = queue
            switch next {
            case .success(let value):
                return value
            case .failure(let error):
                throw error
            }
        }
        // Default success when nothing is enqueued — keeps single-test
        // setups concise.
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }
}

// MARK: - LSPInstallStatus

/// Lifecycle of a single language-server install. Stored per-languageId
/// in the installer and surfaced via `currentStatus(forLanguageId:)`.
enum LSPInstallStatus: Sendable, Equatable {
    case notStarted
    case inProgress(step: String)
    case completed
    case failed(reason: String)
}

// MARK: - InstallationCheck

/// Snapshot describing whether a language server is installed and what
/// of its prerequisites are present. Returned by
/// `LSPInstaller.checkInstallation(forLanguageId:)`.
struct InstallationCheck: Sendable, Equatable {
    let languageId: String
    let isInstalled: Bool
    let detectedPath: URL?
    let detectedVersion: String?
    /// Map from prerequisite executable name → its on-PATH URL, or `nil`
    /// when missing. Empty when there are no prerequisites (or the
    /// languageId is unknown).
    let prerequisiteStatuses: [String: URL?]
}

// MARK: - ConfirmationMode

/// How `LSPInstaller.install(...)` should consult the user before each
/// step. `.silent` runs without prompting; `.prompt` defers to a handler
/// closure that receives a human-readable step description and answers
/// `true` to proceed, `false` to abort.
enum ConfirmationMode: Sendable {
    case silent
    case prompt(handler: @Sendable (String) async -> Bool)
}

// MARK: - LSPInstaller

/// Drives the install lifecycle for each language server in the
/// registry. Concurrent `install(...)` calls for the same languageId are
/// deduplicated: the second caller shares the first call's `Task`, so
/// the install command runs exactly once.
actor LSPInstaller {

    // MARK: State

    private let registry: LSPServerRegistry
    private let runner: any LSPCommandRunner

    /// Latest known status per languageId, surfaced by
    /// `currentStatus(forLanguageId:)`.
    private var statuses: [String: LSPInstallStatus] = [:]

    /// In-flight installs, keyed by languageId. Used for dedup.
    private var inProgressTasks: [String: Task<LSPInstallStatus, Never>] = [:]

    /// In-flight prerequisite installs, keyed by the prerequisite's
    /// executable name. Lets concurrent `install(...)` calls for
    /// *different* languageIds share a single `Task` for a shared
    /// prerequisite (e.g. typescript + python both need `npm` and
    /// bootstrap it via `brew install node`).
    private var prereqInProgress: [String: Task<Bool, Never>] = [:]

    // MARK: Init

    init(registry: LSPServerRegistry, runner: any LSPCommandRunner) {
        self.registry = registry
        self.runner = runner
    }

    // MARK: Public API

    /// Probes whether the server for `id` is installed, captures its
    /// version if `versionArguments` is set, and records prerequisite
    /// presence. Unknown languageIds yield a synthetic "nothing
    /// installed" record (never `nil`).
    func checkInstallation(forLanguageId id: String) async -> InstallationCheck {
        guard let entry = registry.entry(forLanguageId: id) else {
            return InstallationCheck(
                languageId: id,
                isInstalled: false,
                detectedPath: nil,
                detectedVersion: nil,
                prerequisiteStatuses: [:]
            )
        }

        // Consult the entry's declared installation probe rather than
        // assuming the launch executable is always the right marker.
        // Some entries (notably Swift / `xcrun`) need a richer probe
        // because the launch executable is a wrapper that ships
        // unconditionally with the OS.
        let detectedPath: URL?
        let isInstalled: Bool
        switch entry.installationCheck {
        case .which(let name):
            // Build the launcher-name probe chain: the entry's
            // declared `.which(_)` name comes first (back-compat with
            // single-name entries where `installationCheck` was
            // explicitly set), then any additional names from
            // `executableCandidates` that aren't already covered.
            // `executableCandidates` defaults to `[entry.executable]`,
            // which equals `name` for the common case, so this collapses
            // to a single probe for entries that didn't opt in to a
            // fallback chain.
            var probeChain: [String] = [name]
            for candidate in entry.executableCandidates where !probeChain.contains(candidate) {
                probeChain.append(candidate)
            }
            var foundURL: URL? = nil
            for candidate in probeChain {
                if let url = await runner.locate(candidate) {
                    foundURL = url
                    break
                }
            }
            detectedPath = foundURL
            isInstalled = foundURL != nil
        case .command(let exe, let args, let expectExit0):
            // Gate the command probe on the wrapper executable
            // existing on PATH; otherwise we can't run it at all.
            let url = await runner.locate(exe)
            if url == nil {
                detectedPath = nil
                isInstalled = false
            } else {
                let result = try? await runner.run(
                    executable: exe,
                    arguments: args,
                    workingDirectory: nil,
                    environment: nil
                )
                if let result {
                    let matches = (result.exitCode == 0) == expectExit0
                    isInstalled = matches
                    detectedPath = matches ? url : nil
                } else {
                    isInstalled = false
                    detectedPath = nil
                }
            }
        }

        var detectedVersion: String? = nil
        if isInstalled {
            // Build the version-probe argument chain. The entry's
            // singular `versionArguments` comes first (back-compat),
            // then any additional sets from `versionArgumentCandidates`
            // that aren't already covered. `versionArgumentCandidates`
            // defaults to `[versionArguments]` when only the singular
            // is set, so this collapses to a single probe for entries
            // that didn't opt in to a fallback chain.
            var argChain: [[String]] = []
            if let primary = entry.versionArguments {
                argChain.append(primary)
            }
            for candidate in entry.versionArgumentCandidates where !argChain.contains(candidate) {
                argChain.append(candidate)
            }
            // Best-effort version probe. A failure here only means we
            // can't show a version string; it does not affect the
            // installed-ness verdict. Accept the first candidate that
            // exits 0 with non-empty stdout.
            for versionArgs in argChain {
                if let result = try? await runner.run(
                    executable: entry.executable,
                    arguments: versionArgs,
                    workingDirectory: nil,
                    environment: nil
                ), result.exitCode == 0 {
                    let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        detectedVersion = trimmed
                        break
                    }
                }
            }
        }

        var prereqStatuses: [String: URL?] = [:]
        for prereq in entry.installation.prerequisites {
            let url = await runner.locate(prereq.executable)
            prereqStatuses[prereq.executable] = url
        }

        return InstallationCheck(
            languageId: entry.languageId,
            isInstalled: isInstalled,
            detectedPath: detectedPath,
            detectedVersion: detectedVersion,
            prerequisiteStatuses: prereqStatuses
        )
    }

    /// Convenience: run `checkInstallation` for every entry in the
    /// registry. Returned dictionary is keyed by languageId.
    func checkAllInstallations() async -> [String: InstallationCheck] {
        var out: [String: InstallationCheck] = [:]
        for entry in registry.entries {
            out[entry.languageId] = await checkInstallation(forLanguageId: entry.languageId)
        }
        return out
    }

    /// Installs the server for `languageId`. Concurrent calls for the
    /// same languageId share a single in-flight task.
    ///
    /// When `LSPSettings.autoInstallEnabled` is `false`, the install
    /// short-circuits with an explicit "auto-install disabled in
    /// Settings" failure *before* any task is dispatched. This avoids
    /// the misleading `"user declined: ..."` reason the deprecated
    /// `LSPSettings.confirmationMode(...)` bridge used to produce when
    /// the master switch was off.
    func install(
        languageId: String,
        approvePrerequisites: Bool,
        confirmationMode: ConfirmationMode
    ) async -> LSPInstallStatus {
        if !LSPSettings.autoInstallEnabled {
            let status = LSPInstallStatus.failed(
                reason: "auto-install disabled in Settings "
                    + "(LSP Proxy → Auto-install language servers)"
            )
            statuses[languageId] = status
            return status
        }

        if let existing = inProgressTasks[languageId] {
            return await existing.value
        }

        let task = Task<LSPInstallStatus, Never> { [weak self] in
            guard let self else { return .failed(reason: "installer deallocated") }
            return await self.performInstall(
                languageId: languageId,
                approvePrerequisites: approvePrerequisites,
                confirmationMode: confirmationMode
            )
        }
        inProgressTasks[languageId] = task
        let status = await task.value
        inProgressTasks[languageId] = nil
        return status
    }

    /// Current install status for `id` (`.notStarted` if never touched).
    func currentStatus(forLanguageId id: String) -> LSPInstallStatus {
        statuses[id] ?? .notStarted
    }

    // MARK: - Internal

    private func performInstall(
        languageId: String,
        approvePrerequisites: Bool,
        confirmationMode: ConfirmationMode
    ) async -> LSPInstallStatus {
        guard let entry = registry.entry(forLanguageId: languageId) else {
            let status = LSPInstallStatus.failed(reason: "Unknown language: \(languageId)")
            statuses[languageId] = status
            return status
        }

        // 1. Prerequisites
        if approvePrerequisites {
            for prereq in entry.installation.prerequisites {
                let url = await runner.locate(prereq.executable)
                if url != nil { continue }

                guard let installCommand = prereq.installCommand else {
                    let manual = prereq.manualInstructions ?? "see docs"
                    let status = LSPInstallStatus.failed(
                        reason: "Manual install required for \(prereq.executable): \(manual)"
                    )
                    statuses[languageId] = status
                    return status
                }

                // Per-prerequisite safeToAutoRun gate. `LSPPrerequisite`
                // does not (yet) carry its own `safeToAutoRun` flag, so
                // we default the gate to the entry-level value — a
                // language whose main install is unsafe to auto-run
                // (e.g. swift / xcode-select) should not have its
                // prerequisites auto-run either.
                if !entry.installation.safeToAutoRun,
                   case .silent = confirmationMode {
                    let status = LSPInstallStatus.failed(
                        reason: "\(entry.displayName) prerequisite \(prereq.executable) "
                            + "install requires explicit user consent "
                            + "(safeToAutoRun=false; set Confirm before each install step)"
                    )
                    statuses[languageId] = status
                    return status
                }

                let step = "Install prerequisite \(prereq.executable) via \(installCommand)"
                statuses[languageId] = .inProgress(step: step)

                if case .prompt(let handler) = confirmationMode {
                    let approved = await handler(step)
                    if !approved {
                        let status = LSPInstallStatus.failed(reason: "user declined: \(step)")
                        statuses[languageId] = status
                        return status
                    }
                }

                let success = await runPrerequisiteDeduped(
                    executableName: prereq.executable,
                    command: installCommand
                )
                if !success {
                    let status = LSPInstallStatus.failed(
                        reason: "prerequisite \(prereq.executable) install failed"
                    )
                    statuses[languageId] = status
                    return status
                }
            }
        }

        // 2. safeToAutoRun gate for the main install in silent mode.
        //    The registry pins `safeToAutoRun = false` for entries whose
        //    install command shows an interactive prompt (e.g. swift's
        //    `xcode-select --install` opens a macOS GUI dialog). Silent
        //    callers must not trigger those dialogs without user
        //    consent.
        if !entry.installation.safeToAutoRun, case .silent = confirmationMode {
            let status = LSPInstallStatus.failed(
                reason: "\(entry.displayName) install requires explicit user consent "
                    + "(safeToAutoRun=false; set Confirm before each install step)"
            )
            statuses[languageId] = status
            return status
        }

        // 3. Main install command
        let step = "Install \(entry.displayName) via \(entry.installation.command)"
        statuses[languageId] = .inProgress(step: step)

        if case .prompt(let handler) = confirmationMode {
            let approved = await handler(step)
            if !approved {
                let status = LSPInstallStatus.failed(reason: "user declined: \(step)")
                statuses[languageId] = status
                return status
            }
        }

        do {
            let result = try await runRegistryCommand(entry.installation.command)
            if result.exitCode != 0 {
                let status = LSPInstallStatus.failed(
                    reason: "install \(entry.displayName) failed: exit \(result.exitCode) \(result.stderr)"
                )
                statuses[languageId] = status
                return status
            }
        } catch {
            let status = LSPInstallStatus.failed(reason: "command failed: \(error)")
            statuses[languageId] = status
            return status
        }

        statuses[languageId] = .completed
        return .completed
    }

    // MARK: - Command execution helpers

    /// Runs a registry command string against `runner`. Commands that
    /// contain shell metacharacters (pipes, redirects, quoting, env
    /// interpolation, glob, etc.) are routed through `/bin/sh -c` so
    /// the shell can perform pipeline + quote handling. Plain
    /// whitespace-only commands are exec'd directly so the runner sees
    /// the binary it actually invokes — this matters because
    /// `MockCommandRunner` keys its enqueued results by executable name,
    /// and direct registry tests (e.g. `npm install -g …`) assert that
    /// the registry's own argv appears in `runner.history()`.
    ///
    /// Uses `runner.installRun(...)` rather than `runner.run(...)` so
    /// long-running compile-from-source installs (`ghcup install hls`,
    /// `brew install` on a cold cache, …) get the longer wall-clock
    /// budget rather than the 600 s `run(...)` watchdog that would
    /// terminate them prematurely.
    private func runRegistryCommand(_ command: String) async throws -> CommandResult {
        if Self.commandNeedsShell(command) {
            return try await runner.installRun(
                executable: "/bin/sh",
                arguments: ["-c", command],
                workingDirectory: nil,
                environment: nil
            )
        }
        let (exe, args) = splitShell(command)
        return try await runner.installRun(
            executable: exe,
            arguments: args,
            workingDirectory: nil,
            environment: nil
        )
    }

    /// Dedup-by-executable-name wrapper around `runRegistryCommand`.
    /// Concurrent prerequisite installs that target the same executable
    /// share a single `Task` — the second caller awaits the first
    /// caller's outcome instead of dispatching a duplicate run. Returns
    /// `true` on exit-code 0; `false` on any non-zero exit or a thrown
    /// runner error.
    private func runPrerequisiteDeduped(
        executableName: String,
        command: String
    ) async -> Bool {
        if let inFlight = prereqInProgress[executableName] {
            return await inFlight.value
        }

        // Capture the runner locally — `Task { ... }` does not inherit
        // actor isolation, so we cannot touch `self` from inside the
        // task body. The runner protocol is `Sendable`.
        //
        // Uses `installRun(...)` so prerequisite installers (e.g.
        // `brew install node` to bootstrap `npm`) get the longer
        // wall-clock budget rather than the 600 s `run(...)` watchdog.
        let capturedRunner = runner
        let task = Task<Bool, Never> {
            do {
                let result: CommandResult
                if Self.commandNeedsShell(command) {
                    result = try await capturedRunner.installRun(
                        executable: "/bin/sh",
                        arguments: ["-c", command],
                        workingDirectory: nil,
                        environment: nil
                    )
                } else {
                    let parts = command.split(separator: " ").map(String.init)
                    guard let head = parts.first else { return false }
                    result = try await capturedRunner.installRun(
                        executable: head,
                        arguments: Array(parts.dropFirst()),
                        workingDirectory: nil,
                        environment: nil
                    )
                }
                return result.exitCode == 0
            } catch {
                return false
            }
        }
        prereqInProgress[executableName] = task
        let success = await task.value
        // Only the original creator resumes here on the actor with the
        // slot still pointing at our task; later peers that joined via
        // `inFlight.value` returned above without touching the slot.
        prereqInProgress[executableName] = nil
        return success
    }

    /// True iff `command` contains characters that require a shell to
    /// be interpreted correctly: pipes, redirects, command separators,
    /// subshell parens, env interpolation, backticks, quoting, glob,
    /// brace expansion, char classes, history expansion, variable
    /// assignments, etc. Implemented as a safe-charset whitelist —
    /// alphanumerics plus `. - _ / ` and ASCII whitespace (space, tab)
    /// are considered safe; anything else requires shell evaluation.
    /// This catches every traditional metacharacter AND newer hazards
    /// (`{`, `}`, `[`, `]`, `!`, `=`, …) by construction. Used to
    /// decide whether to route a registry command through `/bin/sh -c`
    /// or `exec` it directly.
    private static func commandNeedsShell(_ command: String) -> Bool {
        var safe = CharacterSet.alphanumerics
        safe.insert(charactersIn: ".-_/ \t")
        return command.unicodeScalars.contains { !safe.contains($0) }
    }

    /// Whitespace-only split of a shell one-liner into
    /// `(executable, arguments)`. Used for the simple-command path;
    /// pipeline-bearing commands go through `/bin/sh -c` via
    /// `runRegistryCommand` instead. Empty input is folded onto a
    /// `/bin/sh -c ""` shape rather than crashing — production code
    /// should never produce an empty command, but a defensive return
    /// is preferable to a `precondition` trap.
    private func splitShell(_ shell: String) -> (executable: String, arguments: [String]) {
        let parts = shell.split(separator: " ").map(String.init)
        if parts.isEmpty {
            return ("/bin/sh", ["-c", shell])
        }
        return (parts[0], Array(parts.dropFirst()))
    }
}
