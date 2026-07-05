//
//  SystemCommandRunnerCancellationTests.swift
//  CalyxTests
//
//  TDD Red phase, round 12 (r12-fix-spec.md, R12-A item 1):
//  SystemCommandRunner.run()'s subprocess wait is a plain
//  withCheckedThrowingContinuation with no withTaskCancellationHandler
//  attached, so cancelling the Swift Task awaiting run() is silently
//  ignored -- the underlying Process keeps running until it exits
//  naturally or the 600s SIGTERM watchdog (runTimeoutSeconds) eventually
//  trips. This matters most for `listAllBounded()`'s timeout arm
//  (SessionDaemonClient.swift): it already calls `daemonTask?.cancel()`
//  on the losing daemon call once the timeout wins, but today that
//  cancellation reaches nothing -- the calyx-session subprocess the
//  daemon call spawned keeps running in the background every time the
//  bound trips, piling up over time.
//
//  Spawns a real `/bin/sh` child through SystemCommandRunner.run()
//  directly (no dedicated test seam exists at this level -- it drives
//  Process itself), mirroring StdioLSPTransportTests' pid-file +
//  POSIX kill(pid, 0) liveness-probe style. Cancels the enclosing Task
//  once the child is confirmed alive, then asserts the child is gone
//  within a bound comfortably short of both the child's natural 30s
//  sleep and the 600s watchdog.
//
//  IMPORTANT: SIGKILLs any pid it captured in a `defer` block to
//  prevent CI leakage, exactly like StdioLSPTransportTests.
//
//  Coverage:
//  - Cancelling a Task awaiting SystemCommandRunner.run() terminates the
//    underlying Process well before its natural duration (RED: today
//    cancellation is ignored entirely -- the child survives the bound)
//

import XCTest
import Darwin
@testable import Calyx

final class SystemCommandRunnerCancellationTests: XCTestCase {

    // MARK: - Setup

    override class func setUp() {
        super.setUp()
        // Foundation usually sets SO_NOSIGPIPE on its pipe FDs, but the
        // host process can still receive SIGPIPE during a write race
        // with a SIGKILL'd child. Ignore it so the test runner doesn't
        // crash, mirroring StdioLSPTransportTests.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Helpers

    /// POSIX-friendly liveness probe. `kill(pid, 0)` does no signal
    /// delivery but returns 0 if the pid exists and the caller has
    /// permission, or -1 with `errno == ESRCH` if the process is gone.
    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Unique scratch path for the shell's `echo $$ > path` pid-emission.
    private func uniquePidPath() -> String {
        NSTemporaryDirectory()
            + "SystemCommandRunnerCancellationTests_\(UUID().uuidString).pid"
    }

    /// Poll `pidPath` until the shell writes its pid, or `timeout`
    /// elapses. Returns the parsed pid.
    private func waitForPid(at pidPath: String, timeout: TimeInterval) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: pidPath, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int32(trimmed), pid > 0 {
                    return pid
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
        struct PidFileTimeout: Error, CustomStringConvertible {
            let path: String
            var description: String { "timed out waiting for pid file at \(path)" }
        }
        throw PidFileTimeout(path: pidPath)
    }

    // MARK: - Cancellation must reach the subprocess

    /// RED (R12-A item 1): today `run()`'s continuation has no
    /// `withTaskCancellationHandler`, so `task.cancel()` never reaches
    /// the spawned `Process` -- the child survives well past the bound
    /// below and is only ever killed by this test's own cleanup `defer`.
    func test_taskCancellation_terminatesSubprocess_wellBeforeNaturalDuration() async throws {
        let pidPath = uniquePidPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }

        let runner = SystemCommandRunner()
        let task = Task {
            try await runner.run(
                executable: "/bin/sh",
                // `exec` replaces the shell's process image with `sleep`
                // in place (same pid) rather than forking it as a child,
                // so the pid captured below is the actual long-running
                // process, not a wrapper that would leave `sleep`
                // orphaned once the wrapper alone is SIGKILL'd.
                arguments: ["-c", "echo $$ > '\(pidPath)'; exec sleep 30"],
                workingDirectory: nil,
                environment: nil
            )
        }

        let pid = try await waitForPid(at: pidPath, timeout: 2.0)
        defer { _ = kill(pid, SIGKILL) } // ensure CI cleanliness regardless of outcome

        XCTAssertTrue(isAlive(pid), "Precondition: the spawned child must be alive before cancelling")

        task.cancel()

        // Bound comfortably short of the child's natural 30s sleep and
        // SystemCommandRunner's own 600s watchdog: a correct
        // implementation ends the subprocess promptly on cancellation.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !isAlive(pid) { break }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        XCTAssertFalse(
            isAlive(pid),
            """
            Child PID \(pid) survived Task cancellation for 5s. SystemCommandRunner.run() must propagate \
            Swift Task cancellation to the underlying Process (SIGTERM) instead of ignoring it until the \
            600s watchdog eventually trips.
            """
        )
    }
}
