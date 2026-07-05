// ProcessCancellationBridge.swift
// Calyx
//
// R16-1 (r16-fix-spec.md): shared by SystemCommandRunner.runInternal and
// GitService.run -- was two byte-identical `private final class
// CancellationBridge` copies, one per file (R14-D/R14-E), consolidated
// here so a future fix to the terminate-once discipline only has to
// land in one place.

import Foundation

/// Thread-safe bridge between `withTaskCancellationHandler`'s
/// `onCancel` closure (which may run before the `Process` even exists
/// yet, concurrently with, or after it starts) and the dispatch-queue
/// block that actually launches it. Whichever side observes the
/// other's write first under `lock` is responsible for calling
/// `terminate()`: `cancel()` terminates directly if `register(_:)`
/// already ran; otherwise `register(_:)`'s return value tells the
/// launching side the task was already cancelled by the time the
/// process came into being, so it must route through `terminate()`
/// itself right after `process.run()` succeeds (calling `terminate()`
/// on an unlaunched `Process` is unsafe, so `cancel()` alone must never
/// do so). `terminate()` is also each caller's watchdog timer's own
/// termination path, so `cancel()` and a natural timeout can never race
/// each other calling `Process.terminate()` unsynchronized.
final class ProcessCancellationBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var terminated = false
    private var process: Process?

    /// Called once, immediately after `process.run()` succeeds.
    /// Returns whether the task was already cancelled by this point.
    func register(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        return isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        terminate()
    }

    /// Single terminate-once path shared by both `cancel()` (Task
    /// cancellation), the register-returns-true already-cancelled
    /// branch, and each caller's own watchdog timer (natural timeout) --
    /// Foundation does not document `Process.terminate()` as safe to
    /// call concurrently from two threads, so this removes that
    /// unverified assumption entirely rather than relying on it.
    func terminate() {
        lock.lock()
        guard !terminated, let proc = process else { lock.unlock(); return }
        terminated = true
        lock.unlock()
        proc.terminate()
    }
}
