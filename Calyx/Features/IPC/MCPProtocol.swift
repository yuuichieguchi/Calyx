//
//  MCPProtocol.swift
//  Calyx
//
//  MCP (Model Context Protocol) message types and router for the Calyx IPC system.
//  JSON-RPC base types live in JSONRPC.swift.
//

import Foundation

// MARK: - MCP Types

/// Result of the MCP `initialize` method.
struct MCPInitializeResult: Sendable, Codable {
    let protocolVersion: String
    let capabilities: MCPCapabilities
    let serverInfo: MCPServerInfo
    let instructions: String?
}

/// MCP server capabilities.
struct MCPCapabilities: Sendable, Codable {
    let tools: MCPToolsCapability
}

/// MCP tools capability.
struct MCPToolsCapability: Sendable, Codable {
    let listChanged: Bool
}

/// MCP server information.
struct MCPServerInfo: Sendable, Codable {
    let name: String
    let version: String
}

/// MCP tool definition.
struct MCPTool: Sendable, Codable {
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]
}

/// Result of the MCP `tools/list` method.
struct MCPToolsListResult: Sendable, Codable {
    let tools: [MCPTool]
}

/// Result of an MCP tool call.
struct MCPToolCallResult: Sendable, Codable {
    let content: [MCPContent]
    let isError: Bool
}

/// MCP content block (text type).
struct MCPContent: Sendable, Codable {
    let type: String
    let text: String
}

// MARK: - MCPRouter

/// Routes MCP JSON-RPC requests and builds responses.
struct MCPRouter: Sendable {

    // MARK: - Schema Helpers

    private static func prop(_ type: String, _ desc: String) -> AnyCodable {
        AnyCodable(["type": AnyCodable(type), "description": AnyCodable(desc)] as [String: AnyCodable])
    }

    private static func arrayProp(_ itemType: String, _ desc: String) -> AnyCodable {
        AnyCodable([
            "type": AnyCodable("array"),
            "items": AnyCodable(["type": AnyCodable(itemType)] as [String: AnyCodable]),
            "description": AnyCodable(desc),
        ] as [String: AnyCodable])
    }

    private static func schema(
        properties: [String: AnyCodable],
        required: [String] = []
    ) -> [String: AnyCodable] {
        var s: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable(properties),
        ]
        if !required.isEmpty {
            s["required"] = AnyCodable(required.map { AnyCodable($0) } as [AnyCodable])
        }
        return s
    }

    /// All tool definitions exposed by this MCP server.
    static var tools: [MCPTool] {
        [
            MCPTool(
                name: "register_peer",
                description: "Register this Claude Code instance as a peer for IPC communication",
                inputSchema: schema(
                    properties: [
                        "name": prop("string", "Peer display name"),
                        "role": prop("string", "Peer role"),
                    ],
                    required: ["name"]
                )
            ),
            MCPTool(
                name: "list_peers",
                description: "List all registered peers",
                inputSchema: schema(properties: [:])
            ),
            MCPTool(
                name: "send_message",
                description: "Send a message to a specific peer",
                inputSchema: schema(
                    properties: [
                        "from": prop("string", "Sender peer ID"),
                        "to": prop("string", "Target peer ID"),
                        "content": prop("string", "Message content"),
                    ],
                    required: ["from", "to", "content"]
                )
            ),
            MCPTool(
                name: "broadcast",
                description: "Broadcast a message to all other peers",
                inputSchema: schema(
                    properties: [
                        "from": prop("string", "Sender peer ID"),
                        "content": prop("string", "Message content"),
                    ],
                    required: ["from", "content"]
                )
            ),
            MCPTool(
                name: "receive_messages",
                description: "Receive pending messages for this peer",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Your peer ID"),
                    ],
                    required: ["peer_id"]
                )
            ),
            MCPTool(
                name: "ack_messages",
                description: "Acknowledge and delete received messages",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Peer ID"),
                        "message_ids": arrayProp("string", "Message IDs to acknowledge"),
                    ],
                    required: ["peer_id", "message_ids"]
                )
            ),
            MCPTool(
                name: "get_peer_status",
                description: "Get status information for a specific peer",
                inputSchema: schema(
                    properties: [
                        "peer_id": prop("string", "Peer ID to check"),
                    ],
                    required: ["peer_id"]
                )
            ),
        ]
    }

    /// LSP tool catalogue. Delegates to `MCPLSPBridge.tools` so the bridge
    /// remains the single source of truth for the `lsp_*` surface.
    static var lspTools: [MCPTool] {
        MCPLSPBridge.tools
    }

    /// Combined IPC + LSP tool catalogue. Used by `tools/list` to advertise
    /// every tool the server can dispatch.
    static var allTools: [MCPTool] {
        tools + lspTools
    }

    /// Classifier — does `name` belong to the LSP tool surface?
    /// Identifies tools by the `lsp_` prefix; the bridge owns the full
    /// dispatch table.
    static func isLSPTool(name: String) -> Bool {
        name.hasPrefix("lsp_")
    }

    /// Opening paragraph shared by both instructions variants below.
    private static let instructionsIntro =
        "You are connected to Calyx IPC, enabling communication with other Claude Code instances in other terminal panes."

    /// Register-peer guidance for a connection `initialize` did NOT
    /// auto-register a peer for (no `X-Calyx-Surface-ID`, e.g. an
    /// external client like OpenCode) — self-registration via
    /// `register_peer` is the only path to a peer_id, so this retains the
    /// original "call register_peer immediately" guidance. That's the
    /// intended, unchanged contract for a surfaceless client, not a gap.
    private static let selfRegisterParagraph =
        "Immediately after connecting, call register_peer once with a descriptive name based on your current task or working directory, and a role describing your function. Do not call register_peer again in the same session."

    /// Register-peer guidance for a connection `initialize` DID
    /// auto-register a peer for (a surface-bound pane — see
    /// `CalyxMCPServer`'s `initialize` case). Round 6: the old text told
    /// every client "call register_peer once immediately after
    /// connecting" while `initialize` itself also auto-registers and
    /// announces a peer_id in the same response — a contradiction that let
    /// an agent following the instruction mint a second, disconnected
    /// identity for a pane that already had one. This variant instead
    /// states the client is already registered, and frames register_peer
    /// as an optional rename (same peer_id back) rather than a fresh
    /// registration.
    private static func alreadyRegisteredParagraphs(peerID: UUID) -> [String] {
        [
            "You are already registered as a peer. Your peer_id is: \(peerID.uuidString). Use this in send_message, receive_messages, and other peer tools.",
            "If you want a more descriptive name/role recorded (e.g. based on your current task or working directory), call register_peer once — this renames your existing registration in place and returns the same peer_id, it does not create a new one. Do not call register_peer more than once in the same session.",
        ]
    }

    /// Paragraphs shared by both instructions variants, following
    /// whichever register-peer guidance applies. Factored out (Round 6
    /// review) so the browser/LSP tool surface descriptions aren't
    /// duplicated (and liable to drift) between the two variants.
    private static let commonSuffixParagraphs: [String] = [
        "After completing any significant task, call receive_messages to check for messages from other peers. When you receive messages, process them and respond via send_message.",
        "Use list_peers to discover other connected instances. Use broadcast for announcements relevant to all peers.",
        "Browser automation tools (browser_*) are available when browser scripting is enabled via the Command Palette. Use browser_snapshot to inspect pages and browser_click/browser_fill to interact with elements. Element refs (@e1, @e2) from snapshots can be used as selectors.",
        "LSP language tools (lsp_*) are available when the LSP bridge is started. Use lsp_hover to inspect type information and documentation at a position in a file. Use lsp_definition / lsp_declaration / lsp_type_definition / lsp_implementation for navigation. Use lsp_references for finding usages. Use lsp_completion for autocomplete and lsp_workspace_symbol for cross-file symbol search. All LSP tools require workspace_root, language_id, and (most of them) file/line/column arguments.",
    ]

    /// Static, trusted instructions text for a connection with no
    /// auto-registered peer. Never inject user-controlled content. Kept
    /// as the default (no-peerID) text: also referenced directly by
    /// `CalyxMCPServerLSPIntegrationTests`.
    static let instructions = ([instructionsIntro, selfRegisterParagraph] + commonSuffixParagraphs)
        .joined(separator: "\n\n")

    /// Instructions text for a connection `initialize` already
    /// auto-registered a peer for — see `alreadyRegisteredParagraphs`'s
    /// doc comment for the contradiction this closes.
    private static func alreadyRegisteredInstructions(peerID: UUID) -> String {
        ([instructionsIntro] + alreadyRegisteredParagraphs(peerID: peerID) + commonSuffixParagraphs)
            .joined(separator: "\n\n")
    }

    /// Build the response for `initialize`. `peerID` is non-nil only when
    /// the connection was surface-bound and `initialize` resolved a peer
    /// for it (see `CalyxMCPServer`'s `initialize` case) — that branches
    /// the instructions text between `alreadyRegisteredInstructions` and
    /// the no-peerID default `instructions`.
    static func buildInitializeResponse(id: JSONRPCId, peerID: UUID? = nil) -> JSONRPCResponse {
        let fullInstructions = peerID.map(alreadyRegisteredInstructions(peerID:)) ?? instructions

        let initResult = MCPInitializeResult(
            protocolVersion: "2024-11-05",
            capabilities: MCPCapabilities(
                tools: MCPToolsCapability(listChanged: false)
            ),
            serverInfo: MCPServerInfo(name: "calyx-ipc", version: "1.0.0"),
            instructions: fullInstructions
        )

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(initResult),
            error: nil
        )
    }

    /// Build the response for `tools/list`.
    static func buildToolsListResponse(id: JSONRPCId) -> JSONRPCResponse {
        let toolsList = MCPToolsListResult(tools: allTools)

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(toolsList),
            error: nil
        )
    }

    /// Build a JSON-RPC error response.
    static func buildErrorResponse(
        id: JSONRPCId?,
        code: Int,
        message: String
    ) -> JSONRPCResponse {
        JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: nil,
            error: JSONRPCError(code: code, message: message)
        )
    }

    /// Build a tool call result response.
    static func buildToolCallResponse(
        id: JSONRPCId,
        content: [MCPContent],
        isError: Bool
    ) -> JSONRPCResponse {
        let callResult = MCPToolCallResult(content: content, isError: isError)

        return JSONRPCResponse(
            jsonrpc: "2.0",
            id: id,
            result: AnyCodable.from(callResult),
            error: nil
        )
    }
}
