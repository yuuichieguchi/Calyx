//
//  MCPUpstreamClientTests.swift
//  CalyxTests
//
//  `MCPUpstreamClient` is an actor that speaks JSON-RPC 2.0 over an
//  `MCPMessageTransport` (here: `InMemoryMCPTransport`) with an injectable
//  clock (`ManualMCPClock`) so timeout tests never sleep on the wall
//  clock.
//
//  `negotiate(order:knownEra:)` is the single handshake owner (API
//  contract section 3.3); every test that calls `callTool` or exercises a
//  server-initiated request first drives a handshake to completion with
//  `negotiateLegacy`/`negotiateModern` below.
//
//  Cancellation: the client never encodes a `notifications/cancelled`
//  JSON-RPC frame itself. Both a request timeout and Swift `Task`
//  cancellation resolve by calling `transport.cancel(requestID:reason:)`
//  -- how that becomes wire traffic is the transport's decision.
//

import XCTest
@testable import Calyx

/// Records every progress update delivered to a `context.progress` handler.
private actor ProgressRecorder {
    private(set) var updates: [MCPProgressUpdate] = []
    func record(_ update: MCPProgressUpdate) { updates.append(update) }
}

/// Records every event delivered on `client.serverEvents`, in order.
private actor ServerEventRecorder {
    private(set) var events: [MCPClientServerEvent] = []
    func record(_ event: MCPClientServerEvent) { events.append(event) }
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class MCPUpstreamClientTests: XCTestCase {

    // MARK: - Helpers

    private func makeClient(
        transport: InMemoryMCPTransport,
        presenter: MCPElicitationPresenting,
        clock: MCPClock,
        requestTimeout: TimeInterval = 30,
        maxMRTRRounds: Int = 8
    ) -> MCPUpstreamClient {
        MCPUpstreamClient(
            transport: transport,
            configuration: MCPUpstreamClient.Configuration(
                clientInfo: MCPImplementation(name: "Calyx", version: "1.0", title: nil, description: nil, websiteUrl: nil),
                requestTimeout: requestTimeout,
                serverDisplayName: "test-server",
                maxMRTRRounds: maxMRTRRounds
            ),
            elicitationPresenter: presenter,
            clock: clock
        )
    }

    private func decodeSent(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func respondSuccess(_ transport: InMemoryMCPTransport, id: Any, resultJSON: String) async {
        let idLiteral: String
        if let intID = id as? Int { idLiteral = "\(intID)" } else { idLiteral = "\"\(id)\"" }
        let json = #"{"jsonrpc":"2.0","id":\#(idLiteral),"result":\#(resultJSON)}"#
        await transport.simulateServerMessage(Data(json.utf8))
    }

    /// Drives a full legacy handshake to completion so a test can go
    /// straight to `callTool`/server-initiated behavior, then returns how
    /// many messages the handshake itself put on the wire (2: `initialize`
    /// + `notifications/initialized`). `InMemoryMCPTransport.sentMessages()`
    /// only grows, so every subsequent assertion in a test must index and
    /// count from this baseline, never from 0/1.
    @discardableResult
    private func negotiateLegacy(_ client: MCPUpstreamClient, transport: InMemoryMCPTransport, protocolVersion: String = "2025-11-25") async throws -> Int {
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let initRequest = try decodeSent(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(initID),"result":{"protocolVersion":"\#(protocolVersion)","capabilities":{},"serverInfo":{"name":"s","version":"1"}}}
        """#.utf8))
        _ = try await task.value
        try await waitUntil { await transport.sentMessages().count == 2 }
        return 2
    }

    /// Drives a full modern handshake to completion (initialize errors,
    /// then server/discover succeeds), returning the handshake message
    /// count (2) the same way `negotiateLegacy` does.
    @discardableResult
    private func negotiateModern(_ client: MCPUpstreamClient, transport: InMemoryMCPTransport) async throws -> Int {
        let task = Task { try await client.negotiate(order: .initializeFirst, knownEra: nil) }
        try await waitUntil { await transport.sentMessages().count == 1 }
        let initRequest = try decodeSent(await transport.sentMessages()[0])
        let initID = initRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":\#(initID),"error":{"code":-32601,"message":"nope"}}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == 2 }
        let discoverRequest = try decodeSent(await transport.sentMessages()[1])
        let discoverID = discoverRequest["id"] as! Int
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":\#(discoverID),"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}}
        """#.utf8))
        _ = try await task.value
        return 2
    }

    // MARK: - id correlation

    func test_callTool_correlatesResponseByIntegerId() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "get_weather", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let id = sent["id"]!

        await respondSuccess(transport, id: id as! Int, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        let outcome = await task.value
        guard case .result(let result) = outcome else {
            return XCTFail("expected .result, got \(outcome)")
        }
        XCTAssertEqual(result.raw["resultType"]?.stringValue, "complete")
    }

    /// `0` is a valid JSON-RPC id and must round-trip through id
    /// correlation like any other id (API contract decision, section 15).
    func test_serverInitiatedPing_withIdZero_respondsWithIdZero() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":0,"method":"ping"}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let response = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(response["id"] as? Int, 0, "id 0 must not be treated as missing")
    }

    // MARK: - timeout cancels via the transport, never a hand-rolled frame

    func test_callTool_timeout_cancelsRequestOnTransport() async throws {
        let transport = InMemoryMCPTransport()
        let clock = ManualMCPClock()
        let requestTimeout: TimeInterval = 5
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: clock, requestTimeout: requestTimeout)
        let baseline = try await negotiateModern(client, transport: transport)

        let sleepsBefore = clock.sleepDurations().count
        let task = Task { await client.callTool(name: "slow_tool", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let id = sent["id"] as! Int

        // `clock.sleep(for:)` computes its wake threshold from `clock.now()`
        // at the moment it is called, so advancing before that call would
        // compute the wrong threshold and never resume. Wait for the
        // timeout's own sleep to actually register first.
        try await waitUntil { clock.sleepDurations().count > sleepsBefore }
        clock.advance(by: requestTimeout)
        let outcome = await task.value
        guard case .protocolError(let error) = outcome else {
            return XCTFail("expected timeout to surface as a protocol error outcome, got \(outcome)")
        }
        XCTAssertEqual(error, .timeout)

        let cancelled = await transport.cancelledRequestIDs()
        XCTAssertEqual(cancelled, [.int(id)])
        // No `notifications/cancelled` frame is ever sent by the client itself.
        let sentMethods = try await transport.sentMessages().map(decodeSent).compactMap { $0["method"] as? String }
        XCTAssertFalse(sentMethods.contains("notifications/cancelled"))
    }

    // MARK: - cancellation of the awaiting task cancels via the transport

    func test_callTool_swiftTaskCancellation_cancelsRequestOnTransport() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock(), requestTimeout: 300)
        let baseline = try await negotiateLegacy(client, transport: transport)

        let task = Task { await client.callTool(name: "slow_tool", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let id = sent["id"] as! Int
        task.cancel()

        let outcome = await task.value
        guard case .cancelled(let reason) = outcome else {
            return XCTFail("expected .cancelled outcome, got \(outcome)")
        }
        XCTAssertEqual(reason, .agentCancelled)

        let cancelled = await transport.cancelledRequestIDs()
        XCTAssertEqual(cancelled, [.int(id)])
    }

    // MARK: - a transport that closes mid-call fails every in-flight call,
    // and later calls return the same failure without sending anything

    func test_callTool_transportClosesMidCall_failsWithTransportClosedReason() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        let task = Task { await client.callTool(name: "slow_tool", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        await transport.simulateCrash(reason: "child exited")

        let outcome = await task.value
        guard case .protocolError(let error) = outcome else {
            return XCTFail("expected a protocol error outcome when the transport closes mid-call, got \(outcome)")
        }
        XCTAssertEqual(error, .transportClosed(reason: "child exited"))
    }

    func test_callTool_afterTransportClosed_returnsTransportClosedWithoutSendingAnything() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        let firstTask = Task { await client.callTool(name: "slow_tool", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        await transport.simulateCrash(reason: "child exited")
        _ = await firstTask.value

        // `InMemoryMCPTransport.send` throws `.closed` once closed rather
        // than recording the payload, so a client that still attempted to
        // send would only ever observe `MCPTransportError.closed`, never
        // the original crash reason. The exact `.transportClosed(reason:)`
        // equality below is the discriminator that proves the client
        // remembers and returns the original failure, not a fresh one.
        let outcome = await client.callTool(name: "another_tool", arguments: [:], context: .none)
        guard case .protocolError(let error) = outcome else {
            return XCTFail("expected a protocol error outcome for a call made after the transport closed, got \(outcome)")
        }
        XCTAssertEqual(error, .transportClosed(reason: "child exited"))
    }

    // MARK: - modern _meta injected on every request

    func test_modernEra_injectsMetaOnEveryRequest() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "get_weather", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let meta = sent["params"] as? [String: Any]
        let metaObject = meta?["_meta"] as? [String: Any]
        XCTAssertEqual(metaObject?["io.modelcontextprotocol/protocolVersion"] as? String, "2026-07-28")
        let capabilities = metaObject?["io.modelcontextprotocol/clientCapabilities"] as? [String: Any]
        let extensions = capabilities?["extensions"] as? [String: Any]
        let ui = extensions?["io.modelcontextprotocol/ui"] as? [String: Any]
        XCTAssertEqual(ui?["mimeTypes"] as? [String], ["text/html;profile=mcp-app"])
        XCTAssertNotNil(metaObject?["io.modelcontextprotocol/clientInfo"])
        XCTAssertNil(capabilities?["sampling"], "must never declare sampling, modern era included")
        let elicitation = capabilities?["elicitation"] as? [String: Any]
        XCTAssertEqual((elicitation?["form"] as? [String: Any])?.isEmpty, true)
        XCTAssertEqual((elicitation?["url"] as? [String: Any])?.isEmpty, true)

        let id = sent["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    // MARK: - legacy server-initiated ping

    func test_legacyEra_answersServerPingWithEmptyResult() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":99,"method":"ping"}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let response = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(response["id"] as? Int, 99)
        XCTAssertEqual((response["result"] as? [String: Any])?.isEmpty, true)
    }

    // MARK: - legacy sampling/createMessage -> -32601 (not declared)

    func test_legacyEra_answersSamplingCreateMessageWithMethodNotFound() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":7,"method":"sampling/createMessage","params":{}}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let response = try decodeSent(await transport.sentMessages()[baseline])
        let error = response["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }

    // MARK: - legacy roots/list -> -32601 (never declared as a server-initiated capability)

    func test_legacyEra_answersRootsListWithMethodNotFound() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":8,"method":"roots/list"}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let response = try decodeSent(await transport.sentMessages()[baseline])
        let error = response["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
    }

    // MARK: - elicitation routed to injected presenter (legacy elicitation/create)

    func test_elicitationRequest_isRoutedToInjectedPresenter() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.accept(content: ["answer": AnyCodable("yes")])])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":10,"method":"elicitation/create","params":{"message":"Enter a value","requestedSchema":{"type":"object","properties":{}}}}
        """#.utf8))
        try await waitUntil { await presenter.calls.count == 1 }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let call = presenter.calls[0]
        guard case .form(let message, _) = call.mode else {
            return XCTFail("expected .form mode for a legacy elicitation/create, got \(call.mode)")
        }
        XCTAssertEqual(message, "Enter a value")
        XCTAssertEqual(call.serverContext.displayName, "test-server")
        let response = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(response["id"] as? Int, 10)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "accept", "the legacy ElicitResult shape mirrors the presenter's decision verbatim")
        XCTAssertEqual((result["content"] as? [String: Any])?["answer"] as? String, "yes")
    }

    func test_elicitationRequest_declined_answersWithDeclineAction() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.decline])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":11,"method":"elicitation/create","params":{"message":"Enter a value","requestedSchema":{"type":"object","properties":{}}}}
        """#.utf8))
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let response = try decodeSent(await transport.sentMessages()[baseline])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "decline")
        XCTAssertNil(result["content"])
    }

    func test_elicitationRequest_urlMode_isRoutedToPresenterWithURLPayload() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.decline])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":12,"method":"elicitation/create","params":{"mode":"url","message":"Sign in to continue","url":"https://example.com/authorize","elicitationId":"e1"}}
        """#.utf8))
        try await waitUntil { await presenter.calls.count == 1 }
        let call = presenter.calls[0]
        guard case .url(let message, let url) = call.mode else {
            return XCTFail("expected .url mode, got \(call.mode)")
        }
        XCTAssertEqual(message, "Sign in to continue")
        XCTAssertEqual(url, "https://example.com/authorize")
    }

    /// The URL-mode `elicitationId` (2025-11-25) is not exposed on
    /// `MCPElicitationRequest.Mode.url` -- the client keeps an internal
    /// `elicitationId -> MCPElicitationID` table (section 1.5) and uses
    /// it to dismiss the matching presentation when
    /// `notifications/elicitation/complete` names that same id.
    func test_urlModeElicitation_completeNotification_dismissesTheMatchingPresentation() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.accept(content: [:])])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":13,"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/authorize","elicitationId":"e-complete"}}
        """#.utf8))
        try await waitUntil { await presenter.calls.count == 1 }
        let presentedID = presenter.calls[0].id

        // §1.5: `content` is present on the ElicitResult wire shape only
        // for action == "accept" AND mode == "form" -- an accepted URL-mode
        // elicitation must not carry a `content` key.
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let urlResponse = try decodeSent(await transport.sentMessages()[baseline])
        let urlResult = try XCTUnwrap(urlResponse["result"] as? [String: Any])
        XCTAssertEqual(urlResult["action"] as? String, "accept")
        XCTAssertNil(urlResult["content"], "content is only present for accept + form mode")

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"e-complete"}}"#.utf8))
        try await waitUntil { await presenter.dismissedIDs.count == 1 }
        XCTAssertEqual(presenter.dismissedIDs, [presentedID])

        // A second, identical completion notification must not dismiss
        // again: the correlation entry is removed once consumed. A
        // server-initiated `ping` is answered only after every message
        // ahead of it in the actor's single receive loop has been
        // processed, so waiting for its reply is an ordering barrier that
        // proves the second notification was handled without sleeping for
        // synchronization.
        let countBeforePing = await transport.sentMessages().count
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"e-complete"}}"#.utf8))
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":"barrier-1","method":"ping"}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == countBeforePing + 1 }
        XCTAssertEqual(presenter.dismissedIDs.count, 1, "an already-consumed elicitationId must not dismiss twice")
    }

    /// An unknown elicitationId in the completion notification is ignored.
    func test_urlModeElicitation_completeNotification_withUnknownId_isIgnored() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.accept(content: [:])])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":14,"method":"elicitation/create","params":{"mode":"url","message":"Sign in","url":"https://example.com/authorize","elicitationId":"e-known"}}
        """#.utf8))
        try await waitUntil { await presenter.calls.count == 1 }

        let countBeforePing = await transport.sentMessages().count
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"e-unrelated"}}"#.utf8))
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":"barrier-2","method":"ping"}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == countBeforePing + 1 }
        XCTAssertEqual(presenter.dismissedIDs.count, 0)
    }

    // MARK: - MRTR: input_required retries with a new id, verbatim state
    //
    // `inputRequests` entries are shaped per the 2026-07-28 schema's
    // `InputRequest` (anyOf CreateMessageRequest / ListRootsRequest /
    // ElicitRequest): `{"method": "elicitation/create"|"roots/list"|
    // "sampling/createMessage", "params": {...}}`.

    func test_mrtr_inputRequired_retriesWithNewIdAndVerbatimRequestStateAndResponses() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.accept(content: ["value": AnyCodable("filled")])])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "needs_input", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let firstRequest = try decodeSent(await transport.sentMessages()[baseline])
        let firstID = firstRequest["id"] as! Int

        await respondSuccess(
            transport,
            id: firstID,
            resultJSON: #"{"resultType":"input_required","requestState":"opaque-state-1","inputRequests":{"field-1":{"method":"elicitation/create","params":{"message":"fill me","requestedSchema":{"type":"object","properties":{}}}}}}"#
        )

        try await waitUntil { await transport.sentMessages().count == baseline + 2 }
        let secondRequest = try decodeSent(await transport.sentMessages()[baseline + 1])
        XCTAssertEqual(secondRequest["method"] as? String, "tools/call")
        let secondID = secondRequest["id"] as! Int
        XCTAssertNotEqual(secondID, firstID, "MRTR retry must use a NEW request id")
        let secondParams = secondRequest["params"] as? [String: Any]
        XCTAssertEqual(secondParams?["requestState"] as? String, "opaque-state-1", "requestState must be carried verbatim")
        let inputResponses = secondParams?["inputResponses"] as? [String: Any]
        let fieldResponse = try XCTUnwrap(inputResponses?["field-1"] as? [String: Any])
        XCTAssertEqual(fieldResponse["action"] as? String, "accept",
            "each elicitation MRTR inputResponses entry mirrors the legacy ElicitResult wire shape: {action, content?}")
        XCTAssertEqual((fieldResponse["content"] as? [String: Any])?["value"] as? String, "filled")

        await respondSuccess(transport, id: secondID, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        let outcome = await task.value
        guard case .result = outcome else {
            return XCTFail("expected .result after MRTR retry completes, got \(outcome)")
        }
    }

    func test_mrtr_inputRequired_declinedEntry_reportsDeclineActionWithNoContent() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.decline])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "needs_input", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let firstID = try decodeSent(await transport.sentMessages()[baseline])["id"] as! Int
        await respondSuccess(
            transport, id: firstID,
            resultJSON: #"{"resultType":"input_required","requestState":"s1","inputRequests":{"field-1":{"method":"elicitation/create","params":{"message":"fill me","requestedSchema":{"type":"object","properties":{}}}}}}"#
        )

        try await waitUntil { await transport.sentMessages().count == baseline + 2 }
        let secondParams = try decodeSent(await transport.sentMessages()[baseline + 1])["params"] as? [String: Any]
        let inputResponses = secondParams?["inputResponses"] as? [String: Any]
        let fieldResponse = try XCTUnwrap(inputResponses?["field-1"] as? [String: Any])
        XCTAssertEqual(fieldResponse["action"] as? String, "decline")
        XCTAssertNil(fieldResponse["content"])

        let secondID = try decodeSent(await transport.sentMessages()[baseline + 1])["id"] as! Int
        await respondSuccess(transport, id: secondID, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    /// Counting rule (contract section 3.3): the initial `tools/call` is
    /// not itself a round. Every resend triggered by an `input_required`
    /// response counts as one round. With `maxMRTRRounds == 8`, 8 resends
    /// are allowed (9 requests on the wire total: 1 initial + 8 resends);
    /// the 9th `input_required` response -- to the 8th resend -- is the
    /// one that exceeds the cap and must not trigger a 10th request.
    /// `waitUntil`'s bounded timeout catches "too few resends" (the loop
    /// itself fails to observe a resend and throws). A watchdog on
    /// `task.value` separately catches "one too many": if the
    /// implementation sends a 10th request on the 9th `input_required`,
    /// the loop above finishes cleanly with no response ever given to
    /// that 10th request, and `await task.value` would otherwise hang
    /// forever on the default `requestTimeout` with a clock that is
    /// never advanced. The watchdog cancels the task after a bounded
    /// wall-clock wait so a wrong implementation fails as `.cancelled`
    /// instead of hanging the test.
    func test_mrtr_exceedingMaxRoundsProducesAnError() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: (0..<10).map { .accept(content: ["f": AnyCodable("v\($0)")]) })
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock(), maxMRTRRounds: 8)
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "never_completes", arguments: [:], context: .none) }

        // 9 responses total: the initial call's response, then 8 resends'
        // responses. Only the first 8 of those 9 trigger another resend.
        for round in 0..<9 {
            try await waitUntil { await transport.sentMessages().count == baseline + round + 1 }
            let request = try decodeSent(await transport.sentMessages()[baseline + round])
            let id = request["id"] as! Int
            await respondSuccess(
                transport,
                id: id,
                resultJSON: #"{"resultType":"input_required","requestState":"state-\#(round)","inputRequests":{"f":{"method":"elicitation/create","params":{"message":"m","requestedSchema":{"type":"object","properties":{}}}}}}"#
            )
        }

        let watchdog = Task { [task] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            task.cancel()
        }
        let outcome = await task.value
        watchdog.cancel()
        guard case .protocolError(let error) = outcome else {
            return XCTFail("expected a protocol error after exceeding maxMRTRRounds, got \(outcome)")
        }
        XCTAssertEqual(error, .mrtrRoundLimitExceeded)
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, baseline + 9, "must not send a 10th request (1 initial + 8 resends is the cap)")
    }

    // MARK: - sampling input request -> isError result (Calyx never presents a sampling UI)

    func test_samplingInputRequest_surfacesAsIsErrorResult() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "wants_sampling", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let request = try decodeSent(await transport.sentMessages()[baseline])
        let id = request["id"] as! Int
        await respondSuccess(
            transport,
            id: id,
            resultJSON: #"{"resultType":"input_required","inputRequests":{"s":{"method":"sampling/createMessage","params":{}}}}"#
        )

        let outcome = await task.value
        guard case .result(let result) = outcome else {
            return XCTFail("expected an isError .result since Calyx does not provide sampling, got \(outcome)")
        }
        XCTAssertEqual(result.raw["isError"]?.boolValue, true)
        XCTAssertEqual(presenter.calls.count, 0, "sampling is never presented")
        let sentCount = await transport.sentMessages().count
        XCTAssertEqual(sentCount, baseline + 1, "a sampling-only input request is never retried")
    }

    // MARK: - roots: modern era only, per-request capability presence, only with a known cwd

    func test_modernEra_withCwd_declaresRootsCapability() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let cwd = URL(fileURLWithPath: "/Users/dev/project", isDirectory: false)
        let task = Task { await client.callTool(name: "t", arguments: [:], context: MCPToolCallContext(cwd: cwd, progress: nil)) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let meta = (sent["params"] as? [String: Any])?["_meta"] as? [String: Any]
        let capabilities = meta?["io.modelcontextprotocol/clientCapabilities"] as? [String: Any]
        XCTAssertNotNil(capabilities?["roots"], "roots capability declared per-request when cwd is known")

        let id = sent["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    func test_modernEra_withoutCwd_declaresNoRootsCapability() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let meta = (sent["params"] as? [String: Any])?["_meta"] as? [String: Any]
        let capabilities = meta?["io.modelcontextprotocol/clientCapabilities"] as? [String: Any]
        XCTAssertNil(capabilities?["roots"])

        let id = sent["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    func test_legacyEra_neverDeclaresRootsEvenWithCwd() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        let task = Task { await client.callTool(name: "t", arguments: [:], context: MCPToolCallContext(cwd: URL(fileURLWithPath: "/tmp", isDirectory: true), progress: nil)) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let params = sent["params"] as? [String: Any]
        XCTAssertNil(params?["_meta"], "legacy requests carry no per-request _meta injection at all")

        let id = sent["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    /// A server-initiated MRTR `roots/list` input request is answered with
    /// the actual root list, NOT the `{action, content?}` elicitation shape
    /// -- it is not an elicitation and the presenter is never called.
    func test_mrtr_rootsListInputRequest_answeredWithCwdRootDirectly() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let cwd = URL(fileURLWithPath: "/Users/dev/project", isDirectory: false)
        let task = Task { await client.callTool(name: "needs_roots", arguments: [:], context: MCPToolCallContext(cwd: cwd, progress: nil)) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let firstID = try decodeSent(await transport.sentMessages()[baseline])["id"] as! Int
        await respondSuccess(
            transport, id: firstID,
            resultJSON: #"{"resultType":"input_required","requestState":"s1","inputRequests":{"r":{"method":"roots/list","params":{}}}}"#
        )

        try await waitUntil { await transport.sentMessages().count == baseline + 2 }
        let secondParams = try decodeSent(await transport.sentMessages()[baseline + 1])["params"] as? [String: Any]
        let inputResponses = secondParams?["inputResponses"] as? [String: Any]
        let rootsResponse = try XCTUnwrap(inputResponses?["r"] as? [String: Any])
        let roots = try XCTUnwrap(rootsResponse["roots"] as? [[String: Any]])
        XCTAssertEqual(roots.first?["uri"] as? String, "file:///Users/dev/project")
        XCTAssertEqual(presenter.calls.count, 0, "roots/list is answered directly, never presented to the user")

        let secondID = try decodeSent(await transport.sentMessages()[baseline + 1])["id"] as! Int
        await respondSuccess(transport, id: secondID, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    /// When `context.cwd` is nil, a server-initiated `roots/list` MRTR
    /// entry is left unanswered: the resend must not include a
    /// `roots/list` entry key in `inputResponses` while still answering
    /// the sibling elicitation entry in the same round.
    func test_mrtr_rootsListInputRequest_withoutCwd_isLeftUnanswered() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.accept(content: ["value": AnyCodable("v")])])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "needs_roots", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let firstID = try decodeSent(await transport.sentMessages()[baseline])["id"] as! Int
        await respondSuccess(
            transport, id: firstID,
            resultJSON: #"{"resultType":"input_required","requestState":"s1","inputRequests":{"r":{"method":"roots/list","params":{}},"e":{"method":"elicitation/create","params":{"message":"m","requestedSchema":{"type":"object","properties":{}}}}}}"#
        )

        try await waitUntil { await transport.sentMessages().count == baseline + 2 }
        let secondParams = try decodeSent(await transport.sentMessages()[baseline + 1])["params"] as? [String: Any]
        let inputResponses = secondParams?["inputResponses"] as? [String: Any]
        XCTAssertNil(inputResponses?["r"], "no cwd means the roots/list entry is not answered")
        XCTAssertNotNil(inputResponses?["e"], "the sibling elicitation entry is still answered")

        let secondID = try decodeSent(await transport.sentMessages()[baseline + 1])["id"] as! Int
        await respondSuccess(transport, id: secondID, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    // MARK: - progress: `params._meta.progressToken` injected only when a handler is set, both eras
    //
    // The legacy era carries no other `_meta` key -- no protocolVersion,
    // no clientCapabilities, no clientInfo -- only `progressToken` when a
    // progress handler is set.

    func test_progressHandler_injectsTokenAndRoutesNotificationsToTheHandler() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let recorder = ProgressRecorder()
        let context = MCPToolCallContext(cwd: nil, progress: { update in await recorder.record(update) })
        let task = Task { await client.callTool(name: "long_task", arguments: [:], context: context) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let meta = (sent["params"] as? [String: Any])?["_meta"] as? [String: Any]
        let token = try XCTUnwrap(meta?["progressToken"])
        let id = sent["id"] as! Int

        let tokenLiteral = (token as? Int).map { "\($0)" } ?? "\"\(token)\""
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.5,"progressToken":\#(tokenLiteral),"total":1,"message":"halfway"}}
        """#.utf8))
        try await waitUntil { await recorder.updates.count == 1 }
        let update = await recorder.updates[0]
        XCTAssertEqual(update.progress, 0.5)
        XCTAssertEqual(update.total, 1)
        XCTAssertEqual(update.message, "halfway")

        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    func test_noProgressHandler_omitsProgressToken() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let meta = (sent["params"] as? [String: Any])?["_meta"] as? [String: Any]
        XCTAssertNil(meta?["progressToken"])

        let id = sent["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    /// The legacy era never carries the three `io.modelcontextprotocol/*`
    /// keys, but it does carry `params._meta.progressToken` when a
    /// progress handler is set -- and nothing else in `_meta`.
    func test_legacyEra_progressHandler_injectsTokenOnly() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        let context = MCPToolCallContext(cwd: nil, progress: { _ in })
        let task = Task { await client.callTool(name: "long_task", arguments: [:], context: context) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let sent = try decodeSent(await transport.sentMessages()[baseline])
        let params = sent["params"] as? [String: Any]
        let meta = try XCTUnwrap(params?["_meta"] as? [String: Any])
        XCTAssertNotNil(meta["progressToken"])
        XCTAssertEqual(meta.keys.count, 1, "legacy _meta must carry only progressToken, none of the io.modelcontextprotocol/* keys")

        let id = sent["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    // MARK: - surfaceID: copied verbatim from MCPToolCallContext into a presented MCPElicitationRequest

    func test_surfaceID_propagatesToElicitationRequest() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.accept(content: ["value": AnyCodable("filled")])])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)
        let surfaceID = UUID()

        let task = Task { await client.callTool(name: "needs_signin", arguments: [:], context: MCPToolCallContext(surfaceID: surfaceID, cwd: nil, progress: nil)) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let firstID = try decodeSent(await transport.sentMessages()[baseline])["id"] as! Int
        await respondSuccess(
            transport, id: firstID,
            resultJSON: #"{"resultType":"input_required","requestState":"s1","inputRequests":{"e":{"method":"elicitation/create","params":{"message":"m","requestedSchema":{"type":"object","properties":{}}}}}}"#
        )
        try await waitUntil { await presenter.calls.count == 1 }
        XCTAssertEqual(presenter.calls[0].surfaceID, surfaceID)

        try await waitUntil { await transport.sentMessages().count == baseline + 2 }
        let secondID = try decodeSent(await transport.sentMessages()[baseline + 1])["id"] as! Int
        await respondSuccess(transport, id: secondID, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    // MARK: - listTools(cursor:) returns one page, forwarding the cursor

    func test_listTools_returnsOnePageWithNextCursor() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { try await client.listTools(cursor: nil) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let request = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "tools/list")
        let id = request["id"] as! Int
        await respondSuccess(
            transport, id: id,
            resultJSON: #"{"tools":[{"name":"get_weather","inputSchema":{"type":"object","properties":{}}}],"nextCursor":"page-2"}"#
        )

        let (tools, nextCursor) = try await task.value
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.name, "get_weather")
        XCTAssertEqual(nextCursor, "page-2")
    }

    func test_listTools_forwardsTheGivenCursor() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { try await client.listTools(cursor: "page-2") }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let request = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual((request["params"] as? [String: Any])?["cursor"] as? String, "page-2")
        let id = request["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"tools":[]}"#)

        let (tools, nextCursor) = try await task.value
        XCTAssertEqual(tools.count, 0)
        XCTAssertNil(nextCursor, "a response with no nextCursor key means there is no next page")
    }

    // MARK: - readResource(uri:) returns the raw resources/read result dictionary

    func test_readResource_returnsRawResultDictionary() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { try await client.readResource(uri: "ui://widget/main.html") }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let request = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "resources/read")
        XCTAssertEqual((request["params"] as? [String: Any])?["uri"] as? String, "ui://widget/main.html")
        let id = request["id"] as! Int
        await respondSuccess(
            transport, id: id,
            resultJSON: #"{"contents":[{"uri":"ui://widget/main.html","mimeType":"text/html","text":"<html></html>"}]}"#
        )

        let result = try await task.value
        let contents = result["contents"]?.arrayValue
        XCTAssertEqual(contents?.count, 1)
        XCTAssertEqual(contents?.first?["mimeType"]?.stringValue, "text/html")
        XCTAssertEqual(contents?.first?["uri"]?.stringValue, "ui://widget/main.html")
    }

    // MARK: - resources/list, resources/templates/list, prompts/list return one raw page

    func test_listResources_sendsResourcesList_forwardsCursor_returnsRawItemsAndNextCursor() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { try await client.listResources(cursor: "page-2") }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let request = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "resources/list")
        XCTAssertEqual((request["params"] as? [String: Any])?["cursor"] as? String, "page-2")
        let id = request["id"] as! Int
        await respondSuccess(
            transport, id: id,
            resultJSON: #"{"resources":[{"uri":"file:///notes.md","name":"notes","x-extra":7}],"nextCursor":"page-3"}"#
        )

        let (items, nextCursor) = try await task.value
        XCTAssertEqual(items, [[
            "uri": AnyCodable("file:///notes.md"),
            "name": AnyCodable("notes"),
            "x-extra": AnyCodable(7),
        ]])
        XCTAssertEqual(nextCursor, "page-3")
    }

    func test_listResourceTemplates_sendsResourcesTemplatesList_forwardsCursor_returnsRawItemsAndNextCursor() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { try await client.listResourceTemplates(cursor: "page-2") }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let request = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "resources/templates/list")
        XCTAssertEqual((request["params"] as? [String: Any])?["cursor"] as? String, "page-2")
        let id = request["id"] as! Int
        await respondSuccess(
            transport, id: id,
            resultJSON: #"{"resourceTemplates":[{"uriTemplate":"file:///{path}","name":"files"}]}"#
        )

        let (items, nextCursor) = try await task.value
        XCTAssertEqual(items, [[
            "uriTemplate": AnyCodable("file:///{path}"),
            "name": AnyCodable("files"),
        ]])
        XCTAssertNil(nextCursor, "a response with no nextCursor key means there is no next page")
    }

    func test_listPrompts_sendsPromptsList_withoutCursorWhenNil_returnsRawItemsAndNextCursor() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { try await client.listPrompts(cursor: nil) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let request = try decodeSent(await transport.sentMessages()[baseline])
        XCTAssertEqual(request["method"] as? String, "prompts/list")
        XCTAssertNil((request["params"] as? [String: Any])?["cursor"], "a nil cursor is not sent")
        let id = request["id"] as! Int
        await respondSuccess(
            transport, id: id,
            resultJSON: #"{"prompts":[{"name":"summarize","arguments":[{"name":"text","required":true}]}],"nextCursor":""}"#
        )

        let (items, nextCursor) = try await task.value
        XCTAssertEqual(items, [[
            "name": AnyCodable("summarize"),
            "arguments": AnyCodable([AnyCodable(["name": AnyCodable("text"), "required": AnyCodable(true)])]),
        ]])
        XCTAssertEqual(nextCursor, "", "an empty-string cursor is a cursor")
    }

    // MARK: - callTool passes MCPToolCallContext.headerMirrors through as .request(headerMirrors:)

    func test_callTool_passesHeaderMirrorsThroughAsRequestOutboundKind() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let mirrors = [MCPHTTPHeaderMirror(headerName: "Region", propertyPath: ["region"])]
        let context = MCPToolCallContext(cwd: nil, progress: nil, headerMirrors: mirrors)
        let task = Task { await client.callTool(name: "t", arguments: [:], context: context) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let frame = await transport.sentFrames()[baseline]
        XCTAssertEqual(frame.kind, .request(headerMirrors: mirrors))

        let id = try decodeSent(frame.data)["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    /// When `context.headerMirrors` is left at its default, the outbound
    /// kind still carries the empty array explicitly, not some other
    /// representation of "no mirrors".
    func test_callTool_withNoHeaderMirrors_sendsEmptyHeaderMirrorsOnRequestKind() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        let baseline = try await negotiateModern(client, transport: transport)

        let task = Task { await client.callTool(name: "t", arguments: [:], context: .none) }
        try await waitUntil { await transport.sentMessages().count == baseline + 1 }
        let frame = await transport.sentFrames()[baseline]
        XCTAssertEqual(frame.kind, .request(headerMirrors: []))

        let id = try decodeSent(frame.data)["id"] as! Int
        await respondSuccess(transport, id: id, resultJSON: #"{"content":[],"resultType":"complete"}"#)
        _ = await task.value
    }

    // MARK: - serverEvents: the client is the only subscriber of transport.inbound; it forwards
    // whatever it does not consume itself, and yields .closed exactly once on an unsolicited close

    /// A notification the client has no other use for (`notifications/tools/list_changed`)
    /// is forwarded verbatim as `.notification(method:params:)`.
    func test_serverEvents_deliversNotificationTheClientDoesNotConsume() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        _ = try await negotiateLegacy(client, transport: transport)

        let recorder = ServerEventRecorder()
        let collector = Task {
            for await event in client.serverEvents { await recorder.record(event) }
        }

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#.utf8))
        try await waitUntil { await recorder.events.count == 1 }
        collector.cancel()

        let events = await recorder.events
        XCTAssertEqual(events, [.notification(method: "notifications/tools/list_changed", params: nil)])
    }

    /// Everything the client handles itself -- server-initiated `ping`,
    /// server-initiated `elicitation/create`, `notifications/elicitation/complete`,
    /// `notifications/progress`, and `notifications/subscriptions/acknowledged`
    /// -- must never surface on `serverEvents`.
    func test_serverEvents_omitsNotificationsAndRequestsTheClientConsumesItself() async throws {
        let transport = InMemoryMCPTransport()
        let presenter = FakeElicitationPresenter(scriptedResponses: [.decline])
        let client = makeClient(transport: transport, presenter: presenter, clock: ManualMCPClock())
        let baseline = try await negotiateLegacy(client, transport: transport)

        let recorder = ServerEventRecorder()
        let collector = Task {
            for await event in client.serverEvents { await recorder.record(event) }
        }

        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        await transport.simulateServerMessage(Data(#"""
        {"jsonrpc":"2.0","id":2,"method":"elicitation/create","params":{"message":"Enter a value","requestedSchema":{"type":"object","properties":{}}}}
        """#.utf8))
        try await waitUntil { await presenter.calls.count == 1 }
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/elicitation/complete","params":{"elicitationId":"unknown"}}"#.utf8))
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":0.1,"progressToken":999}}"#.utf8))
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{"toolsListChanged":true}}}"#.utf8))

        // Barrier: a server-initiated ping is answered only after every
        // message ahead of it in the actor's single receive loop has been
        // processed, so waiting for its reply proves every message above
        // was handled without sleeping for synchronization. Three replies
        // are expected on the wire: the ping (id 1), the elicitation/create
        // response (id 2), and this barrier ping -- the three notifications
        // in between produce no reply of their own.
        await transport.simulateServerMessage(Data(#"{"jsonrpc":"2.0","id":"barrier","method":"ping"}"#.utf8))
        try await waitUntil { await transport.sentMessages().count == baseline + 3 }

        collector.cancel()
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty, "notifications and requests the client consumes itself must never appear on serverEvents, got \(events)")
    }

    func test_serverEvents_deliversClosedExactlyOnceOnUnsolicitedClose() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        _ = try await negotiateLegacy(client, transport: transport)

        let recorder = ServerEventRecorder()
        let collector = Task {
            for await event in client.serverEvents { await recorder.record(event) }
        }

        await transport.simulateCrash(reason: "child exited")
        try await waitUntil { await recorder.events.count == 1 }

        // Bounded negative check: nothing else should ever arrive after
        // the one .closed element, in particular not a second .closed.
        do {
            try await waitUntil(timeout: 0.3) { await recorder.events.count > 1 }
            XCTFail(".closed must be delivered exactly once, not more")
        } catch is WaitTimedOut {
            // expected: no second element arrived within the window
        }
        collector.cancel()

        let events = await recorder.events
        XCTAssertEqual(events, [.closed(reason: "child exited", exit: nil, stderrTail: nil)])
    }

    /// A caller-initiated, graceful `transport.close()` must never be
    /// observed as `.closed` on `serverEvents` -- that case is reserved
    /// for an unsolicited close (the crash-detection contract, section
    /// 2). This waits for a bounded window in which nothing should
    /// happen, then asserts nothing did; it is not sleeping for
    /// synchronization, it is bounding how long a negative assertion can
    /// wait before it is allowed to pass.
    func test_serverEvents_neverDeliversClosedOnGracefulTransportClose() async throws {
        let transport = InMemoryMCPTransport()
        let client = makeClient(transport: transport, presenter: FakeElicitationPresenter(scriptedResponses: []), clock: ManualMCPClock())
        _ = try await negotiateLegacy(client, transport: transport)

        let recorder = ServerEventRecorder()
        let collector = Task {
            for await event in client.serverEvents { await recorder.record(event) }
        }

        await transport.close()

        do {
            try await waitUntil(timeout: 0.3) { await recorder.events.count > 0 }
            XCTFail("a graceful close() must never be observed as .closed on serverEvents")
        } catch is WaitTimedOut {
            // expected: no event was delivered within the window
        }
        collector.cancel()
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: - polling helper

    /// Polls `predicate` until it becomes true or `timeout` elapses.
    /// Throws (fails the test) on timeout instead of skipping, so a
    /// production regression that never satisfies the condition is
    /// reported as a failure, not silently skipped.
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
}
