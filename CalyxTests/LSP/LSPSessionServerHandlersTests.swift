//
//  LSPSessionServerHandlersTests.swift
//  Calyx
//
//  Tests for the server -> client direction handlers that `LSPSession` is
//  expected to install during `start()`, in addition to the existing
//  `client/registerCapability`, `client/unregisterCapability` and
//  `window/workDoneProgress/create` handlers.
//
//  New surface under test:
//    - window/showMessage           (notification)  -> append to ServerLog
//    - window/logMessage            (notification)  -> append to ServerLog
//    - window/showMessageRequest    (request)       -> append + respond null
//    - window/showDocument          (request)       -> append + respond
//                                                     `{ "success": true }`
//    - workspace/configuration      (request)       -> reply with a null
//                                                     array of the same
//                                                     length as `items`
//    - workspace/applyEdit          (request)       -> enqueue into the
//                                                     `pendingApplyEdits`
//                                                     queue and respond
//                                                     `{ "applied": false }`
//    - workspace/workspaceFolders   (request)       -> respond with a
//                                                     single-entry folder
//                                                     pointing at
//                                                     `workspaceRoot`.
//
//  And the new actor-isolated introspection methods:
//    - `recentServerMessages()`
//    - `pendingApplyEdits()`
//    - `clearServerMessages()`
//    - `consumePendingApplyEdit(id:)`
//
//  TDD phase: RED. None of these handlers (nor the `ServerLogEntry` and
//  `PendingApplyEdit` value types) exist yet on `LSPSession`. This file is
//  expected to fail to compile until the swift-specialist implements the
//  surface under `Calyx/Features/LSP/LSPSession.swift`.
//
//  Spec entry points:
//    - window/showMessage:         https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessage
//    - window/showMessageRequest:  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessageRequest
//    - window/logMessage:          https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_logMessage
//    - window/showDocument:        https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showDocument
//    - workspace/configuration:    https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_configuration
//    - workspace/applyEdit:        https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_applyEdit
//    - workspace/workspaceFolders: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_workspaceFolders
//

import XCTest
@testable import Calyx

@MainActor
final class LSPSessionServerHandlersTests: XCTestCase {

    // MARK: - Constants

    private let testWorkspaceRoot = URL(fileURLWithPath: "/tmp/calyx-lsp-session-server-handlers-test")
    private let testLanguageId = "swift"

    // MARK: - Construction helper

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

    private func jsonRPCRequest(id: Int, method: String, paramsJSON: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(paramsJSON)}"#
    }

    private func jsonRPCNotification(method: String, paramsJSON: String) -> String {
        return #"{"jsonrpc":"2.0","method":"\#(method)","params":\#(paramsJSON)}"#
    }

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
    }

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

    /// Poll `transport.sentMessages()` for a JSON-RPC response whose `id`
    /// matches `requestId` (response = no `method` key, has `id`). Returns
    /// the parsed message body or `nil` on timeout.
    private func waitForResponse(
        requestId: Int,
        on transport: InMemoryLSPTransport,
        timeout: TimeInterval = 2.0
    ) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sent = await transport.sentMessages()
            let joined = Data(sent.reduce(into: Data()) { $0.append($1) })
            if let dicts = try? parseAllFramedJSON(joined) {
                for dict in dicts {
                    if dict["method"] == nil,
                       let idAny = dict["id"],
                       let idInt = (idAny as? Int) ?? (idAny as? NSNumber)?.intValue,
                       idInt == requestId {
                        return dict
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    // MARK: - Server simulators

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

    /// Start a session and wait for it to reach `.running`.
    private func startedSession(
        workspaceRoot: URL? = nil
    ) async throws -> (LSPSession, InMemoryLSPTransport) {
        let (session, transport) = makeSession(workspaceRoot: workspaceRoot)
        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }
        try await session.start()
        _ = await responder.value
        return (session, transport)
    }

    // MARK: - 1. window/showMessage notification appends

    func test_windowShowMessage_appendsToServerMessages() async throws {
        let (session, transport) = try await startedSession()

        let params = #"{"type":3,"message":"hello from server"}"#
        let msg = jsonRPCNotification(method: "window/showMessage", paramsJSON: params)
        await transport.simulateServerMessage(lspFrame(msg))

        let arrived = await waitUntil {
            await !session.recentServerMessages().isEmpty
        }
        XCTAssertTrue(arrived, "showMessage notification must be appended to server messages")

        let log = await session.recentServerMessages()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.source, .showMessage)
        XCTAssertEqual(log.first?.type, 3)
        XCTAssertEqual(log.first?.message, "hello from server")
    }

    // MARK: - 2. window/logMessage notification appends

    func test_windowLogMessage_appendsToServerMessages() async throws {
        let (session, transport) = try await startedSession()

        let params = #"{"type":4,"message":"verbose log line"}"#
        let msg = jsonRPCNotification(method: "window/logMessage", paramsJSON: params)
        await transport.simulateServerMessage(lspFrame(msg))

        let arrived = await waitUntil {
            await !session.recentServerMessages().isEmpty
        }
        XCTAssertTrue(arrived, "logMessage notification must be appended to server messages")

        let log = await session.recentServerMessages()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.source, .logMessage)
        XCTAssertEqual(log.first?.type, 4)
        XCTAssertEqual(log.first?.message, "verbose log line")
    }

    // MARK: - 3. window/showMessageRequest appends and responds null

    func test_windowShowMessageRequest_appendsAndRespondsWithNull() async throws {
        let (session, transport) = try await startedSession()

        let requestId = 4242
        let params = #"{"type":2,"message":"pick one","actions":[{"title":"OK"}]}"#
        let req = jsonRPCRequest(id: requestId, method: "window/showMessageRequest", paramsJSON: params)
        await transport.simulateServerMessage(lspFrame(req))

        // Response observed on the wire.
        let response = await waitForResponse(requestId: requestId, on: transport)
        guard let response else {
            return XCTFail("session must respond to window/showMessageRequest")
        }
        XCTAssertNil(response["error"], "showMessageRequest response must not be an error")
        XCTAssertTrue(
            response["result"] is NSNull,
            "showMessageRequest response result must be JSON null, got \(String(describing: response["result"]))"
        )

        // Side effect: appended to ServerLog with source .showMessageRequest.
        let log = await session.recentServerMessages()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.source, .showMessageRequest)
        XCTAssertEqual(log.first?.type, 2)
        XCTAssertEqual(log.first?.message, "pick one")
    }

    // MARK: - 4. window/showDocument responds with `{ "success": true }`

    func test_windowShowDocument_respondsWithSuccess() async throws {
        let (session, transport) = try await startedSession()

        let requestId = 555
        let params = #"{"uri":"file:///tmp/x.swift","takeFocus":true}"#
        let req = jsonRPCRequest(id: requestId, method: "window/showDocument", paramsJSON: params)
        await transport.simulateServerMessage(lspFrame(req))

        let response = await waitForResponse(requestId: requestId, on: transport)
        guard let response else {
            return XCTFail("session must respond to window/showDocument")
        }
        XCTAssertNil(response["error"], "showDocument response must not be an error")
        guard let result = response["result"] as? [String: Any] else {
            return XCTFail("showDocument result must be an object, got \(String(describing: response["result"]))")
        }
        XCTAssertEqual(result["success"] as? Bool, true)

        // Side effect: appended to ServerLog with source .showDocument.
        let log = await session.recentServerMessages()
        XCTAssertEqual(log.count, 1)
        XCTAssertEqual(log.first?.source, .showDocument)
    }

    // MARK: - 5. workspace/configuration responds with a null array matching items

    func test_workspaceConfiguration_respondsWithNullArray() async throws {
        let (_, transport) = try await startedSession()

        let requestId = 9001
        let params = #"{"items":[{"section":"swift"},{"section":"editor"}]}"#
        let req = jsonRPCRequest(id: requestId, method: "workspace/configuration", paramsJSON: params)
        await transport.simulateServerMessage(lspFrame(req))

        let response = await waitForResponse(requestId: requestId, on: transport)
        guard let response else {
            return XCTFail("session must respond to workspace/configuration")
        }
        XCTAssertNil(response["error"], "configuration response must not be an error")
        guard let arr = response["result"] as? [Any] else {
            return XCTFail("configuration result must be an array, got \(String(describing: response["result"]))")
        }
        XCTAssertEqual(arr.count, 2, "result array length must match items length")
        XCTAssertTrue(arr.allSatisfy { $0 is NSNull }, "every entry must be JSON null at session level")
    }

    // MARK: - 6. workspace/applyEdit enqueues + responds `{ applied: false }`

    func test_workspaceApplyEdit_appendsToPendingQueue() async throws {
        let (session, transport) = try await startedSession()

        let requestId = 7777
        // A minimal WorkspaceEdit with a single text edit on a file URI.
        let params = """
        {
            "label": "Rename foo to bar",
            "edit": {
                "changes": {
                    "file:///tmp/x.swift": [
                        {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"bar"}
                    ]
                }
            }
        }
        """
        let req = jsonRPCRequest(id: requestId, method: "workspace/applyEdit", paramsJSON: params)
        await transport.simulateServerMessage(lspFrame(req))

        let response = await waitForResponse(requestId: requestId, on: transport)
        guard let response else {
            return XCTFail("session must respond to workspace/applyEdit")
        }
        XCTAssertNil(response["error"], "applyEdit response must not be an error")
        guard let result = response["result"] as? [String: Any] else {
            return XCTFail("applyEdit result must be an object, got \(String(describing: response["result"]))")
        }
        XCTAssertEqual(
            result["applied"] as? Bool,
            false,
            "applyEdit must default to applied=false at the session level (AI reviews and applies later)"
        )

        // Side effect: enqueued in pendingApplyEdits.
        let queue = await session.pendingApplyEdits()
        XCTAssertEqual(queue.count, 1, "applyEdit must enqueue exactly one entry")
        XCTAssertEqual(queue.first?.label, "Rename foo to bar")
    }

    // MARK: - 7. workspace/workspaceFolders returns current root

    func test_workspaceWorkspaceFolders_returnsCurrentRoot() async throws {
        let customRoot = URL(fileURLWithPath: "/tmp/calyx-lsp-session-server-handlers-test/sub-root")
        let (_, transport) = try await startedSession(workspaceRoot: customRoot)

        let requestId = 11
        // workspace/workspaceFolders has no params — but jsonRPCRequest
        // requires a body. Use an empty object; the spec allows servers to
        // omit params entirely for parameterless requests.
        let req = jsonRPCRequest(id: requestId, method: "workspace/workspaceFolders", paramsJSON: "null")
        await transport.simulateServerMessage(lspFrame(req))

        let response = await waitForResponse(requestId: requestId, on: transport)
        guard let response else {
            return XCTFail("session must respond to workspace/workspaceFolders")
        }
        XCTAssertNil(response["error"], "workspaceFolders response must not be an error")
        guard let arr = response["result"] as? [[String: Any]] else {
            return XCTFail("workspaceFolders result must be an array of folders, got \(String(describing: response["result"]))")
        }
        XCTAssertEqual(arr.count, 1, "session must report a single workspace folder")
        XCTAssertEqual(arr.first?["uri"] as? String, customRoot.absoluteString)
        XCTAssertEqual(arr.first?["name"] as? String, customRoot.lastPathComponent)
    }

    // MARK: - 8. recentServerMessages caps at the session-configured maximum (100)

    func test_recentServerMessages_capsAtN() async throws {
        let (session, transport) = try await startedSession()

        // Send 105 logMessage notifications. The session must retain at most
        // 100 (the documented cap) and drop the oldest.
        let total = 105
        for i in 0..<total {
            let params = #"{"type":4,"message":"line-\#(i)"}"#
            let msg = jsonRPCNotification(method: "window/logMessage", paramsJSON: params)
            await transport.simulateServerMessage(lspFrame(msg))
        }

        let stabilized = await waitUntil(timeout: 3.0) {
            await session.recentServerMessages().count == 100
        }
        XCTAssertTrue(stabilized, "recentServerMessages must cap at 100 entries")

        let log = await session.recentServerMessages()
        // The oldest 5 must be dropped: first surviving message is "line-5".
        XCTAssertEqual(log.first?.message, "line-5", "oldest entries must be evicted, expected line-5 first")
        XCTAssertEqual(log.last?.message, "line-\(total - 1)", "newest entry must be line-\(total - 1)")
    }

    // MARK: - 9. clearServerMessages empties the log

    func test_clearServerMessages_empties() async throws {
        let (session, transport) = try await startedSession()

        // Seed the log with three notifications.
        for i in 0..<3 {
            let params = #"{"type":3,"message":"m-\#(i)"}"#
            let msg = jsonRPCNotification(method: "window/showMessage", paramsJSON: params)
            await transport.simulateServerMessage(lspFrame(msg))
        }
        let seeded = await waitUntil {
            await session.recentServerMessages().count == 3
        }
        XCTAssertTrue(seeded, "seeded log must contain 3 entries before clear")

        await session.clearServerMessages()

        let after = await session.recentServerMessages()
        XCTAssertTrue(after.isEmpty, "clearServerMessages must remove every entry")
    }

    // MARK: - 10. consumePendingApplyEdit removes the entry with the given id

    func test_consumePendingApplyEdit_removesById() async throws {
        let (session, transport) = try await startedSession()

        // Enqueue two applyEdit requests.
        let editPayload = """
        {"edit":{"changes":{"file:///tmp/a.swift":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"a"}]}}}
        """
        let firstReqId = 100
        let secondReqId = 101
        let first = jsonRPCRequest(id: firstReqId, method: "workspace/applyEdit", paramsJSON: editPayload)
        let second = jsonRPCRequest(id: secondReqId, method: "workspace/applyEdit", paramsJSON: editPayload)
        await transport.simulateServerMessage(lspFrame(first))
        await transport.simulateServerMessage(lspFrame(second))

        let bothEnqueued = await waitUntil {
            await session.pendingApplyEdits().count == 2
        }
        XCTAssertTrue(bothEnqueued, "both applyEdits must be enqueued before consume")

        let queueBefore = await session.pendingApplyEdits()
        // Pick the id of the first entry to consume.
        guard let firstEntry = queueBefore.first else {
            return XCTFail("expected at least one entry to consume")
        }
        let consumedId = firstEntry.id

        await session.consumePendingApplyEdit(id: consumedId)

        let queueAfter = await session.pendingApplyEdits()
        XCTAssertEqual(queueAfter.count, 1, "consume must remove exactly one entry")
        XCTAssertFalse(
            queueAfter.contains(where: { $0.id == consumedId }),
            "consumed id must no longer appear in the queue"
        )
    }
}
