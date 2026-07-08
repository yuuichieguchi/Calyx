//
//  CommandLogE2ETests.swift
//  CalyxUITests
//
//  End-to-end coverage for the command-log pipeline: a command typed
//  into a real pane must be tracked by the real shell integration
//  (ShellIntegrationInstaller/CalyxShellIntegrationEnvironment,
//  installed and pointed at by the real running app-under-test at
//  launch, since command tracking defaults ON) and be queryable back
//  out through the real terminal_* MCP tools
//  (terminal_list_commands/terminal_read_output), exactly the path an
//  MCP-connected coding agent uses.
//
//  ISOLATION CAVEAT (accepted, not a bug): this suite does NOT override
//  `HOME` on the app-under-test's launch environment, unlike
//  `SessionPersistenceE2ETests`. That suite CAN override HOME because
//  every pane command it issues explicitly re-derives the daemon's
//  socket path via `--runtime-dir`/`--state-dir` flags
//  (`PaneCLIExec.calyxSessionRootFlags`) -- there is no equivalent
//  escape hatch here: `calyx.zsh`/the fish integration both read
//  `"$HOME/Library/Application Support/Calyx/agent-endpoint.json"` as a
//  hardcoded path baked into the installed script, with no CLI-flag
//  override. `PaneCLIExec`'s own header already establishes (field-
//  verified) that a pane's shell does NOT inherit Calyx.app's own HOME
//  override at all -- ghostty execs every surface via `login -flp
//  <system-username> ...`, which resets `$HOME` against the REAL
//  system user regardless of what the app process's own environment
//  says. Overriding HOME on the app process here would therefore make
//  the APP write agent-endpoint.json/the integration scripts to an
//  isolated path while the PANE's hook script keeps reading the REAL
//  system path -- a strictly WORSE, silently-broken mismatch, not an
//  isolation win. So this suite deliberately runs against the real
//  `~/Library/Application Support/Calyx/` tree. This is acceptable
//  ONLY because everything written there is exactly what a real
//  "Enable AI Agent IPC" + normal launch already writes in production
//  (idempotent, fixed content -- ShellIntegrationInstaller.install,
//  AgentHookScript.install, AgentEndpointFile.write all overwrite
//  deterministically, no test-specific content, no destructive
//  removal of anything pre-existing): `CALYX_UITEST_SESSION_DIR` /
//  `CALYX_UITEST_DEFAULTS_SUITE` (the base class's own isolation) still
//  cover window/tab-session state and every UserDefaults-backed
//  setting, which is the isolation surface this suite's own assertions
//  actually depend on.
//
//  ENVIRONMENTAL PRECONDITION (outside this test's control, same as any
//  real "Enable AI Agent IPC" use): `IPCConfigManager.enableIPC`'s
//  `anySucceeded` gate requires at least one of `~/.claude`, `~/.codex`,
//  `~/.config/opencode` to exist on the machine running this suite --
//  otherwise `CalyxWindowController.enableIPC` stops the MCP server
//  right after starting it and shows an "IPC Error" alert instead of
//  "IPC Enabled" (both use the same "OK" button this test dismisses
//  either way, but only the success path leaves the server running for
//  the rest of this test to talk to). Not worked around here -- there
//  is no test-level seam for it, and a real developer machine running
//  Claude Code (as this whole task was) already satisfies it via
//  `~/.claude`.
//
//  QUERY MECHANISM (PaneCLIExec pattern, mirrors
//  `SessionPersistenceE2ETests`'s own header on why: the `CalyxUITests`
//  runner is itself App-Sandboxed and cannot open a new outbound
//  connection, so all `/mcp` network traffic must go through a real,
//  unsandboxed pane process). The pane-side query is written in
//  python3 (present on macOS by default), not sed/grep: `tools/call`'s
//  response is a JSON-RPC envelope whose own `result.content[0].text`
//  is ITSELF a JSON string (double-encoded) -- python3's `json` module
//  parses both layers robustly, where `jq` is not guaranteed to be
//  installed and hand-rolled sed/grep JSON parsing is fragile for
//  arbitrarily-ordered keys. The script is written to a `/tmp` file via
//  a single-line base64 encode+decode (rather than pasting its literal
//  multi-line source into the pane), sidestepping any risk of ghostty's
//  paste handling submitting a multi-line paste as several separate
//  command lines instead of one atomic write.
//

import XCTest

final class CommandLogE2ETests: CalyxUITestCase {

    // MARK: - Test

    func test_trackedCommands_areQueryableViaTerminalMCPTools() throws {
        var counter = 0

        enableAIAgentIPCViaCommandPalette()

        // Two tracked commands, fire-and-forget (panePasteAndReturn, NOT
        // paneExec): paneExec appends `> outFile 2>&1` to the pasted
        // line, which (per shell redirection-attaches-to-the-last-
        // simple-command rules) would land on `false` alone for the
        // first command below, polluting the ACTUAL command text
        // preexec captures with a redirection suffix that serves no
        // purpose here -- this suite only needs the SERVER-side tracked
        // record, never the pane's own stdout, so there is nothing to
        // read back from either command.
        panePasteAndReturn("echo CALYX_CMDLOG_MARKER_A1; false")
        panePasteAndReturn("echo done")

        let encodedScript = Data(Self.queryScript.utf8).base64EncodedString()
        let queryCommand = "printf '%s' '\(encodedScript)' | base64 -d > /tmp/calyx-e2e-cmdlog-query.py && " +
            "python3 /tmp/calyx-e2e-cmdlog-query.py"
        // Generous timeoutAttempts: the script itself retries
        // terminal_list_commands for up to ~20s internally (the curl
        // POSTs calyx.zsh's hooks fire are backgrounded+disowned, an
        // async round trip through a real local HTTP server), on top of
        // paneExec's own per-attempt polling.
        let resultJSON = paneExec(queryCommand, counter: &counter, timeoutAttempts: 90)

        XCTAssertNotEqual(resultJSON, "(no output)",
                          "the pane-side query script produced no output at all within the timeout budget")

        guard let data = resultJSON.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("query script output was not valid JSON: \(resultJSON)")
            return
        }

        if let scriptError = result["error"] as? String {
            XCTFail("pane-side query script reported an error: \(scriptError)")
            return
        }

        // MARK: shell_integration flag

        let list = try XCTUnwrap(result["list"] as? [String: Any], "result must carry the raw list response")
        XCTAssertEqual(
            list["shell_integration"] as? Bool, true,
            "terminal_list_commands must report shell_integration: true once at least one command has been tracked"
        )

        // MARK: both commands present, oldest-first

        let commands = try XCTUnwrap(list["commands"] as? [[String: Any]], "list response must carry a commands array")
        XCTAssertGreaterThanOrEqual(commands.count, 2,
                                    "both the marker command and \"echo done\" must be tracked -- found \(commands.count)")

        let markerIndex = commands.firstIndex { ($0["command"] as? String)?.contains("CALYX_CMDLOG_MARKER_A1") == true }
        let doneIndex = commands.firstIndex { ($0["command"] as? String)?.contains("echo done") == true }
        let markerCommandIndex = try XCTUnwrap(markerIndex, "no tracked command's text contains CALYX_CMDLOG_MARKER_A1")
        let doneCommandIndex = try XCTUnwrap(doneIndex, "no tracked command's text contains \"echo done\"")
        XCTAssertLessThan(
            markerCommandIndex, doneCommandIndex,
            "terminal_list_commands must return commands oldest-first: the marker command was submitted before \"echo done\""
        )

        // MARK: marker command's own fields

        let markerCommand = commands[markerCommandIndex]
        XCTAssertEqual(markerCommand["state"] as? String, "finished",
                       "the marker command must have finished (preexec+precmd both fired) by the time it's queryable")
        XCTAssertEqual(markerCommand["exit_code"] as? Int, 1,
                       "`echo CALYX_CMDLOG_MARKER_A1; false` must report exit_code 1 -- the LAST command in the " +
                       "`;`-separated line determines the compound line's own exit status")
        XCTAssertNotNil(markerCommand["duration_ms"], "a finished command must carry a duration_ms")

        // MARK: terminal_read_output

        let readOutput = try XCTUnwrap(result["read_output"] as? [String: Any], "result must carry the read_output response")
        let outputText = try XCTUnwrap(readOutput["text"] as? String, "read_output response must carry a text field")
        XCTAssertTrue(outputText.contains("CALYX_CMDLOG_MARKER_A1"),
                     "the marker command's captured output must contain the literal marker text it echoed")
    }

    // MARK: - Helpers

    /// Opens the Command Palette, executes "Enable AI Agent IPC" (the
    /// real `CalyxWindowController.enableIPC()` -- starts a real
    /// `CalyxMCPServer`, writes a real `agent-endpoint.json`, installs
    /// the real shell/agent-hook scripts), and dismisses the resulting
    /// `NSAlert.runModal()` confirmation, mirroring
    /// `RealQuitRestoreE2ETests`'s own established pattern for driving a
    /// real modal alert from XCUITest.
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

    /// Pane-side python3 script: reads the real agent-endpoint.json,
    /// polls terminal_list_commands (via a real POST to /mcp) until a
    /// command containing the marker text shows up, then reads that
    /// command's output via terminal_read_output. Prints one compact
    /// JSON line to stdout: `{"list": <raw list response>, "read_output":
    /// <raw read_output response>}`, or `{"error": "<message>"}` on any
    /// failure -- so a failure surfaces as informative JSON `paneExec`
    /// captures and this test parses, rather than a bare traceback that
    /// `paneExec`'s own timeout-driven "(no output)" fallback would
    /// otherwise swallow.
    private static let queryScript = """
    import json
    import os
    import subprocess
    import time

    def main():
        endpoint_path = os.path.expanduser(
            "~/Library/Application Support/Calyx/agent-endpoint.json"
        )
        with open(endpoint_path) as f:
            endpoint = json.load(f)
        port = endpoint["port"]
        token = endpoint["token"]

        surface_id = os.environ.get("CALYX_SURFACE_ID", "")
        if not surface_id:
            surface_id = os.environ.get("CALYX_SESSION_ID", "")
        if not surface_id:
            print(json.dumps({"error": "CALYX_SURFACE_ID and CALYX_SESSION_ID both unset in the pane"}))
            return

        def call_tool(name, arguments):
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": name, "arguments": arguments},
            })
            proc = subprocess.run(
                [
                    "curl", "-s", "--max-time", "5",
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
            return json.loads(text)

        list_result = None
        marker_command = None
        for _ in range(20):
            list_result = call_tool("terminal_list_commands", {"surface_id": surface_id})
            marker_command = next(
                (c for c in list_result.get("commands", []) if "CALYX_CMDLOG_MARKER_A1" in c.get("command", "")),
                None,
            )
            if marker_command is not None and len(list_result.get("commands", [])) >= 2:
                break
            time.sleep(1)

        if marker_command is None:
            print(json.dumps({"error": "marker command never appeared", "last_list": list_result}))
            return

        read_output = call_tool("terminal_read_output", {"command_id": marker_command["id"]})
        print(json.dumps({"list": list_result, "read_output": read_output}))

    try:
        main()
    except Exception as e:
        print(json.dumps({"error": repr(e)}))
    """
}
