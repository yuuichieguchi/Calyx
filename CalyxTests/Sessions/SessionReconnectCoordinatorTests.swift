//
//  SessionReconnectCoordinatorTests.swift
//  CalyxTests
//
//  TDD Red Phase for SessionReconnectCoordinator: what to do when a
//  persistent-session surface's child process exits, given that macOS
//  never reports a trustworthy SHOW_CHILD_EXITED exit code (see
//  SessionDaemonClient.swift's header comment) — resolved instead by
//  querying the daemon directly through a fake
//  SessionDaemonClientProtocol.
//
//  Fix round (review findings, item 3) changes three things covered
//  here on top of the original contract:
//    (a) attempt tracking must survive a reconnect's surface swap
//        (keyed by sessionID, not surfaceID)
//    (b) a consecutive-failure cap (maxReconnectAttempts) must decide
//        .giveUp instead of reconnecting forever
//    (c) the gate is "does SessionSurfaceMap have a session for this
//        surface", not the global SessionSettings
//        .persistentSessionsEnabled toggle
//
//  Second fix round (give-up redesign) changes one more thing: .giveUp
//  used to carry a sessionID and its caller deliberately left the pane
//  open. It now carries no payload (the caller resolves whatever it
//  needs via SessionSurfaceMap/the surfaceID in hand), and the caller
//  (CalyxWindowController.handleReconnectGiveUp, see
//  SessionReconnectGiveUpTests) closes the pane with detach semantics
//  through the same path .closePane uses — a decision this coordinator
//  itself is not involved in and does not test.
//
//  Coverage:
//  - Daemon reports .exited -> .closePane
//  - Daemon reports .running -> .reconnect(attempt: 1)
//  - Daemon reports .unreachable -> .reconnect(attempt: 1)
//  - Repeated reconnect decisions for the same sessionID carry a
//    strictly increasing attempt count
//  - Attempt count persists across a surface replacement
//    (SessionSurfaceMap.replaceSurface), proving it's keyed by
//    sessionID and not surfaceID
//  - Exceeding maxReconnectAttempts decides .giveUp instead of
//    continuing to reconnect forever
//  - markEstablished(sessionID:) resets that session's attempt count
//    back to 0
//  - The gate is "SessionSurfaceMap has a session for this surface",
//    not the global toggle: no mapping -> never decides, regardless of
//    the toggle; a mapping present -> still decides even with the
//    toggle off
//

import XCTest
@testable import Calyx

/// Records every `sessionState(id:)` call and replays canned results in
/// order (repeating the last one once exhausted), and records every
/// `kill(id:)` call. A process boundary stand-in — no real
/// `calyx-session` binary involved.
private final class FakeSessionDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    private var results: [SessionQueryResult]
    private var index = 0
    private(set) var requestedIDs: [String] = []
    private(set) var killedIDs: [String] = []

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

    func kill(id: String) async {
        killedIDs.append(id)
    }
}

@MainActor
final class SessionReconnectCoordinatorTests: XCTestCase {

    private var surfaceMap: SessionSurfaceMap!
    private var recorded: [(surfaceID: UUID, decision: SessionReconnectDecision)] = []
    private let settingsSuiteName = "com.calyx.tests.SessionReconnectCoordinatorTests"

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

    // MARK: - Exited -> closePane

    func test_childExited_daemonReportsExited_decidesClosePane() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: [.exited(code: 0)]))

        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.surfaceID, surfaceID)
        XCTAssertEqual(recorded.first?.decision, .closePane,
                       "A daemon-confirmed exited session must close the pane, not reconnect")
    }

    // MARK: - Running -> reconnect(attempt: 1)

    func test_childExited_daemonReportsRunning_decidesReconnectAttempt1() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: [.running]))

        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.decision, .reconnect(sessionID: sessionID, attempt: 1),
                       "A still-running session (the attach process merely disconnected) must reconnect at attempt 1")
    }

    // MARK: - Unreachable -> reconnect(attempt: 1)

    func test_childExited_daemonUnreachable_decidesReconnectAttempt1() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: [.unreachable]))

        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.decision, .reconnect(sessionID: sessionID, attempt: 1),
                       "An unreachable daemon must be assumed reconnectable (attach --create is idempotent), not close the pane")
    }

    // MARK: - Repeated failures -> strictly increasing attempt (backoff shape)

    func test_repeatedUnreachable_attemptIncreasesEachConsecutiveCall() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: [.unreachable, .unreachable, .unreachable]))

        await coordinator.childExited(surfaceID: surfaceID)
        await coordinator.childExited(surfaceID: surfaceID)
        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertEqual(recorded.map(\.decision), [
            .reconnect(sessionID: sessionID, attempt: 1),
            .reconnect(sessionID: sessionID, attempt: 2),
            .reconnect(sessionID: sessionID, attempt: 3),
        ], "Each consecutive reconnect decision for the same surface must carry a strictly increasing " +
           "attempt count, the value a caller derives an exponential backoff delay from")
    }

    // MARK: - Attempt persists across a surface replacement (fix round, item 3a)

    func test_attemptCount_persistsAcrossSurfaceReplacement_keyedBySessionIDNotSurfaceID() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let oldSurfaceID = UUID()
        let newSurfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: oldSurfaceID)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: [.unreachable, .unreachable]))

        await coordinator.childExited(surfaceID: oldSurfaceID)

        // Simulate what performReconnect does on a .reconnect decision:
        // a fresh surface replaces the old one in SessionSurfaceMap.
        surfaceMap.replaceSurface(old: oldSurfaceID, new: newSurfaceID)

        await coordinator.childExited(surfaceID: newSurfaceID)

        XCTAssertEqual(recorded.map(\.decision), [
            .reconnect(sessionID: sessionID, attempt: 1),
            .reconnect(sessionID: sessionID, attempt: 2),
        ], "The attempt count for this sessionID must keep incrementing across a surface replacement, " +
           "proving it's tracked by sessionID rather than being silently reset by tracking surfaceID instead")
    }

    // MARK: - Cap: exceeding maxReconnectAttempts decides .giveUp
    //
    // Regression coverage: exceeding the cap used to decide `.closePane`,
    // which conflated two distinct situations under one kill-semantics
    // close: "the daemon confirmed the session really exited" (kill is
    // correct) versus "reconnect attempts were merely exhausted, the
    // daemon may still be legitimately running" (detach, not kill, is
    // correct). `.giveUp` keeps those cases distinguishable for the
    // caller (`CalyxWindowController.handleReconnectGiveUp`), which
    // closes the pane with detach semantics through the same
    // `closeSurfaceAndCleanUp` path as `.closePane`, rather than the
    // coordinator itself deciding kill-vs-detach.

    func test_repeatedUnreachable_exceedingMaxAttempts_decidesGiveUp() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let maxAttempts = SessionReconnectCoordinator.maxReconnectAttempts
        let results = [SessionQueryResult](repeating: .unreachable, count: maxAttempts + 1)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: results))

        for _ in 0..<maxAttempts {
            await coordinator.childExited(surfaceID: surfaceID)
        }
        XCTAssertEqual(recorded.map(\.decision), (1...maxAttempts).map { .reconnect(sessionID: sessionID, attempt: $0) },
                       "Every attempt up to and including maxReconnectAttempts must still reconnect")

        // One more consecutive failure exceeds the cap.
        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertEqual(recorded.last?.decision, .giveUp,
                       "Exceeding maxReconnectAttempts consecutive failures must decide .giveUp instead of " +
                       "continuing to reconnect forever")
    }

    // MARK: - After giving up, a fresh disconnect starts a new cycle from attempt 1

    func test_afterGiveUp_attemptCountReset_soANewDisconnectRestartsAtOne() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let maxAttempts = SessionReconnectCoordinator.maxReconnectAttempts
        let results = [SessionQueryResult](repeating: .unreachable, count: maxAttempts + 2)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: results))

        for _ in 0...maxAttempts {
            await coordinator.childExited(surfaceID: surfaceID)
        }
        XCTAssertEqual(recorded.last?.decision, .giveUp)

        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertEqual(recorded.last?.decision, .reconnect(sessionID: sessionID, attempt: 1),
                       "giveUp must clear the attempt counter just like markEstablished/markClosed, so a " +
                       "later, unrelated disconnect backs off from attempt 1 again instead of giving up immediately")
    }

    // MARK: - markEstablished(sessionID:) resets backoff

    func test_afterMarkEstablished_nextReconnectAttemptRestartsAtOne() async {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(
            results: [.unreachable, .unreachable, .unreachable]
        ))

        await coordinator.childExited(surfaceID: surfaceID) // attempt 1
        await coordinator.childExited(surfaceID: surfaceID) // attempt 2
        coordinator.markEstablished(sessionID: sessionID)
        await coordinator.childExited(surfaceID: surfaceID) // should restart at 1

        XCTAssertEqual(recorded.map(\.decision), [
            .reconnect(sessionID: sessionID, attempt: 1),
            .reconnect(sessionID: sessionID, attempt: 2),
            .reconnect(sessionID: sessionID, attempt: 1),
        ], "markEstablished must reset the attempt counter so a later, unrelated disconnect backs off from 1 again")
    }

    // MARK: - Gate: SessionSurfaceMap presence, not the global toggle (fix round, item 3c)
    //
    // Replaces the original contract's "settings OFF -> never decides"
    // test: that test conflated the global toggle with the per-surface
    // gate. The corrected contract is that a surface already tracked as
    // a persistent session (has an entry in SessionSurfaceMap) must
    // keep being managed for reconnect purposes regardless of the
    // toggle — the toggle only affects SessionSpawnPlanner's decision
    // for *new* surfaces, not the fate of ones already running. Split
    // into two tests below: the gate is surfaceMap presence in both
    // directions, independent of the toggle.

    func test_noSessionForSurface_childExited_neverDecides_regardlessOfToggle() async {
        // No surfaceMap.register call at all — this surface is not a
        // persistent-session surface.
        let surfaceID = UUID()
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: [.exited(code: 0)]))

        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertTrue(recorded.isEmpty,
                     "A surface with no tracked session must never produce a decision, whether or not " +
                     "the global toggle happens to be on")
    }

    func test_settingsOff_surfaceHasTrackedSession_stillManaged() async {
        SessionSettings.persistentSessionsEnabled = false
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        surfaceMap.register(sessionID: sessionID, surfaceID: surfaceID)
        let coordinator = makeCoordinator(daemon: FakeSessionDaemonClient(results: [.running]))

        await coordinator.childExited(surfaceID: surfaceID)

        XCTAssertEqual(recorded.first?.decision, .reconnect(sessionID: sessionID, attempt: 1),
                       "A surface already tracked in SessionSurfaceMap must still be managed even with " +
                       "the global 'start new panes as persistent' toggle off — turning the toggle off " +
                       "must not abandon sessions that already exist")
    }
}
