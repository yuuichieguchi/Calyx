//
//  GitServiceCancellationTests.swift
//  CalyxTests
//
//  TDD Red phase, round 14 (r14-fix-spec.md, R14-E): GitService.run
//  (args:workDir:) is SystemCommandRunner.runInternal(...)'s own sibling
//  -- cited by that type's CancellationBridge doc comment ("mirrors the
//  pattern used by GitService.run(args:workDir:)") -- yet, unlike
//  SystemCommandRunner post-R12-A, GitService.run(args:workDir:) never
//  adopted the withTaskCancellationHandler fix: its continuation await
//  has no cancellation handler at all, so cancelling a Task awaiting any
//  GitService call (e.g. the diff tab's close path) does nothing -- the
//  spawned `git` subprocess keeps running until it exits naturally or
//  GitService's own unrelated 10s watchdog
//  (DispatchQueue.global().asyncAfter(deadline: .now() + 10)) eventually
//  trips.
//
//  GitService.run(args:workDir:) is `private`, and every public entry
//  point (repoRoot, gitStatus, commitLog, commitFiles, fileDiff) drives it
//  with a fixed argv -- there is no seam to hand it an arbitrary
//  long-running command the way SystemCommandRunnerCancellationTests
//  drives `/bin/sh -c 'exec sleep 30'` directly. Instead, this test makes
//  a REAL `git status` invocation (via the existing public
//  GitService.gitStatus(workDir:)) hang controllably and indefinitely by
//  pointing a scratch repo's `core.fsmonitor` at a script that never
//  responds: git's index-refresh path invokes that hook synchronously and
//  blocks reading its (never-arriving) response, so the `git status`
//  process itself parks in a blocking read -- confirmed empirically
//  (spawning the exact argv/env GitService.run uses, standalone, outside
//  this test file) to be the actual `git status` process, not a detached
//  child, exactly like the `exec`'d `sleep` in
//  SystemCommandRunnerCancellationTests -- so a SIGTERM aimed at the
//  `git` pid alone (no process-group signal) ends it immediately today,
//  once cancellation is wired to send one. The hook script's own
//  `/bin/sleep 30` (an absolute path -- GitService.run's env PATH is
//  `/usr/bin:/usr/local/bin`, which has no `/bin`) is a separate,
//  unmanaged grandchild git does not forward SIGTERM to, so this test
//  tracks and SIGKILLs both pids in a `defer` for CI cleanliness,
//  mirroring StdioLSPTransportTests' / SystemCommandRunnerCancellationTests'
//  pid-file + POSIX kill(pid, 0) liveness-probe style.
//
//  Coverage:
//  - Cancelling a Task awaiting GitService.gitStatus(workDir:) terminates
//    the underlying `git status` process well before its natural
//    duration (RED: today cancellation is ignored entirely -- the
//    process survives the bound)
//

import XCTest
import Darwin
@testable import Calyx

final class GitServiceCancellationTests: XCTestCase {

    // MARK: - Setup

    override class func setUp() {
        super.setUp()
        // Mirrors SystemCommandRunnerCancellationTests: a SIGKILL'd
        // child can race the host process's own pipe writes and deliver
        // SIGPIPE; ignore it so the test runner doesn't crash.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Helpers

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private func uniqueScratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitServiceCancellationTests_\(UUID().uuidString)")
    }

    /// Runs `/usr/bin/git <arguments>` synchronously in `workDir` for
    /// fixture setup only -- never through the type under test.
    @discardableResult
    private func runGitSetupCommand(_ arguments: [String], workDir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = workDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Poll `path` until it contains a parseable pid, or `timeout` elapses.
    private func waitForPid(at path: String, timeout: TimeInterval) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
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
        throw PidFileTimeout(path: path)
    }

    // MARK: - Cancellation must reach the git subprocess

    /// RED (R14-E): today GitService.run(args:workDir:)'s continuation
    /// has no withTaskCancellationHandler, so task.cancel() never reaches
    /// the spawned `git status` process -- it survives well past the
    /// bound below, torn down only by this test's own cleanup `defer`
    /// (or, eventually, GitService's unrelated 10s watchdog).
    func test_taskCancellation_terminatesGitSubprocess_wellBeforeNaturalDuration() async throws {
        let repoDir = uniqueScratchDir()
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoDir) }

        XCTAssertEqual(
            try runGitSetupCommand(["init", "-q", "."], workDir: repoDir), 0,
            "Precondition: git init must succeed"
        )

        let gitPidPath = repoDir.appendingPathComponent("git.pid").path
        let hookPidPath = repoDir.appendingPathComponent("hook.pid").path

        // `core.fsmonitor` hooks are invoked synchronously by `git
        // status`'s index-refresh path, which blocks reading the hook's
        // response until it arrives. This hook never responds -- it
        // records its invoker's pid ($PPID, i.e. the actual `git status`
        // process this test cancels) and its own pid ($$) before parking
        // in `/bin/sleep 30` (absolute path: GitService.run's env PATH,
        // `/usr/bin:/usr/local/bin`, has no `/bin`), so `git status`
        // itself blocks indefinitely -- exactly mirroring the `exec`'d
        // `sleep` technique SystemCommandRunnerCancellationTests uses at
        // the plain-subprocess level.
        let hookScript = repoDir.appendingPathComponent("fsmonitor-hook.sh")
        let hookScriptContents = """
        #!/bin/sh
        echo $PPID > '\(gitPidPath)'
        echo $$ > '\(hookPidPath)'
        exec /bin/sleep 30
        """
        try hookScriptContents.write(to: hookScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScript.path)

        XCTAssertEqual(
            try runGitSetupCommand(["config", "core.fsmonitor", hookScript.path], workDir: repoDir), 0,
            "Precondition: git config must succeed"
        )

        let task = Task {
            try await GitService.gitStatus(workDir: repoDir.path)
        }

        let gitPid = try await waitForPid(at: gitPidPath, timeout: 3.0)
        let hookPid = try await waitForPid(at: hookPidPath, timeout: 3.0)
        defer {
            _ = kill(gitPid, SIGKILL) // ensure CI cleanliness regardless of outcome
            _ = kill(hookPid, SIGKILL)
        }

        XCTAssertTrue(isAlive(gitPid), "Precondition: the spawned `git status` process must be alive before cancelling")

        task.cancel()

        // Bound comfortably short of both the hook's 30s sleep and
        // GitService.run's own 10s watchdog: a correct implementation
        // ends the `git status` subprocess promptly on cancellation.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !isAlive(gitPid) { break }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        XCTAssertFalse(
            isAlive(gitPid),
            """
            `git status` PID \(gitPid) survived Task cancellation for 5s. GitService.run(args:workDir:) must \
            propagate Swift Task cancellation to the underlying `git` process (SIGTERM) instead of ignoring it \
            until the unrelated 10s watchdog eventually trips.
            """
        )

        // Drain the now-cancelled Task so it doesn't outlive the test.
        _ = try? await task.value
    }
}
