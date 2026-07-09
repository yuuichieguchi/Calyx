//
//  MCPCockpitBridgeTests.swift
//  CalyxTests
//
//  Covers all 6 of MCPCockpitBridge's tools: the 3 ungated ones
//  (pane_list, pane_split, tab_create, P4) and the 3 human-approval
//  gated ones (pane_run, pane_send_keys, palette_execute, P5). Drives
//  handleToolCall(name:arguments:) directly against a fake
//  CockpitAppAccessing + a fresh, isolated SessionSurfaceMap (no
//  CalyxMCPServer / HTTP layer involved).
//
//  Coverage:
//  - toolNames and tools stay in sync (Set(tools.map(\.name)) == toolNames)
//  - pane_list: two panes (one fully-populated, one with every optional
//    field nil) serialize with snake_case keys; absent optional fields
//    (title/cwd/agent_kind/calyx_session_id) are OMITTED entirely, not
//    serialized as null
//  - pane_split: "right"/"down" map to SplitDirection .horizontal/
//    .vertical, response echoes {surface_id, direction}; an invalid
//    direction, a missing surface_id, an unresolvable surface_id, and a
//    propagated CockpitAccessError.paneNotFound all raise the matching
//    MCPCockpitBridgeError case; a calyx-session-ID surface_id resolves
//    via SessionSurfaceMap before reaching access.splitPane
//  - tab_create: no args passes (nil, nil) through; group_name/cwd pass
//    through when given; a "~" cwd is tilde-expanded to an absolute
//    path BEFORE validation/access; a cwd that isn't an existing
//    directory is rejected as .invalidArgument BEFORE ever calling
//    access.createTab; a blank cwd or group_name (empty or
//    whitespace/newline-only) is rejected as .invalidArgument rather
//    than silently falling back; a trailing-newline cwd is trimmed
//    before validation/use, and a group_name with surrounding
//    whitespace is trimmed before use (P4 review F1/F2/F3)
//  - an unrecognized tool name raises .unknownTool, distinguished from
//    a stub that blanket-throws unknownTool for every name (see
//    test_unknownTool_throws for how)
//
//  NOT covered (per team-lead scope): a "rejects unexpected extra
//  arguments" test -- MCPCommandLogBridge.handleListCommands only reads
//  its own known keys and silently ignores anything else present in
//  `arguments`; mirroring that (not adding a stricter rejection this
//  bridge alone would enforce).
//
//  Gated tools (pane_run / pane_send_keys / palette_execute, P5):
//  - pane_run: a dead surface_id (access.paneExists false) fails fast
//    with .paneNotFound BEFORE ever reaching the approval gate; default
//    policy submits an ApprovalRequest and waits; .allowed executes via
//    access.sendCommand with doubleReturn decided by whether the target
//    surface has an AgentRegistry entry (RETURN MECHANICS ONLY -- an
//    agent pane still requires approval, no exception); auto-approve on
//    skips the submit entirely; .denied returns {"status":"denied"}
//    without executing; the approval wait itself timing out returns
//    {"status":"approval_timeout"} without executing; a non-Bool
//    `await` (including an NSNumber 0/1 and the string "true") is
//    rejected; `await: true` correlates to the command THIS call
//    started (start-time correlated via
//    CommandLogStore.awaitNextCompletion, immune to latching onto an
//    older already-running command) -- against a surface with nothing
//    tracked it still executes but returns {"status":"timeout"};
//    against a tracked, later-finishing command it returns the full
//    finished record
//  - pane_send_keys: a dead surface_id fails fast with .paneNotFound
//    BEFORE the gate, same as pane_run; text is sent verbatim (no
//    synthetic Return), and an empty string is a valid (accepted, not
//    rejected) payload
//  - palette_execute: an unknown command_id lists every currently
//    AVAILABLE command id, sorted; an available-but-unavailable
//    (isAvailable == false) command is rejected BEFORE ever reaching
//    the approval gate; availability is RE-CHECKED after approval
//    (state can shift during the human's wait); the gated,
//    now-still-available happy path executes and returns
//    {"status":"executed"}
//

import XCTest
@testable import Calyx

// MARK: - Fakes

@MainActor
private final class FakeCockpitAccess: CockpitAppAccessing {
    var panes: [CockpitPaneInfo] = []
    var paneExistsResult = false

    var splitPaneResult: Result<UUID, Error> = .failure(CockpitAccessError.appUnavailable)
    private(set) var recordedSplitSurfaceID: UUID?
    private(set) var recordedSplitDirection: SplitDirection?
    private(set) var splitPaneCallCount = 0

    var createTabResult: Result<CockpitNewTab, Error> = .failure(CockpitAccessError.appUnavailable)
    private(set) var recordedCreateTabGroupName: String?
    private(set) var recordedCreateTabCwd: String?
    private(set) var createTabCallCount = 0

    // MARK: - P5 additions

    var sendCommandResult: Result<Void, Error> = .success(())
    private(set) var recordedSendCommandSurfaceID: UUID?
    private(set) var recordedSendCommandCommand: String?
    private(set) var recordedSendCommandDoubleReturn: Bool?
    private(set) var sendCommandCallCount = 0

    var sendKeysResult: Result<Void, Error> = .success(())
    private(set) var recordedSendKeysSurfaceID: UUID?
    private(set) var recordedSendKeysText: String?
    private(set) var sendKeysCallCount = 0

    /// Queue of successive `availablePaletteCommands()` results -- each
    /// call pops the front, EXCEPT the last remaining element, which
    /// repeats forever once reached (so a test only needing one fixed
    /// answer can supply a single-element queue without it going empty
    /// on a second, incidental call). Defaults to empty (unknown-command
    /// shape) so a test that doesn't care can ignore this entirely.
    var availablePaletteCommandsQueue: [[CockpitPaletteCommand]] = []
    private(set) var availablePaletteCommandsCallCount = 0

    var executePaletteCommandResult: Result<CockpitPaletteCommand, Error> = .failure(CockpitAccessError.appUnavailable)
    private(set) var recordedExecutePaletteCommandID: String?
    private(set) var executePaletteCommandCallCount = 0

    func listPanes() -> [CockpitPaneInfo] { panes }

    func paneExists(_ id: UUID) -> Bool { paneExistsResult }

    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws {
        sendCommandCallCount += 1
        recordedSendCommandSurfaceID = surfaceID
        recordedSendCommandCommand = command
        recordedSendCommandDoubleReturn = doubleReturn
        if case .failure(let error) = sendCommandResult { throw error }
    }

    func sendKeys(surfaceID: UUID, text: String) throws {
        sendKeysCallCount += 1
        recordedSendKeysSurfaceID = surfaceID
        recordedSendKeysText = text
        if case .failure(let error) = sendKeysResult { throw error }
    }

    func splitPane(surfaceID: UUID, direction: SplitDirection) throws -> UUID {
        splitPaneCallCount += 1
        recordedSplitSurfaceID = surfaceID
        recordedSplitDirection = direction
        switch splitPaneResult {
        case .success(let id): return id
        case .failure(let error): throw error
        }
    }

    func createTab(groupName: String?, cwd: String?) throws -> CockpitNewTab {
        createTabCallCount += 1
        recordedCreateTabGroupName = groupName
        recordedCreateTabCwd = cwd
        switch createTabResult {
        case .success(let tab): return tab
        case .failure(let error): throw error
        }
    }

    func availablePaletteCommands() -> [CockpitPaletteCommand] {
        defer { availablePaletteCommandsCallCount += 1 }
        guard !availablePaletteCommandsQueue.isEmpty else { return [] }
        if availablePaletteCommandsQueue.count > 1 {
            return availablePaletteCommandsQueue.removeFirst()
        }
        return availablePaletteCommandsQueue[0]
    }

    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand {
        executePaletteCommandCallCount += 1
        recordedExecutePaletteCommandID = id
        switch executePaletteCommandResult {
        case .success(let command): return command
        case .failure(let error): throw error
        }
    }
}

@MainActor
final class MCPCockpitBridgeTests: XCTestCase {

    // MARK: - Helpers

    private func jsonDict(_ text: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(obj as? [String: Any], "Expected \(text) to parse as a JSON object")
    }

    /// Drives `handleToolCall` expecting it to throw exactly `expected`
    /// (case AND payload, via `MCPCockpitBridgeError`'s `Equatable`
    /// conformance) -- stronger than a substring match, since the error
    /// type is fully pinned by this bridge's own contract.
    private func expectError(
        _ expected: MCPCockpitBridgeError,
        name: String,
        arguments: [String: Any],
        bridge: MCPCockpitBridge,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let result = try await bridge.handleToolCall(name: name, arguments: arguments)
            XCTFail("Expected \(expected) but got a result: \(result)", file: file, line: line)
        } catch let error as MCPCockpitBridgeError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected MCPCockpitBridgeError.\(expected) but got a different error type: \(error)", file: file, line: line)
        }
    }

    /// Drives `handleToolCall` expecting `.invalidArgument(name:
    /// expectedName, reason:)` -- pins only the `name` component;
    /// `reason` is free-form human text GREEN can phrase however it
    /// likes, so it's deliberately not compared.
    private func expectInvalidArgument(
        name expectedName: String,
        toolName: String,
        arguments: [String: Any],
        bridge: MCPCockpitBridge,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let result = try await bridge.handleToolCall(name: toolName, arguments: arguments)
            XCTFail("Expected .invalidArgument(name: \(expectedName)) but got a result: \(result)", file: file, line: line)
        } catch let error as MCPCockpitBridgeError {
            guard case .invalidArgument(let name, _) = error else {
                XCTFail("Expected .invalidArgument(name: \(expectedName)) but got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(name, expectedName, file: file, line: line)
        } catch {
            XCTFail("Expected MCPCockpitBridgeError but got a different error type: \(error)", file: file, line: line)
        }
    }

    /// Bounded scheduler-yield loop, so a concurrently-spawned `Task`
    /// awaiting a gated `handleToolCall` has every reasonable
    /// opportunity to actually reach its `approvals.awaitDecision`
    /// suspension point (having already called `approvals.submit`
    /// synchronously, before that suspend) before the test proceeds to
    /// inspect `approvals.pending` -- same pattern as
    /// ApprovalInboxStoreTests.yieldToScheduler / CommandLogStoreTests's.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    /// Starts a gated `handleToolCall` in a `Task` and yields, so any
    /// synchronous-before-suspension work (submitting an approval
    /// request) has had a chance to run by the time this returns --
    /// callers typically read `approvals.pending` right after to grab
    /// the submitted request's id.
    private func startGatedCall(
        _ bridge: MCPCockpitBridge, name: String, arguments: [String: Any]
    ) async -> Task<String, Error> {
        let task = Task { @MainActor in
            try await bridge.handleToolCall(name: name, arguments: arguments)
        }
        await yieldToScheduler()
        return task
    }

    // MARK: - Tool catalogue

    func test_toolNames_matchesToolsCatalog() {
        XCTAssertEqual(Set(MCPCockpitBridge.tools.map(\.name)), MCPCockpitBridge.toolNames)
    }

    // MARK: - pane_list

    func test_paneList_returnsPanes_omittedNotNull() async throws {
        let access = FakeCockpitAccess()
        let fullPane = CockpitPaneInfo(
            surfaceID: UUID(), windowID: UUID(), groupName: "Default", tabID: UUID(),
            tabTitle: "zsh", title: "vim ~/repo/file.rs", cwd: "/Users/dev/repo",
            isFocused: true, agentKind: "claude", calyxSessionID: "session-abc123"
        )
        let minimalPane = CockpitPaneInfo(
            surfaceID: UUID(), windowID: UUID(), groupName: "Default", tabID: UUID(),
            tabTitle: "zsh", title: nil, cwd: nil,
            isFocused: false, agentKind: nil, calyxSessionID: nil
        )
        access.panes = [fullPane, minimalPane]
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        let result = try await bridge.handleToolCall(name: "pane_list", arguments: [:])

        let json = try jsonDict(result)
        let panes = try XCTUnwrap(json["panes"] as? [[String: Any]])
        XCTAssertEqual(panes.count, 2)

        let fullDict = panes[0]
        XCTAssertEqual(fullDict["surface_id"] as? String, fullPane.surfaceID.uuidString)
        XCTAssertEqual(fullDict["window_id"] as? String, fullPane.windowID.uuidString)
        XCTAssertEqual(fullDict["group_name"] as? String, "Default")
        XCTAssertEqual(fullDict["tab_id"] as? String, fullPane.tabID.uuidString)
        XCTAssertEqual(fullDict["tab_title"] as? String, "zsh")
        XCTAssertEqual(fullDict["title"] as? String, "vim ~/repo/file.rs")
        XCTAssertEqual(fullDict["cwd"] as? String, "/Users/dev/repo")
        XCTAssertEqual(fullDict["is_focused"] as? Bool, true)
        XCTAssertEqual(fullDict["agent_kind"] as? String, "claude")
        XCTAssertEqual(fullDict["calyx_session_id"] as? String, "session-abc123")

        let minimalDict = panes[1]
        XCTAssertEqual(minimalDict["is_focused"] as? Bool, false)
        XCTAssertFalse(minimalDict.keys.contains("title"), "an absent per-pane title must be OMITTED, not serialized as null")
        XCTAssertFalse(minimalDict.keys.contains("cwd"), "an absent per-pane cwd must be OMITTED, not serialized as null")
        XCTAssertFalse(minimalDict.keys.contains("agent_kind"), "an absent agent_kind must be OMITTED, not serialized as null")
        XCTAssertFalse(minimalDict.keys.contains("calyx_session_id"), "an absent calyx_session_id must be OMITTED, not serialized as null")
    }

    // MARK: - pane_split

    func test_paneSplit_right_mapsHorizontal() async throws {
        let access = FakeCockpitAccess()
        let newSurfaceID = UUID()
        access.splitPaneResult = .success(newSurfaceID)
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())
        let sourceSurfaceID = UUID()

        let result = try await bridge.handleToolCall(
            name: "pane_split",
            arguments: ["surface_id": sourceSurfaceID.uuidString, "direction": "right"]
        )

        XCTAssertEqual(access.recordedSplitSurfaceID, sourceSurfaceID)
        XCTAssertEqual(access.recordedSplitDirection, .horizontal, "\"right\" must map to SplitDirection.horizontal")

        let json = try jsonDict(result)
        XCTAssertEqual(json["surface_id"] as? String, newSurfaceID.uuidString)
        XCTAssertEqual(json["direction"] as? String, "right")
    }

    func test_paneSplit_down_mapsVertical() async throws {
        let access = FakeCockpitAccess()
        let newSurfaceID = UUID()
        access.splitPaneResult = .success(newSurfaceID)
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())
        let sourceSurfaceID = UUID()

        let result = try await bridge.handleToolCall(
            name: "pane_split",
            arguments: ["surface_id": sourceSurfaceID.uuidString, "direction": "down"]
        )

        XCTAssertEqual(access.recordedSplitDirection, .vertical, "\"down\" must map to SplitDirection.vertical")

        let json = try jsonDict(result)
        XCTAssertEqual(json["surface_id"] as? String, newSurfaceID.uuidString)
        XCTAssertEqual(json["direction"] as? String, "down")
    }

    func test_paneSplit_invalidDirection_throwsInvalidArgument() async {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        await expectInvalidArgument(
            name: "direction",
            toolName: "pane_split",
            arguments: ["surface_id": UUID().uuidString, "direction": "up"],
            bridge: bridge
        )
    }

    func test_paneSplit_missingSurfaceID_throwsMissingArgument() async {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        await expectError(
            .missingArgument("surface_id"),
            name: "pane_split", arguments: ["direction": "right"], bridge: bridge
        )
    }

    func test_paneSplit_sessionID_resolvesViaSurfaceMap() async throws {
        let access = FakeCockpitAccess()
        let newSurfaceID = UUID()
        access.splitPaneResult = .success(newSurfaceID)
        let sessionMap = SessionSurfaceMap()
        let sourceSurfaceID = UUID()
        let sessionID = "session-\(UUID().uuidString)"
        sessionMap.register(sessionID: sessionID, surfaceID: sourceSurfaceID)
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: sessionMap)

        _ = try await bridge.handleToolCall(
            name: "pane_split", arguments: ["surface_id": sessionID, "direction": "right"]
        )

        XCTAssertEqual(access.recordedSplitSurfaceID, sourceSurfaceID,
                       "a session-ID surface_id must resolve to the surface it's registered to before reaching access.splitPane")
    }

    func test_paneSplit_unresolvableSurfaceID_throws() async {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        await expectError(
            .unresolvableSurfaceID("not-a-real-id"),
            name: "pane_split",
            arguments: ["surface_id": "not-a-real-id", "direction": "right"],
            bridge: bridge
        )
    }

    func test_paneSplit_paneNotFound_propagates() async {
        let access = FakeCockpitAccess()
        let sourceSurfaceID = UUID()
        access.splitPaneResult = .failure(CockpitAccessError.paneNotFound(sourceSurfaceID))
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        await expectError(
            .paneNotFound(sourceSurfaceID),
            name: "pane_split",
            arguments: ["surface_id": sourceSurfaceID.uuidString, "direction": "right"],
            bridge: bridge
        )
    }

    // MARK: - tab_create

    func test_tabCreate_defaults() async throws {
        let access = FakeCockpitAccess()
        let newTab = CockpitNewTab(tabID: UUID(), surfaceID: UUID(), groupName: "Default")
        access.createTabResult = .success(newTab)
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        let result = try await bridge.handleToolCall(name: "tab_create", arguments: [:])

        XCTAssertNil(access.recordedCreateTabGroupName, "no group_name argument must pass nil through to createTab")
        XCTAssertNil(access.recordedCreateTabCwd, "no cwd argument must pass nil through to createTab")

        let json = try jsonDict(result)
        XCTAssertEqual(json["tab_id"] as? String, newTab.tabID.uuidString)
        XCTAssertEqual(json["surface_id"] as? String, newTab.surfaceID.uuidString)
        XCTAssertEqual(json["group_name"] as? String, newTab.groupName)
    }

    func test_tabCreate_groupNameAndCwd_passedThrough() async throws {
        let access = FakeCockpitAccess()
        let newTab = CockpitNewTab(tabID: UUID(), surfaceID: UUID(), groupName: "Ops")
        access.createTabResult = .success(newTab)
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())
        let existingDir = FileManager.default.temporaryDirectory.path

        _ = try await bridge.handleToolCall(
            name: "tab_create", arguments: ["group_name": "Ops", "cwd": existingDir]
        )

        XCTAssertEqual(access.recordedCreateTabGroupName, "Ops")
        XCTAssertEqual(access.recordedCreateTabCwd, existingDir)
    }

    func test_tabCreate_cwdNotADirectory_throwsInvalidArgument() async {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())
        let bogusPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cockpit-red-\(UUID().uuidString)-does-not-exist").path

        await expectInvalidArgument(
            name: "cwd", toolName: "tab_create", arguments: ["cwd": bogusPath], bridge: bridge
        )

        XCTAssertEqual(access.createTabCallCount, 0, "an invalid cwd must be rejected before ever calling access.createTab")
    }

    func test_tabCreate_tildeExpansion() async throws {
        let access = FakeCockpitAccess()
        let newTab = CockpitNewTab(tabID: UUID(), surfaceID: UUID(), groupName: "Default")
        access.createTabResult = .success(newTab)
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        _ = try await bridge.handleToolCall(name: "tab_create", arguments: ["cwd": "~"])

        XCTAssertEqual(access.recordedCreateTabCwd, NSHomeDirectory(),
                       "a \"~\" cwd must be tilde-expanded to an absolute path before reaching access.createTab")
    }

    /// P4 review (F1/F2): a blank cwd (explicit but empty, or
    /// whitespace/newline-only) is a client bug -- reject loudly rather
    /// than silently falling back to the active tab's directory. A
    /// trailing newline on an otherwise-valid path (plausible from an
    /// agent-constructed payload built from raw shell output, e.g.
    /// `$(pwd)`) must be trimmed BEFORE directory validation, so it
    /// validates, and the TRIMMED path (not the raw one) reaches
    /// access.createTab.
    func test_tabCreate_cwdNormalization_blankRejected_trailingNewlineTrimmed() async throws {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        await expectInvalidArgument(name: "cwd", toolName: "tab_create", arguments: ["cwd": ""], bridge: bridge)
        await expectInvalidArgument(name: "cwd", toolName: "tab_create", arguments: ["cwd": "\n"], bridge: bridge)
        XCTAssertEqual(access.createTabCallCount, 0, "a blank cwd must be rejected before ever calling access.createTab")

        let newTab = CockpitNewTab(tabID: UUID(), surfaceID: UUID(), groupName: "Default")
        access.createTabResult = .success(newTab)
        let existingDir = FileManager.default.temporaryDirectory.path

        _ = try await bridge.handleToolCall(name: "tab_create", arguments: ["cwd": "\(existingDir)\n"])

        XCTAssertEqual(access.recordedCreateTabCwd, existingDir,
                       "a trailing-newline cwd must be trimmed before validation and before reaching access.createTab")
    }

    /// P4 review (F3): same blank-rejection contract as cwd, applied to
    /// group_name -- leading/trailing whitespace in a group name is
    /// never intentional from a tool call, so a non-blank value is
    /// trimmed before use too, not just checked for blankness.
    func test_tabCreate_groupNameNormalization_blankRejected_whitespaceTrimmed() async throws {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        await expectInvalidArgument(name: "group_name", toolName: "tab_create", arguments: ["group_name": ""], bridge: bridge)
        XCTAssertEqual(access.createTabCallCount, 0, "a blank group_name must be rejected before ever calling access.createTab")

        let newTab = CockpitNewTab(tabID: UUID(), surfaceID: UUID(), groupName: "E2E")
        access.createTabResult = .success(newTab)

        _ = try await bridge.handleToolCall(name: "tab_create", arguments: ["group_name": " E2E "])

        XCTAssertEqual(access.recordedCreateTabGroupName, "E2E")
    }

    // MARK: - Unknown tool

    func test_unknownTool_throws() async {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(access: access, sessionSurfaceMap: SessionSurfaceMap())

        // A known tool name must be routed to its own handler, not fall
        // through to unknownTool -- pins that the dispatch switch
        // actually recognizes pane_list, distinguishing this from a
        // stub that blanket-throws unknownTool for literally every
        // name (which would make the unknownTool assertion below
        // vacuously true).
        do {
            _ = try await bridge.handleToolCall(name: "pane_list", arguments: [:])
        } catch let error as MCPCockpitBridgeError {
            if case .unknownTool = error {
                XCTFail("pane_list must be a recognized tool name, not fall through to unknownTool")
            }
        } catch {
            // Any other error is fine here -- only unknownTool
            // specifically would indicate the dispatch switch doesn't
            // know this name.
        }

        await expectError(.unknownTool("pane_frobnicate"), name: "pane_frobnicate", arguments: [:], bridge: bridge)
    }

    // MARK: - pane_run

    func test_paneRun_defaultPolicy_submitsRequest_thenAllow_executes_singleReturn() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunDefault"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        let callTask = await startGatedCall(bridge, name: "pane_run", arguments: ["surface_id": surfaceID.uuidString, "command": "ls"])

        XCTAssertEqual(approvals.pending.count, 1, "pane_run must submit an approval request before executing, when approval is required")
        let request = approvals.pending.first
        XCTAssertEqual(request?.targetSurfaceID, surfaceID)
        XCTAssertEqual(request?.payload, "ls")
        if case .mcpTool(let name)? = request?.source {
            XCTAssertEqual(name, "pane_run")
        } else {
            XCTFail("expected source .mcpTool(name: \"pane_run\")")
        }
        guard let requestID = request?.id else {
            callTask.cancel()
            return
        }
        approvals.decide(id: requestID, .allowed)

        let result = try await callTask.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "sent")
        XCTAssertEqual(access.recordedSendCommandSurfaceID, surfaceID)
        XCTAssertEqual(access.recordedSendCommandCommand, "ls")
        XCTAssertEqual(access.recordedSendCommandDoubleReturn, false,
                       "a target pane with no AgentRegistry entry must get a single, not doubled, synthetic Return")
    }

    func test_paneRun_agentPane_stillRequiresApproval_butDoubleReturn() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunAgentPane"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let approvals = ApprovalInboxStore()
        let agentRegistry = AgentRegistry()
        let surfaceID = UUID()
        agentRegistry.handleHookEvent(
            AgentEvent(hookEventName: "SessionStart", sessionID: "s1", cwd: nil, message: nil),
            surfaceID: surfaceID
        )
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: agentRegistry, commandLogStore: CommandLogStore()
        )

        let callTask = await startGatedCall(bridge, name: "pane_run", arguments: ["surface_id": surfaceID.uuidString, "command": "ls"])

        XCTAssertEqual(approvals.pending.count, 1,
                       "an agent-pane target must STILL require approval -- there is no agent-pane exception to the gate")
        guard let requestID = approvals.pending.first?.id else {
            callTask.cancel()
            return
        }
        approvals.decide(id: requestID, .allowed)

        _ = try await callTask.value
        XCTAssertEqual(access.recordedSendCommandDoubleReturn, true,
                       "a target pane WITH an AgentRegistry entry must get a doubled synthetic Return")
    }

    func test_paneRun_autoApproveOn_executesWithoutSubmitting() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunAutoApprove"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        CockpitSettings.autoApproveEnabled = true

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        let result = try await bridge.handleToolCall(name: "pane_run", arguments: ["surface_id": surfaceID.uuidString, "command": "ls"])

        XCTAssertTrue(approvals.pending.isEmpty, "auto-approve on must never submit an approval request")
        XCTAssertEqual(access.sendCommandCallCount, 1)
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "sent")
    }

    func test_paneRun_deny_returnsStatusDenied_notIsError_neverExecutes() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunDeny"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        let callTask = await startGatedCall(bridge, name: "pane_run", arguments: ["surface_id": surfaceID.uuidString, "command": "rm -rf /tmp/x"])

        XCTAssertEqual(approvals.pending.count, 1)
        guard let requestID = approvals.pending.first?.id else {
            callTask.cancel()
            return
        }
        approvals.decide(id: requestID, .denied)

        let result = try await callTask.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "denied")
        XCTAssertEqual(access.sendCommandCallCount, 0, "a denied command must never reach access.sendCommand")
    }

    func test_paneRun_approvalTimeout_returnsApprovalTimeout_neverExecutes() async throws {
        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore(),
            approvalTimeoutMs: 100
        )
        let surfaceID = UUID()

        let result = try await bridge.handleToolCall(name: "pane_run", arguments: ["surface_id": surfaceID.uuidString, "command": "ls"])

        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "approval_timeout")
        XCTAssertEqual(access.sendCommandCallCount, 0, "a timed-out approval must never reach access.sendCommand")
    }

    func test_paneRun_cancelledAfterAllowed_doesNotExecute_returnsApprovalTimeout() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunCancelledAfterAllowed"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        let callTask = await startGatedCall(bridge, name: "pane_run", arguments: ["surface_id": surfaceID.uuidString, "command": "ls"])
        guard let requestID = approvals.pending.first?.id else {
            callTask.cancel()
            XCTFail("expected a pending approval request")
            return
        }

        // Deliberately deterministic, not a real race: decide(id:_:) is a
        // synchronous @MainActor call that resumes gate()'s suspended
        // continuation, but resuming a continuation only makes the
        // awaiting Task eligible to run again -- since gate() and this
        // test are BOTH @MainActor-isolated, the resumed Task cannot
        // preempt this still-running synchronous call; it's merely
        // enqueued to continue once this call returns control to the
        // scheduler. Cancelling right here, in the same synchronous
        // block right after decide(), therefore reliably sets
        // Task.isCancelled to true BEFORE gate()'s post-.allowed
        // recheck ever runs -- pinning the ApprovalInboxStore-documented
        // "an .allowed decision racing a concurrent cancellation" caller
        // obligation without depending on real scheduler timing.
        approvals.decide(id: requestID, .allowed)
        callTask.cancel()

        let result = try await callTask.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "approval_timeout",
                       "a Task cancelled between .allowed and execution must never execute -- report " +
                       "approval_timeout, not a false success")
        XCTAssertEqual(access.sendCommandCallCount, 0, "a cancelled-after-allowed call must never reach access.sendCommand")
    }

    func test_paneRun_invalidAwaitType_rejected() async {
        let access = FakeCockpitAccess()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: ApprovalInboxStore(), agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        await expectInvalidArgument(
            name: "await", toolName: "pane_run",
            arguments: ["surface_id": surfaceID.uuidString, "command": "ls", "await": 1],
            bridge: bridge
        )
        await expectInvalidArgument(
            name: "await", toolName: "pane_run",
            arguments: ["surface_id": surfaceID.uuidString, "command": "ls", "await": "true"],
            bridge: bridge
        )
    }

    func test_paneRun_paneDoesNotExist_failsFastBeforeGate() async {
        let access = FakeCockpitAccess() // paneExistsResult defaults to false
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        await expectError(
            .paneNotFound(surfaceID), name: "pane_run",
            arguments: ["surface_id": surfaceID.uuidString, "command": "ls"], bridge: bridge
        )

        XCTAssertTrue(approvals.pending.isEmpty, "a dead surface_id must fail before ever reaching the approval gate")
        XCTAssertEqual(access.sendCommandCallCount, 0)
    }

    func test_paneRun_awaitTrue_untrackedShell_returnsStatusTimeout_afterExecution() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunAwaitUntracked"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        CockpitSettings.autoApproveEnabled = true

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let commandLog = CommandLogStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: ApprovalInboxStore(), agentRegistry: AgentRegistry(), commandLogStore: commandLog
        )
        let surfaceID = UUID()

        let result = try await bridge.handleToolCall(
            name: "pane_run",
            arguments: ["surface_id": surfaceID.uuidString, "command": "ls", "await": true, "timeout_ms": 100]
        )

        XCTAssertEqual(access.sendCommandCallCount, 1, "execution must happen even though nothing is tracked to await")
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "timeout")
    }

    func test_paneRun_awaitTrue_returnsCompletedRecord() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunAwaitCompleted"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        CockpitSettings.autoApproveEnabled = true

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let commandLog = CommandLogStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: ApprovalInboxStore(), agentRegistry: AgentRegistry(), commandLogStore: commandLog
        )
        let surfaceID = UUID()

        let callTask = Task { @MainActor in
            try await bridge.handleToolCall(
                name: "pane_run",
                arguments: ["surface_id": surfaceID.uuidString, "command": "ls", "await": true, "timeout_ms": 5000]
            )
        }
        await yieldToScheduler()

        // Ingested AFTER the call has begun (and therefore after its
        // entryTime) -- awaitNextCompletion correlates on startedAt, so a
        // record pre-seeded before the call (as an older version of this
        // test did) would never satisfy it. This also mirrors real
        // shell-integration timing, where the .start event always
        // arrives strictly after the command is sent.
        commandLog.ingest(
            CommandEvent(phase: .start, cmdID: "cmd-1", command: "ls", cwd: "/tmp", exitCode: nil, ts: Date()),
            surfaceID: surfaceID
        )
        commandLog.ingest(
            CommandEvent(phase: .end, cmdID: "cmd-1", command: nil, cwd: nil, exitCode: 0, ts: Date()),
            surfaceID: surfaceID
        )

        let result = try await callTask.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["state"] as? String, "finished")
    }

    func test_paneRun_awaitTrue_correlatesToTheLaunchedCommand() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneRunAwaitCorrelates"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        CockpitSettings.autoApproveEnabled = true

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let commandLog = CommandLogStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: ApprovalInboxStore(), agentRegistry: AgentRegistry(), commandLogStore: commandLog
        )
        let surfaceID = UUID()

        // An OLDER command is already running on this surface BEFORE
        // pane_run is even called -- if await:true resolved via
        // awaitCompletion's eager newest-running-record semantics
        // instead of start-time correlation, it would latch onto this
        // one (or, worse, time out instantly since nothing this call
        // itself launched is running yet).
        commandLog.ingest(
            CommandEvent(phase: .start, cmdID: "cmd-old", command: "sleep 100", cwd: "/tmp", exitCode: nil, ts: Date()),
            surfaceID: surfaceID
        )

        let callTask = Task { @MainActor in
            try await bridge.handleToolCall(
                name: "pane_run",
                arguments: ["surface_id": surfaceID.uuidString, "command": "ls", "await": true, "timeout_ms": 5000]
            )
        }
        await yieldToScheduler()

        // The NEWER command -- the one THIS call actually launched --
        // starts and finishes after entryTime.
        commandLog.ingest(
            CommandEvent(phase: .start, cmdID: "cmd-new", command: "ls", cwd: "/tmp", exitCode: nil, ts: Date()),
            surfaceID: surfaceID
        )
        commandLog.ingest(
            CommandEvent(phase: .end, cmdID: "cmd-new", command: nil, cwd: nil, exitCode: 0, ts: Date()),
            surfaceID: surfaceID
        )

        let result = try await callTask.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["cmd_id"] as? String, "cmd-new",
                       "await:true must correlate to the command THIS call started, not an older already-running one")

        let oldRecord = commandLog.records(surfaceID: surfaceID, limit: nil, state: .running).first
        XCTAssertEqual(oldRecord?.cmdID, "cmd-old", "the older command must be left untouched, still running")
    }

    // MARK: - pane_send_keys

    func test_paneSendKeys_verbatim_noReturn_emptyAllowed_ctrlC() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paneSendKeys"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let access = FakeCockpitAccess()
        access.paneExistsResult = true
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        let callTask = await startGatedCall(bridge, name: "pane_send_keys", arguments: ["surface_id": surfaceID.uuidString, "text": "\u{03}"])
        XCTAssertEqual(approvals.pending.count, 1, "pane_send_keys must submit an approval request before sending, when approval is required")
        guard let requestID = approvals.pending.first?.id else {
            callTask.cancel()
            return
        }
        approvals.decide(id: requestID, .allowed)

        let result = try await callTask.value
        XCTAssertEqual(access.recordedSendKeysText, "\u{03}", "text must be sent verbatim, with no appended Return")
        XCTAssertEqual(access.sendCommandCallCount, 0, "pane_send_keys must never call access.sendCommand")
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "sent")

        // An empty string is a valid (no-op paste) payload too, not a
        // missing/invalid argument.
        let emptyTask = await startGatedCall(bridge, name: "pane_send_keys", arguments: ["surface_id": surfaceID.uuidString, "text": ""])
        XCTAssertEqual(approvals.pending.count, 1)
        guard let emptyRequestID = approvals.pending.first?.id else {
            emptyTask.cancel()
            return
        }
        approvals.decide(id: emptyRequestID, .allowed)
        _ = try await emptyTask.value
        XCTAssertEqual(access.recordedSendKeysText, "", "an empty text argument must be accepted and sent verbatim, not rejected")
    }

    func test_paneSendKeys_paneDoesNotExist_failsFastBeforeGate() async {
        let access = FakeCockpitAccess() // paneExistsResult defaults to false
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )
        let surfaceID = UUID()

        await expectError(
            .paneNotFound(surfaceID), name: "pane_send_keys",
            arguments: ["surface_id": surfaceID.uuidString, "text": "hi"], bridge: bridge
        )

        XCTAssertTrue(approvals.pending.isEmpty, "a dead surface_id must fail before ever reaching the approval gate")
        XCTAssertEqual(access.sendKeysCallCount, 0)
    }

    // MARK: - palette_execute

    func test_paletteExecute_unknownId_errorListsAvailableSorted() async {
        let access = FakeCockpitAccess()
        access.availablePaletteCommandsQueue = [[
            CockpitPaletteCommand(id: "b", title: "B", category: "cat", isAvailable: true),
            CockpitPaletteCommand(id: "a", title: "A", category: "cat", isAvailable: true),
        ]]
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: ApprovalInboxStore(), agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )

        await expectError(
            .unknownPaletteCommand(id: "totally-unknown", available: ["a", "b"]),
            name: "palette_execute", arguments: ["command_id": "totally-unknown"], bridge: bridge
        )
    }

    func test_paletteExecute_unavailable_error_beforeGate() async {
        let access = FakeCockpitAccess()
        access.availablePaletteCommandsQueue = [[
            CockpitPaletteCommand(id: "cmd-1", title: "Cmd", category: "cat", isAvailable: false),
        ]]
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )

        await expectError(
            .paletteCommandUnavailable("cmd-1"),
            name: "palette_execute", arguments: ["command_id": "cmd-1"], bridge: bridge
        )

        XCTAssertTrue(approvals.pending.isEmpty, "an unavailable command must be rejected before ever reaching the approval gate")
    }

    func test_paletteExecute_recheckAfterApproval() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paletteRecheck"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let access = FakeCockpitAccess()
        access.availablePaletteCommandsQueue = [
            [CockpitPaletteCommand(id: "cmd-1", title: "Cmd", category: "cat", isAvailable: true)],
            [CockpitPaletteCommand(id: "cmd-1", title: "Cmd", category: "cat", isAvailable: false)],
        ]
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )

        let callTask = await startGatedCall(bridge, name: "palette_execute", arguments: ["command_id": "cmd-1"])
        XCTAssertEqual(approvals.pending.count, 1,
                       "palette_execute must submit an approval request when the command is available and approval is required")
        guard let requestID = approvals.pending.first?.id else {
            callTask.cancel()
            return
        }
        approvals.decide(id: requestID, .allowed)

        do {
            _ = try await callTask.value
            XCTFail("Expected .paletteCommandUnavailable after the command's availability flipped false during the approval wait")
        } catch let error as MCPCockpitBridgeError {
            XCTAssertEqual(error, .paletteCommandUnavailable("cmd-1"))
        } catch {
            XCTFail("Expected MCPCockpitBridgeError but got \(error)")
        }
        XCTAssertEqual(access.executePaletteCommandCallCount, 0, "must never execute once the re-check finds the command unavailable")
    }

    func test_paletteExecute_gated_thenAllow_executes() async throws {
        let suiteName = "com.calyx.tests.MCPCockpitBridgeTests.paletteGatedAllow"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let access = FakeCockpitAccess()
        let command = CockpitPaletteCommand(id: "cmd-1", title: "Restart Session", category: "session", isAvailable: true)
        access.availablePaletteCommandsQueue = [[command], [command]]
        access.executePaletteCommandResult = .success(command)
        let approvals = ApprovalInboxStore()
        let bridge = MCPCockpitBridge(
            access: access, sessionSurfaceMap: SessionSurfaceMap(),
            approvals: approvals, agentRegistry: AgentRegistry(), commandLogStore: CommandLogStore()
        )

        let callTask = await startGatedCall(bridge, name: "palette_execute", arguments: ["command_id": "cmd-1"])
        XCTAssertEqual(approvals.pending.count, 1)
        XCTAssertEqual(approvals.pending.first?.payload, "palette_execute: cmd-1 — Restart Session")
        XCTAssertNil(approvals.pending.first?.targetSurfaceID, "palette_execute has no single target surface -- its banner shows in the key window")
        guard let requestID = approvals.pending.first?.id else {
            callTask.cancel()
            return
        }
        approvals.decide(id: requestID, .allowed)

        let result = try await callTask.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "executed")
        XCTAssertEqual(json["command_id"] as? String, "cmd-1")
        XCTAssertEqual(json["title"] as? String, "Restart Session")
    }
}
