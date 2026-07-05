//
//  SessionBrowserModelTests.swift
//  CalyxTests
//
//  TDD Red Phase for `SessionBrowserModel`: the UI-independent logic
//  layer behind the session browser window (`refresh()`'s row
//  construction + orphan detection, `attach(_:)`/`kill(_:)`'s actions).
//  Exercised with a fake `SessionDaemonClientProtocol` and a real,
//  test-owned `SessionSurfaceMap` instance — no window, no real
//  `calyx-session` process, matching this codebase's direct-query test
//  style (see `SessionReconnectCoordinatorTests`'s `FakeSessionDaemonClient`).
//
//  Coverage:
//  - refresh() populates `rows` from `daemonClient.listAll()`
//  - Orphan detection: a *running* session with no `SessionSurfaceMap`
//    entry is `isOrphan == true`; one with a registered surface is
//    `isOrphan == false` and `isAttachedHere == true`
//  - An *exited* session is never flagged `isOrphan`, regardless of
//    `SessionSurfaceMap`
//  - attach(_:) invokes `onAttachRequested` with the row
//  - kill(_:) calls `daemonClient.kill(id:)` with the row's session id
//

import XCTest
@testable import Calyx

/// Records every `listAll()`/`kill(id:)`/`setMeta(id:key:value:)` call
/// and replays a canned `[SessionInfo]` — a process boundary stand-in,
/// no real `calyx-session` binary involved.
private final class FakeBrowserDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    var sessionsToReturn: [SessionInfo] = []
    private(set) var killedIDs: [String] = []
    private(set) var metaSetCalls: [(id: String, key: String, value: String)] = []

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }

    func kill(id: String) async {
        killedIDs.append(id)
    }

    func listAll() async -> [SessionInfo] {
        sessionsToReturn
    }

    func setMeta(id: String, key: String, value: String) async {
        metaSetCalls.append((id, key, value))
    }
}

@MainActor
final class SessionBrowserModelTests: XCTestCase {

    private var daemonClient: FakeBrowserDaemonClient!
    private var surfaceMap: SessionSurfaceMap!
    private var model: SessionBrowserModel!

    override func setUp() {
        super.setUp()
        daemonClient = FakeBrowserDaemonClient()
        // A fresh instance per test — never touch `.shared`, which
        // other suites also read from.
        surfaceMap = SessionSurfaceMap()
        model = SessionBrowserModel(daemonClient: daemonClient, surfaceMap: surfaceMap)
    }

    override func tearDown() {
        model = nil
        surfaceMap = nil
        daemonClient = nil
        super.tearDown()
    }

    private func makeInfo(
        id: String,
        state: SessionLifecycleState,
        name: String? = nil,
        cwd: String? = nil,
        meta: [String: String] = [:]
    ) -> SessionInfo {
        SessionInfo(
            id: id, name: name, cwd: cwd, state: state,
            createdAtMs: 0, attachedClients: state == .running ? 1 : 0, pid: 0, meta: meta
        )
    }

    // MARK: - refresh() populates rows

    func test_refresh_populatesRowsFromListAll() async {
        daemonClient.sessionsToReturn = [
            makeInfo(id: "session-a", state: .running),
            makeInfo(id: "session-b", state: .exited(code: 0)),
        ]

        await model.refresh()

        XCTAssertEqual(model.rows.count, 2, "refresh() must populate one row per SessionInfo from listAll()")
        XCTAssertEqual(Set(model.rows.map(\.id)), ["session-a", "session-b"])
    }

    // MARK: - Orphan detection (running, no SessionSurfaceMap entry)

    func test_refresh_runningSessionWithNoSurfaceEntry_isOrphan() async throws {
        daemonClient.sessionsToReturn = [makeInfo(id: "orphaned-session", state: .running)]
        // No surfaceMap.register call — this running session has no
        // live ghostty surface attached in this process.

        await model.refresh()

        let row = try XCTUnwrap(model.rows.first(where: { $0.id == "orphaned-session" }),
                                "refresh() must produce a row for every session listAll() returns")
        XCTAssertTrue(row.isOrphan, "A running session absent from SessionSurfaceMap must be flagged isOrphan")
        XCTAssertFalse(row.isAttachedHere)
    }

    func test_refresh_runningSessionWithSurfaceEntry_isNotOrphan_isAttachedHere() async throws {
        let sessionID = "attached-session"
        surfaceMap.register(sessionID: sessionID, surfaceID: UUID())
        daemonClient.sessionsToReturn = [makeInfo(id: sessionID, state: .running)]

        await model.refresh()

        let row = try XCTUnwrap(model.rows.first(where: { $0.id == sessionID }),
                                "refresh() must produce a row for every session listAll() returns")
        XCTAssertFalse(row.isOrphan,
                       "A running session WITH a live SessionSurfaceMap entry must not be flagged isOrphan")
        XCTAssertTrue(row.isAttachedHere)
    }

    // MARK: - Exited sessions are never orphans

    func test_refresh_exitedSession_neverFlaggedOrphan_regardlessOfSurfaceMap() async throws {
        daemonClient.sessionsToReturn = [makeInfo(id: "exited-session", state: .exited(code: 1))]
        // Deliberately no surfaceMap registration either — exited
        // sessions must be `isOrphan == false` regardless.

        await model.refresh()

        let row = try XCTUnwrap(model.rows.first(where: { $0.id == "exited-session" }),
                                "refresh() must produce a row for every session listAll() returns")
        XCTAssertFalse(row.isOrphan, "An exited session is never 'orphaned' — there is nothing running to reconnect to")
    }

    // MARK: - attach(_:) requests attaching via the injected callback

    func test_attach_invokesOnAttachRequested_withTheRow() async throws {
        daemonClient.sessionsToReturn = [makeInfo(id: "session-a", state: .running)]
        await model.refresh()
        let row = try XCTUnwrap(model.rows.first, "refresh() must have populated at least one row")

        var requestedRow: SessionBrowserRow?
        model.onAttachRequested = { requestedRow = $0 }

        model.attach(row)

        XCTAssertEqual(requestedRow?.id, row.id, "attach(_:) must invoke onAttachRequested with the row it was given")
    }

    // MARK: - kill(_:) calls daemonClient.kill(id:) with the row's session id

    func test_kill_callsDaemonClientKill_withRowSessionID() async throws {
        daemonClient.sessionsToReturn = [makeInfo(id: "session-to-kill", state: .running)]
        await model.refresh()
        let row = try XCTUnwrap(model.rows.first, "refresh() must have populated at least one row")

        await model.kill(row)

        XCTAssertEqual(daemonClient.killedIDs, ["session-to-kill"],
                       "kill(_:) must call daemonClient.kill(id:) with exactly the row's session id")
    }
}
