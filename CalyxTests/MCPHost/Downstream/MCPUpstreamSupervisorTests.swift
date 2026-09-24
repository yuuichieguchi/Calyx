//
//  MCPUpstreamSupervisorTests.swift
//  CalyxTests
//
//  The connection `MCPUpstreamSupervisor.makeConnection(for:)` builds for
//  an HTTP server sends the configured headers, with their values read
//  from the secret store, through the injected `MCPHTTPSession` (backed
//  here by `URLProtocolStub`).
//
//  Contract section 13a.1: every connection state change reaches the view
//  host through `serverConnectionChanged(serverID:state:)`; `retry`,
//  `signOut`, `authState(for:)` and `disconnectAll`; and
//  `.calyxMCPConnectionsDidChange` after each reconciliation. A stdio
//  server whose command does not exist moves through `connecting` to
//  `failed` without a child process or a network request.
//

import XCTest
@testable import Calyx

@MainActor
final class MCPUpstreamSupervisorTests: XCTestCase {

    private var recorder: MCPHTTPStubRecorder!
    private var urlSession: URLSession!
    private var registryDir: String!

    override func setUp() {
        super.setUp()
        recorder = MCPHTTPStubRecorder()
        urlSession = URLSession(configuration: MCPHTTPStubProtocol.configuration(recorder: recorder))
        registryDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: registryDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let registryDir { try? FileManager.default.removeItem(atPath: registryDir) }
        registryDir = nil
        urlSession = nil
        recorder = nil
        super.tearDown()
    }

    private func waitForRequestCount(_ count: Int, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while recorder.requests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_makeConnection_httpConfig_sendsTheConfiguredHeaderWithItsStoredValue() async throws {
        let secretStore = InMemoryMCPSecretStore()
        let httpSession = MCPHTTPSession(urlSession: urlSession)
        let supervisor = MCPUpstreamSupervisor(
            registry: MCPServerRegistry(directory: registryDir, secretStore: secretStore),
            secretStore: secretStore,
            authFlow: MCPOAuthFlow(
                session: httpSession,
                discovery: MCPOAuthMetadataDiscovery(session: httpSession),
                registration: MCPOAuthClientRegistration(session: httpSession, store: InMemoryMCPOAuthClientRegistrationStore()),
                browser: FakeMCPOAuthBrowserOpening(),
                redirectConfig: MCPOAuthRedirectConfig(host: .loopback, port: .random),
                credentials: InMemoryMCPOAuthCredentialStore()
            ),
            clientInfo: MCPImplementation(name: "Calyx", version: "1.0", title: nil, description: nil, websiteUrl: nil),
            httpSession: httpSession
        )
        supervisor.setElicitationPresenting(NoOpElicitationPresenter())
        let serverID = MCPServerID()
        try await secretStore.set("configured-value", forKey: .header(serverID: serverID, name: "X-Api"))
        let config = MCPServerConfig(
            id: serverID,
            alias: try XCTUnwrap(MCPServerAlias(rawValue: "weather")),
            displayName: "Weather Service",
            isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: ["X-Api"], hint: nil),
            auth: nil
        )
        recorder.enqueue { _ in .empty(status: 500) }

        let connection = supervisor.makeConnection(for: config)
        await connection.start()
        try await waitForRequestCount(1)
        await connection.stop()

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://mcp.example.com/mcp"))
        XCTAssertEqual(request.headers["X-Api"], "configured-value")
    }

    // MARK: - Section 13a.1 additions

    private struct Harness {
        let supervisor: MCPUpstreamSupervisor
        let registry: MCPServerRegistry
        let secretStore: InMemoryMCPSecretStore
        let viewHost: RecordingViewHost
    }

    private func makeHarness() -> Harness {
        let secretStore = InMemoryMCPSecretStore()
        let httpSession = MCPHTTPSession(urlSession: urlSession)
        let registry = MCPServerRegistry(directory: registryDir, secretStore: secretStore)
        let supervisor = MCPUpstreamSupervisor(
            registry: registry,
            secretStore: secretStore,
            authFlow: MCPOAuthFlow(
                session: httpSession,
                discovery: MCPOAuthMetadataDiscovery(session: httpSession),
                registration: MCPOAuthClientRegistration(session: httpSession, store: InMemoryMCPOAuthClientRegistrationStore()),
                browser: FakeMCPOAuthBrowserOpening(),
                redirectConfig: MCPOAuthRedirectConfig(host: .loopback, port: .random),
                credentials: InMemoryMCPOAuthCredentialStore()
            ),
            clientInfo: MCPImplementation(name: "Calyx", version: "1.0", title: nil, description: nil, websiteUrl: nil),
            httpSession: httpSession
        )
        let viewHost = RecordingViewHost()
        supervisor.setElicitationPresenting(NoOpElicitationPresenter())
        supervisor.setViewHosting(viewHost)
        return Harness(supervisor: supervisor, registry: registry, secretStore: secretStore, viewHost: viewHost)
    }

    private func missingCommandConfig(alias: String = "broken") throws -> MCPServerConfig {
        MCPServerConfig(
            id: MCPServerID(),
            alias: try XCTUnwrap(MCPServerAlias(rawValue: alias)),
            displayName: "Broken Server",
            isEnabled: true,
            transport: .stdio(command: "/nonexistent/calyx-supervisor-test-command", args: [], envNames: [], cwd: nil),
            auth: nil
        )
    }

    private func httpConfig(alias: String = "remote") throws -> MCPServerConfig {
        MCPServerConfig(
            id: MCPServerID(),
            alias: try XCTUnwrap(MCPServerAlias(rawValue: alias)),
            displayName: "Remote Server",
            isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil),
            auth: nil
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func isFailed(_ state: MCPConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    func test_connectionStateChanges_reachTheViewHost() async throws {
        let harness = makeHarness()
        let config = try missingCommandConfig()
        try await harness.registry.add(config)

        await harness.supervisor.connectAll()
        try await waitUntil { harness.viewHost.states(for: config.id).contains(where: Self.isFailed) }

        let states = harness.viewHost.states(for: config.id)
        XCTAssertEqual(states.first, .connecting, "the first state a started connection reports is connecting")
        XCTAssertTrue(states.contains(where: Self.isFailed), "a command that cannot be spawned ends in failed, which the view host must see")
    }

    func test_retry_movesAFailedConnectionBackToConnecting() async throws {
        let harness = makeHarness()
        let config = try missingCommandConfig()
        try await harness.registry.add(config)
        await harness.supervisor.connectAll()
        try await waitUntil { harness.viewHost.states(for: config.id).contains(where: Self.isFailed) }
        let countBeforeRetry = harness.viewHost.states(for: config.id).count

        try await harness.supervisor.retry(serverID: config.id)
        try await waitUntil { harness.viewHost.states(for: config.id).count > countBeforeRetry }

        XCTAssertEqual(harness.viewHost.states(for: config.id).dropFirst(countBeforeRetry).first, .connecting,
                       "retry forwards retryFromFailed(), which enters connecting")
    }

    func test_retry_unknownServer_throws() async throws {
        let harness = makeHarness()
        let unknown = MCPServerID()
        do {
            try await harness.supervisor.retry(serverID: unknown)
            XCTFail("retry of a server the supervisor does not know must throw")
        } catch let error as MCPUpstreamSupervisorError {
            XCTAssertEqual(error, .unknownServer(unknown))
        }
    }

    func test_authState_stdioServer_isNotRequired() async throws {
        let harness = makeHarness()
        let config = try missingCommandConfig()
        try await harness.registry.add(config)

        let state = try await harness.supervisor.authState(for: config.id)

        XCTAssertEqual(state, .notRequired)
    }

    func test_authState_httpServer_followsTheStoredTokens() async throws {
        let harness = makeHarness()
        let config = try httpConfig()
        try await harness.registry.add(config)
        let credentials = MCPSecretStoreOAuthCredentials(secretStore: harness.secretStore)

        let before = try await harness.supervisor.authState(for: config.id)
        try await credentials.setTokens(
            MCPOAuthTokenSet(accessToken: "stored-access", refreshToken: nil, expiresAt: nil, scope: nil),
            for: config.id
        )
        let after = try await harness.supervisor.authState(for: config.id)

        XCTAssertEqual(before, .signedOut)
        XCTAssertEqual(after, .signedIn(account: nil), "no ID token carries an account name, so it is nil")
    }

    func test_signOut_deletesTheTokensButKeepsTheClientRegistration() async throws {
        let harness = makeHarness()
        let config = try httpConfig()
        try await harness.registry.add(config)
        let credentials = MCPSecretStoreOAuthCredentials(secretStore: harness.secretStore)
        let client = MCPOAuthStoredClient(
            clientID: "registered-client",
            tokenEndpoint: try XCTUnwrap(URL(string: "https://auth.example.com/token")),
            clientAuthentication: .none,
            grantedScope: nil
        )
        try await credentials.setTokens(
            MCPOAuthTokenSet(accessToken: "stored-access", refreshToken: nil, expiresAt: nil, scope: nil),
            for: config.id
        )
        try await credentials.setClientRegistration(client, for: config.id)

        try await harness.supervisor.signOut(serverID: config.id)

        let tokens = try await credentials.tokens(for: config.id)
        let registration = try await credentials.clientRegistration(for: config.id)
        let state = try await harness.supervisor.authState(for: config.id)
        XCTAssertNil(tokens)
        XCTAssertEqual(registration, client, "the per-issuer client registration is reused by the next sign-in")
        XCTAssertEqual(state, .signedOut)
    }

    func test_signOut_ofAConnectedServer_reconnectsTheSameConnection_withoutTearingDownViews() async throws {
        let harness = makeHarness()
        let config = try httpConfig()
        try await harness.registry.add(config)
        recorder.enqueue { _ in .empty(status: 500) }
        await harness.supervisor.connectAll()
        try await waitUntil { harness.viewHost.states(for: config.id).contains(where: Self.isFailed) }
        let connectionBefore = try XCTUnwrap(harness.supervisor.connection(forServerID: config.id))
        let countBefore = harness.viewHost.states(for: config.id).count

        try await harness.supervisor.signOut(serverID: config.id)
        try await waitUntil { harness.viewHost.states(for: config.id).count >= countBefore + 2 }

        let connectionAfter = try XCTUnwrap(harness.supervisor.connection(forServerID: config.id))
        XCTAssertTrue(connectionAfter as AnyObject === connectionBefore as AnyObject, "sign-out reconnects the same connection, not a new one")
        XCTAssertEqual(Array(harness.viewHost.states(for: config.id).dropFirst(countBefore).prefix(2)), [.disabled, .connecting],
                       "the connection is disabled and enabled again")
        XCTAssertTrue(harness.viewHost.tornDownServers.isEmpty, "sign-out keeps the server's views")
    }

    func test_disconnectAll_closesEveryConnection_andConnectAllBringsThemBack() async throws {
        let harness = makeHarness()
        let config = try missingCommandConfig()
        try await harness.registry.add(config)
        await harness.supervisor.connectAll()
        XCTAssertNotNil(harness.supervisor.connection(forServerID: config.id))

        await harness.supervisor.disconnectAll()
        XCTAssertNil(harness.supervisor.connection(forServerID: config.id), "IPC off leaves no connection open")

        await harness.supervisor.connectAll()
        XCTAssertNotNil(harness.supervisor.connection(forServerID: config.id), "IPC on again reconnects every enabled server")
    }

    func test_reconcile_postsConnectionsDidChange() async throws {
        let harness = makeHarness()
        try await harness.registry.add(try missingCommandConfig())
        let posted = expectation(forNotification: .calyxMCPConnectionsDidChange, object: nil)

        await harness.supervisor.connectAll()

        await fulfillment(of: [posted], timeout: 2)
    }

    func test_disconnectAll_postsConnectionsDidChange() async throws {
        let harness = makeHarness()
        try await harness.registry.add(try missingCommandConfig())
        await harness.supervisor.connectAll()
        let posted = expectation(forNotification: .calyxMCPConnectionsDidChange, object: nil)

        await harness.supervisor.disconnectAll()

        await fulfillment(of: [posted], timeout: 2)
    }

    // MARK: - Reconciliation runs one at a time

    private func missingCommandConfig(id: MCPServerID, alias: String, command: String) throws -> MCPServerConfig {
        MCPServerConfig(
            id: id,
            alias: try XCTUnwrap(MCPServerAlias(rawValue: alias)),
            displayName: "Broken Server",
            isEnabled: true,
            transport: .stdio(command: command, args: [], envNames: [], cwd: nil),
            auth: nil
        )
    }

    private static func isConnecting(_ state: MCPConnectionState) -> Bool { state == .connecting }
    private static func isDisabled(_ state: MCPConnectionState) -> Bool { state == .disabled }

    /// Every connection the supervisor starts reports `.connecting` once
    /// (a missing command fails without restarting), and `.disabled` once
    /// when it is stopped. Started minus stopped is the number still open.
    func test_twoRegistryChangesWhileReconciling_leaveExactlyOneOpenConnection() async throws {
        let harness = makeHarness()
        let serverID = MCPServerID()
        try await harness.registry.add(try missingCommandConfig(id: serverID, alias: "broken", command: "/nonexistent/calyx-reconcile-a"))
        await harness.supervisor.connectAll()
        harness.supervisor.startObservingRegistry()
        try await waitUntil { harness.viewHost.states(for: serverID).contains(where: Self.isFailed) }

        harness.viewHost.holdsTeardowns = true
        try await harness.registry.update(try missingCommandConfig(id: serverID, alias: "broken", command: "/nonexistent/calyx-reconcile-b"))
        try await waitUntil { harness.viewHost.heldTeardownCount == 1 }
        try await harness.registry.update(try missingCommandConfig(id: serverID, alias: "broken", command: "/nonexistent/calyx-reconcile-c"))
        // Gives a second, concurrent reconciliation the chance to start.
        try await Task.sleep(for: .milliseconds(100))
        harness.viewHost.releaseTeardowns()

        let open = { () -> Int in
            let states = harness.viewHost.states(for: serverID)
            return states.filter(Self.isConnecting).count - states.filter(Self.isDisabled).count
        }
        try await waitUntil { harness.viewHost.tornDownServers.count == 2 && open() == 1 }
        XCTAssertEqual(open(), 1, "one connection is open for the server after both changes")

        await harness.supervisor.disconnectAll()
        try await waitUntil { open() == 0 }
        XCTAssertEqual(open(), 0, "every connection the supervisor started is stopped; none leaked")
    }

    // MARK: - A crash after ready reaches the Settings row (K65)

    /// A stdio MCP server (legacy handshake, newline-delimited JSON) that
    /// answers `initialize` and `tools/list` with one UI tool, then exits
    /// with status 1 half a second later: a crash after `ready`.
    private static let crashingServerScript = """
    import json, sys, threading, os, time
    def send(message):
        sys.stdout.write(json.dumps(message) + "\\n")
        sys.stdout.flush()
    def crash_soon():
        time.sleep(0.5)
        os._exit(1)
    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": message["id"], "result": {
                "protocolVersion": "2025-11-25",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "crashing", "version": "1.0"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": message["id"], "result": {"tools": [{
                "name": "show", "inputSchema": {"type": "object"},
                "_meta": {"ui": {"resourceUri": "ui://crashing/show.html"}}}]}})
            threading.Thread(target=crash_soon).start()
        elif "id" in message:
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "no"}})
    """

    func test_crashAfterReady_reachesTheSettingsRowAsDisconnected() async throws {
        let harness = makeHarness()
        let config = MCPServerConfig(
            id: MCPServerID(),
            alias: try XCTUnwrap(MCPServerAlias(rawValue: "crashing")),
            displayName: "Crashing Server",
            isEnabled: true,
            transport: .stdio(command: "/usr/bin/python3", args: ["-u", "-c", Self.crashingServerScript], envNames: [], cwd: nil),
            auth: nil
        )
        try await harness.registry.add(config)
        let model = MCPServerSettingsModel()
        model.configure(MCPServerSettingsModel.Dependencies(
            registry: harness.registry,
            connections: harness.supervisor,
            catalog: FakeCatalogProviding(),
            secretStore: harness.secretStore,
            actions: MCPSupervisorSettingsActions(supervisor: harness.supervisor)
        ))

        await harness.supervisor.connectAll()
        // What the composition root does on `.calyxMCPConnectionsDidChange`.
        model.refreshConnections()
        var seen: [String] = []
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !seen.contains(where: { $0.contains("Disconnected") }) {
            let text = model.rowState(for: config).statusText
            if seen.last != text { seen.append(text) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await harness.supervisor.disconnectAll()

        let readyIndex = try XCTUnwrap(seen.firstIndex(of: "1 tool, 1 with UI"), "the row never showed ready -- saw \(seen)")
        let disconnectedIndex = try XCTUnwrap(
            seen.firstIndex(of: "Disconnected (reconnecting)"),
            "a crash after ready must reach the row as disconnected -- saw \(seen)"
        )
        XCTAssertLessThan(readyIndex, disconnectedIndex, "saw \(seen)")
    }
}

/// Records the connection states the supervisor forwards. While
/// `holdsTeardowns` is set, `teardownViews` waits until `releaseTeardowns()`.
@MainActor
private final class RecordingViewHost: MCPAppViewHosting {
    private var recordedStates: [MCPServerID: [MCPConnectionState]] = [:]
    private(set) var tornDownServers: [MCPServerID] = []
    var holdsTeardowns = false
    private var heldTeardowns: [CheckedContinuation<Void, Never>] = []

    var heldTeardownCount: Int { heldTeardowns.count }

    func releaseTeardowns() {
        holdsTeardowns = false
        let held = heldTeardowns
        heldTeardowns.removeAll()
        held.forEach { $0.resume() }
    }

    func states(for serverID: MCPServerID) -> [MCPConnectionState] {
        recordedStates[serverID] ?? []
    }

    func serverConnectionChanged(serverID: MCPServerID, state: MCPConnectionState) {
        recordedStates[serverID, default: []].append(state)
    }

    func uiToolInvocationDidStart(_ invocation: MCPUIToolInvocation, session: any MCPAppServerSession) async {}
    func hasActiveView(forSurface surfaceID: UUID) -> Bool { false }
    func isStandalonePanel(_ id: MCPInvocationID) -> Bool { false }
    func remapSurface(old: UUID, new: UUID) {}
    func teardownViews(forServer serverID: MCPServerID, reason: String) async {
        tornDownServers.append(serverID)
        guard holdsTeardowns else { return }
        await withCheckedContinuation { heldTeardowns.append($0) }
    }
    func callAppTool(surfaceID: UUID, viewID: UUID, name: String, arguments: [String: AnyCodable]) async -> MCPCallToolResult {
        MCPCallToolResult(raw: [:])
    }
    func uiToolInvocationDidFinish(_ id: MCPInvocationID, result: MCPCallToolResult) async {}
    func uiToolInvocationWasCancelled(_ id: MCPInvocationID) async {}
}
