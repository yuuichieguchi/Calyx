//
//  StdioLSPTransportLifecycleTests.swift
//  CalyxTests
//
//  Additive lifecycle API on StdioLSPTransport needed to reuse it as
//  MCPHost's stdio byte layer: spawn() throws, waitForExit() async ->
//  MCPTransportExitInfo, and closeGracefully(stdinGrace:termGrace:)
//  (close stdin, wait, SIGTERM, wait, SIGKILL). The existing close()
//  behavior (immediate SIGTERM + 2s SIGKILL escalation) is unchanged and
//  is not retested here; see LSPClientBugSpecTests / LSPClientTests for
//  that coverage.
//

import XCTest
@testable import Calyx

final class StdioLSPTransportLifecycleTests: XCTestCase {

    // MARK: - spawn()

    func test_spawn_startsChildProcessExplicitly() async throws {
        // Before this addition, the process only spawned lazily on first
        // send. spawn() must start it eagerly and be idempotent.
        let transport = StdioLSPTransport(executable: "/bin/cat")
        try await transport.spawn()
        // A second call must not throw or double-spawn.
        try await transport.spawn()
        await transport.close()
    }

    // MARK: - waitForExit()

    func test_waitForExit_reportsCleanExitStatusForCatOnStdinEOF() async throws {
        let transport = StdioLSPTransport(executable: "/bin/cat")
        try await transport.spawn()
        try await transport.send(Data("hello\n".utf8))
        // cat mirrors input to output and exits 0 on stdin EOF.
        // closeGracefully's first phase closes stdin; a generous termGrace
        // here just bounds the test, it should not be needed.
        await transport.closeGracefully(stdinGrace: 1.0, termGrace: 1.0)
        let exit = await transport.waitForExit()
        XCTAssertEqual(exit, .exited(0))
    }

    func test_waitForExit_reportsSignalForKilledChild() async throws {
        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; echo ready; while :; do sleep 1; done"]
        )
        try await transport.spawn()
        // The child prints "ready" only after installing the trap, so the
        // SIGTERM sent by close() cannot arrive before the trap is in place.
        var received = Data()
        for await chunk in transport.incoming {
            received.append(chunk)
            if String(decoding: received, as: UTF8.self).contains("ready\n") { break }
        }
        await transport.close() // escalates SIGTERM -> (ignored) -> SIGKILL after ~2s
        let exit = await transport.waitForExit()
        XCTAssertEqual(exit, .signaled(SIGKILL))
    }

    // MARK: - closeGracefully(stdinGrace:termGrace:)

    func test_closeGracefully_catExitsOnStdinCloseWithoutNeedingTerm() async throws {
        let transport = StdioLSPTransport(executable: "/bin/cat")
        try await transport.spawn()
        let start = Date()
        await transport.closeGracefully(stdinGrace: 1.0, termGrace: 1.0)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "cat exits promptly on stdin EOF; closeGracefully must not wait out the full term grace period")
        let exit = await transport.waitForExit()
        XCTAssertEqual(exit, .exited(0))
    }

    func test_closeGracefully_stdinIgnoringChild_escalatesToSIGTERM() async throws {
        // A child that ignores stdin EOF (keeps running with an open
        // stdin pipe) but honors SIGTERM must be reported as .signaled
        // with SIGTERM specifically, distinguishing "the term phase ran"
        // from "closeGracefully skipped straight to SIGKILL".
        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            arguments: ["-c", "while :; do sleep 1; done"]
        )
        try await transport.spawn()
        await transport.closeGracefully(stdinGrace: 0.2, termGrace: 1.0)
        let exit = await transport.waitForExit()
        XCTAssertEqual(exit, .signaled(SIGTERM))
    }

    func test_closeGracefully_termIgnoringChild_escalatesToSIGKILL() async throws {
        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"]
        )
        try await transport.spawn()
        await transport.closeGracefully(stdinGrace: 0.2, termGrace: 0.2)
        let exit = await transport.waitForExit()
        XCTAssertEqual(exit, .signaled(SIGKILL))
    }

    func test_closeGracefully_isIdempotent() async throws {
        let transport = StdioLSPTransport(executable: "/bin/cat")
        try await transport.spawn()
        await transport.closeGracefully(stdinGrace: 0.5, termGrace: 0.5)
        // Must not hang, throw (there is nothing to throw here), or crash.
        await transport.closeGracefully(stdinGrace: 0.5, termGrace: 0.5)
    }

    // MARK: - recentStderr()

    func test_recentStderr_capturesChildStderrOutput() async throws {
        let transport = StdioLSPTransport(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'boom: config not found' 1>&2; sleep 5"]
        )
        try await transport.spawn()
        let expected = Data("boom: config not found\n".utf8)
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if await transport.recentStderr().count >= expected.count { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let tail = await transport.recentStderr()
        let tailString = String(data: tail, encoding: .utf8) ?? ""
        XCTAssertTrue(tailString.contains("boom: config not found"), "expected the child's stderr to be captured, got \(tailString)")
        await transport.close()
    }

    func test_recentStderr_emptyWhenChildWritesNothing() async throws {
        let transport = StdioLSPTransport(executable: "/bin/cat")
        try await transport.spawn()
        await transport.closeGracefully(stdinGrace: 0.5, termGrace: 0.5)
        let tail = await transport.recentStderr()
        XCTAssertEqual(tail, Data())
    }
}
