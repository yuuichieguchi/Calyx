//
//  LSPClientBugSpecTests.swift
//  Calyx
//
//  Wave 2 retrofit — INDEPENDENT regression tests for LSPClient. These
//  are written from the bug spec rather than from the existing fix
//  diff, so they double-check that the contractual fixes hold without
//  inheriting any of the original test's blind spots.
//
//  One test per bug:
//    1. In-actor wire ordering preserves call order.
//    2. Content-Length > 64 MiB fails pending and CLOSES THE TRANSPORT.
//    3. Server responses with a string id resolve the int-id continuation.
//    4. Task cancellation clears `pending` and emits `$/cancelRequest`.
//    5. Wall-clock timeout throws `.timeout` and emits `$/cancelRequest`.
//    6. Response with neither result nor error fails as malformedFraming.
//    7. Server-initiated handler throwing DecodingError maps to JSON-RPC -32602.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPClientBugSpecTests: XCTestCase {

    // MARK: - Local helpers (intentionally not shared with LSPClientTests)

    /// Holds a value behind an actor so test tasks can mutate it without
    /// taking out a `@unchecked Sendable` loan on a struct.
    private actor Box<T: Sendable> {
        private var value: T
        init(_ value: T) { self.value = value }
        func set(_ v: T) { self.value = v }
        func get() -> T { value }
    }

    /// Wrap a JSON string in a Content-Length-framed envelope.
    private func frame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    /// Parse a framed LSP message into the JSON body dictionary.
    private func parse(_ data: Data) -> [String: Any] {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return [:] }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }

    /// Read an `id` field (Int or NSNumber) into a Swift Int.
    private func intId(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Poll `predicate` until true or the deadline elapses. Returns
    /// true if the predicate became true within the budget.
    private func waitFor(
        _ seconds: TimeInterval = 2.0,
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    /// Convenience: `XCTAssertTrue` over an async predicate. Wraps the
    /// autoclosure rule that bars an `await` directly inside
    /// XCTAssert* arguments.
    private func assertEventually(
        _ seconds: TimeInterval = 2.0,
        _ message: @autoclosure () -> String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @Sendable () async -> Bool
    ) async {
        let ok = await waitFor(seconds, predicate)
        XCTAssertTrue(ok, message(), file: file, line: line)
    }

    // MARK: - Sample Codable types

    private struct Args: Codable, Sendable { let x: Int }
    private struct Reply: Codable, Sendable, Equatable { let ok: Bool }

    // MARK: - 1. In-actor wire ordering

    /// Two sendRequest calls A then B must hit the wire in the same
    /// order the actor accepted them. Regression guard against
    /// "send synchronously, not in a spawned Task" being broken again.
    func test_sendRequest_inActorWireOrdering_matchesCallOrder() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        // Fire A and wait for it to land. Then fire B and wait. If the
        // client ever forked a Task to do the send, the second frame
        // could reorder ahead of the first — this test catches that.
        let aTask = Task {
            try await client.sendRequest(
                method: "spec/alpha",
                params: Args(x: 1),
                resultType: AnyCodable.self
            )
        }
        await assertEventually { await transport.sentMessages().count >= 1 }

        let bTask = Task {
            try await client.sendRequest(
                method: "spec/beta",
                params: Args(x: 2),
                resultType: AnyCodable.self
            )
        }
        await assertEventually { await transport.sentMessages().count >= 2 }

        let sent = await transport.sentMessages()
        let first = parse(sent[0])
        let second = parse(sent[1])
        XCTAssertEqual(first["method"] as? String, "spec/alpha")
        XCTAssertEqual(second["method"] as? String, "spec/beta")
        // Ids are auto-assigned monotonically inside the actor — the
        // wire-order id sequence must also be monotonic.
        XCTAssertEqual(intId(first["id"]), 1)
        XCTAssertEqual(intId(second["id"]), 2)

        // Tear the tasks down so the test exits cleanly.
        aTask.cancel()
        bTask.cancel()
        _ = await aTask.result
        _ = await bTask.result
    }

    // MARK: - 2. Content-Length over 64 MiB cap

    /// A header reporting 100 MB (> 64 MiB cap) must (a) fail every
    /// in-flight request with `.malformedFraming` AND (b) close the
    /// transport. The "and closes transport" half is the load-bearing
    /// invariant for this retrofit.
    func test_contentLength_above64MiB_failsAllPending_andClosesTransport() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let captured = Box<Error?>(nil)
        let inflight = Task {
            do {
                _ = try await client.sendRequest(
                    method: "spec/will-fail",
                    params: Args(x: 0),
                    resultType: AnyCodable.self
                )
            } catch {
                await captured.set(error)
            }
        }
        await assertEventually { await transport.sentMessages().count >= 1 }

        // 100_000_000 > 64 * 1024 * 1024 (67_108_864). Header-only frame
        // is enough: the parser rejects on the Content-Length value
        // before any body is consumed.
        await transport.simulateServerMessage(
            Data("Content-Length: 100000000\r\n\r\n".utf8)
        )
        _ = await inflight.value

        let err = await captured.get()
        guard let lsp = err as? LSPClientError, case .malformedFraming = lsp else {
            XCTFail("expected .malformedFraming, got \(String(describing: err))")
            return
        }

        // Transport must be closed. A direct send (bypassing the client)
        // is the most surgical probe — InMemoryLSPTransport.send throws
        // `.transportClosed` once `close()` has run.
        do {
            try await transport.send(Data("after-fatal".utf8))
            XCTFail("transport must be closed after fatal framing event")
        } catch {
            // expected
        }
    }

    // MARK: - 3. String id round-trip on response

    /// Per LSP, the server may echo our id back as a string even when
    /// we sent it as an integer. The dispatch table's lenient
    /// `string("1")` → `int(1)` fallback must resolve the continuation.
    func test_response_withStringId_resolvesContinuation() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        // The first outbound sendRequest is assigned id 1 (int).
        let sender = Task { () -> Reply in
            try await client.sendRequest(
                method: "spec/string-id",
                params: Args(x: 7),
                resultType: Reply.self
            )
        }
        await assertEventually { await transport.sentMessages().count >= 1 }

        // Server echoes the id as the string "1" — the LSPRequestID
        // fallback path is the contract under test.
        await transport.simulateServerMessage(
            frame(#"{"jsonrpc":"2.0","id":"1","result":{"ok":true}}"#)
        )

        let reply = try await sender.value
        XCTAssertEqual(reply, Reply(ok: true))
    }

    // MARK: - 4. Cancellation removes pending and sends $/cancelRequest

    /// Cancelling the calling task must (a) resume the sendRequest
    /// with CancellationError, (b) remove the entry from `pending`,
    /// AND (c) emit `$/cancelRequest` with the same id.
    func test_sendRequest_cancellation_removesPending_andSendsCancelRequest() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let captured = Box<Error?>(nil)
        let inflight = Task {
            do {
                _ = try await client.sendRequest(
                    method: "spec/long-call",
                    params: Args(x: 1),
                    resultType: AnyCodable.self
                )
            } catch {
                await captured.set(error)
            }
        }

        await assertEventually { await transport.sentMessages().count >= 1 }
        let pendingBefore = await client.pendingCount
        XCTAssertEqual(pendingBefore, 1)

        inflight.cancel()
        _ = await inflight.value

        // (a) CancellationError surfaced to the caller.
        let err = await captured.get()
        XCTAssertTrue(err is CancellationError, "expected CancellationError, got \(String(describing: err))")

        // (c) The $/cancelRequest notification eventually lands on the wire.
        await assertEventually { await transport.sentMessages().count >= 2 }

        // (b) Pending dictionary cleared. Cancellation cleanup happens
        // via a Task spawned in `onCancel`, so poll briefly.
        await assertEventually { await client.pendingCount == 0 }

        let sent = await transport.sentMessages()
        let cancel = parse(sent[1])
        XCTAssertEqual(cancel["method"] as? String, "$/cancelRequest")
        let params = cancel["params"] as? [String: Any]
        XCTAssertEqual(intId(params?["id"]), 1)
    }

    // MARK: - 5. Wall-clock timeout

    /// With a short configured timeout and a server that never replies,
    /// sendRequest must fail with `.timeout` AND emit `$/cancelRequest`
    /// so the server can stop working.
    func test_sendRequest_timeout_failsContinuation_andSendsCancelRequest() async throws {
        let transport = InMemoryLSPTransport()
        // 50 ms is plenty short to keep the test fast yet well above
        // any scheduling jitter on macOS CI hardware.
        let client = LSPClient(transport: transport, requestTimeoutSeconds: 0.05)
        try await client.start()
        defer { Task { await client.close() } }

        do {
            _ = try await client.sendRequest(
                method: "spec/never-replies",
                params: Args(x: 1),
                resultType: AnyCodable.self
            )
            XCTFail("expected sendRequest to throw .timeout")
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .timeout)
        }

        // `handleTimeout` is awaited inside the race-catch before the
        // error returns to the caller, so by the time we observe the
        // throw the $/cancelRequest is already on the wire.
        let sent = await transport.sentMessages()
        XCTAssertEqual(sent.count, 2, "expected original request + $/cancelRequest")
        let cancel = parse(sent[1])
        XCTAssertEqual(cancel["method"] as? String, "$/cancelRequest")
        let params = cancel["params"] as? [String: Any]
        XCTAssertEqual(intId(params?["id"]), 1)
    }

    // MARK: - 6. Response missing both result and error

    /// A JSON-RPC response with no `result` and no `error` is a
    /// protocol violation; the continuation must fail with
    /// `.malformedFraming` rather than resolving with nil.
    func test_response_missingResultAndError_failsContinuation() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        let captured = Box<Error?>(nil)
        let sender = Task {
            do {
                _ = try await client.sendRequest(
                    method: "spec/bogus-response",
                    params: Args(x: 1),
                    resultType: AnyCodable.self
                )
            } catch {
                await captured.set(error)
            }
        }
        await assertEventually { await transport.sentMessages().count >= 1 }

        // Response object with NEITHER result nor error.
        await transport.simulateServerMessage(
            frame(#"{"jsonrpc":"2.0","id":1}"#)
        )
        _ = await sender.value

        let err = await captured.get()
        guard let lsp = err as? LSPClientError, case .malformedFraming = lsp else {
            XCTFail("expected .malformedFraming, got \(String(describing: err))")
            return
        }
    }

    // MARK: - 7. Server-initiated handler DecodingError → -32602

    /// When a server-initiated request handler throws DecodingError,
    /// the client must respond with JSON-RPC error code -32602
    /// (InvalidParams), not the generic -32603 (InternalError).
    func test_serverRequest_decodingError_mapsTo_minus32602() async throws {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        try await client.start()
        defer { Task { await client.close() } }

        // The handler decodes params into a struct whose required key
        // is missing from the inbound payload. JSONDecoder will throw
        // DecodingError.keyNotFound, exercising the -32602 mapping.
        struct Required: Decodable, Sendable { let mustExist: Int }
        await client.setRequestHandler(method: "spec/strict") { params in
            let raw = params ?? AnyCodable(NSNull())
            let data = try JSONEncoder().encode(raw)
            _ = try JSONDecoder().decode(Required.self, from: data)
            return AnyCodable(NSNull())
        }

        // Server initiates a request that the handler will reject.
        await transport.simulateServerMessage(
            frame(#"{"jsonrpc":"2.0","id":99,"method":"spec/strict","params":{"wrong":1}}"#)
        )
        await assertEventually { await transport.sentMessages().count >= 1 }

        let sent = await transport.sentMessages()
        let response = parse(sent[0])
        XCTAssertEqual(intId(response["id"]), 99)
        let errorObj = response["error"] as? [String: Any]
        XCTAssertNotNil(errorObj, "DecodingError must produce a JSON-RPC error response")
        XCTAssertEqual(intId(errorObj?["code"]), -32602)
    }
}
