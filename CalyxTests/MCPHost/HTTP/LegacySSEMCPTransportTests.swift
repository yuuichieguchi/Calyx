//
//  LegacySSEMCPTransportTests.swift
//  CalyxTests
//
//  The deprecated 2024-11-05 HTTP+SSE transport (API contract section
//  5.6). The supervisor's `transportFactory` awaits `openStream()` before
//  handing the transport back, so these tests call it explicitly too.
//
//    enum LegacySSEError: Error, Equatable {
//        case endpointEventTimedOut
//        case crossOriginEndpointRefused(URL)
//    }
//    actor LegacySSEMCPTransport: MCPMessageTransport {
//        static let endpointEventTimeout: TimeInterval = 10
//        init(
//            sseEndpoint: URL,
//            session: MCPHTTPSession,
//            staticHeaders: [String: String] = [:],
//            headerProvider: (@Sendable () async throws -> String)? = nil,
//            on401: (@Sendable () async throws -> Void)? = nil,
//            on403InsufficientScope: (@Sendable (String?) async throws -> Void)? = nil,
//            clock: any MCPClock = SystemMCPClock()
//        )
//        func openStream() async throws
//        func send(_ data: Data, kind: MCPOutboundKind) async throws   // always POST (202 / error); MCPTransportError.closed before openStream
//        nonisolated var inbound: AsyncStream<MCPInbound> { get }
//        func cancel(requestID: JSONRPCId, reason: String?) async       // POSTs notifications/cancelled
//        func close() async
//    }
//
//  `openStream()` GETs `sseEndpoint`, waits for `event: endpoint` within
//  `endpointEventTimeout` (driven here via `ManualMCPClock`), and refuses
//  an endpoint URL whose scheme/host/port differ from `sseEndpoint`'s. All
//  JSON-RPC messages POST to the discovered endpoint; every response and
//  server-initiated notification arrives as an `event: message` SSE event
//  on the same GET stream, delivered as `.frame`. `event: endpoint` itself
//  is never delivered as a `.frame`. A GET stream that ends without an
//  explicit `close()` is an unsolicited `.closed`.
//

import XCTest
@testable import Calyx

final class LegacySSEMCPTransportTests: XCTestCase {

    private var recorder: MCPHTTPStubRecorder!
    private var urlSession: URLSession!
    private let sseEndpoint = URL(string: "https://mcp.example.com/sse")!
    private let postEndpoint = URL(string: "https://mcp.example.com/messages?sessionId=abc")!

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

    private func session(maxBodyBytes: Int = MCPHTTPSession.defaultMaxBodyBytes) -> MCPHTTPSession {
        MCPHTTPSession(urlSession: urlSession, maxBodyBytes: maxBodyBytes)
    }

    private func transport(clock: any MCPClock = SystemMCPClock(), maxBodyBytes: Int = MCPHTTPSession.defaultMaxBodyBytes) -> LegacySSEMCPTransport {
        LegacySSEMCPTransport(sseEndpoint: sseEndpoint, session: session(maxBodyBytes: maxBodyBytes), clock: clock)
    }

    private func requestBody(id: Int = 1, method: String = "tools/call") -> Data {
        let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": ["name": "x", "arguments": [String: Any]()]]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func endpointEventChunk(_ url: URL = URL(string: "https://mcp.example.com/messages?sessionId=abc")!) -> Data {
        Data("event: endpoint\ndata: \(url.absoluteString)\n\n".utf8)
    }

    // MARK: - openStream() opens the GET and discovers the endpoint

    func test_openStream_opensGETOnSSEEndpoint() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) }
        let transport = transport()
        try await transport.openStream()

        let getRequest = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(getRequest.method, "GET")
        XCTAssertEqual(getRequest.url, sseEndpoint)
    }

    func test_openStream_noEndpointEventWithinTimeout_throwsEndpointEventTimedOut() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [], thenClose: false) } // never sends `endpoint`
        let clock = ManualMCPClock()
        let transport = transport(clock: clock)

        async let opening: Void = transport.openStream()

        let deadline = Date().addingTimeInterval(2)
        while !clock.sleepDurations().contains(LegacySSEMCPTransport.endpointEventTimeout), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(clock.sleepDurations().contains(LegacySSEMCPTransport.endpointEventTimeout))
        clock.advance(by: LegacySSEMCPTransport.endpointEventTimeout)

        do {
            try await opening
            XCTFail("expected endpointEventTimedOut")
        } catch let error as LegacySSEError {
            XCTAssertEqual(error, .endpointEventTimedOut)
        }
    }

    func test_openStream_crossOriginEndpoint_throwsCrossOriginEndpointRefused() async throws {
        let evilURL = URL(string: "https://evil.example.com/messages")!
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk(evilURL)], thenClose: false) }
        let transport = transport()

        do {
            try await transport.openStream()
            XCTFail("expected crossOriginEndpointRefused")
        } catch let error as LegacySSEError {
            XCTAssertEqual(error, .crossOriginEndpointRefused(evilURL))
        }
    }

    func test_openStream_endpointOnDifferentPort_sameHostAndScheme_isStillCrossOrigin() async throws {
        let differentPort = URL(string: "https://mcp.example.com:8443/messages")!
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk(differentPort)], thenClose: false) }
        let transport = transport()

        do {
            try await transport.openStream()
            XCTFail("expected crossOriginEndpointRefused")
        } catch let error as LegacySSEError {
            XCTAssertEqual(error, .crossOriginEndpointRefused(differentPort))
        }
    }

    // MARK: - send() before openStream()

    func test_send_beforeOpenStream_throwsTransportErrorClosed() async throws {
        let transport = transport()

        do {
            try await transport.send(requestBody(), kind: .request())
            XCTFail("expected MCPTransportError.closed")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }
    }

    // MARK: - Only event: message becomes a .frame

    func test_eventMessage_deliveredAsFrame() async throws {
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        recorder.enqueue { _ in
            .sse(status: 200, chunks: [
                self.endpointEventChunk(),
                Data("event: message\ndata: \(String(data: payload, encoding: .utf8)!)\n\n".utf8),
            ], thenClose: false)
        }
        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.openStream()

        let inbound = await iterator.next()
        guard case .frame(let data) = inbound else {
            return XCTFail("expected .frame, got \(String(describing: inbound))")
        }
        XCTAssertEqual(data, payload)
    }

    func test_eventEndpoint_isNeverDeliveredAsAFrame() async throws {
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        recorder.enqueue { _ in
            .sse(status: 200, chunks: [
                self.endpointEventChunk(),
                Data("event: message\ndata: \(String(data: payload, encoding: .utf8)!)\n\n".utf8),
            ], thenClose: false)
        }
        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.openStream()

        let inbound = await iterator.next()
        guard case .frame(let data) = inbound else {
            return XCTFail("expected the endpoint event to be skipped and the first frame to be the message event")
        }
        XCTAssertEqual(data, payload, "the endpoint event's own data must never surface as a .frame")
    }

    // MARK: - SSE responses are exempt from the session's total-body cap

    func test_eventStream_totalBytesExceedingSessionCap_keepsDeliveringFrames() async throws {
        // 8 events of ~100 bytes each (800 bytes total), well over the
        // 512-byte session cap, delivered as separate chunks after the
        // endpoint event. The cap must not apply cumulatively to an SSE
        // connection.
        let payloads = (0..<8).map { index in
            Data(#"{"jsonrpc":"2.0","id":\#(index),"result":{"pad":""#.utf8) + Data(repeating: 0x61, count: 80) + Data(#""}}"#.utf8)
        }
        var chunks: [Data] = [endpointEventChunk()]
        for payload in payloads {
            chunks.append(Data("event: message\ndata: \(String(data: payload, encoding: .utf8)!)\n\n".utf8))
        }
        recorder.enqueue { _ in .sse(status: 200, chunks: chunks, thenClose: false) }
        let transport = transport(maxBodyBytes: 512)
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.openStream()

        for (index, payload) in payloads.enumerated() {
            let inbound = await iterator.next()
            guard case .frame(let data) = inbound else {
                return XCTFail("expected .frame #\(index), got \(String(describing: inbound))")
            }
            XCTAssertEqual(data, payload)
        }
    }

    func test_eventStream_singleEventExceedingSessionCap_yieldsClosed() async throws {
        // Delivered via `.gatedSSE` (not two back-to-back `.sse` chunks) so
        // URLSession cannot coalesce the endpoint event and the oversized
        // event into one delegate callback: the endpoint event must be
        // fully parsed and dispatched (resolving openStream()) before the
        // oversized event's chunk arrives and throws.
        let oversizedData = String(repeating: "a", count: 600)
        let gate = MCPHTTPStubGate()
        recorder.enqueue { _ in
            .gatedSSE(
                status: 200,
                first: self.endpointEventChunk(),
                second: Data("event: message\ndata: \(oversizedData)\n\n".utf8),
                gate: gate
            )
        }
        let transport = transport(maxBodyBytes: 512)
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.openStream()
        gate.open()

        let inbound = await iterator.next()
        guard case .closed(let reason, _, _) = inbound else {
            return XCTFail("expected .closed, got \(String(describing: inbound))")
        }
        XCTAssertTrue(reason.contains("event stream failed"), "reason was: \(reason)")
    }

    // MARK: - send() posts to the discovered endpoint

    func test_send_afterOpenStream_postsToDiscoveredEndpoint_accepts202() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) } // GET
        recorder.enqueue { _ in .empty(status: 202) } // POST
        let transport = transport()
        try await transport.openStream()

        try await transport.send(requestBody(), kind: .request())

        let postRequest = try XCTUnwrap(recorder.requests.first { $0.method == "POST" })
        XCTAssertEqual(postRequest.url, postEndpoint)
    }

    // MARK: - cancel() POSTs notifications/cancelled

    func test_cancel_postsNotificationsCancelled() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) } // GET
        recorder.enqueue { _ in .empty(status: 202) } // cancel POST
        let transport = transport()
        try await transport.openStream()

        await transport.cancel(requestID: .int(1), reason: "user cancelled")

        let deadline = Date().addingTimeInterval(2)
        while recorder.requests.count < 2, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let postRequest = try XCTUnwrap(recorder.requests.first { $0.method == "POST" })
        let bodyString = postRequest.bodyData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(bodyString.contains("notifications/cancelled"))
    }

    // MARK: - A dropped GET stream is an unsolicited close

    func test_droppedGETStream_isUnsolicitedClosed() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: true) }
        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.openStream()

        let inbound = await iterator.next()
        guard case .closed(_, let exit, let stderrTail) = inbound else {
            return XCTFail("expected an unsolicited .closed when the GET stream ends without close(), got \(String(describing: inbound))")
        }
        XCTAssertNil(exit, "HTTP transports have no process exit info")
        XCTAssertNil(stderrTail, "HTTP transports have no stderr tail")
    }

    // MARK: - close() / send after close()

    func test_close_neverYieldsClosedOnInbound() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) }
        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.openStream()

        await transport.close()
        let next = await iterator.next()
        XCTAssertNil(next, "close() finishes the inbound stream directly; it must never yield .closed itself")
    }

    func test_send_afterClose_throwsTransportErrorClosed() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) }
        let transport = transport()
        try await transport.openStream()
        await transport.close()

        do {
            try await transport.send(requestBody(), kind: .request())
            XCTFail("expected MCPTransportError.closed")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }
    }

    // MARK: - Static headers

    func test_staticHeaders_sentOnTheGETStream_andEveryPOST() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) }
        recorder.enqueue { _ in .empty(status: 202) }
        let transport = LegacySSEMCPTransport(
            sseEndpoint: sseEndpoint,
            session: session(),
            staticHeaders: ["X-Tenant": "tenant-a", "X-Region": "eu-west"]
        )
        try await transport.openStream()
        try await transport.send(requestBody(), kind: .request())

        XCTAssertEqual(recorder.requests.map(\.method), ["GET", "POST"])
        for request in recorder.requests {
            XCTAssertEqual(request.headers["X-Tenant"], "tenant-a", "\(request.method) must carry every static header")
            XCTAssertEqual(request.headers["X-Region"], "eu-west", "\(request.method) must carry every static header")
        }
    }

    func test_staticAuthorization_withoutHeaderProvider_isSentAsConfigured() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) }
        recorder.enqueue { _ in .empty(status: 202) }
        let transport = LegacySSEMCPTransport(
            sseEndpoint: sseEndpoint,
            session: session(),
            staticHeaders: ["Authorization": "Static configured"]
        )
        try await transport.openStream()
        try await transport.send(requestBody(), kind: .request())

        XCTAssertEqual(recorder.requests.map { $0.headers["Authorization"] }, ["Static configured", "Static configured"])
    }

    func test_headerProviderAuthorization_takesPrecedenceOverStaticAuthorization() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [self.endpointEventChunk()], thenClose: false) }
        recorder.enqueue { _ in .empty(status: 202) }
        let transport = LegacySSEMCPTransport(
            sseEndpoint: sseEndpoint,
            session: session(),
            staticHeaders: ["Authorization": "Static configured"],
            headerProvider: { "abc" }
        )
        try await transport.openStream()
        try await transport.send(requestBody(), kind: .request())

        XCTAssertEqual(recorder.requests.map { $0.headers["Authorization"] }, ["Bearer abc", "Bearer abc"])
    }
}
