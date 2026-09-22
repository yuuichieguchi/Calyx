// IPCListenerReadyGuard.swift
// Calyx
//
// Guards a `CheckedContinuation` behind `startListenerAndWaitForReady`'s
// resume against being resumed twice. `NWListener.stateUpdateHandler` can
// fire `.ready` and, sometime later, still fire `.failed` or `.cancelled`
// on the SAME listener (a subsequent `nl.cancel()` on a failure path also
// drives `.cancelled` into the same live closure) -- a `CheckedContinuation`
// resumed a second time traps.
//
// Every call site that touches one guard instance (the `.ready` arm, the
// `.failed`/`.cancelled` arm, and the timeout's `asyncAfter`) runs on the
// same serial `listenerQueue`, so this needs no lock beyond a plain `Bool`.
// `@unchecked Sendable` is safe under that single-serial-queue invariant
// only -- it must never be constructed or called from more than one queue.

import Foundation

final class IPCListenerReadyGuard: @unchecked Sendable {

    private var hasResumed = false

    /// Runs `body` exactly once across every call to this instance: the
    /// first caller wins and runs it; every later caller is a no-op.
    /// Callers pass a closure that resumes the continuation so the "did
    /// it actually resume" decision and the resume itself stay on the
    /// same call. Every production call site discards whether it won,
    /// so there is nothing to report back.
    func resumeOnce(_ body: () -> Void) {
        guard !hasResumed else { return }
        hasResumed = true
        body()
    }
}
