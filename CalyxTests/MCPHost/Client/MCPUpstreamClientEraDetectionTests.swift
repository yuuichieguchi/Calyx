//
//  MCPUpstreamClientEraDetectionTests.swift
//  CalyxTests
//
//  Handshake and era detection (API contract section 3.3): `negotiate`
//  is the single handshake owner. `order` picks the message sequence
//  (`.initializeFirst` for stdio/legacy HTTP+SSE, `.discoverFirst` for
//  Streamable HTTP); `knownEra`, when non-nil, is tried first regardless
//  of `order` and falls back to the normal `order` sequence on failure.
//
//  `.initializeFirst`: `initialize` first; any JSON-RPC error OR a
//  timeout falls back to `server/discover`. A `DiscoverResult` response,
//  OR an `initialize` error `-32022` whose `data.supported` includes
//  "2026-07-28", both mean "modern"; any other outcome of `-32022`
//  falls back to `server/discover` like any other error. Both failing
//  throws `MCPNegotiationError.handshakeFailed`.
//
//  `.discoverFirst`: `server/discover` first; a transport `.error` with
//  HTTP 400/404/405, or a JSON-RPC error, falls back to `initialize`.
//  If `initialize` ALSO comes back as an HTTP 400/404/405 error, this
//  throws `MCPNegotiationError.legacySSERequired` (the supervisor is
//  expected to switch to `LegacySSEMCPTransport` and retry with
//  `.initializeFirst`).
//
//  A legacy result sends `notifications/initialized`; a modern
//  (discover) result never does. `instructions` is preserved on both
//  branches.
//

import XCTest
@testable import Calyx

@MainActor
final class MCPUpstreamClientEraDetectionTests: XCTestCase {

    // MARK: - Helpers

    private func makeClient(transport: InMemoryMCPTransport, clock: MCPClock, requestTimeout: TimeInterval = 5) -> MCPUpstreamClient {
        MCPUpstreamClient(
            transport: transport,
            configuration: MCPUpstreamClient.Configuration(
                clientInfo: MCPImplementation(name: "Calyx", version: "1.0", title: nil, description: nil, websiteUrl: nil),
                requestTimeout: requestTimeout,
                serverDisplayName: "test-server",
                maxMRTRRounds: 8
            ),
            elicitationPresenter: FakeElicitationPresenter(scriptedResponses: []),
            clock: clock
        )
    }

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

    private struct WaitTimedOut: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: - .initializeFirst: initialize succeeds -> legacy, carries clientInfo/capabilities, sends initialized

    func test_negotiate_initializeFirstOrder_initializeSucceeds_detectsLegacy_andSendsInitializedNotification() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }

        let frame = await transport.sentFrames()[0]
        XCTAssertEqual(frame.kind, .request(headerMirrors: []))
        let request = try decode(frame.data)
        XCTAssertEqual(request["method"] as? String, "initialize")
        let params = request["params"] as? [String: Any]
        XCTAssertEqual((params?["clientInfo"] as? [String: Any])?["name"] as? String, "Calyx")

        let declaredCapabilities = try XCTUnwrap(params?["capabilities"] as? [String: Any])
        XCTAssertNil(declaredCapabilities["sampling"], "must never declare sampling")
        XCTAssertNil(declaredCapabilities["roots"], "the legacy handshake never declares roots")
        let elicitation = try XCTUnwrap(declaredCapabilities["elicitation"] as? [String: Any])
        XCTAssertEqual((elicitation["form"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual((elicitation["url"] as? [String: Any])?.isEmpty, true)
        let extensions = declaredCapabilities["extensions"] as? [String: Any]
        let ui = try XCTUnwrap(extensions?["io.modelcontextprotocol/ui"] as? [String: Any])
        XCTAssertEqual(ui["mimeTypes"] as? [String], ["text/html;profile=mcp-app"])

        let id = request["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"},"instructions":"call get_weather"}}
        """#.utf8))

        let result = try await task.value
        guard case .legacy(let version, let initResult) = result else {
            return XCTFail("expected .legacy, got \(result)")
        }
        XCTAssertEqual(version, .v2025_11_25)
        XCTAssertEqual(initResult.protocolVersion, "2025-11-25")
        XCTAssertEqual(initResult.serverInfo.name, "s")
        XCTAssertEqual(initResult.instructions, "call get_weather", "instructions must be kept, not discarded")

        try await waitUntil { await transport.sentMessages().count == 2 }
        let notificationFrame = await transport.sentFrames()[1]
        XCTAssertEqual(notificationFrame.kind, .notification)
        let notification = try decode(notificationFrame.data)
        XCTAssertEqual(notification["method"] as? String, "notifications/initialized")
        XCTAssertNil(notification["id"])
    }

    // MARK: - .initializeFirst: initialize error -> discover -> modern

    func test_negotiate_initializeFirstOrder_initializeErrors_thenDiscoverSucceeds_detectsModern() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(initID),"error":{"code":-32601,"message":"Method not found"}}"#.utf8))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let discoverRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(discoverID),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0,"instructions":"welcome"}}
        """#.utf8))

        let result = try await task.value
        guard case .modern(let discoverResult) = result else {
            return XCTFail("expected .modern, got \(result)")
        }
        XCTAssertEqual(discoverResult.supportedVersions, ["2026-07-28"])
        XCTAssertEqual(discoverResult.instructions, "welcome")

        // A modern (discover) result never sends notifications/initialized.
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 2)
    }

    /// Same as above with a DIFFERENT initialize error code, proving the
    /// discover fallback is not keyed to one specific error code.
    func test_negotiate_initializeFirstOrder_initializeErrorsWithDifferentCode_thenDiscoverSucceeds_detectsModern() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(initID),"error":{"code":-32700,"message":"Parse error"}}"#.utf8))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let discoverRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(discoverID),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}}
        """#.utf8))

        let result = try await task.value
        guard case .modern = result else {
            return XCTFail("expected .modern, got \(result)")
        }
    }

    // MARK: - .initializeFirst: initialize timeout -> discover -> modern

    func test_negotiate_initializeFirstOrder_initializeTimesOut_thenDiscoverSucceeds_detectsModern() async throws {
        let transport = InMemoryMCPTransport()
        let clock = ManualMCPClock()
        let requestTimeout: TimeInterval = 5
        let client = makeClient(transport: transport, clock: clock, requestTimeout: requestTimeout)
        let sleepsBefore = clock.sleepDurations().count
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        // No response is ever simulated for `initialize`. Wait for the
        // handshake timeout's own `clock.sleep(for:)` call to actually
        // register (its threshold is computed from `clock.now()` at call
        // time, so advancing before that call would compute the wrong
        // threshold and never resume) before advancing past it -- this
        // fires the handshake timeout without a real wall-clock wait.
        try await waitUntil { clock.sleepDurations().count > sleepsBefore }
        clock.advance(by: requestTimeout)
        try await waitUntil { await transport.sentMessages().count == 2 }
        let discoverRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(discoverID),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}}
        """#.utf8))

        let result = try await task.value
        guard case .modern = result else {
            return XCTFail("expected .modern, got \(result)")
        }
    }

    // MARK: - .initializeFirst: -32022 with data.supported containing 2026-07-28 -> modern, no discover probe

    func test_negotiate_initializeFirstOrder_dashErrorWithModernSupported_detectsModernWithoutDiscover() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(initID),"error":{"code":-32022,"message":"unsupported","data":{"supported":["2026-07-28"]}}}
        """#.utf8))

        let result = try await task.value
        guard case .modern = result else {
            return XCTFail("expected .modern, got \(result)")
        }
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 1, "no discover probe when -32022 already names a modern supported version")
    }

    /// -32022 whose `data.supported` does NOT include the modern version is
    /// just another handshake error: it falls back to `server/discover`
    /// like any other error code, it does not decide "modern" on its own.
    func test_negotiate_initializeFirstOrder_dashErrorWithoutModernSupported_fallsBackToDiscover() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(initID),"error":{"code":-32022,"message":"unsupported","data":{"supported":["2025-11-25"]}}}
        """#.utf8))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let discoverRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover", "a non-modern -32022 must still fall back to server/discover")
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(discoverID),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}}
        """#.utf8))

        let result = try await task.value
        guard case .modern = result else {
            return XCTFail("expected .modern, got \(result)")
        }
    }

    // MARK: - .initializeFirst: both fail -> handshakeFailed(initialize:discover:)

    func test_negotiate_initializeFirstOrder_bothFail_throwsHandshakeFailedWithBothErrors() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let initRequest = try decode(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(initID),"error":{"code":-32601,"message":"nope"}}"#.utf8))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let discoverRequest = try decode(await transport.sentMessages()[1])
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(discoverID),"error":{"code":-32602,"message":"no discover either"}}"#.utf8))

        do {
            _ = try await task.value
            XCTFail("negotiate must throw when neither initialize nor server/discover succeed")
        } catch let error as MCPNegotiationError {
            XCTAssertEqual(
                error,
                .handshakeFailed(
                    initialize: .serverError(JSONRPCError(code: -32601, message: "nope", data: nil)),
                    discover: .serverError(JSONRPCError(code: -32602, message: "no discover either", data: nil))
                )
            )
        } catch {
            XCTFail("expected MCPNegotiationError.handshakeFailed, got \(error)")
        }
    }

    // MARK: - .discoverFirst: discover succeeds -> modern, no initialize sent

    func test_negotiate_discoverFirstOrder_discoverSucceeds_detectsModern_noInitializeSent() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .discoverFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let discoverRequest = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(discoverID),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}}
        """#.utf8))

        let result = try await task.value
        guard case .modern = result else {
            return XCTFail("expected .modern, got \(result)")
        }
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 1, "no initialize probe when discover succeeds directly")
    }

    // MARK: - .discoverFirst: discover fails with an HTTP-status transport error -> initialize -> legacy

    func test_negotiate_discoverFirstOrder_discoverHTTPErrorFallsBackToInitialize_thenSucceeds_detectsLegacy() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .discoverFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let discoverRequest = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 404, message: "not found"))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let initRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(initRequest["method"] as? String, "initialize", "an HTTP 404 on discover must fall back to initialize")
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(initID),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
        """#.utf8))

        let result = try await task.value
        guard case .legacy(let version, _) = result else {
            return XCTFail("expected .legacy, got \(result)")
        }
        XCTAssertEqual(version, .v2025_11_25)
    }

    // MARK: - .discoverFirst: discover fails with a JSON-RPC error -> initialize -> legacy

    func test_negotiate_discoverFirstOrder_discoverJSONRPCErrorFallsBackToInitialize_thenSucceeds() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .discoverFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let discoverRequest = try decode(await transport.sentMessages()[0])
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(discoverID),"error":{"code":-32601,"message":"Method not found"}}"#.utf8))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let initRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(initRequest["method"] as? String, "initialize", "a JSON-RPC error on discover must also fall back to initialize")
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(initID),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
        """#.utf8))

        let result = try await task.value
        guard case .legacy = result else {
            return XCTFail("expected .legacy, got \(result)")
        }
    }

    // MARK: - .discoverFirst: both discover and initialize come back as HTTP errors -> legacySSERequired

    func test_negotiate_discoverFirstOrder_bothHTTPErrors_throwsLegacySSERequired() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .discoverFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 400, message: "bad request"))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let initRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(initRequest["method"] as? String, "initialize")
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 405, message: "method not allowed"))

        do {
            _ = try await task.value
            XCTFail("negotiate must throw legacySSERequired when both discover and initialize come back as HTTP errors")
        } catch let error as MCPNegotiationError {
            XCTAssertEqual(error, .legacySSERequired)
        } catch {
            XCTFail("expected MCPNegotiationError.legacySSERequired, got \(error)")
        }
    }

    // MARK: - a 401 transport error throws authorizationRequired immediately, in either order, with no fallback

    func test_negotiate_initializeFirstOrder_transportError401_throwsAuthorizationRequiredImmediately() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let signal = MCPTransportSignal(httpStatus: 401, message: "unauthorized", wwwAuthenticate: #"Bearer realm="mcp""#)
        await transport.simulateTransportError(signal)

        do {
            _ = try await task.value
            XCTFail("negotiate must throw authorizationRequired on a 401, not fall back to server/discover")
        } catch let error as MCPNegotiationError {
            XCTAssertEqual(error, .authorizationRequired(signal))
        } catch {
            XCTFail("expected MCPNegotiationError.authorizationRequired, got \(error)")
        }
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 1, "a 401 must not trigger a fallback request")
    }

    func test_negotiate_discoverFirstOrder_transportError401_throwsAuthorizationRequiredImmediately() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .discoverFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let discoverRequest = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(discoverRequest["method"] as? String, "server/discover")
        let signal = MCPTransportSignal(httpStatus: 401, message: "unauthorized", wwwAuthenticate: #"Bearer realm="mcp""#)
        await transport.simulateTransportError(signal)

        do {
            _ = try await task.value
            XCTFail("negotiate must throw authorizationRequired on a 401, not fall back to initialize")
        } catch let error as MCPNegotiationError {
            XCTAssertEqual(error, .authorizationRequired(signal))
        } catch {
            XCTFail("expected MCPNegotiationError.authorizationRequired, got \(error)")
        }
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 1, "a 401 on discover must not trigger a fallback to initialize")
    }

    // MARK: - knownEra: tried first regardless of order, overriding order's normal first message

    func test_negotiate_knownEraLegacy_sendsInitializeFirst_evenUnderDiscoverFirstOrder() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .discoverFirst, knownEra: .legacy(.v2025_11_25)) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let request = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(request["method"] as? String, "initialize", "a known legacy era must be tried first, bypassing .discoverFirst order")
        let params = request["params"] as? [String: Any]
        XCTAssertEqual(params?["protocolVersion"] as? String, "2025-11-25", "the known-era initialize attempt must be sent with the known version")
        let id = request["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
        """#.utf8))

        let result = try await task.value
        guard case .legacy = result else {
            return XCTFail("expected .legacy, got \(result)")
        }
    }

    func test_negotiate_knownEraModern_sendsDiscoverFirst_evenUnderInitializeFirstOrder() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: .modern) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let request = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(request["method"] as? String, "server/discover", "a known modern era must be tried first, bypassing .initializeFirst order")
        let id = request["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(id),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}}
        """#.utf8))

        let result = try await task.value
        guard case .modern = result else {
            return XCTFail("expected .modern, got \(result)")
        }
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, 1, "the known-era attempt succeeding must not also probe initialize")
    }

    // MARK: - knownEra: a failed known-era attempt falls back to the normal order sequence

    func test_negotiate_knownEraFails_fallsBackToNormalOrderSequence() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: .modern) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let knownEraAttempt = try decode(await transport.sentMessages()[0])
        XCTAssertEqual(knownEraAttempt["method"] as? String, "server/discover")
        let discoverID = knownEraAttempt["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(discoverID),"error":{"code":-32601,"message":"gone"}}"#.utf8))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let fallbackRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(fallbackRequest["method"] as? String, "initialize", "a failed known-era attempt must fall back to the normal .initializeFirst sequence")
        let initID = fallbackRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(initID),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
        """#.utf8))

        let result = try await task.value
        guard case .legacy = result else {
            return XCTFail("expected .legacy, got \(result)")
        }
    }

    // MARK: - The transport is given each probe's version before the probe

    func test_negotiate_discoverFirst_discover404_setsModernThenLegacyVersion_beforeInitializeIsSent() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .discoverFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        await transport.simulateTransportError(MCPTransportSignal(httpStatus: 404, message: "not found"))

        try await waitUntil { await transport.sentMessages().count == 2 }
        let initRequest = try decode(await transport.sentMessages()[1])
        XCTAssertEqual(initRequest["method"] as? String, "initialize")
        let log = await transport.negotiatedProtocolVersionLog()
        XCTAssertEqual(log.map(\.version), [.v2026_07_28, .v2025_11_25])
        XCTAssertEqual(log.map(\.sentBefore), [0, 1], "2026-07-28 before server/discover, 2025-11-25 before initialize")

        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(initID),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
        """#.utf8))
        _ = try await task.value
        try await waitUntil { await transport.sentMessages().count == 3 }
        let finalLog = await transport.negotiatedProtocolVersionLog()
        XCTAssertEqual(finalLog.last?.version, .v2025_06_18, "the negotiated version is set once the era is decided")
        XCTAssertEqual(finalLog.last?.sentBefore, 2, "before notifications/initialized is sent")
    }

    func test_negotiate_initializeFirst_legacySuccess_setsLegacyVersion_beforeTheFirstFrame() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, clock: ManualMCPClock())
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let firstLog = await transport.negotiatedProtocolVersionLog()
        XCTAssertEqual(firstLog.first?.version, .v2025_11_25)
        XCTAssertEqual(firstLog.first?.sentBefore, 0, "the version is set before the first frame")

        let request = try decode(await transport.sentMessages()[0])
        let id = request["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
        """#.utf8))
        _ = try await task.value
        let versions = await transport.negotiatedProtocolVersions()
        XCTAssertEqual(versions, [.v2025_11_25, .v2025_11_25])
    }
}
