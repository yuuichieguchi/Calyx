//
//  CalyxMCPServerWiringBugSpecTests.swift
//  CalyxTests
//
//  Race-safety regression tests for the `CalyxMCPServer` start/stop
//  wiring. The bug under test is a double-start that lets the previous
//  `lspStartTask` race the freshly-installed one to commit
//  `self.lspBridge`. Before the fix the loser leaked a fully-built
//  `LSPService` — child language-server processes and `FSEvents`
//  watches kept running with no live reference able to reach
//  `shutdownAll()`.
//
//  Audit narrative (verbatim):
//    - `start()` checks `if isRunning { stop() }`, where `stop()`
//      schedules an unstructured `Task { await
//      preStartupBridge?.service.shutdownAll() ... }` and returns
//      synchronously.
//    - `start()` then immediately enqueues a new `lspStartTask` on the
//      same actor while the previous teardown Task is still running
//      asynchronously.
//    - The two `lspStartTask`s can be live simultaneously — the
//      cancelled-but-still-executing prior one races the new one to
//      install bridges into `self.lspBridge`. The loser leaks a
//      fully-built LSPService plus running child processes.
//
//  Fix shape:
//    - `stop()` now returns the teardown Task; `stopAndWait()` is the
//      async wrapper.
//    - `start()` captures the returned teardown Task and the new
//      `lspStartTask` body chains itself off `await
//      priorTeardown.value` before calling `startLSP()`. The new LSP
//      startup body therefore only executes after the prior teardown
//      has finished its `shutdownAll` and identity check.
//
//  Verification:
//    - `inflightTeardownCount` exposes how many `stop()` teardown Tasks
//      are still in flight.
//    - `inflightTeardownCountAtLastStartLSPEntry` records the value at
//      the moment `startLSP()` last began. With the chain in place
//      this is `0`; without the chain, it is non-zero whenever the
//      teardown is mid-`shutdownAll` while `@MainActor` schedules the
//      racing new `lspStartTask`.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerWiringBugSpecTests: XCTestCase {

    // MARK: - Properties

    /// Each test uses a dedicated instance instead of `.shared` so the
    /// global server state observed elsewhere in the suite (and by
    /// production code in `CalyxWindowController`) is not perturbed.
    private var server: CalyxMCPServer!

    /// Loopback ports are claimed exclusively by `NWListener.start`, so
    /// rapidly cycling start/stop on the same port can lose to
    /// lingering teardown of the previous listener. Use a high port that
    /// the rest of the suite does not touch.
    private let basePort = 51830

    /// Test-isolated `agent-endpoint.json` directory, so `start()` /
    /// `stop()` in this suite never touch the real
    /// `~/Library/Application Support/Calyx/agent-endpoint.json`.
    private var agentEndpointDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        // stop() now also resets agentRegistry; agentRegistry defaults to
        // the true AgentRegistry.shared singleton, so this suite's
        // start()/stop() calls would otherwise reset shared app-wide
        // state on every test.
        server.agentRegistry = AgentRegistry()
    }

    override func tearDown() {
        // Sync `stop()` schedules an async teardown; we additionally
        // poll until it drains so the next test starts from a clean
        // slate.
        let teardown = server.stop()
        let drainTeardownTask = Task { @MainActor in
            await teardown.value
        }
        // Best-effort drain — the suite-wide invariant is that the
        // teardown completes; this just avoids leaving the Task
        // dangling across tests.
        _ = drainTeardownTask
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Poll `predicate` on `@MainActor` until it returns true or the
    /// timeout expires. Matches the pattern used in
    /// `CalyxMCPServerLSPIntegrationTests.waitUntil`.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5.0,
        pollInterval: TimeInterval = 0.01,
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return predicate()
    }

    // MARK: - Regression Tests

    /// Race-safety regression: a `start()` → `start()` toggle must
    /// fully serialise the new `startLSP()` body behind the prior
    /// bridge teardown.
    ///
    /// Scenario:
    ///   1. `start(A)` schedules `startup_A`; we await it so `bridge_A`
    ///      is committed to `self.lspBridge` before we proceed.
    ///   2. `start(B)` runs. Internally it calls `stop()` which
    ///      schedules `teardown_1` (capturing `preStartupBridge =
    ///      bridge_A`) and returns synchronously. `start(B)` then
    ///      installs `startup_B` in `self.lspStartTask`.
    ///   3. We await `startup_B`. Inside its body `teardown_1` is
    ///      mid-flight on `@MainActor`, suspended in
    ///      `await bridge_A.service.shutdownAll()`. Without the fix
    ///      `startup_B` is free to run during that suspension and
    ///      records a non-zero `inflightTeardownCount` at startLSP
    ///      entry. With the fix `startup_B` first
    ///      `await priorTeardown.value`s, so it only enters `startLSP`
    ///      after `teardown_1` has fully drained.
    ///
    /// Assertion: `inflightTeardownCountAtLastStartLSPEntry == 0`. Pre
    /// fix this is `1` (RED); post fix it is `0` (GREEN). The check
    /// is the deterministic test-only signal for the
    /// race-to-install-bridge leak described in the audit.
    func test_doubleStart_newStartLSPRunsAfterPriorTeardownDrains() async throws {
        // ---- Phase 1: start(A) and let it commit bridge_A. ----
        try server.start(token: "alpha-token", preferredPort: basePort)
        XCTAssertTrue(server.isRunning,
                      "precondition: first start() must mark the server running")

        // Drain startup_A so bridge_A is installed before we re-enter
        // start(). With bridge_A present at stop() time,
        // `preStartupBridge` is non-nil and `teardown_1`'s
        // `shutdownAll` is a real suspension point — exactly the
        // window the bug used to slip through.
        if let startupA = server._testCurrentLSPStartTask() {
            await startupA.value
        }
        XCTAssertNotNil(
            server.lspBridge,
            "precondition: startup_A must have committed bridge_A before start(B) runs"
        )
        XCTAssertEqual(
            server.inflightTeardownCount, 0,
            "precondition: no teardown should be in flight before the second start()"
        )
        // Reset the probe so a stale value from startup_A cannot mask
        // a leak in startup_B.
        XCTAssertEqual(
            server.inflightTeardownCountAtLastStartLSPEntry, 0,
            "precondition: first startLSP() runs with no teardown in flight"
        )

        // ---- Phase 2: start(B). Sync clear nils lspBridge and
        //               lspStartTask; the returned teardown_1
        //               captures preStartupBridge = bridge_A and
        //               will suspend in shutdownAll(). ----
        try server.start(token: "beta-token", preferredPort: basePort)
        XCTAssertTrue(server.isRunning,
                      "second start() must keep the server running")
        XCTAssertEqual(
            server.inflightTeardownCount, 1,
            "stop() inside start(B) must have scheduled teardown_1 — it should still be in flight at this synchronous boundary"
        )

        // Capture startup_B so we can await its full body. With the
        // chain fix `startup_B` first awaits priorTeardown.value, so
        // awaiting startup_B implicitly awaits teardown_1; pre-fix
        // startup_B does not wait at all and can complete before
        // teardown_1.
        let startupB = try XCTUnwrap(
            server._testCurrentLSPStartTask(),
            "start(B) must install a new lspStartTask"
        )
        await startupB.value

        // ---- Phase 3: drain teardown_1 if it is still in flight.
        //               With the fix this is already done (startup_B
        //               awaited it); pre-fix startup_B may have
        //               finished while teardown_1 was still
        //               shutdownAll'ing bridge_A. Poll briefly so
        //               this race window is observable either way
        //               — the test assertion is on the probe
        //               captured *during* startup_B, not on the
        //               post-drain state. ----
        let drained = await waitUntil(timeout: 5.0) {
            self.server.inflightTeardownCount == 0
        }
        XCTAssertTrue(
            drained,
            "teardown_1 must eventually finish; otherwise stop()'s async portion is leaking"
        )

        // ---- Phase 4: the deterministic regression assertion. ----
        XCTAssertEqual(
            server.inflightTeardownCountAtLastStartLSPEntry, 0,
            """
            startLSP() of the second start() must run only after the prior \
            teardown has fully drained. A non-zero value means the new \
            lspStartTask raced the cancelled-but-still-executing prior \
            teardown on @MainActor — both could then commit bridges to \
            self.lspBridge and the loser leaks a fully-built LSPService \
            plus its child language-server processes and FSEvents watches.
            """
        )

        // Sanity invariants on the final state. Independent of the
        // race fix, but useful to keep this regression honest.
        XCTAssertNotNil(
            server.lspBridge,
            "after both starts and the teardown drain, exactly one bridge must remain"
        )
        XCTAssertEqual(
            server.inflightTeardownCount, 0,
            "no teardown Task should still be in flight after the test settles"
        )
    }
}
