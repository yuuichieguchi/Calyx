//
//  CalyxMCPServer.swift
//  Calyx
//
//  MCP server: accepts JSON-RPC over TCP, authenticates via bearer token,
//  routes to MCPRouter / IPCStore for IPC tool calls.
//

import Foundation
import Network

@MainActor
final class CalyxMCPServer {

    static let shared = CalyxMCPServer()

    // MARK: - Public State

    private(set) var isRunning: Bool = false
    private(set) var port: Int = 0
    private(set) var token: String = ""
    let store = IPCStore()
    var terminalControl: any TerminalControlProviding = TerminalControlService()

    // MARK: - Private

    private var listener: NWListener?

    private static let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    // MARK: - Init

    init() {}

    /// For testing only — sets the token without starting the listener.
    func _testSetToken(_ token: String) {
        self.token = token
    }

    // MARK: - Lifecycle

    func start(token: String, preferredPort: Int = 41830) throws {
        if isRunning { stop() }

        self.token = token

        var lastError: Error?

        for portOffset in 0..<10 {
            let tryPort = preferredPort + portOffset
            do {
                let params = NWParameters.tcp
                let nwPort = NWEndpoint.Port(integerLiteral: UInt16(tryPort))
                params.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: nwPort
                )
                let nl = try NWListener(using: params)

                nl.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        self?.handleConnection(connection)
                    }
                }
                nl.start(queue: .main)

                self.listener = nl
                self.port = tryPort
                self.isRunning = true
                return
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? NSError(
            domain: "CalyxMCPServer",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to bind to any port in range \(preferredPort)-\(preferredPort + 9)",
            ]
        )
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = 0
        Task { await store.cleanup() }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPParser.maxHeaderSize + HTTPParser.maxBodySize) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, let data else {
                    connection.cancel()
                    return
                }

                do {
                    let httpRequest = try HTTPParser.parse(data)

                    // Only accept POST /mcp
                    guard httpRequest.method == "POST", httpRequest.path == "/mcp" else {
                        self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 404, body: nil))
                        return
                    }

                    // Extract bearer token from Authorization header (case-insensitive)
                    let authToken: String? = {
                        for (key, value) in httpRequest.headers {
                            if key.lowercased() == "authorization", value.hasPrefix("Bearer ") {
                                return String(value.dropFirst(7))
                            }
                        }
                        return nil
                    }()

                    guard let body = httpRequest.body else {
                        self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 400, body: nil))
                        return
                    }

                    let (statusCode, responseBody) = await self.handleJSONRPC(data: body, authToken: authToken)
                    let httpResponse = HTTPParser.response(statusCode: statusCode, body: responseBody)
                    self.sendHTTPResponse(connection: connection, httpResponse: httpResponse)
                } catch let error as HTTPParseError {
                    let statusCode: Int
                    switch error {
                    case .headerTooLarge, .bodyTooLarge: statusCode = 413
                    case .invalidContentLength, .malformedRequest: statusCode = 400
                    case .timeout: statusCode = 408
                    }
                    self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: statusCode, body: nil))
                } catch {
                    self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 500, body: nil))
                }
            }
        }
    }

    private func sendHTTPResponse(connection: NWConnection, httpResponse: HTTPResponse) {
        let data = httpResponse.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - JSON-RPC Handler

    /// Process a single JSON-RPC request.
    /// Returns an HTTP-like status code and optional response body.
    func handleJSONRPC(data: Data, authToken: String?) async -> (statusCode: Int, body: Data?) {

        // 1. Authentication
        guard let authToken, authToken == token else {
            return unauthorizedResponse()
        }

        // 2. Parse JSON
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            let resp = MCPRouter.buildErrorResponse(id: nil, code: -32700, message: "Parse error")
            return (200, encode(resp))
        }

        // 3. Notifications (no id) → 204
        guard let requestId = request.id else {
            return (204, nil)
        }

        // 4. Route by method
        switch request.method {
        case "initialize":
            let resp = MCPRouter.buildInitializeResponse(id: requestId)
            return (200, encode(resp))

        case "tools/list":
            let resp = MCPRouter.buildToolsListResponse(id: requestId)
            return (200, encode(resp))

        case "notifications/initialized":
            return (204, nil)

        case "tools/call":
            return await handleToolCall(id: requestId, params: request.params)

        default:
            let resp = MCPRouter.buildErrorResponse(id: requestId, code: -32601, message: "Method not found")
            return (200, encode(resp))
        }
    }

    // MARK: - Tool Call Dispatch

    private func handleToolCall(
        id: JSONRPCId,
        params: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {

        guard let params else {
            return toolError(id: id, text: "Missing params")
        }

        guard let toolName = extractString(params, "name") else {
            return toolError(id: id, text: "Missing tool name")
        }

        let arguments = extractDict(params, "arguments")

        switch toolName {
        case "register_peer":
            return await handleRegisterPeer(id: id, arguments: arguments)

        case "list_peers":
            return await handleListPeers(id: id)

        case "send_message":
            return await handleSendMessage(id: id, arguments: arguments)

        case "broadcast":
            return await handleBroadcast(id: id, arguments: arguments)

        case "receive_messages":
            return await handleReceiveMessages(id: id, arguments: arguments)

        case "ack_messages":
            return await handleAckMessages(id: id, arguments: arguments)

        case "get_peer_status":
            return await handleGetPeerStatus(id: id, arguments: arguments)

        case "list_panes":
            return handleListPanes(id: id)

        case "create_split":
            return handleCreateSplit(id: id, arguments: arguments)

        default:
            return toolError(id: id, text: "Unknown tool: \(toolName)")
        }
    }

    // MARK: - Tool Handlers

    private func handleRegisterPeer(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        let name = (arguments?["name"] as? String) ?? ""
        let role = (arguments?["role"] as? String) ?? ""
        let peer = await store.registerPeer(name: name, role: role)
        let json = "{\"peerId\":\"\(peer.id.uuidString)\"}"
        return toolSuccess(id: id, text: json)
    }

    private func handleListPeers(
        id: JSONRPCId
    ) async -> (statusCode: Int, body: Data?) {
        let peers = await store.listPeers()
        let peerDicts: [[String: Any]] = peers.map { peerToDict($0) }
        let result: [String: Any] = ["peers": peerDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize peers")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleSendMessage(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"] as? String,
              let toStr = arguments?["to"] as? String,
              let content = arguments?["content"] as? String,
              let fromUUID = UUID(uuidString: fromStr),
              let toUUID = UUID(uuidString: toStr) else {
            return toolError(id: id, text: "Missing or invalid from/to/content")
        }

        do {
            let message = try await store.sendMessage(from: fromUUID, to: toUUID, content: content)
            let json = "{\"messageId\":\"\(message.id.uuidString)\"}"
            return toolSuccess(id: id, text: json)
        } catch let error as IPCError {
            return toolError(id: id, text: error.errorDescription ?? error.localizedDescription)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
        }
    }

    private func handleBroadcast(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"] as? String,
              let content = arguments?["content"] as? String,
              let fromUUID = UUID(uuidString: fromStr) else {
            return toolError(id: id, text: "Missing or invalid from/content")
        }

        do {
            let messages = try await store.broadcast(from: fromUUID, content: content)
            let json = "{\"messageCount\":\(messages.count)}"
            return toolSuccess(id: id, text: json)
        } catch let error as IPCError {
            return toolError(id: id, text: error.errorDescription ?? error.localizedDescription)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
        }
    }

    private func handleReceiveMessages(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        let messages = await store.receiveMessages(for: peerUUID)
        let messageDicts: [[String: Any]] = messages.map { messageToDict($0) }
        let result: [String: Any] = ["messages": messageDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize messages")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleAckMessages(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr),
              let messageIdStrings = arguments?["message_ids"] as? [String] else {
            return toolError(id: id, text: "Missing or invalid peer_id/message_ids")
        }

        let messageUUIDs = messageIdStrings.compactMap { UUID(uuidString: $0) }
        await store.ackMessages(ids: messageUUIDs, for: peerUUID)
        let json = "{\"acknowledged\":\(messageUUIDs.count)}"
        return toolSuccess(id: id, text: json)
    }

    private func handleGetPeerStatus(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        guard let peer = await store.peerStatus(id: peerUUID) else {
            return toolError(id: id, text: "Peer not found")
        }

        let dict = peerToDict(peer)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize peer")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleListPanes(
        id: JSONRPCId
    ) -> (statusCode: Int, body: Data?) {
        let panes = terminalControl.listPanes()
        let paneDicts: [[String: Any]] = panes.map { paneToDict($0) }
        let result: [String: Any] = ["panes": paneDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize panes")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleCreateSplit(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) -> (statusCode: Int, body: Data?) {
        guard let directionStr = arguments?["direction"] as? String else {
            return toolError(id: id, text: "Missing required parameter: direction")
        }

        guard let direction = SplitDirection(rawValue: directionStr) else {
            return toolError(id: id, text: "Invalid direction '\(directionStr)': must be 'horizontal' or 'vertical'")
        }

        let targetPaneId: UUID?
        if let paneIdStr = arguments?["pane_id"] as? String {
            guard let uuid = UUID(uuidString: paneIdStr) else {
                return toolError(id: id, text: "Invalid pane_id '\(paneIdStr)': must be a valid UUID")
            }
            targetPaneId = uuid
        } else {
            targetPaneId = nil
        }

        guard let newPaneID = terminalControl.createSplit(direction: direction, targetPaneId: targetPaneId) else {
            return toolError(id: id, text: "Failed to create split pane")
        }

        let json = "{\"paneId\":\"\(newPaneID.uuidString)\"}"
        return toolSuccess(id: id, text: json)
    }

    // MARK: - Response Helpers

    private func unauthorizedResponse() -> (statusCode: Int, body: Data?) {
        let dict: [String: Any] = ["error": "Unauthorized"]
        let data = try? JSONSerialization.data(withJSONObject: dict)
        return (401, data)
    }

    private func toolSuccess(id: JSONRPCId, text: String) -> (statusCode: Int, body: Data?) {
        let content = [MCPContent(type: "text", text: text)]
        let resp = MCPRouter.buildToolCallResponse(id: id, content: content, isError: false)
        return (200, encode(resp))
    }

    private func toolError(id: JSONRPCId, text: String) -> (statusCode: Int, body: Data?) {
        let content = [MCPContent(type: "text", text: text)]
        let resp = MCPRouter.buildToolCallResponse(id: id, content: content, isError: true)
        return (200, encode(resp))
    }

    private func encode(_ response: JSONRPCResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    // MARK: - Serialization Helpers

    private func peerToDict(_ peer: Peer) -> [String: Any] {
        [
            "id": peer.id.uuidString,
            "name": peer.name,
            "role": peer.role,
            "lastSeen": Self.iso8601.string(from: peer.lastSeen),
            "registeredAt": Self.iso8601.string(from: peer.registeredAt),
        ]
    }

    private func paneToDict(_ pane: PaneInfo) -> [String: Any] {
        var dict: [String: Any] = [
            "id": pane.id,
            "title": pane.title,
            "isFocused": pane.isFocused,
        ]
        if let pwd = pane.pwd {
            dict["pwd"] = pwd
        }
        return dict
    }

    private func messageToDict(_ message: Message) -> [String: Any] {
        [
            "id": message.id.uuidString,
            "from": message.from.uuidString,
            "to": message.to.uuidString,
            "content": message.content,
            "timestamp": Self.iso8601.string(from: message.timestamp),
        ]
    }

    // MARK: - AnyCodable Extraction Helpers

    /// Extract a string value from an AnyCodable dictionary.
    private func extractString(_ dict: [String: AnyCodable], _ key: String) -> String? {
        guard let value = dict[key] else { return nil }
        // Encode the AnyCodable to JSON, then decode as a plain string
        guard let data = try? JSONEncoder().encode(value),
              let str = try? JSONDecoder().decode(String.self, from: data) else {
            return nil
        }
        return str
    }

    /// Extract a [String: Any] dictionary from an AnyCodable value at the given key.
    private func extractDict(_ dict: [String: AnyCodable], _ key: String) -> [String: Any]? {
        guard let value = dict[key] else { return nil }
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }
}
