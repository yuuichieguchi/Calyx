// ApprovalInboxStore.swift
// Calyx
//
// Queue of pending ApprovalRequests plus a continuation-based
// await/decide/expire lifecycle for whoever submitted the request.
// Mirrors CommandLogStore.awaitCompletion's bridge-based coordination
// (see that method's doc comment), sharing its exactly-once resume
// mechanics via the generic `AwaitBridge` helper
// (`Calyx/Helpers/AwaitBridge.swift`). See
// CalyxTests/ApprovalInbox/ApprovalInboxStoreTests.swift for the
// specced contract.
//
// Approvals are single-use: a decision resumes the in-flight waiter and
// is never recorded or replayed -- any awaitDecision on a non-pending id
// (already decided, already expired, cancelled, or simply unknown)
// resolves `.expired`, always, so a decision can never replay to a
// second, later awaiter.
//
// Precise contract for a decide() racing a concurrent cancellation:
// AwaitBridge.cancel(resumingWith:) claims its resume atomically (one
// lock acquisition, no gap -- see that method's own doc comment), so
// once its critical section starts, no other value can be delivered to
// that waiter. But a decide() that claims the resume BEFORE
// cancellation's critical section starts is indistinguishable, from
// inside this store, from "approved-then-disconnected": the waiter's
// underlying Task may already be marked cancelled by the time it
// observes `.allowed` -- this store has no way to know which happened
// first. Callers gating an irreversible action on `awaitDecision`
// returning `.allowed` MUST re-check `Task.isCancelled` themselves
// before acting on it -- see `awaitDecision`'s own doc comment.
//
// One live waiter per request id: a concurrent duplicate awaitDecision
// call for an id that already has a suspended waiter resolves `.expired`
// immediately rather than displacing or orphaning the original -- the
// original stays live and decidable.
//
// Divergence from CommandLogStore's observer semantics, deliberate: an
// ApprovalRequest is 1:1 with its waiter (the MCP tool call that
// submitted it); when the waiter is cancelled the request has no
// consumer, so it leaves `pending` and the banner along with it -- a
// banner nobody can execute must not linger.
//
// init() must never construct another singleton in a stored property --
// a prior circular-init crash makes that a hard rule for this codebase.

import Foundation

@MainActor
@Observable
final class ApprovalInboxStore {

    static let shared = ApprovalInboxStore()

    private(set) var pending: [ApprovalRequest] = []

    /// At most one live waiter bridge per request id -- see the type's
    /// header comment for the single-waiter contract this backs.
    private var awaitersByID: [UUID: AwaitBridge<ApprovalDecision>] = [:]

    /// Same clamp, and the same rationale, as
    /// CommandLogStore.awaitCompletion's own: bounds the timeout Task's
    /// `Task.sleep` duration so a caller-supplied `timeoutMs` can never
    /// go negative (crashing the `UInt64` conversion) or so large that
    /// converting it to nanoseconds overflows `UInt64` (`Int.max`
    /// milliseconds far exceeds `UInt64.max` nanoseconds).
    private static let maxTimeoutMs = 3_600_000

    init() {}

    // MARK: - submit

    /// Inserts in createdAt order so `pending` always reads oldest-first,
    /// regardless of submission order.
    func submit(_ request: ApprovalRequest) {
        let insertIndex = pending.firstIndex { $0.createdAt > request.createdAt } ?? pending.count
        pending.insert(request, at: insertIndex)
    }

    // MARK: - decide

    /// A no-op if `id` is no longer in `pending` (already decided,
    /// expired, or unknown) -- never resurrects a resolved request or
    /// double-resumes its waiter.
    func decide(id: UUID, _ decision: ApprovalDecision) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index)
        awaitersByID.removeValue(forKey: id)?.resume(with: decision)
    }

    // MARK: - awaitDecision

    /// If `id` isn't pending, resolves `.expired` immediately -- see the
    /// type header's single-use contract. If `id` already has a live
    /// waiter, also resolves `.expired` immediately rather than
    /// displacing it -- see the type header's single-waiter contract.
    /// Otherwise suspends until `decide(id:_:)`, `expireAll()`, this
    /// call's own timeout, or the awaiting Task's cancellation resolves
    /// it -- see `waitForDecision` and `AwaitBridge` for the
    /// exactly-once resume mechanics, which mirror
    /// CommandLogStore.waitForRecord.
    ///
    /// Caller obligation (see the type header's precise cancellation
    /// contract): a `.allowed` result does NOT guarantee this call's own
    /// Task was never cancelled -- a decide() that wins its race against
    /// a concurrent cancellation delivers `.allowed` here regardless.
    /// Any caller that gates an irreversible action on `.allowed` MUST
    /// re-check `Task.isCancelled` itself before acting on it.
    func awaitDecision(id: UUID, timeoutMs: Int) async -> ApprovalDecision {
        let clampedTimeoutMs = min(max(timeoutMs, 0), Self.maxTimeoutMs)
        guard pending.contains(where: { $0.id == id }) else {
            return .expired
        }
        guard awaitersByID[id] == nil else {
            return .expired
        }
        return await waitForDecision(id: id, timeoutMs: clampedTimeoutMs)
    }

    private func waitForDecision(id: UUID, timeoutMs: Int) async -> ApprovalDecision {
        let bridge = AwaitBridge<ApprovalDecision>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalDecision, Never>) in
                awaitersByID[id] = bridge
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    self.expire(id: id, bridge: bridge)
                }
                let alreadyCancelled = bridge.register(continuation: continuation, timeoutTask: timeoutTask)
                if alreadyCancelled {
                    timeoutTask.cancel()
                    self.expire(id: id, bridge: bridge)
                }
            }
        } onCancel: {
            bridge.cancel(resumingWith: .expired)
            Task { @MainActor in
                self.expire(id: id, bridge: bridge)
            }
        }
    }

    /// Shared tail for the timeout, alreadyCancelled, and Task-cancellation
    /// paths. ALL store cleanup -- both the `awaitersByID` eviction and
    /// the `pending` removal -- is gated on `bridge` still being the
    /// id's CURRENT bridge (`===` identity check): a re-await that has
    /// since registered a fresh bridge for the same id must never have
    /// its live registration evicted, NOR its still-live request pulled
    /// out of `pending`, by a stale, deferred `expire` call arriving late
    /// from the non-isolated `onCancel` hop (see the type header's
    /// cancel-kills-the-request divergence from CommandLogStore for why
    /// `pending` removal belongs here at all). When the identity check
    /// fails, this call touches nothing but its own (already-resumed)
    /// bridge. `bridge.resume` is itself exactly-once, so this whole
    /// method is safe to call more than once for the same bridge.
    private func expire(id: UUID, bridge: AwaitBridge<ApprovalDecision>) {
        if awaitersByID[id] === bridge {
            awaitersByID.removeValue(forKey: id)
            if let index = pending.firstIndex(where: { $0.id == id }) {
                pending.remove(at: index)
            }
        }
        bridge.resume(with: .expired)
    }

    // MARK: - expireAll

    func expireAll() {
        for request in pending {
            awaitersByID.removeValue(forKey: request.id)?.resume(with: .expired)
        }
        pending.removeAll()
    }

    #if DEBUG
    func _testReset() {
        for bridge in awaitersByID.values {
            bridge.resume(with: .expired)
        }
        awaitersByID.removeAll()
        pending.removeAll()
    }
    #endif
}
