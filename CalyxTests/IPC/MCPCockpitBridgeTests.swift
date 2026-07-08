//
//  MCPCockpitBridgeTests.swift
//  CalyxTests
//
//  TDD Red Phase for MCPCockpitBridge's three UNGATED tools: pane_list,
//  pane_split, tab_create. Drives handleToolCall(name:arguments:)
//  directly against a fake CockpitAppAccessing + a fresh, isolated
//  SessionSurfaceMap (no CalyxMCPServer / HTTP layer involved).
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
//  bridge alone would enforce). await-argument rejection: N/A, no tool
//  in this P4 round awaits anything (pane_run lands in P5).
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

    func listPanes() -> [CockpitPaneInfo] { panes }

    func paneExists(_ id: UUID) -> Bool { paneExistsResult }

    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws {}

    func sendKeys(surfaceID: UUID, text: String) throws {}

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

    func availablePaletteCommands() -> [CockpitPaletteCommand] { [] }

    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand {
        throw CockpitAccessError.appUnavailable
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

        await expectError(.unknownTool("pane_run"), name: "pane_run", arguments: [:], bridge: bridge)
    }
}
