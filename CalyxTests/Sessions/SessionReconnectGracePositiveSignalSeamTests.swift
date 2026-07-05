//
//  SessionReconnectGracePositiveSignalSeamTests.swift
//  CalyxTests
//
//  TDD Red phase (COMPILE-RED, HELD-OUT FILE) for round-18 finding G6:
//  the reconnect grace task (`CalyxWindowController.performReconnect`'s
//  deferred `markEstablished(sessionID:)` confirmation `Task`, see that
//  method's own doc comment and `SessionReconnectEstablishGraceSeamTests`
//  for the grace-period fix this builds on) resets the attempt counter
//  on TIME ALONE: once `reconnectEstablishGraceMilliseconds` elapses and
//  `SessionSurfaceMap.shared.surfaceID(for: sessionID) == newSurfaceID`
//  still holds, it calls `markEstablished` unconditionally -- it never
//  asks whether the replacement is actually, positively connected.
//
//  THE RESIDUAL BUG: an attach process that dies SLOWER than the grace
//  window (e.g. a ~2.5s die/respawn cycle against a daemon that keeps
//  answering `.running`/`.unreachable`) gets its attempt count reset
//  every single cycle by the surface-identity check alone (the surface
//  itself is never swapped out again in this scenario, so that check
//  keeps passing). The count never advances past 1, backoff never
//  grows past 0s, and `SessionReconnectCoordinator.maxReconnectAttempts`
//  is never reached, so `.giveUp` never fires: an unbounded reconnect
//  loop at roughly the grace-window's own cadence, distinct from (and
//  slower than) the full-speed flashing loop
//  `SessionReconnectAttemptResetTimingTests` already covers. `.exited`
//  still routes straight to `.closePane` (see
//  `SessionReconnectCoordinator.childExited`), so this is scoped
//  entirely to the `.running`/`.unreachable` branch.
//
//  THE FIX CONTRACT: establishment requires POSITIVE evidence that the
//  CURRENT replacement is actually connected, not just that time has
//  passed and the surface wasn't swapped out again. Concretely, at
//  grace-fire, in addition to the existing surface-identity check, the
//  controller must consult a daemon probe and only call
//  `markEstablished` when that probe reports the session `Running`
//  AND `attachedClients >= 1` (`SessionInfo.attachedClients`, already
//  parsed from `ls --all --json`'s `attached_clients` field -- see
//  `SessionDaemonClient.swift`). Any other answer (exited, unreachable,
//  running with zero attached clients) OR a probe that fails/times out
//  must leave the attempt count untouched -- fail-closed: wrongly not
//  resetting only delays backoff recovery, wrongly resetting reopens
//  this exact unbounded loop.
//
//  PROPOSED SEAM (none of this exists in the codebase yet):
//
//    enum ReconnectGraceProbeResult: Sendable, Equatable {
//        case established
//        case notEstablished
//    }
//
//    #if DEBUG
//    extension CalyxWindowController {
//        var _reconnectGraceProbeForTesting: (() async throws -> ReconnectGraceProbeResult)? { get set }
//    }
//    #endif
//
//  `CalyxWindowController.performReconnect`'s grace `Task` would consult
//  a new private `reconnectGraceProbe(sessionID:) async ->
//  ReconnectGraceProbeResult` immediately before its existing
//  `markEstablished` call, gated on the SAME surface-identity check
//  already there (not instead of it -- both must hold):
//
//    if !Task.isCancelled, SessionSurfaceMap.shared.surfaceID(for: sessionID) == newSurfaceID,
//       await self.reconnectGraceProbe(sessionID: sessionID) == .established {
//        self.sessionReconnectCoordinator.markEstablished(sessionID: sessionID)
//    }
//
//  `reconnectGraceProbe(sessionID:)` itself, mirroring
//  `createReconnectSurface`'s `#if DEBUG`-hook-first/real-fallback shape
//  exactly: under `#if DEBUG`, if `_reconnectGraceProbeForTesting` is
//  set, `(try? await hook()) ?? .notEstablished` (a throwing hook is
//  fail-closed by construction -- see T3 below); otherwise, the real
//  probe reuses the EXISTING `listAllBounded()` bounded-race helper
//  (`SessionDaemonClientProtocol`'s extension, already used by
//  `SessionBrowserModel.refresh()`/`AppDelegate.fetchSessionsForAgentResume()`)
//  against `SessionDaemonClient.shared` -- the same singleton
//  `sessionReconnectCoordinator`'s own `init` already wires in above --
//  rather than adding a second daemon-query primitive: find the
//  `SessionInfo` matching `sessionID`, and report `.established` only
//  if `match.state == .running && match.attachedClients >= 1`; a
//  missing match, `.exited`, or `listAllBounded()`'s own already-bounded
//  degrade-to-`[]`-on-timeout/unreachable all fall through to
//  `.notEstablished` for free, with no new bound needed.
//
//  NONE of `ReconnectGraceProbeResult`, `_reconnectGraceProbeForTesting`,
//  or `reconnectGraceProbe(sessionID:)` exist yet -- `performReconnect`
//  today calls `markEstablished` from the surface-identity check alone.
//  Following this codebase's established convention for new-API RED
//  tests (see `SessionReconnectEstablishGraceSeamTests`'s header
//  comment, itself citing `SessionDaemonClientSessionStateBoundTimeoutSeamTests`
//  and `CalyxWindowControllerFullScreenTests`), this file is expected to
//  FAIL TO COMPILE until the TDD Green phase adds the seam above. That
//  compile failure IS this contract's RED evidence.
//
//  THIS IS THE "HELD-OUT" FILE for this round: it must be excluded from
//  the build (e.g. temporarily moved out of `CalyxTests/`) while running
//  the rest of the round's RED suite, since a compile failure anywhere
//  in the `CalyxTests` target fails the WHOLE target (Swift compiles a
//  target as one module) -- otherwise no other test, old or new, could
//  be verified at all. Verify this file's specific compiler errors with
//  a separate, standalone attempt once the rest of the suite is
//  confirmed green/RED as expected.
//
//  COORDINATION NOTE for whoever implements Green: once the probe
//  requirement lands, `SessionReconnectEstablishGraceSeamTests`'s
//  existing `test_performReconnect_replacementSurvivesGracePeriod_attemptCountEventuallyResets`
//  drives a real `performReconnect` with `CALYX_SESSION_BIN=/usr/bin/true`
//  and never registers `sessionID` with any real or fake daemon ledger.
//  The real, un-hooked `reconnectGraceProbe(sessionID:)` fallback would
//  call the real `SessionDaemonClient.shared.listAllBounded()`, find no
//  matching session, and report `.notEstablished` -- breaking that
//  test's expectation that the count eventually resets, under strict
//  fail-closed semantics. That test will need its own
//  `_reconnectGraceProbeForTesting = { .established }` addition
//  alongside the Green fix, not left as-is.
//
//  Reuses the exact fixture/seam approach
//  `SessionReconnectEstablishGraceSeamTests`/`SessionReconnectAttemptResetTimingTests`
//  already establish (`_performReconnectSurfaceCreationHookForTesting`,
//  `_sessionReconnectCoordinatorForTesting`,
//  `SessionReconnectCoordinator._testSeedAttemptCount(sessionID:count:)`,
//  the `CALYX_SESSION_BIN` env override, the inactive-second-tab fixture
//  shape) -- see those files' own header comments for why each is
//  necessary/safe. `pumpRunLoop`/`ReconnectFixture`/`makeReconnectFixture`
//  themselves now live in the shared `CalyxTests/ReconnectFixture.swift`
//  (round-18 cleanup consolidating what used to be three byte-identical
//  per-file copies).
//
//  Coverage:
//  - T1: grace fires, surface identity intact, probe reports
//    `.notEstablished` (e.g. attachedClients == 0 / session
//    unreachable) -- the seeded attempt count must stay UNCHANGED past
//    the grace window (the bug: today's unconditional reset would wipe
//    it).
//  - T2: grace fires, surface identity intact, probe reports
//    `.established` (session Running, attachedClients >= 1) -- the
//    attempt count DOES reset (the legitimate establishment path must
//    keep working under the fix).
//  - T3: grace fires, surface identity intact, probe THROWS -- fail-
//    closed, the attempt count must stay UNCHANGED, exactly like an
//    explicit `.notEstablished` answer.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class SessionReconnectGracePositiveSignalSeamTests: XCTestCase {

    private var registeredSessionIDs: [String] = []

    private struct ProbeFailure: Error {}

    override func tearDown() {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = nil
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// Common driver for all three tests below: overrides the grace
    /// period to a tiny value, seeds `attemptCounts[sessionID] = 2`
    /// (simulating two prior consecutive reconnect failures already
    /// recorded), points `_reconnectGraceProbeForTesting` at `probe`,
    /// and drives a real `.reconnect(attempt: 1)` decision through the
    /// real, unmodified `performReconnect`, waiting for the surface
    /// swap to visibly complete before returning.
    private func driveReconnect(
        probe: @escaping () async throws -> ReconnectGraceProbeResult
    ) -> ReconnectFixture {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = 30

        let fixture = makeReconnectFixture()
        registeredSessionIDs.append(fixture.sessionID)
        fixture.controller._sessionReconnectCoordinatorForTesting._testSeedAttemptCount(
            sessionID: fixture.sessionID, count: 2
        )

        let newSurfaceID = UUID()
        fixture.tab.registry._testInsert(view: SurfaceView(frame: .zero), id: newSurfaceID)
        fixture.controller._performReconnectSurfaceCreationHookForTesting = { newSurfaceID }
        fixture.controller._reconnectGraceProbeForTesting = probe

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

    /// RED (COMPILE-RED per this file's header comment).
    ///
    /// T1 -- the bug's own direct coverage: the probe reports
    /// `.notEstablished` (e.g. the daemon says the session is
    /// unreachable, or Running with zero attached clients). Surface
    /// identity is intact (the replacement was never swapped out
    /// again), so today's surface-identity-only check would wrongly
    /// reset the count anyway. The seeded count must still read `2`
    /// well past the (tiny, overridden) grace window.
    func test_probeReportsNotEstablished_attemptCountStaysUnchanged() {
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

        let fixture = driveReconnect(probe: { .notEstablished })

        // Give the 30ms grace task every chance to fire and (wrongly)
        // reset the count -- poll for a change for well longer than
        // the override, then assert none happened.
        pumpRunLoop(timeout: 0.3) {
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID] != 2
        }

        XCTAssertEqual(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID], 2,
            "A grace-fire probe reporting .notEstablished (session not confirmed Running with an " +
            "attached client) must NOT reset the attempt count -- elapsed time and surface identity " +
            "alone are not positive evidence the replacement is actually connected. Resetting here " +
            "reopens an unbounded reconnect loop at roughly the grace window's own cadence."
        )
    }

    /// RED (COMPILE-RED per this file's header comment).
    ///
    /// T2 -- the legitimate establishment path must still work under
    /// the fix: the probe reports `.established` (session Running,
    /// attachedClients >= 1), so the attempt count DOES reset, exactly
    /// like `SessionReconnectEstablishGraceSeamTests`'s existing
    /// coverage of the grace-period-alone fix, but now driven
    /// explicitly through the probe rather than surface identity alone.
    func test_probeReportsEstablished_attemptCountResets() {
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

        let fixture = driveReconnect(probe: { .established })

        pumpRunLoop(timeout: 1.0) {
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID] == nil
        }

        XCTAssertNil(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID],
            "A grace-fire probe reporting .established (session Running, attachedClients >= 1) is " +
            "exactly the positive evidence markEstablished's legitimate purpose needs -- the attempt " +
            "count must still reset once the replacement is confirmed CONNECTED, not merely confirmed " +
            "to still exist under the same surface UUID."
        )
    }

    /// RED (COMPILE-RED per this file's header comment).
    ///
    /// T3 -- fail-closed: a probe that throws (daemon query failed, or
    /// stands in for a bounded call timing out) must be treated exactly
    /// like an explicit `.notEstablished` answer, not like success. The
    /// seeded count must stay unchanged.
    func test_probeThrows_attemptCountStaysUnchanged() {
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

        let fixture = driveReconnect(probe: { throw ProbeFailure() })

        pumpRunLoop(timeout: 0.3) {
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID] != 2
        }

        XCTAssertEqual(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID], 2,
            "A probe that throws (the daemon query failed or timed out) must be treated exactly like " +
            "an explicit .notEstablished answer -- fail-closed. Wrongly resetting on a failed probe " +
            "reopens the same unbounded reconnect loop an explicit .notEstablished answer must also avoid."
        )
    }
}
