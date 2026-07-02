//
//  CalyxMCPServerLoopbackBugSpecTests.swift
//  CalyxTests
//
//  Regression tests for two related defects in the IPC MCP server
//  surface area:
//
//    1. Dual-stack loopback mismatch. `CalyxMCPServer` binds its
//       `NWListener` to `.ipv4(.loopback)` only (i.e. 127.0.0.1), but
//       `ClaudeConfigManager` publishes
//       `"url": "http://localhost:<port>/mcp"`. On macOS, getaddrinfo
//       resolves `localhost` to `::1` first; Claude Code attempts the
//       v6 connect first and gets ECONNREFUSED because nothing is
//       bound on `::1:<port>`. Spec: the published URL must encode
//       `127.0.0.1` literally so the address family matches the bind.
//
//    2. Hardcoded 10-port linear scan with no fallback. `start()`
//       iterates `preferredPort..<preferredPort+10` and throws if all
//       ten are in use. Spec: after the canonical scan exhausts, the
//       listener should fall back to a kernel-assigned port via
//       `NWEndpoint.Port(integerLiteral: 0)` (i.e. `.any`) and publish
//       whichever port the kernel actually returned, so a busy host
//       does not silently break IPC.
//
//  Both tests live under `CalyxTests/IPC/` to sit next to the existing
//  `CalyxMCPServerWiringBugSpecTests` — the established home for
//  audit-driven IPC regressions.
//

import XCTest
import Network
@testable import Calyx

@MainActor
final class CalyxMCPServerLoopbackBugSpecTests: XCTestCase {

    // MARK: - Properties

    /// Each test uses its own server instance to avoid perturbing
    /// `CalyxMCPServer.shared` (which `CalyxWindowController` and other
    /// suites observe).
    private var server: CalyxMCPServer!

    /// Test-isolated config path passed to `ClaudeConfigManager`. The
    /// production code defaults to `~/.claude.json`; we redirect into a
    /// per-test tempdir so we never touch the user's real config.
    private var tempDir: String!
    private var configPath: String!

    /// Pre-bound listeners used by
    /// `test_listener_fallsBackToKernelAssignedPort_whenAllPreferredPortsTaken`
    /// to exhaust the 41830-41839 canonical scan range. Held at instance
    /// scope so `tearDown` can cancel them even if the test fails mid-way.
    private var preBoundListeners: [NWListener] = []

    /// Port range used by the production code's hardcoded scan. Mirrored
    /// here so the test fails loudly if production changes the base
    /// (the test would no longer be exhausting the real scan window).
    private let canonicalScanBase: Int = 41830
    private let canonicalScanCount: Int = 10

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        server = CalyxMCPServer()

        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(
            atPath: tempDir,
            withIntermediateDirectories: true
        )
        configPath = tempDir + "/claude.json"
        // Redirect agent-endpoint.json into the same per-test tempdir so
        // start()/stop() never touch the real
        // ~/Library/Application Support/Calyx/agent-endpoint.json.
        server.agentEndpointDirectory = tempDir
        // stop() now also resets agentRegistry; agentRegistry defaults to
        // the true AgentRegistry.shared singleton, so this suite's
        // start()/stop() calls would otherwise reset shared app-wide
        // state on every test.
        server.agentRegistry = AgentRegistry()
    }

    override func tearDown() {
        // Cancel any test-owned pre-bound listeners first so the
        // ports they hold are released before the next test runs.
        for nl in preBoundListeners {
            nl.cancel()
        }
        preBoundListeners.removeAll()

        // Drain the server. `stop()` schedules an async teardown Task;
        // we await it on a best-effort basis so the next test does not
        // inherit a half-shut-down LSP bridge.
        let teardown = server.stop()
        let drainTask = Task { @MainActor in
            await teardown.value
        }
        _ = drainTask
        server = nil

        if let tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        tempDir = nil
        configPath = nil

        super.tearDown()
    }

    // MARK: - Helpers

    /// Read the JSON written by `ClaudeConfigManager.enableIPC` into the
    /// test-isolated `configPath` and pull out
    /// `mcpServers.calyx-ipc.url`.
    private func readPublishedURL() throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let obj = try JSONSerialization.jsonObject(with: data)
        let dict = try XCTUnwrap(
            obj as? [String: Any],
            "claude.json root must decode as a JSON object"
        )
        let mcpServers = try XCTUnwrap(
            dict["mcpServers"] as? [String: Any],
            "published config must contain an `mcpServers` map"
        )
        let calyxEntry = try XCTUnwrap(
            mcpServers["calyx-ipc"] as? [String: Any],
            "published config must contain a `calyx-ipc` entry"
        )
        return try XCTUnwrap(
            calyxEntry["url"] as? String,
            "calyx-ipc entry must contain a `url` field"
        )
    }

    /// Attempt to bind an `NWListener` on `127.0.0.1:<port>`. Returns
    /// the listener on success, `nil` on failure (e.g. port already
    /// in use by another process). Used to exhaust the canonical scan
    /// window before `start()` runs.
    private func bindLoopbackListener(port: Int) -> NWListener? {
        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return nil
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: nwPort
        )
        do {
            let nl = try NWListener(using: params)
            nl.newConnectionHandler = { conn in
                // Accept and immediately drop — we only care about the
                // bind. Without an explicit handler the listener
                // refuses to start.
                conn.cancel()
            }
            nl.start(queue: .main)
            return nl
        } catch {
            return nil
        }
    }

    /// Poll until `predicate` returns true or `timeout` expires. Matches
    /// the helper shape in `CalyxMCPServerWiringBugSpecTests`.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.01,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(
                nanoseconds: UInt64(pollInterval * 1_000_000_000)
            )
        }
        return predicate()
    }

    // MARK: - Bug 1: published URL must use 127.0.0.1 literal

    /// The MCP listener binds to `.ipv4(.loopback)` only. Publishing
    /// `localhost` instead of `127.0.0.1` lets the client resolve to
    /// `::1` first on dual-stack macOS, which is not bound. The
    /// published URL must therefore encode the IPv4 literal that
    /// matches the bind.
    ///
    /// Verified by writing the config to a test-isolated path (so the
    /// user's real `~/.claude.json` is untouched), reading the JSON
    /// back, and asserting the `url` field is
    /// `http://127.0.0.1:<port>/mcp` and does NOT contain `localhost`.
    ///
    /// Pre-fix: production writes `http://localhost:<port>/mcp` → RED.
    /// Post-fix: production writes `http://127.0.0.1:<port>/mcp` → GREEN.
    func test_publishedURL_usesIPv4LoopbackLiteral_not_localhost() throws {
        // Arrange — pick a port outside the canonical scan window so
        // this test is independent of the second test's pre-bind.
        let port = 51840
        let token = "loopback-test-token"

        // Act — drive the production code path that writes the URL
        // into `~/.claude.json`. We pass the test-isolated path so no
        // shared state is touched.
        try ClaudeConfigManager.enableIPC(
            port: port,
            token: token,
            configPath: configPath
        )

        // Assert — published URL must encode the IPv4 loopback
        // literal that matches the `NWListener` bind in
        // `CalyxMCPServer.start`.
        let publishedURL = try readPublishedURL()

        XCTAssertFalse(
            publishedURL.contains("localhost"),
            """
            Published URL contains `localhost` but the `NWListener` is \
            bound to `.ipv4(.loopback)` (127.0.0.1) only. On macOS \
            getaddrinfo resolves `localhost` to `::1` first, so Claude \
            attempts the v6 connect and gets ECONNREFUSED. Publish the \
            IPv4 literal instead. Actual URL: \(publishedURL)
            """
        )

        let expectedURL = "http://127.0.0.1:\(port)/mcp"
        XCTAssertEqual(
            publishedURL,
            expectedURL,
            """
            Published URL must be exactly \(expectedURL) so the address \
            family encoded in the URL matches the address family the \
            server is actually bound on. Actual: \(publishedURL)
            """
        )

        // Defence-in-depth: also assert the regex shape spelled out in
        // the bug report, in case a future refactor varies the
        // surrounding URL components.
        let pattern = #"^http://127\.0\.0\.1:\d+/mcp$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(publishedURL.startIndex..., in: publishedURL)
        XCTAssertNotNil(
            regex.firstMatch(in: publishedURL, range: range),
            """
            Published URL must match \(pattern). Actual: \(publishedURL)
            """
        )
    }

    // MARK: - Bug 2: kernel-assigned port fallback when scan exhausts

    /// The production `start()` iterates `preferredPort..<preferredPort+10`
    /// and throws if all ten ports are bound. On a busy host this hard
    /// caps the server at 10 simultaneous Calyx instances and leaves no
    /// graceful path back. The spec'd fix is: after the canonical scan
    /// exhausts, ask the kernel for an ephemeral port via
    /// `NWEndpoint.Port(integerLiteral: 0)` (`.any`) and publish
    /// whichever port the kernel actually returned so the URL stays
    /// consistent with the bind.
    ///
    /// Scenario:
    ///   1. The test binds all ports in the canonical scan range
    ///      (`41830-41839`) on `127.0.0.1` itself. These holds force
    ///      `CalyxMCPServer.start`'s linear scan to fail on every
    ///      iteration.
    ///   2. The test calls `server.start(token:, preferredPort:)` with
    ///      the canonical base. Pre-fix, this throws — the assertion
    ///      `start did not throw` is the RED signal.
    ///   3. Post-fix, `start` falls back to `.any`, the kernel returns
    ///      an ephemeral port (typically far above 41839), and that
    ///      port is recorded in `server.port`.
    ///
    /// Assertion: `start` succeeds AND `server.port` is non-zero AND
    /// not in `41830...41839`.
    func test_listener_fallsBackToKernelAssignedPort_whenAllPreferredPortsTaken() async throws {
        // Arrange — bind every port in the canonical scan range so the
        // production linear scan has no valid slot. We require all ten
        // to bind successfully; otherwise the test would not actually
        // be exhausting the production scan window and a green result
        // would be meaningless.
        for offset in 0..<canonicalScanCount {
            let port = canonicalScanBase + offset
            let nl = try XCTUnwrap(
                bindLoopbackListener(port: port),
                """
                Test setup precondition failed: could not bind \
                127.0.0.1:\(port). Another process is holding it, so \
                this test cannot exhaust the canonical scan range \
                deterministically. Pick a quieter host or kill the \
                squatter.
                """
            )
            preBoundListeners.append(nl)
        }

        // NWListener.start is asynchronous; give the kernel a tick to
        // actually accept the bind so the production scan sees the
        // ports as taken rather than racing them.
        let allReady = await waitUntil(timeout: 2.0) {
            self.preBoundListeners.allSatisfy { $0.state == .ready }
        }
        XCTAssertTrue(
            allReady,
            "Pre-bound listeners failed to reach .ready within 2s — test cannot reliably exhaust the canonical scan."
        )

        // Act — drive `start()` with the canonical base. Pre-fix this
        // throws after the linear scan exhausts; post-fix it falls
        // back to a kernel-assigned port.
        let token = "fallback-test-token"
        XCTAssertNoThrow(
            try server.start(
                token: token,
                preferredPort: canonicalScanBase
            ),
            """
            start() must fall back to a kernel-assigned ephemeral port \
            (`NWEndpoint.Port(integerLiteral: 0)` / `.any`) when the \
            canonical 10-port scan exhausts. Pre-fix the linear scan \
            simply throws, hard-capping the server at 10 simultaneous \
            instances and leaving no graceful recovery for a busy host.
            """
        )

        // Assert — after a successful start the server must report a
        // running state, a non-zero port, and that port must lie
        // outside the canonical scan range (because the test is still
        // holding every port in that range).
        XCTAssertTrue(
            server.isRunning,
            "start() returned without throwing but `isRunning` is still false"
        )

        let boundPort = server.port
        XCTAssertNotEqual(
            boundPort, 0,
            "After a successful fallback start(), `server.port` must be the kernel-assigned port, not 0."
        )

        let canonicalScanRange = canonicalScanBase ..< (canonicalScanBase + canonicalScanCount)
        XCTAssertFalse(
            canonicalScanRange.contains(boundPort),
            """
            Bound port \(boundPort) is inside the canonical scan range \
            \(canonicalScanRange.lowerBound)-\(canonicalScanRange.upperBound - 1), \
            but the test is still holding every port in that range. \
            Either the pre-binds dropped (false-green: scan succeeded \
            on a port the test thought it owned) or the production \
            fix is not actually using the kernel-assigned ephemeral \
            slot.
            """
        )
    }
}
