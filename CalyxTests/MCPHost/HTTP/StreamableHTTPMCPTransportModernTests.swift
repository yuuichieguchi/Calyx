//
//  StreamableHTTPMCPTransportModernTests.swift
//  CalyxTests
//
//  Modern (2026-07-28, stateless, per-request `_meta`) Streamable HTTP
//  transport. Contract asserted here (API contract section 5.5, and the
//  closure-based OAuth cooperation adopted per section 5.7's explicit
//  direction to implementers):
//
//    actor StreamableHTTPMCPTransport: MCPMessageTransport {
//        init(
//            endpoint: URL,
//            session: MCPHTTPSession,
//            protocolVersion: MCPProtocolVersion,
//            staticHeaders: [String: String] = [:],
//            headerProvider: (@Sendable () async throws -> String)? = nil,
//            on401: (@Sendable () async throws -> Void)? = nil,
//            on403InsufficientScope: (@Sendable (String?) async throws -> Void)? = nil,
//            clock: any MCPClock = SystemMCPClock()
//        )
//        func send(_ data: Data, kind: MCPOutboundKind) async throws
//        nonisolated var inbound: AsyncStream<MCPInbound> { get }
//        func cancel(requestID: JSONRPCId, reason: String?) async
//        func close() async
//    }
//
//  Every JSON-RPC body handed to `send` already carries `_meta` with the
//  negotiated protocol version -- the transport mirrors selected body
//  fields into headers, it does not invent them.
//
//  Per section 5.5, a -32020 HeaderMismatch response is returned to the
//  caller as-is (no transport-level retry; refreshing tools and retrying
//  the call is `MCPUpstreamConnection`'s responsibility, not the
//  transport's).
//

import XCTest
@testable import Calyx

final class StreamableHTTPMCPTransportModernTests: XCTestCase {

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

    private func toolCallBody(id: Int = 1, name: String = "get_weather", arguments: [String: Any] = ["location": "Seattle, WA"]) -> Data {
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func session() -> MCPHTTPSession { MCPHTTPSession(urlSession: urlSession) }

    private func transport(
        headerProvider: (@Sendable () async throws -> String)? = nil,
        on401: (@Sendable () async throws -> Void)? = nil,
        on403InsufficientScope: (@Sendable (String?) async throws -> Void)? = nil,
        clock: any MCPClock = SystemMCPClock()
    ) -> StreamableHTTPMCPTransport {
        StreamableHTTPMCPTransport(
            endpoint: endpoint,
            session: session(),
            protocolVersion: .v2026_07_28,
            headerProvider: headerProvider,
            on401: on401,
            on403InsufficientScope: on403InsufficientScope,
            clock: clock
        )
    }

    private func waitForRequestCount(_ count: Int, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while recorder.requests.count < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - POST only, required headers

    func test_send_toolsCall_isPOSTOnly_withAcceptHeaderListingBothTypes() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        try await transport.send(toolCallBody(), kind: .request())

        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Accept"], "application/json, text/event-stream")
    }

    func test_send_toolsCall_setsProtocolVersionHeader_equalToNegotiatedVersion() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        try await transport.send(toolCallBody(), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["MCP-Protocol-Version"], "2026-07-28")
    }

    func test_send_toolsCall_setsMcpMethodAndMcpNameHeaders() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        try await transport.send(toolCallBody(name: "get_weather"), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Mcp-Method"], "tools/call")
        XCTAssertEqual(request.headers["Mcp-Name"], "get_weather")
    }

    func test_send_resourcesRead_setsMcpNameFromParamsUri() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "resources/read",
            "params": ["uri": "file:///projects/myapp/config.json", "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]],
        ]
        let body = try! JSONSerialization.data(withJSONObject: object)
        let transport = transport()
        try await transport.send(body, kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Mcp-Method"], "resources/read")
        XCTAssertEqual(request.headers["Mcp-Name"], "file:///projects/myapp/config.json")
    }

    func test_send_promptsGet_setsMcpNameFromParamsName() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": 3, "method": "prompts/get",
            "params": ["name": "summarize", "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]],
        ]
        let body = try! JSONSerialization.data(withJSONObject: object)
        let transport = transport()
        try await transport.send(body, kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Mcp-Name"], "summarize")
    }

    func test_send_toolsList_hasNoMcpNameHeader() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let object: [String: Any] = [
            "jsonrpc": "2.0", "id": 4, "method": "tools/list",
            "params": ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]],
        ]
        let body = try! JSONSerialization.data(withJSONObject: object)
        let transport = transport()
        try await transport.send(body, kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertNil(request.headers["Mcp-Name"])
    }

    // MARK: - Non-ASCII header values use the base64 sentinel (section 5.5, streamable-http.mdx)

    func test_send_nonASCIIToolName_encodesMcpNameWithBase64Sentinel() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        try await transport.send(toolCallBody(name: "Hello, 世界"), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        // Computed independently: base64(UTF8("Hello, 世界")) == "SGVsbG8sIOS4lueVjA=="
        XCTAssertEqual(request.headers["Mcp-Name"], "=?base64?SGVsbG8sIOS4lueVjA==?=")
    }

    func test_send_headerParamContainingNewline_encodesWithBase64Sentinel() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        let mirror = MCPHTTPHeaderMirror(headerName: "Text", propertyPath: ["text"])
        try await transport.send(toolCallBody(arguments: ["text": "line1\nline2"]), kind: .request(headerMirrors: [mirror]))

        let request = try XCTUnwrap(recorder.requests.first)
        // Computed independently: base64(UTF8("line1\nline2")) == "bGluZTEKbGluZTI="
        XCTAssertEqual(request.headers["Mcp-Param-Text"], "=?base64?bGluZTEKbGluZTI=?=")
    }

    // MARK: - x-mcp-header tool argument mirroring

    func test_send_headerMirroredArgument_mirroredToMcpParamHeader() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        let mirror = MCPHTTPHeaderMirror(headerName: "Region", propertyPath: ["region"])
        try await transport.send(
            toolCallBody(name: "execute_sql", arguments: ["region": "us-west1", "query": "SELECT 1"]),
            kind: .request(headerMirrors: [mirror])
        )

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Mcp-Param-Region"], "us-west1")
    }

    func test_send_headerMirroredArgument_absentValue_omitsHeader() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        let mirror = MCPHTTPHeaderMirror(headerName: "Region", propertyPath: ["region"])
        try await transport.send(
            toolCallBody(name: "execute_sql", arguments: ["query": "SELECT 1"]),
            kind: .request(headerMirrors: [mirror])
        )

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertNil(request.headers["Mcp-Param-Region"])
    }

    // MARK: - JSON response handling

    func test_send_jsonResponse_deliveredOnInboundAsFrame() async throws {
        let responseBody = Data(#"{"jsonrpc":"2.0","id":1,"result":{"content":[]}}"#.utf8)
        recorder.enqueue { _ in .json(status: 200, body: responseBody) }
        let transport = transport()

        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(toolCallBody(), kind: .request())

        let inbound = await iterator.next()
        guard case .frame(let data) = inbound else {
            return XCTFail("expected .frame, got \(String(describing: inbound))")
        }
        XCTAssertEqual(data, responseBody)
    }

    // MARK: - Per-request SSE response handling

    func test_send_sseResponse_progressThenFinalResponse_bothDeliveredInOrder() async throws {
        let progress = Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":50}}"#.utf8)
        let final = Data(#"{"jsonrpc":"2.0","id":1,"result":{"content":[]}}"#.utf8)
        recorder.enqueue { _ in
            .sse(status: 200, chunks: [
                Data("data: \(String(data: progress, encoding: .utf8)!)\n\n".utf8),
                Data("data: \(String(data: final, encoding: .utf8)!)\n\n".utf8),
            ], thenClose: true)
        }
        let transport = transport()

        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(toolCallBody(), kind: .request())

        let first = await iterator.next()
        guard case .frame(let firstData) = first else { return XCTFail("expected progress frame") }
        XCTAssertEqual(firstData, progress)

        let second = await iterator.next()
        guard case .frame(let secondData) = second else { return XCTFail("expected final frame") }
        XCTAssertEqual(secondData, final)
    }

    // MARK: - cancel() closes the in-flight stream without sending a notification

    func test_cancel_stopsTheUnderlyingURLSessionTask_andSendsNoCancelledNotification() async throws {
        recorder.enqueue { _ in .sse(status: 200, chunks: [], thenClose: false) }
        let transport = transport()
        try await transport.send(toolCallBody(id: 7), kind: .request())

        await transport.cancel(requestID: .int(7), reason: "user cancelled")

        // Cancellation tears down the underlying task asynchronously;
        // poll briefly rather than sleeping a fixed duration blind.
        let deadline = Date().addingTimeInterval(2)
        while recorder.stopLoadingCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(recorder.stopLoadingCount, 1)
        XCTAssertEqual(recorder.requests.count, 1, "modern Streamable HTTP never sends a client-to-server notification for cancellation; closing the stream IS the cancel signal")
    }

    // MARK: - No standalone GET stream in the modern (stateless) transport

    func test_modernTransport_neverIssuesAGETRequest() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        try await transport.send(toolCallBody(), kind: .request())

        XCTAssertFalse(recorder.requests.contains { $0.method == "GET" })
    }

    // MARK: - Notifications

    func test_send_notification_accepts202_withoutThrowingOrEmittingAFrame() async throws {
        recorder.enqueue { _ in .empty(status: 202) }
        let transport = transport()
        let object: [String: Any] = [
            "jsonrpc": "2.0", "method": "notifications/progress",
            "params": ["progress": 10, "_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]],
        ]
        try await transport.send(try! JSONSerialization.data(withJSONObject: object), kind: .notification)

        XCTAssertEqual(recorder.requests.first?.method, "POST")
    }

    // MARK: - HeaderMismatch (-32020) is returned as-is, never retried by the transport

    func test_send_headerMismatch_deliveredAsFrame_withoutTransportLevelRetry() async throws {
        recorder.enqueue { _ in
            .json(status: 400, body: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32020,"message":"Header mismatch"}}"#.utf8))
        }
        let transport = transport()

        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(toolCallBody(id: 1), kind: .request())

        let inbound = await iterator.next()
        guard case .frame(let data) = inbound else {
            return XCTFail("expected .frame carrying the JSON-RPC error reply, got \(String(describing: inbound))")
        }
        guard case .response(let id, _, let error) = try JSONRPCMessage.parse(data) else {
            return XCTFail("expected a JSON-RPC response")
        }
        XCTAssertEqual(id, .int(1))
        XCTAssertEqual(error?.code, -32020)
        XCTAssertEqual(recorder.requests.count, 1, "the transport itself must not retry a -32020; that is MCPUpstreamConnection's responsibility")
    }

    // MARK: - Non-2xx generally, including 401 with WWW-Authenticate

    func test_send_401Response_withNoHeaderProvider_deliveredAsErrorSignal_withWWWAuthenticate() async throws {
        recorder.enqueue { _ in .empty(status: 401, headers: ["WWW-Authenticate": #"Bearer realm="mcp""#]) }
        let transport = transport()

        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(toolCallBody(), kind: .request())

        let inbound = await iterator.next()
        guard case .error(let signal) = inbound else {
            return XCTFail("expected .error, got \(String(describing: inbound))")
        }
        XCTAssertEqual(signal.httpStatus, 401)
        XCTAssertEqual(signal.wwwAuthenticate, #"Bearer realm="mcp""#)
    }

    // MARK: - OAuth cooperation (section 5.7)

    func test_send_headerProviderSet_attachesAuthorizationBearerHeader() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport(headerProvider: { "abc" })
        try await transport.send(toolCallBody(), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer abc")
    }

    func test_send_401_triggersOn401Once_thenRetriesOnceWithNewHeaderValue() async throws {
        let on401CallCount = Locked(0)
        let providedValues = Locked<[String]>([])
        var callCount = 0
        recorder.enqueue { _ in
            callCount += 1
            if callCount == 1 { return .empty(status: 401) }
            return .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        }
        let transport = transport(
            headerProvider: {
                let next = "token-\(providedValues.withLock { $0.count })"
                providedValues.withLock { $0.append(next) }
                return next
            },
            on401: { on401CallCount.withLock { $0 += 1 } }
        )

        try await transport.send(toolCallBody(), kind: .request())

        XCTAssertEqual(on401CallCount.withLock { $0 }, 1)
        XCTAssertEqual(recorder.requests.count, 2, "exactly one retry after the 401")
        XCTAssertEqual(recorder.requests[0].headers["Authorization"], "Bearer token-0")
        XCTAssertEqual(recorder.requests[1].headers["Authorization"], "Bearer token-1", "the retry must carry the value the header provider returns after on401 runs")
    }

    func test_send_401Persists_afterRetryStillFails_propagatesErrorWithoutASecondOn401Call() async throws {
        let on401CallCount = Locked(0)
        recorder.enqueue { _ in .empty(status: 401) }
        let transport = transport(
            headerProvider: { "abc" },
            on401: { on401CallCount.withLock { $0 += 1 } }
        )

        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(toolCallBody(), kind: .request())

        let inbound = await iterator.next()
        guard case .error(let signal) = inbound else {
            return XCTFail("expected .error, got \(String(describing: inbound))")
        }
        XCTAssertEqual(signal.httpStatus, 401)
        XCTAssertEqual(on401CallCount.withLock { $0 }, 1, "on401 must not be called again for the retry's own failure")
        XCTAssertEqual(recorder.requests.count, 2, "the original request plus exactly one retry, no more")
    }

    func test_send_401_on401Throws_deliversErrorSignalWithoutRetrying() async throws {
        struct AuthGaveUp: Error {}
        recorder.enqueue { _ in .empty(status: 401, headers: ["WWW-Authenticate": #"Bearer realm="mcp""#]) }
        let transport = transport(
            headerProvider: { "abc" },
            on401: { throw AuthGaveUp() }
        )

        var iterator = transport.inbound.makeAsyncIterator()
        // on401 threw, so the 401 is reported on inbound and send() returns.
        try await transport.send(toolCallBody(), kind: .request())

        let inbound = await iterator.next()
        guard case .error(let signal) = inbound else {
            return XCTFail("expected .error, got \(String(describing: inbound))")
        }
        XCTAssertEqual(signal.httpStatus, 401)
        XCTAssertEqual(signal.wwwAuthenticate, #"Bearer realm="mcp""#)
        XCTAssertEqual(recorder.requests.count, 1, "on401 throwing must not be followed by a retry")
    }

    func test_send_403InsufficientScope_triggersHookOnceWithParsedChallengeScope_thenRetriesOnceOnSuccess() async throws {
        let scopeCallCount = Locked(0)
        let capturedScope = Locked<String?>(nil)
        var callCount = 0
        recorder.enqueue { _ in
            callCount += 1
            if callCount == 1 {
                return .empty(status: 403, headers: ["WWW-Authenticate": #"Bearer error="insufficient_scope", scope="tools:execute""#])
            }
            return .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
        }
        let transport = transport(
            headerProvider: { "abc" },
            on403InsufficientScope: { scope in
                scopeCallCount.withLock { $0 += 1 }
                capturedScope.withLock { $0 = scope }
            }
        )

        try await transport.send(toolCallBody(), kind: .request())

        XCTAssertEqual(scopeCallCount.withLock { $0 }, 1)
        // MCPHTTPBearerChallenge.parse extracts the scope auth-param, not
        // the raw WWW-Authenticate header value.
        XCTAssertEqual(capturedScope.withLock { $0 }, "tools:execute")
        XCTAssertEqual(recorder.requests.count, 2, "success from on403InsufficientScope retries the original request exactly once")
    }

    func test_send_403WithoutInsufficientScopeError_doesNotTriggerTheHook() async throws {
        let scopeCallCount = Locked(0)
        recorder.enqueue { _ in .empty(status: 403, headers: ["WWW-Authenticate": #"Bearer realm="mcp""#]) }
        let transport = transport(
            headerProvider: { "abc" },
            on403InsufficientScope: { _ in scopeCallCount.withLock { $0 += 1 } }
        )

        var iterator = transport.inbound.makeAsyncIterator()
        try await transport.send(toolCallBody(), kind: .request())

        let inbound = await iterator.next()
        guard case .error(let signal) = inbound else {
            return XCTFail("expected .error, got \(String(describing: inbound))")
        }
        XCTAssertEqual(signal.httpStatus, 403)
        XCTAssertEqual(scopeCallCount.withLock { $0 }, 0, "a 403 whose challenge has no error=\"insufficient_scope\" must not trigger the hook")
    }

    // MARK: - close()

    func test_close_neverYieldsClosedOnInbound() async throws {
        let transport = transport()
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.close()
        let next = await iterator.next()
        XCTAssertNil(next, "close() finishes the inbound stream directly; it must never yield .closed itself")
    }

    func test_send_afterClose_throwsTransportErrorClosed() async throws {
        let transport = transport()
        await transport.close()

        do {
            try await transport.send(toolCallBody(), kind: .request())
            XCTFail("expected MCPTransportError.closed")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        }
    }

    // MARK: - Static headers

    func test_staticHeaders_sentOnThePOST() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = StreamableHTTPMCPTransport(
            endpoint: endpoint,
            session: session(),
            protocolVersion: .v2026_07_28,
            staticHeaders: ["X-Tenant": "tenant-a"]
        )
        try await transport.send(toolCallBody(), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["X-Tenant"], "tenant-a")
    }

    func test_staticAuthorization_withoutHeaderProvider_isSentAsConfigured() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = StreamableHTTPMCPTransport(
            endpoint: endpoint,
            session: session(),
            protocolVersion: .v2026_07_28,
            staticHeaders: ["Authorization": "Static configured"]
        )
        try await transport.send(toolCallBody(), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Static configured")
    }

    func test_headerProviderAuthorization_takesPrecedenceOverStaticAuthorization() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = StreamableHTTPMCPTransport(
            endpoint: endpoint,
            session: session(),
            protocolVersion: .v2026_07_28,
            staticHeaders: ["Authorization": "Static configured", "X-Tenant": "tenant-a"],
            headerProvider: { "abc" }
        )
        try await transport.send(toolCallBody(), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer abc")
        XCTAssertEqual(request.headers["X-Tenant"], "tenant-a")
    }

    func test_staticHeaders_neverReplaceTheProtocolHeadersTheTransportSets() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = StreamableHTTPMCPTransport(
            endpoint: endpoint,
            session: session(),
            protocolVersion: .v2026_07_28,
            staticHeaders: ["Accept": "text/plain", "MCP-Protocol-Version": "2024-11-05", "Mcp-Method": "ping"]
        )
        try await transport.send(toolCallBody(), kind: .request())

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.headers["Accept"], "application/json, text/event-stream")
        XCTAssertEqual(request.headers["MCP-Protocol-Version"], "2026-07-28")
        XCTAssertEqual(request.headers["Mcp-Method"], "tools/call")
    }

    // MARK: - setNegotiatedProtocolVersion(_:)

    func test_setNegotiatedProtocolVersion_toLegacy_sendsLegacyHeaders_andCapturesMcpSessionId() async throws {
        recorder.enqueue { _ in
            .json(status: 200, headers: ["Mcp-Session-Id": "sess-1"],
                  body: Data(#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-11-25"}}"#.utf8))
        }
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)) }
        let transport = transport()
        await transport.setNegotiatedProtocolVersion(.v2025_11_25)

        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [String: Any](), "clientInfo": ["name": "Calyx", "version": "1.0"]],
        ]
        try await transport.send(try JSONSerialization.data(withJSONObject: initialize), kind: .request())
        try await transport.send(toolCallBody(id: 1), kind: .request())

        XCTAssertEqual(recorder.requests.count, 2)
        XCTAssertNil(recorder.requests[0].headers["MCP-Protocol-Version"], "a legacy initialize carries no MCP-Protocol-Version header")
        XCTAssertEqual(recorder.requests[1].headers["MCP-Protocol-Version"], "2025-11-25")
        XCTAssertEqual(recorder.requests[1].headers["Mcp-Session-Id"], "sess-1")
        XCTAssertNil(recorder.requests[1].headers["Mcp-Method"], "Mcp-Method belongs to the modern era only")
    }
}
