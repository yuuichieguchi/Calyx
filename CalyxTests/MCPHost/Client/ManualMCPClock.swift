//
//  ManualMCPClock.swift
//  CalyxTests
//
//  Single shared `MCPClock` test double for every MCPHost actor that
//  takes an injectable clock (`MCPUpstreamClient`, `MCPUpstreamConnection`,
//  `StreamableHTTPMCPTransport`'s SSE reconnect delay). Per the API
//  contract section 3.1, progress through virtual time happens only
//  through an explicit `advance(by:)` call: `sleep(for:)` suspends the
//  caller until `advance(by:)` has moved virtual time past the
//  requested threshold, so a test controls exactly when a timeout or
//  backoff delay elapses instead of racing the wall clock.
//
//  A suspended `sleep(for:)` also resumes immediately if its Task is
//  cancelled, so a production race between "the real response arrived"
//  and "the timeout elapsed" cannot hang a test when the response wins.
//
//  `sleepDurations()` records every requested duration, in order, for
//  tests that assert on the backoff/delay sequence itself.
//

import Foundation
@testable import Calyx

final class ManualMCPClock: MCPClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var _sleepDurations: [TimeInterval] = []
    private var pendingWaiters: [UUID: (threshold: Date, continuation: CheckedContinuation<Void, Never>)] = [:]
    /// Waiter ids cancelled before their continuation was registered (the
    /// cancellation handler can run concurrently with, and before, the
    /// registration below). Consulted at registration time so a waiter
    /// that was already cancelled resumes immediately instead of hanging.
    private var cancelledWaiterIDs: Set<UUID> = []

    init() {
        self.current = Date(timeIntervalSince1970: 0)
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func sleep(for seconds: TimeInterval) async {
        let (threshold, alreadyDue) = registerSleep(seconds)

        if alreadyDue { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if current >= threshold || cancelledWaiterIDs.remove(waiterID) != nil {
                    lock.unlock()
                    continuation.resume()
                } else {
                    pendingWaiters[waiterID] = (threshold, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            if let waiter = pendingWaiters.removeValue(forKey: waiterID) {
                lock.unlock()
                waiter.continuation.resume()
            } else {
                cancelledWaiterIDs.insert(waiterID)
                lock.unlock()
            }
        }
    }

    /// Records `seconds` and returns its wake threshold. Synchronous so
    /// the lock is never taken directly in an async context.
    private func registerSleep(_ seconds: TimeInterval) -> (threshold: Date, alreadyDue: Bool) {
        lock.lock(); defer { lock.unlock() }
        _sleepDurations.append(seconds)
        let threshold = current.addingTimeInterval(seconds)
        return (threshold, current >= threshold)
    }

    /// Move virtual time forward by `seconds` and resume every
    /// `sleep(for:)` call whose threshold has now been reached.
    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let now = current
        let due = pendingWaiters.filter { $0.value.threshold <= now }
        for key in due.keys { pendingWaiters.removeValue(forKey: key) }
        lock.unlock()
        for waiter in due.values { waiter.continuation.resume() }
    }

    /// Every duration passed to `sleep(for:)`, in order.
    func sleepDurations() -> [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return _sleepDurations
    }
}
