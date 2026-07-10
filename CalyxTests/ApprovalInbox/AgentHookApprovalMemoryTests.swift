//
//  AgentHookApprovalMemoryTests.swift
//  CalyxTests
//
//  TDD Red Phase for Stage E of the approval-inbox-for-CLI-agents
//  feature: AgentHookApprovalMemory, the per-session "Always Allow"
//  memory that lets a human's Always-Allow click on an agent-hook
//  approval request (see ApprovalRequest.Source.agentHook) skip the
//  inbox entirely on a later matching request, without touching the
//  blanket CockpitSettings.autoApproveEnabled toggle.
//
//  Two independent scopes, deliberately NOT unified into one keyspace:
//  - PANE scope (rememberPane): auto-allows only the exact
//    (surfaceID, kind, toolName) tuple -- "always allow THIS tool in
//    THIS pane".
//  - CROSS scope (rememberCross): auto-allows (kind, toolName) on ANY
//    surface -- "always allow THIS tool everywhere".
//  isAutoAllowed(surfaceID:kind:toolName:) is true if EITHER scope
//  matches -- cross-scope OR pane-scope.
//
//  Mirrors ApprovalInboxStore's singleton convention (`static let
//  shared`, plain `init()` so a test can construct an isolated instance)
//  and its own file header's warning: init() must never construct
//  another singleton in a stored property.
//
//  Coverage:
//  - empty memory: isAutoAllowed is false for anything
//  - rememberPane: allowed only for that EXACT (surfaceID, kind,
//    toolName) tuple -- a different surface, kind, or tool each
//    independently miss
//  - rememberCross: allowed for ANY surfaceID sharing the same
//    (kind, toolName)
//  - clearPaneEntries(surfaceID:) removes only that surface's pane
//    entries, leaving cross memory and other panes' entries untouched
//  - clearAll() clears both scopes entirely
//

import XCTest
@testable import Calyx

@MainActor
final class AgentHookApprovalMemoryTests: XCTestCase {

    private let kind = AgentEntry.claudeCodeKind
    private let toolName = "Bash"

    // MARK: - Empty memory

    func test_isAutoAllowed_emptyMemory_returnsFalse() {
        let memory = AgentHookApprovalMemory()

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: toolName),
                       "a memory that has never recorded anything must never auto-allow")
    }

    // MARK: - rememberPane

    func test_rememberPane_allowsOnlyExactSurfaceKindToolTuple() {
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: kind, toolName: toolName)

        XCTAssertTrue(memory.isAutoAllowed(surfaceID: surfaceID, kind: kind, toolName: toolName),
                     "the exact remembered (surfaceID, kind, toolName) tuple must be auto-allowed")

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: toolName),
                       "a DIFFERENT surfaceID must not be auto-allowed by a pane-scoped memory")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.codexKind, toolName: toolName),
                       "a DIFFERENT kind on the SAME surface/tool must not be auto-allowed")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: kind, toolName: "Write"),
                       "a DIFFERENT toolName on the SAME surface/kind must not be auto-allowed")
    }

    // MARK: - rememberCross

    func test_rememberCross_allowsAnySurfaceWithSameKindTool() {
        let memory = AgentHookApprovalMemory()
        memory.rememberCross(kind: kind, toolName: toolName)

        XCTAssertTrue(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: toolName),
                     "a cross-scoped remember must auto-allow an arbitrary, never-before-seen surfaceID")
        XCTAssertTrue(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: toolName),
                     "a cross-scoped remember must auto-allow a SECOND arbitrary surfaceID too -- proving " +
                     "it is not accidentally scoped to the first surface it was ever queried with")

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: UUID(), kind: AgentEntry.codexKind, toolName: toolName),
                       "a DIFFERENT kind must not be auto-allowed by a cross-scoped memory for another kind")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: "Write"),
                       "a DIFFERENT toolName must not be auto-allowed by a cross-scoped memory for another tool")
    }

    // MARK: - clearPaneEntries

    func test_clearPaneEntries_removesOnlyThatSurfacesPaneEntries_keepsCrossAndOtherPanes() {
        let memory = AgentHookApprovalMemory()
        let clearedSurfaceID = UUID()
        let otherSurfaceID = UUID()

        memory.rememberPane(surfaceID: clearedSurfaceID, kind: kind, toolName: toolName)
        memory.rememberPane(surfaceID: otherSurfaceID, kind: kind, toolName: toolName)
        memory.rememberCross(kind: kind, toolName: "Write")

        memory.clearPaneEntries(surfaceID: clearedSurfaceID)

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: clearedSurfaceID, kind: kind, toolName: toolName),
                       "clearPaneEntries(surfaceID:) must remove the cleared surface's own pane entry")
        XCTAssertTrue(memory.isAutoAllowed(surfaceID: otherSurfaceID, kind: kind, toolName: toolName),
                     "clearPaneEntries(surfaceID:) must leave a DIFFERENT surface's pane entry untouched")
        XCTAssertTrue(memory.isAutoAllowed(surfaceID: clearedSurfaceID, kind: kind, toolName: "Write"),
                     "clearPaneEntries(surfaceID:) must leave CROSS-scoped memory untouched, even for the " +
                     "same surfaceID it was just called with")
    }

    // MARK: - clearAll

    func test_clearAll_clearsBothScopes() {
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: kind, toolName: toolName)
        memory.rememberCross(kind: kind, toolName: "Write")

        memory.clearAll()

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: kind, toolName: toolName),
                       "clearAll() must clear pane-scoped memory")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: UUID(), kind: kind, toolName: "Write"),
                       "clearAll() must clear cross-scoped memory")
    }
}
