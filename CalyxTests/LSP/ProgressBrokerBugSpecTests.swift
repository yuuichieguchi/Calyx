//
//  ProgressBrokerBugSpecTests.swift
//  Calyx
//
//  Independent regression tests (Wave 1 RETROFIT) co-authored with the fix
//  for a memory-growth bug in `ProgressBroker`.
//
//  Bug:
//    Pre-fix, the broker wrote ended progress entries back into its live
//    `tokens` dictionary in addition to the bounded `recentlyEnded` ring.
//    For a long-running language server emitting thousands of `$/progress`
//    notifications (begin -> report -> end), the live dict grew
//    monotonically and never released the ended entries — a leak in the
//    LSP foreground state.
//
//  Post-fix contract:
//    * `.end` MUST remove the token from the live `tokens` dict.
//    * `.end` MUST place the entry into the bounded `recentlyEnded` ring.
//    * `status(for:)` MUST continue to return `.end` for recently-ended
//      tokens (consulted via the ring fallback).
//    * The behaviour MUST be safe under actor concurrency.
//
//  Spec refs:
//    - $/progress lifecycle:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
//    - WorkDoneProgress Begin/Report/End:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgress
//
//  These tests are deliberately written in a separate file from
//  `ProgressBrokerTests.swift` so the regression suite can be invoked
//  independently and so the test bodies are written against the bug spec
//  rather than the existing behavioural fixtures.
//

import XCTest
@testable import Calyx

@MainActor
final class ProgressBrokerBugSpecTests: XCTestCase {

    // MARK: - Helpers

    private func makeBroker() -> ProgressBroker {
        return ProgressBroker()
    }

    private func tok(_ s: String) -> ProgressToken {
        return .string(s)
    }

    private func beginValue(title: String = "T") -> WorkDoneProgress {
        return .begin(WorkDoneProgressBegin(
            title: title,
            cancellable: nil,
            message: nil,
            percentage: nil
        ))
    }

    private func reportValue(percentage: UInt? = nil) -> WorkDoneProgress {
        return .report(WorkDoneProgressReport(
            cancellable: nil,
            message: nil,
            percentage: percentage
        ))
    }

    private func endValue(message: String? = nil) -> WorkDoneProgress {
        return .end(WorkDoneProgressEnd(message: message))
    }

    // ====================================================================
    // MARK: - 1. Ended token evicted from live dict
    // ====================================================================

    func test_endedToken_removedFromLiveTokensDict() async {
        let broker = makeBroker()
        let t = tok("retrofit-end-1")

        // Baseline: live dict starts empty.
        let baseline = await broker.liveTokenCount
        XCTAssertEqual(baseline, 0, "fresh broker has no live tokens")

        await broker.registerToken(t)
        await broker.handleProgress(token: t, value: beginValue(title: "Indexing"))

        // Between begin and end the token must be live.
        let mid = await broker.liveTokenCount
        XCTAssertEqual(
            mid, 1,
            "live token count must include the in-flight token between begin and end"
        )

        await broker.handleProgress(token: t, value: reportValue(percentage: 42))
        await broker.handleProgress(token: t, value: endValue(message: "done"))

        // Post-fix contract: on `.end` the entry leaves the live dict.
        let after = await broker.liveTokenCount
        XCTAssertEqual(
            after, baseline,
            "ended token must be removed from live tokens dict (returns to baseline)"
        )
    }

    // ====================================================================
    // MARK: - 2. status(for:) still reports .end via recentlyEnded
    // ====================================================================

    func test_endedToken_statusStillRetrievable_viaRecentlyEnded() async {
        let broker = makeBroker()
        let t = tok("retrofit-end-2")

        await broker.registerToken(t)
        await broker.handleProgress(token: t, value: beginValue(title: "Compiling"))
        await broker.handleProgress(token: t, value: endValue(message: "ok"))

        // The token has left the live dict, but its `.end` status must
        // remain queryable via the bounded ring fallback.
        let liveCount = await broker.liveTokenCount
        XCTAssertEqual(
            liveCount, 0,
            "precondition: ended token must not be in the live dict"
        )

        let status = await broker.status(for: t)
        XCTAssertNotNil(
            status,
            "status(for:) must NOT return nil for a recently-ended token"
        )
        XCTAssertEqual(
            status, .end,
            "status(for:) for a recently-ended token must report .end via the ring"
        )
    }

    // ====================================================================
    // MARK: - 3. Many ended tokens do not accumulate in live dict;
    //            recentlyEnded remains bounded.
    // ====================================================================

    func test_manyEndedTokens_doNotAccumulate() async {
        let broker = makeBroker()
        let cycles = 500

        for i in 0..<cycles {
            let t = tok("retrofit-cycle-\(i)")
            await broker.registerToken(t)
            await broker.handleProgress(token: t, value: beginValue(title: "T\(i)"))
            await broker.handleProgress(token: t, value: endValue())
        }

        // The live dict MUST be empty: every cycle ended.
        let live = await broker.liveTokenCount
        XCTAssertEqual(
            live, 0,
            "after \(cycles) begin+end cycles, live dict must be empty (no leak)"
        )

        // The recentlyEnded ring must be bounded — i.e. strictly fewer
        // than `cycles` entries retained when `cycles` greatly exceeds the
        // ring capacity. (Exact capacity is an implementation detail; the
        // contract is "bounded".)
        let snap = await broker.snapshot()
        XCTAssertTrue(
            snap.inFlight.isEmpty,
            "no in-flight entries should remain after all cycles ended"
        )
        XCTAssertLessThanOrEqual(
            snap.recentlyEnded.count, cycles,
            "recentlyEnded must never exceed total ends seen"
        )
        XCTAssertLessThan(
            snap.recentlyEnded.count, cycles,
            "ring must be bounded: \(cycles) ends must not retain \(cycles) entries"
        )
    }

    // ====================================================================
    // MARK: - 4. Concurrent begin+end cycles under actor isolation
    // ====================================================================

    func test_concurrentBeginEndCycles_safeUnderActorIsolation() async {
        let broker = makeBroker()
        let count = 100

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<count {
                group.addTask {
                    let t: ProgressToken = .string("retrofit-concurrent-\(i)")
                    await broker.registerToken(t)
                    await broker.handleProgress(
                        token: t,
                        value: .begin(WorkDoneProgressBegin(
                            title: "C\(i)",
                            cancellable: nil,
                            message: nil,
                            percentage: nil
                        ))
                    )
                    await broker.handleProgress(
                        token: t,
                        value: .end(WorkDoneProgressEnd(message: nil))
                    )
                }
            }
            await group.waitForAll()
        }

        // After all concurrent cycles have settled, the live dict must be
        // empty and the snapshot must be internally consistent.
        let live = await broker.liveTokenCount
        XCTAssertEqual(
            live, 0,
            "after \(count) concurrent begin+end cycles, no token should remain live"
        )

        let snap = await broker.snapshot()
        XCTAssertTrue(
            snap.inFlight.isEmpty,
            "snapshot.inFlight must be empty after concurrent cycles settle"
        )

        // Every token we issued must report `.end` (via the ring) OR `nil`
        // (if evicted by ring overflow). Crucially, none may report
        // `.begin` or `.report` — that would indicate the actor lost an
        // update under contention.
        for i in 0..<count {
            let t: ProgressToken = .string("retrofit-concurrent-\(i)")
            let status = await broker.status(for: t)
            if let status = status {
                XCTAssertEqual(
                    status, .end,
                    "token \(i) reported \(status) instead of .end — inconsistent state under contention"
                )
            }
            // status == nil is acceptable: ring may have evicted this entry.
        }
    }
}
