//
//  SurfaceRegistryDestroySurfaceOrphanGatingTests.swift
//  CalyxTests
//
//  TDD Red Phase for SurfaceRegistry.destroySurface(_:)'s new command-log
//  orphan gating: a torn-down surface's running commands are orphaned
//  UNLESS the surface is still tracked in SessionSurfaceMap (a
//  persistent-session pane, whose daemon-side session survives the
//  pane's teardown and whose commands get remapped onto the fresh
//  surfaceID by CalyxWindowController's reconnect path instead).
//
//  Uses injectable commandLogStore/sessionSurfaceMap seams (mirroring
//  CalyxMCPServer.agentRegistry/sessionSurfaceMap) rather than a real
//  ghostty surface -- the gating check itself does not depend on a live
//  SurfaceRegistry entry existing for the destroyed id.
//
//  Coverage:
//  - No SessionSurfaceMap entry -> running commands become .orphaned
//  - SessionSurfaceMap entry present -> running commands stay .running
//  - (Cockpit P2 review finding W4) destroySurface also calls the
//    injectable approvalInboxStore's expireForSurface(_:), same
//    "defaults to .shared, test-injectable" DI shape as
//    commandLogStore/sessionSurfaceMap -- proven here the same way, via
//    the no-live-entry path (the only path testable without a real
//    ghostty surface controller; both destroySurface call sites invoke
//    approvalInboxStore.expireForSurface(id) identically, so exercising
//    either exercises the wiring itself).
//  - (Stage E) destroySurface also calls the injectable
//    agentHookApprovalMemory's clearPaneEntries(surfaceID:), same DI
//    shape as approvalInboxStore above -- proven via the no-live-entry
//    path too, and distinguished from an (incorrect) clearAll() call by
//    asserting a cross-scoped entry survives the destroy.
//

import XCTest
@testable import Calyx

@MainActor
final class SurfaceRegistryDestroySurfaceOrphanGatingTests: XCTestCase {

    func test_destroySurface_orphanGating_marksOrphanedOnlyWhenNoSessionMapping() throws {
        let registry = SurfaceRegistry()
        let store = CommandLogStore()
        registry.commandLogStore = store
        let sessionMap = SessionSurfaceMap()
        registry.sessionSurfaceMap = sessionMap

        // Case A: no session mapping -- an ordinary, non-persistent pane.
        let unmappedSurfaceID = UUID()
        store.ingest(
            CommandEvent(phase: .start, cmdID: "cmd-a", command: "sleep 100", cwd: "/tmp", exitCode: nil, ts: nil),
            surfaceID: unmappedSurfaceID
        )

        // Case B: sessionID registered in SessionSurfaceMap -- a
        // persistent-session pane; the daemon-side session survives the
        // pane's teardown.
        let mappedSurfaceID = UUID()
        sessionMap.register(sessionID: "session-persistent", surfaceID: mappedSurfaceID)
        store.ingest(
            CommandEvent(phase: .start, cmdID: "cmd-b", command: "sleep 100", cwd: "/tmp", exitCode: nil, ts: nil),
            surfaceID: mappedSurfaceID
        )

        registry.destroySurface(unmappedSurfaceID)
        registry.destroySurface(mappedSurfaceID)

        let unmappedRecord = try XCTUnwrap(store.records(surfaceID: unmappedSurfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(unmappedRecord.state, .orphaned,
                       "destroySurface on a surface with no SessionSurfaceMap entry must orphan its " +
                       "running commands")

        let mappedRecord = try XCTUnwrap(store.records(surfaceID: mappedSurfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(mappedRecord.state, .running,
                       "destroySurface on a surface still tracked in SessionSurfaceMap (a persistent " +
                       "session pane) must leave its running commands untouched -- the daemon-side " +
                       "session survives the pane's teardown")
    }

    func test_destroySurface_expiresApprovalRequestsTargetingTheDestroyedSurface() async throws {
        let registry = SurfaceRegistry()
        let approvalStore = ApprovalInboxStore()
        registry.approvalInboxStore = approvalStore

        let surfaceID = UUID()
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID, payload: "ls", createdAt: Date()
        )
        approvalStore.submit(request)

        let waiter = Task { @MainActor in
            await approvalStore.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        for _ in 0..<50 { await Task.yield() }

        registry.destroySurface(surfaceID)

        let result = await waiter.value
        XCTAssertEqual(result, .expired,
                       "destroySurface must call approvalInboxStore.expireForSurface(id), resolving any " +
                       "in-flight awaitDecision for a request targeting the destroyed surface with .expired")
        XCTAssertTrue(approvalStore.pending.isEmpty,
                      "destroySurface must remove the expired request from pending")
    }

    func test_destroySurface_clearsAgentHookApprovalMemoryPaneEntries_butNotCrossMemory() {
        let registry = SurfaceRegistry()
        let memory = AgentHookApprovalMemory()
        registry.agentHookApprovalMemory = memory

        let surfaceID = UUID()
        let otherSurfaceID = UUID()
        memory.rememberPane(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash")
        memory.rememberCross(kind: AgentEntry.claudeCodeKind, toolName: "Write")
        XCTAssertTrue(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                     "precondition: the pane memory was recorded before destroySurface")

        registry.destroySurface(surfaceID)

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "destroySurface must call agentHookApprovalMemory.clearPaneEntries(surfaceID:), " +
                       "removing the destroyed surface's own pane entry")
        XCTAssertTrue(memory.isAutoAllowed(surfaceID: otherSurfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Write"),
                     "destroySurface must leave CROSS-scoped memory untouched -- it must call " +
                     "clearPaneEntries(surfaceID:), not clearAll()")
    }
}
