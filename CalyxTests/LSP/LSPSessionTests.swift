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

    // MARK: - Regression test helpers (bug fixes 1-6)

    /// Build a fresh per-test temp directory; auto-cleaned in teardown.
    private func makeTempDir(line: UInt = #line) throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LSPSessionTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: raw, withIntermediateDirectories: true
        )
        let url = raw.resolvingSymlinksInPath()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Build a real `LSPSessionPersistence` backed by a clean per-test
    /// temp file. Used so regression tests for the persist/remove
    /// pipeline observe real disk side effects, while still scoping
    /// every test to its own storage URL.
    private func makePersistence() throws -> LSPSessionPersistence {
        let dir = try makeTempDir()
        let storage = dir.appendingPathComponent("sessions.json")
        return LSPSessionPersistence(storageURL: storage)
    }

    /// `makeSession` variant that also threads a real persistence into
    /// the freshly built `LSPSession`. Returns the persistence so tests
    /// that need to inspect the on-disk snapshot can do so.
    private func makeSessionWithPersistence() throws -> (LSPSession, InMemoryLSPTransport, LSPSessionPersistence) {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        let persistence = try makePersistence()
        let session = LSPSession(
            workspaceRoot: testWorkspaceRoot,
            languageId: testLanguageId,
            client: client,
            persistence: persistence
        )
        return (session, transport, persistence)
    }

    /// Drive both `initialize` and `shutdown` responses on `transport`
    /// for as long as the returned Task is alive. Caps polling so the
    /// loop terminates even if the test forgets to cancel it.
    private func driveInitAndShutdown(on transport: InMemoryLSPTransport) -> Task<Void, Never> {
        let frame = self.lspFrame
        let parse = self.parseFramedJSON
        return Task {
            var initAnswered = false
            var shutdownAnswered: Set<Int> = []
            for _ in 0..<1000 {
                if Task.isCancelled { return }
                let sent = await transport.sentMessages()
                for data in sent {
                    guard let dict = try? parse(data),
                          let method = dict["method"] as? String,
                          let idAny = dict["id"] else { continue }
                    let id: Int
                    if let i = idAny as? Int {
                        id = i
                    } else if let n = idAny as? NSNumber {
                        id = n.intValue
                    } else {
                        continue
                    }
                    if method == "initialize", !initAnswered {
                        let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{},"serverInfo":{"name":"mock"}}}"#
                        await transport.simulateServerMessage(frame(resp))
                        initAnswered = true
                    } else if method == "shutdown", !shutdownAnswered.contains(id) {
                        let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":null}"#
                        await transport.simulateServerMessage(frame(resp))
                        shutdownAnswered.insert(id)
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // MARK: - Regression 1: shutdown() is idempotent

    /// Bug: calling `shutdown()` twice walks through the full teardown
    /// sequence twice. Most visibly, the second call enqueues a second
    /// `scheduleRemoveSnapshot()` Task onto the persist chain and waits
    /// up to 2s for it to drain.
    ///
    /// The session must early-return once it has already reached
    /// `.shutdown` so the persist pipeline is not perturbed.
    func test_shutdown_isIdempotent_doesNotReissueRemoveSnapshot() async throws {
        let (session, transport, _) = try makeSessionWithPersistence()
        let driver = driveInitAndShutdown(on: transport)
        try await session.start()

        try await session.shutdown()
        let firstCallCount = await session.scheduleRemoveSnapshotCallCountForTests
        XCTAssertEqual(
            firstCallCount, 1,
            "sanity: first shutdown() must schedule exactly one remove, got \(firstCallCount)"
        )

        // Second shutdown — should early-return without re-issuing a
        // remove. Buggy code falls through and calls
        // `scheduleRemoveSnapshot()` again.
        try await session.shutdown()
        let secondCallCount = await session.scheduleRemoveSnapshotCallCountForTests
        XCTAssertEqual(
            secondCallCount, 1,
            "second shutdown() must NOT schedule another remove (idempotency) — got \(secondCallCount) total calls"
        )

        driver.cancel()
    }

    // MARK: - Regression 2: server-initiated request handlers installed before client.start()

    /// Bug: the session calls `client.start()` (which starts pumping
    /// the transport) BEFORE installing server-initiated request
    /// handlers. Any server-originated request that arrives in the gap
    /// is dispatched against an empty handler dictionary and gets back
    /// a `-32601 MethodNotFound` error, which some strict servers treat
    /// as fatal.
    ///
    /// A purely behavioural test (buffer a request before `start()`
    /// and look for `-32601` on the wire) is timing-dependent: actor
    /// scheduling on macOS routinely runs the session's
    /// `setRequestHandler` job before the receive task's first
    /// `ingest` job, masking the bug. To detect the bug
    /// deterministically we verify the underlying invariant via the
    /// TEST-ONLY sequence counters stamped from inside `start()`:
    /// `installServerRequestHandlers()` MUST be invoked before
    /// `client.start()` so the handler dictionary is already populated
    /// when the receive task begins consuming bytes.
    func test_serverRequestHandlersInstalledBeforeClientStart() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        let clientStartSeq = await session.testOnlyClientStartSeq
        let installSeq = await session.testOnlyInstallHandlersSeq

        XCTAssertGreaterThan(
            clientStartSeq, 0,
            "client.start() stamp was never recorded; instrumentation hook may be missing"
        )
        XCTAssertGreaterThan(
            installSeq, 0,
            "installServerRequestHandlers stamp was never recorded; instrumentation hook may be missing"
        )
        XCTAssertLessThan(
            installSeq, clientStartSeq,
            "server-request handlers must be installed BEFORE client.start() so the receive loop never dispatches against an empty handler dictionary — got installSeq=\(installSeq), clientStartSeq=\(clientStartSeq)"
        )
    }

    // MARK: - Regression 3: drain timeout does not leak the loser teardown Task

    /// Bug: the drain race in `shutdown()` spawns two unstructured
    /// Tasks (a drain observer and a 2-second sleep timer) and resumes
    /// the caller on whichever wins. The loser is never cancelled — so
    /// even when the persist completes in <1ms, the sleep Task lives
    /// the full 2 seconds, holding the `OSAllocatedUnfairLock` capture
    /// and (post-fix) any other state surfaced through `[weak self]`.
    ///
    /// The fix must cancel the loser. Verified by observing that the
    /// in-flight teardown task counter returns to zero soon after the
    /// caller resumes from `shutdown()`.
    func test_shutdown_drainCompletes_doesNotLeakLoserTeardownTask() async throws {
        let (session, transport, _) = try makeSessionWithPersistence()
        let driver = driveInitAndShutdown(on: transport)
        try await session.start()

        try await session.shutdown()

        // Wait a generous slice for the drain observer Task to
        // complete (it should be near-instant since persistence on
        // a local tmpfs is sub-millisecond). The sleep Task in the
        // buggy code is hardcoded to 2s.
        try? await Task.sleep(nanoseconds: 300_000_000) // 300ms

        let inflight = await session.inflightTeardownTaskCountForTests
        XCTAssertEqual(
            inflight, 0,
            "loser teardown Task must be cancelled after the drain race resolves — got \(inflight) Task(s) still alive 300ms after shutdown() returned"
        )

        driver.cancel()
    }

    // MARK: - Regression 4: shutdown() before start() is a no-op on the wire

    /// Bug: when the session is still in `.notStarted` (or `.shutdown` /
    /// `.failed`), `shutdown()` does NOT early-return. It walks through
    /// the full sequence: `client.sendRequest("shutdown")`,
    /// `client.sendNotification("exit")`, `client.close()`,
    /// `scheduleRemoveSnapshot()` and the 2-second drain.
    ///
    /// The first two calls happen to be no-ops via `try?` because the
    /// LSPClient itself is `.notStarted`, but they still execute. The
    /// fix is to early-return when state is one of the terminal /
    /// pre-handshake variants.
    func test_shutdown_beforeStart_doesNotSendAnyLSPMethods() async throws {
        let (session, transport) = makeSession()

        // No start() — session is in `.notStarted`.
        try await session.shutdown()

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        let methods = dicts.compactMap { $0["method"] as? String }
        XCTAssertTrue(
            methods.isEmpty,
            "shutdown() before start() must not put any LSP method on the wire — observed: \(methods)"
        )

        // Also confirm the scheduleRemoveSnapshot path was NOT walked.
        let removeCount = await session.scheduleRemoveSnapshotCallCountForTests
        XCTAssertEqual(
            removeCount, 0,
            "shutdown() before start() must not schedule a remove snapshot — got \(removeCount)"
        )
    }

    // MARK: - Regression 5: server-request handlers check sessionState

    /// Bug: the `[self]`-capturing server-request handlers (e.g.
    /// `workspace/applyEdit`, `window/showMessage`,
    /// `window/showDocument`) mutate session state unconditionally,
    /// without consulting `sessionState`. A request that lands while
    /// the session is `.shutdown` (or `.failed`) will still enqueue
    /// onto `pendingApplyEditQueue`, append into `serverMessages`,
    /// etc.
    ///
    /// We simulate the "post-shutdown" condition by flipping
    /// `sessionState` to `.shutdown` directly (via the TEST-ONLY
    /// accessor) without driving the full `shutdown()` path — this
    /// keeps the transport open and the receive loop alive so the
    /// in-memory message can actually reach the handler dictionary
    /// for the assertion to be meaningful.
    func test_serverRequestHandler_dropsMutationsWhenSessionShutdown() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value

        // Sanity: queue is empty before we flip to shutdown.
        let queueBefore = await session.pendingApplyEdits()
        XCTAssertTrue(queueBefore.isEmpty, "queue must be empty before applyEdit")

        // Simulate post-shutdown by directly setting state.
        await session.setSessionStateForTests(.shutdown)

        // Inject a workspace/applyEdit. The handler closure (captured
        // [self]) will execute on the LSPClient's dispatcher; the
        // buggy version unconditionally enqueues into
        // `pendingApplyEditQueue`. The fix must check `sessionState`
        // and drop the mutation.
        let editPayload = #"{"label":"test-edit","edit":{"changes":{}}}"#
        let req = jsonRPCRequest(id: 8001, method: "workspace/applyEdit", paramsJSON: editPayload)
        await transport.simulateServerMessage(lspFrame(req))

        // Give the receive loop and handler Task time to run.
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let queueAfter = await session.pendingApplyEdits()
        XCTAssertTrue(
            queueAfter.isEmpty,
            "server-request handlers must NOT mutate session state once the session is `.shutdown` — got \(queueAfter.count) leaked apply edit(s)"
        )
    }

    // MARK: - Regression 6: pendingPersistTask chain depth stays bounded

    /// Bug: `pendingPersistTask` is a linked list of Tasks where each
    /// new Task captures `prior` via `await prior?.value`. Across a
    /// burst of didOpen/didClose cycles the chain depth can grow to
    /// match the burst size — each captured closure holds a strong
    /// reference to its predecessor until the closure body returns.
    ///
    /// The fix is some flavour of structured queue (e.g. an actor with
    /// a single worker task, or a coalescing scheme) that keeps the
    /// chain depth bounded regardless of burst size.
    func test_persistChain_doesNotGrowUnboundedlyAcrossRapidCycles() async throws {
        let (session, transport, _) = try makeSessionWithPersistence()
        let driver = driveInitAndShutdown(on: transport)
        try await session.start()

        // Rapidly schedule 25 didOpen/didClose cycles. Each cycle is
        // two `schedulePersistSnapshot` calls (one for didOpen, one
        // for didClose), so 50 persist Tasks are scheduled in quick
        // succession.
        let burstSize = 25
        for i in 0..<burstSize {
            let uri = "file:///tmp/calyx-lsp-session-test/burst-\(i).swift"
            try await session.didOpen(uri: uri, languageId: "swift", version: 1, text: "x")
            try await session.didClose(uri: uri)
        }

        let peak = await session.pendingPersistChainPeakDepthForTests
        // A correctly bounded chain stays at most 2 deep (one in-flight
        // persist plus the next pending task). The buggy chain grows
        // monotonically with the burst — we allow a generous threshold
        // (10) so this test isn't flaky on fast machines that drain
        // some Tasks mid-burst.
        XCTAssertLessThan(
            peak, burstSize,
            "pendingPersistTask chain depth must not grow with burst size — peak=\(peak) burst=\(burstSize * 2)"
        )

        driver.cancel()
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
