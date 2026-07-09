//
//  AwaitBridgeTests.swift
//  CalyxTests
//
//  Stress test for AwaitBridge<Value>'s exactly-once resume discipline,
//  specifically the fix for the cancel()-races-resume() interleaving
//  found in the P1 final review gate: an earlier version of
//  `cancel(resumingWith:)` split its work across two separate lock
//  acquisitions (set `isCancelled`, unlock, THEN call `resume(with:)`,
//  which re-locks), leaving a window in which a concurrent
//  `resume(with:)` call from a totally independent, non-lock-gated call
//  path (mirroring ApprovalInboxStore.decide(), which shares no lock
//  with the `onCancel`-triggered `cancel(resumingWith:)` call) could win
//  the race and deliver its own value even though cancellation had
//  already begun. Races two DispatchQueue.global() threads against a
//  fresh AwaitBridge instance, ~1000 times, to make that interleaving
//  likely to occur if the bug were still present -- a double-resume
//  would crash the underlying CheckedContinuation outright.
//

import XCTest
@testable import Calyx

final class AwaitBridgeTests: XCTestCase {

    /// ~1000-iteration race between `cancel(resumingWith: .expired)` and
    /// `resume(with: .allowed)`, launched from two independent
    /// `DispatchQueue.global()` threads against a freshly-registered
    /// continuation each iteration. Exactly one value is ever delivered
    /// per iteration (a double-resume would crash `CheckedContinuation`,
    /// failing the test outright rather than merely producing a wrong
    /// assertion). Without any bias, `DispatchQueue.global()`'s worker
    /// pool empirically favors whichever block was enqueued first almost
    /// every time (its dispatch/wake latency dwarfs the few instructions
    /// each block does before touching the lock), which would silently
    /// starve one outcome across all 1000 iterations without actually
    /// proving the race is safe in both orders -- so each iteration
    /// alternates a tiny head start between the two sides (`delayCancel`)
    /// to force both winning orders to occur repeatedly, while still
    /// genuinely racing at `AwaitBridge`'s lock (the delay only biases
    /// who ARRIVES first; the lock is what actually decides the winner).
    func test_cancelResumeRace_exactlyOneValueDelivered_bothOutcomesOccur() async throws {
        let iterations = 1_000
        var allowedCount = 0
        var expiredCount = 0

        for iteration in 0..<iterations {
            let bridge = AwaitBridge<ApprovalDecision>()
            let timeoutTask = Task<Void, Never> {}
            let delayCancel = iteration.isMultiple(of: 2)

            let delivered = await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                _ = bridge.register(continuation: continuation, timeoutTask: timeoutTask)
                DispatchQueue.global().async {
                    if delayCancel { usleep(200) }
                    bridge.cancel(resumingWith: .expired)
                }
                DispatchQueue.global().async {
                    if !delayCancel { usleep(200) }
                    bridge.resume(with: .allowed)
                }
            }

            switch delivered {
            case .allowed:
                allowedCount += 1
                XCTAssertFalse(bridge.resume(with: .denied),
                               "the bridge must be permanently resumed once resume(.allowed) has delivered " +
                               "a value")
            case .expired:
                expiredCount += 1
                XCTAssertFalse(bridge.resume(with: .allowed),
                               "resume() arriving after cancel() already won must be a no-op, never " +
                               "re-delivering a different value")
            case .denied:
                XCTFail("this race only ever resumes with .expired (cancel) or .allowed (resume) -- " +
                        ".denied is unreachable")
            }

            // Whichever side won, calling the other operation again must
            // not crash -- an idempotent no-op. This exercises "cancel()
            // arriving after resume() already won" directly, which the
            // switch above only covers indirectly (via resume()'s own
            // return value).
            bridge.cancel(resumingWith: .expired)
        }

        XCTAssertGreaterThan(allowedCount, 0,
                             "resume(.allowed) must win at least once across \(iterations) iterations -- " +
                             "if this is always 0, the race isn't actually being exercised")
        XCTAssertGreaterThan(expiredCount, 0,
                             "cancel(.expired) must win at least once across \(iterations) iterations -- " +
                             "if this is always 0, the race isn't actually being exercised")
    }
}
