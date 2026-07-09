// CockpitApprovalE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the Cockpit MCP tool surface: pane_list /
// pane_split / tab_create (P4, ungated) and pane_run (P5, gated by a
// REAL, clickable approval banner) driven through the real running
// app-under-test's real MCP server, exactly the path an MCP-connected
// coding agent uses. P1-P5 are already committed (Green) -- this suite
// is integration coverage for already-implemented behavior, not a RED
// stub: it is expected to PASS when correctly written.
//
// ISOLATION CAVEAT (accepted, not a bug -- identical reasoning to
// CommandLogE2ETests.swift's own header, restated here since this
// suite depends on the exact same fixed path): this suite does NOT
// override `HOME` on the app-under-test's launch environment.
// `PaneCLIExec`'s own header establishes (field-verified) that a
// pane's shell does NOT inherit Calyx.app's own HOME override at all --
// ghostty execs every surface via `login -flp <system-username> ...`,
// which resets `$HOME` against the REAL system user regardless of what
// the app process's own environment says. This suite's pane-side
// scripts read `~/Library/Application Support/Calyx/agent-endpoint.json`
// (the SAME fixed, no-override-possible path CommandLogE2ETests'
// query script reads), so overriding HOME on the app process would
// only make the APP write that file to an isolated path while every
// pane-side script keeps reading the REAL system path -- a strictly
// WORSE mismatch. `CALYX_UITEST_SESSION_DIR` / `CALYX_UITEST_DEFAULTS_SUITE`
// (the base class's own isolation) still cover window/tab-session
// state and every UserDefaults-backed setting -- including
// CockpitSettings.autoApproveEnabled, which is why this suite can rely
// on a truly fresh "auto-approve OFF" default per run (see
// CockpitSettings.swift / SettingsStore.swift: `_testStore` is nil in
// this out-of-process app-under-test, so resolution falls to
// `uiTestSuite`, keyed by `CALYX_UITEST_DEFAULTS_SUITE`, never
// `.standard`).
//
// ENVIRONMENTAL PRECONDITION (outside this test's control, same as
// CommandLogE2ETests.swift's own): `IPCConfigManager.enableIPC`'s
// `anySucceeded` gate requires at least one of `~/.claude`, `~/.codex`,
// `~/.config/opencode` to exist on the machine running this suite.
//
// QUERY MECHANISM (PaneCLIExec pattern, mirrors CommandLogE2ETests.swift's
// own header on why: the CalyxUITests runner is itself App-Sandboxed and
// cannot open a new outbound connection, so all `/mcp` traffic must go
// through a real, unsandboxed pane process). Two call shapes are needed
// here, unlike CommandLogE2ETests' single one:
//
// - UNGATED tools (pane_list/pane_split/tab_create) return immediately,
//   so `toolCallSync` reuses CommandLogE2ETests' exact shape: write a
//   base64-encoded python3 script to /tmp via `paneExec`, wait for its
//   one-line JSON stdout.
// - The GATED tool (pane_run) BLOCKS the pane-side curl call until a
//   human answers the approval banner (or the bridge's own ~55s
//   internal timeout fires) -- `paneExec`'s own wait-for-output-file
//   loop cannot be used to ISSUE it (this test needs control back
//   immediately, to go click the banner). `toolCallBackgrounded`
//   instead pastes a command that backgrounds the same python3 script
//   inside a detached subshell (`(... &); disown` idiom, see
//   `toolCallBackgrounded`'s own doc comment) via `panePasteAndReturn`
//   (fire-and-forget, does not wait), and this test separately polls
//   the script's own /tmp output file with `waitForFileContent` (a
//   near-duplicate of `paneExec`'s own tail-polling loop, kept local
//   rather than promoted into `PaneCLIExec` -- same "kept as a
//   near-duplicate" rationale that file's own header already states
//   for its relationship to `BrowserScriptingUITests.terminalExec`)
//   IN BETWEEN clicking the banner's button and asserting the result,
//   so the XCUITest driver is free to interact with the banner while
//   the pane-side curl is still blocked waiting on it.
//

import XCTest

final class CockpitApprovalE2ETests: CalyxUITestCase {

    // MARK: - Accessibility identifiers

    /// Literal mirrors of `AccessibilityID.ApprovalBanner.*`
    /// (Calyx/Helpers/AccessibilityID.swift) -- the `CalyxUITests`
    /// target drives the app-under-test as a separate OS process via
    /// `XCUIApplication`, with no `@testable import Calyx` linkage, so
    /// that enum isn't visible here. Every other E2E suite in this
    /// directory (e.g. `CommandLogE2ETests.enableAIAgentIPCViaCommandPalette`'s
    /// own `"calyx.commandPalette.searchField"`) already hardcodes the
    /// same identifiers as string literals for the same reason; named
    /// here (rather than inlined at each call site) purely because this
    /// suite references them from more than one place.
    private static let approvalBannerAllowButtonID = "calyx.approvalBanner.allowButton"
    private static let approvalBannerDenyButtonID = "calyx.approvalBanner.denyButton"
    private static let approvalBannerPayloadID = "calyx.approvalBanner.payload"

    // MARK: - Test

    func test_cockpitTools_endToEnd() throws {
        var counter = 0

        enableAIAgentIPCViaCommandPalette()

        // MARK: 1. Resolve this pane's own surface_id

        let surfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertNotEqual(surfaceID, "(no output)", "could not read $CALYX_SURFACE_ID from the pane")
        XCTAssertFalse(surfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for every ghostty-spawned pane")

        // MARK: 2. pane_list -- this window's own pane is present, with a cwd, snake_case keys

        let firstList = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)
        let firstPanes = try XCTUnwrap(firstList["panes"] as? [[String: Any]], "pane_list must return a panes array")
        let ownPaneBeforeSplit = try XCTUnwrap(
            firstPanes.first { ($0["surface_id"] as? String) == surfaceID },
            "pane_list must include this window's own pane (surface_id \(surfaceID)) -- got: \(firstPanes)"
        )
        for key in ["surface_id", "window_id", "group_name", "tab_id", "tab_title", "is_focused"] {
            XCTAssertNotNil(ownPaneBeforeSplit[key], "pane_list entry must carry the snake_case key \"\(key)\"")
        }
        XCTAssertNotNil(ownPaneBeforeSplit["cwd"] as? String,
                        "the sole pane in a single-pane tab must report a cwd (falls back to the tab's own pwd)")
        let paneCountBeforeSplit = firstPanes.count

        // MARK: 3. pane_run, unregistered pane -> requires approval (auto-approve defaults OFF) -> Allow -> executes

        let allowOutFile = "/tmp/calyx-e2e-cockpit-run-allow-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo COCKPIT_MARKER_ALLOW\", \"await\": false}",
            outFile: allowOutFile, counter: &counter
        )

        let allowButton = app.buttons[Self.approvalBannerAllowButtonID]
        XCTAssertTrue(waitFor(allowButton, timeout: 15), "the approval banner's Allow button never appeared")

        let payloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(payloadText, timeout: 5), "the approval banner's payload text never appeared")
        XCTAssertTrue(elementText(payloadText).contains("COCKPIT_MARKER_ALLOW"),
                     "the banner must display the exact pending command -- got: \(elementText(payloadText))")

        allowButton.click()

        let allowResultText = waitForFileContent(atPath: allowOutFile)
        XCTAssertNotEqual(allowResultText, "(no output)", "the backgrounded pane_run (Allow) curl produced no output")
        let allowResult = try parseJSONObject(allowResultText, context: "pane_run Allow result")
        XCTAssertEqual(allowResult["status"] as? String, "sent",
                       "Allow must execute the command and report status \"sent\" -- got: \(allowResultText)")

        // Round-trips through the REAL shell integration -- proves the
        // command actually ran in the pane, not just that the bridge
        // claimed success.
        let allowMarkerRecord = try waitForTrackedCommand(
            containing: "COCKPIT_MARKER_ALLOW", surfaceID: surfaceID, counter: &counter
        )
        XCTAssertEqual(allowMarkerRecord["state"] as? String, "finished",
                       "the allowed marker command must finish and be tracked by the real shell integration")

        // MARK: 4. pane_run, second request -> Deny -> never executes

        let denyOutFile = "/tmp/calyx-e2e-cockpit-run-deny-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo COCKPIT_MARKER_DENY\", \"await\": false}",
            outFile: denyOutFile, counter: &counter
        )

        let denyButton = app.buttons[Self.approvalBannerDenyButtonID]
        XCTAssertTrue(waitFor(denyButton, timeout: 15), "the approval banner's Deny button never appeared for the second request")

        let denyPayloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(denyPayloadText, timeout: 5))
        XCTAssertTrue(elementText(denyPayloadText).contains("COCKPIT_MARKER_DENY"),
                     "the banner must now display the SECOND pending command -- got: \(elementText(denyPayloadText))")

        denyButton.click()

        let denyResultText = waitForFileContent(atPath: denyOutFile)
        XCTAssertNotEqual(denyResultText, "(no output)", "the backgrounded pane_run (Deny) curl produced no output")
        let denyResult = try parseJSONObject(denyResultText, context: "pane_run Deny result")
        XCTAssertEqual(denyResult["status"] as? String, "denied",
                       "Deny must never execute -- must report status \"denied\" -- got: \(denyResultText)")

        // Bounded absence check: the denied marker must NEVER show up as
        // a tracked command (polls a short, fixed window rather than
        // waiting out a full timeout budget for something that must NOT
        // appear).
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 1)
            let list = toolCallSync(name: "terminal_list_commands", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\"}", counter: &counter)
            let commands = (list["commands"] as? [[String: Any]]) ?? []
            let found = commands.contains { ($0["command"] as? String)?.contains("COCKPIT_MARKER_DENY") == true }
            XCTAssertFalse(found, "a denied pane_run must never reach the real shell -- COCKPIT_MARKER_DENY must never be tracked")
        }

        // MARK: 5. pane_split -- one more pane in the same tab

        let splitResult = toolCallSync(
            name: "pane_split", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"direction\": \"right\"}", counter: &counter
        )
        XCTAssertNotNil(splitResult["surface_id"] as? String, "pane_split must return the newly created pane's surface_id")
        XCTAssertEqual(splitResult["direction"] as? String, "right")

        let secondList = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)
        let secondPanes = try XCTUnwrap(secondList["panes"] as? [[String: Any]])
        XCTAssertEqual(secondPanes.count, paneCountBeforeSplit + 1,
                       "pane_split must add exactly one pane to the same tab")

        // MARK: 6. tab_create -- a pane appears in the new group

        let newGroupName = "E2E-COCKPIT"
        let tabCreateResult = toolCallSync(
            name: "tab_create", argumentsJSON: "{\"group_name\": \"\(newGroupName)\"}", counter: &counter
        )
        XCTAssertEqual(tabCreateResult["group_name"] as? String, newGroupName)

        let thirdList = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)
        let thirdPanes = try XCTUnwrap(thirdList["panes"] as? [[String: Any]])
        XCTAssertTrue(
            thirdPanes.contains { ($0["group_name"] as? String) == newGroupName },
            "pane_list must reflect a pane in the newly created group \"\(newGroupName)\" -- got: \(thirdPanes)"
        )
    }

    // MARK: - Helpers

    /// Opens the Command Palette, executes "Enable AI Agent IPC", and
    /// dismisses the resulting `NSAlert.runModal()` confirmation --
    /// identical to `CommandLogE2ETests`'s own helper of the same name
    /// (kept as a near-duplicate rather than shared, matching this
    /// suite's other files' own precedent).
    private func enableAIAgentIPCViaCommandPalette() {
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette did not appear")

        searchField.typeText("Enable AI Agent IPC")
        searchField.typeKey(.enter, modifierFlags: [])

        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10),
                     "the IPC enable/error alert (CalyxWindowController.showIPCAlert) did not appear")
        alert.buttons["OK"].click()
    }

    private func parseJSONObject(_ text: String, context: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(context) was not a valid JSON object: \(text)")
            return [:]
        }
        return object
    }

    /// Field-verified fix (this suite's own first real run): a SwiftUI
    /// `Text(...).accessibilityIdentifier(...)` INSIDE a `ScrollView`
    /// (`ApprovalBannerView.swift`'s payload text) does not expose its
    /// rendered content via `.label` -- `.label` came back empty even
    /// though the element existed and the text was genuinely on screen.
    /// Joins `.label` and `.value as? String` (whichever is non-empty,
    /// or both concatenated if both are) so a content assertion is
    /// robust to either surfacing convention, without needing to know
    /// in advance which one a given SwiftUI container/modifier
    /// combination picks.
    private func elementText(_ element: XCUIElement) -> String {
        let label = element.label
        let value = element.value as? String ?? ""
        if label.isEmpty { return value }
        if value.isEmpty || value == label { return label }
        return label + " " + value
    }

    /// Synchronous tools/call: writes `toolCallScript`'s output to /tmp
    /// via `paneExec` and waits for it inline, same shape as
    /// `CommandLogE2ETests.queryScript`. Only safe for a tool that
    /// returns promptly (every P4 Cockpit tool, and any already-decided
    /// P5 poll) -- never for an UNANSWERED gated call, which would block
    /// the pane's curl (and therefore this call) for up to the bridge's
    /// own ~55s internal approval timeout.
    private func toolCallSync(name: String, argumentsJSON: String, counter: inout Int, timeoutAttempts: Int = 20) -> [String: Any] {
        let script = toolCallScript(name: name, argumentsJSON: argumentsJSON, maxTimeSeconds: 10)
        let encoded = Data(script.utf8).base64EncodedString()
        counter += 1
        let scriptPath = "/tmp/calyx-e2e-cockpit-sync-\(counter).py"
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && python3 \(scriptPath)"
        let resultText = paneExec(command, counter: &counter, timeoutAttempts: timeoutAttempts)

        guard resultText != "(no output)",
              let data = resultText.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(name) pane-side query produced no/invalid JSON output: \(resultText)")
            return [:]
        }
        if let scriptError = result["error"] as? String {
            XCTFail("\(name) pane-side script reported an error: \(scriptError)")
            return [:]
        }
        return result
    }

    /// Backgrounded tools/call: pastes a command that runs
    /// `toolCallScript`'s python3 script inside a detached subshell
    /// (`(cmd &); disown` -- backgrounds it, then disowns it from the
    /// interactive shell's own job control so no "[1]+ Done" job-control
    /// notification is later printed into the pane's scrollback) via
    /// `panePasteAndReturn`, which does not wait for any output --
    /// control returns to this test immediately, while the pane-side
    /// curl call is left running (and, for a gated tool, blocked on the
    /// approval banner this test is about to go answer). The script's
    /// own stdout goes to `outFile`; poll it separately with
    /// `waitForFileContent` once the banner has been answered.
    private func toolCallBackgrounded(name: String, argumentsJSON: String, outFile: String, counter: inout Int) {
        try? FileManager.default.removeItem(atPath: outFile)
        // >55s: comfortably longer than the bridge's own ~55s internal
        // approval-wait timeout, so THIS curl call is never the one that
        // cuts the round trip short -- the approval flow's own
        // .expired/.allowed/.denied resolution decides the outcome, not
        // an impatient client socket.
        let script = toolCallScript(name: name, argumentsJSON: argumentsJSON, maxTimeSeconds: 65)
        let encoded = Data(script.utf8).base64EncodedString()
        counter += 1
        let scriptPath = "/tmp/calyx-e2e-cockpit-bg-\(counter).py"
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && " +
            "(python3 \(scriptPath) > \(outFile) 2>&1 &); disown"
        panePasteAndReturn(command)
    }

    /// Near-duplicate of `PaneCLIExec.paneExec`'s own tail-polling loop
    /// (see this file's header for why it is not shared): polls `path`
    /// until it has non-empty content or a bounded number of attempts
    /// elapse, returning the trimmed content (or "(no output)").
    /// `timeoutAttempts: 130` at the default 0.5s poll interval budgets
    /// ~65s -- matching `toolCallBackgrounded`'s own `maxTimeSeconds`
    /// ceiling for a gated call's curl, plus headroom for this test's
    /// own (expected sub-second) banner click.
    private func waitForFileContent(atPath path: String, timeoutAttempts: Int = 130) -> String {
        for _ in 0..<timeoutAttempts {
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: path),
               let content = try? String(contentsOfFile: path, encoding: .utf8),
               !content.isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no output)"
    }

    /// Polls `terminal_list_commands` (a synchronous, ungated tool) for
    /// up to ~20s for a command whose own text contains `marker`,
    /// returning its record once found.
    private func waitForTrackedCommand(containing marker: String, surfaceID: String, counter: inout Int) throws -> [String: Any] {
        for _ in 0..<20 {
            let list = toolCallSync(name: "terminal_list_commands", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\"}", counter: &counter)
            let commands = (list["commands"] as? [[String: Any]]) ?? []
            if let found = commands.first(where: { ($0["command"] as? String)?.contains(marker) == true }) {
                return found
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("no tracked command containing \"\(marker)\" appeared for surface \(surfaceID) within the timeout budget")
        return [:]
    }

    /// Builds a python3 script that POSTs a single `tools/call` to the
    /// real MCP server (endpoint read from the real, fixed
    /// `agent-endpoint.json` path -- see this file's header) and prints
    /// the tool's own (already-decoded) JSON result text on one line, or
    /// `{"error": ...}` on any failure -- mirrors
    /// `CommandLogE2ETests.queryScript`'s `call_tool` helper exactly,
    /// generalized to an arbitrary tool name/arguments pair instead of a
    /// fixed sequence of terminal_* calls. `argumentsJSON` (already-valid
    /// JSON text this file's own callers build from simple,
    /// quote-free values -- UUIDs, "right"/"down", plain marker/group
    /// text) is embedded as a Python triple-single-quoted string literal
    /// and re-parsed with `json.loads` inside the script, rather than
    /// shell-escaped as a `sys.argv` element -- this sidesteps shell
    /// quoting entirely, at the cost of requiring `argumentsJSON` to
    /// never itself contain a `'''` sequence (true for every call site
    /// in this file).
    private func toolCallScript(name: String, argumentsJSON: String, maxTimeSeconds: Int) -> String {
        """
        import json
        import os
        import subprocess

        def main():
            endpoint_path = os.path.expanduser(
                "~/Library/Application Support/Calyx/agent-endpoint.json"
            )
            with open(endpoint_path) as f:
                endpoint = json.load(f)
            port = endpoint["port"]
            token = endpoint["token"]

            arguments = json.loads('''\(argumentsJSON)''')
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": "\(name)", "arguments": arguments},
            })
            proc = subprocess.run(
                [
                    "curl", "-s", "--max-time", "\(maxTimeSeconds)",
                    "-X", "POST",
                    "-H", "Authorization: Bearer " + token,
                    "-H", "Content-Type: application/json",
                    "--data-binary", body,
                    "http://127.0.0.1:%d/mcp" % port,
                ],
                capture_output=True, text=True,
            )
            envelope = json.loads(proc.stdout)
            text = envelope["result"]["content"][0]["text"]
            print(text)

        try:
            main()
        except Exception as e:
            print(json.dumps({"error": repr(e)}))
        """
    }
}
