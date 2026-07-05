//
//  SessionDaemonClientWriteOpCancellationShieldTests.swift
//  CalyxTests
//
//  TDD Red phase, round 14 (r14-fix-spec.md, R14-C): now that R12-A makes
//  Task cancellation reach the actual subprocess (SystemCommandRunner's
//  CancellationBridge), SessionDaemonClient.kill(id:) and setMeta(...) --
//  both WRITE ops -- have become newly exposed to a caller's ambient Task
//  cancellation racing an in-flight IPC write: kill(id:) awaits
//  `commandRunner.run(...)` directly in the same Task as its caller, so
//  if that caller's enclosing Task is cancelled mid-flight, cancellation
//  now reaches the subprocess and can SIGTERM the write partway through --
//  silently losing the kill, worse than a slow-but-eventually-completed
//  one (see SessionDaemonClientBoundedOperationsTests' header comment,
//  which explicitly carves kill(id:) out of the bounded-with-cancel
//  treatment for exactly this reason).
//
//  The fix (R14-C) wraps the commandRunner.run call in an inner
//  unstructured Task and awaits its .value -- the same shielding pattern
//  LSPInstaller.runPrerequisiteDeduped already uses (an unstructured
//  `Task { ... }` is not automatically cancelled just because its
//  creating context's Task is cancelled) -- so ambient cancellation of
//  any future caller's Task can never reach the runner mid-IPC.
//
//  This test drives `SessionDaemonClient.kill(id:)` (a REAL client, not a
//  protocol-level fake) with a fake LSPCommandRunner whose run(...)
//  suspends on a continuation this test controls explicitly and records,
//  via `withTaskCancellationHandler`, whether ITS OWN enclosing Task (the
//  one actually awaiting run(...)) ever observed cancellation. The host
//  Task calling kill(id:) is cancelled while the fake's run() is
//  confirmed in flight; a correct (shielded) implementation must leave
//  the fake's own Task uncancelled -- ambient cancellation stops at the
//  shield -- and kill(id:) must still run the fake to completion once the
//  test resumes it.
//
//  Coverage:
//  - kill(id:) shields commandRunner.run(...) from the caller's ambient
//    Task cancellation (RED today: cancelling the host Task reaches
//    straight through to the runner's own Task, observed as true, and
//    the kill never gets the chance to be resumed to completion the way
//    this test expects)
//

import XCTest
@testable import Calyx

/// Suspends on a continuation this test resumes explicitly
/// (`resumeRun()`), standing in for an in-flight `calyx-session kill` IPC
/// round-trip. `withTaskCancellationHandler` records, via
/// `observedCancellation`, whether the Task actually awaiting run(...)
/// was ever cancelled -- the direct observable for "did ambient
/// cancellation reach the runner," independent of whatever kill(id:)'s
/// own caller does.
private final class CancellationRecordingCommandRunner: LSPCommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _hasEnteredRun = false
    private var _observedCancellation = false
    private var _didComplete = false
    private var pendingContinuation: CheckedContinuation<Void, Never>?

    var hasEnteredRun: Bool {
        lock.lock(); defer { lock.unlock() }
        return _hasEnteredRun
    }
    var observedCancellation: Bool {
        lock.lock(); defer { lock.unlock() }
        return _observedCancellation
    }
    var didComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        return _didComplete
    }

    private func markEntered() {
        lock.lock(); _hasEnteredRun = true; lock.unlock()
    }
    private func markObservedCancellation() {
        lock.lock(); _observedCancellation = true; lock.unlock()
    }
    private func markCompleted() {
        lock.lock(); _didComplete = true; lock.unlock()
    }

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        markEntered()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.lock.lock()
                self.pendingContinuation = continuation
                self.lock.unlock()
            }
        } onCancel: {
            self.markObservedCancellation()
        }
        markCompleted()
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func locate(_ executable: String) async -> URL? { nil }

    /// Lets the "IPC round-trip" finish, mirroring the daemon's actual
    /// process eventually exiting.
    func resumeRun() {
        lock.lock()
        let continuation = pendingContinuation
        pendingContinuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private struct FixedBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

final class SessionDaemonClientWriteOpCancellationShieldTests: XCTestCase {

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve, mirroring
    /// SessionBrowserModelRefreshDedupeTests' `waitUntil` helper.
    private func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    /// RED (R14-C): cancelling the host Task calling kill(id:) mid-flight
    /// must NOT reach the runner's own Task -- today it does, because
    /// kill(id:) awaits commandRunner.run(...) directly in the caller's
    /// Task instead of an insulated inner one.
    func test_kill_shieldsRunnerFromHostTaskCancellation() async {
        let resolver = FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session")
        let runner = CancellationRecordingCommandRunner()
        let client = SessionDaemonClient(resolver: resolver, commandRunner: runner)

        let hostTask = Task { await client.kill(id: "some-session-id") }

        // Let the kill actually reach the runner before cancelling, so
        // the cancellation below is provably issued while the IPC write
        // is genuinely in flight, not merely racing its start.
        await waitUntil { runner.hasEnteredRun }

        hostTask.cancel()

        // Give the cancellation every opportunity to propagate down to
        // the runner's Task before asserting it did not.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertFalse(
            runner.observedCancellation,
            "kill(id:) must shield commandRunner.run(...) from the caller's ambient Task cancellation -- an " +
            "in-flight write must never be cancelled just because the caller's Task was"
        )

        // Let the "IPC round-trip" finish and confirm the kill still ran
        // to completion despite the host Task's cancellation.
        runner.resumeRun()
        _ = await hostTask.value

        XCTAssertTrue(
            runner.didComplete,
            "kill(id:) must let an in-flight commandRunner.run(...) call run to completion even after the " +
            "caller's Task was cancelled"
        )
    }
}
