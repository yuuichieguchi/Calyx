//
//  MCPLSPBridge.swift
//  Calyx
//
//  Bridges the MCP tool surface (`tools/list` + `tools/call`) onto the LSP
//  request vocabulary. The bridge advertises ten core LSP tools and routes
//  each MCP `tools/call` through an `LSPSession` (vended by `LSPService`)
//  to the underlying language server.
//
//  Tools shipped here cover navigation, symbol-discovery, completion,
//  refactoring/diagnostics, and Calyx-side orchestration (install +
//  session lifecycle):
//
//      lsp_hover               -> textDocument/hover
//      lsp_definition          -> textDocument/definition
//      lsp_declaration         -> textDocument/declaration
//      lsp_type_definition     -> textDocument/typeDefinition
//      lsp_implementation      -> textDocument/implementation
//      lsp_references          -> textDocument/references
//      lsp_document_highlight  -> textDocument/documentHighlight
//      lsp_document_symbol     -> textDocument/documentSymbol
//      lsp_workspace_symbol    -> workspace/symbol
//      lsp_completion          -> textDocument/completion
//      lsp_signature_help      -> textDocument/signatureHelp
//      lsp_prepare_rename      -> textDocument/prepareRename
//      lsp_rename              -> textDocument/rename
//      lsp_code_action         -> textDocument/codeAction
//      lsp_diagnostics         -> textDocument/diagnostic (pull mode)
//      lsp_check_installation  -> LSPInstaller.checkInstallation(...)
//      lsp_install             -> LSPInstaller.install(...)
//      lsp_install_status      -> LSPInstaller.currentStatus(...)
//      lsp_session_status      -> LSPService.currentSessions()
//      lsp_session_warmup      -> LSPService.session(for:languageId:)
//      lsp_session_shutdown    -> LSPService.shutdownSession(...)
//      lsp_call_hierarchy_prepare    -> textDocument/prepareCallHierarchy
//      lsp_call_hierarchy_incoming   -> callHierarchy/incomingCalls
//      lsp_call_hierarchy_outgoing   -> callHierarchy/outgoingCalls
//      lsp_type_hierarchy_prepare    -> textDocument/prepareTypeHierarchy
//      lsp_type_hierarchy_supertypes -> typeHierarchy/supertypes
//      lsp_type_hierarchy_subtypes   -> typeHierarchy/subtypes
//      lsp_moniker                   -> textDocument/moniker
//      lsp_code_lens                 -> textDocument/codeLens
//      lsp_code_lens_resolve         -> codeLens/resolve
//      lsp_inlay_hint                -> textDocument/inlayHint
//      lsp_inlay_hint_resolve        -> inlayHint/resolve
//      lsp_inline_value              -> textDocument/inlineValue
//      lsp_folding_range             -> textDocument/foldingRange
//      lsp_selection_range           -> textDocument/selectionRange
//      lsp_semantic_tokens_full      -> textDocument/semanticTokens/full
//      lsp_semantic_tokens_range     -> textDocument/semanticTokens/range
//      lsp_semantic_tokens_delta     -> textDocument/semanticTokens/full/delta
//      lsp_linked_editing_range      -> textDocument/linkedEditingRange
//      lsp_document_link             -> textDocument/documentLink
//      lsp_document_link_resolve     -> documentLink/resolve
//      lsp_document_color            -> textDocument/documentColor
//      lsp_color_presentation        -> textDocument/colorPresentation
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

    /// `internal` (default) so the tool enums in this file can reach the
    /// service for warmup / status / shutdown without a public accessor.
    let service: LSPService
    private let workspaceResolver: WorkspaceResolver
    /// Optional installer used by the install / check tools. Existing
    /// integrations (`CalyxMCPServer`) construct the bridge without an
    /// installer; when absent the install tools return a structured
    /// `"installer not configured"` error payload instead of throwing so
    /// MCP callers still receive a JSON content block.
    let installer: LSPInstaller?

    // MARK: Init

    /// Designated initializer. The `installer` parameter is optional so
    /// callers that don't need the install/orchestration cluster (e.g.
    /// the legacy `CalyxMCPServer` wiring) can keep their existing call
    /// sites untouched.
    init(
        service: LSPService,
        workspaceResolver: WorkspaceResolver,
        installer: LSPInstaller? = nil
    ) {
        self.service = service
        self.workspaceResolver = workspaceResolver
        self.installer = installer
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
            MCPTool(
                name: SignatureHelpTool.name,
                description: SignatureHelpTool.description,
                inputSchema: SignatureHelpTool.inputSchema
            ),
            MCPTool(
                name: PrepareRenameTool.name,
                description: PrepareRenameTool.description,
                inputSchema: PrepareRenameTool.inputSchema
            ),
            MCPTool(
                name: RenameTool.name,
                description: RenameTool.description,
                inputSchema: RenameTool.inputSchema
            ),
            MCPTool(
                name: CodeActionTool.name,
                description: CodeActionTool.description,
                inputSchema: CodeActionTool.inputSchema
            ),
            MCPTool(
                name: DiagnosticsTool.name,
                description: DiagnosticsTool.description,
                inputSchema: DiagnosticsTool.inputSchema
            ),
            MCPTool(
                name: CheckInstallationTool.name,
                description: CheckInstallationTool.description,
                inputSchema: CheckInstallationTool.inputSchema
            ),
            MCPTool(
                name: InstallTool.name,
                description: InstallTool.description,
                inputSchema: InstallTool.inputSchema
            ),
            MCPTool(
                name: InstallStatusTool.name,
                description: InstallStatusTool.description,
                inputSchema: InstallStatusTool.inputSchema
            ),
            MCPTool(
                name: SessionStatusTool.name,
                description: SessionStatusTool.description,
                inputSchema: SessionStatusTool.inputSchema
            ),
            MCPTool(
                name: SessionWarmupTool.name,
                description: SessionWarmupTool.description,
                inputSchema: SessionWarmupTool.inputSchema
            ),
            MCPTool(
                name: SessionShutdownTool.name,
                description: SessionShutdownTool.description,
                inputSchema: SessionShutdownTool.inputSchema
            ),
            MCPTool(
                name: CallHierarchyPrepareTool.name,
                description: CallHierarchyPrepareTool.description,
                inputSchema: CallHierarchyPrepareTool.inputSchema
            ),
            MCPTool(
                name: CallHierarchyIncomingTool.name,
                description: CallHierarchyIncomingTool.description,
                inputSchema: CallHierarchyIncomingTool.inputSchema
            ),
            MCPTool(
                name: CallHierarchyOutgoingTool.name,
                description: CallHierarchyOutgoingTool.description,
                inputSchema: CallHierarchyOutgoingTool.inputSchema
            ),
            MCPTool(
                name: TypeHierarchyPrepareTool.name,
                description: TypeHierarchyPrepareTool.description,
                inputSchema: TypeHierarchyPrepareTool.inputSchema
            ),
            MCPTool(
                name: TypeHierarchySupertypesTool.name,
                description: TypeHierarchySupertypesTool.description,
                inputSchema: TypeHierarchySupertypesTool.inputSchema
            ),
            MCPTool(
                name: TypeHierarchySubtypesTool.name,
                description: TypeHierarchySubtypesTool.description,
                inputSchema: TypeHierarchySubtypesTool.inputSchema
            ),
            MCPTool(
                name: MonikerTool.name,
                description: MonikerTool.description,
                inputSchema: MonikerTool.inputSchema
            ),
            MCPTool(
                name: CodeLensTool.name,
                description: CodeLensTool.description,
                inputSchema: CodeLensTool.inputSchema
            ),
            MCPTool(
                name: CodeLensResolveTool.name,
                description: CodeLensResolveTool.description,
                inputSchema: CodeLensResolveTool.inputSchema
            ),
            MCPTool(
                name: InlayHintTool.name,
                description: InlayHintTool.description,
                inputSchema: InlayHintTool.inputSchema
            ),
            MCPTool(
                name: InlayHintResolveTool.name,
                description: InlayHintResolveTool.description,
                inputSchema: InlayHintResolveTool.inputSchema
            ),
            MCPTool(
                name: InlineValueTool.name,
                description: InlineValueTool.description,
                inputSchema: InlineValueTool.inputSchema
            ),
            MCPTool(
                name: FoldingRangeTool.name,
                description: FoldingRangeTool.description,
                inputSchema: FoldingRangeTool.inputSchema
            ),
            MCPTool(
                name: SelectionRangeTool.name,
                description: SelectionRangeTool.description,
                inputSchema: SelectionRangeTool.inputSchema
            ),
            MCPTool(
                name: SemanticTokensFullTool.name,
                description: SemanticTokensFullTool.description,
                inputSchema: SemanticTokensFullTool.inputSchema
            ),
            MCPTool(
                name: SemanticTokensRangeTool.name,
                description: SemanticTokensRangeTool.description,
                inputSchema: SemanticTokensRangeTool.inputSchema
            ),
            MCPTool(
                name: SemanticTokensDeltaTool.name,
                description: SemanticTokensDeltaTool.description,
                inputSchema: SemanticTokensDeltaTool.inputSchema
            ),
            MCPTool(
                name: LinkedEditingRangeTool.name,
                description: LinkedEditingRangeTool.description,
                inputSchema: LinkedEditingRangeTool.inputSchema
            ),
            MCPTool(
                name: DocumentLinkTool.name,
                description: DocumentLinkTool.description,
                inputSchema: DocumentLinkTool.inputSchema
            ),
            MCPTool(
                name: DocumentLinkResolveTool.name,
                description: DocumentLinkResolveTool.description,
                inputSchema: DocumentLinkResolveTool.inputSchema
            ),
            MCPTool(
                name: DocumentColorTool.name,
                description: DocumentColorTool.description,
                inputSchema: DocumentColorTool.inputSchema
            ),
            MCPTool(
                name: ColorPresentationTool.name,
                description: ColorPresentationTool.description,
                inputSchema: ColorPresentationTool.inputSchema
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
        case SignatureHelpTool.name:
            return try await SignatureHelpTool.handle(arguments: arguments, bridge: self)
        case PrepareRenameTool.name:
            return try await PrepareRenameTool.handle(arguments: arguments, bridge: self)
        case RenameTool.name:
            return try await RenameTool.handle(arguments: arguments, bridge: self)
        case CodeActionTool.name:
            return try await CodeActionTool.handle(arguments: arguments, bridge: self)
        case DiagnosticsTool.name:
            return try await DiagnosticsTool.handle(arguments: arguments, bridge: self)
        case CheckInstallationTool.name:
            return try await CheckInstallationTool.handle(arguments: arguments, bridge: self)
        case InstallTool.name:
            return try await InstallTool.handle(arguments: arguments, bridge: self)
        case InstallStatusTool.name:
            return try await InstallStatusTool.handle(arguments: arguments, bridge: self)
        case SessionStatusTool.name:
            return try await SessionStatusTool.handle(arguments: arguments, bridge: self)
        case SessionWarmupTool.name:
            return try await SessionWarmupTool.handle(arguments: arguments, bridge: self)
        case SessionShutdownTool.name:
            return try await SessionShutdownTool.handle(arguments: arguments, bridge: self)
        case CallHierarchyPrepareTool.name:
            return try await CallHierarchyPrepareTool.handle(arguments: arguments, bridge: self)
        case CallHierarchyIncomingTool.name:
            return try await CallHierarchyIncomingTool.handle(arguments: arguments, bridge: self)
        case CallHierarchyOutgoingTool.name:
            return try await CallHierarchyOutgoingTool.handle(arguments: arguments, bridge: self)
        case TypeHierarchyPrepareTool.name:
            return try await TypeHierarchyPrepareTool.handle(arguments: arguments, bridge: self)
        case TypeHierarchySupertypesTool.name:
            return try await TypeHierarchySupertypesTool.handle(arguments: arguments, bridge: self)
        case TypeHierarchySubtypesTool.name:
            return try await TypeHierarchySubtypesTool.handle(arguments: arguments, bridge: self)
        case MonikerTool.name:
            return try await MonikerTool.handle(arguments: arguments, bridge: self)
        case CodeLensTool.name:
            return try await CodeLensTool.handle(arguments: arguments, bridge: self)
        case CodeLensResolveTool.name:
            return try await CodeLensResolveTool.handle(arguments: arguments, bridge: self)
        case InlayHintTool.name:
            return try await InlayHintTool.handle(arguments: arguments, bridge: self)
        case InlayHintResolveTool.name:
            return try await InlayHintResolveTool.handle(arguments: arguments, bridge: self)
        case InlineValueTool.name:
            return try await InlineValueTool.handle(arguments: arguments, bridge: self)
        case FoldingRangeTool.name:
            return try await FoldingRangeTool.handle(arguments: arguments, bridge: self)
        case SelectionRangeTool.name:
            return try await SelectionRangeTool.handle(arguments: arguments, bridge: self)
        case SemanticTokensFullTool.name:
            return try await SemanticTokensFullTool.handle(arguments: arguments, bridge: self)
        case SemanticTokensRangeTool.name:
            return try await SemanticTokensRangeTool.handle(arguments: arguments, bridge: self)
        case SemanticTokensDeltaTool.name:
            return try await SemanticTokensDeltaTool.handle(arguments: arguments, bridge: self)
        case LinkedEditingRangeTool.name:
            return try await LinkedEditingRangeTool.handle(arguments: arguments, bridge: self)
        case DocumentLinkTool.name:
            return try await DocumentLinkTool.handle(arguments: arguments, bridge: self)
        case DocumentLinkResolveTool.name:
            return try await DocumentLinkResolveTool.handle(arguments: arguments, bridge: self)
        case DocumentColorTool.name:
            return try await DocumentColorTool.handle(arguments: arguments, bridge: self)
        case ColorPresentationTool.name:
            return try await ColorPresentationTool.handle(arguments: arguments, bridge: self)
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

    /// Pull `file`, `start_line`, `start_column`, `end_line`, `end_column`
    /// from `arguments` and build the `(uri, range)` pair shared by every
    /// range-based LSP request (`lsp_code_action`, `lsp_inlay_hint`,
    /// `lsp_inline_value`).
    func extractRange(arguments: [String: AnyCodable]) throws -> (uri: DocumentUri, range: LSPRange) {
        let uri = try extractDocumentUri(arguments: arguments)
        let startLine = try MCPLSPBridge.requireInt(arguments: arguments, key: "start_line")
        let startCol = try MCPLSPBridge.requireInt(arguments: arguments, key: "start_column")
        let endLine = try MCPLSPBridge.requireInt(arguments: arguments, key: "end_line")
        let endCol = try MCPLSPBridge.requireInt(arguments: arguments, key: "end_column")
        let range = LSPRange(
            start: Position(line: startLine, character: startCol),
            end: Position(line: endLine, character: endCol)
        )
        return (uri, range)
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

    /// Decode an `AnyCodable` payload (typically a nested JSON object such
    /// as a `CallHierarchyItem` / `TypeHierarchyItem`) into a typed
    /// `Decodable` value by round-tripping through JSON. Used by the
    /// item-based hierarchy tools to turn the raw `item` argument into the
    /// strongly-typed parameter expected by the LSP request.
    nonisolated static func decodeFromAnyCodable<T: Decodable>(
        _ value: AnyCodable,
        as type: T.Type,
        argumentName: String
    ) throws -> T {
        do {
            let data = try JSONEncoder().encode(value)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MCPLSPBridgeError.invalidArgument(
                name: argumentName,
                reason: "failed to decode as \(T.self): \(error)"
            )
        }
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

/// Build the JSON-Schema for an item-based MCP tool (the call/type
/// hierarchy `incoming` / `outgoing` / `supertypes` / `subtypes` tools,
/// and the `code_lens` / `inlay_hint` resolve tools).
/// The item payload is the verbatim domain object (e.g.
/// `CallHierarchyItem`, `TypeHierarchyItem`, `CodeLens`, `InlayHint`)
/// returned by the matching producer call. `itemKey` selects the
/// argument-dict key under which the value is expected; defaults to
/// `"item"` so existing hierarchy tools keep their wire format.
private func itemBasedSchema(
    itemKey: String = "item",
    itemDescription: String
) -> [String: AnyCodable] {
    let props: [String: AnyCodable] = [
        "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
        "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
        itemKey: AnyCodable([
            "type": AnyCodable("object"),
            "description": AnyCodable(itemDescription),
        ] as [String: AnyCodable]),
    ]
    let required = ["workspace_root", "language_id", itemKey]
    return [
        "type": AnyCodable("object"),
        "properties": AnyCodable(props),
        "required": AnyCodable(required.map { AnyCodable($0) }),
    ]
}

/// Build the JSON-Schema for a file-only MCP tool (`lsp_code_lens`,
/// `lsp_folding_range`). Mirrors `DocumentSymbolTool` / `DiagnosticsTool`'s
/// inline schema but factored into a shared helper.
private func fileOnlySchema() -> [String: AnyCodable] {
    let props: [String: AnyCodable] = [
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
}

/// Build the JSON-Schema for a range-based MCP tool (`lsp_code_action`).
/// Shape mirrors `positionRequestSchema` but with `(start_line,
/// start_column, end_line, end_column)` in place of `(line, column)`.
private func rangeRequestSchema(
    extraProperties: [String: AnyCodable] = [:],
    extraRequired: [String] = []
) -> [String: AnyCodable] {
    var props: [String: AnyCodable] = [
        "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
        "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
        "file": prop("string", "Absolute path or file:// URI of the target file"),
        "start_line": prop("integer", "0-based start line of the target range"),
        "start_column": prop("integer", "0-based start column of the target range"),
        "end_line": prop("integer", "0-based end line of the target range"),
        "end_column": prop("integer", "0-based end column of the target range"),
    ]
    for (key, value) in extraProperties {
        props[key] = value
    }
    var required = [
        "workspace_root", "language_id", "file",
        "start_line", "start_column", "end_line", "end_column",
    ]
    required.append(contentsOf: extraRequired)
    return [
        "type": AnyCodable("object"),
        "properties": AnyCodable(props),
        "required": AnyCodable(required.map { AnyCodable($0) }),
    ]
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

// MARK: - SignatureHelpTool

enum SignatureHelpTool: MCPLSPTool {
    static let name = "lsp_signature_help"
    static let description = "Get signature help (parameter info) at a position."
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
        let params = SignatureHelpParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: SignatureHelp? = try await session.sendRequest(
                method: "textDocument/signatureHelp",
                params: params,
                resultType: SignatureHelp?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - PrepareRenameTool

enum PrepareRenameTool: MCPLSPTool {
    static let name = "lsp_prepare_rename"
    static let description = "Check whether the symbol at a position can be renamed."
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
        let params = PrepareRenameParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: PrepareRenameResult? = try await session.sendRequest(
                method: "textDocument/prepareRename",
                params: params,
                resultType: PrepareRenameResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - RenameTool

enum RenameTool: MCPLSPTool {
    static let name = "lsp_rename"
    static let description = "Rename the symbol at a position across the workspace."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema(
        extraProperties: [
            "new_name": prop("string", "New name to apply to the symbol"),
        ],
        extraRequired: ["new_name"]
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
        let newName = try MCPLSPBridge.requireString(arguments: arguments, key: "new_name")
        let params = RenameParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            newName: newName
        )
        do {
            let result: WorkspaceEdit? = try await session.sendRequest(
                method: "textDocument/rename",
                params: params,
                resultType: WorkspaceEdit?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CodeActionTool

enum CodeActionTool: MCPLSPTool {
    static let name = "lsp_code_action"
    static let description = "Request code actions (quick fixes, refactors) for a range in a file."
    static let inputSchema: [String: AnyCodable] = rangeRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, range) = try bridge.extractRange(arguments: arguments)
        let context = CodeActionContext(diagnostics: [])
        let params = CodeActionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range,
            context: context
        )
        do {
            let result: [CodeActionItem]? = try await session.sendRequest(
                method: "textDocument/codeAction",
                params: params,
                resultType: [CodeActionItem]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DiagnosticsTool

enum DiagnosticsTool: MCPLSPTool {
    static let name = "lsp_diagnostics"
    static let description = "Pull the current diagnostics for a file (textDocument/diagnostic)."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "file": prop("string", "Absolute path or file:// URI of the target file"),
            "identifier": prop("string", "Optional server-side identifier from registration"),
            "previous_result_id": prop("string", "Optional result id from a prior diagnostic response"),
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
        let identifier = try MCPLSPBridge.optionalString(arguments: arguments, key: "identifier")
        let previousResultId = try MCPLSPBridge.optionalString(
            arguments: arguments,
            key: "previous_result_id"
        )
        let params = DocumentDiagnosticParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            identifier: identifier,
            previousResultId: previousResultId
        )
        do {
            let result: DocumentDiagnosticReport? = try await session.sendRequest(
                method: "textDocument/diagnostic",
                params: params,
                resultType: DocumentDiagnosticReport?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CheckInstallationTool

enum CheckInstallationTool: MCPLSPTool {
    static let name = "lsp_check_installation"
    static let description = "Report installation status of LSP servers (optionally for one languageId)."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "language_id": prop(
                "string",
                "Optional. If present, check only this languageId; otherwise check every registry entry."
            ),
        ]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable([AnyCodable]()),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        guard let installer = bridge.installer else {
            return MCPContent(
                type: "text",
                text: #"{"error":"installer not configured"}"#
            )
        }
        if let lang = try MCPLSPBridge.optionalString(arguments: arguments, key: "language_id") {
            let check = await installer.checkInstallation(forLanguageId: lang)
            return try MCPLSPBridge.makeJSONContent(InstallationCheckDTO(from: check))
        }
        let all = await installer.checkAllInstallations()
        let dtos: [String: InstallationCheckDTO] = all.mapValues(InstallationCheckDTO.init(from:))
        return try MCPLSPBridge.makeJSONContent(dtos)
    }
}

// MARK: - InstallTool

enum InstallTool: MCPLSPTool {
    static let name = "lsp_install"
    static let description = "Auto-install the LSP server for a languageId."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "language_id": prop("string", "Target languageId to install (e.g. 'typescript')"),
            "approve_prerequisites": prop(
                "boolean",
                "If true, the installer is also allowed to install missing prerequisites (e.g. npm)."
            ),
        ]
        let required = ["language_id"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let languageId = try MCPLSPBridge.requireString(arguments: arguments, key: "language_id")
        let approve = try MCPLSPBridge.optionalBool(
            arguments: arguments,
            key: "approve_prerequisites"
        ) ?? false
        guard let installer = bridge.installer else {
            return MCPContent(
                type: "text",
                text: #"{"error":"installer not configured"}"#
            )
        }
        let status = await installer.install(
            languageId: languageId,
            approvePrerequisites: approve,
            confirmationMode: .silent
        )
        return try MCPLSPBridge.makeJSONContent(InstallStatusDTO(from: status))
    }
}

// MARK: - InstallStatusTool

enum InstallStatusTool: MCPLSPTool {
    static let name = "lsp_install_status"
    static let description = "Return the current install status for a languageId."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "language_id": prop("string", "Target languageId to query"),
        ]
        let required = ["language_id"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let languageId = try MCPLSPBridge.requireString(arguments: arguments, key: "language_id")
        guard let installer = bridge.installer else {
            return MCPContent(
                type: "text",
                text: #"{"error":"installer not configured"}"#
            )
        }
        let status = await installer.currentStatus(forLanguageId: languageId)
        return try MCPLSPBridge.makeJSONContent(InstallStatusDTO(from: status))
    }
}

// MARK: - SessionStatusTool

enum SessionStatusTool: MCPLSPTool {
    static let name = "lsp_session_status"
    static let description = "List every currently open LSP session."
    static let inputSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable([String: AnyCodable]()),
        "required": AnyCodable([AnyCodable]()),
    ]

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let sessions = await bridge.service.currentSessions()
        let dtos = sessions.map(SessionInfoDTO.init(from:))
        return try MCPLSPBridge.makeJSONContent(dtos)
    }
}

// MARK: - SessionWarmupTool

enum SessionWarmupTool: MCPLSPTool {
    static let name = "lsp_session_warmup"
    static let description = "Pre-start an LSP session for a workspace + languageId pair."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
        ]
        let required = ["workspace_root", "language_id"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        // `resolveSession` already enforces the required arguments and
        // returns a started session (building it on cache miss). Re-using
        // it here keeps the warmup idempotency contract aligned with the
        // dispatcher path the LSP request tools take.
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let state = await session.state()
        let dto = SessionInfoDTO(
            workspaceRoot: session.workspaceRoot.absoluteString,
            languageId: session.languageId,
            state: SessionStateDTO(from: state),
            createdAtUptimeMillis: 0
        )
        return try MCPLSPBridge.makeJSONContent(dto)
    }
}

// MARK: - SessionShutdownTool

enum SessionShutdownTool: MCPLSPTool {
    static let name = "lsp_session_shutdown"
    static let description = "Shut down a specific LSP session and forget it from the cache."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
        ]
        let required = ["workspace_root", "language_id"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let workspaceString = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "workspace_root"
        )
        let languageId = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "language_id"
        )
        let workspaceURL = MCPLSPBridge.fileURL(fromPathOrUri: workspaceString)
        await bridge.service.shutdownSession(
            workspaceRoot: workspaceURL,
            languageId: languageId
        )
        return MCPContent(type: "text", text: #"{"shutdown":true}"#)
    }
}

// MARK: - CallHierarchyPrepareTool

enum CallHierarchyPrepareTool: MCPLSPTool {
    static let name = "lsp_call_hierarchy_prepare"
    static let description = "Prepare a call hierarchy at a position. Returns CallHierarchyItem entries to use with incoming/outgoing calls."
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
        let params = CallHierarchyPrepareParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: [CallHierarchyItem]? = try await session.sendRequest(
                method: "textDocument/prepareCallHierarchy",
                params: params,
                resultType: [CallHierarchyItem]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CallHierarchyIncomingTool

enum CallHierarchyIncomingTool: MCPLSPTool {
    static let name = "lsp_call_hierarchy_incoming"
    static let description = "Get incoming calls for a CallHierarchyItem returned by lsp_call_hierarchy_prepare."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemDescription: "CallHierarchyItem returned by lsp_call_hierarchy_prepare"
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
        guard let itemAny = arguments["item"] else {
            throw MCPLSPBridgeError.missingArgument("item")
        }
        let item = try MCPLSPBridge.decodeFromAnyCodable(
            itemAny,
            as: CallHierarchyItem.self,
            argumentName: "item"
        )
        let params = CallHierarchyIncomingCallsParams(item: item)
        do {
            let result: [CallHierarchyIncomingCall]? = try await session.sendRequest(
                method: "callHierarchy/incomingCalls",
                params: params,
                resultType: [CallHierarchyIncomingCall]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CallHierarchyOutgoingTool

enum CallHierarchyOutgoingTool: MCPLSPTool {
    static let name = "lsp_call_hierarchy_outgoing"
    static let description = "Get outgoing calls for a CallHierarchyItem returned by lsp_call_hierarchy_prepare."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemDescription: "CallHierarchyItem returned by lsp_call_hierarchy_prepare"
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
        guard let itemAny = arguments["item"] else {
            throw MCPLSPBridgeError.missingArgument("item")
        }
        let item = try MCPLSPBridge.decodeFromAnyCodable(
            itemAny,
            as: CallHierarchyItem.self,
            argumentName: "item"
        )
        let params = CallHierarchyOutgoingCallsParams(item: item)
        do {
            let result: [CallHierarchyOutgoingCall]? = try await session.sendRequest(
                method: "callHierarchy/outgoingCalls",
                params: params,
                resultType: [CallHierarchyOutgoingCall]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - TypeHierarchyPrepareTool

enum TypeHierarchyPrepareTool: MCPLSPTool {
    static let name = "lsp_type_hierarchy_prepare"
    static let description = "Prepare a type hierarchy at a position. Returns TypeHierarchyItem entries to use with supertypes/subtypes."
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
        let params = TypeHierarchyPrepareParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: [TypeHierarchyItem]? = try await session.sendRequest(
                method: "textDocument/prepareTypeHierarchy",
                params: params,
                resultType: [TypeHierarchyItem]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - TypeHierarchySupertypesTool

enum TypeHierarchySupertypesTool: MCPLSPTool {
    static let name = "lsp_type_hierarchy_supertypes"
    static let description = "Get supertypes for a TypeHierarchyItem returned by lsp_type_hierarchy_prepare."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemDescription: "TypeHierarchyItem returned by lsp_type_hierarchy_prepare"
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
        guard let itemAny = arguments["item"] else {
            throw MCPLSPBridgeError.missingArgument("item")
        }
        let item = try MCPLSPBridge.decodeFromAnyCodable(
            itemAny,
            as: TypeHierarchyItem.self,
            argumentName: "item"
        )
        let params = TypeHierarchySupertypesParams(item: item)
        do {
            let result: [TypeHierarchyItem]? = try await session.sendRequest(
                method: "typeHierarchy/supertypes",
                params: params,
                resultType: [TypeHierarchyItem]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - TypeHierarchySubtypesTool

enum TypeHierarchySubtypesTool: MCPLSPTool {
    static let name = "lsp_type_hierarchy_subtypes"
    static let description = "Get subtypes for a TypeHierarchyItem returned by lsp_type_hierarchy_prepare."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemDescription: "TypeHierarchyItem returned by lsp_type_hierarchy_prepare"
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
        guard let itemAny = arguments["item"] else {
            throw MCPLSPBridgeError.missingArgument("item")
        }
        let item = try MCPLSPBridge.decodeFromAnyCodable(
            itemAny,
            as: TypeHierarchyItem.self,
            argumentName: "item"
        )
        let params = TypeHierarchySubtypesParams(item: item)
        do {
            let result: [TypeHierarchyItem]? = try await session.sendRequest(
                method: "typeHierarchy/subtypes",
                params: params,
                resultType: [TypeHierarchyItem]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - MonikerTool

enum MonikerTool: MCPLSPTool {
    static let name = "lsp_moniker"
    static let description = "Get monikers (cross-project symbol identifiers) at a position."
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
        let params = MonikerParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: [Moniker]? = try await session.sendRequest(
                method: "textDocument/moniker",
                params: params,
                resultType: [Moniker]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CodeLensTool

enum CodeLensTool: MCPLSPTool {
    static let name = "lsp_code_lens"
    static let description = "Get code lens entries (e.g. references, run/debug actions) for a document."
    static let inputSchema: [String: AnyCodable] = fileOnlySchema()

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
        let params = CodeLensParams(textDocument: TextDocumentIdentifier(uri: uri))
        do {
            let result: [CodeLens]? = try await session.sendRequest(
                method: "textDocument/codeLens",
                params: params,
                resultType: [CodeLens]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CodeLensResolveTool

enum CodeLensResolveTool: MCPLSPTool {
    static let name = "lsp_code_lens_resolve"
    static let description = "Resolve the command / data of a code lens entry returned by lsp_code_lens."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemKey: "code_lens",
        itemDescription: "CodeLens object returned by lsp_code_lens. Forwarded verbatim to codeLens/resolve."
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
        guard let codeLensAny = arguments["code_lens"] else {
            throw MCPLSPBridgeError.missingArgument("code_lens")
        }
        let codeLens = try MCPLSPBridge.decodeFromAnyCodable(
            codeLensAny,
            as: CodeLens.self,
            argumentName: "code_lens"
        )
        do {
            let result: CodeLens? = try await session.sendRequest(
                method: "codeLens/resolve",
                params: codeLens,
                resultType: CodeLens?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - InlayHintTool

enum InlayHintTool: MCPLSPTool {
    static let name = "lsp_inlay_hint"
    static let description = "Get inlay hints (inferred type / parameter labels) for a range in a document."
    static let inputSchema: [String: AnyCodable] = rangeRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, range) = try bridge.extractRange(arguments: arguments)
        let params = InlayHintParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range
        )
        do {
            let result: [InlayHint]? = try await session.sendRequest(
                method: "textDocument/inlayHint",
                params: params,
                resultType: [InlayHint]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - InlayHintResolveTool

enum InlayHintResolveTool: MCPLSPTool {
    static let name = "lsp_inlay_hint_resolve"
    static let description = "Resolve the tooltip / text edits / label parts of an InlayHint returned by lsp_inlay_hint."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemKey: "inlay_hint",
        itemDescription: "InlayHint object returned by lsp_inlay_hint. Forwarded verbatim to inlayHint/resolve."
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
        guard let hintAny = arguments["inlay_hint"] else {
            throw MCPLSPBridgeError.missingArgument("inlay_hint")
        }
        let hint = try MCPLSPBridge.decodeFromAnyCodable(
            hintAny,
            as: InlayHint.self,
            argumentName: "inlay_hint"
        )
        do {
            let result: InlayHint? = try await session.sendRequest(
                method: "inlayHint/resolve",
                params: hint,
                resultType: InlayHint?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - InlineValueTool

enum InlineValueTool: MCPLSPTool {
    static let name = "lsp_inline_value"
    static let description = "Get inline value hints for a range while a debugger is stopped at a frame."
    static let inputSchema: [String: AnyCodable] = rangeRequestSchema(
        extraProperties: [
            "frame_id": prop(
                "integer",
                "DAP stack frame id where execution has stopped. Defaults to 0."
            ),
            "stopped_start_line": prop(
                "integer",
                "0-based start line of the stopped-location range. Defaults to start_line."
            ),
            "stopped_start_column": prop(
                "integer",
                "0-based start column of the stopped-location range. Defaults to start_column."
            ),
            "stopped_end_line": prop(
                "integer",
                "0-based end line of the stopped-location range. Defaults to end_line."
            ),
            "stopped_end_column": prop(
                "integer",
                "0-based end column of the stopped-location range. Defaults to end_column."
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
        let (uri, range) = try bridge.extractRange(arguments: arguments)
        let frameId = try MCPLSPBridge.optionalInt(
            arguments: arguments,
            key: "frame_id"
        ) ?? 0
        // Spec requires a `stoppedLocation` range. When the caller omits the
        // `stopped_*` fields the bridge mirrors the requested target range —
        // a sensible default for non-debug uses where the caller does not
        // distinguish between "range under inspection" and "frame location".
        let stoppedStartLine = try MCPLSPBridge.optionalInt(
            arguments: arguments,
            key: "stopped_start_line"
        )
        let stoppedStartCol = try MCPLSPBridge.optionalInt(
            arguments: arguments,
            key: "stopped_start_column"
        )
        let stoppedEndLine = try MCPLSPBridge.optionalInt(
            arguments: arguments,
            key: "stopped_end_line"
        )
        let stoppedEndCol = try MCPLSPBridge.optionalInt(
            arguments: arguments,
            key: "stopped_end_column"
        )
        let stoppedLocation: LSPRange
        if let sl = stoppedStartLine,
           let sc = stoppedStartCol,
           let el = stoppedEndLine,
           let ec = stoppedEndCol {
            stoppedLocation = LSPRange(
                start: Position(line: sl, character: sc),
                end: Position(line: el, character: ec)
            )
        } else {
            stoppedLocation = range
        }
        let context = InlineValueContext(
            frameId: frameId,
            stoppedLocation: stoppedLocation
        )
        let params = InlineValueParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range,
            context: context
        )
        do {
            let result: [InlineValue]? = try await session.sendRequest(
                method: "textDocument/inlineValue",
                params: params,
                resultType: [InlineValue]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - FoldingRangeTool

enum FoldingRangeTool: MCPLSPTool {
    static let name = "lsp_folding_range"
    static let description = "Get folding ranges (regions, imports, comments) for a document."
    static let inputSchema: [String: AnyCodable] = fileOnlySchema()

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
        let params = FoldingRangeParams(textDocument: TextDocumentIdentifier(uri: uri))
        do {
            let result: [FoldingRange]? = try await session.sendRequest(
                method: "textDocument/foldingRange",
                params: params,
                resultType: [FoldingRange]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - SelectionRangeTool

enum SelectionRangeTool: MCPLSPTool {
    static let name = "lsp_selection_range"
    static let description = "Get selection ranges for an array of positions in a document."
    static let inputSchema: [String: AnyCodable] = {
        // `positions` is an array of `{ line, column }` objects. We document
        // the item schema inline so callers can see the expected shape via
        // `tools/list`.
        let positionItemSchema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "line": prop("integer", "0-based line number"),
                "column": prop("integer", "0-based UTF-16 column / character offset"),
            ] as [String: AnyCodable]),
            "required": AnyCodable([AnyCodable("line"), AnyCodable("column")]),
        ]
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "file": prop("string", "Absolute path or file:// URI of the target file"),
            "positions": AnyCodable([
                "type": AnyCodable("array"),
                "description": AnyCodable("Positions at which to compute selection ranges"),
                "items": AnyCodable(positionItemSchema),
            ] as [String: AnyCodable]),
        ]
        let required = ["workspace_root", "language_id", "file", "positions"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    /// MCP-facing position payload: matches the rest of the bridge's
    /// `{ line, column }` convention. Translated into an LSP `Position`
    /// (`character` key) before sending.
    private struct PositionInput: Decodable, Sendable {
        let line: Int
        let column: Int
    }

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
        guard let positionsAny = arguments["positions"] else {
            throw MCPLSPBridgeError.missingArgument("positions")
        }
        // `AnyCodable.storage` is private. Round-trip through JSON to recover
        // the typed `[PositionInput]` array. Mirrors `decodeFromAnyCodable`
        // but is tailored to surface a clearer error message for the
        // positions-array case.
        let inputs: [PositionInput]
        do {
            let data = try JSONEncoder().encode(positionsAny)
            inputs = try JSONDecoder().decode([PositionInput].self, from: data)
        } catch {
            throw MCPLSPBridgeError.invalidArgument(
                name: "positions",
                reason: "expected an array of {line, column} objects: \(error)"
            )
        }
        let positions = inputs.map {
            Position(line: $0.line, character: $0.column)
        }
        let params = SelectionRangeParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            positions: positions
        )
        do {
            let result: [SelectionRange]? = try await session.sendRequest(
                method: "textDocument/selectionRange",
                params: params,
                resultType: [SelectionRange]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - SemanticTokensFullTool

enum SemanticTokensFullTool: MCPLSPTool {
    static let name = "lsp_semantic_tokens_full"
    static let description = "Get semantic tokens for a whole document (textDocument/semanticTokens/full)."
    static let inputSchema: [String: AnyCodable] = fileOnlySchema()

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
        let params = SemanticTokensParams(
            textDocument: TextDocumentIdentifier(uri: uri)
        )
        do {
            let result: SemanticTokens? = try await session.sendRequest(
                method: "textDocument/semanticTokens/full",
                params: params,
                resultType: SemanticTokens?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - SemanticTokensRangeTool

enum SemanticTokensRangeTool: MCPLSPTool {
    static let name = "lsp_semantic_tokens_range"
    static let description = "Get semantic tokens for a range in a document (textDocument/semanticTokens/range)."
    static let inputSchema: [String: AnyCodable] = rangeRequestSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let session: LSPSession
        do {
            session = try await bridge.resolveSession(arguments: arguments)
        } catch let err as MCPLSPBridgeError {
            throw err
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
        let (uri, range) = try bridge.extractRange(arguments: arguments)
        let params = SemanticTokensRangeParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range
        )
        do {
            let result: SemanticTokens? = try await session.sendRequest(
                method: "textDocument/semanticTokens/range",
                params: params,
                resultType: SemanticTokens?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - SemanticTokensDeltaTool

enum SemanticTokensDeltaTool: MCPLSPTool {
    static let name = "lsp_semantic_tokens_delta"
    static let description = "Get a delta of semantic tokens against a previous result id (textDocument/semanticTokens/full/delta)."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "file": prop("string", "Absolute path or file:// URI of the target file"),
            "previous_result_id": prop(
                "string",
                "resultId returned by a previous semanticTokens/full (or /delta) call"
            ),
        ]
        let required = ["workspace_root", "language_id", "file", "previous_result_id"]
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
        let previousResultId = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "previous_result_id"
        )
        let params = SemanticTokensDeltaParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            previousResultId: previousResultId
        )
        do {
            let result: SemanticTokensDeltaResult? = try await session.sendRequest(
                method: "textDocument/semanticTokens/full/delta",
                params: params,
                resultType: SemanticTokensDeltaResult?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - LinkedEditingRangeTool

enum LinkedEditingRangeTool: MCPLSPTool {
    static let name = "lsp_linked_editing_range"
    static let description = "Get linked editing ranges at a position (e.g. matching open/close tags)."
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
        let params = LinkedEditingRangeParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        do {
            let result: LinkedEditingRanges? = try await session.sendRequest(
                method: "textDocument/linkedEditingRange",
                params: params,
                resultType: LinkedEditingRanges?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DocumentLinkTool

enum DocumentLinkTool: MCPLSPTool {
    static let name = "lsp_document_link"
    static let description = "Get document links (e.g. import paths, URLs) for a document."
    static let inputSchema: [String: AnyCodable] = fileOnlySchema()

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
        let params = DocumentLinkParams(
            textDocument: TextDocumentIdentifier(uri: uri)
        )
        do {
            let result: [DocumentLink]? = try await session.sendRequest(
                method: "textDocument/documentLink",
                params: params,
                resultType: [DocumentLink]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DocumentLinkResolveTool

enum DocumentLinkResolveTool: MCPLSPTool {
    static let name = "lsp_document_link_resolve"
    static let description = "Resolve the target / data of a DocumentLink returned by lsp_document_link."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemKey: "document_link",
        itemDescription: "DocumentLink object returned by lsp_document_link. Forwarded verbatim to documentLink/resolve."
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
        guard let linkAny = arguments["document_link"] else {
            throw MCPLSPBridgeError.missingArgument("document_link")
        }
        let link = try MCPLSPBridge.decodeFromAnyCodable(
            linkAny,
            as: DocumentLink.self,
            argumentName: "document_link"
        )
        do {
            let result: DocumentLink? = try await session.sendRequest(
                method: "documentLink/resolve",
                params: link,
                resultType: DocumentLink?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - DocumentColorTool

enum DocumentColorTool: MCPLSPTool {
    static let name = "lsp_document_color"
    static let description = "Get color references in a document for color presentation pickers."
    static let inputSchema: [String: AnyCodable] = fileOnlySchema()

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
        let params = DocumentColorParams(
            textDocument: TextDocumentIdentifier(uri: uri)
        )
        do {
            let result: [ColorInformation]? = try await session.sendRequest(
                method: "textDocument/documentColor",
                params: params,
                resultType: [ColorInformation]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - ColorPresentationTool

enum ColorPresentationTool: MCPLSPTool {
    static let name = "lsp_color_presentation"
    static let description = "Get textual color presentations (hex / rgba labels) for a color at a range."
    static let inputSchema: [String: AnyCodable] = rangeRequestSchema(
        extraProperties: [
            "color": AnyCodable([
                "type": AnyCodable("object"),
                "description": AnyCodable(
                    "LSP Color with red, green, blue, alpha doubles in the closed range [0, 1]."
                ),
            ] as [String: AnyCodable]),
        ],
        extraRequired: ["color"]
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
        let (uri, range) = try bridge.extractRange(arguments: arguments)
        guard let colorAny = arguments["color"] else {
            throw MCPLSPBridgeError.missingArgument("color")
        }
        let color = try MCPLSPBridge.decodeFromAnyCodable(
            colorAny,
            as: LSPColor.self,
            argumentName: "color"
        )
        let params = ColorPresentationParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            color: color,
            range: range
        )
        do {
            let result: [ColorPresentation]? = try await session.sendRequest(
                method: "textDocument/colorPresentation",
                params: params,
                resultType: [ColorPresentation]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - Install / session DTOs
//
// `LSPInstaller` / `LSPService` ship value types that are deliberately not
// `Codable` (they include `URL?` maps and non-Codable associated values).
// These DTOs mirror only the fields the MCP surface needs to render, and
// add explicit Codable conformance with stable JSON shapes.

/// JSON shape returned by `lsp_check_installation`.
private struct InstallationCheckDTO: Codable, Sendable, Equatable {
    let languageId: String
    let isInstalled: Bool
    let detectedPath: String?
    let detectedVersion: String?
    let prerequisiteStatuses: [String: String?]

    init(from check: InstallationCheck) {
        self.languageId = check.languageId
        self.isInstalled = check.isInstalled
        self.detectedPath = check.detectedPath?.absoluteString
        self.detectedVersion = check.detectedVersion
        var prereqs: [String: String?] = [:]
        for (key, value) in check.prerequisiteStatuses {
            prereqs[key] = value?.absoluteString
        }
        self.prerequisiteStatuses = prereqs
    }
}

/// JSON shape returned by `lsp_install` and `lsp_install_status`.
///
/// Encoded form examples:
///   - `{"state":"notStarted"}`
///   - `{"state":"inProgress","step":"…"}`
///   - `{"state":"completed"}`
///   - `{"state":"failed","reason":"…"}`
private struct InstallStatusDTO: Codable, Sendable, Equatable {
    let state: String
    let step: String?
    let reason: String?

    init(from status: LSPInstallStatus) {
        switch status {
        case .notStarted:
            self.state = "notStarted"
            self.step = nil
            self.reason = nil
        case .inProgress(let step):
            self.state = "inProgress"
            self.step = step
            self.reason = nil
        case .completed:
            self.state = "completed"
            self.step = nil
            self.reason = nil
        case .failed(let reason):
            self.state = "failed"
            self.step = nil
            self.reason = reason
        }
    }
}

/// JSON shape returned by `lsp_session_status` / `lsp_session_warmup`.
///
/// `state` is rendered as a discriminated nested DTO so the consumer can
/// match on the lifecycle phase without parsing free text.
private struct SessionInfoDTO: Codable, Sendable, Equatable {
    let workspaceRoot: String
    let languageId: String
    let state: SessionStateDTO
    let createdAtUptimeMillis: Int64

    init(
        workspaceRoot: String,
        languageId: String,
        state: SessionStateDTO,
        createdAtUptimeMillis: Int64
    ) {
        self.workspaceRoot = workspaceRoot
        self.languageId = languageId
        self.state = state
        self.createdAtUptimeMillis = createdAtUptimeMillis
    }

    init(from info: LSPSessionInfo) {
        self.workspaceRoot = info.workspaceRoot.absoluteString
        self.languageId = info.languageId
        self.state = SessionStateDTO(from: info.state)
        self.createdAtUptimeMillis = info.createdAtUptimeMillis
    }
}

/// Discriminated JSON shape for a `SessionState`.
private struct SessionStateDTO: Codable, Sendable, Equatable {
    let phase: String
    let serverName: String?
    let serverVersion: String?
    let reason: String?

    init(from state: SessionState) {
        switch state {
        case .notStarted:
            self.phase = "notStarted"
            self.serverName = nil
            self.serverVersion = nil
            self.reason = nil
        case .initializing:
            self.phase = "initializing"
            self.serverName = nil
            self.serverVersion = nil
            self.reason = nil
        case .running(let serverInfo):
            self.phase = "running"
            self.serverName = serverInfo?.name
            self.serverVersion = serverInfo?.version
            self.reason = nil
        case .shuttingDown:
            self.phase = "shuttingDown"
            self.serverName = nil
            self.serverVersion = nil
            self.reason = nil
        case .shutdown:
            self.phase = "shutdown"
            self.serverName = nil
            self.serverVersion = nil
            self.reason = nil
        case .failed(let reason):
            self.phase = "failed"
            self.serverName = nil
            self.serverVersion = nil
            self.reason = reason
        }
    }
}
