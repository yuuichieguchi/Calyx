//
//  SessionDaemonClientBoundedCancellationTests.swift
//  CalyxTests
//
//  TDD Red phase, round 14 (r14-fix-spec.md, R14-A): `bounded()`
//  (SessionDaemonClient.swift's shared race helper backing both
//  `listAllBounded()` and `sessionStateBounded(id:)`) awaits its
//  `withCheckedContinuation` directly, with no `withTaskCancellationHandler`
//  attached. Cancelling the caller's Task while the race is in flight
//  therefore does nothing: neither the internal `operationTask` nor
//  `timeoutTask` (both unstructured, hence never auto-cancelled just
//  because the *caller's* Task was) ever observes it, so the call rides
//  out the full ~5s `daemonQueryBoundTimeoutSeconds` bound regardless --
//  the exact "quick-toggle overlapping-fetch" gap AppDelegate's
//  disable-branch comment already describes (R14-A makes that comment
//  true).
//
//  The fix wraps the continuation await in `withTaskCancellationHandler`
//  whose handler cancels BOTH the operation and timeout arms, resuming
//  promptly with the `onTimeout` sentinel.
//
//  Drives `SessionDaemonClient.listAllBounded()` (a REAL client, not a
//  protocol-level fake) with a fake `LSPCommandRunner` whose run(...)
//  suspends forever (mirrors SessionDaemonClientBoundedListTests'
//  NeverCompletingCommandRunner) but additionally records, via its own
//  `withTaskCancellationHandler`, the wall-clock moment its own enclosing
//  Task (`bounded()`'s internal operationTask) is cancelled -- the direct
//  observable for "did the caller's cancellation actually reach the
//  runner," distinct from the internal race's own eventual (~5s) losing-
//  arm cancellation of that same operationTask.
//
//  Coverage:
//  - Cancelling the Task awaiting listAllBounded() ends promptly (well
//    under the 5s bound) with the [] sentinel, AND the runner observed
//    cancellation promptly too (RED today: the call rides out the full
//    ~5s bound, and by the time it resolves the runner's cancellation was
//    already observed via the race's own unrelated internal mechanism --
//    not promptly, and not because of the caller's early cancel())
//

import XCTest
@testable import Calyx

/// An `LSPCommandRunner` whose run(...) never completes on its own
/// (mirrors `NeverCompletingCommandRunner`), but wraps its suspension in
/// `withTaskCancellationHandler` to record the wall-clock moment its own
/// enclosing Task is cancelled. Harmless to leave permanently suspended,
/// matching that fixture's own "harmless to leave suspended for the rest
/// of the process's life" reasoning.
private final class CancellationTimestampingCommandRunner: LSPCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _runEnteredAt: Date?
    private var _cancelObservedAt: Date?

    var runEnteredAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _runEnteredAt
    }
    var cancelObservedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _cancelObservedAt
    }

    /// `NSLock.lock()`/`unlock()` are unavailable at the top level of an
    /// `async` function body under this toolchain's Swift 6 diagnostics
    /// (async-unsafe scoped locking), so `run(...)` below calls these
    /// plain synchronous helpers instead of locking inline, mirroring
    /// SessionBrowserModelRefreshDedupeTests' `incrementCallCount()`.
    private func markEntered() {
        lock.lock(); defer { lock.unlock() }
        if _runEnteredAt == nil { _runEnteredAt = Date() }
    }
    private func markCancelObserved() {
        lock.lock(); defer { lock.unlock() }
        if _cancelObservedAt == nil { _cancelObservedAt = Date() }
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        markEntered()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (_: CheckedContinuation<CommandResult, Never>) in
                // Deliberately never resumed.
            }
        } onCancel: {
            self.markCancelObserved()
        }
    }

    func locate(_ executable: String) async -> URL? { nil }
}

private struct FixedBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

final class SessionDaemonClientBoundedCancellationTests: XCTestCase {

    /// RED (R14-A): cancelling the outer Task awaiting listAllBounded()
    /// must end the call promptly and reach the runner promptly too --
    /// today neither happens: the call rides out the internal race's own
    /// ~5s bound, and the runner's cancellation (when it eventually
    /// fires) comes from that race's own unrelated timeout-arm logic, not
    /// from the caller's early cancel().
    func test_listAllBounded_externalCancellation_endsPromptlyAndReachesRunnerPromptly() async {
        let resolver = FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session")
        let runner = CancellationTimestampingCommandRunner()
        let client = SessionDaemonClient(resolver: resolver, commandRunner: runner)

        let start = Date()
        let outer = Task { await client.listAllBounded() }

        // Wait until the runner's run() has actually been entered, so
        // the cancel() below is provably issued while the daemon
        // round-trip is genuinely in flight, not merely racing its
        // start.
        let enterDeadline = Date().addingTimeInterval(2.0)
        while runner.runEnteredAt == nil, Date() < enterDeadline {
            await Task.yield()
        }
        XCTAssertNotNil(runner.runEnteredAt, "Precondition: the fake runner must have been entered before cancelling")

        let cancelledAt = Date()
        outer.cancel()

        let result = await outer.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            result, [],
            "listAllBounded() must still degrade to [] on cancellation, exactly like its own timeout sentinel"
        )
        XCTAssertLessThan(
            elapsed, 1.0,
            "cancelling the caller's Task must end listAllBounded() promptly, not ride out the full ~5s " +
            "daemonQueryBoundTimeoutSeconds bound"
        )

        guard let observedAt = runner.cancelObservedAt else {
            XCTFail("the runner never observed cancellation propagated from the caller's Task")
            return
        }
        XCTAssertLessThan(
            observedAt.timeIntervalSince(cancelledAt), 1.0,
            "cancellation must reach the runner promptly -- not merely via the internal race's own ~5s " +
            "timeout-arm cancellation of the losing operationTask"
        )
    }
}
