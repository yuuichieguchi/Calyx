//
//  ProgressBrokerTests.swift
//  Calyx
//
//  Tests for the `ProgressBroker` actor that aggregates
//  `window/workDoneProgress/create` token reservations with the matching
//  `$/progress` notification stream.
//
//  Spec references:
//    - $/progress: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
//    - window/workDoneProgress/create:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create
//    - WorkDoneProgressBegin/Report/End:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgress
//
//  Behaviour under test:
//    - `registerToken` reserves a token. Re-registering an existing token must
//      NOT overwrite an in-flight progress entry (spec preserves existing).
//    - `handleProgress(begin)` captures title/cancellable/percentage and
//      transitions status to `.begin`.
//    - `handleProgress(report)` updates message/percentage; status `.report`.
//    - `handleProgress(end)` captures final message; status `.end`; the token
//      moves out of `inFlight()` and into `recentlyEnded` (snapshot).
//    - `handleProgress` for an unknown (never-registered) token is silently
//      dropped: `status` continues to return `nil` for that token.
//    - `reset()` returns the broker to its empty initial state.
//
//  TDD phase: RED. `ProgressBroker`, `ProgressEntry`, `ProgressStatus`, and
//  `ProgressSnapshot` do not exist yet. This file is expected to fail to
//  compile until the swift-specialist creates
//  `Calyx/Features/LSP/ProgressBroker.swift`.
//

import XCTest
@testable import Calyx

@MainActor
final class ProgressBrokerTests: XCTestCase {

    // MARK: - Helpers

    private func makeBroker() -> ProgressBroker {
        return ProgressBroker()
    }

    private func token(_ s: String) -> ProgressToken {
        return .string(s)
    }

    private func beginValue(
        title: String,
        cancellable: Bool? = nil,
        message: String? = nil,
        percentage: UInt? = nil
    ) -> WorkDoneProgress {
        return .begin(WorkDoneProgressBegin(
            title: title,
            cancellable: cancellable,
            message: message,
            percentage: percentage
        ))
    }

    private func reportValue(
        message: String? = nil,
        percentage: UInt? = nil,
        cancellable: Bool? = nil
    ) -> WorkDoneProgress {
        return .report(WorkDoneProgressReport(
            cancellable: cancellable,
            message: message,
            percentage: percentage
        ))
    }

    private func endValue(message: String? = nil) -> WorkDoneProgress {
        return .end(WorkDoneProgressEnd(message: message))
    }

    // ====================================================================
    // MARK: - Token registration
    // ====================================================================

    func test_registerToken_reservesButStatusIsNilUntilBegin() async {
        let broker = makeBroker()
        let tok = token("tok-1")

        await broker.registerToken(tok)

        let status = await broker.status(for: tok)
        XCTAssertNil(status, "registered token without begin has no status yet")

        let inFlight = await broker.inFlight()
        XCTAssertTrue(inFlight.isEmpty, "no progress entries until begin received")
    }

    func test_registerToken_isIdempotentAfterBegin() async {
        let broker = makeBroker()
        let tok = token("tok-1")

        await broker.registerToken(tok)
        await broker.handleProgress(token: tok, value: beginValue(title: "Indexing", percentage: 10))

        // Re-registering an already-active token must NOT overwrite its state.
        await broker.registerToken(tok)

        let status = await broker.status(for: tok)
        XCTAssertEqual(status, .begin, "re-registering an in-flight token must preserve its state")
        let inFlight = await broker.inFlight()
        XCTAssertEqual(inFlight.count, 1)
        XCTAssertEqual(inFlight.first?.title, "Indexing")
    }

    // ====================================================================
    // MARK: - Begin
    // ====================================================================

    func test_handleProgress_begin_capturesTitleAndCancellable() async {
        let broker = makeBroker()
        let tok = token("tok-1")
        await broker.registerToken(tok)
        await broker.handleProgress(
            token: tok,
            value: beginValue(title: "Indexing", cancellable: true, percentage: 0)
        )

        let status = await broker.status(for: tok)
        XCTAssertEqual(status, .begin)

        let inFlight = await broker.inFlight()
        XCTAssertEqual(inFlight.count, 1)
        let entry = inFlight[0]
        XCTAssertEqual(entry.token, tok)
        XCTAssertEqual(entry.status, .begin)
        XCTAssertEqual(entry.title, "Indexing")
        XCTAssertEqual(entry.cancellable, true)
        XCTAssertEqual(entry.percentage, 0)
    }

    // ====================================================================
    // MARK: - Report
    // ====================================================================

    func test_handleProgress_report_updatesPercentageAndMessage() async {
        let broker = makeBroker()
        let tok = token("tok-1")
        await broker.registerToken(tok)
        await broker.handleProgress(token: tok, value: beginValue(title: "Indexing", cancellable: true, percentage: 0))
        await broker.handleProgress(token: tok, value: reportValue(message: "halfway", percentage: 50))

        let status = await broker.status(for: tok)
        XCTAssertEqual(status, .report)

        let inFlight = await broker.inFlight()
        XCTAssertEqual(inFlight.count, 1)
        let entry = inFlight[0]
        XCTAssertEqual(entry.status, .report)
        XCTAssertEqual(entry.message, "halfway")
        XCTAssertEqual(entry.percentage, 50)
        XCTAssertEqual(entry.title, "Indexing", "title from begin must persist across report")
    }

    // ====================================================================
    // MARK: - End
    // ====================================================================

    func test_handleProgress_end_removesFromInFlightAndKeepsRecentlyEnded() async {
        let broker = makeBroker()
        let tok = token("tok-1")
        await broker.registerToken(tok)
        await broker.handleProgress(token: tok, value: beginValue(title: "Indexing"))
        await broker.handleProgress(token: tok, value: reportValue(percentage: 50))
        await broker.handleProgress(token: tok, value: endValue(message: "done"))

        let status = await broker.status(for: tok)
        XCTAssertEqual(status, .end)

        let inFlight = await broker.inFlight()
        XCTAssertTrue(inFlight.isEmpty, "ended token must not appear in inFlight()")

        let snap = await broker.snapshot()
        XCTAssertTrue(snap.inFlight.isEmpty)
        XCTAssertEqual(snap.recentlyEnded.count, 1)
        let entry = snap.recentlyEnded[0]
        XCTAssertEqual(entry.token, tok)
        XCTAssertEqual(entry.status, .end)
        XCTAssertEqual(entry.message, "done")
        XCTAssertEqual(entry.title, "Indexing", "title from begin must persist into end entry")
    }

    // ====================================================================
    // MARK: - Snapshot
    // ====================================================================

    func test_snapshot_segregatesInFlightAndRecentlyEnded() async {
        let broker = makeBroker()
        let t1 = token("tok-active")
        let t2 = token("tok-ended")
        await broker.registerToken(t1)
        await broker.registerToken(t2)
        await broker.handleProgress(token: t1, value: beginValue(title: "Active"))
        await broker.handleProgress(token: t2, value: beginValue(title: "Ended"))
        await broker.handleProgress(token: t2, value: endValue(message: "ok"))

        let snap = await broker.snapshot()
        XCTAssertEqual(snap.inFlight.count, 1)
        XCTAssertEqual(snap.inFlight.first?.token, t1)
        XCTAssertEqual(snap.recentlyEnded.count, 1)
        XCTAssertEqual(snap.recentlyEnded.first?.token, t2)
    }

    // ====================================================================
    // MARK: - Duplicate begin
    // ====================================================================

    func test_handleProgress_begin_twiceOnSameToken_lastWins() async {
        let broker = makeBroker()
        let tok = token("tok-1")
        await broker.registerToken(tok)
        await broker.handleProgress(token: tok, value: beginValue(title: "First"))
        await broker.handleProgress(token: tok, value: beginValue(title: "Second", percentage: 5))

        let inFlight = await broker.inFlight()
        XCTAssertEqual(inFlight.count, 1)
        XCTAssertEqual(inFlight.first?.title, "Second", "second begin overwrites first")
        XCTAssertEqual(inFlight.first?.percentage, 5)
    }

    // ====================================================================
    // MARK: - Unregistered token
    // ====================================================================

    func test_handleProgress_unregisteredToken_isIgnored() async {
        let broker = makeBroker()
        let tok = token("ghost")

        await broker.handleProgress(token: tok, value: beginValue(title: "Should be ignored"))

        let status = await broker.status(for: tok)
        XCTAssertNil(status, "progress for unregistered token must be silently ignored")
        let inFlight = await broker.inFlight()
        XCTAssertTrue(inFlight.isEmpty)
    }

    // ====================================================================
    // MARK: - Reset
    // ====================================================================

    func test_reset_clearsAllState() async {
        let broker = makeBroker()
        let t1 = token("a")
        let t2 = token("b")
        await broker.registerToken(t1)
        await broker.registerToken(t2)
        await broker.handleProgress(token: t1, value: beginValue(title: "A"))
        await broker.handleProgress(token: t2, value: beginValue(title: "B"))
        await broker.handleProgress(token: t2, value: endValue(message: "fin"))

        await broker.reset()

        let s1 = await broker.status(for: t1)
        let s2 = await broker.status(for: t2)
        XCTAssertNil(s1)
        XCTAssertNil(s2)

        let snap = await broker.snapshot()
        XCTAssertTrue(snap.inFlight.isEmpty)
        XCTAssertTrue(snap.recentlyEnded.isEmpty)
    }
}
