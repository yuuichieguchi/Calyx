//
//  LSPInstallerShellDetectionBugSpecTests.swift
//  CalyxTests
//
//  RED-phase regression test for a metacharacter-coverage bug in
//  `LSPInstaller.commandNeedsShell(_:)` (see
//  Calyx/Features/LSP/LSPInstaller.swift around lines 623–628).
//
//  Bug
//  ---
//  `commandNeedsShell` consults a hardcoded set of shell metacharacters:
//      "|", "&", ";", "<", ">", "(", ")", "$", "`", "'", "\"", "*", "?", "\\"
//  Missing from that set:
//      - `{` / `}`  — brace expansion          (e.g. `foo/{bar,baz}`)
//      - `[` / `]`  — bracketed glob char class (e.g. `ls [abc]`)
//      - `!`        — history expansion        (e.g. `rm !history`)
//      - `=`        — variable assignment      (e.g. `VAR=value cmd`)
//  A user-override registry whose `installation.command` uses any of
//  those shell features routes through the bare-`exec` path because
//  `commandNeedsShell` returns `false`. The runner then sees the
//  unexpanded token (e.g. literal `foo/{bar,baz}`) as the package name,
//  which is wrong.
//
//  Fix spec
//  --------
//  Extend the metacharacter set, OR invert the predicate ("recognise pure
//  alnum + `-` `/` `.` `_` ` ` as safe; anything else needs the shell").
//
//  Test-access design
//  ------------------
//  `commandNeedsShell` is `private static` inside `LSPInstaller`, so
//  `@testable import Calyx` does NOT expose it (only `internal` symbols
//  are surfaced). We therefore drive the public `install(...)` path with
//  a custom `LSPServerRegistry` whose `installation.command` strings
//  carry each metacharacter under test, and inspect
//  `MockCommandRunner.history()` to confirm the installer routed each
//  command through `/bin/sh -c "<command>"` rather than the bare-exec
//  path. This keeps the assertion robust against changes to the
//  predicate's name / location.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPInstallerShellDetectionBugSpecTests: XCTestCase {

    // ====================================================================
    // MARK: - Helpers
    // ====================================================================

    /// Success `CommandResult` shortcut.
    private func ok(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(exitCode: 0, stdout: stdout, stderr: stderr)
    }

    /// Build a one-entry `LSPServerRegistry` whose only language uses the
    /// supplied install command. No prerequisites, `safeToAutoRun = true`,
    /// `.which` probe pointed at a binary we will leave unresolved so the
    /// install path actually executes the command.
    private func makeRegistry(
        languageId: String,
        installCommand: String
    ) -> LSPServerRegistry {
        let entry = LSPServerDefinition(
            languageId: languageId,
            displayName: "Test \(languageId)",
            executable: "test-\(languageId)-server",
            arguments: [],
            versionArguments: nil,
            fileExtensions: [".test"],
            workspaceMarkers: [],
            installation: LSPInstallationSpec(
                command: installCommand,
                prerequisites: [],
                safeToAutoRun: true
            ),
            defaultInitializationOptions: nil
        )
        return LSPServerRegistry(entries: [entry])
    }

    /// Run the install path against a runner that pre-enqueues success
    /// under BOTH the post-fix shell executable (`/bin/sh`) and the
    /// pre-fix bare-exec head, so the resulting `history()` snapshot is
    /// driven by the installer's routing decision, not by a runner-queue
    /// exhaustion failure.
    private func runInstall(
        languageId: String,
        installCommand: String,
        bareExecHead: String
    ) async -> [(executable: String, arguments: [String])] {
        // UserDefaults isolation — `LSPInstaller.install(...)` short-
        // circuits when `LSPSettings.autoInstallEnabled` is `false`.
        LSPSettings.resetToDefaults()
        LSPSettings.autoInstallEnabled = true

        let registry = makeRegistry(
            languageId: languageId,
            installCommand: installCommand
        )
        let runner = MockCommandRunner()

        await runner.enqueueRunResult("/bin/sh", result: .success(ok()))
        await runner.enqueueRunResult(bareExecHead, result: .success(ok()))

        let installer = LSPInstaller(registry: registry, runner: runner)
        _ = await installer.install(
            languageId: languageId,
            approvePrerequisites: false,
            confirmationMode: .silent
        )

        defer { LSPSettings.resetToDefaults() }
        return await runner.history()
    }

    /// True iff the recorded history contains a `/bin/sh -c <command>`
    /// invocation matching the original install command verbatim.
    private func invokedViaShell(
        history: [(executable: String, arguments: [String])],
        command: String
    ) -> Bool {
        history.contains { record in
            record.executable == "/bin/sh"
                && record.arguments.count >= 2
                && record.arguments[0] == "-c"
                && record.arguments[1] == command
        }
    }

    /// True iff the recorded history contains an invocation whose
    /// `executable` equals `bareExecHead` — i.e. the pre-fix bare-exec
    /// path was taken for a command that ought to go through `/bin/sh`.
    private func invokedAsBareExec(
        history: [(executable: String, arguments: [String])],
        bareExecHead: String
    ) -> Bool {
        history.contains { record in
            record.executable == bareExecHead
        }
    }

    // ====================================================================
    // MARK: - The bug
    // ====================================================================

    func test_commandNeedsShell_detectsBraceExpansion_and_charClass() async {

        // ---- Case 1: brace expansion `{,}` ----
        do {
            let cmd = "brew install foo/{bar,baz}"
            let history = await runInstall(
                languageId: "brace-lang",
                installCommand: cmd,
                bareExecHead: "brew"
            )
            XCTAssertTrue(
                invokedViaShell(history: history, command: cmd),
                "brace expansion `{bar,baz}` must route through /bin/sh -c; "
                    + "got history=\(history)"
            )
            XCTAssertFalse(
                invokedAsBareExec(history: history, bareExecHead: "brew"),
                "brace-expansion command must NOT be bare-exec'd as `brew` "
                    + "(would pass `foo/{bar,baz}` as a literal package name); "
                    + "got history=\(history)"
            )
        }

        // ---- Case 2: bracketed glob char class `[abc]` ----
        do {
            let cmd = "ls [abc]"
            let history = await runInstall(
                languageId: "charclass-lang",
                installCommand: cmd,
                bareExecHead: "ls"
            )
            XCTAssertTrue(
                invokedViaShell(history: history, command: cmd),
                "glob char class `[abc]` must route through /bin/sh -c; "
                    + "got history=\(history)"
            )
            XCTAssertFalse(
                invokedAsBareExec(history: history, bareExecHead: "ls"),
                "char-class command must NOT be bare-exec'd as `ls`; "
                    + "got history=\(history)"
            )
        }

        // ---- Case 3: history expansion `!` ----
        do {
            let cmd = "rm -rf !history"
            let history = await runInstall(
                languageId: "bang-lang",
                installCommand: cmd,
                bareExecHead: "rm"
            )
            XCTAssertTrue(
                invokedViaShell(history: history, command: cmd),
                "history expansion `!history` must route through /bin/sh -c; "
                    + "got history=\(history)"
            )
            XCTAssertFalse(
                invokedAsBareExec(history: history, bareExecHead: "rm"),
                "bang-expansion command must NOT be bare-exec'd as `rm`; "
                    + "got history=\(history)"
            )
        }

        // ---- Case 4: leading variable assignment `VAR=value cmd` ----
        do {
            let cmd = "VAR=value command"
            let history = await runInstall(
                languageId: "var-lang",
                installCommand: cmd,
                bareExecHead: "VAR=value"
            )
            XCTAssertTrue(
                invokedViaShell(history: history, command: cmd),
                "leading `VAR=value` assignment must route through /bin/sh -c; "
                    + "got history=\(history)"
            )
            XCTAssertFalse(
                invokedAsBareExec(history: history, bareExecHead: "VAR=value"),
                "var-assignment command must NOT be bare-exec'd with `VAR=value` "
                    + "as the executable name; got history=\(history)"
            )
        }

        // ---- Case 5 (sanity-positive): plain alnum + `-` + ` ` is safe ----
        do {
            let cmd = "npm install -g pyright"
            let history = await runInstall(
                languageId: "plain-lang",
                installCommand: cmd,
                bareExecHead: "npm"
            )
            // A pure alnum / dash / space command must NOT be wrapped in
            // /bin/sh -c — it should be exec'd directly as `npm` with the
            // remaining tokens as argv. This catches an over-eager fix
            // that wraps everything in a shell.
            XCTAssertFalse(
                invokedViaShell(history: history, command: cmd),
                "plain `npm install -g pyright` must NOT route through /bin/sh -c; "
                    + "got history=\(history)"
            )
            let bareExecMatches = history.contains { record in
                record.executable == "npm"
                    && record.arguments == ["install", "-g", "pyright"]
            }
            XCTAssertTrue(
                bareExecMatches,
                "plain `npm install -g pyright` must be bare-exec'd as "
                    + "`npm install -g pyright`; got history=\(history)"
            )
        }
    }
}
