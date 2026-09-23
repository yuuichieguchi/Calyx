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
//  ISOLATION: launched with `--calyx-path-root=<scoped temp dir>` plus
//  `-calyx.ipc.enabled YES`, so `CalyxPathRoot.testRoot` scopes every
//  Calyx-owned and agent-owned config path -- `AppSupportDirectory`,
//  `AgentToolPaths`, and therefore `AgentEndpointFile` -- beneath the
//  temp dir instead of the developer's real home, and
//  `AppDelegate.resyncAgentHooksIfInstalled` (gated on
//  `LaunchEnvironmentPolicy.mayPerformAgentIPCActivation()`, which
//  requires `CalyxPathRoot.testRoot != nil` under `--uitesting`) runs
//  real launch-time activation against that scoped root. This closed a real
//  path-resolution hole: a pane's shell starts via `login -flp
//  <system-username>`, which resets `$HOME` to the real system user
//  regardless of `CalyxPathRoot.testRoot`, so `calyx.zsh`/the fish
//  integration previously could only read the hardcoded, unscoped
//  `"$HOME/Library/Application Support/Calyx/agent-endpoint.json"`.
//  `GhosttySurfaceController` now injects `CALYX_ENDPOINT_FILE` into
//  every pane's own environment (`AgentEndpointFile.path`, already
//  reflecting the scoped root), which every generated script reads
//  ahead of that literal fallback -- see `AgentEndpointFile.swift` and
//  `GhosttySurface.swift`'s own doc comments. `setUp()` below
//  pre-creates `<scopedRoot>/.claude`, satisfying
//  `IPCConfigManager.enableIPC`'s `anySucceeded` gate (see below)
//  without depending on the developer's own machine.
//
//  ENVIRONMENTAL PRECONDITION, now satisfied by `setUp()` rather than
//  left to the host machine: `IPCConfigManager.enableIPC`'s
//  `anySucceeded` gate requires at least one of `~/.claude`, `~/.codex`,
//  `~/.config/opencode` (resolved beneath the scoped root here) to
//  exist -- otherwise launch-time activation stops the MCP server right
//  after starting it and leaves `AgentRegistry.hooksIssues` set instead
//  of a running server. `setUp()` creates `<scopedRoot>/.claude` before
//  `app.launch()` so this suite's activation always succeeds regardless
//  of what CLIs happen to be installed on the machine running it.
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

    // MARK: - Scoped launch

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
        ["--calyx-path-root=\(scopedPathRoot)", "-calyx.ipc.enabled", "YES"]
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: scopedPathRoot)
    }

    /// Polls for the scoped `agent-endpoint.json` (written by
    /// `AgentEndpointFile.write` once launch-time activation's real
    /// `CalyxMCPServer.start()` succeeds) so this test never pastes a
    /// pane command before the shell-integration scripts it depends on
    /// are actually installed at `<scopedPathRoot>/Calyx`.
    private func waitForIPCActivation(timeout: TimeInterval = 20) {
        let endpointPath = scopedPathRoot + "/Calyx/agent-endpoint.json"
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: endpointPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointPath),
                     "launch-time AI Agent IPC activation never wrote agent-endpoint.json under the scoped root")
    }

    // MARK: - Test

    func test_trackedCommands_areQueryableViaTerminalMCPTools() throws {
        var counter = 0

        waitForIPCActivation()

        // Two tracked commands, typed directly into the frontmost pane
        // (NOT panePasteAndReturn/paneExec): both of those helpers write
        // the command to a script file and type `sh <scriptPath>` into
        // the pane instead, so the interactive shell's preexec hook only
        // ever sees that `sh` invocation as `$1` -- never the command
        // text inside the script -- which would leave the SERVER-side
        // tracked `command` field unable to match either marker below.
        // Typing the literal command text directly makes preexec capture
        // exactly what this test needs to find via terminal_list_commands.
        // Typed pane text must consist only of characters whose key
        // position is the same under the test runner's and the pane's
        // keyboard layouts: letters, digits, space, `;`, Return. `_` and
        // `'` are not, and arrive as other characters -- see
        // `typeIntoPane` in PaneCLIExec.swift.
        Thread.sleep(forTimeInterval: 1)
        typeIntoPane("echo CALYXCMDLOGMARKERA1; false\n")
        Thread.sleep(forTimeInterval: 1)
        typeIntoPane("echo done\n")

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

        let markerIndex = commands.firstIndex { ($0["command"] as? String)?.contains("CALYXCMDLOGMARKERA1") == true }
        let doneIndex = commands.firstIndex { ($0["command"] as? String)?.contains("echo done") == true }
        let markerCommandIndex = try XCTUnwrap(markerIndex, "no tracked command's text contains CALYXCMDLOGMARKERA1")
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
                       "`echo CALYXCMDLOGMARKERA1; false` must report exit_code 1 -- the LAST command in the " +
                       "`;`-separated line determines the compound line's own exit status")
        XCTAssertNotNil(markerCommand["duration_ms"], "a finished command must carry a duration_ms")

        // MARK: terminal_read_output

        let readOutput = try XCTUnwrap(result["read_output"] as? [String: Any], "result must carry the read_output response")
        let outputText = try XCTUnwrap(readOutput["text"] as? String, "read_output response must carry a text field")
        XCTAssertTrue(outputText.contains("CALYXCMDLOGMARKERA1"),
                     "the marker command's captured output must contain the literal marker text it echoed")
    }

    // MARK: - Helpers

    /// Pane-side python3 script: reads the scoped agent-endpoint.json,
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
        endpoint_path = os.environ.get("CALYX_ENDPOINT_FILE") or os.path.expanduser(
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
                (c for c in list_result.get("commands", []) if "CALYXCMDLOGMARKERA1" in c.get("command", "")),
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
