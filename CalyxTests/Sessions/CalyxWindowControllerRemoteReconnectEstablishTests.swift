//
//  CalyxWindowControllerRemoteReconnectEstablishTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, contract R4 (ordinary, ASSERTION-based
//  RED -- no new production API needed, unlike this round's other
//  contracts; every seam this file uses already exists):
//
//  performReconnect's grace Task (round-18 finding G6, see
//  ReconnectGraceProbeResult's own doc comment) requires a POSITIVE
//  daemon probe (reconnectGraceProbe(sessionID:), which queries
//  SessionDaemonClient.shared -- the LOCAL calyx-session daemon)
//  reporting the session Running with attachedClients >= 1 before it
//  resets the reconnect attempt counter. That's correct for a LOCAL
//  session: the local daemon genuinely knows its own session's state.
//
//  THE BUG THIS ROUND MUST FIX: a REMOTE session's daemon lives entirely
//  on the remote machine (remoteAttachCommand's whole point). The LOCAL
//  daemon can never have a matching SessionInfo for it -- `listAllBounded()`
//  will forever return no match, so `reconnectGraceProbe` forever reports
//  `.notEstablished` for a remote sessionID, no matter how healthy the
//  remote session actually is. Under the CURRENT code, this means a
//  remote pane's attempt counter is NEVER reset by the grace check: two
//  independent, ordinary ssh disconnects occurring DAYS apart would
//  accumulate toward the SAME `maxReconnectAttempts` cap instead of each
//  starting fresh, eventually giving up (closing the pane) even though
//  each individual disconnect recovered fine on its own.
//
//  THE FIX CONTRACT (per this round's investigation, matching the local
//  path's own existing surface-identity-check precedent): for a REMOTE
//  session (its leaf's SessionRef.host != nil, read from tab.sessionRefs
//  the same way contract R3 does, captured at reconnect time before the
//  leaf remap overwrites the old key), grace establishment must fall
//  back to the surface-survival check ALONE -- i.e. exactly the
//  pre-G6 semantics -- once SessionSurfaceMap.shared.surfaceID(for:
//  sessionID) == newSurfaceID still holds past the grace window, WITHOUT
//  ever consulting reconnectGraceProbe at all. LOCAL session semantics
//  are UNCHANGED: the probe is still required.
//
//  THE ACCEPTED TRADEOFF (documented at the decision site per this
//  round's brief): a positive local probe of a remote session is
//  structurally impossible in v1 (no local knowledge of remote daemon
//  state), so the unbounded-slow-loop risk G6 fixed for the LOCAL case
//  is accepted, unmitigated, for remote panes -- bounded in practice by
//  ssh's own connection failures being comparatively slow (seconds,
//  not the sub-second churn G6's local-daemon scenario produced).
//
//  Reuses SessionReconnectGracePositiveSignalSeamTests' exact
//  driveReconnect shape (CalyxWindowControllerReconnectGraceOverrides
//  .reconnectEstablishGraceMilliseconds, _sessionReconnectCoordinatorForTesting
//  ._testSeedAttemptCount, _performReconnectSurfaceCreationHookForTesting,
//  the CALYX_SESSION_BIN env sentinel, pumpRunLoop), plus
//  makeReconnectFixture's new `host:` parameter (ReconnectFixture.swift).
//  DELIBERATELY never sets `_reconnectGraceProbeForTesting` at all in
//  either test below: the point is to observe the REAL,
//  un-hooked `reconnectGraceProbe` fallback's behavior (a bounded, but
//  real, SessionDaemonClient.shared.listAllBounded() call that can never
//  find a match for either fixture's fake sessionID), with
//  SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds
//  overridden down to 1s purely to keep this file's wall-clock runtime
//  bounded regardless of pre/post-fix behavior.
//
//  Coverage:
//  - T1 (the fix itself): a remote session (fixture host != nil) with no
//    probe hook set still resets its attempt count once the grace window
//    elapses with surface identity intact -- establishment falls back to
//    surface-survival alone, the real (always-.notEstablished-for-this-
//    sessionID) daemon probe must never gate it.
//  - T2 (regression guard): a local session (fixture host == nil), same
//    setup, must NOT reset -- the probe is still required for a local
//    session, matching this round's "local semantics unchanged" contract
//    and G6's own existing coverage.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerRemoteReconnectEstablishTests: XCTestCase {

    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = nil
        SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds = nil
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// Common driver, mirroring SessionReconnectGracePositiveSignalSeamTests
    /// .driveReconnect exactly, except `_reconnectGraceProbeForTesting` is
    /// deliberately left unset (nil) throughout -- both tests below need
    /// the REAL fallback probe's behavior, not a scripted one.
    private func driveReconnect(host: String?) -> ReconnectFixture {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = 30
        SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds = 1

        let fixture = makeReconnectFixture(host: host)
        registeredSessionIDs.append(fixture.sessionID)
        fixture.controller._sessionReconnectCoordinatorForTesting._testSeedAttemptCount(
            sessionID: fixture.sessionID, count: 2
        )

        let newSurfaceID = UUID()
        fixture.tab.registry._testInsert(view: SurfaceView(frame: .zero), id: newSurfaceID)
        fixture.controller._performReconnectSurfaceCreationHookForTesting = { newSurfaceID }

        fixture.controller.handleSessionReconnectDecision(
            surfaceID: fixture.trackedLeafID,
            decision: .reconnect(sessionID: fixture.sessionID, attempt: 1)
        )

        pumpRunLoop(timeout: 1.0) {
            fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID)
        }
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID),
                      "Precondition: performReconnect must have swapped in the replacement surface")

        return fixture
    }

    /// T1 -- the fix itself. Against the CURRENT code, `performReconnect`
    /// does not distinguish remote from local sessions at all: the grace
    /// Task always consults `reconnectGraceProbe`, which (with no test
    /// hook set) falls back to the real, bounded
    /// `SessionDaemonClient.shared.listAllBounded()` call. That call can
    /// never find this fixture's fake sessionID (nothing registered it
    /// with any real daemon), so it always resolves `.notEstablished`,
    /// and the seeded count of 2 stays at 2 forever -- exactly the bug
    /// this contract exists to fix.
    func test_performReconnect_remoteSession_establishesFromSurfaceSurvivalAlone_withoutDaemonProbe() throws {
        let localBin = "/tmp/calyx-session-sentinel-\(UUID().uuidString)"
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", localBin, 1)
        defer {
            if let originalBinPath { setenv("CALYX_SESSION_BIN", originalBinPath, 1) } else { unsetenv("CALYX_SESSION_BIN") }
        }

        let fixture = driveReconnect(host: "devbox.example.com")

        // Give the 30ms grace task, plus the (overridden, 1s-bounded)
        // real daemon probe it would consult under the CURRENT code,
        // every chance to run to completion before asserting.
        pumpRunLoop(timeout: 2.0) {
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID] == nil
        }

        XCTAssertNil(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID],
            "For a remote session (SessionRef.host != nil), establishment must fall back to the " +
            "surface-survival check alone once the grace window elapses with surface identity intact -- " +
            "a positive LOCAL daemon probe of a REMOTE session is structurally impossible (the local " +
            "daemon has no record of it at all), so requiring one (today's behavior) means the attempt " +
            "counter can never reset for a remote pane, and independent ssh disconnects occurring days " +
            "apart would wrongly accumulate toward the same permanent give-up cap instead of each " +
            "recovering independently."
        )
    }

    /// T2 -- regression guard: the local path's existing G6 semantics
    /// (probe required) must remain exactly as they are. Mirrors
    /// SessionReconnectGracePositiveSignalSeamTests
    /// .test_probeReportsNotEstablished_attemptCountStaysUnchanged, but
    /// through the REAL fallback probe (no `_reconnectGraceProbeForTesting`
    /// hook) rather than a scripted one, to prove directly that a local
    /// session's establishment still genuinely depends on a real,
    /// consulted daemon round-trip, not merely on some blanket bypass
    /// this contract's fix might otherwise be tempted to introduce.
    func test_performReconnect_localSession_stillRequiresDaemonProbe_regressionGuard() throws {
        let localBin = "/tmp/calyx-session-sentinel-\(UUID().uuidString)"
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", localBin, 1)
        defer {
            if let originalBinPath { setenv("CALYX_SESSION_BIN", originalBinPath, 1) } else { unsetenv("CALYX_SESSION_BIN") }
        }

        let fixture = driveReconnect(host: nil)

        pumpRunLoop(timeout: 2.0) {
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID] != 2
        }

        XCTAssertEqual(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID], 2,
            "For a local session (SessionRef.host == nil), establishment must still require a genuine " +
            "daemon probe reporting .established -- this round's remote-session fallback must not " +
            "regress the local path G6 already fixed. The real fallback probe can never find this " +
            "fixture's fake sessionID, so it must report .notEstablished and leave the seeded count " +
            "unchanged, exactly as it does today."
        )
    }
}
