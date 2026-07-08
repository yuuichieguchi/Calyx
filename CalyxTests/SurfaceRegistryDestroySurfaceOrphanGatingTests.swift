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
}
