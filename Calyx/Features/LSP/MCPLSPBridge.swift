//
//  MCPLSPBridge.swift
//  Calyx
//
//  Bridges the MCP tool surface (`tools/list` + `tools/call`) onto the LSP
//  request vocabulary. The bridge advertises ten core LSP tools and routes
//  each MCP `tools/call` through an `LSPSession` (vended by `LSPService`)
//  to the underlying language server.
//
//  Tools shipped here cover the navigation, symbol-discovery and
//  completion families:
//
//      lsp_hover            -> textDocument/hover
//      lsp_definition       -> textDocument/definition
//      lsp_declaration      -> textDocument/declaration
//      lsp_type_definition  -> textDocument/typeDefinition
//      lsp_implementation   -> textDocument/implementation
//      lsp_references       -> textDocument/references
//      lsp_document_highlight -> textDocument/documentHighlight
//      lsp_document_symbol  -> textDocument/documentSymbol
//      lsp_workspace_symbol -> workspace/symbol
//      lsp_completion       -> textDocument/completion
//
//  Response shaping rule: every tool serialises its LSP result as JSON and
//  hands the JSON string back as the `text` of a single `MCPContent` block.
//  A JSON `null` result surfaces as the literal string `"null"`. Server
//  errors are caught and the error message is embedded in the text payload
//  (rather than propagated as a thrown error) so the MCP caller still
//  receives a structured `content` block.
//

import Foundation

// MARK: - MCPLSPTool

/// One MCP tool that wraps a single LSP request. Implementations declare
/// their MCP name, description and JSON-Schema, and the dispatch logic
/// that turns the raw `arguments` payload into an LSP request through the
/// bridge's `LSPSession`.
protocol MCPLSPTool: Sendable {
    /// MCP tool name (e.g. `"lsp_hover"`).
    static var name: String { get }
    /// One-line description surfaced via `tools/list`.
    static var description: String { get }
    /// JSON-Schema describing the expected `arguments` payload.
    static var inputSchema: [String: AnyCodable] { get }
    /// Execute the tool against `bridge`. Implementations should catch
    /// `LSPClientError.serverError` and shape it into the returned
    /// `MCPContent.text` so the MCP caller sees a structured response
    /// instead of a thrown error.
    @MainActor
    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent
}

// MARK: - MCPLSPBridgeError

/// Failures raised by `MCPLSPBridge` before any LSP request is dispatched.
enum MCPLSPBridgeError: Error, Equatable {
    /// `handleToolCall` received a `name` not present in `tools`.
    case unknownTool(String)
    /// A required argument was missing from the `arguments` dictionary.
    case missingArgument(String)
    /// An argument was present but failed to coerce into the expected
    /// shape (e.g. a non-integer where an integer was required).
    case invalidArgument(name: String, reason: String)
}

// MARK: - MCPLSPBridge

/// Main-actor registry + dispatcher that exposes LSP requests as MCP
/// tools to `CalyxMCPServer`.
@MainActor
final class MCPLSPBridge {

    // MARK: Stored properties

    private let service: LSPService
    private let workspaceResolver: WorkspaceResolver

    // MARK: Init

    init(service: LSPService, workspaceResolver: WorkspaceResolver) {
        self.service = service
        self.workspaceResolver = workspaceResolver
    }

    // MARK: - Tool catalogue

    /// The full set of MCP tools published by this bridge. The list is
    /// `nonisolated static` so callers (`MCPRouter`, tests) can enumerate
    /// it without hopping onto the main actor.
    nonisolated static var tools: [MCPTool] {
        [
            MCPTool(
                name: HoverTool.name,
                description: HoverTool.description,
                inputSchema: HoverTool.inputSchema
            ),
            MCPTool(
                name: DefinitionTool.name,
                description: DefinitionTool.description,
                inputSchema: DefinitionTool.inputSchema
            ),
            MCPTool(
                name: DeclarationTool.name,
                description: DeclarationTool.description,
                inputSchema: DeclarationTool.inputSchema
            ),
            MCPTool(
                name: TypeDefinitionTool.name,
                description: TypeDefinitionTool.description,
                inputSchema: TypeDefinitionTool.inputSchema
            ),
            MCPTool(
                name: ImplementationTool.name,
                description: ImplementationTool.description,
                inputSchema: ImplementationTool.inputSchema
            ),
            MCPTool(
                name: ReferencesTool.name,
                description: ReferencesTool.description,
                inputSchema: ReferencesTool.inputSchema
            ),
            MCPTool(
                name: DocumentHighlightTool.name,
                description: DocumentHighlightTool.description,
                inputSchema: DocumentHighlightTool.inputSchema
            ),
            MCPTool(
                name: DocumentSymbolTool.name,
                description: DocumentSymbolTool.description,
                inputSchema: DocumentSymbolTool.inputSchema
            ),
            MCPTool(
                name: WorkspaceSymbolTool.name,
                description: WorkspaceSymbolTool.description,
                inputSchema: WorkspaceSymbolTool.inputSchema
            ),
            MCPTool(
                name: CompletionTool.name,
                description: CompletionTool.description,
                inputSchema: CompletionTool.inputSchema
            ),
        ]
    }

    // MARK: - Dispatch

    /// Route an MCP `tools/call` to the matching `MCPLSPTool`.
    func handleToolCall(name: String, arguments: [String: AnyCodable]) async throws -> MCPContent {
        switch name {
        case HoverTool.name:
            return try await HoverTool.handle(arguments: arguments, bridge: self)
        case DefinitionTool.name:
            return try await DefinitionTool.handle(arguments: arguments, bridge: self)
        case DeclarationTool.name:
            return try await DeclarationTool.handle(arguments: arguments, bridge: self)
        case TypeDefinitionTool.name:
            return try await TypeDefinitionTool.handle(arguments: arguments, bridge: self)
        case ImplementationTool.name:
            return try await ImplementationTool.handle(arguments: arguments, bridge: self)
        case ReferencesTool.name:
            return try await ReferencesTool.handle(arguments: arguments, bridge: self)
        case DocumentHighlightTool.name:
            return try await DocumentHighlightTool.handle(arguments: arguments, bridge: self)
        case DocumentSymbolTool.name:
            return try await DocumentSymbolTool.handle(arguments: arguments, bridge: self)
        case WorkspaceSymbolTool.name:
            return try await WorkspaceSymbolTool.handle(arguments: arguments, bridge: self)
        case CompletionTool.name:
            return try await CompletionTool.handle(arguments: arguments, bridge: self)
        default:
            throw MCPLSPBridgeError.unknownTool(name)
        }
    }

    // MARK: - Argument helpers

    /// Resolve a started `LSPSession` for the `workspace_root` and
    /// `language_id` keys in `arguments`. Throws if either is missing or
    /// malformed.
    func resolveSession(arguments: [String: AnyCodable]) async throws -> LSPSession {
        let workspaceRootString = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "workspace_root"
        )
        let languageId = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "language_id"
        )
        let workspaceURL = MCPLSPBridge.fileURL(fromPathOrUri: workspaceRootString)
        return try await service.session(
            for: workspaceURL,
            languageId: languageId
        )
    }

    /// Pull `file`, `line`, `column` from `arguments` and build the
    /// `(uri, position)` pair shared by every position-based LSP request.
    func extractPosition(arguments: [String: AnyCodable]) throws -> (uri: DocumentUri, position: Position) {
        let file = try MCPLSPBridge.requireString(arguments: arguments, key: "file")
        let line = try MCPLSPBridge.requireInt(arguments: arguments, key: "line")
        let column = try MCPLSPBridge.requireInt(arguments: arguments, key: "column")
        let uri = MCPLSPBridge.documentUri(fromPathOrUri: file)
        return (uri, Position(line: line, character: column))
    }

    /// Pull just the `file` key (used by `documentSymbol`).
    func extractDocumentUri(arguments: [String: AnyCodable]) throws -> DocumentUri {
        let file = try MCPLSPBridge.requireString(arguments: arguments, key: "file")
        return MCPLSPBridge.documentUri(fromPathOrUri: file)
    }

    // MARK: - Argument coercion (nonisolated)

    /// Decode the `AnyCodable` value at `key` as a `String`, throwing
    /// `MCPLSPBridgeError.missingArgument` if absent and
    /// `MCPLSPBridgeError.invalidArgument` if the underlying JSON is the
    /// wrong shape.
    nonisolated static func requireString(arguments: [String: AnyCodable], key: String) throws -> String {
        guard let raw = arguments[key] else {
            throw MCPLSPBridgeError.missingArgument(key)
        }
        guard let value: String = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return value
    }

    /// Decode the `AnyCodable` value at `key` as an `Int`.
    nonisolated static func requireInt(arguments: [String: AnyCodable], key: String) throws -> Int {
        guard let raw = arguments[key] else {
            throw MCPLSPBridgeError.missingArgument(key)
        }
        guard let value: Int = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected integer")
        }
        return value
    }

    /// Decode an optional `Bool` argument; returns `nil` when absent.
    nonisolated static func optionalBool(arguments: [String: AnyCodable], key: String) throws -> Bool? {
        guard let raw = arguments[key] else { return nil }
        guard let value: Bool = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected boolean")
        }
        return value
    }

    /// Decode an optional `Int` argument; returns `nil` when absent.
    nonisolated static func optionalInt(arguments: [String: AnyCodable], key: String) throws -> Int? {
        guard let raw = arguments[key] else { return nil }
        guard let value: Int = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected integer")
        }
        return value
    }

    /// Decode an optional `String` argument; returns `nil` when absent.
    nonisolated static func optionalString(arguments: [String: AnyCodable], key: String) throws -> String? {
        guard let raw = arguments[key] else { return nil }
        guard let value: String = decodeValue(raw) else {
            throw MCPLSPBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return value
    }

    /// `AnyCodable.storage` is private; recover the underlying primitive
    /// by round-tripping through `JSONEncoder` + `JSONSerialization`.
    private nonisolated static func decodeValue<T>(_ raw: AnyCodable) -> T? {
        guard let data = try? JSONEncoder().encode(raw),
              let any = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              )
        else { return nil }
        if let value = any as? T { return value }
        // JSONSerialization bridges JSON integers to `NSNumber`; peel an
        // `Int` out of that branch manually so `Int` callers succeed even
        // when the underlying number was decoded as `Double`.
        if T.self == Int.self {
            if let n = any as? NSNumber {
                return Int(truncating: n) as? T
            }
        }
        if T.self == Bool.self {
            if let n = any as? NSNumber {
                return (n.boolValue as? T)
            }
        }
        return nil
    }

    /// Convert a workspace path (either an absolute filesystem path or a
    /// `file://` URI) into a `URL` suitable for `LSPService.session(for:)`.
    nonisolated static func fileURL(fromPathOrUri input: String) -> URL {
        if input.hasPrefix("file://"), let url = URL(string: input) {
            return url
        }
        return URL(fileURLWithPath: input)
    }

    /// Convert an absolute path or `file://` URI into the LSP
    /// `DocumentUri` (string) form.
    nonisolated static func documentUri(fromPathOrUri input: String) -> DocumentUri {
        if input.hasPrefix("file://") {
            return input
        }
        return URL(fileURLWithPath: input).absoluteString
    }

    // MARK: - Response shaping helpers

    /// Encode a result as a single-text-block `MCPContent`. Used by every
    /// success path.
    nonisolated static func makeJSONContent<T: Encodable>(_ value: T) throws -> MCPContent {
        let encoder = JSONEncoder()
        // Stable key order keeps test snapshots deterministic.
        // `.withoutEscapingSlashes` keeps file:// URIs (and other slashed
        // strings) human-readable instead of emitting `file:\/\/` escapes
        // — important for MCP callers that grep the JSON payload.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let text = String(data: data, encoding: .utf8) ?? "null"
        return MCPContent(type: "text", text: text)
    }

    /// Map an LSPSession error (or any other thrown error) into a
    /// human-readable text payload. JSON-RPC server errors are surfaced
    /// inline so the MCP caller can read the diagnostic instead of
    /// receiving an opaque thrown error.
    nonisolated static func makeErrorContent(_ error: Error) -> MCPContent {
        let message: String
        switch error {
        case let LSPSessionError.clientError(inner):
            message = describe(clientError: inner)
        case let inner as LSPClientError:
            message = describe(clientError: inner)
        default:
            message = String(describing: error)
        }
        return MCPContent(type: "text", text: "LSP error: \(message)")
    }

    private nonisolated static func describe(clientError: LSPClientError) -> String {
        switch clientError {
        case .serverError(let code, let message):
            return "server error \(code): \(message)"
        case .responseDecodingFailed(let reason):
            return "response decoding failed: \(reason)"
        case .malformedFraming(let reason):
            return "malformed framing: \(reason)"
        case .methodNotFound(let m):
            return "method not found: \(m)"
        case .timeout:
            return "timeout"
        case .transportClosed:
            return "transport closed"
        case .alreadyStarted:
            return "client already started"
        case .notStarted:
            return "client not started"
        }
    }
}

// MARK: - Schema helpers

/// Build the JSON-Schema for a position-based MCP tool. `extra` is merged
/// into the `properties` map *after* the standard keys so callers can
/// override descriptions or add tool-specific fields.
private func positionRequestSchema(
    extraProperties: [String: AnyCodable] = [:],
    extraRequired: [String] = []
) -> [String: AnyCodable] {
    var props: [String: AnyCodable] = [
        "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
        "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
        "file": prop("string", "Absolute path or file:// URI of the target file"),
        "line": prop("integer", "0-based line number"),
        "column": prop("integer", "0-based UTF-16 column / character offset"),
    ]
    for (key, value) in extraProperties {
        props[key] = value
    }
    var required = ["workspace_root", "language_id", "file", "line", "column"]
    required.append(contentsOf: extraRequired)
    return [
        "type": AnyCodable("object"),
        "properties": AnyCodable(props),
        "required": AnyCodable(required.map { AnyCodable($0) }),
    ]
}

/// Build a single `{ "type": ..., "description": ... }` JSON-Schema fragment.
private func prop(_ type: String, _ description: String) -> AnyCodable {
    AnyCodable([
        "type": AnyCodable(type),
        "description": AnyCodable(description),
    ] as [String: AnyCodable])
}

// MARK: - HoverTool

enum HoverTool: MCPLSPTool {
    static let name = "lsp_hover"
    static let description = "Get hover information (type signature, docs) at a position in a file."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        let params = HoverParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: Hover? = try await session.sendRequest(
                method: "textDocument/hover",
                params: params,
                resultType: Hover?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DefinitionTool

enum DefinitionTool: MCPLSPTool {
    static let name = "lsp_definition"
    static let description = "Go to the definition(s) of the symbol at a position."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        let params = DefinitionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: DefinitionResult? = try await session.sendRequest(
                method: "textDocument/definition",
                params: params,
                resultType: DefinitionResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DeclarationTool

enum DeclarationTool: MCPLSPTool {
    static let name = "lsp_declaration"
    static let description = "Go to the declaration(s) of the symbol at a position."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        let params = DeclarationParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: DeclarationResult? = try await session.sendRequest(
                method: "textDocument/declaration",
                params: params,
                resultType: DeclarationResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - TypeDefinitionTool

enum TypeDefinitionTool: MCPLSPTool {
    static let name = "lsp_type_definition"
    static let description = "Go to the type definition(s) of the symbol at a position."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        let params = TypeDefinitionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: TypeDefinitionResult? = try await session.sendRequest(
                method: "textDocument/typeDefinition",
                params: params,
                resultType: TypeDefinitionResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - ImplementationTool

enum ImplementationTool: MCPLSPTool {
    static let name = "lsp_implementation"
    static let description = "Go to the implementation(s) of the symbol at a position."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        let params = ImplementationParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: ImplementationResult? = try await session.sendRequest(
                method: "textDocument/implementation",
                params: params,
                resultType: ImplementationResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - ReferencesTool

enum ReferencesTool: MCPLSPTool {
    static let name = "lsp_references"
    static let description = "Find all references to the symbol at a position."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema(
        extraProperties: [
            "include_declaration": prop(
                "boolean",
                "Whether to include the declaration site in the result"
            ),
        ]
    )

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        let includeDecl = try MCPLSPBridge.optionalBool(
            arguments: arguments,
            key: "include_declaration"
        ) ?? false
        let params = ReferenceParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            context: ReferenceContext(includeDeclaration: includeDecl)
        )
        do {
            let result: [Location]? = try await session.sendRequest(
                method: "textDocument/references",
                params: params,
                resultType: [Location]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DocumentHighlightTool

enum DocumentHighlightTool: MCPLSPTool {
    static let name = "lsp_document_highlight"
    static let description = "Highlight every occurrence of the symbol at a position within the file."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        let params = DocumentHighlightParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: [DocumentHighlight]? = try await session.sendRequest(
                method: "textDocument/documentHighlight",
                params: params,
                resultType: [DocumentHighlight]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DocumentSymbolTool

enum DocumentSymbolTool: MCPLSPTool {
    static let name = "lsp_document_symbol"
    static let description = "Return the symbol tree (classes, functions, etc.) for a single file."
    static let inputSchema: [String: AnyCodable] = {
        var props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "file": prop("string", "Absolute path or file:// URI of the target file"),
        ]
        let required = ["workspace_root", "language_id", "file"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let uri = try bridge.extractDocumentUri(arguments: arguments)
        let params = DocumentSymbolParams(
            textDocument: TextDocumentIdentifier(uri: uri)
        )
        do {
            let result: DocumentSymbolResult? = try await session.sendRequest(
                method: "textDocument/documentSymbol",
                params: params,
                resultType: DocumentSymbolResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - WorkspaceSymbolTool

enum WorkspaceSymbolTool: MCPLSPTool {
    static let name = "lsp_workspace_symbol"
    static let description = "Search for symbols across the whole workspace by name."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "query": prop("string", "Substring to match against symbol names"),
        ]
        let required = ["workspace_root", "language_id", "query"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let query = try MCPLSPBridge.requireString(arguments: arguments, key: "query")
        let params = WorkspaceSymbolParams(query: query)
        do {
            let result: WorkspaceSymbolResult? = try await session.sendRequest(
                method: "workspace/symbol",
                params: params,
                resultType: WorkspaceSymbolResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CompletionTool

enum CompletionTool: MCPLSPTool {
    static let name = "lsp_completion"
    static let description = "Request code completion suggestions at a position."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema(
        extraProperties: [
            "trigger_kind": prop(
                "integer",
                "CompletionTriggerKind: 1=Invoked, 2=TriggerCharacter, 3=TriggerForIncompleteCompletions"
            ),
            "trigger_character": prop(
                "string",
                "Single character that triggered completion (only when trigger_kind == 2)"
            ),
        ]
    )

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, position) = try bridge.extractPosition(arguments: arguments)

        var context: CompletionContext?
        if let kindRaw = try MCPLSPBridge.optionalInt(arguments: arguments, key: "trigger_kind") {
            guard let kind = CompletionTriggerKind(rawValue: kindRaw) else {
                throw MCPLSPBridgeError.invalidArgument(
                    name: "trigger_kind",
                    reason: "must be one of 1, 2, 3"
                )
            }
            let triggerChar = try MCPLSPBridge.optionalString(
                arguments: arguments,
                key: "trigger_character"
            )
            context = CompletionContext(
                triggerKind: kind,
                triggerCharacter: triggerChar
            )
        }

        let params = CompletionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            context: context
        )
        do {
            let result: CompletionResult? = try await session.sendRequest(
                method: "textDocument/completion",
                params: params,
                resultType: CompletionResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}
