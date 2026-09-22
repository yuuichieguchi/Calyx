//
//  IPCListenerReadyGuardTests.swift
//  CalyxTests
//
//  Covers IPCListenerReadyGuard, the resume-once guard L2.3 requires
//  once CalyxMCPServer.startListenerAndWaitForReady(_:) replaces its
//  current DispatchSemaphore.wait(timeout:) (CalyxMCPServer.swift:1194)
//  with `await withCheckedContinuation`. NWListener's stateUpdateHandler
//  (CalyxMCPServer.swift:1159-1174) can fire `.ready` and later still
//  fire `.failed`/`.cancelled` on the SAME listener -- a CheckedContinuation
//  resumed twice traps. This is NOT testable against a real NWListener in
//  a unit test (no real network listener, per the harness's own
//  constraint), so this pins the guard as a standalone pure type instead.
//
//  Required seam at the CalyxMCPServer integration point (not added by
//  this test-only change -- described here for the implementer):
//  `startListenerAndWaitForReady` constructs one `IPCListenerReadyGuard`
//  per call, before `nl.start(queue:)`. Both the `.ready` arm and the
//  `.failed`/`.cancelled` arms of `stateUpdateHandler`, and the 1s
//  `asyncAfter` timeout, must each call `guard.resumeOnce { ... }` and
//  only actually call the continuation's `resume` inside that closure.
//  All three run on the same serial `listenerQueue`
//  (CalyxMCPServer.swift:1156-1158), so the guard's internal state needs
//  no synchronization beyond a plain Bool -- matching the plan's own
//  "ガードは素の Bool で足りる".
//
//  Coverage:
//  - first call to resumeOnce runs its body exactly once and reports success
//  - a second call, after the first, does not run its body and reports failure
//  - a `.ready` call followed by a `.cancelled` call: only the `.ready`
//    body's side effect is observed
//

import XCTest
@testable import Calyx

final class IPCListenerReadyGuardTests: XCTestCase {

    func test_firstResumeOnce_runsBodyOnce() {
        let guardian = IPCListenerReadyGuard()
        var callCount = 0

        guardian.resumeOnce { callCount += 1 }

        XCTAssertEqual(callCount, 1, "The first call to resumeOnce must run its body exactly once")
    }

    func test_secondResumeOnce_doesNotRunBodyAgain() {
        let guardian = IPCListenerReadyGuard()
        var callCount = 0
        guardian.resumeOnce { callCount += 1 }

        guardian.resumeOnce { callCount += 1 }

        XCTAssertEqual(callCount, 1, "A second call to resumeOnce must never run its body -- this is the guard " +
                       "against a CheckedContinuation being resumed twice when .ready fires before .cancelled/.failed")
    }

    /// Mirrors the real failure sequence: stateUpdateHandler fires
    /// `.ready` first (the success path resumes the continuation), then
    /// later fires `.cancelled` on the same listener (a resume that must
    /// be swallowed, not crash).
    func test_readyThenCancelled_onlyReadyBodyObserved() {
        let guardian = IPCListenerReadyGuard()
        var observedOutcome: String?

        guardian.resumeOnce { observedOutcome = "ready" }
        guardian.resumeOnce { observedOutcome = "cancelled" }

        XCTAssertEqual(observedOutcome, "ready",
                       "Only .ready's body may run; .cancelled firing afterward must never overwrite the outcome")
    }
}
