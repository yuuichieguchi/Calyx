//
//  LSPInstallerTests.swift
//  Calyx
//
//  Tests for `LSPInstaller` — the actor that drives auto-installation of
//  the 15 language servers Calyx ships with. The installer cooperates
//  with `LSPServerRegistry` for the install recipes, and with an
//  injectable `LSPCommandRunner` so tests never touch the real shell,
//  `brew`, `npm`, `rustup`, etc.
//
//  TDD phase: RED. None of the installer types exist yet. This file is
//  expected to fail to compile until the swift-specialist creates
//  `Calyx/Features/LSP/LSPInstaller.swift` (all 7 types must live in the
//  same file in the implementation):
//    - LSPCommandRunner            (protocol)
//    - CommandResult               (struct)
//    - MockCommandRunner           (actor, test seam)
//    - LSPInstallStatus            (enum)
//    - LSPInstaller                (actor)
//    - ConfirmationMode            (enum)
//    - InstallationCheck           (struct)
//
//  Notes on test design:
//    - Each test creates a fresh `MockCommandRunner` so state never bleeds.
//    - Expected install commands are pulled live from the registry; we
//      never hard-code shell strings (avoids drift if the registry table
//      is edited).
//    - Concurrency assertions use `async let` and a short
//      `Task.sleep(nanoseconds:)` where coordination is unavoidable. The
//      whole file is budgeted to finish well under 5 seconds.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPInstallerTests: XCTestCase {

    // ====================================================================
    // MARK: - Helpers
    // ====================================================================

    /// Fresh built-in registry per test.
    private func makeRegistry() -> LSPServerRegistry {
        LSPServerRegistry.builtIn()
    }

    /// Stand-in URL for "this executable is on PATH at this absolute path".
    private func bin(_ name: String) -> URL {
        URL(fileURLWithPath: "/usr/local/bin/\(name)")
    }

    /// Convenience for the success case of `CommandResult`.
    private func ok(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
    }

    /// Convenience for a failed `CommandResult`.
    private func fail(
        exitCode: Int32 = 1,
        stdout: String = "",
        stderr: String = "boom"
    ) -> CommandResult {
        CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    /// Split a shell one-liner into argv-style components for the runner.
    /// This is the same split rule the implementation is expected to use:
    /// whitespace-delimited tokens, no quoting support (the registry table
    /// never uses quoted args). Tests compare on the resulting argv.
    private func split(_ shell: String) -> (executable: String, arguments: [String]) {
        let parts = shell.split(separator: " ").map(String.init)
        precondition(!parts.isEmpty, "registry command must not be empty")
        return (parts[0], Array(parts.dropFirst()))
    }

    // ====================================================================
    // MARK: - 1. checkInstallation — installed
    // ====================================================================

    func test_checkInstallation_whenExecutableFound_returnsInstalledTrue() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        let tsPath = bin("typescript-language-server")
        await runner.setLocateResult("typescript-language-server", url: tsPath)
        // `--version` invocation succeeds with a version string.
        await runner.enqueueRunResult(
            "typescript-language-server",
            result: .success(CommandResult(exitCode: 0, stdout: "4.3.3\n", stderr: ""))
        )

        let installer = LSPInstaller(registry: registry, runner: runner)
        let check = await installer.checkInstallation(forLanguageId: "typescript")

        XCTAssertEqual(check.languageId, "typescript")
        XCTAssertTrue(check.isInstalled)
        XCTAssertEqual(check.detectedPath, tsPath)
    }

    // ====================================================================
    // MARK: - 2. checkInstallation — not installed
    // ====================================================================

    func test_checkInstallation_whenExecutableNotFound_returnsInstalledFalse() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        // Nothing pre-set on the runner → locate returns nil for everything.

        let installer = LSPInstaller(registry: registry, runner: runner)
        let check = await installer.checkInstallation(forLanguageId: "rust")

        XCTAssertEqual(check.languageId, "rust")
        XCTAssertFalse(check.isInstalled)
        XCTAssertNil(check.detectedPath)
        XCTAssertNil(check.detectedVersion)
    }

    // ====================================================================
    // MARK: - 3. checkInstallation — version captured
    // ====================================================================

    func test_checkInstallation_withVersionArguments_capturesVersion() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        let raPath = bin("rust-analyzer")
        await runner.setLocateResult("rust-analyzer", url: raPath)
        await runner.enqueueRunResult(
            "rust-analyzer",
            result: .success(
                CommandResult(
                    exitCode: 0,
                    stdout: "rust-analyzer 1.85.0\n",
                    stderr: ""
                )
            )
        )

        let installer = LSPInstaller(registry: registry, runner: runner)
        let check = await installer.checkInstallation(forLanguageId: "rust")

        XCTAssertTrue(check.isInstalled)
        XCTAssertEqual(check.detectedPath, raPath)
        // The version is captured verbatim from stdout (trimmed).
        XCTAssertEqual(check.detectedVersion, "rust-analyzer 1.85.0")

        // The version-detection command must have actually run with the
        // registry-declared argv for the rust entry.
        let rustEntry = registry.entry(forLanguageId: "rust")
        XCTAssertNotNil(rustEntry)
        let history = await runner.history()
        XCTAssertTrue(
            history.contains { record in
                record.executable == "rust-analyzer"
                    && record.arguments == (rustEntry?.versionArguments ?? [])
            },
            "expected rust-analyzer to be invoked with versionArguments; got \(history)"
        )
    }

    // ====================================================================
    // MARK: - 4. checkInstallation — unknown languageId
    // ====================================================================

    func test_checkInstallation_unknownLanguageId_returnsNil() async {
        // Per the brief, unknown ids return a synthetic, "nothing installed"
        // InstallationCheck — never nil. Naming is preserved for parity
        // with the task spec.
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        let installer = LSPInstaller(registry: registry, runner: runner)

        let check = await installer.checkInstallation(forLanguageId: "cobol")

        XCTAssertEqual(check.languageId, "cobol")
        XCTAssertFalse(check.isInstalled)
        XCTAssertNil(check.detectedPath)
        XCTAssertNil(check.detectedVersion)
        XCTAssertEqual(check.prerequisiteStatuses.count, 0)
    }

    // ====================================================================
    // MARK: - 5. checkAllInstallations
    // ====================================================================

    func test_checkAllInstallations_returnsAllFifteenLanguages() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        let installer = LSPInstaller(registry: registry, runner: runner)

        let all = await installer.checkAllInstallations()

        XCTAssertEqual(all.keys.count, 15)
        for entry in registry.entries {
            XCTAssertNotNil(
                all[entry.languageId],
                "missing check for \(entry.languageId)"
            )
            // Nothing was pre-set on the runner, so every entry must
            // report "not installed".
            XCTAssertEqual(all[entry.languageId]?.languageId, entry.languageId)
            XCTAssertEqual(all[entry.languageId]?.isInstalled, false)
        }
    }

    // ====================================================================
    // MARK: - 6. install — silent happy path
    // ====================================================================

    func test_install_silent_executesInstallCommand() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()

        // The typescript install is `npm install -g typescript-language-server typescript`.
        // npm must be locatable so the prerequisite check passes.
        await runner.setLocateResult("npm", url: bin("npm"))

        // Enqueue success for the install command itself.
        await runner.enqueueRunResult("npm", result: .success(ok(stdout: "added 1 package\n")))

        let installer = LSPInstaller(registry: registry, runner: runner)
        let status = await installer.install(
            languageId: "typescript",
            approvePrerequisites: false,
            confirmationMode: .silent
        )

        XCTAssertEqual(status, .completed)

        let history = await runner.history()
        // Pull the expected argv from the registry rather than hard-coding.
        let tsEntry = registry.entry(forLanguageId: "typescript")
        XCTAssertNotNil(tsEntry)
        let (exe, args) = split(tsEntry!.installation.command)
        XCTAssertTrue(
            history.contains { $0.executable == exe && $0.arguments == args },
            "expected install command \(exe) \(args) in history; got \(history)"
        )
    }

    // ====================================================================
    // MARK: - 7. install — runner reports failure
    // ====================================================================

    func test_install_failedCommand_returnsFailed() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        await runner.setLocateResult("npm", url: bin("npm"))
        await runner.enqueueRunResult(
            "npm",
            result: .success(fail(exitCode: 17, stderr: "EACCES"))
        )

        let installer = LSPInstaller(registry: registry, runner: runner)
        let status = await installer.install(
            languageId: "typescript",
            approvePrerequisites: false,
            confirmationMode: .silent
        )

        switch status {
        case .failed(let reason):
            XCTAssertFalse(reason.isEmpty, "failure reason must be populated")
        default:
            XCTFail("expected .failed, got \(status)")
        }
    }

    // ====================================================================
    // MARK: - 8. install — unknown languageId
    // ====================================================================

    func test_install_unknownLanguageId_returnsFailed() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        let installer = LSPInstaller(registry: registry, runner: runner)

        let status = await installer.install(
            languageId: "cobol",
            approvePrerequisites: false,
            confirmationMode: .silent
        )

        switch status {
        case .failed(let reason):
            XCTAssertFalse(reason.isEmpty)
        default:
            XCTFail("expected .failed for unknown languageId, got \(status)")
        }

        // No commands should have been run for an unknown language.
        let history = await runner.history()
        XCTAssertTrue(history.isEmpty, "no commands expected; got \(history)")
    }

    // ====================================================================
    // MARK: - 9. install — prompt mode, user declines
    // ====================================================================

    func test_install_promptMode_handlerRejects_returnsFailed() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        await runner.setLocateResult("npm", url: bin("npm"))

        let installer = LSPInstaller(registry: registry, runner: runner)
        let status = await installer.install(
            languageId: "typescript",
            approvePrerequisites: false,
            confirmationMode: .prompt(handler: { _ in false })
        )

        switch status {
        case .failed(let reason):
            // Spec: when the user declines, the reason string includes
            // "user declined" verbatim so downstream UI can pattern-match.
            XCTAssertTrue(
                reason.lowercased().contains("user declined"),
                "expected reason to mention 'user declined'; got '\(reason)'"
            )
        default:
            XCTFail("expected .failed when handler returns false, got \(status)")
        }

        // No install command should have run.
        let history = await runner.history()
        XCTAssertTrue(
            history.allSatisfy { $0.executable != "npm" || $0.arguments.first != "install" },
            "no npm install should have run when user declined; got \(history)"
        )
    }

    // ====================================================================
    // MARK: - 10. install — prompt mode, user approves
    // ====================================================================

    func test_install_promptMode_handlerApproves_executes() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        await runner.setLocateResult("npm", url: bin("npm"))
        await runner.enqueueRunResult("npm", result: .success(ok()))

        let installer = LSPInstaller(registry: registry, runner: runner)
        let status = await installer.install(
            languageId: "typescript",
            approvePrerequisites: false,
            confirmationMode: .prompt(handler: { _ in true })
        )

        XCTAssertEqual(status, .completed)

        let history = await runner.history()
        let tsEntry = registry.entry(forLanguageId: "typescript")!
        let (exe, args) = split(tsEntry.installation.command)
        XCTAssertTrue(
            history.contains { $0.executable == exe && $0.arguments == args },
            "expected install command in history after approval; got \(history)"
        )
    }

    // ====================================================================
    // MARK: - 11. install — concurrent calls deduplicate
    // ====================================================================

    func test_install_concurrentCalls_dedup() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        await runner.setLocateResult("npm", url: bin("npm"))
        // Only one success enqueued. If dedup is broken, the second
        // concurrent call will hit an empty queue and surface as .failed,
        // which the assertion below catches.
        await runner.enqueueRunResult("npm", result: .success(ok()))

        let installer = LSPInstaller(registry: registry, runner: runner)

        async let a = installer.install(
            languageId: "typescript",
            approvePrerequisites: false,
            confirmationMode: .silent
        )
        async let b = installer.install(
            languageId: "typescript",
            approvePrerequisites: false,
            confirmationMode: .silent
        )
        let (statusA, statusB) = await (a, b)

        XCTAssertEqual(statusA, .completed)
        XCTAssertEqual(statusB, .completed, "second concurrent call must share the first install's result")

        // The runner should have been asked to execute the install command
        // exactly once, despite two concurrent install() calls.
        let history = await runner.history()
        let tsEntry = registry.entry(forLanguageId: "typescript")!
        let (exe, args) = split(tsEntry.installation.command)
        let matches = history.filter { $0.executable == exe && $0.arguments == args }
        XCTAssertEqual(
            matches.count, 1,
            "install command must run only once; ran \(matches.count) times. history=\(history)"
        )
    }

    // ====================================================================
    // MARK: - 12. install — prerequisites chain
    // ====================================================================

    func test_install_withPrerequisites_chains() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()

        // npm is missing → installer must run the prerequisite install
        // command ("brew install node") before the main install. We
        // intentionally do NOT set a locate for "npm" so the installer
        // sees it as missing. `brew` itself is locatable.
        await runner.setLocateResult("brew", url: bin("brew"))

        // First: prerequisite install (brew install node) succeeds.
        await runner.enqueueRunResult("brew", result: .success(ok(stdout: "installed node\n")))
        // Then: main install (npm install -g …) succeeds.
        await runner.enqueueRunResult("npm", result: .success(ok(stdout: "installed ts\n")))

        let installer = LSPInstaller(registry: registry, runner: runner)
        let status = await installer.install(
            languageId: "typescript",
            approvePrerequisites: true,
            confirmationMode: .silent
        )

        XCTAssertEqual(status, .completed)

        let history = await runner.history()
        // Expected ordering: brew install node FIRST, then npm install.
        let tsEntry = registry.entry(forLanguageId: "typescript")!
        let prereq = tsEntry.installation.prerequisites.first!
        let (prereqExe, prereqArgs) = split(prereq.installCommand!)
        let (mainExe, mainArgs) = split(tsEntry.installation.command)

        let prereqIdx = history.firstIndex { $0.executable == prereqExe && $0.arguments == prereqArgs }
        let mainIdx = history.firstIndex { $0.executable == mainExe && $0.arguments == mainArgs }
        XCTAssertNotNil(prereqIdx, "prerequisite \(prereqExe) \(prereqArgs) was not invoked; got \(history)")
        XCTAssertNotNil(mainIdx, "main install \(mainExe) \(mainArgs) was not invoked; got \(history)")
        if let p = prereqIdx, let m = mainIdx {
            XCTAssertLessThan(p, m, "prerequisite must precede main install in history; got \(history)")
        }
    }

    // ====================================================================
    // MARK: - 13. install — prompt mode, per-step confirmation
    // ====================================================================

    func test_install_withPrerequisites_promptMode_perStepConfirmation() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        await runner.setLocateResult("brew", url: bin("brew"))
        // npm missing again → triggers prerequisite chain.
        await runner.enqueueRunResult("brew", result: .success(ok()))
        await runner.enqueueRunResult("npm", result: .success(ok()))

        // Capture every step description the installer asks about.
        let captured = StepCapture()
        let installer = LSPInstaller(registry: registry, runner: runner)
        let status = await installer.install(
            languageId: "typescript",
            approvePrerequisites: true,
            confirmationMode: .prompt(handler: { description in
                await captured.record(description)
                return true
            })
        )

        XCTAssertEqual(status, .completed)

        let steps = await captured.steps()
        XCTAssertGreaterThanOrEqual(
            steps.count, 2,
            "handler must be invoked at least once per step (prerequisite + main); got \(steps)"
        )
        // Step descriptions are free-form strings, but ordering must be
        // prerequisite-before-main, and both must mention something we
        // can lock onto: the executable name for prereq, the languageId
        // (or the registry display name) for main.
        XCTAssertTrue(
            steps.first?.lowercased().contains("npm") == true
                || steps.first?.lowercased().contains("node") == true
                || steps.first?.lowercased().contains("brew") == true,
            "first prompt should describe the prerequisite step; got '\(steps.first ?? "<nil>")'"
        )
    }

    // ====================================================================
    // MARK: - 14. currentStatus reflects in-progress install
    // ====================================================================

    func test_currentStatus_reflectsInProgress() async throws {
        let registry = makeRegistry()
        let runner = MockCommandRunner()
        await runner.setLocateResult("npm", url: bin("npm"))

        // Make the install command hang until we explicitly release it,
        // so we have a guaranteed window in which currentStatus must
        // report .inProgress.
        let gate = AsyncGate()
        await runner.enqueueRunResult(
            "npm",
            result: .success(ok())
        )
        await runner.setRunHook { _, _ in
            await gate.wait()
        }

        let installer = LSPInstaller(registry: registry, runner: runner)

        // Kick off the install in a detached task so we can poll status.
        let installTask = Task {
            await installer.install(
                languageId: "typescript",
                approvePrerequisites: false,
                confirmationMode: .silent
            )
        }

        // Give the installer a chance to enter the in-progress state.
        // 50ms is enough on every machine we test on; total budget for
        // this test stays well under 1s.
        try await Task.sleep(nanoseconds: 50_000_000)

        let mid = await installer.currentStatus(forLanguageId: "typescript")
        switch mid {
        case .inProgress:
            break // expected
        default:
            XCTFail("expected .inProgress while command is running; got \(mid)")
        }

        // Release the hook, let the install finish, and verify the final
        // status flips to .completed.
        await gate.open()
        let final = await installTask.value
        XCTAssertEqual(final, .completed)

        let afterStatus = await installer.currentStatus(forLanguageId: "typescript")
        XCTAssertEqual(afterStatus, .completed)
    }
}

// ====================================================================
// MARK: - Local test-only support actors
// ====================================================================

/// Records the descriptions passed to a ConfirmationMode.prompt handler.
private actor StepCapture {
    private var captured: [String] = []
    func record(_ s: String) { captured.append(s) }
    func steps() -> [String] { captured }
}

/// Trivial async one-shot gate so test 14 can hold the install command
/// open while the test inspects currentStatus.
private actor AsyncGate {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuations.append(cont)
        }
    }

    func open() {
        opened = true
        let pending = continuations
        continuations.removeAll()
        for c in pending { c.resume() }
    }
}
