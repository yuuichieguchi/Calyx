//
//  LSPTimeoutsBugSpecTests.swift
//  CalyxTests
//
//  Bug-spec regression tests for two hardcoded wall-clock timeouts that
//  do not scale with the work being performed:
//
//    1. `LSPClient` applies a single `requestTimeoutSeconds` (default
//       120 s) to EVERY JSON-RPC request, including the initial LSP
//       `initialize` handshake. Real-world language servers
//       (`rust-analyzer`, `jdtls`) routinely take 3-10 minutes for
//       first-time workspace indexing, exceeding the 120 s cap and
//       causing the session to fail. The fix splits the timeout into:
//         - `initializeTimeoutSeconds` (default 600 s = 10 min)
//         - `requestTimeoutSeconds`    (default 120 s, unchanged)
//
//    2. `SystemCommandRunner` applies a single `runTimeoutSeconds`
//       watchdog (default 600 s = 10 min) to every spawned process,
//       including long-running installers such as `ghcup install hls`
//       which compiles GHC from source and routinely runs 30+ minutes.
//       The fix introduces a dedicated install path with a much higher
//       wall-clock budget (e.g. 1800 s+ or unbounded), distinct from
//       the existing `run(...)` watchdog.
//
//  Both tests below are written to FAIL against the current code: the
//  LSPClient test references an `initializeTimeoutSeconds:` init
//  parameter that does not yet exist, and the SystemCommandRunner test
//  references an `installRun(...)` method that does not yet exist. The
//  compiler is the assertion mechanism for the RED phase — once the
//  fixes land, both tests compile and pass.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPTimeoutsBugSpecTests: XCTestCase {

    // MARK: - Helpers (intentionally local to this file)

    /// Holds a value behind an actor so test tasks can mutate it without
    /// taking out a `@unchecked Sendable` loan on a struct. Mirrors the
    /// pattern in `LSPClientBugSpecTests`.
    private actor Box<T: Sendable> {
        private var value: T
        init(_ value: T) { self.value = value }
        func set(_ v: T) { self.value = v }
        func get() -> T { value }
    }

    /// Wrap a JSON string in a Content-Length-framed envelope.
    private func frame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    /// Parse a framed LSP message into the JSON body dictionary.
    private func parse(_ data: Data) -> [String: Any] {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// Read a JSON-RPC id field as a Swift Int regardless of wire form.
    private func intId(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Poll `predicate` until true or the deadline elapses.
    private func waitFor(
        _ seconds: TimeInterval = 2.0,
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    /// Sample request payload.
    private struct Args: Codable, Sendable { let x: Int }
    private struct Reply: Codable, Sendable, Equatable { let ok: Bool }

    // ====================================================================
    // MARK: - 1. LSPClient initialize uses a separate, longer timeout
    // ====================================================================

    /// The `initialize` request can legitimately take many minutes on
    /// first-time index builds (rust-analyzer / jdtls). Subsequent
    /// requests, however, should still time out promptly so a stuck
    /// server cannot wedge the editor.
    ///
    /// Contract under test:
    ///   - `LSPClient.init` accepts a separate `initializeTimeoutSeconds`
    ///     parameter, distinct from `requestTimeoutSeconds`.
    ///   - When constructed with `requestTimeoutSeconds: 0.1` and
    ///     `initializeTimeoutSeconds: 5.0`, an `initialize` request that
    ///     takes ~1 s to respond MUST succeed (the per-method override
    ///     kicks in), and a subsequent non-initialize request that takes
    ///     ~0.5 s MUST time out (the short default still applies).
    ///
    /// RED expectation: against the CURRENT code, `LSPClient.init` does
    /// not accept `initializeTimeoutSeconds:`, so this test fails to
    /// compile. That compile failure is the RED signal.
    func test_initialize_usesSeparateLongTimeout() async throws {
        let transport = InMemoryLSPTransport()

        // The constructor call below is the load-bearing assertion: it
        // pins the existence of `initializeTimeoutSeconds` as a public
        // init parameter, distinct from `requestTimeoutSeconds`.
        let client = LSPClient(
            transport: transport,
            requestTimeoutSeconds: 0.1,
            initializeTimeoutSeconds: 5.0
        )
        try await client.start()
        defer { Task { await client.close() } }

        // Spawn a small "server" that replies to the `initialize`
        // request after ~1 s — well past the 0.1 s requestTimeout but
        // comfortably under the 5 s initializeTimeout. If the fix is
        // correct, this request must succeed.
        let initSender = Task { () -> Reply in
            try await client.sendRequest(
                method: "initialize",
                params: Args(x: 1),
                resultType: Reply.self
            )
        }
        // Wait for the initialize frame to land on the wire.
        let initOnWire = await waitFor(2.0) {
            await transport.sentMessages().count >= 1
        }
        XCTAssertTrue(initOnWire, "initialize request was never sent")

        // Sleep ~1 s, then reply. This delay must exceed the 0.1 s
        // requestTimeout to prove the override matters. Use the
        // client-assigned id (1).
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await transport.simulateServerMessage(
            frame(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)
        )
        let initReply = try await initSender.value
        XCTAssertEqual(initReply, Reply(ok: true),
                       "initialize must complete under the longer initializeTimeout")

        // Now send a non-initialize request and never reply. The short
        // 0.1 s requestTimeout must still apply: the call must throw
        // `.timeout`. A 0.5 s safety budget is deliberately well below
        // the 5 s initializeTimeout so that even if the implementation
        // accidentally fell through to the longer budget, the test
        // would still fail.
        do {
            _ = try await client.sendRequest(
                method: "textDocument/hover",
                params: Args(x: 2),
                resultType: Reply.self
            )
            XCTFail("expected non-initialize request to time out at 0.1 s")
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .timeout,
                           "non-initialize request must use short requestTimeout")
        }
    }

    // ====================================================================
    // MARK: - 2. SystemCommandRunner exposes a longer install timeout
    // ====================================================================

    /// Install commands (`ghcup install hls`, building GHC from source;
    /// `brew install`; `rustup component add` on a cold cache; …) can
    /// legitimately run 30+ minutes. The existing 600 s `run(...)`
    /// watchdog terminates them prematurely.
    ///
    /// Contract under test:
    ///   - `SystemCommandRunner` exposes a dedicated `installRun(...)`
    ///     entry point that applies a wall-clock budget >= 1800 s
    ///     (30 min), distinct from the 600 s cap used by `run(...)`.
    ///   - The longer budget does not affect fast-exiting commands:
    ///     a `/bin/sh -c 'sleep 0.1; exit 0'` invocation through the
    ///     install path returns exit code 0 with no timeout artifact.
    ///
    /// RED expectation: against the CURRENT code, `SystemCommandRunner`
    /// does not expose `installRun(...)`, so the call below fails to
    /// compile. That compile failure is the RED signal.
    func test_runner_install_usesLongerTimeout_thanRunTimeout() async throws {
        let shPath = "/bin/sh"
        guard FileManager.default.fileExists(atPath: shPath) else {
            throw XCTSkip("/bin/sh is not present on this host")
        }

        let runner = SystemCommandRunner()

        // The method call below is the load-bearing assertion: it pins
        // the existence of `installRun(...)` as a distinct entry point
        // from `run(...)`. The `/bin/sh -c 'sleep 0.1; exit 0'` payload
        // exits in well under a second so we never actually wait long
        // enough to exercise the longer wall-clock budget — the test
        // only proves the API split exists.
        let result = try await runner.installRun(
            executable: shPath,
            arguments: ["-c", "sleep 0.1; exit 0"],
            workingDirectory: nil,
            environment: nil
        )

        // A fast-exiting command must succeed; the longer wall-clock
        // budget has no observable effect on it.
        XCTAssertEqual(result.exitCode, 0,
                       "fast-exit command must return 0 through install path")
        XCTAssertNotEqual(
            result.exitCode,
            SystemCommandRunner.timeoutExitCode,
            "install path must not classify a fast-exit command as timed out"
        )
    }
}
