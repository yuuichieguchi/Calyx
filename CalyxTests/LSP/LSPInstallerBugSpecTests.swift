//
//  LSPInstallerBugSpecTests.swift
//  CalyxTests
//
//  RED-phase regression tests for four `LSPInstaller` bugs derived from
//  the live production source (Calyx/Features/LSP/LSPInstaller.swift) and
//  the registry table (Calyx/Features/LSP/LSPServerRegistry.swift).
//
//  Bugs covered (each test maps 1:1 to a bug):
//    1. `splitShell` mangles shell pipelines — the rustup prereq
//       `curl ... | sh` becomes argv with literal `|` and `sh` tokens.
//    2. `safeToAutoRun` is dead code — `performInstall` never reads it,
//       so silent mode happily runs the macOS `xcode-select --install`
//       GUI prompt without user consent.
//    3. Cross-language prerequisite duplication — installing TypeScript
//       and Python concurrently runs `brew install node` twice instead
//       of dedup'ing the shared `npm` prerequisite.
//    4. `LSPSettings.resolve(...).disabled` round-trips through the
//       deprecated `confirmationMode(...)` bridge, surfacing a
//       misleading `"user declined: ..."` failure when no user ever
//       saw a prompt — the installer should report
//       `"auto-install disabled"` instead.
//
//  These tests are INDEPENDENT of LSPInstallerTests.swift — separate
//  class, separate fixtures. A private copy of `MockCommandRunner`'s
//  behavioural contract is reused via the production `MockCommandRunner`
//  actor exposed through `@testable import Calyx`.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPInstallerBugSpecTests: XCTestCase {

    // ====================================================================
    // MARK: - Helpers (independent of LSPInstallerTests.swift)
    // ====================================================================

    /// Fresh built-in registry per test.
    private func makeRegistry() -> LSPServerRegistry {
        LSPServerRegistry.builtIn()
    }

    /// Stand-in URL for "this executable resolves on PATH".
    private func bin(_ name: String) -> URL {
        URL(fileURLWithPath: "/usr/local/bin/\(name)")
    }

    /// Success CommandResult shortcut.
    private func ok(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
    }

    // ====================================================================
    // MARK: - Bug 1. splitShell mangles `curl ... | sh`
    // ====================================================================
    //
    // The rustup prerequisite installCommand is literally:
    //   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
    //
    // A whitespace-only split produces:
    //   executable = "curl"
    //   arguments  = ["--proto", "'=https'", "--tlsv1.2", "-sSf",
    //                 "https://sh.rustup.rs", "|", "sh"]
    // which is nonsense: `|` is a shell operator, not a curl argv element,
    // and the embedded single-quoted `'=https'` will be passed verbatim
    // (with the quotes) to curl, which is also wrong.
    //
    // Post-fix expectation: the installer routes pipeline-bearing one-liners
    // through `/bin/sh -c "<the whole one-liner>"` so the shell gets to
    // perform pipeline + quote handling.

    func test_install_rustPrereq_pipelineIsExecutedViaShell_notLiteralPipe() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()

        // rustup is missing → prereq install kicks in.
        // We do NOT set a locate for "rustup".
        // We pre-enqueue success for the expected post-fix executor
        // ("/bin/sh"), and also for the would-be pre-fix executor
        // ("curl") so the test fails on the assertion, not on a runner
        // queue exhaustion.
        await runner.enqueueRunResult("/bin/sh", result: .success(ok()))
        await runner.enqueueRunResult("curl", result: .success(ok()))
        // The main install command is `rustup component add rust-analyzer`.
        // Pre-fix splits cleanly into ("rustup", ["component", "add",
        // "rust-analyzer"]). Enqueue success so the overall install
        // returns .completed if we got that far.
        await runner.enqueueRunResult("rustup", result: .success(ok()))

        let installer = LSPInstaller(registry: registry, runner: runner)
        _ = await installer.install(
            languageId: "rust",
            approvePrerequisites: true,
            confirmationMode: .silent
        )

        let history = await runner.history()

        // POST-FIX: must invoke /bin/sh -c "<curl ... | sh>".
        let invokedViaShell = history.contains { record in
            record.executable == "/bin/sh"
                && record.arguments.count >= 2
                && record.arguments[0] == "-c"
                && record.arguments[1].contains("curl")
                && record.arguments[1].contains("sh.rustup.rs")
                && record.arguments[1].contains("|")
        }
        XCTAssertTrue(
            invokedViaShell,
            "expected installer to invoke /bin/sh -c '<curl ... | sh>'; got history=\(history)"
        )

        // PRE-FIX: passes literal `|` and `sh` as argv elements to curl.
        // After the fix this must not happen.
        let leakedLiteralPipe = history.contains { record in
            record.executable == "curl" && record.arguments.contains("|")
        }
        XCTAssertFalse(
            leakedLiteralPipe,
            "must not pass literal '|' as an argv element to curl; got history=\(history)"
        )

        // PRE-FIX: also leaks the single-quoted `'=https'` token because
        // splitShell does not strip quoting. Post-fix shell handles this.
        let leakedQuotedToken = history.contains { record in
            record.executable == "curl" && record.arguments.contains("'=https'")
        }
        XCTAssertFalse(
            leakedQuotedToken,
            "must not pass literal `'=https'` (with quotes) as a curl arg; got history=\(history)"
        )
    }

    // ====================================================================
    // MARK: - Bug 2. safeToAutoRun is dead — silent mode bypasses consent
    // ====================================================================
    //
    // The Swift registry entry pins `safeToAutoRun: false` because its
    // install command (`xcode-select --install`) shows a macOS GUI dialog.
    // `performInstall` ignores that flag entirely, so silent-mode callers
    // (e.g. the MCP bridge running unattended) trigger the OS dialog
    // without any user consent.
    //
    // Post-fix expectation: when `safeToAutoRun == false` and the caller
    // requested `.silent`, the installer refuses to execute the command
    // and surfaces an explicit consent-required failure.

    func test_install_swiftSilentMode_refusesUnsafeAutoRun() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()

        // Sanity-check our assumption against the registry rather than
        // hard-coding the entry shape.
        let swiftEntry = registry.entry(forLanguageId: "swift")
        XCTAssertNotNil(swiftEntry, "registry must contain the swift entry")
        XCTAssertEqual(
            swiftEntry?.installation.safeToAutoRun, false,
            "swift entry must have safeToAutoRun=false for this test to be meaningful"
        )

        let installer = LSPInstaller(registry: registry, runner: runner)
        let status = await installer.install(
            languageId: "swift",
            approvePrerequisites: false,
            confirmationMode: .silent
        )

        // Assertion A: command must NOT have been executed.
        let history = await runner.history()
        let ranXcodeSelect = history.contains { record in
            record.executable == "xcode-select" && record.arguments.contains("--install")
        }
        XCTAssertFalse(
            ranXcodeSelect,
            "silent mode must not execute xcode-select --install when safeToAutoRun=false; got history=\(history)"
        )

        // Assertion B: status must be .failed with an explicit
        // consent-required reason (NOT .completed and NOT a silent succeed).
        switch status {
        case .failed(let reason):
            let lowered = reason.lowercased()
            let mentionsConsent =
                lowered.contains("consent")
                || lowered.contains("safetoautorun")
                || lowered.contains("safe to auto")
                || lowered.contains("interactive")
                || lowered.contains("requires confirmation")
                || lowered.contains("requires approval")
                || lowered.contains("prompt required")
            XCTAssertTrue(
                mentionsConsent,
                "expected reason to mention explicit consent / safeToAutoRun; got '\(reason)'"
            )
        default:
            XCTFail(
                "expected .failed when safeToAutoRun=false and mode=.silent; got \(status)"
            )
        }
    }

    // ====================================================================
    // MARK: - Bug 3. cross-language prerequisite duplication
    // ====================================================================
    //
    // TypeScript and Python both declare `npm` as a prerequisite, and both
    // declare the same `installCommand` ("brew install node") to bootstrap
    // it. With `npm` missing on PATH, installing both languages
    // concurrently runs `brew install node` twice — once per languageId —
    // because the installer only dedups whole `install(languageId:)`
    // tasks, not per-prerequisite installs across languages.
    //
    // Post-fix expectation: the installer dedups concurrent prerequisite
    // installs by executable name so the shared `brew install node` runs
    // exactly once even under fan-out.

    func test_install_concurrentLanguages_dedupSharedPrerequisite() async {
        let registry = makeRegistry()
        let runner = MockCommandRunner()

        // brew is available, npm is not.
        await runner.setLocateResult("brew", url: bin("brew"))
        // (We intentionally do NOT set a locate for "npm".)

        // Pre-fix runs brew install node TWICE — enqueue two successes so
        // the queue does not become a confounding factor.
        await runner.enqueueRunResult("brew", result: .success(ok(stdout: "installed node\n")))
        await runner.enqueueRunResult("brew", result: .success(ok(stdout: "installed node\n")))
        // Each language's main install runs npm install -g ... once.
        await runner.enqueueRunResult("npm", result: .success(ok()))
        await runner.enqueueRunResult("npm", result: .success(ok()))

        let installer = LSPInstaller(registry: registry, runner: runner)

        async let ts = installer.install(
            languageId: "typescript",
            approvePrerequisites: true,
            confirmationMode: .silent
        )
        async let py = installer.install(
            languageId: "python",
            approvePrerequisites: true,
            confirmationMode: .silent
        )
        _ = await (ts, py)

        let history = await runner.history()

        // Count distinct `brew install node` invocations.
        let brewInstallNodeCount = history.filter { record in
            record.executable == "brew" && record.arguments == ["install", "node"]
        }.count
        XCTAssertEqual(
            brewInstallNodeCount, 1,
            "shared prerequisite `brew install node` must run exactly once across concurrent installs; "
                + "ran \(brewInstallNodeCount) times. history=\(history)"
        )
    }

    // ====================================================================
    // MARK: - Bug 4. `.disabled` resolution surfaces a clear error
    // ====================================================================
    //
    // The legacy `LSPSettings.confirmationMode(...)` collapses
    // `autoInstallEnabled == false` onto `.prompt(handler: { _ in false })`.
    // Routing that through `LSPInstaller.install(...)` produces
    // `failed(reason: "user declined: <step>")` — misleading because no
    // user ever saw a prompt; the master switch was simply off.
    //
    // Post-fix expectation: the installer (either directly, or via a new
    // routing path) reports `"auto-install disabled"` as the failure reason
    // so MCP callers and the UI can route on a meaningful message.

    @available(*, deprecated, message: "intentional: exercises the legacy confirmationMode(...) bridge")
    func test_install_whenAutoInstallDisabled_failsWithExplicitDisabledReason() async {
        // Isolate UserDefaults state.
        LSPSettings.resetToDefaults()
        defer { LSPSettings.resetToDefaults() }

        LSPSettings.autoInstallEnabled = false

        let registry = makeRegistry()
        let runner = MockCommandRunner()
        // npm available so the only thing that could halt the install is
        // the disabled master switch, not a missing prerequisite.
        await runner.setLocateResult("npm", url: bin("npm"))

        let installer = LSPInstaller(registry: registry, runner: runner)

        // Production wiring: LSPService + MCPLSPBridge both go through
        // `LSPSettings.confirmationMode(confirmationHandler:)`.
        let mode = LSPSettings.confirmationMode(confirmationHandler: { _ in true })
        let status = await installer.install(
            languageId: "typescript",
            approvePrerequisites: false,
            confirmationMode: mode
        )

        switch status {
        case .failed(let reason):
            let lowered = reason.lowercased()
            XCTAssertTrue(
                lowered.contains("auto-install disabled"),
                "expected reason to contain 'auto-install disabled' when the master switch is off; "
                    + "got '\(reason)'"
            )
            XCTAssertFalse(
                lowered.contains("user declined"),
                "must not surface 'user declined' when no user actually saw a prompt; got '\(reason)'"
            )
        default:
            XCTFail("expected .failed when auto-install is disabled; got \(status)")
        }

        // Belt-and-braces: confirm no install command was executed.
        let history = await runner.history()
        XCTAssertTrue(
            history.allSatisfy { record in
                !(record.executable == "npm" && record.arguments.first == "install")
            },
            "no npm install should have run when auto-install is disabled; got \(history)"
        )
    }
}
