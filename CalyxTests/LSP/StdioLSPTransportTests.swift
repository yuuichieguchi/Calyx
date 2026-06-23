//
//  StdioLSPTransportTests.swift
//  Calyx
//
//  RED-phase regression tests targeting four known defects in
//  `StdioLSPTransport`:
//
//    1. No `deinit` ever terminates the spawned child. Dropping the
//       transport without calling `close()` orphans the LSP server
//       process (rust-analyzer / sourcekit-lsp leak GB of RSS).
//    2. `close()` is fire-and-forget. It sends SIGTERM via
//       `Process.terminate()` but never escalates to SIGKILL, so a
//       server that traps/ignores SIGTERM survives close.
//    3. `writeSync` uses synchronous `FileHandle.write(contentsOf:)`
//       on the actor's executor. A slow-draining stdin pipe wedges
//       the entire actor; no further `send`/`close` can make progress.
//    4. The stderr drain handler appends bytes to the host process's
//       stderr without any bounded ring buffer. There is also no
//       accessor exposing the recent tail to the rest of the app.
//
//  These tests are inherently integration tests because the bugs are
//  about real process / pipe behavior. They spawn `/bin/sh` children
//  and use POSIX `kill(pid, 0)` probes to detect liveness.
//
//  IMPORTANT: every test SIGKILLs any pid it captured in a `defer`
//  block to prevent CI leakage.
//

import XCTest
import Darwin
@testable import Calyx

@MainActor
final class StdioLSPTransportTests: XCTestCase {

    // MARK: - Setup

    override class func setUp() {
        super.setUp()
        // Foundation usually sets SO_NOSIGPIPE on its pipe FDs, but the
        // host process can still receive SIGPIPE during a write race with
        // a SIGKILL'd child. Ignore it so the test runner doesn't crash.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Helpers

    /// POSIX-friendly liveness probe. `kill(pid, 0)` does no signal
    /// delivery but returns 0 if the pid exists and the caller has
    /// permission, or -1 with `errno == ESRCH` if the process is gone.
    private func isAlive(_ pid: pid_t) -> Bool {
        return kill(pid, 0) == 0
    }

    /// Unique scratch path for the shell's `echo $$ > path` pid-emission.
    private func uniquePidPath() -> String {
        return NSTemporaryDirectory()
            + "StdioLSPTransportTests_\(UUID().uuidString).pid"
    }

    /// Poll `pidPath` until the shell writes its pid, or `timeout`
    /// elapses. Returns the parsed pid.
    private func waitForPid(
        at pidPath: String,
        timeout: TimeInterval
    ) async throws -> pid_t {
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
            var description: String {
                "timed out waiting for pid file at \(path)"
            }
        }
        throw PidFileTimeout(path: pidPath)
    }

    /// Spawn a transport against a long-running `/bin/sh` child that
    /// emits its pid to `pidPath`, wait for the pid, then return it.
    /// The local `transport` variable goes out of scope on return so
    /// ARC releases the actor. After the fix, a proper `deinit` will
    /// terminate the child before the function returns; today, with no
    /// deinit, the OS process is orphaned.
    private func spawnAndReleaseTransport(pidPath: String) async throws -> pid_t {
        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            arguments: ["-c", "echo $$ > '\(pidPath)'; sleep 30"]
        )
        // First send triggers `ensureSpawned()`; payload is tiny so it
        // fits in the pipe buffer even though the shell never reads
        // stdin.
        try await transport.send(Data("ping\n".utf8))
        let pid = try await waitForPid(at: pidPath, timeout: 2.0)
        return pid
        // `transport` released here -> actor refcount hits 0.
    }

    // MARK: - Bug 1: dropped transport orphans the child

    /// Asserts that dropping a `StdioLSPTransport` without calling
    /// `close()` still terminates the spawned child process.
    ///
    /// Today this FAILS: there is no `deinit` on the actor, so the
    /// Foundation `Process` object is deallocated but the underlying
    /// OS child keeps running.
    func test_droppedTransport_killsSpawnedChild() async throws {
        let pidPath = uniquePidPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }

        let pid = try await spawnAndReleaseTransport(pidPath: pidPath)
        defer { _ = kill(pid, SIGKILL) } // ensure CI cleanliness

        // Allow generous time for any deferred ARC / Foundation cleanup
        // that a future `deinit` would orchestrate.
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        XCTAssertFalse(
            isAlive(pid),
            """
            Child PID \(pid) was orphaned. Dropping StdioLSPTransport \
            without close() must terminate the spawned LSP child (deinit \
            should call terminate()+SIGKILL fallback).
            """
        )
    }

    // MARK: - Bug 2: close() does not escalate SIGTERM -> SIGKILL

    /// Asserts that `close()` reliably kills the child even when the
    /// child ignores SIGTERM. Today this FAILS because `close()` only
    /// calls `Process.terminate()` (which delivers SIGTERM) and never
    /// escalates to SIGKILL.
    func test_close_escalatesToSIGKILL_whenChildIgnoresSIGTERM() async throws {
        let pidPath = uniquePidPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }

        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            // `trap '' TERM` installs an empty handler -> SIGTERM is
            // explicitly ignored. Only SIGKILL can take the child down.
            arguments: [
                "-c",
                "echo $$ > '\(pidPath)'; trap '' TERM; sleep 30",
            ]
        )
        try await transport.send(Data("ping\n".utf8))
        let pid = try await waitForPid(at: pidPath, timeout: 2.0)
        defer { _ = kill(pid, SIGKILL) }

        await transport.close()

        // Poll up to 5s for the child to die. A correct implementation
        // would call terminate(), wait briefly, then send SIGKILL.
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if !isAlive(pid) { break }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        XCTAssertFalse(
            isAlive(pid),
            """
            Child PID \(pid) survived close(): SIGTERM was ignored by the \
            child and no SIGKILL escalation occurred within 5s.
            """
        )
    }

    // MARK: - Bug 3: synchronous write wedges the actor

    /// Asserts that `send` does not block the actor indefinitely when
    /// the child stops draining stdin. Today this FAILS because
    /// `FileHandle.write(contentsOf:)` is fully synchronous on the
    /// actor's executor; once the pipe buffer (~64KB on macOS) fills,
    /// `send` blocks forever and the actor is wedged.
    func test_send_doesNotBlockActor_whenStdinPipeIsFull() async throws {
        let pidPath = uniquePidPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }

        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            // Child never reads stdin. Anything beyond the pipe buffer
            // size blocks the producer indefinitely.
            arguments: ["-c", "echo $$ > '\(pidPath)'; sleep 30"]
        )

        // Small initial send: triggers spawn and lands in the pipe
        // buffer trivially.
        try await transport.send(Data("ping\n".utf8))
        let pid = try await waitForPid(at: pidPath, timeout: 2.0)
        defer { _ = kill(pid, SIGKILL) } // unblocks the wedged write

        // 256KB -- well above macOS's default pipe buffer (~64KB).
        let bigPayload = Data(repeating: 0x41, count: 256 * 1024)

        let completed = expectation(description: "send completes within budget")
        completed.assertForOverFulfill = false

        // Detached so the actor wedge does not stall the test task itself.
        Task.detached {
            _ = try? await transport.send(bigPayload)
            completed.fulfill()
        }

        // Budget: 5s. A correct, non-blocking implementation should
        // either succeed within ms or throw quickly. Today's synchronous
        // write hangs the actor for the entire `sleep 30`, blowing
        // through the 5s budget.
        await fulfillment(of: [completed], timeout: 5.0)
    }

    // MARK: - Bug 4: unbounded stderr drain, no accessor

    /// Asserts that recent stderr is captured into a bounded buffer
    /// exposed via `recentStderr()`. Today this FAILS to COMPILE
    /// because the accessor does not exist on `StdioLSPTransport`;
    /// stderr is simply forwarded to the host's stderr without any
    /// bound.
    func test_recentStderr_returnsBoundedTail_whenChildFloodsStderr() async throws {
        let pidPath = uniquePidPath()
        defer { try? FileManager.default.removeItem(atPath: pidPath) }

        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            // Emit ~1MB of stderr, then keep the child alive so the
            // transport's drain handler has time to ingest it.
            arguments: [
                "-c",
                "echo $$ > '\(pidPath)'; yes ERROR | head -c 1048576 1>&2; sleep 30",
            ]
        )
        try await transport.send(Data("ping\n".utf8))
        let pid = try await waitForPid(at: pidPath, timeout: 2.0)
        defer { _ = kill(pid, SIGKILL) }
        defer { Task.detached { await transport.close() } }

        // Allow the stderr drain handler to read the 1MB burst.
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1s

        // RED-PHASE SIGNAL: `recentStderr()` does NOT exist on
        // StdioLSPTransport yet. This call will not compile until the
        // swift-specialist adds a bounded ring-buffer accessor.
        let tail = await transport.recentStderr()

        XCTAssertLessThanOrEqual(
            tail.count,
            64 * 1024,
            "recentStderr() must return a bounded tail (<= 64KB) to prevent unbounded stderr retention."
        )
        XCTAssertFalse(
            tail.isEmpty,
            "recentStderr() should contain the most recent stderr bytes from the child."
        )
    }
}
