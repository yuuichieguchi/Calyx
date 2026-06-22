//
//  LSPSessionTests.swift
//  Calyx
//
//  Tests for the LSP 3.18 session actor (`LSPSession`) which sits above
//  `LSPClient` and owns the initialize → initialized handshake, the
//  textDocument open/change/close/save lifecycle, and the
//  shutdown → exit teardown for a single (workspace root, languageId)
//  pair.
//
//  Coverage:
//    - Initial state is `.notStarted`.
//    - `start()` sends `initialize` then `initialized` and stores server
//      capabilities into the embedded `CapabilityRegistry`.
//    - Server `initializeResult.serverInfo` is reflected in `.running`.
//    - Calling `start()` twice throws `.alreadyStarted`.
//    - A server-side error response to `initialize` transitions the state
//      to `.failed`.
//    - `shutdown()` sends `shutdown` request and `exit` notification and
//      closes the transport.
//    - `didOpen` / `didChange` / `didClose` / `didSave` emit the right
//      LSP notifications and maintain the open-document set.
//    - Re-opening the same URI is a no-op (no duplicate notification).
//    - `didChange` on an unopened URI throws `LSPSessionError.documentNotOpen`.
//    - Concurrent `didOpen` for the same URI is deduplicated.
//    - Dynamic `client/registerCapability` updates the capability registry.
//    - `nonisolated` `workspaceRoot` and `languageId` properties are
//      accessible without `await`.
//
//  TDD phase: RED. None of `LSPSession`, `SessionState`, `LSPSessionError`
//  exist yet. This file is expected to fail to compile until the
//  swift-specialist implements them under `Calyx/Features/LSP/`.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPSessionTests: XCTestCase {

    // MARK: - Constants

    private let testWorkspaceRoot = URL(fileURLWithPath: "/tmp/calyx-lsp-session-test")
    private let testLanguageId = "swift"

    // MARK: - Construction helper

    /// Construct a session wired to a fresh in-memory transport.
    /// The session owns the client; the transport is returned so tests
    /// can observe outbound bytes and simulate inbound traffic.
    private func makeSession(
        workspaceRoot: URL? = nil,
        languageId: String? = nil
    ) -> (LSPSession, InMemoryLSPTransport) {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        let session = LSPSession(
            workspaceRoot: workspaceRoot ?? testWorkspaceRoot,
            languageId: languageId ?? testLanguageId,
            client: client
        )
        return (session, transport)
    }

    // MARK: - Framing & JSON helpers

    private func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    private func jsonRPCResponse(id: Int, resultJSON: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#
    }

    private func jsonRPCErrorResponse(id: Int, code: Int, message: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(code),"message":"\#(message)"}}"#
    }

    private func jsonRPCRequest(id: Int, method: String, paramsJSON: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(paramsJSON)}"#
    }

    /// Parse a framed JSON body into a Foundation dictionary.
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

    /// Parse every consecutive framed JSON message in `data` into dictionaries.
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
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
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
        case noInitializeRequest
    }

    /// Poll until predicate becomes true or timeout elapses.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.005,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await predicate()
    }

    // MARK: - Server simulators

    /// JSON literal representing a minimal `InitializeResult` with the
    /// requested provider flags.
    private func initializeResultJSON(
        hoverProvider: Bool = true,
        serverName: String = "test-lsp",
        serverVersion: String? = "0.1.0"
    ) -> String {
        let versionField: String
        if let v = serverVersion {
            versionField = #","version":"\#(v)""#
        } else {
            versionField = ""
        }
        return """
        {"capabilities":{"hoverProvider":\(hoverProvider)},"serverInfo":{"name":"\(serverName)"\(versionField)}}
        """
    }

    /// Watch `transport.sentMessages()` for the first `initialize` request
    /// and reply with the given result/error JSON. Returns when the
    /// response has been pushed into the transport.
    ///
    /// `responseBuilder` receives the JSON-RPC id of the captured request
    /// and returns the JSON-RPC payload (without framing) to deliver back.
    private func respondToInitialize(
        on transport: InMemoryLSPTransport,
        responseBuilder: @escaping (Int) -> String
    ) -> Task<Void, Never> {
        let frame = self.lspFrame
        let parse = self.parseFramedJSON
        return Task {
            for _ in 0..<400 {
                let sent = await transport.sentMessages()
                for data in sent {
                    if let dict = try? parse(data),
                       (dict["method"] as? String) == "initialize",
                       let idAny = dict["id"] {
                        let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                        let body = responseBuilder(idInt)
                        await transport.simulateServerMessage(frame(body))
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // MARK: - 1. Initial state

    func test_initialState_isNotStarted() async throws {
        let (session, _) = makeSession()
        let state = await session.state()
        XCTAssertEqual(state, SessionState.notStarted)
    }

    // MARK: - 2. start sends initialize then initialized

    func test_start_sendsInitializeWithCapabilities_thenInitialized() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }

        try await session.start()
        _ = await responder.value

        // After start completes, sentMessages must contain initialize THEN
        // initialized in that order.
        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))

        // Find index of "initialize" and "initialized" in the sequence.
        let methods = dicts.map { ($0["method"] as? String) ?? "" }
        guard let initIdx = methods.firstIndex(of: "initialize") else {
            return XCTFail("initialize request was not sent. methods=\(methods)")
        }
        guard let initdIdx = methods.firstIndex(of: "initialized") else {
            return XCTFail("initialized notification was not sent. methods=\(methods)")
        }
        XCTAssertLessThan(initIdx, initdIdx, "initialize must precede initialized")

        // The initialize message must include capabilities.
        let initReq = dicts[initIdx]
        XCTAssertNotNil(initReq["id"], "initialize is a request and must carry an id")
        let params = initReq["params"] as? [String: Any]
        XCTAssertNotNil(params?["capabilities"], "initialize must include capabilities")

        // The initialized notification must carry no id.
        let initd = dicts[initdIdx]
        XCTAssertNil(initd["id"], "initialized is a notification")
    }

    // MARK: - 3. initialize result is reflected in CapabilityRegistry

    func test_start_storesServerCapabilities() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON(hoverProvider: true))
        }

        try await session.start()
        _ = await responder.value

        let registry = await session.capabilityRegistry()
        let hoverCapable = await registry.isCapable(method: "textDocument/hover")
        XCTAssertTrue(hoverCapable, "hover capability advertised in initializeResult must be recorded")
    }

    // MARK: - 4. Double start

    func test_start_calledTwice_throwsAlreadyStarted() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }

        try await session.start()
        _ = await responder.value

        do {
            try await session.start()
            XCTFail("second start() must throw")
        } catch let err as LSPSessionError {
            XCTAssertEqual(err, .alreadyStarted)
        }
    }

    // MARK: - 5. initialize error → failed state

    func test_start_failedInitialize_setsFailedState() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCErrorResponse(id: id, code: -32002, message: "init failed")
        }

        do {
            try await session.start()
            XCTFail("start() must throw when initialize errors")
        } catch {
            // expected; specific error type is implementation-defined but
            // should surface the underlying server error.
        }
        _ = await responder.value

        let state = await session.state()
        switch state {
        case .failed:
            break
        default:
            XCTFail("expected .failed state after initialize error, got \(state)")
        }
    }

    // MARK: - 5b. initialize failure closes the underlying client

    /// Regression: `installServerRequestHandlers()` registers closures
    /// that strongly capture `self` to establish the intentional
    /// `LSPSession ↔ LSPClient ↔ closure ↔ LSPSession` retain cycle.
    /// On the success path the cycle is broken by `shutdown()`'s
    /// `client.close()`. On the failure path (initialize errors out
    /// after the handlers have already been installed), `start()` must
    /// also call `client.close()` so the cycle does not leak the
    /// session, the client, and the receive task forever. We observe
    /// the close via the transport — closed transports reject `send`
    /// with `LSPClientError.transportClosed`.
    func test_start_failedInitialize_closesUnderlyingTransport() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCErrorResponse(id: id, code: -32002, message: "init failed")
        }

        do {
            try await session.start()
            XCTFail("start() must throw when initialize errors")
        } catch {
            // expected
        }
        _ = await responder.value

        // `client.close()` cascades to `transport.close()`, after which
        // any subsequent `send` must fail with `.transportClosed`.
        do {
            try await transport.send(Data("x".utf8))
            XCTFail(
                "transport must be closed after initialize failure — LSPSession.start() must call client.close() to break the handler retain cycle"
            )
        } catch let err as LSPClientError {
            XCTAssertEqual(err, .transportClosed)
        } catch {
            XCTFail("expected LSPClientError.transportClosed, got \(error)")
        }
    }

    // MARK: - 6. ServerInfo surfaced in .running

    func test_state_running_includesServerInfo() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(
                id: id,
                resultJSON: self.initializeResultJSON(
                    serverName: "rust-analyzer",
                    serverVersion: "0.4.2"
                )
            )
        }

        try await session.start()
        _ = await responder.value

        let state = await session.state()
        switch state {
        case .running(let info):
            XCTAssertEqual(info?.name, "rust-analyzer")
            XCTAssertEqual(info?.version, "0.4.2")
        default:
            XCTFail("expected .running, got \(state)")
        }
    }

    // MARK: - 7. shutdown sends shutdown + exit, closes transport

    func test_shutdown_sendsShutdownAndExit_andClosesTransport() async throws {
        let (session, transport) = makeSession()

        let initResponder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await initResponder.value

        // Respond to the shutdown request that the session will send.
        let shutdownResponder = Task { [transport] in
            let frame = self.lspFrame
            let parse = self.parseFramedJSON
            for _ in 0..<400 {
                let sent = await transport.sentMessages()
                for data in sent {
                    guard let dict = try? parse(data),
                          (dict["method"] as? String) == "shutdown",
                          let idAny = dict["id"]
                    else { continue }
                    let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                    let resp = self.jsonRPCResponse(id: idInt, resultJSON: "null")
                    await transport.simulateServerMessage(frame(resp))
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        try await session.shutdown()
        _ = await shutdownResponder.value

        // The combined sentMessages must include both `shutdown` (request)
        // and `exit` (notification) in that order.
        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let methods = dicts.map { ($0["method"] as? String) ?? "" }
        guard let shutdownIdx = methods.firstIndex(of: "shutdown") else {
            return XCTFail("shutdown request was not sent. methods=\(methods)")
        }
        guard let exitIdx = methods.firstIndex(of: "exit") else {
            return XCTFail("exit notification was not sent. methods=\(methods)")
        }
        XCTAssertLessThan(shutdownIdx, exitIdx, "shutdown must precede exit")

        // exit must be a notification (no id).
        XCTAssertNil(dicts[exitIdx]["id"])

        // Transport must subsequently reject sends.
        do {
            try await transport.send(Data("x".utf8))
            XCTFail("transport must be closed after session.shutdown()")
        } catch {
            // expected
        }

        let state = await session.state()
        XCTAssertEqual(state, SessionState.shutdown)
    }

    // MARK: - 8. didOpen sends params and updates open set

    func test_didOpen_sendsParams() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let uri = "file:///tmp/calyx-lsp-session-test/main.swift"
        try await session.didOpen(uri: uri, languageId: "swift", version: 1, text: "print(1)")

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let openMsgs = dicts.filter { ($0["method"] as? String) == "textDocument/didOpen" }
        XCTAssertEqual(openMsgs.count, 1, "exactly one didOpen must be sent")

        let params = openMsgs[0]["params"] as? [String: Any]
        let td = params?["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, uri)
        XCTAssertEqual(td?["languageId"] as? String, "swift")
        XCTAssertEqual(td?["version"] as? Int, 1)
        XCTAssertEqual(td?["text"] as? String, "print(1)")

        let openSet = await session.openDocuments()
        XCTAssertTrue(openSet.contains(uri))
    }

    // MARK: - 9. didOpen twice for same URI is a no-op

    func test_didOpen_secondTime_isNoOp() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let uri = "file:///tmp/calyx-lsp-session-test/main.swift"
        try await session.didOpen(uri: uri, languageId: "swift", version: 1, text: "v1")
        try await session.didOpen(uri: uri, languageId: "swift", version: 2, text: "v2")

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let openMsgs = dicts.filter { ($0["method"] as? String) == "textDocument/didOpen" }
        XCTAssertEqual(openMsgs.count, 1, "second didOpen for same URI must be a no-op")

        let openSet = await session.openDocuments()
        XCTAssertEqual(openSet, [uri])
    }

    // MARK: - 10. didChange on unopened URI throws

    func test_didChange_unopenedDocument_throws() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let uri = "file:///tmp/calyx-lsp-session-test/missing.swift"
        do {
            try await session.didChange(
                uri: uri,
                version: 2,
                changes: [.full(text: "anything")]
            )
            XCTFail("didChange on unopened document must throw")
        } catch let err as LSPSessionError {
            XCTAssertEqual(err, LSPSessionError.documentNotOpen(uri))
        }
    }

    // MARK: - 11. didChange sends incremental + full mix

    func test_didChange_sendsChanges() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let uri = "file:///tmp/calyx-lsp-session-test/main.swift"
        try await session.didOpen(uri: uri, languageId: "swift", version: 1, text: "old body")

        let changes: [TextDocumentContentChangeEvent] = [
            .incremental(
                range: LSPRange(
                    start: Position(line: 0, character: 0),
                    end: Position(line: 0, character: 3)
                ),
                rangeLength: 3,
                text: "NEW"
            ),
            .full(text: "wholly replaced")
        ]
        try await session.didChange(uri: uri, version: 2, changes: changes)

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let changeMsgs = dicts.filter { ($0["method"] as? String) == "textDocument/didChange" }
        XCTAssertEqual(changeMsgs.count, 1, "exactly one didChange must be sent")

        let params = changeMsgs[0]["params"] as? [String: Any]
        let td = params?["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, uri)
        XCTAssertEqual(td?["version"] as? Int, 2)

        let contentChanges = params?["contentChanges"] as? [[String: Any]]
        XCTAssertEqual(contentChanges?.count, 2)

        // First entry: incremental (has `range`).
        let first = contentChanges?[0]
        XCTAssertNotNil(first?["range"], "incremental change must serialise `range`")
        XCTAssertEqual(first?["text"] as? String, "NEW")

        // Second entry: full (no `range`).
        let second = contentChanges?[1]
        XCTAssertNil(second?["range"], "full change must not include `range`")
        XCTAssertEqual(second?["text"] as? String, "wholly replaced")
    }

    // MARK: - 12. didClose removes from open set and sends notification

    func test_didClose_sendsAndRemovesFromOpenSet() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let uri = "file:///tmp/calyx-lsp-session-test/main.swift"
        try await session.didOpen(uri: uri, languageId: "swift", version: 1, text: "v1")
        try await session.didClose(uri: uri)

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let closeMsgs = dicts.filter { ($0["method"] as? String) == "textDocument/didClose" }
        XCTAssertEqual(closeMsgs.count, 1, "exactly one didClose must be sent")

        let params = closeMsgs[0]["params"] as? [String: Any]
        let td = params?["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, uri)

        let openSet = await session.openDocuments()
        XCTAssertFalse(openSet.contains(uri))
    }

    // MARK: - 13. didSave with and without text

    func test_didSave_sendsParams_withAndWithoutText() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let uri = "file:///tmp/calyx-lsp-session-test/main.swift"
        try await session.didOpen(uri: uri, languageId: "swift", version: 1, text: "body")

        try await session.didSave(uri: uri, text: nil)
        try await session.didSave(uri: uri, text: "saved body")

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let saveMsgs = dicts.filter { ($0["method"] as? String) == "textDocument/didSave" }
        XCTAssertEqual(saveMsgs.count, 2, "two didSave notifications expected")

        let first = saveMsgs[0]["params"] as? [String: Any]
        XCTAssertEqual((first?["textDocument"] as? [String: Any])?["uri"] as? String, uri)
        XCTAssertNil(first?["text"], "first didSave must omit `text` field entirely")

        let second = saveMsgs[1]["params"] as? [String: Any]
        XCTAssertEqual(second?["text"] as? String, "saved body")
    }

    // MARK: - 14. nonisolated workspaceRoot / languageId

    func test_unknownLanguageId_workspaceRoot_propertiesAccessible() {
        // Construct with a non-default language id and verify the
        // nonisolated property surface works synchronously (no `await`).
        let workspaceRoot = URL(fileURLWithPath: "/private/var/lsp-session-test")
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        let session = LSPSession(
            workspaceRoot: workspaceRoot,
            languageId: "rust",
            client: client
        )
        XCTAssertEqual(session.languageId, "rust")
        XCTAssertEqual(session.workspaceRoot, workspaceRoot)
    }

    // MARK: - 15. Concurrent didOpen for same URI is deduplicated

    func test_concurrentDidOpen_dedup() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let uri = "file:///tmp/calyx-lsp-session-test/race.swift"

        async let a: Void = session.didOpen(uri: uri, languageId: "swift", version: 1, text: "A")
        async let b: Void = session.didOpen(uri: uri, languageId: "swift", version: 1, text: "B")
        async let c: Void = session.didOpen(uri: uri, languageId: "swift", version: 1, text: "C")
        _ = try await (a, b, c)

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let openMsgs = dicts.filter { ($0["method"] as? String) == "textDocument/didOpen" }
        XCTAssertEqual(openMsgs.count, 1, "concurrent didOpen for same URI must be deduplicated")

        let openSet = await session.openDocuments()
        XCTAssertEqual(openSet, [uri])
    }

    // MARK: - 16. Dynamic capability registration via client/registerCapability

    func test_capabilityRegistry_includesDynamicRegistration() async throws {
        let (session, transport) = makeSession()

        // Start with an InitializeResult that does NOT advertise rename.
        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        // Sanity: rename is NOT statically capable yet.
        let registry = await session.capabilityRegistry()
        let renameBefore = await registry.isCapable(method: "textDocument/rename")
        XCTAssertFalse(renameBefore)

        // Simulate the server sending a `client/registerCapability` request.
        // The session is expected to install a handler on its LSPClient that
        // forwards the registrations into its CapabilityRegistry.
        let payload = """
        {"registrations":[{"id":"rename-1","method":"textDocument/rename"}]}
        """
        let serverReq = jsonRPCRequest(id: 42, method: "client/registerCapability", paramsJSON: payload)
        await transport.simulateServerMessage(lspFrame(serverReq))

        let ok = await waitUntil {
            let registry = await session.capabilityRegistry()
            return await registry.isCapable(method: "textDocument/rename")
        }
        XCTAssertTrue(ok, "dynamic registration must be reflected in the capability registry")
    }
}
