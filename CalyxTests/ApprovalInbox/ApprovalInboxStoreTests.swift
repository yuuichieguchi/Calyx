//
//  ApprovalInboxStoreTests.swift
//  CalyxTests
//
//  TDD Red Phase for ApprovalInboxStore: the Cockpit approval-request
//  queue and its await/decide/expire continuation lifecycle (mirrors
//  CommandLogStore.awaitCompletion's bridge-based coordination -- see
//  CommandLogStoreTests.swift's awaitCompletion tests for the timing
//  idioms reused here).
//
//  Coverage:
//  - submit enqueues into `pending`, ordered oldest-first by createdAt
//  - decide(.allowed) / decide(.denied) removes the request from
//    pending and resumes any in-flight awaitDecision with that decision
//  - awaitDecision times out to .expired and removes the request from
//    pending when nobody decides in time
//  - a decide() arriving after a request has already expired is a
//    no-op (no crash, no double-resume); a subsequent awaitDecision on
//    that same (now-untracked) id resumes .expired immediately rather
//    than waiting out a fresh timeout
//  - expireAll resumes every pending waiter with .expired and clears
//    pending
//  - cancelling an in-flight awaitDecision Task resolves promptly and
//    leaves the store in a state where a later decide() is a safe no-op
//

import XCTest
@testable import Calyx

@MainActor
final class ApprovalInboxStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(targetSurfaceID: UUID? = nil, payload: String = "ls", createdAt: Date = Date()) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: targetSurfaceID, payload: payload, createdAt: createdAt)
    }

    /// Bounded scheduler-yield loop, so a concurrently-spawned `Task`
    /// awaiting `store.awaitDecision` has every reasonable opportunity
    /// to actually reach its suspension point before the test proceeds
    /// to trigger a decision -- same pattern as
    /// CommandLogStoreTests.yieldToScheduler.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    // MARK: - submit

    func test_submit_appendsPending_oldestFirst() {
        let store = ApprovalInboxStore()
        let older = makeRequest(payload: "ls", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeRequest(payload: "pwd", createdAt: Date(timeIntervalSince1970: 1_700_000_100))

        store.submit(newer)
        store.submit(older)

        XCTAssertEqual(store.pending.map(\.id), [older.id, newer.id],
                       "pending must be ordered oldest-first by createdAt, regardless of submission order")
    }

    // MARK: - decide

    func test_decideAllowed_removesFromPending_andResumesAwaiterWithAllowed() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "submit must enqueue the request before any decision is made")

        let task = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        store.decide(id: request.id, .allowed)

        let result = await task.value
        XCTAssertEqual(result, .allowed, "decide(.allowed) must resume the awaiter with .allowed")
        XCTAssertTrue(store.pending.isEmpty, "a decided request must be removed from pending")
    }

    func test_decideDenied_resumesDenied() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "submit must enqueue the request before any decision is made")

        let task = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        store.decide(id: request.id, .denied)

        let result = await task.value
        XCTAssertEqual(result, .denied, "decide(.denied) must resume the awaiter with .denied")
        XCTAssertTrue(store.pending.isEmpty, "a decided request must be removed from pending")
    }

    // MARK: - decide(ids:_:) batched

    /// W6: the batched form must post `.calyxApprovalInboxChanged`
    /// exactly ONCE for the whole batch, not once per resolved id --
    /// backs `ApprovalBannerModel.alwaysAllow(id:)`'s drain, so it
    /// triggers one refresh per open window instead of N.
    func test_decideIDs_resolvesAllAndPostsExactlyOneNotification() async throws {
        let store = ApprovalInboxStore()
        let first = makeRequest(payload: "one")
        let second = makeRequest(payload: "two")
        let third = makeRequest(payload: "three")
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let firstWaiter = Task { @MainActor in await store.awaitDecision(id: first.id, timeoutMs: 5_000) }
        let secondWaiter = Task { @MainActor in await store.awaitDecision(id: second.id, timeoutMs: 5_000) }
        let thirdWaiter = Task { @MainActor in await store.awaitDecision(id: third.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        let notifyCountBeforeBatch = store._testNotifyCount

        store.decide(ids: [first.id, second.id, third.id], .allowed)

        XCTAssertEqual(store._testNotifyCount - notifyCountBeforeBatch, 1,
                       "decide(ids:_:) must post exactly one change notification for the whole batch, " +
                       "not one per resolved id")
        XCTAssertTrue(store.pending.isEmpty, "decide(ids:_:) must resolve every id in the batch")

        let firstResult = await firstWaiter.value
        let secondResult = await secondWaiter.value
        let thirdResult = await thirdWaiter.value
        XCTAssertEqual(firstResult, .allowed)
        XCTAssertEqual(secondResult, .allowed)
        XCTAssertEqual(thirdResult, .allowed)
    }

    func test_decideIDs_allStaleIDs_isNoOp_postsNoNotification() {
        let store = ApprovalInboxStore()
        let request = makeRequest()
        store.submit(request)
        store.decide(id: request.id, .allowed) // resolve it, so its id is now stale

        let notifyCountBeforeBatch = store._testNotifyCount

        store.decide(ids: [request.id], .denied)

        XCTAssertEqual(store._testNotifyCount, notifyCountBeforeBatch,
                       "a batch where every id is already stale must post no notification at all")
    }

    // MARK: - timeout / expiry

    func test_awaitDecision_timeout_resumesExpired_andRemovesFromPending() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "submit must enqueue the request before it can time out")

        let result = await store.awaitDecision(id: request.id, timeoutMs: 100)

        XCTAssertEqual(result, .expired, "an undecided request must resume .expired once its timeout elapses")
        XCTAssertTrue(store.pending.isEmpty, "an expired request must be removed from pending")
    }

    func test_decideAfterExpiry_isNoOp_neverDoubleResumes() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "submit must enqueue the request before it can expire")

        let firstResult = await store.awaitDecision(id: request.id, timeoutMs: 50)
        XCTAssertEqual(firstResult, .expired)

        // Arriving after the request already expired -- must not crash or
        // resurrect it.
        store.decide(id: request.id, .allowed)

        XCTAssertTrue(store.pending.isEmpty,
                      "an already-expired request must not resurface in pending after a late decide")

        // Unknown/already-resolved id contract: resumes .expired
        // immediately rather than waiting out a fresh timeout.
        let secondResult = await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        XCTAssertEqual(secondResult, .expired,
                       "awaiting a decision for an already-resolved id must resume .expired immediately")
    }

    // MARK: - expireAll

    func test_expireAll_resumesEveryPendingWaiterExpired() async throws {
        let store = ApprovalInboxStore()
        let first = makeRequest(payload: "ls")
        let second = makeRequest(payload: "pwd")

        store.submit(first)
        store.submit(second)
        XCTAssertEqual(Set(store.pending.map(\.id)), Set([first.id, second.id]),
                       "both submitted requests must be pending before expireAll is called")

        let firstTask = Task { @MainActor in await store.awaitDecision(id: first.id, timeoutMs: 5_000) }
        let secondTask = Task { @MainActor in await store.awaitDecision(id: second.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        store.expireAll()

        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        XCTAssertEqual(firstResult, .expired)
        XCTAssertEqual(secondResult, .expired)
        XCTAssertTrue(store.pending.isEmpty, "expireAll must clear every pending request")
    }

    // MARK: - cancellation

    func test_awaitDecision_taskCancellation_resumesWithoutLeakingContinuation() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "submit must enqueue the request before the awaiter can be cancelled")

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        waiter.cancel()
        _ = await waiter.value

        // A decide() arriving after cancellation must not crash or
        // double-resume a continuation that's already gone.
        store.decide(id: request.id, .allowed)

        XCTAssertTrue(store.pending.isEmpty, "a cancelled-then-decided request must not remain in pending")
    }

    func test_cancelThenDecide_neverReplaysAllowed() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        waiter.cancel()
        _ = await waiter.value

        // Arriving in the window right after cancellation -- must not
        // resurrect the request as a durable "approved" answer that a
        // later awaiter could pick up.
        store.decide(id: request.id, .allowed)

        let secondResult = await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        XCTAssertEqual(secondResult, .expired,
                       "A decision that raced a cancelled waiter must never be replayed to a later awaitDecision call")
    }

    // MARK: - timeout edge cases

    func test_awaitDecision_negativeZeroAndHugeTimeouts_doNotTrap_andExpirePromptly() async throws {
        let store = ApprovalInboxStore()

        let negativeRequest = makeRequest(payload: "negative")
        store.submit(negativeRequest)
        let negativeResult = await store.awaitDecision(id: negativeRequest.id, timeoutMs: -1)
        XCTAssertEqual(negativeResult, .expired, "A negative timeoutMs must clamp to 0, not trap or hang")

        let zeroRequest = makeRequest(payload: "zero")
        store.submit(zeroRequest)
        let zeroResult = await store.awaitDecision(id: zeroRequest.id, timeoutMs: 0)
        XCTAssertEqual(zeroResult, .expired, "A zero timeoutMs must expire promptly")

        let hugeRequest = makeRequest(payload: "huge")
        store.submit(hugeRequest)
        let hugeTask = Task { @MainActor in
            await store.awaitDecision(id: hugeRequest.id, timeoutMs: Int.max)
        }
        await yieldToScheduler()

        store.decide(id: hugeRequest.id, .allowed)

        let hugeResult = await hugeTask.value
        XCTAssertEqual(hugeResult, .allowed,
                       "Int.max must clamp instead of trapping when converted to nanoseconds, and still " +
                       "resolve via decide() well before the clamped upper bound")
    }

    // MARK: - single-use / single-waiter contract

    func test_approvalIsSingleUse_secondAwaitAfterDecideReturnsExpired() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        let task = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        store.decide(id: request.id, .allowed)
        let firstResult = await task.value
        XCTAssertEqual(firstResult, .allowed)

        let secondResult = await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        XCTAssertEqual(secondResult, .expired,
                       "A decision is single-use: a second awaitDecision on an already-decided id must not " +
                       "replay .allowed")
    }

    func test_secondConcurrentAwait_sameID_returnsExpiredImmediately_firstStillDecidable() async throws {
        let store = ApprovalInboxStore()
        let request = makeRequest()

        store.submit(request)
        let firstWaiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        let secondResult = await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        XCTAssertEqual(secondResult, .expired,
                       "A second concurrent awaitDecision on the same id must resolve .expired immediately " +
                       "rather than orphaning or replacing the first waiter")

        store.decide(id: request.id, .allowed)
        let firstResult = await firstWaiter.value
        XCTAssertEqual(firstResult, .allowed,
                       "The first waiter must remain live and decidable after a second concurrent await bounced off")
    }

    // MARK: - expireForSurface

    func test_expireForSurface_resumesOnlyTargetedWaiters_leavesOthersPending() async throws {
        let store = ApprovalInboxStore()
        let targetSurfaceID = UUID()
        let otherSurfaceID = UUID()
        let targeted = makeRequest(targetSurfaceID: targetSurfaceID, payload: "targeted")
        let untargeted = makeRequest(targetSurfaceID: otherSurfaceID, payload: "other")
        let windowAgnostic = makeRequest(targetSurfaceID: nil, payload: "agnostic")

        store.submit(targeted)
        store.submit(untargeted)
        store.submit(windowAgnostic)

        let targetedWaiter = Task { @MainActor in await store.awaitDecision(id: targeted.id, timeoutMs: 5_000) }
        let otherWaiter = Task { @MainActor in await store.awaitDecision(id: untargeted.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        store.expireForSurface(targetSurfaceID)

        let targetedResult = await targetedWaiter.value
        XCTAssertEqual(targetedResult, .expired,
                       "expireForSurface must resume a waiter targeting the destroyed surface with .expired")
        XCTAssertEqual(Set(store.pending.map(\.id)), Set([untargeted.id, windowAgnostic.id]),
                       "expireForSurface must remove only the request(s) targeting that surface, " +
                       "leaving other-surface and window-agnostic requests pending")

        store.decide(id: untargeted.id, .allowed)
        let otherResult = await otherWaiter.value
        XCTAssertEqual(otherResult, .allowed,
                       "a request targeting a different surface must remain independently decidable")
    }

    func test_expireForSurface_unknownSurface_isNoOp() {
        let store = ApprovalInboxStore()
        let request = makeRequest(targetSurfaceID: UUID())
        store.submit(request)

        store.expireForSurface(UUID())

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "expireForSurface for a surface with no matching pending request must not touch pending")
    }
}
