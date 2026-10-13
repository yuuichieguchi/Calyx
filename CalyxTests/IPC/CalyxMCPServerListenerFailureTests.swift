//
//  CalyxMCPServerListenerFailureTests.swift
//  CalyxTests
//
//  Spec Feature C, J3 / C.1 item 4: when the NWListener fails or is
//  cancelled after `.ready` (and it is still the server's listener while
//  the server is running), the server performs the same teardown as
//  `stop()`: agent-endpoint.json removed, `isRunning == false`, every
//  waiting `/ipc-wake` long-poll released with 204, every pending
//  approval long-poll expired. Driven through the planned DEBUG seam
//  `_testSimulateListenerFailure()`.
//
//  The expected long-poll results are exactly what `stop()` produces
//  today (CalyxMCPServerIPCWakeTests.test_serverStop_makesAWaitingPollReturn204,
//  CalyxMCPServerApprovalRequestTests.test_serverStop_expiresPendingHookApproval_returnsFailSafeBody):
//  wake -> 204 with no body; approval (claude-code, no nonce) -> 200 with
//  an empty body.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerListenerFailureTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var agentEndpointDir: String!
    private let testToken = "listener-failure-test-token"
    private let wakeSuite = "com.calyx.tests.CalyxMCPServerListenerFailureTests.wake"
    private let cockpitSuite = "com.calyx.tests.CalyxMCPServerListenerFailureTests.cockpit"
    private let nonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"
    private let promptBound: Duration = .seconds(10)

    override func setUp() async throws {
        try await super.setUp()
        IPCWakeSettings._testUseSuite(named: wakeSuite)
        IPCWakeSettings.enabled = true
        CockpitSettings._testUseSuite(named: cockpitSuite)
        CockpitSettings.agentHookApprovalEnabled = true
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server.approvalInbox = ApprovalInboxStore()
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server.approvalSurfaceExists = { _ in true }
        server.ipcWakeTimeoutMs = 30_000
        try await server.start(token: testToken, preferredPort: 0)
    }

    override func tearDown() async throws {
        await server.stopAndWait()
        server = nil
        if let agentEndpointDir { try? FileManager.default.removeItem(atPath: agentEndpointDir) }
        agentEndpointDir = nil
        CockpitSettings._testTeardownSuite(named: cockpitSuite)
        IPCWakeSettings._testTeardownSuite(named: wakeSuite)
        try await super.tearDown()
    }

    private var endpointFilePath: String { agentEndpointDir + "/agent-endpoint.json" }

    private func waitUntil(timeout: TimeInterval = 10.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func test_listenerFailure_removesTheEndpointFileAndStopsTheServer() async throws {
        XCTAssertTrue(server.isRunning, "precondition: the server is running")
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointFilePath), "precondition: start() wrote the file")

        server._testSimulateListenerFailure()

        let stopped = await waitUntil { !self.server.isRunning }
        XCTAssertTrue(stopped, "a listener failure after .ready must stop the server")
        let removed = await waitUntil { !FileManager.default.fileExists(atPath: self.endpointFilePath) }
        XCTAssertTrue(removed, "a listener failure after .ready must remove agent-endpoint.json")
    }

    func test_listenerFailure_releasesAWaitingWakePollWith204() async throws {
        let surface = UUID()
        let request = HTTPRequest(method: "POST", path: "/ipc-wake", headers: [
            "Authorization": "Bearer \(testToken)",
            "X-Calyx-Surface-ID": surface.uuidString,
            "X-Calyx-Wake-Nonce": nonce,
        ], body: nil)
        let pollTask = Task { @MainActor in await self.server.route(request: request) }
        let waiting = await waitUntil { self.server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surface) }
        XCTAssertTrue(waiting, "precondition: the wake poll is waiting")

        let clock = ContinuousClock()
        let start = clock.now
        server._testSimulateListenerFailure()
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNil(response.body)
        XCTAssertLessThan(clock.now - start, promptBound, "the failure must end the poll, not its 30 s timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    func test_listenerFailure_expiresAPendingApprovalPoll() async throws {
        let inbox = ApprovalInboxStore()
        server.approvalInbox = inbox
        let body = Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"},"hook_event_name":"PermissionRequest"}"#.utf8)
        let request = HTTPRequest(method: "POST", path: "/approval-request", headers: [
            "Authorization": "Bearer \(testToken)",
            "X-Calyx-Surface-ID": UUID().uuidString,
        ], body: body)
        let task = Task { @MainActor in await self.server.route(request: request) }
        let submitted = await waitUntil { inbox.pending.count == 1 }
        XCTAssertTrue(submitted, "precondition: the approval request is pending")

        server._testSimulateListenerFailure()
        let response = await task.value

        XCTAssertTrue(inbox.pending.isEmpty, "the failure must expire the pending approval, as stop() does")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.body, "stop()'s expiry returns an empty body, never a fabricated decision")
    }

    /// start() on a running server calls stop() (which cancels the OLD
    /// listener) and installs a NEW one. The old listener's `.cancelled`
    /// is delivered asynchronously, after the new listener is current;
    /// handleListenerEnded's identity check must ignore it.
    func test_supersededListenerCancelled_doesNotStopARestartedServer() async throws {
        let oldPort = server.port
        XCTAssertTrue(server.isRunning, "precondition: the server is running")

        try await server.start(token: testToken, preferredPort: 0)
        let newPort = server.port
        XCTAssertTrue(server.isRunning, "precondition: the restarted server is running")
        XCTAssertNotEqual(newPort, 0)

        // Give the old listener's .cancelled time to arrive (up to 2 s);
        // the server must stay running throughout.
        let stopped = await waitUntil(timeout: 2.0) { !self.server.isRunning }
        XCTAssertFalse(stopped, "the superseded listener's .cancelled must not stop the restarted server")
        XCTAssertTrue(server.isRunning)
        XCTAssertEqual(server.port, newPort)

        let data = try Data(contentsOf: URL(fileURLWithPath: endpointFilePath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["port"] as? Int, newPort, "agent-endpoint.json names the new port (old: \(oldPort))")
    }
}
