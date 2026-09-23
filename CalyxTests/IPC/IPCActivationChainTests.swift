//
//  IPCActivationChainTests.swift
//  CalyxTests
//
//  Covers IPCActivationChain, the @MainActor Task chain that serializes
//  enable()/disable() end to end: L1's per-file flock only orders writes
//  to ONE file, but a single activation touches several files (agent
//  config, agent hooks), so an enable immediately followed by a disable
//  can otherwise land out of order across files. The chain also owns the
//  in-flight flag Settings observes: it must go up synchronously when
//  run() is entered and come down only after the LAST queued work
//  finishes, never dipping between two consecutive operations (a dip
//  would flicker the Settings row's controls between two back-to-back
//  toggles), and it posts .calyxIPCStateDidChange on both transitions.
//
//  Every wait below is wrapped in a bounded timeout (withTimeout) so a
//  regression that deadlocks the chain fails the test rather than
//  hanging the suite.
//

import XCTest
@testable import Calyx

/// Bounds an async expression so a chain that deadlocks fails this test
/// instead of hanging the suite. Local copy: LSPClientTests.swift's own
/// withTimeout is private to that file.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval = 2,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// A minimal, deterministic `IPCDeactivationReport` fixture -- these
/// tests exercise the chain's serialization and in-flight bookkeeping,
/// never the report's own content, so every axis is `.skipped`.
private func makeDeactivationReport() -> IPCDeactivationReport {
    IPCDeactivationReport(
        config: IPCConfigResult(
            claudeCode: .skipped(reason: "test"),
            codex: .skipped(reason: "test"),
            openCode: .skipped(reason: "test"),
            hermes: .skipped(reason: "test"),
            grok: .skipped(reason: "test")
        ),
        hooks: AgentHooksResult(
            claudeCode: .skipped(reason: "test"),
            codex: .skipped(reason: "test"),
            openCode: .skipped(reason: "test"),
            grok: .skipped(reason: "test"),
            pi: .skipped(reason: "test")
        )
    )
}

/// A one-shot async gate: `wait()` suspends until `fire()` is called,
/// even if `fire()` happens to run first (unlike a bare
/// `CheckedContinuation`, which would crash on a `wait()` that arrives
/// after `fire()`). File-scope rather than nested in the test class so
/// it never picks up the class's `@MainActor` isolation.
private actor Gate {
    private var isFired = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isFired { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        isFired = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class IPCActivationChainTests: XCTestCase {

    // MARK: - Ordering

    /// task1's work sleeps mid-body before its second marker; task2's
    /// work never sleeps. Without the chain's serialization, MainActor
    /// is free to run task2 to completion during task1's sleep (both
    /// tasks are created back to back, before either has suspended),
    /// producing "2-start"/"2-end" ahead of "1-end". Only strict
    /// serialization -- task2's body not even starting until task1's
    /// work fully completes -- produces the asserted order.
    func test_backToBackCalls_runStrictlySerially() async throws {
        let chain = IPCActivationChain()

        actor Log {
            var entries: [String] = []
            func add(_ entry: String) { entries.append(entry) }
        }
        let log = Log()

        let task1 = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in
                await log.add("1-start")
                try? await Task.sleep(nanoseconds: 30_000_000)
                await log.add("1-end")
                return makeDeactivationReport()
            }
        }
        let task2 = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in
                await log.add("2-start")
                await log.add("2-end")
                return makeDeactivationReport()
            }
        }

        let result = await withTimeout {
            await task1.value
            await task2.value
            return await log.entries
        }
        let entries = try XCTUnwrap(result, "chain.run must not hang for two back-to-back calls")

        XCTAssertEqual(entries, ["1-start", "1-end", "2-start", "2-end"],
                       "chain.run must strictly serialize back-to-back calls: \"2-start\" must never appear " +
                       "before \"1-end\"")
    }

    // MARK: - In-flight flag

    func test_runningOperation_upSynchronouslyOnEntry_neverDipsBetweenConsecutiveOperations_downOnlyAfterLast() async throws {
        let chain = IPCActivationChain()
        XCTAssertFalse((chain.runningOperation != nil), "Precondition: a freshly constructed chain has no work in flight")

        let task1 = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in
                XCTAssertTrue((chain.runningOperation != nil), "runningOperation must go non-nil synchronously when run() is entered")
                try? await Task.sleep(nanoseconds: 20_000_000)
                return makeDeactivationReport()
            }
        }
        let task2 = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in
                XCTAssertTrue((chain.runningOperation != nil),
                              "runningOperation must not dip to nil between two consecutive queued operations")
                return makeDeactivationReport()
            }
        }

        let completed = await withTimeout {
            await task1.value
            await task2.value
            return true
        }
        XCTAssertNotNil(completed, "chain.run must not hang for two back-to-back calls")

        XCTAssertFalse((chain.runningOperation != nil), "runningOperation must drop to nil only after the LAST queued work finishes")
    }

    // MARK: - Notification

    func test_runningOperation_postsStateChangeNotification_onceForEachTransition() async throws {
        let chain = IPCActivationChain()
        let expectation = XCTNSNotificationExpectation(name: .calyxIPCStateDidChange)
        expectation.expectedFulfillmentCount = 2
        expectation.assertForOverFulfill = true

        _ = await withTimeout {
            await chain.runDisable { () async -> IPCDeactivationReport in makeDeactivationReport() }
        }

        await fulfillment(of: [expectation], timeout: 2)
    }

    // MARK: - runningOperation

    /// Queues an enable, lets it start running and blocks it on a gate,
    /// then queues a disable behind it. While the enable is still
    /// running, `runningOperation` must read `.enabling` -- the newest
    /// QUEUED operation is `.disabling`, but nothing disabling has
    /// started executing yet. Once the enable is released, the disable
    /// becomes the running operation and `runningOperation` must switch
    /// to `.disabling` for the duration of its own work.
    func test_runningOperation_reflectsExecutingOp_notNewestQueued() async throws {
        let chain = IPCActivationChain()
        XCTAssertNil(chain.runningOperation, "Precondition: an idle chain has no running operation")

        let enableStarted = Gate()
        let releaseEnable = Gate()
        let disableStarted = Gate()
        let releaseDisable = Gate()

        let enableTask = Task { @MainActor in
            await chain.runEnable { () async -> IPCActivationOutcome in
                await enableStarted.fire()
                await releaseEnable.wait()
                return .serverFailed(.tokenGeneration)
            }
        }

        await enableStarted.wait()
        XCTAssertEqual(chain.runningOperation, .enabling,
                       "runningOperation must read .enabling while the enable's own work is executing")

        // Queue the disable while the enable is still running, and give
        // its Task a settle window to reach its own queued-but-blocked
        // state (blocked on awaiting the enable's Task, never on the
        // gate below -- disableStarted only fires once it is actually
        // running).
        let disableTask = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in
                await disableStarted.fire()
                await releaseDisable.wait()
                return makeDeactivationReport()
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(chain.runningOperation, .enabling,
                       "a queued disable must not become the running operation before the enable finishes")

        await releaseEnable.fire()
        await disableStarted.wait()
        XCTAssertEqual(chain.runningOperation, .disabling,
                       "runningOperation must switch to .disabling once the queued disable starts executing")

        await releaseDisable.fire()

        let completed = await withTimeout {
            await enableTask.value
            await disableTask.value
            return true
        }
        XCTAssertNotNil(completed, "both queued operations must complete without hanging")

        XCTAssertNil(chain.runningOperation, "runningOperation must drop back to nil once the chain is idle")
    }

    /// Two back-to-back calls in the SAME direction must never post a
    /// spurious "operation changed" notification: the running direction
    /// never actually changes between them.
    func test_runningOperation_sameDirectionBackToBack_postsNoExtraNotification() async throws {
        let chain = IPCActivationChain()
        let expectation = XCTNSNotificationExpectation(name: .calyxIPCStateDidChange)
        // Exactly 2: entering flight (first disable starts running) and
        // leaving flight (second disable finishes). No third post for
        // the second disable becoming the running operation, since it
        // was already .disabling.
        expectation.expectedFulfillmentCount = 2
        expectation.assertForOverFulfill = true

        let task1 = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in
                try? await Task.sleep(nanoseconds: 20_000_000)
                return makeDeactivationReport()
            }
        }
        let task2 = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in makeDeactivationReport() }
        }

        _ = await withTimeout {
            await task1.value
            await task2.value
            return true
        }

        await fulfillment(of: [expectation], timeout: 2)
    }

    /// Pins the production consequence directly: with an enable running
    /// and a disable queued behind it, `runningOperation` must never be observed
    /// observed `false` until BOTH have completed. Checked two ways so a
    /// spurious teardown post is caught, not just a spurious flag value:
    /// every `.calyxIPCStateDidChange` post is snapshotted together with
    /// whether the disable's own work has already run, and `runningOperation`
    /// is also read directly at the moment the disable is executing.
    func test_runningOperation_neverObservedNil_untilBothQueuedOperationsComplete() async throws {
        let chain = IPCActivationChain()

        @MainActor final class SnapshotBox {
            var posts: [(hasRunningOperation: Bool, disableWorkHasRun: Bool)] = []
            var disableWorkHasRun = false
        }
        let box = SnapshotBox()

        let observer = NotificationCenter.default.addObserver(
            forName: .calyxIPCStateDidChange,
            object: nil,
            queue: nil
        ) { _ in
            // IPCActivationChain posts only from its own @MainActor context
            // (see the chain's own comments), so the thread this handler
            // runs on -- the notification's posting thread -- is always
            // already the main thread isolated to that actor.
            MainActor.assumeIsolated {
                box.posts.append((hasRunningOperation: (chain.runningOperation != nil), disableWorkHasRun: box.disableWorkHasRun))
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let enableStarted = Gate()
        let releaseEnable = Gate()
        let disableStarted = Gate()

        let enableTask = Task { @MainActor in
            await chain.runEnable { () async -> IPCActivationOutcome in
                await enableStarted.fire()
                await releaseEnable.wait()
                return .serverFailed(.tokenGeneration)
            }
        }

        await enableStarted.wait()

        let disableTask = Task { @MainActor in
            await chain.runDisable { () async -> IPCDeactivationReport in
                await disableStarted.fire()
                box.disableWorkHasRun = true
                XCTAssertTrue((chain.runningOperation != nil), "runningOperation must still be non-nil while the disable's own work runs")
                return makeDeactivationReport()
            }
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        await releaseEnable.fire()
        await disableStarted.wait()

        let completed = await withTimeout {
            await enableTask.value
            await disableTask.value
            return true
        }
        XCTAssertNotNil(completed, "both queued operations must complete without hanging")

        XCTAssertFalse((chain.runningOperation != nil), "runningOperation must be nil once both queued operations have completed")

        let posts = box.posts

        XCTAssertEqual(posts.count, 3,
                       "expected exactly 3 notification posts: enter flight, switch to disabling, leave flight -- " +
                       "a spurious extra teardown post would appear here even if runningOperation's own value looked " +
                       "correct on direct reads")

        for post in posts.dropLast() {
            XCTAssertTrue(post.hasRunningOperation,
                          "every post before the disable's work has run must still read a non-nil runningOperation")
        }

        let lastPost = try XCTUnwrap(posts.last)
        XCTAssertFalse(lastPost.hasRunningOperation, "the final post must be the one where runningOperation actually drops to nil")
        XCTAssertTrue(lastPost.disableWorkHasRun,
                      "the final post must land after the disable's own work has already run, never before")
    }
}
