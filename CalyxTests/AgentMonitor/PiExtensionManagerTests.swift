//
//  PiExtensionManagerTests.swift
//  CalyxTests
//
//  Installs and removes `<agent root>/extensions/calyx.ts`, the
//  TypeScript extension pi auto-loads from `~/.pi/agent/extensions/`
//  with no settings edit required.
//
//  pi has neither an MCP client configuration file nor a hook system, so
//  this single file is the entire integration: the row-state pings, the
//  synchronous approval gate, and the MCP tool bridge all live in it.
//  That makes the scriptBody pins below the real contract surface, not
//  decoration: every fact they hold was measured against pi 0.74.2, and
//  a silent drift in any of them produces a pi pane Calyx either cannot
//  see or cannot gate.
//
//  Coverage:
//  - install creates the `extensions/` directory and writes scriptBody
//    verbatim, overwriting idempotently on reinstall; remove deletes it
//    (and throws when an existing file cannot be deleted); isInstalled
//    reflects install state; a symlinked destination is followed to its
//    real file and the link itself survives both operations
//  - scriptBody invariants: the `pi` agent-kind header, the herdr branch
//    (registers only the `calyx_mcp` dispatcher, nothing else) and the
//    pane-identity guard (registers nothing at all) each firing before
//    the lifecycle handlers and the original `calyx` dispatcher, the
//    five pi lifecycle events mapped onto the canonical hook event
//    vocabulary, the canonical snake_case state ping, the approval
//    request's PermissionRequest envelope and its timeout derived from
//    ApprovalHookTiming, the two dispatcher tools (`calyx` for
//    calyx-ipc, `calyx_mcp` for /calyx-mcp), the block path taken only
//    on an explicit deny, the session id read from
//    sessionManager.getSessionId(), and the mtime-cached endpoint read
//    through node:fs/promises
//  - AgentToolPaths.piConfigDirectory points at pi's agent root
//
//  Every call here passes an explicit temporary `extensionsDirectory`.
//  A bare `install()` / `remove()` would write to (or delete from) the
//  developer's own `~/.pi/agent/extensions/`.
//

import XCTest
@testable import Calyx

final class PiExtensionManagerTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    /// Passed as `extensionsDirectory:`: pi's agent root (`~/.pi/agent`
    /// in production), not the `extensions/` directory itself. install()/
    /// remove()/isInstalled() operate on `<this>/extensions/calyx.ts`,
    /// mirroring `OpenCodePluginManager`'s `pluginsDirectory:`.
    private var agentRoot: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        agentRoot = tempDir + "/pi-agent"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private var expectedExtensionPath: String {
        agentRoot + "/extensions/calyx.ts"
    }

    /// `scriptBody` with its `//` comment lines and all whitespace
    /// removed. Dropping comment lines keeps a pin from being satisfied
    /// by prose that merely describes the behavior, and dropping
    /// whitespace keeps every pin insensitive to the formatting the
    /// extension happens to use.
    private var scriptCode: String {
        PiExtensionManager.scriptBody
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
            .joined()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\t", with: "")
    }

    private func assertScriptContains(
        _ needle: String, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(scriptCode.contains(needle), "\(message) [missing: \(needle)]", file: file, line: line)
    }

    private func occurrences(of needle: String) -> Int {
        scriptCode.components(separatedBy: needle).count - 1
    }

    /// Asserts `needle` appears in the code near `anchor`, so a pin tied
    /// to one specific request cannot be satisfied by an unrelated one
    /// elsewhere in the file.
    private func assertScript(
        _ needle: String,
        appearsNear anchor: String,
        charsBefore: Int = 600,
        charsAfter: Int = 1200,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let code = scriptCode
        guard let anchorRange = code.range(of: anchor) else {
            XCTFail("\(message) [anchor never appears: \(anchor)]", file: file, line: line)
            return
        }
        let start = code.index(anchorRange.lowerBound, offsetBy: -charsBefore, limitedBy: code.startIndex)
            ?? code.startIndex
        let end = code.index(anchorRange.upperBound, offsetBy: charsAfter, limitedBy: code.endIndex)
            ?? code.endIndex
        XCTAssertTrue(code[start..<end].contains(needle),
                      "\(message) [\(needle) not found near \(anchor)]", file: file, line: line)
    }

    /// Asserts `piEvent` maps to `hookEventName` within the same mapping
    /// entry, without pinning object-literal versus switch syntax, and
    /// without requiring the map's keys to be quoted (they are all valid
    /// JavaScript identifiers, so an implementation may write them bare).
    /// The earliest of the three spellings is used deliberately: the
    /// event map sits above the handlers, so the first occurrence of an
    /// event name is its mapping entry rather than a later
    /// `pi.on("...")` registration.
    private func assertMapping(
        _ piEvent: String,
        mapsTo hookEventName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let body = PiExtensionManager.scriptBody
        let candidates = ["\"\(piEvent)\"", "'\(piEvent)'", "\(piEvent):"]
            .compactMap { body.range(of: $0) }
        guard let keyRange = candidates.min(by: { $0.lowerBound < $1.lowerBound }) else {
            XCTFail("scriptBody must reference pi's \(piEvent) event", file: file, line: line)
            return
        }
        let windowEnd = body.index(keyRange.upperBound, offsetBy: 200, limitedBy: body.endIndex) ?? body.endIndex
        XCTAssertTrue(body[keyRange.upperBound..<windowEnd].contains(hookEventName),
                      "pi's \(piEvent) must map to hook_event_name \(hookEventName) within its mapping entry",
                      file: file, line: line)
    }

    // MARK: - install()

    func test_install_createsExtensionsDirectoryAndWritesScriptBodyExactly() throws {
        let path = try PiExtensionManager.install(extensionsDirectory: agentRoot)

        XCTAssertEqual(path, expectedExtensionPath, "install() must return the extension's absolute path")

        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: agentRoot + "/extensions", isDirectory: &isDir),
                      "install() must create the extensions/ directory pi auto-discovers from")
        XCTAssertTrue(isDir.boolValue)

        guard FileManager.default.fileExists(atPath: path) else {
            XCTFail("install() must write the extension file at the path it returns")
            return
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(content, PiExtensionManager.scriptBody,
                       "Installed extension content must match scriptBody exactly")
    }

    func test_install_reinstall_overwritesIdempotently() throws {
        let firstPath = try PiExtensionManager.install(extensionsDirectory: agentRoot)
        guard FileManager.default.fileExists(atPath: firstPath) else {
            XCTFail("Precondition: install must have written the extension, it returned \(firstPath)")
            return
        }
        try "stale content from a previous version".write(toFile: firstPath, atomically: true, encoding: .utf8)

        let secondPath = try PiExtensionManager.install(extensionsDirectory: agentRoot)

        XCTAssertEqual(firstPath, secondPath, "install() must return the same path on reinstall")
        let content = try String(contentsOfFile: secondPath, encoding: .utf8)
        XCTAssertEqual(content, PiExtensionManager.scriptBody,
                       "Reinstalling must overwrite stale content with the current scriptBody")
    }

    func test_piConfigDirectory_isPisAgentRootRatherThanTheDotPiRoot() {
        XCTAssertTrue(AgentToolPaths.piConfigDirectory.hasSuffix("/.pi/agent"),
                       "The path reaches down to agent because ~/.pi alone is not evidence of an " +
                       "installed pi, and the extensions/ directory install() writes into lives " +
                       "directly under the agent root")
    }

    func test_piConfigDirectory_productionRoot_resolvesAgainstRealHome() {
        XCTAssertEqual(AgentToolPaths.piConfigDirectory(testRoot: nil), NSHomeDirectory() + "/.pi/agent",
                       "With no CalyxPathRoot.testRoot override, piConfigDirectory must resolve to exactly " +
                       "the same string production has always used")
    }

    // MARK: - scriptBody invariants

    func test_scriptBody_sendsAgentKindHeaderAsPi() {
        assertScriptContains("\"X-Calyx-Agent-Kind\":\"pi\"",
                             "Every request must identify the CLI as pi. Without the header the server " +
                             "defaults the kind to claude-code, so a pi pane would report a Claude Code " +
                             "row and the approval endpoint would answer in the wrong vocabulary")
        assertScriptContains("\"X-Calyx-Surface-ID\":",
                             "Every request must name the pane it came from, or the server cannot bind " +
                             "the row to a surface")
    }

    // Anchored on the guard CONDITION itself (`!calyxPaneID`), not on the
    // `calyxPaneID` declaration line: inside herdr the herdr branch (its
    // own dispatcher registration and `return`) sits BEFORE this guard in
    // the script (see the herdr test below), so the first
    // `pi.on(`/`pi.registerTool(` call in the WHOLE script is no longer a
    // reliable anchor for "nothing registered before the identity check".
    // What must still hold is narrower and still real: the ORIGINAL
    // lifecycle handler (`pi.on(`) and the original `"calyx"` dispatcher
    // (exact `name:"calyx"`, never matching the longer `name:"calyx_mcp"`)
    // must never be registered before this guard's own `return`.
    func test_scriptBody_guardsOnPaneIdentityBeforeRegisteringLifecycleAndTheCalyxDispatcher() {
        assertScriptContains("process.env.CALYX_SESSION_ID||process.env.CALYX_SURFACE_ID",
                             "A persistent pane's CALYX_SESSION_ID stays stable across surface changes, " +
                             "so it is preferred over the launch-time surface UUID. The || fallback also " +
                             "treats an empty string as absent, which ?? would not")
        assertScriptContains("!calyxPaneID",
                             "scriptBody must guard on the absence of a resolved pane identity")

        let code = scriptCode
        guard let guardConditionRange = code.range(of: "!calyxPaneID") else {
            XCTFail("scriptBody must read !calyxPaneID as its no-pane-identity guard condition")
            return
        }
        guard let guardReturn = code.range(of: "return", range: guardConditionRange.upperBound..<code.endIndex) else {
            XCTFail("The pane-identity guard must return")
            return
        }
        let firstLifecycleOrCalyxDispatcherRegistration = [
            code.range(of: "pi.on("),
            code.range(of: "name:\"calyx\""),
        ].compactMap { $0?.lowerBound }.min()
        guard let firstLifecycleOrCalyxDispatcherRegistration else {
            XCTFail("scriptBody must register at least one pi.on() handler and the \"calyx\" dispatcher")
            return
        }
        XCTAssertTrue(guardReturn.upperBound <= firstLifecycleOrCalyxDispatcherRegistration,
                      "The no-pane-identity guard must return BEFORE the first pi.on() lifecycle handler " +
                      "or the \"calyx\" dispatcher registers. Registering first and checking later would " +
                      "leave a pi started outside Calyx carrying a live approval gate that blocks on a " +
                      "server nobody is running")
    }

    // Inside herdr, the pane's own lifecycle/approval-gate identity is
    // already mirrored into Calyx by herdr itself, so only the calyx_mcp
    // dispatcher (the new /calyx-mcp bridge, guarded to fail open when
    // Calyx is unreachable) is registered there -- no pi.on() lifecycle
    // handler, no approval gate, and not the original "calyx" dispatcher
    // either.
    func test_scriptBody_insideHerdr_registersOnlyTheCalyxMCPDispatcher() {
        assertScriptContains("process.env.HERDR_PANE_ID",
                             "A pi running inside a herdr pane is mirrored into Calyx by herdr itself, so " +
                             "only the calyx_mcp dispatcher registers there")

        let code = scriptCode
        guard let herdrRange = code.range(of: "HERDR_PANE_ID") else {
            XCTFail("scriptBody must read HERDR_PANE_ID")
            return
        }
        guard let herdrDispatcherRegistration = code.range(
            of: "name:\"calyx_mcp\"", range: herdrRange.upperBound..<code.endIndex
        ) else {
            XCTFail("Inside herdr, scriptBody must register the calyx_mcp dispatcher")
            return
        }
        guard let herdrGuardReturn = code.range(
            of: "return", range: herdrDispatcherRegistration.upperBound..<code.endIndex
        ) else {
            XCTFail("The herdr branch must return after registering only the calyx_mcp dispatcher")
            return
        }
        let anyOtherRegistrationInHerdrBranch = [
            code.range(of: "pi.on(", range: herdrRange.upperBound..<herdrGuardReturn.lowerBound),
            code.range(of: "name:\"calyx\"", range: herdrRange.upperBound..<herdrGuardReturn.lowerBound),
        ].compactMap { $0 }
        XCTAssertTrue(anyOtherRegistrationInHerdrBranch.isEmpty,
                      "The herdr branch must register nothing but the calyx_mcp dispatcher before " +
                      "returning -- no lifecycle pi.on() handler, no approval gate, and not the " +
                      "original \"calyx\" dispatcher")
    }

    func test_scriptBody_mapsPiLifecycleEventsToCanonicalHookEventNames() {
        assertMapping("session_start", mapsTo: "SessionStart")
        assertMapping("before_agent_start", mapsTo: "UserPromptSubmit")
        assertMapping("tool_execution_end", mapsTo: "PostToolUse")
        assertMapping("agent_end", mapsTo: "Stop")
        assertMapping("session_shutdown", mapsTo: "SessionEnd")
    }

    func test_scriptBody_postsCanonicalSnakeCaseStatePings() {
        assertScriptContains("/agent-event",
                             "Row state reaches Calyx through the agent event endpoint")
        assertScriptContains("hook_event_name:",
                             "The ping must use the canonical snake_case field AgentEvent.decode already " +
                             "reads, so pi needs no decoder branch of its own")
        assertScriptContains("session_id:",
                             "The session id lets a later reattach offer to resume this conversation")
        assertScriptContains("cwd:",
                             "The row shows the working directory the agent is running in")
    }

    func test_scriptBody_readsSessionIDFromTheSessionManager() {
        assertScriptContains(".sessionManager.getSessionId()",
                             "pi puts no session id in any event payload. getSessionId() returns a plain " +
                             "string in both session modes")
        XCTAssertFalse(PiExtensionManager.scriptBody.contains("getSessionFile"),
                       "getSessionFile() returns undefined under --no-session, so deriving the id from " +
                       "its basename yields no id at all for a session started that way")
    }

    func test_scriptBody_readsEndpointFileThroughNodeAndCachesItByMtime() {
        assertScriptContains("agent-endpoint.json",
                             "Port and token are read from the endpoint file, so a Calyx restart or a " +
                             "token rotation is picked up without reinstalling the extension")
        assertScriptContains("node:fs/promises",
                             "pi loads extensions in Node through jiti")
        assertScriptContains("readFile",
                             "The endpoint file is read with Node's own file API")
        assertScriptContains("mtimeMs",
                             "The endpoint file's mtime is what decides whether it must be re-parsed")
        assertScriptContains("cachedEndpoint",
                             "The parsed endpoint is cached across events rather than re-read per event")
        XCTAssertFalse(PiExtensionManager.scriptBody.contains("Bun."),
                       "Bun's globals do not exist in pi's Node runtime, so a Bun API would throw on the " +
                       "first event and take every ping with it")
    }

    func test_scriptBody_readsEndpointPathFromCalyxEndpointFileWithLiteralFallback() {
        let needle = ("process.env.CALYX_ENDPOINT_FILE ?? \(AgentEndpointFile.javascriptFallbackPathExpression)")
            .replacingOccurrences(of: " ", with: "")
        assertScriptContains(
            needle,
            "Extension must read CALYX_ENDPOINT_FILE (injected by GhosttySurfaceController, scoped to " +
            "wherever Calyx actually wrote agent-endpoint.json), falling back to the literal " +
            "process.env.HOME-relative path for a pane launched before that injection existed"
        )
    }

    func test_scriptBody_usesBothTheAgentEventAndApprovalRequestEndpoints() {
        assertScriptContains("/agent-event", "State pings go to the agent event endpoint")
        assertScriptContains("/approval-request",
                             "The approval gate blocks on the approval endpoint. pi ships no permission " +
                             "prompt of its own, so this request is the only thing that can stop a tool " +
                             "call")
    }

    func test_scriptBody_approvalRequestUsesThePermissionRequestEnvelope() {
        assertScriptContains("hook_event_name:\"\(ApprovalHookEvent.name)\"",
                             "The approval request must name the event Calyx's gate answers for. A " +
                             "payload naming anything else short-circuits to an empty body and the gate " +
                             "is silently inert")
        assertScript("tool_name:", appearsNear: "/approval-request",
                     "AgentHookToolCall reads the tool name from tool_name. A payload without it is " +
                     "rejected outright, so no banner ever appears")
        assertScript("tool_input:", appearsNear: "/approval-request",
                     "The banner shows the human what they are approving, which comes from tool_input")
    }

    func test_scriptBody_approvalRequestTimeoutMatchesTheCurlTimeoutConstant() {
        let expectedTimeout = "AbortSignal.timeout(\(ApprovalHookTiming.curlTimeoutSeconds * 1000))"

        assertScriptContains(expectedTimeout,
                             "The gate's client deadline is ApprovalHookTiming.curlTimeoutSeconds " +
                             "expressed in milliseconds, interpolated from the constant rather than " +
                             "written out, so the nesting invariant that constant exists to enforce " +
                             "cannot drift here. A measured 600 second block survives pi untouched, so " +
                             "the server's own long poll always answers first")
        assertScript(expectedTimeout, appearsNear: "/approval-request",
                     "This deadline belongs to the approval fetch. The state ping has its own much " +
                     "shorter one, and swapping the two would either kill the gate early or hang a ping " +
                     "for ten minutes")
    }

    func test_scriptBody_blocksOnlyOnAnExplicitDeny() {
        assertScriptContains("block:true",
                             "A blocked tool call is the only mechanism pi offers for refusing one, and " +
                             "the reason travels to the model as the tool result content")
        XCTAssertEqual(occurrences(of: "block:true"), 1,
                       "Exactly one path may block. An allow, an empty body, a refused connection and a " +
                       "timeout all leave the call alone: a second blocking path would turn an " +
                       "unreachable Calyx into a pi that cannot run any tool at all")

        let code = scriptCode
        guard let denyRange = code.range(of: "\"deny\"") else {
            XCTFail("scriptBody must compare the server's decision against deny")
            return
        }
        let windowEnd = code.index(denyRange.upperBound, offsetBy: 200, limitedBy: code.endIndex) ?? code.endIndex
        XCTAssertTrue(code[denyRange.upperBound..<windowEnd].contains("block:true"),
                      "The block must be reached from the deny comparison itself, so no other outcome " +
                      "can take that branch")
    }

    // Exactly 2, counted across the WHOLE script: the herdr branch and
    // the non-herdr branch both register calyx_mcp, so a literal
    // `pi.registerTool({name:"calyx_mcp",...})` call site inlined into
    // both branches would make this 3. A single `registerCalyxMCP(pi)`
    // helper function, called once from each branch, is what keeps this
    // at 2 while still registering calyx_mcp inside herdr.
    func test_scriptBody_registersExactlyTwoDispatcherTools() {
        XCTAssertEqual(occurrences(of: "pi.registerTool("), 2,
                       "Two dispatchers: the original \"calyx\" (calyx-ipc) bridge, and the new " +
                       "\"calyx_mcp\" (/calyx-mcp) bridge. Registering every re-published tool " +
                       "individually would put each one's name and description into pi's system prompt " +
                       "on every turn")
        assertScriptContains("name:\"calyx\"",
                             "The dispatcher's name is what the model calls")
        assertScriptContains("required:[\"tool\"]",
                             "The dispatcher takes {tool, args}: the tool to run is mandatory. pi " +
                             "validates arguments against this schema before the call reaches the " +
                             "extension at all")
        assertScriptContains("args:{",
                             "The dispatched tool's own arguments ride in args")
    }

    // MARK: - calyx_mcp dispatcher (/calyx-mcp bridge)

    func test_scriptBody_calyxMCPDispatcher_bridgesTheCalyxMCPEndpoint() {
        assertScriptContains("name:\"calyx_mcp\"",
                             "The second dispatcher's name is what the model calls to reach the " +
                             "re-published MCP-Apps tools")
        assertScriptContains("/calyx-mcp",
                             "The calyx_mcp dispatcher must bridge the /calyx-mcp path, not /mcp")
    }

    func test_scriptBody_calyxMCPDispatcher_sendsHerdrHeaders() {
        assertScript("X-Calyx-Herdr-Pane-ID", appearsNear: "/calyx-mcp",
                     "The calyx_mcp dispatcher must identify its herdr pane so CalyxMCPServer's " +
                     "herdr-first pane resolution can bind it to a surface")
        assertScript("X-Calyx-Herdr-Socket-Path", appearsNear: "/calyx-mcp",
                     "The calyx_mcp dispatcher must also send the herdr socket-path header")
        assertScriptContains("HERDR_PANE_ID",
                             "The herdr pane header's value is read from process.env.HERDR_PANE_ID")
    }

    // The dispatcher must fail open: an unreachable Calyx (or an
    // endpoint file that doesn't exist yet) must never throw all the way
    // out to pi and block the model's tool call -- same fail-open
    // contract as postState/callCalyx's own try/catch above.
    func test_scriptBody_calyxMCPDispatcher_failsOpenWhenEndpointUnreachable() {
        let code = scriptCode
        guard let dispatcherRange = code.range(of: "name:\"calyx_mcp\"") else {
            XCTFail("scriptBody must register the calyx_mcp dispatcher")
            return
        }
        let windowEnd = code.index(dispatcherRange.upperBound, offsetBy: 1200, limitedBy: code.endIndex) ?? code.endIndex
        XCTAssertTrue(code[dispatcherRange.upperBound..<windowEnd].contains("catch"),
                      "The calyx_mcp dispatcher's execute body must catch a failed fetch/endpoint-read " +
                      "rather than letting it throw uncaught, so an unreachable Calyx fails open instead " +
                      "of blocking the tool call")
    }

    func test_scriptBody_declaresDispatcherParametersAsPlainJSONSchema() {
        assertScriptContains("type:\"object\"",
                             "pi.registerTool accepts a plain JSON Schema object for parameters, and " +
                             "enforces it")
        XCTAssertFalse(PiExtensionManager.scriptBody.contains("typebox"),
                       "A TypeBox import would add a dependency the extension does not need: a plain " +
                       "JSON Schema object is accepted and validated as-is")
    }

    func test_scriptBody_bridgesCalyxIPCThroughTheMCPEndpoint() {
        assertScriptContains("/mcp",
                             "The dispatcher proxies to Calyx's MCP endpoint")
        assertScriptContains("\"initialize\"",
                             "A single initialize on session start is what gives the row its MCP " +
                             "connection presence and binds the surface to a peer, which is what lights " +
                             "the unread badge")
        assertScriptContains("\"tools/list\"",
                             "The dispatcher's list request enumerates the tools available to the model")
        assertScriptContains("\"tools/call\"",
                             "Every other dispatch is proxied as a tools/call")
    }

    // MARK: - remove()

    func test_remove_missingFileIsNoop_andDeletesAnInstalledExtension() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedExtensionPath))
        XCTAssertNoThrow(try PiExtensionManager.remove(extensionsDirectory: agentRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedExtensionPath))

        let installedPath = try PiExtensionManager.install(extensionsDirectory: agentRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedPath),
                      "Precondition: install must have written the extension")

        try PiExtensionManager.remove(extensionsDirectory: agentRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: installedPath),
                       "remove() must delete the installed extension")
    }

    func test_remove_fileExistsButDeletionFails_throws() throws {
        // Deleting a file needs write permission on its containing
        // directory, not on the file. Stripping write from extensions/
        // while keeping read and execute stands in for any "exists but
        // cannot be deleted" failure, which must surface as a thrown
        // error rather than being swallowed.
        let extensionsDir = agentRoot + "/extensions"
        _ = try PiExtensionManager.install(extensionsDirectory: agentRoot)
        guard FileManager.default.fileExists(atPath: expectedExtensionPath) else {
            XCTFail("Precondition: install must have written the extension at \(expectedExtensionPath)")
            return
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: extensionsDir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: extensionsDir)
        }

        XCTAssertThrowsError(try PiExtensionManager.remove(extensionsDirectory: agentRoot),
                             "remove() must throw when the extension file exists but cannot be deleted")
    }

    // MARK: - isInstalled()

    func test_isInstalled_reflectsInstallState() throws {
        XCTAssertFalse(PiExtensionManager.isInstalled(extensionsDirectory: agentRoot),
                       "Nothing installed yet, so it must not be reported as installed")

        _ = try PiExtensionManager.install(extensionsDirectory: agentRoot)

        XCTAssertTrue(PiExtensionManager.isInstalled(extensionsDirectory: agentRoot),
                      "After install, must be reported as installed")

        try PiExtensionManager.remove(extensionsDirectory: agentRoot)

        XCTAssertFalse(PiExtensionManager.isInstalled(extensionsDirectory: agentRoot),
                       "After remove, must no longer be reported as installed")
    }

    // MARK: - Symlinked destinations

    // A dotfiles-managed pi agent root can legitimately symlink its
    // extensions/ directory, or an individual extension file, elsewhere.
    // install() follows the link and overwrites the real target, leaving
    // the link itself intact, and remove() resolves the same way: for a
    // symlinked destination, deleting the raw path would unlink the
    // symlink and orphan the real installed file.

    func test_install_symlinkAtDestinationPath_followsAndOverwritesRealFileKeepingLinkIntact() throws {
        let extensionsDir = agentRoot + "/extensions"
        try FileManager.default.createDirectory(atPath: extensionsDir, withIntermediateDirectories: true)
        let realFile = tempDir + "/real_extension.ts"
        FileManager.default.createFile(atPath: realFile, contents: Data("// stale content".utf8))
        let destinationPath = extensionsDir + "/calyx.ts"
        try FileManager.default.createSymbolicLink(atPath: destinationPath, withDestinationPath: realFile)

        _ = try PiExtensionManager.install(extensionsDirectory: agentRoot)

        let realContent = try String(contentsOfFile: realFile, encoding: .utf8)
        XCTAssertEqual(realContent, PiExtensionManager.scriptBody,
                       "install() must overwrite the real file reached through the symlink")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: destinationPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at the destination path must survive the install")
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: destinationPath)
        XCTAssertEqual(destination, realFile)
    }

    func test_remove_symlinkAtDestinationPath_removesRealFileKeepingLinkIntact() throws {
        let extensionsDir = agentRoot + "/extensions"
        try FileManager.default.createDirectory(atPath: extensionsDir, withIntermediateDirectories: true)
        let realFile = tempDir + "/real_extension.ts"
        FileManager.default.createFile(atPath: realFile, contents: Data("// installed body".utf8))
        let destinationPath = extensionsDir + "/calyx.ts"
        try FileManager.default.createSymbolicLink(atPath: destinationPath, withDestinationPath: realFile)

        try PiExtensionManager.remove(extensionsDirectory: agentRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: realFile),
                       "remove() must delete the real file reached through the symlink, not orphan it")

        let attrsAfter = try FileManager.default.attributesOfItem(atPath: destinationPath)
        XCTAssertEqual(attrsAfter[.type] as? FileAttributeType, .typeSymbolicLink,
                       "The symlink at the destination path must survive remove(), now dangling")
    }
}
