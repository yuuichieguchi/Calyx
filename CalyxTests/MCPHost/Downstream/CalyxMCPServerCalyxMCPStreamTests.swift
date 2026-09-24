//
//  CalyxMCPServerCalyxMCPStreamTests.swift
//  CalyxTests
//
//  Coverage: item 5's server -> client notification path for
//  /calyx-mcp: GET without `Accept: text/event-stream` -> 406; GET with
//  an invalid/unknown session -> 404; otherwise a chunked
//  `text/event-stream` response with periodic keep-alive comment lines
//  (MCP 2026-07-28 Streamable HTTP: "servers are encouraged to
//  periodically emit an SSE comment line... as a keep-alive"). The GET
//  stream itself is LEGACY-only: MCP 2026-07-28 Streamable HTTP
//  explicitly removed the GET stream endpoint ("Removal of the GET
//  stream endpoint. Removal of protocol-level sessions."), so every GET
//  test below mints its session through the legacy `initialize`
//  handshake, never a modern per-request `_meta` call. The modern
//  generation's own server -> client path is `subscriptions/listen`
//  (a POST whose response is itself the SSE stream), covered separately
//  below by its acknowledgment-ordering test. Non-loopback `Origin` ->
//  403 (Streamable HTTP §Security & Endpoint: "Servers MUST validate the
//  Origin header... If the Origin header is present and invalid,
//  servers MUST respond with HTTP 403 Forbidden"); request body size
//  cap is 32 MiB for authenticated /calyx-mcp, 1 MiB everywhere else
//  (unauthenticated /calyx-mcp included, and /mcp unchanged).
//
//  `Content-Type: application/json` buffered validation/method-routing
//  behavior is covered by the modern/legacy route test files; this file
//  is scoped to the streaming-specific seam (`routeStreaming`) and the
//  size/Origin gates that sit in front of every route.
//
//  Assumed API surface:
//    enum RoutedResponse { case buffered(HTTPResponse), stream(head: HTTPResponseHead, body: AsyncStream<Data>) }
//    struct HTTPResponseHead: Sendable { let statusCode: Int; let headers: [String: String] }
//    func CalyxMCPServer.routeStreaming(request: HTTPRequest, lifetime: Task<Void, Never>) async -> RoutedResponse
//  `lifetime` is the caller's own cancellation handle for the stream
//  (mirrors `dispatchRoute`'s existing `routeTask`); this file passes a
//  Task that never finishes so the stream stays open for the duration
//  of each test, then cancels it in teardown.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCalyxMCPStreamTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "stream-test-token"
    private var agentEndpointDir: String!
    private var lifetimeTasks: [Task<Void, Never>] = []

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        server.setCalyxMCPRouter(MCPCalyxMCPRouterTestSupport.makeMinimalRouter(bearerToken: { [testToken] in testToken }))
    }

    override func tearDown() {
        for task in lifetimeTasks { task.cancel() }
        lifetimeTasks.removeAll()
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// A Task that never completes on its own, standing in for the
    /// caller's own connection-lifetime handle -- mirrors
    /// `dispatchRoute`'s `routeTask` shape without needing a real
    /// `NWConnection`. Cancelled in `tearDown` for every test that
    /// creates one.
    private func openLifetime() -> Task<Void, Never> {
        let task = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
            }
        }
        lifetimeTasks.append(task)
        return task
    }

    private func mintSessionID() async throws -> String {
        let body = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "stream-test", "version": "1.0"],
            ],
        ])
        let req = HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(testToken)"],
            body: body
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        let sessionID = resp.headers.first { $0.key.caseInsensitiveCompare("Mcp-Session-Id") == .orderedSame }?.value
        return try XCTUnwrap(sessionID)
    }

    private func collectFirstChunks(_ stream: AsyncStream<Data>, count: Int, timeout: Duration = .seconds(5)) async -> [Data] {
        await withTaskGroup(of: [Data].self) { group in
            group.addTask {
                var collected: [Data] = []
                for await chunk in stream {
                    collected.append(chunk)
                    if collected.count >= count { break }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return []
            }
            let result = await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    // MARK: - GET without Accept: text/event-stream -> 406

    func test_getCalyxMCP_missingEventStreamAccept_returns406() async throws {
        let sessionID = try await mintSessionID()
        let req = HTTPRequest(
            method: "GET", path: "/calyx-mcp",
            headers: ["Authorization": "Bearer \(testToken)", "Mcp-Session-Id": sessionID, "Accept": "application/json"],
            body: nil
        )
        let routed = await server.routeStreaming(request: req, lifetime: openLifetime())
        guard case .buffered(let resp) = routed else {
            return XCTFail("a non-SSE Accept header must never open a stream")
        }
        XCTAssertEqual(resp.statusCode, 406)
    }

    // MARK: - GET with invalid session -> 404

    func test_getCalyxMCP_invalidSession_returns404() async throws {
        let req = HTTPRequest(
            method: "GET", path: "/calyx-mcp",
            headers: [
                "Authorization": "Bearer \(testToken)",
                "Mcp-Session-Id": "not-a-real-session",
                "Accept": "text/event-stream",
            ],
            body: nil
        )
        let routed = await server.routeStreaming(request: req, lifetime: openLifetime())
        guard case .buffered(let resp) = routed else {
            return XCTFail("an invalid session must never open a stream")
        }
        XCTAssertEqual(resp.statusCode, 404)
    }

    func test_getCalyxMCP_missingSessionHeaderEntirely_returns404() async throws {
        let req = HTTPRequest(
            method: "GET", path: "/calyx-mcp",
            headers: ["Authorization": "Bearer \(testToken)", "Accept": "text/event-stream"],
            body: nil
        )
        let routed = await server.routeStreaming(request: req, lifetime: openLifetime())
        guard case .buffered(let resp) = routed else {
            return XCTFail("a missing session must never open a stream")
        }
        XCTAssertEqual(resp.statusCode, 404)
    }

    // MARK: - Valid GET: chunked text/event-stream, keep-alive comment

    func test_getCalyxMCP_validSessionAndAccept_opensChunkedEventStream() async throws {
        let sessionID = try await mintSessionID()
        let req = HTTPRequest(
            method: "GET", path: "/calyx-mcp",
            headers: ["Authorization": "Bearer \(testToken)", "Mcp-Session-Id": sessionID, "Accept": "text/event-stream"],
            body: nil
        )
        let routed = await server.routeStreaming(request: req, lifetime: openLifetime())
        guard case .stream(let head, let body) = routed else {
            return XCTFail("a valid session with the right Accept header must open a stream")
        }
        XCTAssertEqual(head.statusCode, 200)
        let contentType = head.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        XCTAssertEqual(contentType, "text/event-stream")

        // The first chunk must be actual SSE framing: either a comment
        // line (starts with ":", MCP 2026-07-28 Streamable HTTP's own
        // keep-alive shape) or a real "event:"/"data:" line -- not just
        // arbitrary bytes. Either way it must be terminated, so a client
        // parsing line-by-line never stalls mid-line waiting for more.
        let chunks = await collectFirstChunks(body, count: 1)
        guard let first = chunks.first, let text = String(data: first, encoding: .utf8) else {
            return XCTFail("the stream must emit at least one decodable chunk within 5s")
        }
        XCTAssertTrue(
            text.hasPrefix(":") || text.hasPrefix("event:") || text.hasPrefix("data:"),
            "the first chunk must be a keep-alive comment or real SSE framing, actual: \(text)"
        )
        XCTAssertTrue(text.hasSuffix("\n"), "an SSE line must be newline-terminated, actual: \(text)")
    }

    // MARK: - Modern subscriptions/listen: ack first, carrying the request's own id as subscriptionId

    func test_subscriptionsListen_firstMessageIsTheAcknowledgmentCarryingTheRequestIDAsSubscriptionId() async throws {
        // MCP 2026-07-28 Subscriptions: "The server MUST send
        // notifications/subscriptions/acknowledged as the first message
        // carrying the subscription's ID in _meta under
        // io.modelcontextprotocol/subscriptionId... The value is the
        // JSON-RPC ID of the subscriptions/listen request."
        let body = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "subscriptions/listen",
            "params": [
                "_meta": [
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any],
                ],
                "notifications": ["toolsListChanged": true],
            ],
        ])
        let req = HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(testToken)",
                "MCP-Protocol-Version": "2026-07-28",
                "Mcp-Method": "subscriptions/listen",
                "Accept": "text/event-stream",
            ],
            body: body
        )
        let routed = await server.routeStreaming(request: req, lifetime: openLifetime())
        guard case .stream(_, let responseBody) = routed else {
            return XCTFail("a modern subscriptions/listen request with SSE Accept must open a stream")
        }

        let chunks = await collectFirstChunks(responseBody, count: 1)
        guard let first = chunks.first, let text = String(data: first, encoding: .utf8) else {
            return XCTFail("the ack must arrive as the first chunk within 5s")
        }
        // Parse out the "data: {...}" JSON payload from the SSE frame.
        let dataLine = text.split(separator: "\n").first { $0.hasPrefix("data:") }
        guard let dataLine else {
            return XCTFail("first SSE frame must carry a data: line, actual: \(text)")
        }
        let jsonText = dataLine.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        let json = try JSONSerialization.jsonObject(with: Data(jsonText.utf8)) as? [String: Any]
        XCTAssertEqual(json?["method"] as? String, "notifications/subscriptions/acknowledged",
                       "the first message on the stream must be the acknowledgment, not any other notification")
        let params = json?["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        XCTAssertEqual(meta?["io.modelcontextprotocol/subscriptionId"] as? Int, 1,
                       "subscriptionId must equal the subscriptions/listen request's own JSON-RPC id")
    }

    // MARK: - Origin validation

    func test_postCalyxMCP_nonLoopbackOrigin_returns403() async throws {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        let req = HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(testToken)",
                "Origin": "https://evil.example.com",
            ],
            body: body
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 403)
    }

    func test_postCalyxMCP_loopbackOrigin_isNotRejectedForOriginAlone() async throws {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        let req = HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(testToken)",
                "Origin": "http://127.0.0.1:41830",
            ],
            body: body
        )
        let resp = await server.route(request: req)
        XCTAssertNotEqual(resp.statusCode, 403)
    }

    func test_postCalyxMCP_missingOrigin_isNotRejected() async throws {
        // Origin is only sent by browser-like clients; a CLI agent
        // sending no Origin at all must not be rejected -- only a
        // PRESENT and invalid Origin triggers 403 (MCP Streamable HTTP:
        // "If the Origin header is present and invalid").
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        let req = HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: ["Content-Type": "application/json", "Authorization": "Bearer \(testToken)"],
            body: body
        )
        let resp = await server.route(request: req)
        XCTAssertNotEqual(resp.statusCode, 403)
    }

    // MARK: - Body size cap: 32 MiB for authenticated /calyx-mcp, 1 MiB elsewhere

    /// A real loopback socket is required for this: the cap must be
    /// enforced by the connection-buffering layer (`HTTPParser`'s
    /// completeness gate / `CalyxMCPServer`'s receive loop), not by
    /// `route(request:)`, which only ever sees an already-fully-buffered
    /// `HTTPRequest` -- by the time a body that size reached `route`,
    /// the oversized-body rejection this test exists to pin would
    /// already have been bypassed.
    func test_authenticatedCalyxMCP_acceptsBodyLargerThanOneMiBButUnderThirtyTwoMiB() async throws {
        try await server.start(token: testToken, preferredPort: 0)
        let port = server.port
        XCTAssertNotEqual(port, 0)

        // 1 MiB + 1 byte: over /mcp's cap, must still be accepted here.
        let oversizedForOrdinaryRoutes = 1024 * 1024 + 1
        let bigArgument = String(repeating: "a", count: oversizedForOrdinaryRoutes)
        let bodyDict: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "app_context", "arguments": ["padding": bigArgument]],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
        XCTAssertGreaterThan(bodyData.count, oversizedForOrdinaryRoutes)

        let token = testToken
        let statusCode = try await Task.detached {
            try sendRawPostToCalyxMCP(port: port, token: token, body: bodyData)
        }.value
        XCTAssertNotEqual(statusCode, 413,
                          "an authenticated /calyx-mcp request between 1 MiB and 32 MiB must not be rejected " +
                          "for size -- only /mcp and unauthenticated /calyx-mcp cap at 1 MiB")
    }

    func test_unauthenticatedCalyxMCP_stillCapsAtOneMiB() async throws {
        try await server.start(token: testToken, preferredPort: 0)
        let port = server.port
        XCTAssertNotEqual(port, 0)

        let oversized = 1024 * 1024 + 1
        let bigArgument = String(repeating: "a", count: oversized)
        let bodyDict: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "app_context", "arguments": ["padding": bigArgument]],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: bodyDict)

        // No Authorization header at all -- the raised cap is only for
        // an AUTHENTICATED request to this path.
        let statusCode = try await Task.detached {
            try sendRawPostToCalyxMCP(port: port, token: nil, body: bodyData)
        }.value
        XCTAssertEqual(statusCode, 413,
                       "an unauthenticated request to /calyx-mcp must still cap at the ordinary 1 MiB limit " +
                       "-- the 32 MiB allowance is not a pre-auth amplification vector")
    }
}

// MARK: - Raw socket helper

/// File scope, so it carries no `@MainActor` isolation and can block
/// inside `Task.detached` without starving the server's own
/// main-actor connection handling.
private func sendRawPostToCalyxMCP(port: Int, token: String?, body: Data) throws -> Int {
    var headerString = "POST /calyx-mcp HTTP/1.1\r\n"
    headerString += "Host: 127.0.0.1:\(port)\r\n"
    if let token {
        headerString += "Authorization: Bearer \(token)\r\n"
    }
    headerString += "Content-Type: application/json\r\n"
    headerString += "Content-Length: \(body.count)\r\n"
    headerString += "Connection: close\r\n"
    headerString += "\r\n"
    let headerData = Data(headerString.utf8)

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

    let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else {
        throw NSError(domain: "CalyxMCPStreamTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed: errno \(errno)"])
    }
    defer { close(fd) }

    var recvTimeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

    let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connectResult == 0 else {
        throw NSError(domain: "CalyxMCPStreamTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect() failed: errno \(errno)"])
    }

    var toSend = headerData
    toSend.append(body)
    try toSend.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < rawBuf.count {
            let sent = Darwin.send(fd, rawBuf.baseAddress!.advanced(by: offset), rawBuf.count - offset, 0)
            guard sent > 0 else {
                throw NSError(domain: "CalyxMCPStreamTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "send() failed: errno \(errno)"])
            }
            offset += sent
        }
    }

    var responseData = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let received = buffer.withUnsafeMutableBytes { rawBuf -> Int in
            Darwin.recv(fd, rawBuf.baseAddress, rawBuf.count, 0)
        }
        if received <= 0 { break }
        responseData.append(contentsOf: buffer[0..<received])
        // Stop once we have the status line -- we don't need the
        // rest of a potentially large response body for this check.
        if responseData.count > 12, let text = String(data: responseData, encoding: .utf8),
           text.contains("\r\n") {
            break
        }
    }
    guard let responseString = String(data: responseData, encoding: .utf8) else {
        throw NSError(domain: "CalyxMCPStreamTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "non-UTF8 response"])
    }
    let statusLine = responseString.components(separatedBy: "\r\n").first ?? ""
    let parts = statusLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, let statusCode = Int(parts[1]) else {
        throw NSError(domain: "CalyxMCPStreamTest", code: 5, userInfo: [NSLocalizedDescriptionKey: "could not parse status from: \(responseString)"])
    }
    return statusCode
}
