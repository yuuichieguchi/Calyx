// MCPAppsE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the MCP Apps host (plan:
// zesty-conjuring-dream.md): a stdio fixture MCP server
// (Fixtures/mcp_apps_fixture_server.py, legacy 2025-11-25 handshake,
// newline-delimited JSON) is pre-registered under a scoped
// `--calyx-path-root`, then every scenario drives real `/calyx-mcp`
// traffic from a live pane -- exactly the CockpitApprovalE2ETests
// pattern (see that file's own header for the full ISOLATION /
// ENVIRONMENTAL PRECONDITION / QUERY MECHANISM rationale, restated only
// where this suite's own mechanism differs).
//
// NONE OF THE PRODUCTION TYPES THIS SUITE DEPENDS ON EXIST YET.
// Every accessibility identifier below is a literal string this suite
// assumes the implementation will wire up; every `mcp-servers.json`
// field name and shape, every `_meta.ui` field, every Settings string
// keyword is an assumption this file's own header documents explicitly
// (see "PRODUCTION ASSUMPTIONS" below) rather than leaving implicit.
// This file WILL compile (no `@testable import`, every identifier is a
// string literal) -- the expected RED here is a RUNTIME failure (the
// accessibility elements never appear, `/calyx-mcp` never answers,
// `mcp-servers.json` is never read), not a build break.
//
// PRODUCTION ASSUMPTIONS this suite's own Red/Green depends on:
// - `mcp-servers.json` (`<scopedPathRoot>/Calyx/mcp-servers.json`):
//   `{"schemaVersion": 1, "servers": [{"id": "<UUID>", "alias": "fx",
//   "displayName": "...", "isEnabled": true, "transport": {"stdio":
//   {"command": "/usr/bin/python3", "args": [...], "envNames": [],
//   "cwd": "<scopedPathRoot>"}}}]}`.
// - Re-exported tool names are `<alias>-<upstream name>` (plan §4), so
//   this suite calls `fx-show_counter`, `fx-slow_tool`, `fx-crash`,
//   `fx-show_bad_mime`, etc. The view's OWN `tools/call` (from inside
//   the WKWebView bridge, never through this suite directly) uses the
//   UPSTREAM name (`record_event`, `model_only`) unprefixed, since it
//   is scoped to the one upstream server already (plan §5,
//   `MCPAppServerSession` bound to one server).
// - `/calyx-mcp` accepts a request with NO prior session (pi-style,
//   plan §4) and answers a plain JSON body (not SSE) when sent
//   `Accept: application/json`; `X-Calyx-Surface-ID` resolves the
//   calling pane (plan §4 pane resolution order).
// - `_meta.ui.resourceUri` on a proxied tool RESULT is exported to the
//   agent in the `ui://<alias>/<upstream host>/<rest>` form (contract
//   C11, `MCPUIResourceURI.export`: the alias is PREPENDED and the
//   upstream host is kept), so the fixture's `ui://fixture/counter.html`
//   reaches this suite as `ui://fx/fixture/counter.html`. The fixture's
//   own `tools/call` results carry `_meta.ui.resourceUri` (Calyx never
//   adds one from the tool definition, K62). The VIEW receives the
//   upstream form, since its session is bound to the upstream server.
// - Accessibility identifiers (implementer adds all of these):
//   `calyx.mcpApps.dock.<surfaceID>`,
//   `calyx.mcpApps.view.<viewID>.{web,header,stateLabel,closeButton}`,
//   `calyx.mcpApps.prompt.{container,primaryButton,allowForViewButton,
//   cancelButton,copyButton}`, `calyx.mcpApps.standalonePanel.<viewID>`,
//   `calyx.settings.mcpServers.{list,emptyState,ipcDisabledBanner,
//   configErrorBanner,addButton,importButton}`,
//   `calyx.settings.mcpServers.row.<id>.{status,enabledSwitch,
//   editButton,retryButton,removeButton}`,
//   `calyx.settings.mcpServers.editor.{nameField,aliasField,
//   transportPicker,commandField,argsField,saveButton}`,
//   `calyx.settings.mcpServers.import.{textView,preview,confirmButton}`.
//   Settings toolbar item title: "MCP Apps" (looked up by label, no
//   identifier -- mirrors SettingsWindowE2ETests's own established
//   toolbar-button-by-label idiom, see that file's header for why).
// - Settings row status text and view state-label text are asserted by
//   a single case-insensitive SUBSTRING keyword per state: "with UI"
//   (ready: the Settings row reads "N tools, M with UI"), "MIME" (wrong
//   resource MIME type), "multiple" (2+ content items), "large"
//   (oversized resource), "base64" (invalid blob), "ui://" (non-ui://
//   resourceUri). After a crash of a ready server the row is non-ready
//   in one of two states before it is ready again: `restarting`
//   ("Disconnected (reconnecting)", during the restart backoff) and
//   then `connecting` ("Connecting", during the restarted fixture's own
//   5 s sleep and handshake) -- `MCPServerRowStatusResolver`'s strings,
//   so the crash scenario accepts either "Disconnected" or "Connecting".
// - `toggle_split_zoom`'s default keybinding is unmodified from
//   ghostty's own default (`ghostty/src/config/Config.zig`, "Toggle
//   zoom a split"): Cmd+Shift+Return. Calyx's own config never
//   overrides it (`grep -rn "toggle_split_zoom" Calyx/` at the time
//   this suite was written found no override). The binding is on the
//   physical Return key, so the suite types `XCUIKeyboardKey.return`
//   ("\r"); `.enter` is "\u{3}", the keypad Enter key (ghostty's
//   `numpad_enter`), which matches no binding.
// - Plain Cmd+W closes the FOCUSED PANE, not the whole tab
//   (`CalyxUITestCase.swift`'s own `closeTabViaMenu()` doc comment,
//   confirming a prior shortcut move already landed).
//
// FIXTURE SERVER CONTRACT (Fixtures/mcp_apps_fixture_server.py, its own
// header has the full rationale): `--event-log <path>` is a
// newline-delimited log of tokens the counter VIEW observed, appended
// via its own `record_event` (app-only) tool calls -- this suite reads
// that file directly instead of reaching into the WKWebView's
// accessibility tree (which MCP Apps view content deliberately isn't
// exposed through). Tokens used below: "view:ui/initialize-sent",
// "view:ui/initialize-result", "view:initialized", "host:tool-input",
// "host:tool-result", "host:tool-cancelled", "host:context-changed",
// "view:message_sent", "view:model_only_error:<code>". `crash` leaves a
// marker file (`<event-log>.crashed`) and exits; on the NEXT process
// start the fixture sleeps 5s before answering `initialize`, widening
// the non-ready window (restart backoff, then connecting) before the
// reconnect makes the row ready again. Every UI tool's `tools/call`
// result carries `_meta.ui.resourceUri` = that tool's upstream URI.
//
// PANE COMMANDS AND TEMP FILES: every `/tmp` file this suite reads back
// (command output, background call output, the `cat` receive file)
// has a fresh UUID in its name, and a file that already exists before
// its command runs fails the test. The sandboxed test runner cannot
// delete files under `/tmp` (a `try? removeItem` there fails silently),
// so a reused name would read a previous test's output. A command is
// typed into a pane only while that pane's shell is at its prompt:
// once `cat -u > <file>` holds the foreground, a typed `sh <script>`
// line is read by `cat`, not run. A call that must be issued while
// the pane cannot accept typing (a foreground `cat`, a key Settings
// window) is typed EARLIER as a background job -- started at once, or
// held until the runner creates a trigger file.

import XCTest
import AppKit

/// Shared plumbing for every MCP Apps E2E scenario. Not `final` so both
/// `MCPAppsE2ETests` (fixture pre-registered) and
/// `MCPAppsSettingsE2ETests` (starts with zero servers, for the empty
/// state) can reuse it while overriding `preregistersFixture`.
class MCPAppsE2ETestCaseBase: CalyxUITestCase {

    // MARK: - Accessibility identifiers

    static let fixtureAlias = "fx"

    // The consent prompt (ui/open-link, ui/message) no longer shows
    // inline in the card: it is now the app-wide Cockpit approval
    // banner, same container/allow-button IDs every other approval uses.
    private static let promptContainerID = "calyx.approvalBanner.container"
    private static let promptPrimaryButtonID = "calyx.approvalBanner.allowButton"
    private static let standalonePanelPrefix = "calyx.mcpApps.standalonePanel."

    // MARK: - Scoped launch + fixture pre-registration

    /// Override to `false` for a suite that must start with zero
    /// registered servers (the Settings empty-state scenario).
    var preregistersFixture: Bool { true }

    private lazy var scopedPathRoot: String = {
        let root = NSTemporaryDirectory() + "CalyxUITests-mcpapps-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // Satisfies IPCConfigManager.enableIPC's anySucceeded gate, same
        // as CockpitApprovalE2ETests's own scopedPathRoot.
        try? FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        return root
    }()

    private(set) lazy var eventLogPath: String = scopedPathRoot + "/mcp-fixture-events.log"
    private lazy var crashMarkerPath: String = eventLogPath + ".crashed"
    private(set) lazy var serverID: String = UUID().uuidString.uppercased()

    /// `#filePath` sibling lookup, not a bundled resource: `project.yml`
    /// declares `CalyxUITests` sources as a plain directory reference
    /// with no established precedent (no other non-`.swift` file exists
    /// under `CalyxUITests/`) for xcodegen copying a non-Swift file into
    /// the `.xctest` bundle as a resource, so this suite resolves the
    /// fixture script relative to ITS OWN compiled source location
    /// instead of risking `Bundle(for:).path(forResource:)` returning
    /// `nil` on a machine where that assumption doesn't hold. This is
    /// stable across a full local `xcodebuild test` run (compile and
    /// run share the same checkout), but not portable off this
    /// worktree -- flagged in the handback as a binding assumption.
    private static let fixtureScriptPath: String = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mcp_apps_fixture_server.py")
            .path
    }()

    override func setUp() {
        _ = scopedPathRoot
        if preregistersFixture {
            writeMCPServersConfig()
        }
        super.setUp()
    }

    override var additionalLaunchArguments: [String] {
        ["--calyx-path-root=\(scopedPathRoot)", "-calyx.ipc.enabled", "YES"]
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: scopedPathRoot)
    }

    func writeMCPServersConfig() {
        let calyxDir = scopedPathRoot + "/Calyx"
        try? FileManager.default.createDirectory(atPath: calyxDir, withIntermediateDirectories: true)
        let config: [String: Any] = [
            "schemaVersion": 1,
            "servers": [
                [
                    "id": serverID,
                    "alias": Self.fixtureAlias,
                    "displayName": "MCP Apps Fixture",
                    "isEnabled": true,
                    "transport": [
                        "stdio": [
                            "command": "/usr/bin/python3",
                            "args": [Self.fixtureScriptPath, "--event-log", eventLogPath],
                            "envNames": [],
                            "cwd": scopedPathRoot,
                        ],
                    ],
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) else {
            XCTFail("failed to serialize the scoped mcp-servers.json fixture config")
            return
        }
        do {
            try data.write(to: URL(fileURLWithPath: calyxDir + "/mcp-servers.json"))
        } catch {
            XCTFail("failed to write the scoped mcp-servers.json: \(error)")
        }
    }

    /// Overwrites the scoped `mcp-servers.json` with invalid JSON, for
    /// the config-error-banner scenario.
    func writeCorruptMCPServersConfig() {
        let calyxDir = scopedPathRoot + "/Calyx"
        try? FileManager.default.createDirectory(atPath: calyxDir, withIntermediateDirectories: true)
        let corrupt = "{ this is not valid JSON "
        try? corrupt.write(toFile: calyxDir + "/mcp-servers.json", atomically: true, encoding: .utf8)
    }

    // MARK: - IPC activation

    func waitForIPCActivation(timeout: TimeInterval = 20) {
        let endpointPath = scopedPathRoot + "/Calyx/agent-endpoint.json"
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: endpointPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointPath),
                     "launch-time AI Agent IPC activation never wrote agent-endpoint.json under the scoped root")
    }

    // MARK: - Event log

    /// Polls the fixture's own event log until it has at least
    /// `minCount` lines or `timeout` elapses, returning whatever it has
    /// observed (possibly fewer than `minCount`).
    func waitForEventLog(minCount: Int, timeout: TimeInterval = 20) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var lines: [String] = []
        while Date() < deadline {
            if let content = try? String(contentsOfFile: eventLogPath, encoding: .utf8) {
                lines = content.split(separator: "\n").map(String.init)
                if lines.count >= minCount { return lines }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return lines
    }

    /// Polls the event log until `predicate` is satisfied by the
    /// accumulated lines or `timeout` elapses.
    func pollEventLog(until predicate: ([String]) -> Bool, timeout: TimeInterval = 20) -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var lines: [String] = []
        while Date() < deadline {
            if let content = try? String(contentsOfFile: eventLogPath, encoding: .utf8) {
                lines = content.split(separator: "\n").map(String.init)
                if predicate(lines) { return lines }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return lines
    }

    // MARK: - Pane commands with unique output files

    /// `/tmp/calyx-e2e-mcpapps-<tag>-<UUID>.<ext>`: a path in `/tmp`
    /// (the pane's shell writes it, this sandboxed runner reads it) that
    /// no earlier test or call can have used. See this file's header
    /// ("PANE COMMANDS AND TEMP FILES").
    func uniqueTmpPath(_ tag: String, ext: String) -> String {
        "/tmp/calyx-e2e-mcpapps-\(tag)-\(UUID().uuidString).\(ext)"
    }

    /// Fails the test when `path` already exists before the command that
    /// is supposed to create it has run, and returns `false` so the
    /// caller does not type that command.
    func assertAbsentBeforeCommand(_ path: String) -> Bool {
        guard !FileManager.default.fileExists(atPath: path) else {
            XCTFail("\(path) already exists before the command that writes it ran -- a stale file would be read as this command's output")
            return false
        }
        return true
    }

    /// Writes `content` to a UUID-named script under the runner's own
    /// container tmp and types `sh <scriptPath>` + Return into the
    /// frontmost pane, with the same `[A-Za-z0-9/._-]` path guard and
    /// no quoting as `PaneCLIExec.swift`'s private `typePaneScript` (see
    /// that file's header for why). The caller must know the pane's
    /// shell is at its prompt (see this file's header).
    private func typeMCPPaneScript(_ content: String) {
        let scriptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-e2e-mcpapps-\(UUID().uuidString).sh").path
        do {
            try content.write(toFile: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("failed to write pane script \(scriptFile): \(error)")
            return
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-")
        guard scriptFile.unicodeScalars.allSatisfy(allowed.contains) else {
            XCTFail("pane script path contains a character requiring quoting: \(scriptFile)")
            return
        }
        Thread.sleep(forTimeInterval: 1)
        app.typeText("sh \(scriptFile)\n")
    }

    /// `PaneCLIExec.paneExec` with a UUID-named output file that must not
    /// exist before the command runs (see this file's header): runs
    /// `command` in the frontmost pane with stdout+stderr redirected to
    /// that file and polls it until it has content or `timeoutAttempts`
    /// half-second polls elapse, returning the trimmed content, or
    /// "(no output)".
    func mcpPaneExec(_ command: String, timeoutAttempts: Int = 20) -> String {
        let outFile = uniqueTmpPath("out", ext: "txt")
        guard assertAbsentBeforeCommand(outFile) else { return "(no output)" }
        typeMCPPaneScript("\(command) > \(outFile) 2>&1\n")
        return waitForFileContent(atPath: outFile, timeoutAttempts: timeoutAttempts)
    }

    // MARK: - /calyx-mcp request script

    /// Builds a python3 script that POSTs one JSON-RPC request to the
    /// real `/calyx-mcp` endpoint (never `/mcp`, the pre-existing
    /// unchanged Cockpit endpoint) and prints the full decoded response
    /// envelope on one line, or `{"error": ...}` on any failure. Built
    /// line-by-line (not as one Swift multi-line string literal) so
    /// injected header/marker lines never fight Swift's own literal
    /// dedent behavior.
    func mcpAppsRequestScript(
        method: String, paramsJSON: String, surfaceID: String?, maxTimeSeconds: Int, curlMarker: String? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("import json")
        lines.append("import os")
        lines.append("import subprocess")
        lines.append("")
        lines.append("def main():")
        lines.append("    endpoint_path = os.environ.get(\"CALYX_ENDPOINT_FILE\") or os.path.expanduser(")
        lines.append("        \"~/Library/Application Support/Calyx/agent-endpoint.json\"")
        lines.append("    )")
        lines.append("    with open(endpoint_path) as f:")
        lines.append("        endpoint = json.load(f)")
        lines.append("    port = endpoint[\"port\"]")
        lines.append("    token = endpoint[\"token\"]")
        lines.append("")
        lines.append("    body = json.dumps({")
        lines.append("        \"jsonrpc\": \"2.0\",")
        lines.append("        \"id\": 1,")
        lines.append("        \"method\": \"\(method)\",")
        lines.append("        \"params\": json.loads('''\(paramsJSON)'''),")
        lines.append("    })")
        lines.append("    headers = [")
        lines.append("        \"-H\", \"Authorization: Bearer \" + token,")
        lines.append("        \"-H\", \"Content-Type: application/json\",")
        lines.append("        \"-H\", \"Accept: application/json\",")
        lines.append("    ]")
        if let surfaceID {
            lines.append("    headers += [\"-H\", \"X-Calyx-Surface-ID: \(surfaceID)\"]")
        }
        lines.append("    curl_argv = [\"curl\", \"-s\", \"--max-time\", \"\(maxTimeSeconds)\", \"-X\", \"POST\"] + headers")
        if let curlMarker {
            lines.append("    curl_argv += [\"-A\", \"\(curlMarker)\"]")
        }
        lines.append("    curl_argv += [\"--data-binary\", body, \"http://127.0.0.1:%d/calyx-mcp\" % port]")
        lines.append("    proc = subprocess.run(curl_argv, capture_output=True, text=True)")
        lines.append("    stdout = proc.stdout")
        lines.append("    if stdout.strip().startswith(\"event:\") or \"\\ndata:\" in stdout:")
        lines.append("        data_lines = [line[5:].strip() for line in stdout.splitlines() if line.startswith(\"data:\")]")
        lines.append("        stdout = data_lines[-1] if data_lines else stdout")
        lines.append("    envelope = json.loads(stdout)")
        lines.append("    print(json.dumps(envelope))")
        lines.append("")
        lines.append("try:")
        lines.append("    main()")
        lines.append("except Exception as e:")
        lines.append("    print(json.dumps({\"error\": repr(e)}))")
        return lines.joined(separator: "\n") + "\n"
    }

    func toolCallParamsJSON(name: String, argumentsJSON: String) -> String {
        "{\"name\": \"\(name)\", \"arguments\": \(argumentsJSON)}"
    }

    @discardableResult
    func mcpAppsCallSync(
        method: String, paramsJSON: String, surfaceID: String?, timeoutAttempts: Int = 20
    ) -> [String: Any] {
        let script = mcpAppsRequestScript(method: method, paramsJSON: paramsJSON, surfaceID: surfaceID, maxTimeSeconds: 10)
        let encoded = Data(script.utf8).base64EncodedString()
        let scriptPath = uniqueTmpPath("sync", ext: "py")
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && python3 \(scriptPath)"
        let resultText = mcpPaneExec(command, timeoutAttempts: timeoutAttempts)
        guard resultText != "(no output)",
              let data = resultText.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(method) pane-side /calyx-mcp call produced no/invalid JSON output: \(resultText)")
            return [:]
        }
        return envelope
    }

    /// Types (into the frontmost pane, whose shell must be at its
    /// prompt) a background job that issues one `tools/call` and writes
    /// the decoded envelope to a fresh UUID-named `/tmp` file, returning
    /// that file's path; the pane's shell is back at its prompt as soon
    /// as the job is started. With `startWhenFileExists`, the job waits
    /// until the runner creates that file (the runner cannot type into
    /// the pane then, see this file's header) and gives up without
    /// calling after 120 s, so a test that fails before creating it does
    /// not leave the job polling forever.
    @discardableResult
    func mcpAppsCallBackgrounded(
        name: String, argumentsJSON: String, surfaceID: String?,
        maxTimeSeconds: Int = 65, curlMarker: String? = nil, startWhenFileExists triggerFile: String? = nil
    ) -> String {
        let outFile = uniqueTmpPath("bg-out", ext: "json")
        guard assertAbsentBeforeCommand(outFile) else { return outFile }
        let paramsJSON = toolCallParamsJSON(name: name, argumentsJSON: argumentsJSON)
        let script = mcpAppsRequestScript(
            method: "tools/call", paramsJSON: paramsJSON, surfaceID: surfaceID,
            maxTimeSeconds: maxTimeSeconds, curlMarker: curlMarker
        )
        let encoded = Data(script.utf8).base64EncodedString()
        let scriptPath = uniqueTmpPath("bg", ext: "py")
        let call = "python3 \(scriptPath) > \(outFile) 2>&1"
        let job: String
        if let triggerFile {
            job = "i=0; while [ ! -e '\(triggerFile)' ] && [ $i -lt 600 ]; do sleep 0.2; i=$((i+1)); done; " +
                "if [ -e '\(triggerFile)' ]; then \(call); fi"
        } else {
            job = call
        }
        typeMCPPaneScript("printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && (\(job)) &\n")
        return outFile
    }

    func waitForFileContent(atPath path: String, timeoutAttempts: Int = 130) -> String {
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

    /// Same joined-`.label`/`.value` fallback as
    /// `CockpitApprovalE2ETests.elementText` -- see that file's own doc
    /// comment for the field-verified reason both must be checked.
    func elementText(_ element: XCUIElement) -> String {
        let label = element.label
        let value = element.value as? String ?? ""
        if label.isEmpty { return value }
        if value.isEmpty || value == label { return label }
        return label + " " + value
    }

    // MARK: - Legacy /mcp (unchanged Cockpit endpoint) helper

    /// Own copy of CockpitApprovalE2ETests' `toolCallSync` shape,
    /// targeting the pre-existing, unmodified `/mcp` endpoint --used
    /// only for plumbing this suite's own scenarios need (creating a
    /// second pane via `pane_split`), never for anything this suite is
    /// itself testing. Kept as a near-duplicate rather than promoted to
    /// `PaneCLIExec`, matching this codebase's established convention
    /// (see `CockpitApprovalE2ETests.swift`'s own header).
    @discardableResult
    func legacyIPCCallSync(name: String, argumentsJSON: String, timeoutAttempts: Int = 20) -> [String: Any] {
        var lines: [String] = []
        lines.append("import json")
        lines.append("import os")
        lines.append("import subprocess")
        lines.append("")
        lines.append("def main():")
        lines.append("    endpoint_path = os.environ.get(\"CALYX_ENDPOINT_FILE\") or os.path.expanduser(")
        lines.append("        \"~/Library/Application Support/Calyx/agent-endpoint.json\"")
        lines.append("    )")
        lines.append("    with open(endpoint_path) as f:")
        lines.append("        endpoint = json.load(f)")
        lines.append("    port = endpoint[\"port\"]")
        lines.append("    token = endpoint[\"token\"]")
        lines.append("")
        lines.append("    arguments = json.loads('''\(argumentsJSON)''')")
        lines.append("    body = json.dumps({")
        lines.append("        \"jsonrpc\": \"2.0\",")
        lines.append("        \"id\": 1,")
        lines.append("        \"method\": \"tools/call\",")
        lines.append("        \"params\": {\"name\": \"\(name)\", \"arguments\": arguments},")
        lines.append("    })")
        lines.append("    proc = subprocess.run(")
        lines.append("        [")
        lines.append("            \"curl\", \"-s\", \"--max-time\", \"10\",")
        lines.append("            \"-X\", \"POST\",")
        lines.append("            \"-H\", \"Authorization: Bearer \" + token,")
        lines.append("            \"-H\", \"Content-Type: application/json\",")
        lines.append("            \"--data-binary\", body,")
        lines.append("            \"http://127.0.0.1:%d/mcp\" % port,")
        lines.append("        ],")
        lines.append("        capture_output=True, text=True,")
        lines.append("    )")
        lines.append("    envelope = json.loads(proc.stdout)")
        lines.append("    text = envelope[\"result\"][\"content\"][0][\"text\"]")
        lines.append("    print(text)")
        lines.append("")
        lines.append("try:")
        lines.append("    main()")
        lines.append("except Exception as e:")
        lines.append("    print(json.dumps({\"error\": repr(e)}))")
        let script = lines.joined(separator: "\n") + "\n"
        let encoded = Data(script.utf8).base64EncodedString()
        let scriptPath = uniqueTmpPath("legacy", ext: "py")
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && python3 \(scriptPath)"
        let resultText = mcpPaneExec(command, timeoutAttempts: timeoutAttempts)
        guard resultText != "(no output)",
              let data = resultText.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(name) pane-side legacy /mcp call produced no/invalid JSON output: \(resultText)")
            return [:]
        }
        return result
    }

    // MARK: - Readiness gate

    /// Polls `tools/list` on `/calyx-mcp` until the fixture's own
    /// `fx-show_counter` tool is present (Calyx connects to every
    /// enabled upstream server at IPC start, and the FIRST call
    /// otherwise races that connection + `tools/list` round trip).
    /// Also asserts, as a real side effect of this same catalog read,
    /// that the app-only `fx-record_event` is never exported to a
    /// caller whose pane resolved (plan §5's host MUST).
    func waitForFixtureReady(surfaceID: String) {
        var lastNames: [String] = []
        for _ in 0..<40 {
            let envelope = mcpAppsCallSync(method: "tools/list", paramsJSON: "{}", surfaceID: surfaceID)
            if let result = envelope["result"] as? [String: Any],
               let tools = result["tools"] as? [[String: Any]] {
                lastNames = tools.compactMap { $0["name"] as? String }
                if lastNames.contains("\(Self.fixtureAlias)-show_counter") {
                    XCTAssertFalse(
                        lastNames.contains("\(Self.fixtureAlias)-record_event"),
                        "an app-only tool (record_event) must never be exported to a pane whose surface " +
                        "resolved -- got: \(lastNames)"
                    )
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTFail("\(Self.fixtureAlias)-show_counter never appeared in tools/list within the timeout budget -- last seen: \(lastNames)")
    }

    // MARK: - Settings navigation

    private func openSettingsViaMenu() {
        app.activate()
        Thread.sleep(forTimeInterval: 0.5)
        menuAction("Calyx", item: "Settings…")
    }

    /// Opens Settings and selects the "MCP Apps" toolbar pane
    /// (looked up by label -- no accessibility identifier exists on any
    /// Settings toolbar button in this codebase, see
    /// SettingsWindowE2ETests's own header), returning the Settings
    /// window handle.
    @discardableResult
    func openMCPServersSettingsPane() -> XCUIElement {
        openSettingsViaMenu()
        let settingsWindow = app.windows.firstMatch
        XCTAssertTrue(waitFor(settingsWindow, timeout: 10), "the Settings window never appeared")
        let toolbarButton = settingsWindow.toolbars.buttons["MCP Apps"]
        XCTAssertTrue(waitFor(toolbarButton, timeout: 10), "the Settings toolbar never showed an \"MCP Apps\" item")
        toolbarButton.click()
        return settingsWindow
    }

    // MARK: - Queries used by more than one scenario

    func dockElement(surfaceID: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "calyx.mcpApps.dock.\(surfaceID)").firstMatch
    }

    func anyViewStateLabel() -> XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH 'calyx.mcpApps.view.' AND identifier ENDSWITH '.stateLabel'"
        )).firstMatch
    }

    func anyStandalonePanel() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", Self.standalonePanelPrefix))
            .firstMatch
    }

    func promptContainer() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.promptContainerID).firstMatch
    }

    func promptPrimaryButton() -> XCUIElement {
        app.buttons[Self.promptPrimaryButtonID]
    }
}

// MARK: - Scenarios 1-10: fixture pre-registered

final class MCPAppsE2ETests: MCPAppsE2ETestCaseBase {

    // MARK: 1. show_counter opens the dock; event order is initialize -> initialized -> tool-input -> tool-result

    func test_showCounter_opensDockWithOrderedEventLog() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        XCTAssertFalse(surfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for every ghostty-spawned pane")
        waitForFixtureReady(surfaceID: surfaceID)

        let envelope = mcpAppsCallSync(
            method: "tools/call",
            paramsJSON: toolCallParamsJSON(name: "\(Self.fixtureAlias)-show_counter", argumentsJSON: "{\"action\": \"none\"}"),
            surfaceID: surfaceID, timeoutAttempts: 30
        )
        guard let toolResult = envelope["result"] as? [String: Any] else {
            XCTFail("show_counter produced no result -- got: \(envelope)")
            return
        }
        XCTAssertNil(toolResult["isError"], "show_counter must not report isError -- got: \(envelope)")
        let resourceURI = ((toolResult["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["resourceUri"] as? String
        XCTAssertEqual(
            resourceURI, "ui://\(Self.fixtureAlias)/fixture/counter.html",
            "the tool result's _meta.ui.resourceUri (the fixture's ui://fixture/counter.html) must reach the agent " +
            "exported as ui://<alias>/<upstream host>/... (contract C11) -- got: \(String(describing: resourceURI))"
        )

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertTrue(waitFor(dock, timeout: 20), "the MCP Apps dock never appeared in the calling pane after show_counter")

        let events = waitForEventLog(minCount: 4, timeout: 20)
        let initializedIndex = try XCTUnwrap(events.firstIndex(of: "view:initialized"),
            "the view's own event log never recorded \"view:initialized\" -- got: \(events)")
        let toolInputIndex = try XCTUnwrap(events.firstIndex(of: "host:tool-input"),
            "the view's own event log never recorded \"host:tool-input\" -- got: \(events)")
        let toolResultIndex = try XCTUnwrap(events.firstIndex(of: "host:tool-result"),
            "the view's own event log never recorded \"host:tool-result\" -- got: \(events)")
        XCTAssertLessThan(initializedIndex, toolInputIndex,
            "the view must finish its own initialize/initialized handshake before receiving tool-input -- order: \(events)")
        XCTAssertLessThan(toolInputIndex, toolResultIndex,
            "tool-input must precede tool-result -- order: \(events)")
    }

    // MARK: 2. ui/message shows the consent prompt; Allow delivers to a foreground `cat -u > <file>`

    func test_uiMessage_consentPromptDeliversToForegroundPane() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        XCTAssertFalse(surfaceID.isEmpty)
        waitForFixtureReady(surfaceID: surfaceID)

        // The call is typed as a background job while the pane's shell
        // is still at its prompt: once `cat` holds the foreground below,
        // a typed `sh <script>` line would be read by `cat` instead of
        // run (see this file's header). The job waits for a trigger file
        // the runner creates only after `cat` is in the foreground, so
        // no dock or consent prompt exists (and none can take keyboard
        // focus) while either line is typed. The view's ui/message is
        // delivered when the prompt's button is clicked.
        let callTrigger = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-e2e-mcpapps-message-trigger-\(UUID().uuidString)").path
        guard assertAbsentBeforeCommand(callTrigger) else { return }
        let callOutFile = mcpAppsCallBackgrounded(
            name: "\(Self.fixtureAlias)-show_counter", argumentsJSON: "{\"action\": \"message\"}",
            surfaceID: surfaceID, maxTimeSeconds: 30, startWhenFileExists: callTrigger
        )

        let recvFile = uniqueTmpPath("recv", ext: "txt")
        let catReadyFile = uniqueTmpPath("recv-ready", ext: "txt")
        guard assertAbsentBeforeCommand(recvFile), assertAbsentBeforeCommand(catReadyFile) else { return }
        // `-u`: unbuffered cat, so a single delivered line is flushed to
        // the file immediately instead of sitting in a full stdio
        // buffer until EOF (cat's stdout here is a plain file, not a
        // tty, so it is fully buffered by default). `exec` makes `cat`
        // the pane's foreground process reading the tty; the ready file
        // is written just before it.
        panePasteAndReturn("echo ready > \(catReadyFile) && exec cat -u > \(recvFile)")
        let catReady = waitForFileContent(atPath: catReadyFile, timeoutAttempts: 20)
        XCTAssertEqual(catReady, "ready", "the foreground `cat -u` never started in the calling pane")
        try Data().write(to: URL(fileURLWithPath: callTrigger))

        let callOutput = waitForFileContent(atPath: callOutFile, timeoutAttempts: 60)
        let envelope = callOutput.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertNotNil(envelope?["result"] as? [String: Any], "show_counter produced no result -- got: \(callOutput)")
        XCTAssertNil((envelope?["result"] as? [String: Any])?["isError"], "show_counter must not report isError -- got: \(callOutput)")

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertTrue(waitFor(dock, timeout: 20), "the dock never appeared")

        let prompt = promptContainer()
        XCTAssertTrue(waitFor(prompt, timeout: 15), "the ui/message consent prompt never appeared")

        let primaryButton = promptPrimaryButton()
        XCTAssertTrue(waitFor(primaryButton, timeout: 5), "the consent prompt's primary (send) button never appeared")
        primaryButton.click()

        let received = waitForFileContent(atPath: recvFile, timeoutAttempts: 40)
        XCTAssertTrue(received.contains("hello from view"),
            "accepting the consent prompt must deliver the view's ui/message text into the calling pane's foreground process -- got: \(received.debugDescription)")
    }

    // MARK: 3. Counter state (and the view itself) survives switching to another tab and back

    func test_counterState_survivesTabSwitchAndBack() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        let envelope = mcpAppsCallSync(
            method: "tools/call",
            paramsJSON: toolCallParamsJSON(name: "\(Self.fixtureAlias)-show_counter", argumentsJSON: "{\"action\": \"none\"}"),
            surfaceID: surfaceID, timeoutAttempts: 30
        )
        XCTAssertNil((envelope["result"] as? [String: Any])?["isError"])

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertTrue(waitFor(dock, timeout: 20), "the dock never appeared")

        let eventsBefore = waitForEventLog(minCount: 1, timeout: 15)
        let initializeCountBefore = eventsBefore.filter { $0 == "view:ui/initialize-sent" }.count
        XCTAssertEqual(initializeCountBefore, 1, "expected exactly one initial ui/initialize before switching tabs -- got: \(eventsBefore)")

        createNewTabViaMenu()
        XCTAssertTrue(waitForTabCount(2, timeout: 10), "a new tab never appeared")

        let tabs = tabBarTabsQuery().allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(tabs.count, 2, "expected at least two tabs after creating one")
        tabs[0].click()

        XCTAssertTrue(waitFor(dock, timeout: 15), "the dock never reappeared after switching back to the original tab")

        let eventsAfter = waitForEventLog(minCount: 1, timeout: 5)
        let initializeCountAfter = eventsAfter.filter { $0 == "view:ui/initialize-sent" }.count
        XCTAssertEqual(initializeCountAfter, 1,
            "switching tabs and back must NOT reload the view (no second ui/initialize) -- got: \(eventsAfter)")
    }

    // MARK: 4. Zooming another pane in the same tab hides the dock; unzoom shows it

    func test_zoomingAnotherPane_hidesDock_unzoomShowsIt() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        let envelope = mcpAppsCallSync(
            method: "tools/call",
            paramsJSON: toolCallParamsJSON(name: "\(Self.fixtureAlias)-show_counter", argumentsJSON: "{\"action\": \"none\"}"),
            surfaceID: surfaceID, timeoutAttempts: 30
        )
        XCTAssertNil((envelope["result"] as? [String: Any])?["isError"])

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertTrue(waitFor(dock, timeout: 20), "the dock never appeared")

        let splitResult = legacyIPCCallSync(
            name: "pane_split", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"direction\": \"right\"}"
        )
        XCTAssertNotNil(splitResult["surface_id"] as? String, "pane_split must return the newly created pane's surface_id")

        // Ghostty focuses the newly created split automatically, so the
        // default `toggle_split_zoom` keybinding (Cmd+Shift+Return, see
        // this file's header) below targets that new pane, not the
        // original one carrying the dock.
        Thread.sleep(forTimeInterval: 1)
        app.typeKey(.return, modifierFlags: [.command, .shift])

        waitForNonExistence(dock, timeout: 15)

        app.typeKey(.return, modifierFlags: [.command, .shift])

        XCTAssertTrue(waitFor(dock, timeout: 15), "the dock must reappear once the zoomed sibling pane is unzoomed")
    }

    // MARK: 5. Closing the pane mid-call (slow_tool) removes the dock

    func test_closingPaneDuringSlowTool_removesDock() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        // A sibling pane keeps the tab (and window) alive once the
        // original pane is closed below.
        let splitResult = legacyIPCCallSync(
            name: "pane_split", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"direction\": \"right\"}"
        )
        XCTAssertNotNil(splitResult["surface_id"] as? String)
        Thread.sleep(forTimeInterval: 1)

        mcpAppsCallBackgrounded(
            name: "\(Self.fixtureAlias)-slow_tool", argumentsJSON: "{}", surfaceID: surfaceID, maxTimeSeconds: 60
        )

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertTrue(waitFor(dock, timeout: 20), "the dock never appeared for the in-flight slow_tool call")

        // `pane_split` focuses the new (right) pane, so the original
        // pane is clicked to focus it before plain Cmd+W (closes the
        // FOCUSED PANE, see this file's header). A pane/surface view has
        // no accessibility identifier, so the click is placed relative
        // to the original pane's dock: the dock sits at the right of that
        // pane's terminal, and a point 25 pt left of the dock's left edge
        // is inside that terminal (the dock divider's hit area reaches
        // 4 pt left of the dock; the terminal keeps at least 50 pt). A
        // point relative to the window does not work: the sidebar
        // (220 pt by default) covers the left of the 800 pt window, and
        // 25% of its width (200 pt) is inside the sidebar.
        dock.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: -25, dy: 0))
            .click()
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("w", modifierFlags: .command)

        waitForNonExistence(dock, timeout: 15)
    }

    // MARK: 6. Cancelling the call (killing the client mid-call) reaches the view as tool-cancelled

    func test_cancellingCall_reachesViewAsToolCancelled() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        let marker = "mcpapps-cancel-marker-\(UUID().uuidString)"
        mcpAppsCallBackgrounded(
            name: "\(Self.fixtureAlias)-slow_tool", argumentsJSON: "{}", surfaceID: surfaceID,
            maxTimeSeconds: 60, curlMarker: marker
        )

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertTrue(waitFor(dock, timeout: 20), "the dock never appeared for the in-flight slow_tool call")

        Thread.sleep(forTimeInterval: 2)
        // Kills the curl PROCESS itself (its own argv carries `marker`
        // via `-A`), not the python wrapper around it -- killing the
        // wrapper alone would leave the curl child (and its downstream
        // connection) orphaned and still open.
        panePasteAndReturn("pkill -f \(marker)")

        let events = pollEventLog(until: { $0.contains("host:tool-cancelled") }, timeout: 20)
        XCTAssertTrue(events.contains("host:tool-cancelled"),
            "killing the downstream client mid-call must propagate to the view as ui/notifications/tool-cancelled -- observed: \(events)")
    }

    // MARK: 7. Each malformed resource case shows an error card with a matching reason

    func test_malformedResources_showErrorCardWithMatchingReason() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        let cases: [(tool: String, keyword: String)] = [
            ("show_bad_mime", "MIME"),
            ("show_multi_content", "multiple"),
            ("show_oversized", "large"),
            ("show_bad_base64", "base64"),
            ("show_non_ui_uri", "ui://"),
        ]

        for testCase in cases {
            let envelope = mcpAppsCallSync(
                method: "tools/call",
                paramsJSON: toolCallParamsJSON(name: "\(Self.fixtureAlias)-\(testCase.tool)", argumentsJSON: "{}"),
                surfaceID: surfaceID, timeoutAttempts: 30
            )
            guard let toolResult = envelope["result"] as? [String: Any] else {
                XCTFail("\(testCase.tool) produced no result -- got: \(envelope)")
                continue
            }
            XCTAssertNil(toolResult["isError"],
                "\(testCase.tool)'s own tool result must not carry isError -- the agent's result is independent of the view's state (plan §12) -- got: \(envelope)")

            let stateLabel = anyViewStateLabel()
            XCTAssertTrue(waitFor(stateLabel, timeout: 20), "\(testCase.tool) never produced a view with a stateLabel error card")
            let text = elementText(stateLabel)
            XCTAssertTrue(text.localizedCaseInsensitiveContains(testCase.keyword),
                "\(testCase.tool)'s error card must mention \"\(testCase.keyword)\" -- got: \(text)")
        }
    }

    // MARK: 8. The view's own call to a model-only tool is rejected with -32000

    func test_viewCallToModelOnlyTool_isRejected() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        let envelope = mcpAppsCallSync(
            method: "tools/call",
            paramsJSON: toolCallParamsJSON(name: "\(Self.fixtureAlias)-show_counter", argumentsJSON: "{\"action\": \"call_model_only\"}"),
            surfaceID: surfaceID, timeoutAttempts: 30
        )
        XCTAssertNil((envelope["result"] as? [String: Any])?["isError"])

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertTrue(waitFor(dock, timeout: 20), "the dock never appeared")

        let events = pollEventLog(until: { $0.contains("view:model_only_error:-32000") }, timeout: 20)
        XCTAssertTrue(events.contains("view:model_only_error:-32000"),
            "a view's own tools/call against a model-only tool must be rejected with JSON-RPC code -32000 -- observed: \(events)")
    }

    // MARK: 9. crash takes the Settings row out of ready ("Disconnected" or "Connecting"), then back to ready after auto-restart

    func test_crashingServer_showsDisconnectedThenReadyAfterRestart() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        // Settings is opened and the row located BEFORE the crash: the
        // non-ready window (about 1 s of restart backoff, then the
        // restarted fixture's 5 s sleep and handshake) is shorter than
        // opening Settings takes. The Settings window then has key
        // focus, so the crash call cannot be typed into the pane at that
        // point; it is typed now as a background job that waits for a
        // trigger file the runner creates once the row reads ready. The
        // crash never answers normally, so its output is not read.
        let crashTrigger = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-e2e-mcpapps-crash-trigger-\(UUID().uuidString)").path
        guard assertAbsentBeforeCommand(crashTrigger) else { return }
        mcpAppsCallBackgrounded(
            name: "\(Self.fixtureAlias)-crash", argumentsJSON: "{}", surfaceID: surfaceID,
            maxTimeSeconds: 10, startWhenFileExists: crashTrigger
        )

        let settingsWindow = openMCPServersSettingsPane()
        let statusLabel = settingsWindow.staticTexts["calyx.settings.mcpServers.row.\(serverID).status"]
        XCTAssertTrue(waitFor(statusLabel, timeout: 15), "the MCP Servers row for the fixture server never appeared")

        var sawReadyBeforeCrash = false
        let readyBeforeDeadline = Date().addingTimeInterval(20)
        while Date() < readyBeforeDeadline {
            if elementText(statusLabel).localizedCaseInsensitiveContains("with UI") { sawReadyBeforeCrash = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(sawReadyBeforeCrash,
            "the MCP Servers row must be ready before the crash is issued -- last seen: \(elementText(statusLabel))")

        try Data().write(to: URL(fileURLWithPath: crashTrigger))

        var nonReadyText: String?
        let nonReadyDeadline = Date().addingTimeInterval(25)
        while Date() < nonReadyDeadline {
            let text = elementText(statusLabel)
            if !text.localizedCaseInsensitiveContains("with UI"),
               text.localizedCaseInsensitiveContains("Disconnected") || text.localizedCaseInsensitiveContains("Connecting") {
                nonReadyText = text
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertNotNil(nonReadyText,
            "once the fixture server crashes, the MCP Servers row must leave ready and show \"Disconnected\" or " +
            "\"Connecting\" -- last seen: \(elementText(statusLabel))")

        var sawReady = false
        let readyDeadline = Date().addingTimeInterval(30)
        while Date() < readyDeadline {
            if elementText(statusLabel).localizedCaseInsensitiveContains("with UI") { sawReady = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(sawReady,
            "the MCP Servers row must return to ready once the fixture server auto-restarts -- non-ready text seen: " +
            "\(nonReadyText ?? "(none)"), last seen: \(elementText(statusLabel))")
    }

    // MARK: 10. A call with no surface header opens the independent standalone panel

    func test_callWithNoSurfaceHeader_opensStandalonePanel() throws {
        waitForIPCActivation()
        let surfaceID = mcpPaneExec("echo $CALYX_SURFACE_ID")
        waitForFixtureReady(surfaceID: surfaceID)

        let envelope = mcpAppsCallSync(
            method: "tools/call",
            paramsJSON: toolCallParamsJSON(name: "\(Self.fixtureAlias)-show_counter", argumentsJSON: "{\"action\": \"none\"}"),
            surfaceID: nil, timeoutAttempts: 30
        )
        XCTAssertNil((envelope["result"] as? [String: Any])?["isError"], "got: \(envelope)")

        let dock = dockElement(surfaceID: surfaceID)
        XCTAssertFalse(dock.exists, "a call with no surface header must not attach to any pane's own dock")

        let standalonePanel = anyStandalonePanel()
        XCTAssertTrue(waitFor(standalonePanel, timeout: 20),
            "a call with no surface header and no UI-extension declaration must open an independent standalone panel")
    }
}

// MARK: - Scenario 11: Settings > MCP Servers

/// Starts with ZERO registered servers (the empty state), then walks
/// add -> import -> remove -> config-error-banner through the Settings
/// UI itself.
final class MCPAppsSettingsE2ETests: MCPAppsE2ETestCaseBase {

    override var preregistersFixture: Bool { false }

    func test_settingsMCPServers_emptyStateAddImportRemoveAndConfigErrorBanner() throws {
        waitForIPCActivation()
        let settingsWindow = openMCPServersSettingsPane()

        let emptyState = app.descendants(matching: .any).matching(identifier: "calyx.settings.mcpServers.emptyState").firstMatch
        XCTAssertTrue(waitFor(emptyState, timeout: 10), "with zero registered servers, the empty state must be shown")

        let addButton = settingsWindow.descendants(matching: .any).matching(identifier: "calyx.settings.mcpServers.addButton").firstMatch
        XCTAssertTrue(waitFor(addButton, timeout: 5), "the empty state's Add Server button never appeared")
        addButton.click()

        let nameField = app.textFields["calyx.settings.mcpServers.editor.nameField"]
        XCTAssertTrue(waitFor(nameField, timeout: 10), "the add-server editor sheet never appeared")
        nameField.click()
        nameField.typeText("E2E Manual Server")

        // The alias field already holds the alias derived from the name;
        // replace it.
        let aliasField = app.textFields["calyx.settings.mcpServers.editor.aliasField"]
        XCTAssertTrue(waitFor(aliasField, timeout: 5))
        aliasField.click()
        aliasField.typeKey("a", modifierFlags: .command)
        aliasField.typeText("manual")

        let commandField = app.textFields["calyx.settings.mcpServers.editor.commandField"]
        XCTAssertTrue(waitFor(commandField, timeout: 5))
        commandField.click()
        commandField.typeText("/usr/bin/python3")

        let saveButton = app.buttons["calyx.settings.mcpServers.editor.saveButton"]
        XCTAssertTrue(waitFor(saveButton, timeout: 5), "the editor sheet's Save button never appeared")
        saveButton.click()

        let list = app.descendants(matching: .any).matching(identifier: "calyx.settings.mcpServers.list").firstMatch
        XCTAssertTrue(waitFor(list, timeout: 10), "the server list must appear once at least one server is registered")
        XCTAssertFalse(emptyState.exists, "the empty state must be gone once a server is registered")

        let rowStatusQuery = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'calyx.settings.mcpServers.row.' AND identifier ENDSWITH '.status'"
        ))
        XCTAssertEqual(waitForCount({ rowStatusQuery.count }, toEqual: 1, timeout: 15), 1,
            "after saving the manually-added server, exactly one row must exist")

        // Import a second server via pasted JSON.
        let importButton = app.buttons["calyx.settings.mcpServers.importButton"]
        XCTAssertTrue(waitFor(importButton, timeout: 5), "the Import JSON button never appeared")
        importButton.click()

        let importTextView = app.textViews["calyx.settings.mcpServers.import.textView"]
        XCTAssertTrue(waitFor(importTextView, timeout: 10), "the JSON import sheet never appeared")
        importTextView.click()
        importTextView.typeText(
            "{\"mcpServers\": {\"imported\": {\"command\": \"/usr/bin/python3\", \"args\": [\"--version\"]}}}"
        )

        let importPreview = app.descendants(matching: .any).matching(identifier: "calyx.settings.mcpServers.import.preview").firstMatch
        XCTAssertTrue(waitFor(importPreview, timeout: 10), "the import sheet never showed a preview of the parsed server")

        let importConfirm = app.buttons["calyx.settings.mcpServers.import.confirmButton"]
        XCTAssertTrue(waitFor(importConfirm, timeout: 5), "the import sheet's confirm button never appeared")
        importConfirm.click()

        XCTAssertEqual(waitForCount({ rowStatusQuery.count }, toEqual: 2, timeout: 15), 2,
            "after adding one server manually and importing one more, exactly two rows must exist")

        // Remove one server.
        let removeButtonQuery = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'calyx.settings.mcpServers.row.' AND identifier ENDSWITH '.removeButton'"
        ))
        XCTAssertGreaterThan(removeButtonQuery.count, 0, "no row exposed a removeButton")
        removeButtonQuery.firstMatch.click()

        XCTAssertEqual(waitForCount({ rowStatusQuery.count }, toEqual: 1, timeout: 15), 1,
            "removing one server must leave exactly one row")

        // Corrupt the scoped mcp-servers.json and relaunch to observe
        // the config error banner (mirrors DemoRecordingScenario's own
        // established `app.terminate()` + `app.launch()` mid-test
        // relaunch idiom -- this launch reuses the SAME
        // `additionalLaunchArguments`/`--calyx-path-root`, since
        // `XCUIApplication.launchArguments` was already captured once
        // by the base class's own `setUp()`).
        writeCorruptMCPServersConfig()
        app.terminate()
        app.launch()
        waitForIPCActivation()
        _ = openMCPServersSettingsPane()

        let configErrorBanner = app.descendants(matching: .any).matching(identifier: "calyx.settings.mcpServers.configErrorBanner").firstMatch
        XCTAssertTrue(waitFor(configErrorBanner, timeout: 15),
            "a corrupt scoped mcp-servers.json must show the config error banner in Settings after relaunch")
    }
}
