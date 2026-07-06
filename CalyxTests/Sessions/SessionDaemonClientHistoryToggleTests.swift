//
//  SessionDaemonClientHistoryToggleTests.swift
//  CalyxTests
//
//  TDD Red phase, P6 RED2: SessionDaemonClient.setHistoryEnabled(_:), the
//  first CLI-reaching surface for ControlMsg::SetHistoryEnabled (see
//  calyx-session/crates/cli/src/commands/history.rs's own P6 RED2 header
//  -- the daemon message pair has existed since an earlier P6 round, but
//  no CLI subcommand could send it until this one). Held-out compile-RED
//  (see SessionCommandSynthesizerRemoteAttachTests's header for this
//  codebase's convention): setHistoryEnabled(_:) does not exist yet on
//  SessionDaemonClientProtocol or SessionDaemonClient, so this file fails
//  to compile until the Green phase adds both. That compile failure IS
//  this file's RED evidence.
//
//  Coverage:
//  - setHistoryEnabled(true) / setHistoryEnabled(false) each prepend
//    ["--runtime-dir", "<root>/.calyx/run"] before ["history", "on"/"off"],
//    mirroring the four existing operations
//    SessionDaemonClientRuntimeDirArgsTests already covers, with a nil
//    environment
//  - setHistoryEnabled(_:) shields commandRunner.run(...) from the
//    caller's ambient Task cancellation, mirroring kill(id:)'s own R14-C
//    shield (SessionDaemonClientWriteOpCancellationShieldTests) -- a
//    WRITE, so an in-flight toggle must run to completion even if the
//    caller's Task is cancelled mid-flight
//

import XCTest
@testable import Calyx

private struct FixedBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

private struct FakeRootResolver: SessionRootResolverProtocol {
    let root: String
    func resolve() -> String { root }
}

/// Records every (arguments, environment) pair run(...) was called with.
/// Mirrors SessionDaemonClientRuntimeDirArgsTests's RecordingCommandRunner
/// (duplicated here rather than shared -- see that file's own per-file
/// convention).
private actor RecordingCommandRunner: LSPCommandRunner {
    private(set) var recordedCalls: [(arguments: [String], environment: [String: String]?)] = []

    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        recordedCalls.append((arguments, environment))
        return CommandResult(exitCode: 0, stdout: "", stderr: "")
    }

    func locate(_ executable: String) async -> URL? { nil }
}

final class SessionDaemonClientHistoryToggleTests: XCTestCase {

    func test_setHistoryEnabledTrue_prependsRuntimeDirBeforeHistoryOn() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        )

        await client.setHistoryEnabled(true)

        let recorded = await runner.recordedCalls
        XCTAssertEqual(recorded.count, 1, "setHistoryEnabled must invoke the command runner exactly once")
        XCTAssertEqual(
            recorded.first?.arguments,
            ["--runtime-dir", "/opt/calyx-fixture/custom-home/.calyx/run", "history", "on"],
            "setHistoryEnabled(true) must prepend --runtime-dir <root>/.calyx/run before its history on " +
            "subcommand arguments"
        )
        XCTAssertNil(recorded.first?.environment,
                     "setHistoryEnabled must pass a nil environment, matching every other operation on this " +
                     "client -- the session root travels via --runtime-dir, not an env override")
    }

    func test_setHistoryEnabledFalse_prependsRuntimeDirBeforeHistoryOff() async {
        let runner = RecordingCommandRunner()
        let client = SessionDaemonClient(
            resolver: FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session"),
            commandRunner: runner,
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home")
        )

        await client.setHistoryEnabled(false)

        let recorded = await runner.recordedCalls
        XCTAssertEqual(
            recorded.first?.arguments,
            ["--runtime-dir", "/opt/calyx-fixture/custom-home/.calyx/run", "history", "off"],
            "setHistoryEnabled(false) must prepend --runtime-dir <root>/.calyx/run before its history off " +
            "subcommand arguments"
        )
    }
}

// MARK: - Write-op cancellation shield

/// Suspends on a continuation this test resumes explicitly, mirroring
/// SessionDaemonClientWriteOpCancellationShieldTests's identically-shaped
/// helper (duplicated here rather than shared -- see that file's own
/// header for the same per-file convention).
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

final class SessionDaemonClientHistoryToggleCancellationShieldTests: XCTestCase {

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve, mirroring
    /// SessionDaemonClientWriteOpCancellationShieldTests's identical helper.
    private func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    /// RED (P6 RED2): cancelling the host Task calling setHistoryEnabled(_:)
    /// mid-flight must NOT reach the runner's own Task -- mirrors
    /// kill(id:)'s own R14-C shield exactly.
    func test_setHistoryEnabled_shieldsRunnerFromHostTaskCancellation() async {
        let resolver = FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session")
        let runner = CancellationRecordingCommandRunner()
        let client = SessionDaemonClient(resolver: resolver, commandRunner: runner)

        let hostTask = Task { await client.setHistoryEnabled(true) }

        // Let the call actually reach the runner before cancelling, so
        // the cancellation below is provably issued while the IPC write
        // is genuinely in flight, not merely racing its start.
        await waitUntil { runner.hasEnteredRun }

        hostTask.cancel()

        // Give the cancellation every opportunity to propagate down to
        // the runner's Task before asserting it did not.
        for _ in 0..<50 { await Task.yield() }

        XCTAssertFalse(
            runner.observedCancellation,
            "setHistoryEnabled must shield commandRunner.run(...) from the caller's ambient Task " +
            "cancellation -- an in-flight toggle write must never be cancelled just because the caller's " +
            "Task was"
        )

        // Let the "IPC round-trip" finish and confirm the call still ran
        // to completion despite the host Task's cancellation.
        runner.resumeRun()
        _ = await hostTask.value

        XCTAssertTrue(
            runner.didComplete,
            "setHistoryEnabled must let an in-flight commandRunner.run(...) call run to completion even " +
            "after the caller's Task was cancelled"
        )
    }
}
