//
//  SessionReconnectCoordinatorRemoteAwareChildExitedTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, BUG 2 (five-angle convergence review
//  finding, CRITICAL): SessionReconnectCoordinator.childExited misreads
//  a REMOTE session as exited. SessionDaemonClient.sessionState(id:)
//  queries the LOCAL calyx-session daemon's `ls --all --json` ledger
//  only; a remote session's id is NEVER present in that LOCAL ledger, so
//  the "id absent even from --all" branch (SessionDaemonClient.swift's
//  own `.exited(code: 0)` fallback comment) ALWAYS fires for a remote
//  session, even while it is perfectly alive on the remote host. With a
//  live local daemon, a remote pane's very first disconnect therefore
//  closes the pane INSTANTLY, with zero reconnect attempts -- exactly
//  the failure mode SessionReconnectCoordinator.childExited's own doc
//  comment (lines ~100-111) currently documents as an "ACCEPTED V1
//  LIMITATION". This round retires that limitation.
//
//  FIX CONTRACT: childExited must know remoteness. Threaded in as a new
//  `isRemote: Bool = false` parameter -- defaulting to `false` keeps
//  EVERY existing call site (both production's
//  CalyxWindowController.processChildExited and every test in
//  SessionReconnectCoordinatorTests) compiling and behaviorally
//  unchanged; only a caller that explicitly passes `isRemote: true`
//  exercises the new branch. When `isRemote` is `true`, childExited must
//  SKIP the local daemon query (`daemonClient.sessionStateBounded(id:)`)
//  entirely -- not merely ignore its result, never issue it at all, since
//  the local daemon has no way to answer a question about a session it
//  never spawned -- and treat the disconnect as retryable exactly like
//  today's `.running`/`.unreachable` branch: increment the attempt
//  counter, `.reconnect` while under `maxReconnectAttempts`, `.giveUp`
//  once exceeded. `isRemote: false` (the default) must behave IDENTICALLY
//  to today's code: query the daemon, branch on `.exited`/`.running`/
//  `.unreachable` exactly as before.
//
//  PROPOSED FIX sketch (childExited):
//
//    func childExited(surfaceID: UUID, isRemote: Bool = false) async {
//        guard let sessionID = surfaceMap.sessionID(for: surfaceID) else { return }
//        guard !inFlightSurfaceIDs.contains(surfaceID) else { return }
//        inFlightSurfaceIDs.insert(surfaceID)
//        defer { inFlightSurfaceIDs.remove(surfaceID) }
//
//        if isRemote {
//            let attempt = (attemptCounts[sessionID] ?? 0) + 1
//            guard attempt <= Self.maxReconnectAttempts else {
//                attemptCounts[sessionID] = nil
//                onDecision(surfaceID, .giveUp)
//                return
//            }
//            attemptCounts[sessionID] = attempt
//            onDecision(surfaceID, .reconnect(sessionID: sessionID, attempt: attempt))
//            return
//        }
//
//        switch await daemonClient.sessionStateBounded(id: sessionID) {
//        ... // unchanged
//        }
//    }
//
//  Also retires the now-false "ACCEPTED V1 LIMITATION" doc comment on
//  this method (SessionReconnectCoordinator.swift ~100-111), which
//  explicitly describes exactly the bug this file's tests prove.
//
//  NOT in scope for this file (per this round's brief): threading
//  `isRemote` from CalyxWindowController.processChildExited via
//  `tab.sessionRefs[surfaceID]?.host != nil` (the controller-level half
//  of this fix) -- these are coordinator-level tests only, driving
//  `childExited(surfaceID:isRemote:)` directly with a fake daemon client,
//  exactly like the existing SessionReconnectCoordinatorTests file this
//  one sits alongside.
//
//  Held-out compile-RED file per this codebase's established convention:
//  `childExited(surfaceID:isRemote:)`'s `isRemote` parameter does not
//  exist yet -- every call in this file passing `isRemote:` explicitly
//  fails to compile. Expected to FAIL TO COMPILE until the Green phase
//  adds the parameter. That compile failure IS this file's RED evidence.
//  Must be excluded from the build while running the rest of the round's
//  RED suite and verified separately for its own specific compiler
//  errors. (SessionReconnectCoordinatorTests itself is UNAFFECTED and
//  stays green throughout, since the new parameter's default value keeps
//  its every existing call compiling unchanged.)
//
//  Coverage:
//  - isRemote: true + daemon configured to report .exited(code: 0) ->
//    .reconnect(attempt: 1), NOT .closePane -- the core bug fix
//  - ...and the local daemon's sessionState(id:) is NEVER queried at all
//    when isRemote is true (proven via the fake's own request-recording,
//    already used by the existing coordinator test file)
//  - isRemote: false (explicit) + the same daemon reporting .exited ->
//    .closePane, unchanged from today -- regression guard
//  - Exceeding maxReconnectAttempts consecutive isRemote: true disconnects
//    still decides .giveUp, exactly like the existing local unreachable
//    cap test
//

import XCTest
@testable import Calyx

/// Records every `sessionState(id:)` call and replays canned results in
/// order (repeating the last one once exhausted). A local duplicate of
/// SessionReconnectCoordinatorTests' own FakeSessionDaemonClient, per
/// this codebase's established per-file fixture-duplication convention.
private final class FakeSessionDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    private var results: [SessionQueryResult]
    private var index = 0
    private(set) var requestedIDs: [String] = []

    init(results: [SessionQueryResult]) {
        self.results = results
    }

    func sessionState(id: String) async -> SessionQueryResult {
        requestedIDs.append(id)
        guard !results.isEmpty else { return .unreachable }
        let result = results[min(index, results.count - 1)]
        index += 1
        return result
    }

    func kill(id: String) async {}
}

@MainActor
final class SessionReconnectCoordinatorRemoteAwareChildExitedTests: XCTestCase {

    private var surfaceMap: SessionSurfaceMap!
    private var recorded: [(surfaceID: UUID, decision: SessionReconnectDecision)] = []
    private let settingsSuiteName = "com.calyx.tests.SessionReconnectCoordinatorRemoteAwareChildExitedTests"

    override func setUp() {
        super.setUp()
        surfaceMap = SessionSurfaceMap()
        recorded = []
        SessionSettings._testUseSuite(named: settingsSuiteName)
        SessionSettings.persistentSessionsEnabled = true
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        surfaceMap = nil
        recorded = []
        super.tearDown()
    }

    private func makeCoordinator(daemon: SessionDaemonClientProtocol) -> SessionReconnectCoordinator {
        SessionReconnectCoordinator(daemonClient: daemon, surfaceMap: surfaceMap) { [weak self] surfaceID, decision in
            self?.recorded.append((surfaceID, decision))
        }
    }

    // MARK: - Core bug fix: a remote session misreported .exited(0) must reconnect, not close

    func test_childExited_isRemoteTrue_daemonWouldReportExited_decidesReconnectNotClosePane() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        // Exactly what SessionDaemonClient.sessionState(id:) actually
        // returns for ANY remote id today (SessionDaemonClient.swift's
        // "id absent even from --all" fallback) -- the LOCAL daemon has
        // never heard of this remote session at all.
        let daemon = FakeSessionDaemonClient(results: [.exited(code: 0)])
        let coordinator = makeCoordinator(daemon: daemon)

        await coordinator.childExited(surfaceID: surfaceID, isRemote: true)

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.decision, .reconnect(sessionID: sessionID, attempt: 1),
                       "A remote session's disconnect must reconnect, never close the pane on the strength " +
                       "of a LOCAL daemon's .exited(0) fallback that only means \"this id is not in MY " +
                       "ledger\", not \"this session actually ended\"")
    }

    func test_childExited_isRemoteTrue_neverQueriesTheLocalDaemonAtAll() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let daemon = FakeSessionDaemonClient(results: [.exited(code: 0)])
        let coordinator = makeCoordinator(daemon: daemon)

        await coordinator.childExited(surfaceID: surfaceID, isRemote: true)

        XCTAssertTrue(daemon.requestedIDs.isEmpty,
                      "A remote disconnect must skip the local daemon query entirely -- the local daemon has " +
                      "no record of a session it never spawned, so asking it at all is meaningless, not just " +
                      "unreliable")
    }

    // MARK: - Regression guard: isRemote false keeps today's behavior

    func test_childExited_isRemoteFalseExplicit_daemonReportsExited_stillDecidesClosePane() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let daemon = FakeSessionDaemonClient(results: [.exited(code: 0)])
        let coordinator = makeCoordinator(daemon: daemon)

        await coordinator.childExited(surfaceID: surfaceID, isRemote: false)

        XCTAssertEqual(recorded.first?.decision, .closePane,
                       "A LOCAL session (isRemote: false) confirmed exited by its own daemon must still " +
                       "close the pane exactly as today -- unchanged regression behavior")
        XCTAssertEqual(daemon.requestedIDs, [sessionID],
                       "...and must still query the local daemon exactly once, since it IS the authority " +
                       "for a local session")
    }

    // MARK: - Attempt-cap giveUp still fires for remote

    func test_repeatedIsRemoteTrueDisconnects_exceedingMaxAttempts_stillDecidesGiveUp() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let maxAttempts = SessionReconnectCoordinator.maxReconnectAttempts
        // The daemon fake's results are irrelevant here (isRemote skips
        // querying it entirely) -- an empty result list still degrades
        // to .unreachable per the fake's own contract, never consulted.
        let daemon = FakeSessionDaemonClient(results: [])
        let coordinator = makeCoordinator(daemon: daemon)

        for _ in 0..<maxAttempts {
            await coordinator.childExited(surfaceID: surfaceID, isRemote: true)
        }
        XCTAssertEqual(recorded.map(\.decision), (1...maxAttempts).map { .reconnect(sessionID: sessionID, attempt: $0) },
                       "Every remote attempt up to and including maxReconnectAttempts must still reconnect")

        await coordinator.childExited(surfaceID: surfaceID, isRemote: true)

        XCTAssertEqual(recorded.last?.decision, .giveUp,
                       "Exceeding maxReconnectAttempts consecutive remote disconnects must still decide " +
                       ".giveUp, exactly like the existing local-unreachable cap contract -- this fix must " +
                       "not accidentally let a remote session retry forever")
        XCTAssertTrue(daemon.requestedIDs.isEmpty, "None of these remote attempts must ever query the local daemon")
    }
}
