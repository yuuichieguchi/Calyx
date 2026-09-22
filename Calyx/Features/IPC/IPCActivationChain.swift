// IPCActivationChain.swift
// Calyx
//
// Serializes enable()/disable() end to end AND owns the whole activation
// transition as one unit: which operation is actually running (nil when
// idle), the last recorded outcome, and a notification whenever
// runningOperation changes (nil <-> some, or switching direction while
// two calls are queued back to back). "In flight" has exactly one
// definition, runningOperation != nil -- there is no separate flag to
// keep in sync with it. L1's config lock is per-file, so it only orders
// writes to ONE file -- a single activation touches several (agent config, agent
// hooks), so an enable immediately followed by a disable can otherwise
// land out of order across files: the enable's config install could
// commit after the disable's config removal, stranding an entry for a
// server that is already stopped. A single @MainActor Task chain is
// enough to fix the landing order because both production coordinators
// (enable and disable) share one instance.
//
// The outcome is recorded INSIDE this chain's own queued work, as the
// last thing before it returns, and the runningOperation-dropping-to-nil
// notification posts only after that recording -- a reader woken by the
// notification always observes the matching report, never a stale one
// from before the operation that just finished. Splitting "in flight" (here) from "last
// outcome" (elsewhere) is what produced two notifications per operation
// and a report that could land after the flag had already dropped;
// folding both into one owner removes that split at the root.
//
// No generation counter: the chain serializes strictly, so a queued
// operation can never become stale relative to another operation running
// concurrently -- an "am I still current" check could never observe
// false, which makes it dead code.

import Foundation

@MainActor
final class IPCActivationChain {

    static let shared = IPCActivationChain()

    /// Which direction is in flight -- distinguishes "Starting…" from a
    /// disabling-specific status line in the Settings row.
    enum Operation: Sendable, Equatable {
        case enabling
        case disabling
    }

    private var tail: Task<Void, Never>?
    private var pendingCount = 0

    /// The operation actually RUNNING right now, `nil` when the chain is
    /// idle. Distinct from "the newest queued operation": when a second
    /// call arrives while the first is still executing, this stays at
    /// the first operation's direction until the first operation
    /// actually finishes and the chain moves on to the second -- so the
    /// Settings row never shows "Stopping…" for an enable that is still
    /// running, or vice versa.
    private(set) var runningOperation: Operation?
    private(set) var lastReport: IPCActivationPresenter.AlertContent?

    init() {}

    /// Queues `work` after every previously queued operation on this
    /// chain, records its result as `lastReport`, and returns the result
    /// once it runs. The tail swap and the
    /// `pendingCount` increment below both complete synchronously before
    /// `work`'s first suspension point, so two calls made back to back
    /// on @MainActor are strictly ordered: the second call's `Task` body
    /// cannot even start running until the first call's `work` has fully
    /// completed.
    func runEnable(_ work: @escaping @MainActor () async -> IPCActivationOutcome) async -> IPCActivationOutcome {
        await run(.enabling) { [self] in
            let outcome = await work()
            record(outcome)
            return outcome
        }
    }

    /// Same contract as `runEnable`, for the disable direction.
    func runDisable(_ work: @escaping @MainActor () async -> IPCDeactivationReport) async -> IPCDeactivationReport {
        await run(.disabling) { [self] in
            let report = await work()
            record(report)
            return report
        }
    }

    private func record(_ outcome: IPCActivationOutcome) {
        lastReport = IPCActivationPresenter.enableAlert(for: outcome)
    }

    private func record(_ report: IPCDeactivationReport) {
        lastReport = IPCActivationPresenter.disableAlert(for: report)
    }

    private func run<T: Sendable>(_ operation: Operation, _ work: @escaping @MainActor () async -> T) async -> T {
        let previousTail = tail
        pendingCount += 1
        // True only when nothing precedes this call in the chain, so its
        // work starts running the moment this Task is scheduled --
        // `runningOperation` can be set synchronously right here. A
        // queued call behind an in-flight one must NOT set
        // `runningOperation` yet: doing so would make it reflect the
        // newest QUEUED operation rather than the one actually running,
        // reintroducing the bug this property exists to fix.
        let entersRunningImmediately = pendingCount == 1
        if entersRunningImmediately {
            runningOperation = operation
            NotificationCenter.default.post(name: .calyxIPCStateDidChange, object: nil)
        }

        let resultBox = ResultBox<T>()
        let currentTail = Task { @MainActor in
            await previousTail?.value
            // Reached once the preceding operation (if any) has fully
            // finished, so this IS the operation now running. Posts only
            // when the running direction actually changes, so a lone
            // queued call (already posted above) never double-posts.
            if !entersRunningImmediately, runningOperation != operation {
                runningOperation = operation
                NotificationCenter.default.post(name: .calyxIPCStateDidChange, object: nil)
            }
            let result = await work()
            resultBox.result = result

            // Decrement and teardown run here, inside the Task body, so
            // they are ordered by the chain itself (each task's body only
            // starts past `await previousTail?.value` once the
            // predecessor's own teardown below has already run) rather
            // than by whichever caller's continuation the runtime happens
            // to resume first.
            pendingCount -= 1
            if pendingCount == 0 {
                runningOperation = nil
                NotificationCenter.default.post(name: .calyxIPCStateDidChange, object: nil)
            }
        }
        tail = currentTail

        await currentTail.value

        // Force-unwrap is safe: `currentTail`'s body always assigns
        // `resultBox.result` before returning, and `await currentTail.value`
        // above already waited for that body to finish.
        return resultBox.result!
    }
}

/// Reference box carrying `run<T>`'s result out of the Task closure.
/// `@MainActor`-isolated like the chain itself, so no extra
/// synchronization is needed beyond the `await currentTail.value` that
/// already orders the write before the read.
@MainActor
private final class ResultBox<T> {
    var result: T?
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by `IPCActivationChain` whenever `runningOperation`
    /// changes: entering flight (`nil` -> some), the running operation
    /// switching direction (a queued call taking over from the one that
    /// just finished), and leaving flight once `runningOperation` drops
    /// back to `nil` AND the finishing operation's outcome has already
    /// been recorded into `lastReport` -- so `SettingsWindowController`,
    /// the only observer, always reads state that matches what just
    /// happened.
    static let calyxIPCStateDidChange = Notification.Name("com.calyx.ipc.stateDidChange")
}
