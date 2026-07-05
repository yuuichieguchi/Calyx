//
//  SessionReconnectEstablishGraceSeamTests.swift
//  CalyxTests
//
//  TDD Red phase (COMPILE-RED, HELD-OUT FILE) for the eventual fix to
//  the HIGH-SPEED RECONNECT FLASHING bug covered directly by
//  SessionReconnectAttemptResetTimingTests (see that file's header
//  comment for the bug itself): `CalyxWindowController.performReconnect`
//  must reset sessionID's attempt count (via
//  `sessionReconnectCoordinator.markEstablished(sessionID:)`) only once
//  the replacement surface has survived a GRACE PERIOD without its own
//  child exiting, not immediately upon creation.
//
//  Asserting the real production grace period directly would need a
//  multi-second wall-clock test. This codebase's established
//  convention (see `SessionDaemonClientBoundTimeoutOverrides`,
//  exercised by `SessionDaemonClientSessionStateBoundTimeoutSeamTests`)
//  is to add a narrow, DEBUG-only override hook instead, so the
//  grace-period wait can be shrunk to a few milliseconds for the test.
//  This file proposes that same shape for the reconnect grace period:
//
//    #if DEBUG
//    enum CalyxWindowControllerReconnectGraceOverrides {
//        nonisolated(unsafe) static var reconnectEstablishGraceMilliseconds: UInt64?
//    }
//    #endif
//
//  -- `nil` (the default) means "use the production value" (proposed:
//  2000ms). `CalyxWindowController`'s own
//  `reconnectEstablishGraceMilliseconds` computed property would
//  consult this override first under `#if DEBUG`, mirroring
//  `SessionDaemonClientProtocol.daemonQueryBoundTimeoutSeconds`'s
//  identical shape. `performReconnect` would then schedule the
//  `markEstablished(sessionID:)` call on a `Task` that sleeps out this
//  bound before firing, rather than calling it synchronously and
//  immediately as it does today -- and should re-check, once that wait
//  elapses, that `newSurfaceID` is still the session's current surface
//  (e.g. via `SessionSurfaceMap.shared.surfaceID(for: sessionID) ==
//  newSurfaceID`) before marking it established, so a replacement that
//  was ITSELF already swapped out again by a second reconnect within
//  the grace window doesn't wrongly reset an unrelated, still-in-
//  progress attempt count.
//
//  NONE of this exists in the codebase yet: neither the override enum,
//  nor the grace-period wait itself (`performReconnect` today calls
//  `markEstablished(sessionID:)` unconditionally and immediately --
//  see `SessionReconnectAttemptResetTimingTests` for that bug's own
//  direct, already-RED coverage). Following this codebase's
//  established convention for new-API RED tests (see
//  `SessionDaemonClientSessionStateBoundTimeoutSeamTests`'s header
//  comment, itself citing `CalyxWindowControllerFullScreenTests`), this
//  file is expected to FAIL TO COMPILE until the TDD Green phase adds
//  the override enum plus the grace-period wait it gates. That compile
//  failure IS this contract's RED evidence.
//
//  THIS IS THE "HELD-OUT" FILE for this round: it must be excluded
//  from the build (e.g. temporarily moved out of `CalyxTests/`) while
//  running the rest of the round's RED suite, since a compile failure
//  anywhere in the `CalyxTests` target fails the WHOLE target (Swift
//  compiles a target as one module) -- otherwise no other test, old or
//  new, could be verified at all. Verify this file's specific compiler
//  errors with a separate, standalone attempt once the rest of the
//  suite is confirmed green/RED as expected.
//
//  Reuses the exact fixture/seam approach
//  SessionReconnectAttemptResetTimingTests already establishes
//  (`_performReconnectSurfaceCreationHookForTesting`,
//  `_sessionReconnectCoordinatorForTesting`,
//  `SessionReconnectCoordinator._testSeedAttemptCount(sessionID:count:)`,
//  the CALYX_SESSION_BIN env override, the inactive-second-tab fixture
//  shape) -- see that file's own header comment for why each of those
//  is necessary/safe. Duplicated here per this codebase's established
//  per-file fixture-duplication convention.
//
//  Coverage:
//  - A replacement surface that survives past the (overridden, tiny)
//    grace period DOES get its sessionID's attempt count reset --
//    regression coverage for markEstablished's legitimate purpose
//    (a later, unrelated disconnect starts backing off from attempt 1
//    again) against the fix that delays WHEN it fires.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class SessionReconnectEstablishGraceSeamTests: XCTestCase {

    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = nil
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    private func pumpRunLoop(timeout: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private struct ReconnectFixture {
        let controller: CalyxWindowController
        let tab: Tab
        let trackedLeafID: UUID
        let sessionID: String
    }

    /// See SessionReconnectAttemptResetTimingTests.makeFixture's own
    /// doc comment for why the tracked leaf lives on a non-active
    /// second tab.
    private func makeFixture() -> ReconnectFixture {
        let registry = SurfaceRegistry()
        let trackedLeafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: trackedLeafID)

        let sessionID = "test-session-\(UUID().uuidString)"
        let tab = Tab(
            splitTree: SplitTree(leafID: trackedLeafID),
            registry: registry,
            sessionRefs: [trackedLeafID: SessionRef(sessionID: sessionID)]
        )
        SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: trackedLeafID)
        registeredSessionIDs.append(sessionID)

        let otherTab = Tab()
        let group = TabGroup(name: "Default", tabs: [otherTab, tab], activeTabID: otherTab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        return ReconnectFixture(controller: controller, tab: tab, trackedLeafID: trackedLeafID, sessionID: sessionID)
    }

    /// RED (COMPILE-RED per this file's header comment):
    /// `CalyxWindowControllerReconnectGraceOverrides` does not exist
    /// yet, so this file fails to compile until Green adds the
    /// grace-period wait, its override seam, and the delayed
    /// `markEstablished` call described above.
    ///
    /// Once Green lands: overrides the grace period to a tiny value,
    /// seeds attemptCounts[sessionID] = 2 (simulating two prior
    /// consecutive reconnect failures already recorded), drives a real
    /// `.reconnect(attempt: 1)` decision through the real, unmodified
    /// `performReconnect`, then pumps the run loop past the overridden
    /// grace period and asserts the attempt count HAS been reset by
    /// then -- proving `markEstablished`'s legitimate purpose still
    /// works once the replacement genuinely survives, now that the fix
    /// delays when it fires.
    func test_performReconnect_replacementSurvivesGracePeriod_attemptCountEventuallyResets() {
        CalyxWindowControllerReconnectGraceOverrides.reconnectEstablishGraceMilliseconds = 30

        let fixture = makeFixture()
        fixture.controller._sessionReconnectCoordinatorForTesting._testSeedAttemptCount(
            sessionID: fixture.sessionID, count: 2
        )

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
        // Round-18 G6: establishment now also requires
        // `reconnectGraceProbe(sessionID:)` to report `.established`. This
        // test drives a real `performReconnect` against `/usr/bin/true`
        // and never registers `sessionID` with any real or fake daemon
        // ledger, so the real, un-hooked probe fallback would find no
        // matching session and report `.notEstablished` under fail-closed
        // semantics, breaking this test's expectation that the count
        // eventually resets. Stub the probe to isolate this test's actual
        // subject (the grace-period wait/surface-identity check) from G6's
        // separate probe contract, which `SessionReconnectGracePositiveSignalSeamTests`
        // covers directly.
        fixture.controller._reconnectGraceProbeForTesting = { .established }

        fixture.controller.handleSessionReconnectDecision(
            surfaceID: fixture.trackedLeafID,
            decision: .reconnect(sessionID: fixture.sessionID, attempt: 1)
        )

        pumpRunLoop(timeout: 1.0) {
            fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID)
        }
        XCTAssertTrue(fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID),
                      "Precondition: performReconnect must have swapped in the replacement surface")

        // The replacement is left alone from here on (never re-driven
        // through another childExited/decision), simulating "it
        // survived" -- wait past the overridden grace period.
        pumpRunLoop(timeout: 1.0) {
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID] == nil
        }

        XCTAssertNil(
            fixture.controller._sessionReconnectCoordinatorForTesting.attemptCounts[fixture.sessionID],
            "Once the replacement survives past the grace period without its own child exiting, " +
            "performReconnect must still eventually call markEstablished(sessionID:), resetting the " +
            "attempt count so a later, unrelated disconnect starts backing off from attempt 1 again"
        )
    }
}
