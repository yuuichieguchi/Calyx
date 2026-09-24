//
//  MCPUpstreamConnectionTests.swift
//  CalyxTests
//
//  `MCPUpstreamConnection` is the per-server actor that supervises a
//  single `MCPUpstreamClient` above a `MCPMessageTransport`: it owns
//  `start()`/`stop()`, drives `negotiate(order:knownEra:)`, paginates
//  `tools/list`, subscribes to change notifications on the modern era,
//  detects unsolicited transport loss and restarts with exponential
//  backoff, and gives up after repeated crash-looping (API contract
//  section 4.3, `MCPUpstreamConnecting` at section 4.2).
//
//  `InMemoryMCPTransport` distinguishes an unsolicited transport loss
//  (`simulateCrash`) from a caller-initiated `close()`: only the former
//  may ever be observed as `.restarting`. `ManualMCPClock` makes the
//  backoff sequence (1, 2, 4, ... capped at `backoffCapSeconds`)
//  observable without a wall-clock sleep; every test below uses a
//  request timeout far larger than any backoff duration so the two
//  kinds of `clock.sleep` calls can be told apart in
//  `sleepDurations()`.
//
//  All eight `MCPConnectionState` transitions in the contract's section
//  4.1 table are exercised here, including `needsAuthorization` ->
//  `authorizing` -> `connecting`/`needsAuthorization` (via
//  `beginAuthorization()`/`endAuthorization(succeeded:)`) and `ready`/
//  any state -> `disabled` -> `connecting` (via `disable()`/`enable()`).
//  A transport `.error` signal carrying `httpStatus: 401` makes
//  `negotiate` throw `MCPNegotiationError.authorizationRequired`
//  unconditionally (no order-dependent fallback, section 3.3); the same
//  signal arriving as a `.protocolError(.transport(signal))` outcome on
//  an in-flight call after `.ready` drives the same
//  `.needsAuthorization` transition (section 4.3).
//
//  `MCPUpstreamConnection` never subscribes to `transport.inbound`
//  directly (section 4.3: "`transport.inbound` を購読するのは Client
//  だけ"). It subscribes to `client.serverEvents`
//  (`MCPUpstreamClient.serverEvents`, section 3.3) for the events the
//  client itself does not consume: unhandled notifications (e.g.
//  `notifications/tools/list_changed`) and the single unsolicited
//  `.closed(reason:exit:stderrTail:)`. Nothing in this file drives
//  `transport.inbound` to simulate a crash or notification that the
//  connection is expected to observe -- `InMemoryMCPTransport`'s
//  `simulateCrash`/`simulateServerMessage` still work because they are
//  the transport-level primitives `MCPUpstreamClient` itself consumes
//  and republishes on `serverEvents`; this file only asserts on
//  `MCPUpstreamConnection`-level effects (state, tools, events,
//  wire frames), never on `client.serverEvents` directly.
//

import XCTest
@testable import Calyx

private struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

/// Records every `MCPServerEvent` delivered on a connection's `events`
/// stream, in order, for tests that assert on the transition sequence
/// itself rather than only the final state.
private actor EventRecorder {
    private(set) var events: [MCPServerEvent] = []
    func record(_ event: MCPServerEvent) { events.append(event) }
}

/// Hands out a fresh `InMemoryMCPTransport` per `transportFactory`
/// call, recording the `MCPTransportVariant` each call was made with so
/// tests can assert `start()` requests `.standard` and the
/// `legacySSERequired` retry requests `.legacySSE`.
private actor TransportFactory {
    private(set) var issued: [(variant: MCPTransportVariant, transport: InMemoryMCPTransport)] = []
    var shouldThrow = false

    func next(_ variant: MCPTransportVariant) throws -> InMemoryMCPTransport {
        if shouldThrow {
            throw MCPTransportError.closed
        }
        let transport = InMemoryMCPTransport()
        issued.append((variant, transport))
        return transport
    }

    var transports: [InMemoryMCPTransport] { issued.map(\.transport) }
    var variants: [MCPTransportVariant] { issued.map(\.variant) }
}

@MainActor
final class MCPUpstreamConnectionTests: XCTestCase {

    /// A request timeout far larger than any backoff duration
    /// (1, 2, 4, ... capped) so `ManualMCPClock.sleepDurations()` can be
    /// filtered to isolate backoff sleeps from handshake/request-timeout
    /// sleeps that `MCPUpstreamClient` also registers on the same clock.
    private let requestTimeoutMarker: TimeInterval = 9000

    // MARK: - Helpers

    private func decode(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.005,
        _ predicate: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        if await predicate() { return }
        throw WaitTimedOut(description: "condition never became true within \(timeout)s")
    }

    private func makeConfiguration(
        maxCrashesBeforeFailed: Int = 5,
        backoffCapSeconds: TimeInterval = 60,
        serverDisplayName: String = "test-server",
        maxMRTRRounds: Int = 8
    ) -> MCPUpstreamConnection.Configuration {
        MCPUpstreamConnection.Configuration(
            client: MCPUpstreamClient.Configuration(
                clientInfo: MCPImplementation(name: "Calyx", version: "1.0", title: nil, description: nil, websiteUrl: nil),
                requestTimeout: requestTimeoutMarker,
                serverDisplayName: serverDisplayName,
                maxMRTRRounds: maxMRTRRounds
            ),
            maxCrashesBeforeFailed: maxCrashesBeforeFailed,
            backoffCapSeconds: backoffCapSeconds
        )
    }

    private func makeConnection(
        serverID: MCPServerID = MCPServerID(),
        factory: TransportFactory,
        clock: MCPClock,
        handshakeOrder: MCPHandshakeOrder = .initializeFirst,
        knownEra: MCPProtocolEra? = nil,
        presenter: (any MCPElicitationPresenting)? = nil,
        configuration: MCPUpstreamConnection.Configuration? = nil
    ) -> MCPUpstreamConnection {
        MCPUpstreamConnection(
            serverID: serverID,
            transportFactory: { variant in try await factory.next(variant) },
            handshakeOrder: handshakeOrder,
            knownEra: knownEra,
            configuration: configuration ?? makeConfiguration(),
            clock: clock,
            elicitationPresenter: presenter ?? NoOpElicitationPresenter()
        )
    }

    /// Subscribes to `connection.events` on a background `Task` before
    /// `start()` is called, so the recorder observes every transition
    /// from the first. `AsyncStream`'s default unbounded buffering means
    /// elements already yielded before the consuming `Task` gets
    /// scheduled are not lost.
    private func recordEvents(_ connection: MCPUpstreamConnection) async -> EventRecorder {
        let recorder = EventRecorder()
        let stream = await connection.events
        Task {
            for await event in stream {
                await recorder.record(event)
            }
        }
        return recorder
    }

    /// Drives a legacy `initialize` handshake (request already on the
    /// wire) to completion and asserts `notifications/initialized`
    /// follows. Returns the message count after the handshake so
    /// callers index subsequent frames from a known baseline.
    @discardableResult
    private func driveLegacyInitialize(
        _ transport: InMemoryMCPTransport,
        protocolVersion: String = "2025-11-25",
        serverName: String = "s",
        serverVersion: String = "1",
        instructions: String? = nil
    ) async throws -> Int {
        try await waitUntil { await transport.sentMessages().count >= 1 }
        let request = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(request["method"] as? String, "initialize")
        let id = request["id"] as! Int
        let instructionsJSON = instructions.map { "\"\($0)\"" } ?? "null"
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"\#(protocolVersion)","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"\#(serverName)","version":"\#(serverVersion)"},"instructions":\#(instructionsJSON)}}
        """#.utf8))
        try await waitUntil { await transport.sentMessages().count >= 2 }
        let initializedNotification = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(initializedNotification["method"] as? String, "notifications/initialized")
        XCTAssertNil(initializedNotification["id"])
        return 2
    }

    /// Drives a modern `server/discover` handshake to completion.
    @discardableResult
    private func driveModernDiscover(
        _ transport: InMemoryMCPTransport,
        afterMessageCount baseline: Int = 0,
        instructions: String? = nil
    ) async throws -> Int {
        try await waitUntil { await transport.sentMessages().count >= baseline + 1 }
        let request = try decode(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "server/discover")
        let id = request["id"] as! Int
        let instructionsJSON = instructions.map { "\"\($0)\"" } ?? "null"
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(id),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0,"instructions":\#(instructionsJSON)}}
        """#.utf8))
        return baseline + 1
    }

    /// Drives a single `tools/list` page: waits for the request at
    /// `baseline`, asserts its method, and replies with `toolsJSON`
    /// (a raw JSON array literal) and an optional `nextCursor`.
    @discardableResult
    private func driveToolsListPage(
        _ transport: InMemoryMCPTransport,
        afterMessageCount baseline: Int,
        toolsJSON: String,
        nextCursor: String? = nil,
        expectedCursorParam: String? = "__unset__"
    ) async throws -> Int {
        try await waitUntil { await transport.sentMessages().count >= baseline + 1 }
        let request = try decode(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "tools/list")
        if expectedCursorParam != "__unset__" {
            let params = request["params"] as? [String: String]
            XCTAssertEqual(params?["cursor"], expectedCursorParam)
        }
        let id = request["id"] as! Int
        let cursorField = nextCursor.map { ",\"nextCursor\":\"\($0)\"" } ?? ""
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(id),"result":{"tools":\#(toolsJSON)\#(cursorField)}}
        """#.utf8))
        return baseline + 1
    }

    /// Completes a full legacy handshake and a single empty `tools/list`
    /// page on `transport`, leaving the connection ready to be observed
    /// via `waitForReady`. Used by tests that must cycle back through a
    /// full "reconnect to ready" round before the next crash, since only
    /// a crash observed while `.ready` transitions to `.restarting`
    /// (section 4.1: a failure before `.ready` -- including a crash
    /// mid-handshake -- goes straight to `.failed`).
    @discardableResult
    private func driveToReady(_ transport: InMemoryMCPTransport) async throws -> Int {
        let afterHandshake = try await driveLegacyInitialize(transport)
        return try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
    }

    /// Drives `subscriptions/listen`: asserts the `notifications` filter
    /// requests `toolsListChanged: true`, replies with an empty
    /// `result`, then sends the `notifications/subscriptions/acknowledged`
    /// notification carrying the listen request's own id as the
    /// subscription id.
    @discardableResult
    private func driveSubscribeAndAcknowledge(
        _ transport: InMemoryMCPTransport,
        afterMessageCount baseline: Int
    ) async throws -> Int {
        try await waitUntil { await transport.sentMessages().count >= baseline + 1 }
        let request = try decode(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "subscriptions/listen")
        let params = request["params"] as? [String: Any]
        let notifications = params?["notifications"] as? [String: Any]
        XCTAssertEqual(notifications?["toolsListChanged"] as? Bool, true)
        let id = request["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#.utf8))
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true},"_meta":{"io.modelcontextprotocol/subscriptionId":\#(id)}}}
        """#.utf8))
        return baseline + 1
    }

    private func waitForReady(_ connection: MCPUpstreamConnection) async throws {
        try await waitUntil {
            if case .ready = await connection.state() { return true }
            return false
        }
    }

    // MARK: - start(): transport factory variant, handshake order forwarded

    func test_start_requestsStandardTransportVariant() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let variants = await factory.variants
        XCTAssertEqual(variants, [.standard])
        try await driveLegacyInitialize(await factory.transports[0])
        _ = try await driveToolsListPage(await factory.transports[0], afterMessageCount: 2, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)
        await connection.stop()
    }

    func test_start_discoverFirstOrder_knownEraLegacy_sendsInitializeFirstWithKnownVersion() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(
            factory: factory,
            clock: ManualMCPClock(),
            handshakeOrder: .discoverFirst,
            knownEra: .legacy(.v2025_11_25)
        )

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await waitUntil { await transport.sentMessages().count >= 1 }
        let request = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(request["method"] as? String, "initialize", "a known legacy era must be tried first even under .discoverFirst order")
        let params = request["params"] as? [String: Any]
        XCTAssertEqual(params?["protocolVersion"] as? String, "2025-11-25")
        await connection.stop()
    }

    // MARK: - connecting -> ready (legacy)

    func test_start_legacyHandshake_entersReadyWithNegotiatedEraServerInfoInstructionsAndToolCount() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())
        let recorder = await recordEvents(connection)

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await driveLegacyInitialize(transport, serverName: "s", serverVersion: "1", instructions: "Be terse")
        _ = try await driveToolsListPage(transport, afterMessageCount: 2, toolsJSON: #"[{"name":"tool-a"},{"name":"tool-b"}]"#, expectedCursorParam: nil)

        try await waitForReady(connection)
        let expected = MCPConnectionState.ready(
            MCPServerInfo(
                negotiatedEra: .v2025_11_25,
                serverInfo: MCPImplementation(name: "s", version: "1", title: nil, description: nil, websiteUrl: nil),
                instructions: "Be terse"
            ),
            toolCount: 2
        )
        let actual = await connection.state()
        XCTAssertEqual(actual, expected)

        try await waitUntil { await recorder.events.contains(.stateChanged(.connecting)) }
        try await waitUntil { await recorder.events.contains(.stateChanged(expected)) }
        let indexOfConnecting = await recorder.events.firstIndex(of: .stateChanged(.connecting))
        let indexOfReady = await recorder.events.firstIndex(of: .stateChanged(expected))
        XCTAssertLessThan(try XCTUnwrap(indexOfConnecting), try XCTUnwrap(indexOfReady), ".connecting must be observed before .ready")

        await connection.stop()
    }

    // MARK: - tools/list pagination follows an empty-string cursor

    func test_start_paginatesToolsList_followingEmptyStringCursor_untilNextCursorAbsent() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)

        let afterPage1 = try await driveToolsListPage(
            transport,
            afterMessageCount: afterHandshake,
            toolsJSON: #"[{"name":"tool-a"}]"#,
            nextCursor: "",
            expectedCursorParam: nil
        )
        // An empty-string cursor must still be followed with one more
        // page request carrying that exact cursor.
        _ = try await driveToolsListPage(
            transport,
            afterMessageCount: afterPage1,
            toolsJSON: #"[{"name":"tool-b"}]"#,
            expectedCursorParam: ""
        )

        try await waitForReady(connection)
        let tools = await connection.tools()
        XCTAssertEqual(Set(tools.map(\.name)), ["tool-a", "tool-b"])
        guard case .ready(_, let toolCount) = await connection.state() else {
            return XCTFail("expected .ready")
        }
        XCTAssertEqual(toolCount, 2)
        await connection.stop()
    }

    // MARK: - modern era: subscriptions/listen ack gates .ready

    func test_start_modernEra_subscribesWithToolsListChangedTrue_waitsForAckBeforeReady() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(
            factory: factory,
            clock: ManualMCPClock(),
            handshakeOrder: .discoverFirst,
            knownEra: .modern
        )

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterDiscover = try await driveModernDiscover(transport, instructions: "Modern instructions")
        let afterList = try await driveToolsListPage(transport, afterMessageCount: afterDiscover, toolsJSON: "[]", expectedCursorParam: nil)

        // Reply to subscriptions/listen with a bare empty result (not the
        // acknowledged notification): the connection must NOT be ready
        // yet, per section 4.4's "do not treat result: {} as an ack".
        try await waitUntil { await transport.sentMessages().count >= afterList + 1 }
        let listenRequest = try decode(await transport.sentMessages()[afterList])
        XCTAssertEqual(listenRequest["method"] as? String, "subscriptions/listen")
        let notifications = (listenRequest["params"] as? [String: Any])?["notifications"] as? [String: Any]
        XCTAssertEqual(notifications?["toolsListChanged"] as? Bool, true)
        let listenID = listenRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(listenID),"result":{}}"#.utf8))

        try? await waitUntil(timeout: 0.3) {
            if case .ready = await connection.state() { return true }
            return false
        }
        if case .ready = await connection.state() {
            XCTFail("result: {} on subscriptions/listen must not be treated as the acknowledged notification")
        }

        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true},"_meta":{"io.modelcontextprotocol/subscriptionId":\#(listenID)}}}
        """#.utf8))

        try await waitForReady(connection)
        guard case .ready(let info, let toolCount) = await connection.state() else {
            return XCTFail("expected .ready")
        }
        XCTAssertEqual(info.negotiatedEra, .v2026_07_28)
        XCTAssertEqual(info.instructions, "Modern instructions")
        XCTAssertEqual(toolCount, 0)
        await connection.stop()
    }

    // MARK: - legacySSERequired: close transport #1, retry on .legacySSE

    func test_start_legacySSERequired_closesFirstTransport_andRetriesWithLegacySSEVariant() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock(), handshakeOrder: .discoverFirst)

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let firstTransport = await factory.transports[0]
        try await waitUntil { await firstTransport.sentMessages().count >= 1 }
        let discoverRequest = try decode(await firstTransport.sentMessages()[0])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        await firstTransport.simulateTransportError(MCPTransportSignal(httpStatus: 400, message: "bad request"))

        try await waitUntil { await firstTransport.sentMessages().count >= 2 }
        let initRequest = try decode(await firstTransport.sentMessages()[1])
        XCTAssertEqual(initRequest["method"] as? String, "initialize")
        await firstTransport.simulateTransportError(MCPTransportSignal(httpStatus: 405, message: "method not allowed"))

        try await waitUntil { await factory.issued.count == 2 }
        let variants = await factory.variants
        XCTAssertEqual(variants, [.standard, .legacySSE])

        do {
            try await firstTransport.send(Data(), kind: .notification)
            XCTFail("first transport must have been closed before the legacySSE retry")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }

        let secondTransport = await factory.transports[1]
        try await waitUntil { await secondTransport.sentMessages().count >= 1 }
        let retryRequest = try decode(await secondTransport.sentMessages()[0])
        XCTAssertEqual(retryRequest["method"] as? String, "initialize", "the legacySSE retry must use .initializeFirst order")
        try await driveLegacyInitialize(secondTransport)
        _ = try await driveToolsListPage(secondTransport, afterMessageCount: 2, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)
        await connection.stop()
    }

    // MARK: - connecting -> failed

    func test_start_throwingTransportFactory_entersFailed() async throws {
        let factory = TransportFactory()
        await factory.setShouldThrow()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil {
            if case .failed = await connection.state() { return true }
            return false
        }
    }

    func test_start_bothInitializeAndDiscoverFail_entersFailed() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await waitUntil { await transport.sentMessages().count >= 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(initID),"error":{"code":-32601,"message":"nope"}}"#.utf8))

        try await waitUntil { await transport.sentMessages().count >= 2 }
        let discoverRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(discoverID),"error":{"code":-32601,"message":"nope"}}"#.utf8))

        try await waitUntil {
            if case .failed = await connection.state() { return true }
            return false
        }
    }

    // MARK: - ready -> restarting on unsolicited close; in-flight calls fail, never retried

    func test_unsolicitedClose_whileCallInFlight_failsWithTransportClosedReason_andEntersRestarting() async throws {
        let factory = TransportFactory()
        let clock = ManualMCPClock()
        let connection = makeConnection(factory: factory, clock: clock)

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let firstTransport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(firstTransport)
        _ = try await driveToolsListPage(firstTransport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        let callTask = Task { await connection.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await firstTransport.sentMessages().count >= afterHandshake + 2 }
        let callRequest = try decode(await firstTransport.sentMessages()[afterHandshake + 1])
        XCTAssertEqual(callRequest["method"] as? String, "tools/call")

        await firstTransport.simulateCrash(reason: "boom")

        let outcome = await callTask.value
        guard case .protocolError(let error) = outcome else {
            return XCTFail("expected .protocolError after unsolicited close, got \(outcome)")
        }
        XCTAssertEqual(error, .transportClosed(reason: "boom"))

        try await waitUntil {
            if case .restarting = await connection.state() { return true }
            return false
        }
        clock.advance(by: 1)

        // The lost call must never be retried automatically on the new
        // transport once reconnection completes.
        try await waitUntil { await factory.issued.count == 2 }
        let secondTransport = await factory.transports[1]
        try await driveLegacyInitialize(secondTransport)
        try? await waitUntil(timeout: 0.3) { await secondTransport.sentMessages().count >= 3 }
        let secondTransportMessages = try await secondTransport.sentMessages().map(decode)
        XCTAssertFalse(secondTransportMessages.contains { $0["method"] as? String == "tools/call" })
    }

    // MARK: - stop() closes the transport and is never observed as a crash

    func test_stop_closesActiveTransport_neverObservedAsRestarting() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        _ = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        await connection.stop()

        do {
            try await transport.send(Data(), kind: .notification)
            XCTFail("stop() must close the active transport")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }

        try? await waitUntil(timeout: 0.3) { await factory.issued.count > 1 }
        let issuedCount = await factory.issued.count
        XCTAssertEqual(issuedCount, 1, "stop() must not trigger a restart")
        if case .restarting = await connection.state() {
            XCTFail("stop() must never be observed as .restarting")
        }
    }

    // MARK: - backoff sequence, capped

    func test_repeatedCrashes_backOffExponentially_cappedAtConfiguredCeiling() async throws {
        let factory = TransportFactory()
        let clock = ManualMCPClock()
        let connection = makeConnection(
            factory: factory,
            clock: clock,
            configuration: makeConfiguration(maxCrashesBeforeFailed: 5, backoffCapSeconds: 4)
        )
        let requestTimeoutMarker = self.requestTimeoutMarker

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let afterHandshake = try await driveLegacyInitialize(await factory.transports[0])
        _ = try await driveToolsListPage(await factory.transports[0], afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        // Crash 4 times, each time completing a full handshake back to
        // .ready before the next crash: only a crash observed while
        // .ready transitions to .restarting (section 4.1), so each cycle
        // must reach .ready again before it counts as the next
        // ready-state crash. Each backoff is driven forward explicitly
        // via the manual clock, isolated from the distinctive
        // requestTimeoutMarker also recorded on the same clock by
        // MCPUpstreamClient.
        var observedBackoffs: [TimeInterval] = []
        for _ in 0..<4 {
            let issuedBefore = await factory.issued.count
            let backoffsBefore = await clock.sleepDurations().filter { $0 != requestTimeoutMarker }.count
            await factory.transports[issuedBefore - 1].simulateCrash()
            try await waitUntil { await clock.sleepDurations().filter { $0 != requestTimeoutMarker }.count > backoffsBefore }
            let allBackoffs = await clock.sleepDurations().filter { $0 != requestTimeoutMarker }
            observedBackoffs.append(allBackoffs[backoffsBefore])
            clock.advance(by: allBackoffs[backoffsBefore])
            try await waitUntil { await factory.issued.count == issuedBefore + 1 }
            try await driveToReady(await factory.transports[issuedBefore])
            try await waitForReady(connection)
        }

        XCTAssertEqual(observedBackoffs, [1, 2, 4, 4])
        await connection.stop()
    }

    // MARK: - five crashes -> failed with stderrTail, no further auto-restart

    func test_fiveCrashesInShortWindow_entersFailedWithNilStderrTail_andStopsAutoRestarting() async throws {
        let factory = TransportFactory()
        let clock = ManualMCPClock()
        let connection = makeConnection(
            factory: factory,
            clock: clock,
            configuration: makeConfiguration(maxCrashesBeforeFailed: 5, backoffCapSeconds: 4)
        )
        let requestTimeoutMarker = self.requestTimeoutMarker

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        try await driveToReady(await factory.transports[0])
        try await waitForReady(connection)

        // Crashes 1-4, each from .ready, each completing a fresh
        // handshake back to .ready before the next crash.
        for _ in 0..<4 {
            let issuedBefore = await factory.issued.count
            let backoffsBefore = await clock.sleepDurations().filter { $0 != requestTimeoutMarker }.count
            await factory.transports[issuedBefore - 1].simulateCrash()
            try await waitUntil { await clock.sleepDurations().filter { $0 != requestTimeoutMarker }.count > backoffsBefore }
            let backoff = await clock.sleepDurations().filter { $0 != requestTimeoutMarker }[backoffsBefore]
            clock.advance(by: backoff)
            try await waitUntil { await factory.issued.count == issuedBefore + 1 }
            try await driveToReady(await factory.transports[issuedBefore])
            try await waitForReady(connection)
        }

        // The 5th crash, still within the same short window, must enter
        // .failed without spawning a 6th transport.
        let issuedBeforeFifth = await factory.issued.count
        await factory.transports[issuedBeforeFifth - 1].simulateCrash()

        try await waitUntil {
            if case .failed = await connection.state() { return true }
            return false
        }
        guard case .failed(let failure) = await connection.state() else {
            return XCTFail("expected .failed")
        }
        XCTAssertNil(failure.stderrTail, "InMemoryMCPTransport.simulateCrash never carries a stderr tail")

        try? await waitUntil(timeout: 0.3) { await factory.issued.count > issuedBeforeFifth }
        let issuedCount = await factory.issued.count
        XCTAssertEqual(issuedCount, issuedBeforeFifth, ".failed must stop automatic restarts")
    }

    // MARK: - retryFromFailed -> connecting

    func test_retryFromFailed_returnsToConnecting_andCanReachReadyAgain() async throws {
        let factory = TransportFactory()
        await factory.setShouldThrow()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil {
            if case .failed = await connection.state() { return true }
            return false
        }

        await factory.clearShouldThrow()
        await connection.retryFromFailed()

        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        _ = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)
        await connection.stop()
    }

    // MARK: - callTool cancellation propagates to transport.cancel

    func test_callTool_taskCancellation_propagatesToTransportCancel() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        _ = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        let callTask = Task { await connection.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count >= afterHandshake + 2 }
        let callRequest = try decode(await transport.sentMessages()[afterHandshake + 1])
        let callID = callRequest["id"] as! Int

        callTask.cancel()
        _ = await callTask.value

        try await waitUntil { await transport.cancelledRequestIDs().contains(.int(callID)) }
        await connection.stop()
    }

    // MARK: - -32020: one tools/list refresh, one retry

    func test_toolCall_neg32020_refreshesToolsListOnce_retriesOnce_thenSucceeds() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        let afterInitialList = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: #"[{"name":"t"}]"#, expectedCursorParam: nil)
        try await waitForReady(connection)

        let callTask = Task { await connection.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count >= afterInitialList + 1 }
        let firstCallRequest = try decode(await transport.sentMessages()[afterInitialList])
        XCTAssertEqual(firstCallRequest["method"] as? String, "tools/call")
        let firstCallID = firstCallRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(firstCallID),"error":{"code":-32020,"message":"header mismatch, refresh required"}}"#.utf8))

        let afterRefresh = try await driveToolsListPage(transport, afterMessageCount: afterInitialList + 1, toolsJSON: #"[{"name":"t"}]"#, expectedCursorParam: nil)

        try await waitUntil { await transport.sentMessages().count >= afterRefresh + 1 }
        let retryRequest = try decode(await transport.sentMessages()[afterRefresh])
        XCTAssertEqual(retryRequest["method"] as? String, "tools/call")
        let retryID = retryRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(retryID),"result":{"content":[],"resultType":"complete"}}"#.utf8))

        let outcome = await callTask.value
        guard case .result = outcome else {
            return XCTFail("expected .result after the single -32020 retry succeeded, got \(outcome)")
        }
        await connection.stop()
    }

    func test_toolCall_secondNeg32020_propagatesWithoutFurtherRetry() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        let afterInitialList = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: #"[{"name":"t"}]"#, expectedCursorParam: nil)
        try await waitForReady(connection)

        let callTask = Task { await connection.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count >= afterInitialList + 1 }
        let firstCallRequest = try decode(await transport.sentMessages()[afterInitialList])
        let firstCallID = firstCallRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(firstCallID),"error":{"code":-32020,"message":"header mismatch, refresh required"}}"#.utf8))

        let afterRefresh = try await driveToolsListPage(transport, afterMessageCount: afterInitialList + 1, toolsJSON: #"[{"name":"t"}]"#, expectedCursorParam: nil)

        try await waitUntil { await transport.sentMessages().count >= afterRefresh + 1 }
        let retryRequest = try decode(await transport.sentMessages()[afterRefresh])
        let retryID = retryRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(retryID),"error":{"code":-32020,"message":"header mismatch, refresh required"}}"#.utf8))

        let outcome = await callTask.value
        guard case .protocolError(.serverError(let jsonrpcError)) = outcome else {
            return XCTFail("expected .protocolError(.serverError) after the second -32020, got \(outcome)")
        }
        XCTAssertEqual(jsonrpcError.code, -32020)

        // No further tools/list refresh or tools/call retry after the
        // second -32020.
        try? await waitUntil(timeout: 0.3) { await transport.sentMessages().count > afterRefresh + 1 }
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, afterRefresh + 1)
        await connection.stop()
    }

    // MARK: - tools/list_changed refresh: legacy unsolicited notification

    func test_legacyUnsolicitedToolsListChangedNotification_refreshesTools_andEmitsToolsChanged() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())
        let recorder = await recordEvents(connection)

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        let afterInitialList = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))

        _ = try await driveToolsListPage(transport, afterMessageCount: afterInitialList, toolsJSON: #"[{"name":"new-tool"}]"#, expectedCursorParam: nil)

        try await waitUntil { await connection.tools().map(\.name) == ["new-tool"] }
        try await waitUntil { await recorder.events.contains(.toolsChanged) }
        await connection.stop()
    }

    // MARK: - tools/list_changed refresh: modern subscription-stream notification

    func test_modernSubscriptionStreamToolsListChangedNotification_refreshesTools_andEmitsToolsChanged() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(
            factory: factory,
            clock: ManualMCPClock(),
            handshakeOrder: .discoverFirst,
            knownEra: .modern
        )
        let recorder = await recordEvents(connection)

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterDiscover = try await driveModernDiscover(transport)
        let afterInitialList = try await driveToolsListPage(transport, afterMessageCount: afterDiscover, toolsJSON: "[]", expectedCursorParam: nil)
        _ = try await driveSubscribeAndAcknowledge(transport, afterMessageCount: afterInitialList)
        try await waitForReady(connection)
        let afterSubscribe = afterInitialList + 1

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))

        _ = try await driveToolsListPage(transport, afterMessageCount: afterSubscribe, toolsJSON: #"[{"name":"new-tool"}]"#, expectedCursorParam: nil)

        try await waitUntil { await connection.tools().map(\.name) == ["new-tool"] }
        try await waitUntil { await recorder.events.contains(.toolsChanged) }
        await connection.stop()
    }

    // MARK: - callTool / readResource forward to the client with the same context

    func test_callTool_forwardsProgressTokenFromContext() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        let afterList = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        var context = MCPToolCallContext.none
        context.progress = { _ in }
        let callTask = Task { await connection.callTool(name: "t", arguments: [:], context: context) }
        try await waitUntil { await transport.sentMessages().count >= afterList + 1 }
        let callRequest = try decode(await transport.sentMessages()[afterList])
        let meta = callRequest["params"] as? [String: Any]
        let metaObject = meta?["_meta"] as? [String: Any]
        XCTAssertNotNil(metaObject?["progressToken"], "context.progress != nil must produce a progressToken in _meta")
        let callID = callRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(callID),"result":{"content":[],"resultType":"complete"}}"#.utf8))
        _ = await callTask.value
        await connection.stop()
    }

    func test_readResource_forwardsURIOnly() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        let afterList = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        let readTask = Task { try await connection.readResource(uri: "ui://widget/main.html") }
        try await waitUntil { await transport.sentMessages().count >= afterList + 1 }
        let readRequest = try decode(await transport.sentMessages()[afterList])
        XCTAssertEqual(readRequest["method"] as? String, "resources/read")
        let params = readRequest["params"] as? [String: Any]
        XCTAssertEqual(params?["uri"] as? String, "ui://widget/main.html")
        let readID = readRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(readID),"result":{"contents":[{"uri":"ui://widget/main.html","mimeType":"text/html","text":"<html></html>"}]}}
        """#.utf8))
        let result = try await readTask.value
        XCTAssertEqual(result["contents"]?.arrayValue?.first?["uri"]?.stringValue, "ui://widget/main.html")
        await connection.stop()
    }

    // MARK: - Configuration.client is the only client configuration

    func test_configurationClient_clientInfoAndServerDisplayName_flowToTheUnderlyingClient() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(
            factory: factory,
            clock: ManualMCPClock(),
            presenter: nil,
            configuration: makeConfiguration(serverDisplayName: "My Server")
        )

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await waitUntil { await transport.sentMessages().count >= 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        let clientInfo = (initRequest["params"] as? [String: Any])?["clientInfo"] as? [String: Any]
        XCTAssertEqual(clientInfo?["name"] as? String, "Calyx")
        XCTAssertEqual(clientInfo?["version"] as? String, "1.0")
        await connection.stop()
    }

    func test_legacyServerInitiatedElicitation_reachesPresenterWithConfiguredServerDisplayName() async throws {
        let factory = TransportFactory()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.decline])
        let connection = makeConnection(
            factory: factory,
            clock: ManualMCPClock(),
            presenter: presenter,
            configuration: makeConfiguration(serverDisplayName: "My Server")
        )

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        _ = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":99,"method":"elicitation/create","params":{"message":"Confirm?","requestedSchema":{"type":"object","properties":{}}}}
        """#.utf8))

        try await waitUntil { await MainActor.run { presenter.calls.count } == 1 }
        let request = await MainActor.run { presenter.calls[0] }
        XCTAssertEqual(request.serverContext.displayName, "My Server")
        await connection.stop()
    }

    // MARK: - HTTP 401 during negotiate -> needsAuthorization

    func test_negotiateReceivesHTTP401_entersNeedsAuthorization_withoutFallingBackToDiscover() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await waitUntil { await transport.sentMessages().count >= 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(initRequest["method"] as? String, "initialize")
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 401, message: "unauthorized"))

        try await waitUntil {
            if case .needsAuthorization = await connection.state() { return true }
            return false
        }
        // A 401 must not fall back to server/discover the way 400/404/405 do.
        try? await waitUntil(timeout: 0.3) { await transport.sentMessages().count >= 2 }
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 1)
    }

    // MARK: - HTTP 401 on an in-flight call after ready -> needsAuthorization

    func test_401SignalOnInFlightCall_afterReady_entersNeedsAuthorization() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await driveToReady(transport)
        try await waitForReady(connection)

        let callTask = Task { await connection.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count >= 4 }
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 401, message: "unauthorized"))

        let outcome = await callTask.value
        guard case .protocolError(.transport(let signal)) = outcome else {
            return XCTFail("expected .protocolError(.transport(signal)) for a 401 on an in-flight call, got \(outcome)")
        }
        XCTAssertEqual(signal.httpStatus, 401)

        try await waitUntil {
            if case .needsAuthorization = await connection.state() { return true }
            return false
        }
    }

    // MARK: - needsAuthorization -> authorizing -> connecting/needsAuthorization

    func test_beginAuthorization_fromNeedsAuthorization_entersAuthorizing() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await waitUntil { await transport.sentMessages().count >= 1 }
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 401, message: "unauthorized"))
        try await waitUntil {
            if case .needsAuthorization = await connection.state() { return true }
            return false
        }

        await connection.beginAuthorization()

        try await waitUntil {
            if case .authorizing = await connection.state() { return true }
            return false
        }
    }

    func test_endAuthorizationSucceeded_entersConnecting_thenReady_andCallsTransportFactoryAgain() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let firstTransport = await factory.transports[0]
        try await waitUntil { await firstTransport.sentMessages().count >= 1 }
        await firstTransport.simulateTransportError(MCPTransportSignal(httpStatus: 401, message: "unauthorized"))
        try await waitUntil {
            if case .needsAuthorization = await connection.state() { return true }
            return false
        }
        await connection.beginAuthorization()
        try await waitUntil {
            if case .authorizing = await connection.state() { return true }
            return false
        }

        await connection.endAuthorization(succeeded: true)

        try await waitUntil {
            if case .connecting = await connection.state() { return true }
            return false
        }
        try await waitUntil { await factory.issued.count == 2 }
        let secondTransport = await factory.transports[1]
        try await driveToReady(secondTransport)
        try await waitForReady(connection)
        await connection.stop()
    }

    func test_endAuthorizationFailed_returnsToNeedsAuthorization() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await waitUntil { await transport.sentMessages().count >= 1 }
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 401, message: "unauthorized"))
        try await waitUntil {
            if case .needsAuthorization = await connection.state() { return true }
            return false
        }
        await connection.beginAuthorization()
        try await waitUntil {
            if case .authorizing = await connection.state() { return true }
            return false
        }

        await connection.endAuthorization(succeeded: false)

        try await waitUntil {
            if case .needsAuthorization = await connection.state() { return true }
            return false
        }
        let issuedCount = await factory.issued.count
        XCTAssertEqual(issuedCount, 1, "a failed authorization must not spawn a new transport")
    }

    // MARK: - disable()/enable()

    func test_disable_closesTransport_entersDisabled_andNeverStartsRestarting() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        try await driveToReady(transport)
        try await waitForReady(connection)

        await connection.disable()

        do {
            try await transport.send(Data(), kind: .notification)
            XCTFail("disable() must close the active transport")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }

        try await waitUntil {
            if case .disabled = await connection.state() { return true }
            return false
        }
        try? await waitUntil(timeout: 0.3) { await factory.issued.count > 1 }
        let issuedCount = await factory.issued.count
        XCTAssertEqual(issuedCount, 1, "disable() must never trigger a restart")
        if case .restarting = await connection.state() {
            XCTFail("disable() must never be observed as .restarting")
        }
    }

    func test_enable_fromDisabled_reachesReady() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        try await driveToReady(await factory.transports[0])
        try await waitForReady(connection)

        await connection.disable()
        try await waitUntil {
            if case .disabled = await connection.state() { return true }
            return false
        }

        await connection.enable()

        try await waitUntil { await factory.issued.count == 2 }
        try await driveToReady(await factory.transports[1])
        try await waitForReady(connection)
        await connection.stop()
    }

    // MARK: - -32020 retry carries the refreshed definition's headerMirrors

    func test_toolCall_neg32020Retry_usesRefreshedHeaderMirrors() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        let afterInitialList = try await driveToolsListPage(
            transport,
            afterMessageCount: afterHandshake,
            toolsJSON: #"[{"name":"t","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}}}}]"#,
            expectedCursorParam: nil
        )
        try await waitForReady(connection)

        let callTask = Task { await connection.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentFrames().count >= afterInitialList + 1 }
        let firstFrame = await transport.sentFrames()[afterInitialList]
        XCTAssertEqual(firstFrame.kind, .request(headerMirrors: [MCPHTTPHeaderMirror(headerName: "Region", propertyPath: ["region"])]), "a normal call must also be populated with the cached definition's headerMirrors")
        let firstCallRequest = try decode(firstFrame.data)
        let firstCallID = firstCallRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(firstCallID),"error":{"code":-32020,"message":"header mismatch, refresh required"}}"#.utf8))

        let afterRefresh = try await driveToolsListPage(
            transport,
            afterMessageCount: afterInitialList + 1,
            toolsJSON: #"[{"name":"t","inputSchema":{"type":"object","properties":{"zone":{"type":"string","x-mcp-header":"Zone"}}}}]"#,
            expectedCursorParam: nil
        )

        try await waitUntil { await transport.sentFrames().count >= afterRefresh + 1 }
        let retryFrame = await transport.sentFrames()[afterRefresh]
        XCTAssertEqual(retryFrame.kind, .request(headerMirrors: [MCPHTTPHeaderMirror(headerName: "Zone", propertyPath: ["zone"])]), "the -32020 retry must carry the refreshed definition's headerMirrors, not the stale ones")
        let retryRequest = try decode(retryFrame.data)
        let retryID = retryRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(retryID),"result":{"content":[],"resultType":"complete"}}"#.utf8))

        let outcome = await callTask.value
        guard case .result = outcome else {
            return XCTFail("expected .result after the single -32020 retry succeeded, got \(outcome)")
        }
        await connection.stop()
    }

    // MARK: - The negotiated version reaches the transport

    func test_legacyHandshake_setsTheNegotiatedVersionOnTheTransport_beforeToolsList() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport, protocolVersion: "2025-06-18")
        try await waitUntil { await transport.sentMessages().count >= afterHandshake + 1 }
        let versionsWhenToolsListWasSent = await transport.negotiatedProtocolVersions()
        XCTAssertEqual(versionsWhenToolsListWasSent.last, .v2025_06_18, "the negotiated version is set before tools/list")

        _ = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)
        let versions = await transport.negotiatedProtocolVersions()
        XCTAssertEqual(versions.last, .v2025_06_18)
        await connection.stop()
    }

    func test_modernHandshake_setsTheModernVersionOnTheTransport() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock(), handshakeOrder: .discoverFirst, knownEra: .modern)

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterDiscover = try await driveModernDiscover(transport)
        let afterList = try await driveToolsListPage(transport, afterMessageCount: afterDiscover, toolsJSON: "[]", expectedCursorParam: nil)
        try await driveSubscribeAndAcknowledge(transport, afterMessageCount: afterList)
        try await waitForReady(connection)

        let versions = await transport.negotiatedProtocolVersions()
        XCTAssertEqual(versions.last, .v2026_07_28)
        await connection.stop()
    }

    // MARK: - listResources / listResourceTemplates / listPrompts forward to the client

    func test_listMethods_forwardMethodAndCursor_andReturnTheClientPage() async throws {
        let factory = TransportFactory()
        let connection = makeConnection(factory: factory, clock: ManualMCPClock())

        Task { await connection.start() }
        try await waitUntil { await factory.issued.count == 1 }
        let transport = await factory.transports[0]
        let afterHandshake = try await driveLegacyInitialize(transport)
        var sent = try await driveToolsListPage(transport, afterMessageCount: afterHandshake, toolsJSON: "[]", expectedCursorParam: nil)
        try await waitForReady(connection)

        let cases: [(method: String, itemsKey: String, call: @Sendable () async throws -> (items: [[String: AnyCodable]], nextCursor: String?))] = [
            ("resources/list", "resources", { try await connection.listResources(cursor: "c-1") }),
            ("resources/templates/list", "resourceTemplates", { try await connection.listResourceTemplates(cursor: "c-1") }),
            ("prompts/list", "prompts", { try await connection.listPrompts(cursor: "c-1") }),
        ]
        for testCase in cases {
            let call = testCase.call
            let task = Task { try await call() }
            let baseline = sent
            try await waitUntil { await transport.sentMessages().count >= baseline + 1 }
            let request = try decode(await transport.sentMessages()[baseline])
            XCTAssertEqual(request["method"] as? String, testCase.method)
            XCTAssertEqual((request["params"] as? [String: Any])?["cursor"] as? String, "c-1")
            let id = request["id"] as! Int
            await transport.simulateServerMessage(Data(#"""
            {"jsonrpc":"2.0","id":\#(id),"result":{"\#(testCase.itemsKey)":[{"name":"item-a"}],"nextCursor":"c-2"}}
            """#.utf8))
            let page = try await task.value
            XCTAssertEqual(page.items, [["name": AnyCodable("item-a")]], testCase.method)
            XCTAssertEqual(page.nextCursor, "c-2", testCase.method)
            sent = baseline + 1
        }
        await connection.stop()
    }
}

private extension TransportFactory {
    func setShouldThrow() {
        shouldThrow = true
    }
    func clearShouldThrow() {
        shouldThrow = false
    }
}
