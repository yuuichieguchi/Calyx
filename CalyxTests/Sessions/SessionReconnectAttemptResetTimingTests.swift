//
//  SessionReconnectAttemptResetTimingTests.swift
//  CalyxTests
//
//  TDD Red phase for the HIGH-SPEED RECONNECT FLASHING bug:
//  `CalyxWindowController.performReconnect` calls
//  `sessionReconnectCoordinator.markEstablished(sessionID:)`
//  unconditionally, immediately after swapping in the replacement
//  surface -- BEFORE the replacement has had any chance to prove it is
//  actually alive. Against a still-unreachable daemon, the
//  replacement's attach process dies right away,
//  GHOSTTY_ACTION_SHOW_CHILD_EXITED fires again for it, but the
//  attempt counter was already reset to 0 by the premature
//  `markEstablished` call, so the next decision is treated as attempt
//  1 again (0s backoff, see `reconnectBackoffSeconds(forAttempt:)`)
//  instead of attempt 2+: an infinite full-speed reconnect loop (the
//  user-visible pane flashing) that never accumulates toward
//  `SessionReconnectCoordinator.maxReconnectAttempts` and so never
//  gives up.
//
//  THE INTENDED FIX (covered by SessionReconnectEstablishGraceSeamTests,
//  a held-out compile-RED file, not this one): the attempt counter
//  must reset ONLY once the replacement surface survives a grace
//  period without its own child exiting, not merely because it was
//  created. This file covers the bug itself -- the premature reset --
//  which is already fully reproducible against the CURRENT,
//  unmodified `performReconnect`.
//
//  SAFETY / WHY THIS USES SEAMS INSTEAD OF DRIVING A REAL RECONNECT:
//  `performReconnect` creates a real ghostty surface via
//  `tab.registry.createSurface` -- confirmed unsafe/hangs the XCTest
//  process indefinitely (see `AppDelegateAttachWindowTests`'s header
//  comment for the same finding at a different call site). This file
//  relies on `CalyxWindowController
//  ._performReconnectSurfaceCreationHookForTesting`, mirroring
//  `AppDelegate._createSurfaceWithPwdHookForTesting`'s exact style and
//  reasoning, intercepting only that one call; every guard and step
//  around it in `performReconnect` -- including the `markEstablished`
//  call this bug is about -- runs for real, unmodified.
//
//  Likewise, driving the real `SessionReconnectCoordinator.childExited
//  (surfaceID:)` end-to-end (rather than constructing a
//  `.reconnect(...)` decision directly and handing it to
//  `handleSessionReconnectDecision`, this file's approach, matching
//  `SessionReconnectGiveUpTests`'s established convention) would
//  round-trip through the REAL, hardcoded `SessionDaemonClient.shared`
//  singleton: `performReconnect`'s `sessionReconnectCoordinator` is
//  wired directly to it (not injectable at the controller level), and
//  its actual behavior in this test host (real subprocess spawn vs.
//  immediate `.unreachable`, depending on whether a `calyx-session`
//  binary happens to be bundled/resolvable) is not something this file
//  should depend on. `SessionReconnectCoordinatorTests` already fully
//  covers the coordinator's own increment/cap logic against a fake
//  daemon; this file only needs to observe whether `performReconnect`
//  wipes an in-progress attempt count immediately upon the surface
//  swap, which `CalyxWindowController._sessionReconnectCoordinatorForTesting`
//  (read-only) and `SessionReconnectCoordinator
//  ._testSeedAttemptCount(sessionID:count:)` (both new, minimal, DEBUG-
//  gated seams, changing no production behavior) let it assert
//  directly, without any of that unrelated machinery.
//
//  Coverage:
//  - performReconnect must NOT reset sessionID's attempt count
//    immediately upon swapping in the replacement surface (the bug): a
//    count already at N when performReconnect runs must still be N
//    right after the swap, not nil/reset.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class SessionReconnectAttemptResetTimingTests: XCTestCase {

    /// sessionIDs registered with `SessionSurfaceMap.shared` by
    /// `makeReconnectFixture()`, unregistered in `tearDown` (the map is
    /// a process-wide singleton shared across the whole test run).
    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    /// The bug itself. Against the CURRENT code, `performReconnect`
    /// calls `sessionReconnectCoordinator.markEstablished(sessionID:)`
    /// unconditionally right after the surface swap, wiping
    /// `attemptCounts[sessionID]` back to `nil` regardless of whether
    /// the replacement has proven itself alive yet. Seeding
    /// `attemptCounts[sessionID] = 2` beforehand (simulating two prior
    /// consecutive reconnect failures already recorded) and then
    /// driving a real `.reconnect(attempt: 1)` decision through the
    /// real, unmodified `performReconnect` proves this directly: the
    /// count must still read `2` immediately after the swap (the
    /// fix's intended behavior -- reset happens only once a grace
    /// period confirms the replacement survived), but today it reads
    /// `nil`.
    func test_performReconnect_doesNotResetAttemptCountImmediately_uponSwappingInReplacementSurface() {
        let fixture = makeReconnectFixture()
        registeredSessionIDs.append(fixture.sessionID)
        fixture.controller._sessionReconnectCoordinatorForTesting._testSeedAttemptCount(
            sessionID: fixture.sessionID, count: 2
        )

        // CALYX_SESSION_BIN env override (SessionBinaryResolver's own
        // documented test-injection seam, see
        // AppDelegateOfferAgentResumePipelineBoundTests for the same
        // pattern) makes SessionCommandSynthesizer.reattachCommand
        // resolve to a non-nil command, without which performReconnect
        // would bail out ("No calyx-session binary resolvable") before
        // ever reaching the surface-creation hook this test targets.
        // The path need not exist: the hook below intercepts before
        // any command is ever actually executed.
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

        let newSurfaceID = UUID()
        fixture.tab.registry._testInsert(view: SurfaceView(frame: .zero), id: newSurfaceID)
        fixture.controller._performReconnectSurfaceCreationHookForTesting = { newSurfaceID }

        fixture.controller.handleSessionReconnectDecision(
            surfaceID: fixture.trackedLeafID,
            decision: .reconnect(sessionID: fixture.sessionID, attempt: 1)
        )

        // attempt 1 backs off 0s (reconnectBackoffSeconds(forAttempt: 1)
        // == 0), but performReconnect still runs inside an async Task
        // hop -- pump until the swap has visibly happened (the
        // replacement leaf is in place).
        pumpRunLoop(timeout: 1.0) {
            fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID)
        }

        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID),
                      "Precondition: performReconnect must have actually swapped in the replacement surface")

        XCTAssertEqual(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID], 2,
            "performReconnect must not reset sessionID's attempt count immediately upon creating the " +
            "replacement surface -- only once that replacement is confirmed to have survived a grace " +
            "period. Resetting immediately (today's behavior) means a replacement that dies right away " +
            "restarts backoff at attempt 1 (0s delay) instead of accumulating toward the cap, which is " +
            "the high-speed reconnect flashing bug."
        )
    }
}
