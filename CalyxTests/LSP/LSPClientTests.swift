//
//  LSPClientTests.swift
//  Calyx
//
//  Tests for the LSP 3.18 transport client (LSPClient actor) and its
//  transport abstraction (LSPTransport protocol + InMemoryLSPTransport
//  test double).
//
//  Coverage:
//    - LSP framing parse (Content-Length headers, back-to-back, fragmented,
//      malformed)
//    - Client → server: sendRequest/sendNotification (with and without params)
//    - id auto-assignment and request/response correlation
//    - Concurrent sendRequest correlation
//    - Server → client: notification handlers, request handlers, default
//      MethodNotFound (-32601) response
//    - Error surface: serverError, transportClosed, notStarted, alreadyStarted,
//      cancellation on close
//    - InMemoryLSPTransport contract: sentMessages, simulateServerMessage,
//      incoming stream termination on close
//
//  TDD phase: RED. None of `LSPTransport`, `InMemoryLSPTransport`,
//  `LSPClient`, `LSPClientError` exist yet. This file is expected to
//  fail to compile until the swift-specialist implements them.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPClientTests: XCTestCase {

    // MARK: - Helpers

    /// Build a Content-Length framed LSP message from a JSON payload string.
    private func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    /// Build a JSON-RPC request payload string.
    private func jsonRPCRequest(id: Int, method: String, paramsJSON: String? = nil) -> String {
        if let params = paramsJSON {
            return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
        } else {
            return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#
        }
    }

    /// Build a JSON-RPC successful response payload string.
    private func jsonRPCResponse(id: Int, resultJSON: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#
    }

    /// Build a JSON-RPC error response payload string.
    private func jsonRPCErrorResponse(id: Int, code: Int, message: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#
    }

    /// Build a JSON-RPC notification payload string.
    private func jsonRPCNotification(method: String, paramsJSON: String? = nil) -> String {
        if let params = paramsJSON {
            return #"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params)}"#
        } else {
            return #"{"jsonrpc":"2.0","method":"\#(method)"}"#
        }
    }

    /// Extract the JSON body from a single LSP-framed Data blob.
    /// Returns the parsed JSON object as a dictionary.
    private func parseFramedJSON(_ data: Data) throws -> [String: Any] {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw TestError.framingMissing
        }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        guard let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TestError.bodyNotObject
        }
        return dict
    }

    /// Parse all consecutive framed JSON messages from a Data blob.
    private func parseAllFramedJSON(_ data: Data) throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let slice = data.subdata(in: cursor..<data.endIndex)
            guard let headerEnd = slice.range(of: Data("\r\n\r\n".utf8)) else { break }
            let headerData = slice.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else { break }
            var contentLength = 0
            for line in headerString.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLength = Int(parts[1]) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + contentLength
            guard bodyEnd <= slice.endIndex else { break }
            let body = slice.subdata(in: bodyStart..<bodyEnd)
            if let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                results.append(dict)
            }
            cursor = cursor + bodyEnd
        }
        return results
    }

    private enum TestError: Error {
        case framingMissing
        case bodyNotObject
        case timeout
    }

    /// Poll a closure until it returns true or the timeout elapses.
    /// Returns true if the predicate became true within the budget.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.005,
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await predicate()
    }

    // MARK: - Sample Codable Types

    private struct EchoParams: Codable, Sendable, Equatable {
        let text: String
    }

    private struct EchoResult: Codable, Sendable, Equatable {
        let echoed: String
    }

    // MARK: - InMemoryLSPTransport contract

    func test_inMemoryTransport_sendCapturesIntoSentMessages() async throws {
        let transport = InMemoryLSPTransport()
        let payload = Data("hello".utf8)
        try await transport.send(payload)
        let sent = await transport.sentMessages()
        XCTAssertEqual(sent, [payload])
    }

    func test_inMemoryTransport_simulateServerMessageEmitsOnIncoming() async throws {
        let transport = InMemoryLSPTransport()
        let payload = Data("server-bytes".utf8)

        let collectTask = Task<Data?, Never> {
            for await chunk in transport.incoming {
                return chunk
            }
            return nil
        }

        await transport.simulateServerMessage(payload)
        // Give the consumer task a tick to receive.
        let received = await withTimeout(seconds: 1.0) {
            await collectTask.value
        }
        XCTAssertEqual(received, payload)
        collectTask.cancel()
        await transport.close()
    }

    func test_inMemoryTransport_closeTerminatesIncomingStream() async throws {
        let transport = InMemoryLSPTransport()

        let done = Task<Bool, Never> {
            for await _ in transport.incoming { /* drain */ }
            return true
        }

        await transport.close()

        let finished = await withTimeout(seconds: 1.0) { await done.value }
        XCTAssertEqual(finished, true, "incoming stream must terminate after close()")
    }

    // MARK: - Basic framing parse (server → client)

    func test_framing_singleContentLengthFramedMessage_isDecoded() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let notifyExpectation = expectation(description: "notification handler called")
        let captured = ActorBox<String?>(nil)
        await client.setNotificationHandler(method: "test/ping") { params in
            // Capture the params payload as a JSON string so the value
            // crossing the actor boundary remains Sendable.
            if let params {
                let data = try? JSONEncoder().encode(params)
                if let data, let s = String(data: data, encoding: .utf8) {
                    await captured.set(s)
                }
            }
            notifyExpectation.fulfill()
        }

        let payload = jsonRPCNotification(method: "test/ping", paramsJSON: #"{"value":42}"#)
        await transport.simulateServerMessage(lspFrame(payload))

        await fulfillment(of: [notifyExpectation], timeout: 2.0)
        let got = await captured.get()
        XCTAssertNotNil(got)
        // The exact serialization key order is not guaranteed; just check
        // for the field/value pair as a substring.
        XCTAssertTrue(got?.contains("\"value\":42") ?? false, "captured=\(String(describing: got))")
    }

    func test_framing_multipleMessagesInOneBufferAreAllProcessed() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let counter = CounterActor()
        let exp = expectation(description: "received two notifications")
        exp.expectedFulfillmentCount = 2

        await client.setNotificationHandler(method: "test/n1") { _ in
            await counter.bump()
            exp.fulfill()
        }
        await client.setNotificationHandler(method: "test/n2") { _ in
            await counter.bump()
            exp.fulfill()
        }

        let a = lspFrame(jsonRPCNotification(method: "test/n1", paramsJSON: #"{"k":1}"#))
        let b = lspFrame(jsonRPCNotification(method: "test/n2", paramsJSON: #"{"k":2}"#))
        var combined = Data()
        combined.append(a)
        combined.append(b)
        await transport.simulateServerMessage(combined)

        await fulfillment(of: [exp], timeout: 2.0)
        let total = await counter.value
        XCTAssertEqual(total, 2)
    }

    func test_framing_fragmentedMessageAcrossMultipleBuffersIsAssembled() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let exp = expectation(description: "fragmented notification reassembled")
        await client.setNotificationHandler(method: "test/frag") { _ in
            exp.fulfill()
        }

        let framed = lspFrame(jsonRPCNotification(method: "test/frag", paramsJSON: #"{"v":"hello-world"}"#))
        // Split the framed bytes at three arbitrary boundaries.
        let n = framed.count
        XCTAssertGreaterThan(n, 8, "framed payload too small to fragment")
        let p1 = framed.subdata(in: 0..<3)
        let p2 = framed.subdata(in: 3..<(n / 2))
        let p3 = framed.subdata(in: (n / 2)..<(n - 2))
        let p4 = framed.subdata(in: (n - 2)..<n)

        await transport.simulateServerMessage(p1)
        await transport.simulateServerMessage(p2)
        await transport.simulateServerMessage(p3)
        await transport.simulateServerMessage(p4)

        await fulfillment(of: [exp], timeout: 2.0)
    }

    func test_framing_malformedHeaderIsRecoveredAndSubsequentMessageProcessed() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let exp = expectation(description: "follow-up notification still processed")
        await client.setNotificationHandler(method: "test/after-bad") { _ in
            exp.fulfill()
        }

        // 1. Send something that looks like a framed message but has a
        //    non-numeric Content-Length. The client should skip it (log only)
        //    and continue.
        let bogusHeader = "Content-Length: NOT_A_NUMBER\r\n\r\n{}"
        await transport.simulateServerMessage(Data(bogusHeader.utf8))

        // 2. Send a well-formed message afterwards. The client must still
        //    process it.
        let good = lspFrame(jsonRPCNotification(method: "test/after-bad"))
        await transport.simulateServerMessage(good)

        await fulfillment(of: [exp], timeout: 2.0)
    }

    // MARK: - Client → server: sendRequest

    func test_sendRequest_emitsContentLengthFramedJSONRPCRequest() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        // Fire-and-respond in a background task.
        let responderStarted = expectation(description: "responder task started")
        let responder = Task { [transport] in
            responderStarted.fulfill()
            // Wait for the client to emit the request.
            for _ in 0..<200 {
                let sent = await transport.sentMessages()
                if !sent.isEmpty {
                    if let dict = try? self.parseFramedJSON(sent[0]),
                       let idAny = dict["id"],
                       let id = (idAny as? Int) ?? Int(idAny as? String ?? "") {
                        let response = self.jsonRPCResponse(
                            id: id,
                            resultJSON: #"{"echoed":"hello"}"#
                        )
                        await transport.simulateServerMessage(self.lspFrame(response))
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
        await fulfillment(of: [responderStarted], timeout: 1.0)

        let result = try await client.sendRequest(
            method: "test/echo",
            params: EchoParams(text: "hello"),
            resultType: EchoResult.self
        )
        _ = await responder.value

        XCTAssertEqual(result, EchoResult(echoed: "hello"))

        // Inspect the framed request that was sent.
        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1)
        let req = try parseFramedJSON(sent[0])
        XCTAssertEqual(req["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(req["method"] as? String, "test/echo")
        XCTAssertNotNil(req["id"], "id must be auto-assigned")
        XCTAssertNotNil(req["params"], "params must be encoded into the request")
        if let params = req["params"] as? [String: Any] {
            XCTAssertEqual(params["text"] as? String, "hello")
        } else {
            XCTFail("params should be a JSON object")
        }
    }

    func test_sendRequest_concurrentRequestsAreCorrelatedById() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        // Responder: every time a request shows up, respond echoing back the
        // params text. We watch sentMessages.count to detect new requests.
        let responder = Task { [transport] in
            var processed = 0
            for _ in 0..<400 {
                let sent = await transport.sentMessages()
                while processed < sent.count {
                    let data = sent[processed]
                    processed += 1
                    guard let dict = try? self.parseFramedJSON(data),
                          let idAny = dict["id"] else { continue }
                    let params = dict["params"] as? [String: Any]
                    let text = params?["text"] as? String ?? ""
                    let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                    let response = self.jsonRPCResponse(
                        id: idInt,
                        resultJSON: #"{"echoed":"\#(text)"}"#
                    )
                    await transport.simulateServerMessage(self.lspFrame(response))
                }
                if processed >= 3 { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        async let a = client.sendRequest(
            method: "test/echo",
            params: EchoParams(text: "A"),
            resultType: EchoResult.self
        )
        async let b = client.sendRequest(
            method: "test/echo",
            params: EchoParams(text: "B"),
            resultType: EchoResult.self
        )
        async let c = client.sendRequest(
            method: "test/echo",
            params: EchoParams(text: "C"),
            resultType: EchoResult.self
        )

        let (ra, rb, rc) = try await (a, b, c)
        _ = await responder.value

        XCTAssertEqual(ra.echoed, "A")
        XCTAssertEqual(rb.echoed, "B")
        XCTAssertEqual(rc.echoed, "C")
    }

    func test_sendRequest_serverErrorResponseThrowsServerError() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let responder = Task { [transport] in
            for _ in 0..<200 {
                let sent = await transport.sentMessages()
                if let first = sent.first,
                   let dict = try? self.parseFramedJSON(first),
                   let idAny = dict["id"] {
                    let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                    let resp = self.jsonRPCErrorResponse(
                        id: idInt,
                        code: -32000,
                        message: "boom"
                    )
                    await transport.simulateServerMessage(self.lspFrame(resp))
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        do {
            _ = try await client.sendRequest(
                method: "test/echo",
                params: EchoParams(text: "x"),
                resultType: EchoResult.self
            )
            XCTFail("expected serverError")
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .serverError(code: -32000, message: "boom"))
        }
        _ = await responder.value
    }

    // MARK: - sendNotification

    func test_sendNotification_emitsMessageWithoutId() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        try await client.sendNotification(
            method: "test/notify",
            params: EchoParams(text: "hi")
        )

        // Allow the underlying actor send to finish flushing.
        let ok = await waitUntil { await !transport.sentMessages().isEmpty }
        XCTAssertTrue(ok)

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1)
        let dict = try parseFramedJSON(sent[0])
        XCTAssertEqual(dict["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(dict["method"] as? String, "test/notify")
        XCTAssertNil(dict["id"], "notifications must NOT carry an id")
    }

    func test_sendNotification_noParamsOverload_omitsParamsField() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        try await client.sendNotification(method: "exit")

        let ok = await waitUntil { await !transport.sentMessages().isEmpty }
        XCTAssertTrue(ok)

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1)
        let dict = try parseFramedJSON(sent[0])
        XCTAssertEqual(dict["method"] as? String, "exit")
        XCTAssertNil(dict["id"])
        XCTAssertNil(dict["params"], "params field must be absent for paramless overload")
    }

    func test_sendRequest_noParamsOverload_omitsParamsField() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let responder = Task { [transport] in
            for _ in 0..<200 {
                let sent = await transport.sentMessages()
                if let first = sent.first,
                   let dict = try? self.parseFramedJSON(first),
                   let idAny = dict["id"] {
                    let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                    await transport.simulateServerMessage(
                        self.lspFrame(self.jsonRPCResponse(id: idInt, resultJSON: "null"))
                    )
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        struct EmptyResult: Codable, Sendable, Equatable {}
        // Some servers respond with `null` for void results; AnyCodable can decode it,
        // so accept it via AnyCodable here.
        let _: AnyCodable = try await client.sendRequest(
            method: "shutdown",
            resultType: AnyCodable.self
        )
        _ = await responder.value

        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 1)
        let dict = try parseFramedJSON(sent[0])
        XCTAssertEqual(dict["method"] as? String, "shutdown")
        XCTAssertNotNil(dict["id"])
        XCTAssertNil(dict["params"], "params field must be absent for paramless request overload")
    }

    // MARK: - Server → client: request handler + default MethodNotFound

    func test_serverRequest_dispatchesToRegisteredHandlerAndWritesResponse() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        await client.setRequestHandler(method: "server/ping") { _ in
            return AnyCodable(["pong": AnyCodable(true)])
        }

        let serverReq = jsonRPCRequest(id: 99, method: "server/ping", paramsJSON: "{}")
        await transport.simulateServerMessage(lspFrame(serverReq))

        let ok = await waitUntil { await !transport.sentMessages().isEmpty }
        XCTAssertTrue(ok, "client must write a response back")

        let sent = await transport.sentMessages()
        let response = try parseFramedJSON(sent[0])
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 99)
        let result = response["result"] as? [String: Any]
        XCTAssertEqual(result?["pong"] as? Bool, true)
        XCTAssertNil(response["error"])
    }

    func test_serverRequest_unregisteredMethodGetsMethodNotFoundError() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let serverReq = jsonRPCRequest(id: 7, method: "unknown/method")
        await transport.simulateServerMessage(lspFrame(serverReq))

        let ok = await waitUntil { await !transport.sentMessages().isEmpty }
        XCTAssertTrue(ok)

        let sent = await transport.sentMessages()
        let response = try parseFramedJSON(sent[0])
        XCTAssertEqual(response["id"] as? Int, 7)
        let err = response["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? Int, -32601, "MethodNotFound code per JSON-RPC 2.0")
        XCTAssertNotNil(err?["message"])
    }

    // MARK: - Error surface

    func test_sendRequest_beforeStart_throwsNotStarted() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        // Intentionally NOT calling start().
        do {
            _ = try await client.sendRequest(
                method: "test/echo",
                params: EchoParams(text: "x"),
                resultType: EchoResult.self
            )
            XCTFail("expected notStarted")
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .notStarted)
        }
    }

    func test_start_calledTwice_throwsAlreadyStarted() async throws {
        // Note: the API summary in the requirements lists `start()` as
        // non-throwing, but requirement 17 mandates that a second `start()`
        // must throw `.alreadyStarted`. The implementer is expected to make
        // `start()` `async throws`. The first call succeeds; the second
        // call must throw the typed error.
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        do {
            try await client.start()
            XCTFail("expected alreadyStarted")
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .alreadyStarted)
        }
    }

    func test_close_cancelsPendingSendRequests() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()

        // Fire a request that will never be answered.
        let inflight: Task<Void, Error> = Task {
            _ = try await client.sendRequest(
                method: "test/never",
                params: EchoParams(text: "x"),
                resultType: EchoResult.self
            )
        }

        // Wait until the client has actually emitted the request to the
        // transport, so we know it is parked waiting for a response.
        let emitted = await waitUntil { await !transport.sentMessages().isEmpty }
        XCTAssertTrue(emitted, "request should have been emitted before close")

        await client.close()

        do {
            try await inflight.value
            XCTFail("pending sendRequest must throw after close()")
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .transportClosed)
        } catch is CancellationError {
            // Acceptable per the close() contract.
        }
    }

    func test_sendRequest_afterClose_throwsTransportClosed() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        await client.close()

        do {
            _ = try await client.sendRequest(
                method: "test/echo",
                params: EchoParams(text: "x"),
                resultType: EchoResult.self
            )
            XCTFail("expected transportClosed")
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .transportClosed)
        }
    }

    // MARK: - Withholding malformedFraming surface

    func test_malformedFraming_errorIsConstructible() {
        // Exercises the error case directly so it remains part of the public
        // surface even though the receive loop only logs malformed frames.
        let err = LSPClientError.malformedFraming(reason: "bad header")
        XCTAssertEqual(err, .malformedFraming(reason: "bad header"))
    }
}

// MARK: - Test-only Helpers

/// A trivially Sendable mutable cell for capturing async-callback output.
private actor ActorBox<T: Sendable> {
    private var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ v: T) { self.value = v }
    func get() -> T { value }
}

private actor CounterActor {
    private(set) var value: Int = 0
    func bump() { value += 1 }
}

/// Run an async closure with a wall-clock timeout. Returns nil on timeout.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ work: @Sendable @escaping () async -> T
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
