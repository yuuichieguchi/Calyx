// CockpitAgentHookApprovalE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the notification-style approval panel's
// `.agentHook` and `.agentQuestion` layouts: a CLI agent's own PermissionRequest-
// gated hook call and Claude Code's AskUserQuestion tool, driven through
// `POST /approval-request` on the real running app-under-test's real
// bridge HTTP server -- NOT `/mcp`, and NOT `CockpitApprovalE2ETests`'
// own `toolCallScript`/`toolCallSync`/`toolCallBackgrounded` helpers,
// which target `/mcp`'s `tools/call` JSON-RPC envelope and would not
// exercise `CalyxMCPServer.routeApprovalRequest` at all.
//
// A separate class, NOT a subclass of `CockpitApprovalE2ETests`: XCTest
// runs every inherited test method on a subclass too, so subclassing
// would silently re-run that whole suite's five tests under this
// class's own `agentHookApprovalEnabled` launch argument. Every helper
// this file needs is duplicated here as a file-private near-duplicate
// (same convention `CockpitApprovalE2ETests`'s own header already
// documents for its relationship to `CommandLogE2ETests`/
// `BrowserScriptingUITests`), since `CockpitApprovalE2ETests`'s own
// copies are `private` to that class.
//
// `-calyx.cockpit.agentHookApprovalEnabled YES` -- the same
// NSArgumentDomain launch-argument precedent
// `DemoRecordingScenario.test_demoRecordingScenario()` already
// establishes (raw key verbatim from `CockpitSettings.
// agentHookApprovalEnabledKey`, Calyx/Features/ApprovalInbox/
// CockpitSettings.swift; this target has no `@testable import Calyx`
// linkage) -- is required for `routeApprovalRequest`'s own
// `CockpitSettings.agentHookApprovalEnabled` guard to let ANY of these
// requests reach the inbox at all.
//
// ISOLATION: `additionalLaunchArguments` also carries
// `--calyx-path-root=<scoped temp dir>` plus `-calyx.ipc.enabled YES` --
// identical mechanism to CommandLogE2ETests.swift's own header.
// `CalyxPathRoot.testRoot` scopes every Calyx-owned and agent-owned
// config path beneath the temp dir, and
// `AppDelegate.resyncAgentHooksIfInstalled` runs real launch-time
// activation against it. This suite's own embedded Python scripts read
// `CALYX_ENDPOINT_FILE` (injected by `GhosttySurfaceController` into
// every pane's own environment, scoped to wherever this launch actually
// wrote `agent-endpoint.json`) ahead of the literal, unscoped
// `~/Library/Application Support/Calyx/agent-endpoint.json` fallback --
// see `AgentEndpointFile.swift`/`GhosttySurface.swift`'s own doc
// comments for why a pane's shell (started via `login -flp
// <system-username> ...`, which resets `$HOME` to the real system user
// regardless of `CalyxPathRoot.testRoot`) could not otherwise resolve
// the scoped path at all. `setUp()`'s own `scopedPathRoot` also
// pre-creates `<scopedPathRoot>/.claude`, satisfying
// `IPCConfigManager.enableIPC`'s `anySucceeded` gate.

import XCTest
import AppKit

final class CockpitAgentHookApprovalE2ETests: CalyxUITestCase {

    /// `--calyx-path-root=<this>` (see this file's header): a fresh
    /// per-test temp directory, created lazily on first access so it
    /// exists before `additionalLaunchArguments` is read by
    /// `CalyxUITestCase.setUp()`, ahead of `app.launch()`.
    private lazy var scopedPathRoot: String = {
        let root = NSTemporaryDirectory() + "CalyxUITests-pathroot-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // Satisfies IPCConfigManager.enableIPC's anySucceeded gate (see
        // this file's header) without depending on what CLIs happen to
        // be installed on the machine running this suite.
        try? FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        return root
    }()

    override var additionalLaunchArguments: [String] {
        ["-calyx.cockpit.agentHookApprovalEnabled", "YES", "--calyx-path-root=\(scopedPathRoot)", "-calyx.ipc.enabled", "YES"]
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: scopedPathRoot)
    }

    /// Polls for the scoped `agent-endpoint.json`, mirroring
    /// `CommandLogE2ETests.waitForIPCActivation` exactly (kept as a
    /// near-duplicate -- see this file's header).
    private func waitForIPCActivation(timeout: TimeInterval = 20) {
        let endpointPath = scopedPathRoot + "/Calyx/agent-endpoint.json"
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: endpointPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointPath),
                     "launch-time AI Agent IPC activation never wrote agent-endpoint.json under the scoped root")
    }

    // MARK: - Accessibility identifiers (literal mirrors, see this file's own header)

    private static let allowButtonID = "calyx.approvalBanner.allowButton"
    private static let optionsMenuID = "calyx.approvalBanner.optionsMenu"
    private static let questionTextID = "calyx.approvalBanner.questionText"
    private static let answerButtonID = "calyx.approvalBanner.answerButton"
    private static let otherTextFieldID = "calyx.approvalBanner.otherTextField"
    private static let dismissButtonID = "calyx.approvalBanner.dismissButton"
    private static let containerID = "calyx.approvalBanner.container"

    // MARK: - .agentHook: permission_suggestions present

    /// A claude-code Bash call carrying one `setMode` suggestion: the
    /// primary button reads "Yes" (`allowButton`), the Options menu
    /// lists that suggestion's own label ("Yes, and switch to
    /// acceptEdits mode" -- `AgentPermissionOffer.label(for:)`'s
    /// `setMode` case never appends a scope suffix) and "No", and
    /// carries NO "Always Allow ... in This Pane" item (`AgentHookOffers.
    /// cliOwnsPersistence` is true whenever `permissionUpdates` is
    /// non-empty). Choosing "No" must produce a `behavior: "deny"`
    /// response.
    func test_agentHookWithSuggestions_optionsMenuListsOfferAndNo_denyProducesDenyBehavior() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = try resolveFocusedSurfaceID(counter: &counter)

        let bodyJSON = """
        {"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo HOOK_MARKER_ONE"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}
        """
        let outFile = "/tmp/calyx-e2e-agenthook-suggestions-\(ProcessInfo.processInfo.processIdentifier).json"
        postApprovalRequestBackgrounded(bodyJSON: bodyJSON, surfaceID: surfaceID, outFile: outFile, counter: &counter)

        let allowButton = app.buttons[Self.allowButtonID]
        XCTAssertTrue(waitFor(allowButton, timeout: 15), "the primary button never appeared for the agentHook request")
        XCTAssertTrue(elementText(allowButton).contains("Yes"),
                     "an .agentHook primary button must read \"Yes\", got \"\(elementText(allowButton))\"")

        let optionsMenu = app.descendants(matching: .any).matching(identifier: Self.optionsMenuID).firstMatch
        XCTAssertTrue(waitFor(optionsMenu, timeout: 5), "the Options menu never appeared")
        optionsMenu.click()

        let offerItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Yes, and switch to acceptEdits mode")).firstMatch
        XCTAssertTrue(waitFor(offerItem, timeout: 10), "the Options menu never listed the CLI's own permission_suggestions offer by its exact label")

        let noItem = app.menuItems.matching(NSPredicate(format: "title == %@", "No")).firstMatch
        XCTAssertTrue(noItem.exists, "the Options menu must list \"No\"")

        let alwaysAllowItem = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", "Always Allow")).firstMatch
        XCTAssertFalse(alwaysAllowItem.exists,
                       "no Calyx-side \"Always Allow ... in This Pane\" item may appear when the CLI already sent its own permission_suggestions")

        noItem.click()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded /approval-request curl produced no output")
        let decision = try decodedDecision(resultText, context: "agentHook suggestions No result")
        XCTAssertEqual(decision["behavior"] as? String, "deny",
                       "choosing \"No\" must produce hookSpecificOutput.decision.behavior == \"deny\" -- got: \(resultText)")
    }

    // MARK: - .agentHook: no permission_suggestions

    /// The same Bash call with NO `permission_suggestions`: the Options
    /// menu must carry Calyx's own pane-scoped "Always Allow Bash in
    /// This Pane" item instead (`AgentHookOffers.cliOwnsPersistence` is
    /// false when `permissionUpdates` is empty). Choosing the primary
    /// "Yes" button must produce a `behavior: "allow"` response.
    func test_agentHookWithoutSuggestions_optionsMenuListsAlwaysAllow_yesProducesAllowBehavior() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = try resolveFocusedSurfaceID(counter: &counter)

        let bodyJSON = """
        {"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo HOOK_MARKER_TWO"}}
        """
        let outFile = "/tmp/calyx-e2e-agenthook-nosuggestions-\(ProcessInfo.processInfo.processIdentifier).json"
        postApprovalRequestBackgrounded(bodyJSON: bodyJSON, surfaceID: surfaceID, outFile: outFile, counter: &counter)

        let allowButton = app.buttons[Self.allowButtonID]
        XCTAssertTrue(waitFor(allowButton, timeout: 15), "the primary button never appeared for the agentHook request")

        let optionsMenu = app.descendants(matching: .any).matching(identifier: Self.optionsMenuID).firstMatch
        XCTAssertTrue(waitFor(optionsMenu, timeout: 5), "the Options menu never appeared")
        optionsMenu.click()

        let alwaysAllowItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Always Allow Bash in This Pane")).firstMatch
        XCTAssertTrue(waitFor(alwaysAllowItem, timeout: 10),
                     "the Options menu must list Calyx's own pane-scoped Always-Allow item when the CLI sent no permission_suggestions of its own")

        // Dismiss the open menu (its own Escape key) before clicking the
        // primary button, which sits outside the menu's own hit area.
        app.typeKey(.escape, modifierFlags: [])

        allowButton.click()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded /approval-request curl produced no output")
        let decision = try decodedDecision(resultText, context: "agentHook no-suggestions Yes result")
        XCTAssertEqual(decision["behavior"] as? String, "allow",
                       "choosing the primary \"Yes\" button must produce hookSpecificOutput.decision.behavior == \"allow\" -- got: \(resultText)")
    }

    // MARK: - .agentQuestion: choosing a listed option

    /// A single-question, single-select AskUserQuestion call: the
    /// question text renders via `questionText`, no `answerButton`
    /// exists (a single-select listed-option click confirms
    /// immediately, no confirm step needed), and the Options menu lists
    /// each option plus "Other…" and "Chat about this". Choosing "Blue"
    /// must echo `answers["Pick a color"] == "Blue"` into the response.
    func test_agentQuestion_chooseListedOption_answersEchoesChosenLabel() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = try resolveFocusedSurfaceID(counter: &counter)

        let bodyJSON = """
        {"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick a color","header":"Color","options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}],"multiSelect":false}]}}
        """
        let outFile = "/tmp/calyx-e2e-agentquestion-option-\(ProcessInfo.processInfo.processIdentifier).json"
        postApprovalRequestBackgrounded(bodyJSON: bodyJSON, surfaceID: surfaceID, outFile: outFile, counter: &counter)

        let questionText = app.staticTexts[Self.questionTextID]
        XCTAssertTrue(waitFor(questionText, timeout: 15), "the question text never appeared")
        XCTAssertTrue(elementText(questionText).contains("Pick a color"),
                     "the question text must read \"Pick a color\" -- got: \(elementText(questionText))")

        XCTAssertFalse(app.buttons[Self.answerButtonID].exists,
                       "a single-select question with no free-text field showing must render no answerButton -- clicking a listed option confirms immediately")

        let optionsMenu = app.descendants(matching: .any).matching(identifier: Self.optionsMenuID).firstMatch
        XCTAssertTrue(waitFor(optionsMenu, timeout: 5), "the Options menu never appeared")
        optionsMenu.click()

        let redItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Red")).firstMatch
        let blueItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Blue")).firstMatch
        let otherItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Other…")).firstMatch
        let chatItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Chat about this")).firstMatch
        XCTAssertTrue(waitFor(redItem, timeout: 10), "the Options menu never listed the \"Red\" option")
        XCTAssertTrue(blueItem.exists, "the Options menu must list the \"Blue\" option")
        XCTAssertTrue(otherItem.exists, "the Options menu must list \"Other…\"")
        XCTAssertTrue(chatItem.exists, "the Options menu must list \"Chat about this\"")

        blueItem.click()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded /approval-request curl produced no output")
        let decision = try decodedDecision(resultText, context: "agentQuestion option result")
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any], "updatedInput must be an object -- got: \(resultText)")
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: Any], "updatedInput.answers must be an object -- got: \(resultText)")
        XCTAssertEqual(answers["Pick a color"] as? String, "Blue",
                       "choosing the \"Blue\" option must echo answers[\"Pick a color\"] == \"Blue\" -- got: \(resultText)")
    }

    // MARK: - .agentQuestion: "Other…" free text

    /// A second AskUserQuestion request answered via "Other…": choosing
    /// it reveals `otherTextField`; typing free text and pressing Return
    /// must echo that exact text into `answers["Pick a color"]`.
    func test_agentQuestion_chooseOther_freeTextEchoesIntoAnswers() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = try resolveFocusedSurfaceID(counter: &counter)

        let bodyJSON = """
        {"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick a color","header":"Color","options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}],"multiSelect":false}]}}
        """
        let outFile = "/tmp/calyx-e2e-agentquestion-other-\(ProcessInfo.processInfo.processIdentifier).json"
        postApprovalRequestBackgrounded(bodyJSON: bodyJSON, surfaceID: surfaceID, outFile: outFile, counter: &counter)

        let questionText = app.staticTexts[Self.questionTextID]
        XCTAssertTrue(waitFor(questionText, timeout: 15), "the question text never appeared")

        let optionsMenu = app.descendants(matching: .any).matching(identifier: Self.optionsMenuID).firstMatch
        XCTAssertTrue(waitFor(optionsMenu, timeout: 5), "the Options menu never appeared")
        optionsMenu.click()

        let otherItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Other…")).firstMatch
        XCTAssertTrue(waitFor(otherItem, timeout: 10), "the Options menu never listed \"Other…\"")
        otherItem.click()

        let otherTextField = app.textFields[Self.otherTextFieldID]
        XCTAssertTrue(waitFor(otherTextField, timeout: 5), "choosing \"Other…\" must reveal the otherTextField")

        let answerButton = app.buttons[Self.answerButtonID]
        XCTAssertTrue(waitFor(answerButton, timeout: 5), "choosing \"Other…\" must reveal the answerButton (a confirm step is needed for free text)")

        otherTextField.click()
        otherTextField.typeText("FREE_TEXT_MARKER")
        otherTextField.typeKey(.enter, modifierFlags: [])

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded /approval-request curl produced no output")
        let decision = try decodedDecision(resultText, context: "agentQuestion other result")
        let updatedInput = try XCTUnwrap(decision["updatedInput"] as? [String: Any], "updatedInput must be an object -- got: \(resultText)")
        let answers = try XCTUnwrap(updatedInput["answers"] as? [String: Any], "updatedInput.answers must be an object -- got: \(resultText)")
        XCTAssertEqual(answers["Pick a color"] as? String, "FREE_TEXT_MARKER",
                       "submitting \"Other…\" free text must echo it verbatim into answers[\"Pick a color\"] -- got: \(resultText)")
    }

    // MARK: - .agentHook: dismiss produces an empty PermissionRequest body

    /// Claude Code's PermissionRequest hook has no vocabulary for
    /// "Calyx does not answer this" -- `AgentHookPermissionResponse.body`
    /// returns `nil` for `.dismissed` under claude-code, exactly like
    /// `.expired`, so the curl call backing this hook receives an EMPTY
    /// response body (no `hookSpecificOutput` at all) rather than any
    /// allow/deny decision, and the panel closes.
    ///
    /// An empty body alone is indistinguishable from "curl never
    /// finished" or "the file was never written" -- both a hung curl and
    /// a not-yet-run script also read as empty/absent. `includeExitMarker`
    /// appends `CURL_EXIT_<code>` after the response body specifically so
    /// this test can assert on the completed, empty-body case: the file
    /// must read EXACTLY `CURL_EXIT_0`, proving curl actually finished
    /// with a 0-byte body rather than merely not having produced output
    /// yet.
    func test_agentHook_dismiss_producesEmptyResponseBody_removesBanner() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = try resolveFocusedSurfaceID(counter: &counter)

        let bodyJSON = """
        {"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo DISMISS_HOOK_MARKER"}}
        """
        let outFile = "/tmp/calyx-e2e-agenthook-dismiss-\(ProcessInfo.processInfo.processIdentifier).json"
        postApprovalRequestBackgrounded(
            bodyJSON: bodyJSON, surfaceID: surfaceID, outFile: outFile, counter: &counter, includeExitMarker: true
        )

        let container = app.descendants(matching: .any).matching(identifier: Self.containerID).firstMatch
        XCTAssertTrue(waitFor(container, timeout: 15), "the approval banner never appeared for the agentHook request")

        let dismissButton = app.buttons[Self.dismissButtonID]
        XCTAssertTrue(waitFor(dismissButton, timeout: 5), "the dismiss button never appeared in the accessibility tree")

        // The dismiss button is unpainted (`.clear`) until the glass
        // sheet is hovered; `ApprovalPanelWindow` is non-opaque, so a
        // click over unpainted pixels reaches the window behind it
        // instead of this button. Hovering the allow button (inside the
        // sheet) first paints the × in.
        let allowButton = app.buttons[Self.allowButtonID]
        XCTAssertTrue(waitFor(allowButton, timeout: 5), "the allow button never appeared in the accessibility tree")
        allowButton.hover()
        dismissButton.click()

        waitForNonExistence(container, timeout: 5)

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertEqual(resultText, "CURL_EXIT_0",
                       "dismissing a claude-code hook request must produce an EMPTY curl response body (curl itself " +
                       "exiting 0) -- got: \"\(resultText)\"")
    }

    // MARK: - Helpers (file-private near-duplicates -- see this file's own header)

    /// Same joined `.label`/`.value` reading `CockpitApprovalE2ETests.
    /// elementText`'s own doc comment establishes (field-verified: a
    /// SwiftUI `Text`'s rendered content can surface via `.value` rather
    /// than `.label`).
    private func elementText(_ element: XCUIElement) -> String {
        let label = element.label
        let value = element.value as? String ?? ""
        if label.isEmpty { return value }
        if value.isEmpty || value == label { return label }
        return label + " " + value
    }

    /// Resolves the focused pane's `surface_id` via a synchronous
    /// `pane_list` call over `/mcp` -- reading it off the live pane
    /// registry itself, rather than trusting the pane's own
    /// `$CALYX_SURFACE_ID` shell variable, so the value handed to the
    /// raw `/approval-request` POST below is exactly what
    /// `CalyxMCPServer.approvalSurfaceExists(_:)` will look up.
    private func resolveFocusedSurfaceID(counter: inout Int) throws -> String {
        let list = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)
        let panes = try XCTUnwrap(list["panes"] as? [[String: Any]], "pane_list must return a panes array")
        let focused = try XCTUnwrap(
            panes.first { ($0["is_focused"] as? Bool) == true },
            "pane_list must report exactly one focused pane -- got: \(panes)"
        )
        return try XCTUnwrap(focused["surface_id"] as? String, "the focused pane's entry must carry surface_id")
    }

    /// Synchronous `/mcp` `tools/call` -- only for a call that returns
    /// promptly (`pane_list`), mirrors `CockpitApprovalE2ETests.
    /// toolCallSync`'s own shape.
    private func toolCallSync(name: String, argumentsJSON: String, counter: inout Int) -> [String: Any] {
        let script = mcpToolCallScript(name: name, argumentsJSON: argumentsJSON, maxTimeSeconds: 10)
        let encoded = Data(script.utf8).base64EncodedString()
        counter += 1
        let scriptPath = "/tmp/calyx-e2e-agenthook-sync-\(counter).py"
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && python3 \(scriptPath)"
        let resultText = paneExec(command, counter: &counter)

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

    /// Builds a python3 script POSTing a single `tools/call` to `/mcp`,
    /// mirrors `CockpitApprovalE2ETests.toolCallScript` exactly (only
    /// `pane_list` uses this path here).
    private func mcpToolCallScript(name: String, argumentsJSON: String, maxTimeSeconds: Int) -> String {
        """
        import json
        import os
        import subprocess

        def main():
            endpoint_path = os.environ.get("CALYX_ENDPOINT_FILE") or os.path.expanduser(
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

    /// Backgrounds a python3 script that POSTs `bodyJSON` directly to
    /// `/approval-request` (NOT `/mcp` -- that endpoint's own long-poll
    /// blocks until this test answers the resulting banner) with
    /// `X-Calyx-Agent-Kind: claude-code` and `X-Calyx-Surface-ID:
    /// <surfaceID>`, printing the raw response body verbatim to
    /// `outFile`. Mirrors `CockpitApprovalE2ETests.toolCallBackgrounded`'s
    /// own detached-subshell shape (`(cmd &); disown` via
    /// `panePasteAndReturn`, never waiting inline).
    ///
    /// `includeExitMarker`, default false (every existing caller parses
    /// `outFile` as JSON and must see nothing extra appended): when
    /// true, appends a `CURL_EXIT_<code>` line after the response body.
    /// An EMPTY response body (the `.dismissed` case this file's own
    /// dismiss test exercises) writes only a trailing newline to
    /// `outFile`, which a bare `waitForFileContent` poll cannot
    /// distinguish from "the curl call never finished" -- both read as
    /// non-empty-once-the-newline-lands, and both also match the
    /// zero-byte file the shell redirect itself pre-creates before the
    /// script ever runs. The marker line is the only signal that
    /// distinguishes "curl completed with an empty body" from "nothing
    /// has run yet" or "curl is still hanging".
    private func postApprovalRequestBackgrounded(
        bodyJSON: String, surfaceID: String, outFile: String, counter: inout Int, includeExitMarker: Bool = false
    ) {
        try? FileManager.default.removeItem(atPath: outFile)
        let exitMarkerLine = includeExitMarker ? "print(\"CURL_EXIT_%d\" % proc.returncode)" : ""
        let script = """
        import json
        import os
        import subprocess

        def main():
            endpoint_path = os.environ.get("CALYX_ENDPOINT_FILE") or os.path.expanduser(
                "~/Library/Application Support/Calyx/agent-endpoint.json"
            )
            with open(endpoint_path) as f:
                endpoint = json.load(f)
            port = endpoint["port"]
            token = endpoint["token"]

            body = '''\(bodyJSON)'''
            proc = subprocess.run(
                [
                    "curl", "-s", "--max-time", "65",
                    "-X", "POST",
                    "-H", "Authorization: Bearer " + token,
                    "-H", "X-Calyx-Agent-Kind: claude-code",
                    "-H", "X-Calyx-Surface-ID: \(surfaceID)",
                    "-H", "Content-Type: application/json",
                    "--data-binary", body,
                    "http://127.0.0.1:%d/approval-request" % port,
                ],
                capture_output=True, text=True,
            )
            print(proc.stdout)
            \(exitMarkerLine)

        try:
            main()
        except Exception as e:
            print(json.dumps({"error": repr(e)}))
        """
        let encoded = Data(script.utf8).base64EncodedString()
        counter += 1
        let scriptPath = "/tmp/calyx-e2e-agenthook-bg-\(counter).py"
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && " +
            "(python3 \(scriptPath) > \(outFile) 2>&1 &); disown"
        panePasteAndReturn(command)
    }

    /// Polls `path` for content, same bounded 0.5s-interval shape
    /// `CockpitApprovalE2ETests.waitForFileContent` uses.
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

    /// Parses `text` as `{"hookSpecificOutput":{"decision": {...}}}` and
    /// returns the inner `decision` object -- the shape
    /// `AgentHookPermissionResponse.envelope(decision:)` wraps every
    /// claude-code response in.
    private func decodedDecision(_ text: String, context: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(context) was not a valid JSON object: \(text)")
            return [:]
        }
        let hookSpecificOutput = try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any], "\(context) must carry hookSpecificOutput -- got: \(text)")
        return try XCTUnwrap(hookSpecificOutput["decision"] as? [String: Any], "\(context) must carry hookSpecificOutput.decision -- got: \(text)")
    }
}
