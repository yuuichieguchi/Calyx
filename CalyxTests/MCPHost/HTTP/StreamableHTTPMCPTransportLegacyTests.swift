//
//  StreamableHTTPMCPTransportLegacyTests.swift
//  CalyxTests
//
//  Legacy (2025-11-25 and earlier) Streamable HTTP: same
//  `StreamableHTTPMCPTransport` actor as the modern tests, constructed
//  with a non-modern `protocolVersion`, which switches it into
//  session-based behavior (`Mcp-Session-Id`, standalone GET SSE stream,
//  `Last-Event-ID` resumption, session-expiry re-initialization).
//
//  Per transports/2025-11-25#protocol-version-header, `MCP-Protocol-Version`
//  is sent on all requests AFTER the one that established the session, not
//  on the `initialize` request itself.
//
//  Per contract section 5.5, a 404 on a session-bearing request is session
//  loss, and the transport does NOT re-initialize (the handshake is owned
//  only by MCPUpstreamClient). The transport fails that one request with
//  `.error(MCPTransportSignal(httpStatus: 404, ...))`, then immediately
//  yields `.closed(reason: "session not found", exit: nil, stderrTail: nil)`
//  as an unsolicited close and ends `inbound`. `MCPUpstreamConnection` is
//  expected to treat this as `.restarting` and redo the handshake with a
//  fresh transport and Client.
//
//  The SSE reconnect delay goes through the same `MCPClock` abstraction
//  every other MCPHost actor uses, via `clock.sleep(for:)` with the
//  `retry:` field's milliseconds converted to seconds --
//  `ManualMCPClock.sleepDurations()` is the shared assertion surface for
//  every injected delay.
//

import XCTest
@testable import Calyx

final class StreamableHTTPMCPTransportLegacyTests: XCTestCase {

    private var recorder: MCPHTTPStubRecorder!
    private var urlSession: URLSession!
    private let endpoint = URL(string: "https://mcp.example.com/mcp")!

    override func setUp() {
        super.setUp()
        recorder = MCPHTTPStubRecorder()
        urlSession = URLSession(configuration: MCPHTTPStubProtocol.configuration(recorder: recorder))
    }

    override func tearDown() {
        urlSession = nil
        recorder = nil
        super.tearDown()
    }

    private func session() -> MCPHTTPSession { MCPHTTPSession(urlSession: urlSession) }

    private func transport(clock: any MCPClock = SystemMCPClock()) -> StreamableHTTPMCPTransport {
        StreamableHTTPMCPTransport(endpoint: endpoint, session: session(), protocolVersion: .v2025_11_25, clock: clock)
    }

    private func initializeBody(id: Int = 0) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "Calyx", "version": "1.0"]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func requestBody(id: Int, method: String = "tools/call") -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": ["name": "x", "arguments": [String: Any]()]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func waitForRequestCount(_ count: Int, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while recorder.requests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Session ID captured from initialize and echoed on subsequent requests

    func test_initialize_capturesMcpSessionIdHeader_andEchoesOnSubsequentRequest() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "1868a90c-abcd"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        try await transport.send(requestBody(id: 1), kind: .request())

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertEqual(recorder.requests[1].headers["Mcp-Session-Id"], "1868a90c-abcd")
    }

    func test_initialize_doesNotCarryMCPProtocolVersionHeaderOnItself() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())

        XCTAssertNil(recorder.requests[0].headers["MCP-Protocol-Version"])
    }

    func test_subsequentRequest_carriesMCPProtocolVersionHeader() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        try await transport.send(requestBody(id: 1), kind: .request())

        XCTAssertEqual(recorder.requests[1].headers["MCP-Protocol-Version"], "2025-11-25")
    }

    // MARK: - notifications/initialized expects 202, then GET SSE opens

    func test_notificationsInitialized_expects202_thenOpensStandaloneGETStream() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 202) } // notifications/initialized
        recorder.enqueue { _ in .sse(status: 200, chunks: [], thenClose: false) } // standalone GET

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        let notified: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [String: Any]()]
        try await transport.send(try! JSONSerialization.data(withJSONObject: notified), kind: .notification)

        try await waitForRequestCount(3)
        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertEqual(recorder.requests[2].method, "GET")
        XCTAssertEqual(recorder.requests[2].headers["Mcp-Session-Id"], "sess-1")
    }

    func test_standaloneGET_405Response_meansNoStandaloneStream_doesNotThrow() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 202) }
        recorder.enqueue { _ in .empty(status: 405) }

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        let notified: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [String: Any]()]
        // Must not throw: a 405 on the standalone GET just means the
        // server offers no server-initiated stream, which is legal.
        try await transport.send(try! JSONSerialization.data(withJSONObject: notified), kind: .notification)
    }

    // MARK: - Last-Event-ID resumption and retry: honored via the injected clock

    func test_standaloneStream_disconnectWithRetryField_reconnectsWithLastEventID() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 202) }
        recorder.enqueue { _ in
            .sse(status: 200, chunks: [Data("id: evt-42\nretry: 5\ndata:\n\n".utf8)], thenClose: true)
        }
        recorder.enqueue { request in
            XCTAssertEqual(request.headers["Last-Event-ID"], "evt-42")
            return .sse(status: 200, chunks: [], thenClose: false)
        }

        let clock = ManualMCPClock()
        let transport = transport(clock: clock)
        try await transport.send(initializeBody(), kind: .request())
        let notified: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [String: Any]()]
        try await transport.send(try! JSONSerialization.data(withJSONObject: notified), kind: .notification)

        // Wait until the transport has registered its retry sleep, then
        // advance virtual time to let the reconnect proceed.
        let deadline = Date().addingTimeInterval(2)
        while !clock.sleepDurations().contains(0.005), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(clock.sleepDurations().contains(0.005),
            "the retry: 5 (milliseconds) field must drive clock.sleep(for:) in SECONDS via the shared MCPClock, not a private delay closure")
        clock.advance(by: 0.005)

        try await waitForRequestCount(4)
        XCTAssertEqual(recorder.requests.count, 4, "GET, then a reconnect GET carrying Last-Event-ID")
    }

    // MARK: - 404 on a session re-initializes once and retries the request

    func test_404OnSessionRequest_deliversError404_thenNeverRetriesInsideTheTransport() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 404) } // session lost

        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(initializeBody(), kind: .request())
        _ = await iterator.next() // consume the initialize response frame

        try await transport.send(requestBody(id: 1), kind: .request())

        let inbound = await iterator.next()
        guard case .error(let signal) = inbound else {
            return XCTFail("expected .error, got \(String(describing: inbound))")
        }
        XCTAssertEqual(signal.httpStatus, 404)
        XCTAssertEqual(recorder.requests.count, 2, "the transport must not re-initialize on its own; the handshake is owned only by MCPUpstreamClient")
    }

    func test_404OnSessionRequest_yieldsUnsolicitedClosed_andEndsInbound() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 404) }

        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(initializeBody(), kind: .request())
        _ = await iterator.next() // initialize response frame

        try await transport.send(requestBody(id: 1), kind: .request())
        _ = await iterator.next() // the .error(404) for the failed request

        let closedEvent = await iterator.next()
        guard case .closed(let reason, let exit, let stderrTail) = closedEvent else {
            return XCTFail("expected .closed, got \(String(describing: closedEvent))")
        }
        XCTAssertEqual(reason, "session not found")
        XCTAssertNil(exit)
        XCTAssertNil(stderrTail)

        let afterClosed = await iterator.next()
        XCTAssertNil(afterClosed, "inbound must end right after the unsolicited .closed")
    }

    // MARK: - cancel() POSTs notifications/cancelled

    func test_cancel_postsNotificationsCancelled_withSessionId() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 202) } // notifications/cancelled

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        await transport.cancel(requestID: .int(1), reason: "user cancelled")

        try await waitForRequestCount(2)
        let cancelRequest = try XCTUnwrap(recorder.requests.last)
        XCTAssertEqual(cancelRequest.method, "POST")
        XCTAssertEqual(cancelRequest.headers["Mcp-Session-Id"], "sess-1")
        let bodyString = cancelRequest.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(bodyString.contains("notifications/cancelled"))
    }

    // MARK: - DELETE sent on close (best effort)

    func test_close_sendsDELETEWithSessionId() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 200) } // DELETE

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        await transport.close()

        try await waitForRequestCount(2)
        let deleteRequest = recorder.requests.last
        XCTAssertEqual(deleteRequest?.method, "DELETE")
        XCTAssertEqual(deleteRequest?.headers["Mcp-Session-Id"], "sess-1")
    }

    func test_close_deleteFailure_doesNotThrow_bestEffort() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 405) } // server refuses DELETE

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        // Must not throw even though DELETE was refused.
        await transport.close()
    }

    func test_close_neverYieldsClosedOnInbound() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 200) }

        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(initializeBody(), kind: .request())
        _ = await iterator.next() // consume the initialize response frame

        await transport.close()
        let next = await iterator.next()
        XCTAssertNil(next, "close() finishes the inbound stream directly; it must never yield .closed itself")
    }

    func test_send_afterClose_throwsTransportErrorClosed() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 200) }

        let transport = transport()
        try await transport.send(initializeBody(), kind: .request())
        await transport.close()

        do {
            try await transport.send(requestBody(id: 1), kind: .request())
            XCTFail("expected MCPTransportError.closed")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }
    }

    // MARK: - Static headers

    func test_staticHeaders_sentOnEveryPOST_theStandaloneGET_andTheDELETE() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .empty(status: 202) } // notifications/initialized
        recorder.enqueue { _ in .sse(status: 200, chunks: [], thenClose: false) } // standalone GET
        recorder.enqueue { _ in .empty(status: 200) } // DELETE

        let transport = StreamableHTTPMCPTransport(
            endpoint: endpoint,
            session: session(),
            protocolVersion: .v2025_11_25,
            staticHeaders: ["X-Tenant": "tenant-a", "X-Region": "eu-west"]
        )
        try await transport.send(initializeBody(), kind: .request())
        let notified: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [String: Any]()]
        try await transport.send(try! JSONSerialization.data(withJSONObject: notified), kind: .notification)
        try await waitForRequestCount(3)
        await transport.close()
        try await waitForRequestCount(4)

        XCTAssertEqual(recorder.requests.map(\.method), ["POST", "POST", "GET", "DELETE"])
        for request in recorder.requests {
            XCTAssertEqual(request.headers["X-Tenant"], "tenant-a", "\(request.method) must carry every static header")
            XCTAssertEqual(request.headers["X-Region"], "eu-west", "\(request.method) must carry every static header")
        }
    }
}
