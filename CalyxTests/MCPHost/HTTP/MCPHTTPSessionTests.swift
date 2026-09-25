//
//  MCPHTTPSessionTests.swift
//  CalyxTests
//
//  `MCPHTTPSession` is the shared HTTP primitive under every MCPHost
//  HTTP transport (modern Streamable HTTP, legacy Streamable HTTP,
//  legacy HTTP+SSE, and the OAuth flow's own metadata/token fetches).
//  Contract asserted here:
//
//    actor MCPHTTPSession {
//        struct Response: Sendable { let statusCode: Int; let headers: [String: String]; let body: Data }
//        enum MCPHTTPSessionError: Error, Equatable, Sendable {
//            case redirectRefused(status: Int)
//            case bodyTooLarge(limit: Int)
//            case insecureSchemeRefused(url: URL)
//        }
//        static let defaultMaxBodyBytes: Int  // 64 * 1024 * 1024
//        init(urlSession: URLSession, maxBodyBytes: Int = MCPHTTPSession.defaultMaxBodyBytes)
//        func send(_ request: URLRequest) async throws -> Response
//        func stream(_ request: URLRequest) async throws -> (head: Response, body: AsyncThrowingStream<Data, Error>)
//    }
//
//  Redirect refusal exists so a bearer token attached to one origin's
//  Authorization header can never be replayed to a different origin by
//  URLSession's automatic redirect-following. `stream` is subject to the
//  same three refusals as `send` (redirect, body cap, insecure scheme) per
//  contract section 5.1 ("stream も同じ拒否規則・上限を通す"). The plain
//  http loopback allowance covers 127.0.0.1, ::1, and localhost per this
//  test-writing task's explicit instructions; section 5.1's prose names
//  only 127.0.0.1 and localhost, so the ::1 case is this task's addition
//  rather than the contract's.
//

import XCTest
@testable import Calyx

final class MCPHTTPSessionTests: XCTestCase {

    private var recorder: MCPHTTPStubRecorder!
    private var urlSession: URLSession!

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

    // MARK: - Default body cap constant

    func test_defaultMaxBodyBytes_is64MiB() {
        XCTAssertEqual(MCPHTTPSession.defaultMaxBodyBytes, 64 * 1024 * 1024)
    }

    // MARK: - 3xx is always an error

    func test_send_redirectResponse_throwsRedirectRefused_withoutFollowingIt() async throws {
        recorder.enqueue { _ in .redirect(status: 307, location: "https://evil.example.com/steal") }
        let session = MCPHTTPSession(urlSession: urlSession)

        do {
            _ = try await session.send(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
            XCTFail("expected redirectRefused")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .redirectRefused(status: 307))
        }

        XCTAssertEqual(recorder.requests.count, 1, "the redirect target must never be requested")
        XCTAssertEqual(recorder.requests.first?.url.host, "mcp.example.com")
    }

    func test_send_302Redirect_alsoRefused() async throws {
        recorder.enqueue { _ in .redirect(status: 302, location: "https://mcp.example.com/other") }
        let session = MCPHTTPSession(urlSession: urlSession)

        do {
            _ = try await session.send(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
            XCTFail("expected redirectRefused")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .redirectRefused(status: 302))
        }
    }

    // MARK: - Body size cap

    func test_send_bodyExceedingCap_throwsBodyTooLarge() async throws {
        let oversized = Data(repeating: 0x61, count: 101)
        recorder.enqueue { _ in .json(status: 200, body: oversized) }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        do {
            _ = try await session.send(URLRequest(url: URL(string: "http://127.0.0.1:9/mcp")!))
            XCTFail("expected bodyTooLarge")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .bodyTooLarge(limit: 100))
        }
    }

    func test_send_bodyAtExactlyCap_succeeds() async throws {
        let exact = Data(repeating: 0x61, count: 100)
        recorder.enqueue { _ in .json(status: 200, body: exact) }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        let response = try await session.send(URLRequest(url: URL(string: "http://127.0.0.1:9/mcp")!))
        XCTAssertEqual(response.body.count, 100)
    }

    // MARK: - Plain http refused unless loopback

    func test_send_plainHTTPToRemoteHost_throwsInsecureSchemeRefused() async throws {
        let session = MCPHTTPSession(urlSession: urlSession)
        let url = URL(string: "http://mcp.example.com/mcp")!

        do {
            _ = try await session.send(URLRequest(url: url))
            XCTFail("expected insecureSchemeRefused")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .insecureSchemeRefused(url: url))
        }
        XCTAssertEqual(recorder.requests.count, 0, "the request must never reach the network layer")
    }

    func test_send_plainHTTPTo127_0_0_1_isAllowed() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data("{}".utf8)) }
        let session = MCPHTTPSession(urlSession: urlSession)
        let response = try await session.send(URLRequest(url: URL(string: "http://127.0.0.1:41830/mcp")!))
        XCTAssertEqual(response.statusCode, 200)
    }

    func test_send_plainHTTPToLocalhost_isAllowed() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data("{}".utf8)) }
        let session = MCPHTTPSession(urlSession: urlSession)
        let response = try await session.send(URLRequest(url: URL(string: "http://localhost:41830/mcp")!))
        XCTAssertEqual(response.statusCode, 200)
    }

    func test_send_plainHTTPToIPv6Loopback_isAllowed() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data("{}".utf8)) }
        let session = MCPHTTPSession(urlSession: urlSession)
        let response = try await session.send(URLRequest(url: URL(string: "http://[::1]:41830/mcp")!))
        XCTAssertEqual(response.statusCode, 200)
    }

    func test_send_httpsToRemoteHost_isAllowed() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data("{}".utf8)) }
        let session = MCPHTTPSession(urlSession: urlSession)
        let response = try await session.send(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        XCTAssertEqual(response.statusCode, 200)
    }

    // MARK: - Successful pass-through

    func test_send_successfulResponse_returnsStatusHeadersAndBody() async throws {
        recorder.enqueue { _ in .json(status: 200, headers: ["X-Test": "1"], body: Data(#"{"ok":true}"#.utf8)) }
        let session = MCPHTTPSession(urlSession: urlSession)
        let response = try await session.send(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["X-Test"], "1")
        XCTAssertEqual(response.body, Data(#"{"ok":true}"#.utf8))
    }

    // MARK: - stream(): same refusals as send()

    func test_stream_redirectResponse_throwsRedirectRefused_withoutFollowingIt() async throws {
        recorder.enqueue { _ in .redirect(status: 307, location: "https://evil.example.com/steal") }
        let session = MCPHTTPSession(urlSession: urlSession)

        do {
            _ = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
            XCTFail("expected redirectRefused")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .redirectRefused(status: 307))
        }
        XCTAssertEqual(recorder.requests.count, 1, "the redirect target must never be requested")
    }

    func test_stream_plainHTTPToRemoteHost_throwsInsecureSchemeRefused() async throws {
        let session = MCPHTTPSession(urlSession: urlSession)
        let url = URL(string: "http://mcp.example.com/mcp")!

        do {
            _ = try await session.stream(URLRequest(url: url))
            XCTFail("expected insecureSchemeRefused")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .insecureSchemeRefused(url: url))
        }
        XCTAssertEqual(recorder.requests.count, 0, "the request must never reach the network layer")
    }

    func test_stream_bodyExceedingCap_throwsBodyTooLarge() async throws {
        // Two chunks whose combined size crosses the cap; the cap applies
        // to the streamed total, not to any single chunk. Content-Type is
        // forced to non-SSE so this asserts the cap applies to a plain
        // streamed (non-event-stream) body.
        let chunkA = Data(repeating: 0x61, count: 60)
        let chunkB = Data(repeating: 0x62, count: 60)
        recorder.enqueue { _ in
            .sse(status: 200, headers: ["Content-Type": "application/json"], chunks: [chunkA, chunkB], thenClose: true)
        }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        let (_, body) = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        do {
            for try await _ in body {}
            XCTFail("expected bodyTooLarge")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .bodyTooLarge(limit: 100))
        }
    }

    func test_stream_bodyAtExactlyCap_succeeds() async throws {
        // Non-SSE content type: a streamed body right at the cap succeeds,
        // and above it fails (previous test) -- the boundary check applies
        // to any capped (non-event-stream) body.
        let chunk = Data(repeating: 0x61, count: 100)
        recorder.enqueue { _ in
            .sse(status: 200, headers: ["Content-Type": "application/json"], chunks: [chunk], thenClose: true)
        }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        let (_, body) = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        var total = 0
        for try await piece in body { total += piece.count }
        XCTAssertEqual(total, 100)
    }

    // MARK: - SSE responses are exempt from the total-body cap

    func test_stream_2xxEventStreamBodyExceedingCap_isDeliveredInFull() async throws {
        let chunkA = Data(repeating: 0x61, count: 60)
        let chunkB = Data(repeating: 0x62, count: 60)
        recorder.enqueue { _ in .sse(status: 200, chunks: [chunkA, chunkB], thenClose: true) }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        let (head, body) = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        XCTAssertEqual(head.statusCode, 200)
        var total = 0
        for try await piece in body { total += piece.count }
        XCTAssertEqual(total, 120, "a 2xx text/event-stream response must be exempt from the total-body cap")
    }

    func test_stream_2xxEventStreamWithCharsetParameter_isExempt() async throws {
        let chunkA = Data(repeating: 0x61, count: 60)
        let chunkB = Data(repeating: 0x62, count: 60)
        recorder.enqueue { _ in
            .sse(status: 200, headers: ["Content-Type": "text/event-stream; charset=utf-8"], chunks: [chunkA, chunkB], thenClose: true)
        }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        let (_, body) = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        var total = 0
        for try await piece in body { total += piece.count }
        XCTAssertEqual(total, 120, "; charset=... must not defeat the text/event-stream match")
    }

    func test_stream_2xxEventStreamMixedCase_isExempt() async throws {
        let chunkA = Data(repeating: 0x61, count: 60)
        let chunkB = Data(repeating: 0x62, count: 60)
        recorder.enqueue { _ in
            .sse(status: 200, headers: ["Content-Type": "Text/Event-Stream"], chunks: [chunkA, chunkB], thenClose: true)
        }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        let (_, body) = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        var total = 0
        for try await piece in body { total += piece.count }
        XCTAssertEqual(total, 120, "the Content-Type match must be case-insensitive")
    }

    func test_stream_non2xxEventStreamBodyExceedingCap_throwsBodyTooLarge() async throws {
        let chunkA = Data(repeating: 0x61, count: 60)
        let chunkB = Data(repeating: 0x62, count: 60)
        recorder.enqueue { _ in .sse(status: 500, chunks: [chunkA, chunkB], thenClose: true) }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        let (_, body) = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        do {
            for try await _ in body {}
            XCTFail("expected bodyTooLarge")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .bodyTooLarge(limit: 100), "a non-2xx response, even with an event-stream Content-Type, must stay capped")
        }
    }

    func test_send_2xxEventStreamBodyExceedingCap_throwsBodyTooLarge() async throws {
        let chunkA = Data(repeating: 0x61, count: 60)
        let chunkB = Data(repeating: 0x62, count: 60)
        recorder.enqueue { _ in .sse(status: 200, chunks: [chunkA, chunkB], thenClose: true) }
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)

        do {
            _ = try await session.send(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
            XCTFail("expected bodyTooLarge")
        } catch let error as MCPHTTPSession.MCPHTTPSessionError {
            XCTAssertEqual(error, .bodyTooLarge(limit: 100), "send() collects the whole body, so it is never exempt even for an event-stream response")
        }
    }

    // MARK: - maxBodyBytes is readable

    func test_maxBodyBytes_isReadable() {
        let session = MCPHTTPSession(urlSession: urlSession, maxBodyBytes: 100)
        XCTAssertEqual(session.maxBodyBytes, 100)
    }

    func test_stream_chunksDeliveredIncrementally_inOrder() async throws {
        let first = Data("chunk-one".utf8)
        let second = Data("chunk-two".utf8)
        let gate = MCPHTTPStubGate()
        recorder.enqueue { _ in .gatedSSE(status: 200, first: first, second: second, gate: gate) }
        let session = MCPHTTPSession(urlSession: urlSession)

        let (head, body) = try await session.stream(URLRequest(url: URL(string: "https://mcp.example.com/mcp")!))
        XCTAssertEqual(head.statusCode, 200)

        // The stub loads the second chunk only after the first has been
        // received here, so URLSession cannot coalesce the two.
        var received: [Data] = []
        for try await piece in body {
            received.append(piece)
            if received.count == 1 { gate.open() }
        }
        XCTAssertEqual(received, [first, second], "chunks must arrive as separate pieces in the order sent, not concatenated")
    }
}
