// AwaitBridge.swift
// Calyx
//
// Consolidates the two byte-identical private `*AwaitBridge` classes
// that had grown up independently in CommandLogStore
// (CommandAwaitBridge) and ApprovalInboxStore (ApprovalAwaitBridge) --
// both exist to arbitrate exactly-once resume of a single suspended
// continuation between a matching store mutation, a timeout Task, and
// `withTaskCancellationHandler`'s onCancel (which is NOT actor-isolated
// and may run concurrently with the other two on a different thread),
// so a lock rather than actor isolation guards the shared state. Same
// consolidation rationale as ProcessCancellationBridge (R16-1,
// r16-fix-spec.md): a future fix to the exactly-once discipline now
// only has to land in one place.
//
// Deliberately NOT used by SessionDaemonClient's own
// SessionDaemonBoundedRaceBridge: that type races two independent,
// separately-cancellable arms (an operation Task AND a timeout Task)
// with a closure-valued `onTimeout()` result and winner-cancels-loser
// ordering (see that type's own R10-C doc comment) -- a different,
// three-way race shape this simpler single-timeout-arm bridge doesn't
// cover.

import Foundation

/// Thread-safe exactly-once resume for a single suspended continuation,
/// shared by `CommandLogStore.waitForRecord` and
/// `ApprovalInboxStore.waitForDecision`. `register`/`resume`/`cancel`
/// may be called from any of those methods' three call sites (a store
/// mutation, a timeout Task, and `onCancel`), so `lock` -- not actor
/// isolation -- is what makes this safe. `@unchecked Sendable` is sound
/// because every stored property is only ever touched inside `lock`.
final class AwaitBridge<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var isCancelled = false
    private var continuation: CheckedContinuation<Value, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// Returns whether `cancel(resumingWith:)` already ran before this
    /// call -- the caller must resume with its own fallback value
    /// immediately in that case, since `cancel(resumingWith:)` itself
    /// found no continuation yet to resume.
    func register(continuation: CheckedContinuation<Value, Never>, timeoutTask: Task<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
        self.timeoutTask = timeoutTask
        return isCancelled
    }

    @discardableResult
    func resume(with value: Value) -> Bool {
        lock.lock()
        guard !resumed, let continuation else { lock.unlock(); return false }
        resumed = true
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        continuation.resume(returning: value)
        return true
    }

    /// `fallback` resumes the continuation if one is already registered
    /// -- callers pass whatever value their own timeout arm would have
    /// produced (`nil` for `CommandLogStore`, `.expired` for
    /// `ApprovalInboxStore`). Claims the resume in the SAME lock
    /// acquisition that sets `isCancelled`, mirroring `resume(with:)`'s
    /// own atomic check-and-claim shape exactly -- an earlier version of
    /// this method set `isCancelled`, released the lock, and only THEN
    /// called `resume(with:)` (which re-acquires the lock), leaving a
    /// window in which a concurrent `resume(with:)` call from an
    /// entirely independent, non-lock-gated call path (e.g.
    /// `ApprovalInboxStore.decide()`, reached via ordinary MainActor
    /// code with no relationship to this bridge's cancellation) could
    /// win the race and deliver ITS value even though cancellation had
    /// already begun. With no gap between setting `isCancelled` and
    /// claiming the resume, that window no longer exists: once this
    /// method's critical section starts, the outcome is deterministic --
    /// either this call claims the resume, or `resume(with:)` had
    /// already legitimately claimed it before this call acquired the
    /// lock. See `ApprovalInboxStore`'s header comment for what that
    /// remaining, inherent race (which side reaches the lock first) means
    /// for callers.
    func cancel(resumingWith fallback: Value) {
        lock.lock()
        isCancelled = true
        guard !resumed, let continuation else { lock.unlock(); return }
        resumed = true
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        continuation.resume(returning: fallback)
    }
}
