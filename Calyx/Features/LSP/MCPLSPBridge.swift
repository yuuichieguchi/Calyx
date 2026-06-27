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
//      lsp_completion_resolve        -> completionItem/resolve
//      lsp_code_action_resolve       -> codeAction/resolve
//      lsp_formatting                -> textDocument/formatting
//      lsp_range_formatting          -> textDocument/rangeFormatting
//      lsp_on_type_formatting        -> textDocument/onTypeFormatting
//      lsp_workspace_symbol_resolve  -> workspaceSymbol/resolve
//      lsp_workspace_diagnostic_pull -> workspace/diagnostic
//      lsp_workspace_execute_command -> workspace/executeCommand
//      lsp_workspace_apply_edit      -> Calyx-internal (no LSP request)
//      lsp_workspace_configuration_get -> bridge-internal store read
//      lsp_workspace_configuration_set -> bridge-internal store write
//
//  Response shaping rule: every tool serialises its LSP result as JSON and
//  hands the JSON string back as the `text` of a single `MCPContent` block.
//  A JSON `null` result surfaces as the literal string `"null"`. Server
//  errors are caught and the error message is embedded in the text payload
//  (rather than propagated as a thrown error) so the MCP caller still
//  receives a structured `content` block.
//

import Foundation
import OSLog

private let bridgeLogger = Logger(subsystem: "com.calyx", category: "lsp.bridge")

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

    /// Bridge-internal configuration store backing
    /// `lsp_workspace_configuration_get` / `_set`. Keyed by a composite
    /// `"<workspace_root>\0<language_id>\0<section>"` string so each
    /// `(workspace, language, section)` triple owns an independent slot.
    /// Values are forwarded verbatim — the store does not interpret them.
    private var configurationStore: [String: AnyCodable] = [:]

    /// Bridge-side diagnostics snapshot store backing the
    /// `lsp_diagnostics_diff` AI tool. Reads do not hit the LSP server —
    /// the diff is materialised entirely from data ingested earlier via
    /// `textDocument/publishDiagnostics` notifications. The store is
    /// owned externally and handed in at init: the SAME instance MUST
    /// also be passed to `LSPService.init(diagnosticsStore:)` so server
    /// publishes feed back into the same store the bridge reads from.
    /// Tests that don't care about publish wiring may construct a fresh
    /// `DiagnosticsStore()` and pass it in explicitly.
    let diagnosticsStore: DiagnosticsStore

    // MARK: Init

    /// Designated initializer. `installer` stays optional for callers
    /// that don't need the install/orchestration cluster (e.g. the
    /// legacy `CalyxMCPServer` wiring before installer support
    /// landed). `diagnosticsStore` is required and has no default —
    /// accepting a fresh internal store when callers omitted it was a
    /// footgun: the bridge's diff view would then silently disconnect
    /// from the `textDocument/publishDiagnostics` traffic the
    /// surrounding `LSPService` ingests into its own (different)
    /// store, and `lsp_diagnostics_diff` would always come back empty.
    init(
        service: LSPService,
        workspaceResolver: WorkspaceResolver,
        installer: LSPInstaller? = nil,
        diagnosticsStore: DiagnosticsStore
    ) {
        self.service = service
        self.workspaceResolver = workspaceResolver
        self.installer = installer
        self.diagnosticsStore = diagnosticsStore
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
            MCPTool(
                name: CompletionResolveTool.name,
                description: CompletionResolveTool.description,
                inputSchema: CompletionResolveTool.inputSchema
            ),
            MCPTool(
                name: CodeActionResolveTool.name,
                description: CodeActionResolveTool.description,
                inputSchema: CodeActionResolveTool.inputSchema
            ),
            MCPTool(
                name: FormattingTool.name,
                description: FormattingTool.description,
                inputSchema: FormattingTool.inputSchema
            ),
            MCPTool(
                name: RangeFormattingTool.name,
                description: RangeFormattingTool.description,
                inputSchema: RangeFormattingTool.inputSchema
            ),
            MCPTool(
                name: OnTypeFormattingTool.name,
                description: OnTypeFormattingTool.description,
                inputSchema: OnTypeFormattingTool.inputSchema
            ),
            MCPTool(
                name: WorkspaceSymbolResolveTool.name,
                description: WorkspaceSymbolResolveTool.description,
                inputSchema: WorkspaceSymbolResolveTool.inputSchema
            ),
            MCPTool(
                name: WorkspaceDiagnosticPullTool.name,
                description: WorkspaceDiagnosticPullTool.description,
                inputSchema: WorkspaceDiagnosticPullTool.inputSchema
            ),
            MCPTool(
                name: WorkspaceExecuteCommandTool.name,
                description: WorkspaceExecuteCommandTool.description,
                inputSchema: WorkspaceExecuteCommandTool.inputSchema
            ),
            MCPTool(
                name: WorkspaceApplyEditTool.name,
                description: WorkspaceApplyEditTool.description,
                inputSchema: WorkspaceApplyEditTool.inputSchema
            ),
            MCPTool(
                name: WorkspaceConfigurationGetTool.name,
                description: WorkspaceConfigurationGetTool.description,
                inputSchema: WorkspaceConfigurationGetTool.inputSchema
            ),
            MCPTool(
                name: WorkspaceConfigurationSetTool.name,
                description: WorkspaceConfigurationSetTool.description,
                inputSchema: WorkspaceConfigurationSetTool.inputSchema
            ),
            MCPTool(
                name: WillCreateFilesTool.name,
                description: WillCreateFilesTool.description,
                inputSchema: WillCreateFilesTool.inputSchema
            ),
            MCPTool(
                name: DidCreateFilesTool.name,
                description: DidCreateFilesTool.description,
                inputSchema: DidCreateFilesTool.inputSchema
            ),
            MCPTool(
                name: WillRenameFilesTool.name,
                description: WillRenameFilesTool.description,
                inputSchema: WillRenameFilesTool.inputSchema
            ),
            MCPTool(
                name: DidRenameFilesTool.name,
                description: DidRenameFilesTool.description,
                inputSchema: DidRenameFilesTool.inputSchema
            ),
            MCPTool(
                name: WillDeleteFilesTool.name,
                description: WillDeleteFilesTool.description,
                inputSchema: WillDeleteFilesTool.inputSchema
            ),
            MCPTool(
                name: DidDeleteFilesTool.name,
                description: DidDeleteFilesTool.description,
                inputSchema: DidDeleteFilesTool.inputSchema
            ),
            MCPTool(
                name: BatchTool.name,
                description: BatchTool.description,
                inputSchema: BatchTool.inputSchema
            ),
            MCPTool(
                name: HoverBundleTool.name,
                description: HoverBundleTool.description,
                inputSchema: HoverBundleTool.inputSchema
            ),
            MCPTool(
                name: SymbolWalkTool.name,
                description: SymbolWalkTool.description,
                inputSchema: SymbolWalkTool.inputSchema
            ),
            MCPTool(
                name: GlobalWorkspaceSymbolTool.name,
                description: GlobalWorkspaceSymbolTool.description,
                inputSchema: GlobalWorkspaceSymbolTool.inputSchema
            ),
            MCPTool(
                name: CrossWorkspaceDefinitionTool.name,
                description: CrossWorkspaceDefinitionTool.description,
                inputSchema: CrossWorkspaceDefinitionTool.inputSchema
            ),
            MCPTool(
                name: DiagnosticsDiffTool.name,
                description: DiagnosticsDiffTool.description,
                inputSchema: DiagnosticsDiffTool.inputSchema
            ),
            MCPTool(
                name: CapabilitiesTool.name,
                description: CapabilitiesTool.description,
                inputSchema: CapabilitiesTool.inputSchema
            ),
            MCPTool(
                name: NotebookDidOpenTool.name,
                description: NotebookDidOpenTool.description,
                inputSchema: NotebookDidOpenTool.inputSchema
            ),
            MCPTool(
                name: NotebookDidChangeTool.name,
                description: NotebookDidChangeTool.description,
                inputSchema: NotebookDidChangeTool.inputSchema
            ),
            MCPTool(
                name: NotebookDidCloseTool.name,
                description: NotebookDidCloseTool.description,
                inputSchema: NotebookDidCloseTool.inputSchema
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
        case CompletionResolveTool.name:
            return try await CompletionResolveTool.handle(arguments: arguments, bridge: self)
        case CodeActionResolveTool.name:
            return try await CodeActionResolveTool.handle(arguments: arguments, bridge: self)
        case FormattingTool.name:
            return try await FormattingTool.handle(arguments: arguments, bridge: self)
        case RangeFormattingTool.name:
            return try await RangeFormattingTool.handle(arguments: arguments, bridge: self)
        case OnTypeFormattingTool.name:
            return try await OnTypeFormattingTool.handle(arguments: arguments, bridge: self)
        case WorkspaceSymbolResolveTool.name:
            return try await WorkspaceSymbolResolveTool.handle(arguments: arguments, bridge: self)
        case WorkspaceDiagnosticPullTool.name:
            return try await WorkspaceDiagnosticPullTool.handle(arguments: arguments, bridge: self)
        case WorkspaceExecuteCommandTool.name:
            return try await WorkspaceExecuteCommandTool.handle(arguments: arguments, bridge: self)
        case WorkspaceApplyEditTool.name:
            return try await WorkspaceApplyEditTool.handle(arguments: arguments, bridge: self)
        case WorkspaceConfigurationGetTool.name:
            return try await WorkspaceConfigurationGetTool.handle(arguments: arguments, bridge: self)
        case WorkspaceConfigurationSetTool.name:
            return try await WorkspaceConfigurationSetTool.handle(arguments: arguments, bridge: self)
        case WillCreateFilesTool.name:
            return try await WillCreateFilesTool.handle(arguments: arguments, bridge: self)
        case DidCreateFilesTool.name:
            return try await DidCreateFilesTool.handle(arguments: arguments, bridge: self)
        case WillRenameFilesTool.name:
            return try await WillRenameFilesTool.handle(arguments: arguments, bridge: self)
        case DidRenameFilesTool.name:
            return try await DidRenameFilesTool.handle(arguments: arguments, bridge: self)
        case WillDeleteFilesTool.name:
            return try await WillDeleteFilesTool.handle(arguments: arguments, bridge: self)
        case DidDeleteFilesTool.name:
            return try await DidDeleteFilesTool.handle(arguments: arguments, bridge: self)
        case BatchTool.name:
            return try await BatchTool.handle(arguments: arguments, bridge: self)
        case HoverBundleTool.name:
            return try await HoverBundleTool.handle(arguments: arguments, bridge: self)
        case SymbolWalkTool.name:
            return try await SymbolWalkTool.handle(arguments: arguments, bridge: self)
        case GlobalWorkspaceSymbolTool.name:
            return try await GlobalWorkspaceSymbolTool.handle(arguments: arguments, bridge: self)
        case CrossWorkspaceDefinitionTool.name:
            return try await CrossWorkspaceDefinitionTool.handle(arguments: arguments, bridge: self)
        case DiagnosticsDiffTool.name:
            return try await DiagnosticsDiffTool.handle(arguments: arguments, bridge: self)
        case CapabilitiesTool.name:
            return try await CapabilitiesTool.handle(arguments: arguments, bridge: self)
        case NotebookDidOpenTool.name:
            return try await NotebookDidOpenTool.handle(arguments: arguments, bridge: self)
        case NotebookDidChangeTool.name:
            return try await NotebookDidChangeTool.handle(arguments: arguments, bridge: self)
        case NotebookDidCloseTool.name:
            return try await NotebookDidCloseTool.handle(arguments: arguments, bridge: self)
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

    // MARK: - didOpen orchestration

    /// Ensure that `uri` is registered as an open document on `session`
    /// before a position/range/file-based LSP request is dispatched.
    ///
    /// Most language servers (sourcekit-lsp, gopls, rust-analyzer, the
    /// TypeScript server, …) refuse to answer `textDocument/*` requests
    /// for a URI that the client has not previously announced via
    /// `textDocument/didOpen`; sourcekit-lsp surfaces the failure as the
    /// `-32001 "No language service for '...' found"` JSON-RPC error.
    /// MCP tool calls are stateless from the caller's point of view, so
    /// the bridge has to lazily synthesise the didOpen on first contact.
    ///
    /// Behaviour:
    ///   * No-op when the session already tracks the URI (idempotent).
    ///   * No-op for non-`file://` URIs (`untitled:`, `jdt://`, …) — the
    ///     bridge has no on-disk source to read for those.
    ///   * No-op when the file does not exist or can't be read; the
    ///     downstream request will surface a more informative error than
    ///     "we failed before even asking the server."
    ///   * Best-effort: any error from `session.didOpen` is silently
    ///     absorbed so a missing didOpen never replaces the actual
    ///     diagnostic the caller wanted (e.g. a server crash).
    ///
    /// `nonisolated static` so the per-tool handlers (which only carry an
    /// `LSPSession` reference, not the `@MainActor` bridge) can call it
    /// without an extra actor hop.
    ///
    /// Throws when the URI is truly unparseable (`normalizeFileURI` returns
    /// nil for the file:// case), or when the file exists on disk but
    /// cannot be decoded as text in any encoding (UTF-8 attempt followed by
    /// `usedEncoding:` sniff). Non-file URIs (untitled:, jdt://, …) and
    /// file URIs that point at a missing on-disk source are left as silent
    /// no-ops so the downstream LSP request can produce its own diagnostic.
    nonisolated static func ensureFileOpen(
        session: LSPSession,
        uri: DocumentUri
    ) async throws {
        // Idempotency guard: skip work when the URI is already tracked.
        let openDocs = await session.openDocuments()
        if openDocs.contains(uri) {
            return
        }

        // Only file:// URIs map to a readable on-disk source. Anything
        // else (untitled:, jdt://, vscode-notebook-cell:, …) is left
        // alone — the caller is responsible for opening those via the
        // bridge's notebook / explicit didOpen surface.
        guard uri.hasPrefix("file://") else { return }

        // Normalize via the shared helper so unparseable inputs surface
        // as a structured error instead of a silent no-op.
        let normalized = normalizeFileURI(uri)
        guard let url = normalized.fileURL, url.isFileURL else {
            throw MCPLSPBridgeError.invalidArgument(
                name: "uri",
                reason: "unparseable file URI: \(uri)"
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        // Try UTF-8 first; fall back to a tolerant `usedEncoding:` sniff
        // so non-UTF-8 sources still surface a didOpen instead of a
        // silent skip that hides the encoding issue behind a server-side
        // "no language service" error. As a final safety net, attempt
        // `isoLatin1` — every byte 0x00-0xFF maps to a Unicode codepoint
        // in Latin-1, so the decode is guaranteed to succeed for any
        // file that opens at all. The throw on the very last branch
        // therefore only fires when even opening the file fails (e.g.
        // permissions revoked between the existence check and the read).
        let text: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            text = utf8
        } else {
            var used = String.Encoding.utf8
            if let sniffed = try? String(contentsOf: url, usedEncoding: &used) {
                text = sniffed
            } else if let latin1 = try? String(contentsOf: url, encoding: .isoLatin1) {
                text = latin1
            } else {
                throw MCPLSPBridgeError.invalidArgument(
                    name: "uri",
                    reason: "file not readable as text (utf-8 decode and encoding sniff both failed): \(uri)"
                )
            }
        }

        // Use the session's default languageId. `didOpen` is itself
        // idempotent inside the session (it dedups on `openDocs`), so a
        // race between two MCP tool calls that both reach this point
        // before either has finished only sends one notification.
        try? await session.didOpen(
            uri: uri,
            languageId: session.languageId,
            version: 1,
            text: text
        )
    }

    // MARK: - Bridge-internal configuration store

    /// Compose the composite key used by the configuration store. The
    /// separator is `U+0000` (NUL) so any user-supplied string can be used
    /// for `workspace_root` / `language_id` / `section` without ambiguity —
    /// NUL cannot appear in any of the three components.
    nonisolated static func workspaceConfigurationKey(
        workspaceRoot: String,
        languageId: String,
        section: String
    ) -> String {
        "\(workspaceRoot)\u{0000}\(languageId)\u{0000}\(section)"
    }

    /// Read a stored configuration value, or `nil` if the triple has never
    /// been written to.
    func workspaceConfiguration(key: String) -> AnyCodable? {
        configurationStore[key]
    }

    /// Write a configuration value, overwriting any prior value for the
    /// same triple.
    func setWorkspaceConfiguration(key: String, value: AnyCodable) {
        configurationStore[key] = value
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

    /// Decode a required `Bool` argument; throws `missingArgument` when
    /// absent and `invalidArgument` when the underlying JSON is the wrong
    /// shape (e.g. a stray integer or string instead of a boolean).
    nonisolated static func requireBool(arguments: [String: AnyCodable], key: String) throws -> Bool {
        guard let raw = arguments[key] else {
            throw MCPLSPBridgeError.missingArgument(key)
        }
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
    ///
    /// `Int` and `Bool` use strict numeric discrimination:
    ///   - `Int` rejects fractional doubles (`3.9` → nil, not truncated to 3)
    ///     and CFBoolean values.
    ///   - `Bool` only accepts actual `CFBoolean` instances, not arbitrary
    ///     `NSNumber`s coerced via `boolValue` (a JSON `42` must not become
    ///     `true` just because it is non-zero).
    private nonisolated static func decodeValue<T>(_ raw: AnyCodable) -> T? {
        guard let data = try? JSONEncoder().encode(raw),
              let any = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              )
        else { return nil }

        // Bool: reject NSNumbers that aren't a CFBoolean. This is the only
        // way to distinguish JSON `true`/`false` from JSON `1`/`0` — the
        // standard `as? Bool` cast happily succeeds for any 0/1 NSNumber.
        if T.self == Bool.self {
            guard let n = any as? NSNumber,
                  CFGetTypeID(n) == CFBooleanGetTypeID()
            else { return nil }
            return n.boolValue as? T
        }

        // Int: require a whole-number NSNumber. Reject fractional doubles
        // (truncating 3.9 to 3 was the historical defect) and CFBooleans
        // (so `include_declaration: true` does not silently become `1`).
        if T.self == Int.self {
            guard let n = any as? NSNumber else { return nil }
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            guard d.isFinite,
                  d == d.rounded(.toNearestOrEven),
                  d == floor(d)
            else { return nil }
            return Int(truncating: n) as? T
        }

        if let value = any as? T { return value }
        return nil
    }

    /// Normalize `input` (either an absolute filesystem path or a
    /// `file://` URI) into a `(uri, fileURL)` pair where both fields are
    /// derived from the same canonical path. The two forms (raw path vs
    /// `file://`) MUST converge so the session-cache key in
    /// `LSPService.session(for:)` doesn't split a single logical
    /// workspace into two sessions.
    ///
    /// Returns `fileURL == nil` only for truly unparseable `file://`
    /// inputs (e.g. `file://[bad]/foo bar baz`) whose path component
    /// doesn't even start with `/`. Callers that need to react to that
    /// case (`ensureFileOpen` throws an `invalidArgument` error) inspect
    /// the optional directly.
    nonisolated static func normalizeFileURI(_ input: String) -> (uri: String, fileURL: URL?) {
        // A registered-name host (RFC 3986 §3.2.2) is composed of
        // unreserved + sub-delims + percent-encoded octets. We accept
        // the conservative subset that covers SMB-share / DNS hostnames
        // in practice (ASCII letters, digits, `.`, `-`, `_`, `~`) and
        // reject everything else — in particular `[`, `]`, whitespace,
        // and `/` which would indicate a malformed authority component
        // (e.g. `file://[bad]/...`).
        func isValidRegisteredHost(_ host: String) -> Bool {
            guard !host.isEmpty else { return false }
            for scalar in host.unicodeScalars {
                let v = scalar.value
                let isASCIILetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
                let isDigit = v >= 0x30 && v <= 0x39
                let isOtherUnreserved = scalar == "." || scalar == "-"
                    || scalar == "_" || scalar == "~"
                if !(isASCIILetter || isDigit || isOtherUnreserved) {
                    return false
                }
            }
            return true
        }

        if input.hasPrefix("file://") {
            // Fast path: a well-formed `file://` URI with no query /
            // fragment. `URL(string:)` correctly percent-decodes the
            // path portion and round-trips spaces and friends through
            // `.absoluteString`. We bail to the rebuild path when:
            //   * URL(string:) returns nil (someone smuggled in totally
            //     malformed text after the scheme)
            //   * isFileURL is false (the scheme was rewritten)
            //   * query / fragment are present (a `?` in the filename is
            //     a perfectly legal POSIX path char but URL(string:)
            //     misinterprets it as a query delimiter — the rebuild
            //     path correctly re-encodes it)
            //
            // Per RFC 8089 §3 the `file://<host>/<path>` form is valid
            // (SMB shares, Windows UNC paths). We accept both the
            // empty-host (`file:///path`) and the non-empty-host
            // (`file://server/share/path`) forms here, provided the
            // path component is absolute. A non-empty host must look
            // like a registered name — anything that looks like a
            // malformed IP-literal (`[bad]`) or carries forbidden host
            // characters is rejected so the caller can surface a
            // structured "unparseable URI" error.
            if let url = URL(string: input),
               url.isFileURL,
               url.query == nil,
               url.fragment == nil,
               url.path.hasPrefix("/") {
                // Use URLComponents.host because it preserves the
                // square-bracket form for IP-literals — e.g.
                // `file://[bad]/...` exposes host=="[bad]" via
                // URLComponents but host=="bad" via URL.host, and the
                // bracketed form is the one we must reject as a
                // malformed registered name.
                let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host ?? ""
                if host.isEmpty || isValidRegisteredHost(host) {
                    return (url.absoluteString, url)
                }
            }
            // Strip the scheme and inspect what comes next. A
            // well-formed file URI is either:
            //   * `file:///<absolute-path>` — empty host, path starts at
            //     the third `/`.
            //   * `file://<host>/<absolute-path>` (RFC 8089 §3) — host
            //     ends at the first `/` after the scheme, path is
            //     everything from that `/` onwards.
            // For the empty-host form we can hand the absolute path to
            // `URL(fileURLWithPath:)` directly. For the host form we
            // must preserve the host on the rebuild so the
            // percent-encoded output keeps the `file://<host>/<path>`
            // shape.
            let pathPart = String(input.dropFirst("file://".count))
            if pathPart.hasPrefix("/") {
                let fileURL = URL(fileURLWithPath: pathPart)
                return (fileURL.absoluteString, fileURL)
            }
            // Host form: split on the first `/` after the scheme. The
            // remainder MUST start with `/` (an absolute path) — anything
            // else is malformed (`file://server` with no path, etc.).
            if let slashIdx = pathPart.firstIndex(of: "/") {
                let host = String(pathPart[..<slashIdx])
                let absolutePath = String(pathPart[slashIdx...])
                if isValidRegisteredHost(host), absolutePath.hasPrefix("/") {
                    // Build a `file://<host><absolute-path>` URL via
                    // URLComponents so the host is preserved and the
                    // path is percent-encoded consistently with the
                    // empty-host fast path.
                    var comps = URLComponents()
                    comps.scheme = "file"
                    comps.host = host
                    comps.path = absolutePath
                    if let url = comps.url, url.isFileURL {
                        return (url.absoluteString, url)
                    }
                }
            }
            // Anything else is malformed; return nil so `ensureFileOpen`
            // can throw a structured error instead of silently inventing
            // a relative path.
            return (input, nil)
        }
        let fileURL = URL(fileURLWithPath: input)
        return (fileURL.absoluteString, fileURL)
    }

    /// Convert a workspace path (either an absolute filesystem path or a
    /// `file://` URI) into a `URL` suitable for `LSPService.session(for:)`.
    /// The result is derived from `normalizeFileURI` so raw-path and
    /// `file://` callers converge on the same `URL` (and therefore the
    /// same session-cache key).
    nonisolated static func fileURL(fromPathOrUri input: String) -> URL {
        if let url = normalizeFileURI(input).fileURL {
            return url
        }
        // Fall back to a permissive `URL(fileURLWithPath:)` on the raw
        // input so this helper never returns nil for legitimate workspace
        // paths. `ensureFileOpen` is the surface that surfaces
        // "unparseable" as a structured error, not this helper.
        return URL(fileURLWithPath: input)
    }

    /// Convert an absolute path or `file://` URI into the LSP
    /// `DocumentUri` (string) form. Goes through `normalizeFileURI` so
    /// raw-path callers and `file://` callers produce the same
    /// percent-encoded string for the same logical file.
    nonisolated static func documentUri(fromPathOrUri input: String) -> DocumentUri {
        normalizeFileURI(input).uri
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

/// Build the JSON-Schema for a formatting MCP tool (`lsp_formatting`,
/// `lsp_range_formatting`, `lsp_on_type_formatting`). The three tools share
/// `workspace_root`, `language_id`, `file`, `options`; range / position-and-ch
/// variants are gated on the two flags so each tool keeps a stable schema
/// without sprouting bespoke shapes.
private func formattingSchema(
    includeRange: Bool,
    includePositionAndCh: Bool
) -> [String: AnyCodable] {
    var props: [String: AnyCodable] = [
        "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
        "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
        "file": prop("string", "Absolute path or file:// URI of the target file"),
        "options": AnyCodable([
            "type": AnyCodable("object"),
            "description": AnyCodable(
                "FormattingOptions object: { tabSize: int, insertSpaces: bool,"
                + " trimTrailingWhitespace?: bool, insertFinalNewline?: bool,"
                + " trimFinalNewlines?: bool }"
            ),
        ] as [String: AnyCodable]),
    ]
    var required = ["workspace_root", "language_id", "file", "options"]
    if includeRange {
        props["start_line"] = prop("integer", "0-based start line of the target range")
        props["start_column"] = prop("integer", "0-based start column of the target range")
        props["end_line"] = prop("integer", "0-based end line of the target range")
        props["end_column"] = prop("integer", "0-based end column of the target range")
        required.append(contentsOf: ["start_line", "start_column", "end_line", "end_column"])
    }
    if includePositionAndCh {
        props["line"] = prop("integer", "0-based line number where the character was typed")
        props["column"] = prop("integer", "0-based UTF-16 column where the character was typed")
        props["ch"] = prop(
            "string",
            "The character that triggered on-type formatting (e.g. '}' or ';')"
        )
        required.append(contentsOf: ["line", "column", "ch"])
    }
    return [
        "type": AnyCodable("object"),
        "properties": AnyCodable(props),
        "required": AnyCodable(required.map { AnyCodable($0) }),
    ]
}

/// Build the JSON-Schema for a `workspace/*Files` MCP tool. `itemKeys`
/// lists the required string keys that each `files[i]` object must
/// expose:
///   - `["uri"]`           for create / delete (and their will-/did-
///                          counterparts)
///   - `["oldUri", "newUri"]` for rename
private func filesArraySchema(itemKeys: [String]) -> [String: AnyCodable] {
    var itemProps: [String: AnyCodable] = [:]
    for key in itemKeys {
        itemProps[key] = prop("string", "file:// URI for this file or folder")
    }
    let itemSchema: [String: AnyCodable] = [
        "type": AnyCodable("object"),
        "properties": AnyCodable(itemProps),
        "required": AnyCodable(itemKeys.map { AnyCodable($0) }),
    ]
    let props: [String: AnyCodable] = [
        "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
        "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
        "files": AnyCodable([
            "type": AnyCodable("array"),
            "description": AnyCodable(
                "Array of file descriptors. Each entry carries the keys: "
                + itemKeys.joined(separator: ", ")
            ),
            "items": AnyCodable(itemSchema),
        ] as [String: AnyCodable]),
    ]
    let required = ["workspace_root", "language_id", "files"]
    return [
        "type": AnyCodable("object"),
        "properties": AnyCodable(props),
        "required": AnyCodable(required.map { AnyCodable($0) }),
    ]
}

/// Decode the `options` argument shared by the three formatting tools into
/// a typed `FormattingOptions`. Throws `MCPLSPBridgeError.missingArgument`
/// when absent and surfaces decode errors as
/// `MCPLSPBridgeError.invalidArgument`.
private func extractFormattingOptions(
    arguments: [String: AnyCodable]
) throws -> FormattingOptions {
    guard let optionsAny = arguments["options"] else {
        throw MCPLSPBridgeError.missingArgument("options")
    }
    return try MCPLSPBridge.decodeFromAnyCodable(
        optionsAny,
        as: FormattingOptions.self,
        argumentName: "options"
    )
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)

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
            // trigger_kind == 2 (TriggerCharacter) makes no semantic sense
            // without an accompanying trigger_character — silently
            // forwarding `triggerCharacter: nil` masks the caller bug
            // behind a generic "no completions" response from the server.
            if kind == .triggerCharacter, triggerChar == nil {
                throw MCPLSPBridgeError.missingArgument("trigger_character")
            }
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
    static let inputSchema: [String: AnyCodable] = rangeRequestSchema(
        extraProperties: [
            "diagnostics": AnyCodable([
                "type": AnyCodable("array"),
                "description": AnyCodable(
                    "Diagnostics overlapping the range. Forwarded into context.diagnostics so quickfix providers see the same set of problems the client surfaces."
                ),
                "items": AnyCodable([
                    "type": AnyCodable("object"),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "only": AnyCodable([
                "type": AnyCodable("array"),
                "description": AnyCodable(
                    "Filter for action kinds the caller is interested in (e.g. ['quickfix','refactor.extract']). Forwarded into context.only."
                ),
                "items": AnyCodable([
                    "type": AnyCodable("string"),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "trigger_kind": prop(
                "integer",
                "CodeActionTriggerKind: 1=Invoked, 2=Automatic. Forwarded into context.triggerKind."
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)

        // Decode the optional context fields. `diagnostics` round-trips
        // verbatim through the LSP Diagnostic shape so a quickfix consumer
        // sees the exact set of problems the caller fed in; `only` and
        // `trigger_kind` mirror the LSP spec one-for-one.
        let diagnostics: [Diagnostic]
        if let diagnosticsAny = arguments["diagnostics"] {
            diagnostics = try MCPLSPBridge.decodeFromAnyCodable(
                diagnosticsAny,
                as: [Diagnostic].self,
                argumentName: "diagnostics"
            )
        } else {
            diagnostics = []
        }
        let only: [CodeActionKind]?
        if let onlyAny = arguments["only"] {
            only = try MCPLSPBridge.decodeFromAnyCodable(
                onlyAny,
                as: [CodeActionKind].self,
                argumentName: "only"
            )
        } else {
            only = nil
        }
        let triggerKind: CodeActionTriggerKind?
        if let kindRaw = try MCPLSPBridge.optionalInt(arguments: arguments, key: "trigger_kind") {
            guard let kind = CodeActionTriggerKind(rawValue: kindRaw) else {
                throw MCPLSPBridgeError.invalidArgument(
                    name: "trigger_kind",
                    reason: "must be 1 (Invoked) or 2 (Automatic)"
                )
            }
            triggerKind = kind
        } else {
            triggerKind = nil
        }

        let context = CodeActionContext(
            diagnostics: diagnostics,
            only: only,
            triggerKind: triggerKind
        )
        let params = CodeActionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range,
            context: context
        )
        do {
            // Use `CodeActionItemList` (not `[CodeActionItem]`) so that any
            // `null` entries streamed alongside a `partialResultToken` chunk
            // are filtered out rather than crashing the array decode.
            let result: CodeActionItemList? = try await session.sendRequest(
                method: "textDocument/codeAction",
                params: params,
                resultType: CodeActionItemList?.self
            )
            return try MCPLSPBridge.makeJSONContent(result?.items)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        // The MCP tool layer has no UI to surface a prompt to the user, so
        // when `LSPSettings` resolves to `.prompt(...)` the handler we hand
        // it refuses the step (defensive default). A future UI bridge can
        // route the prompt through the app and substitute a real handler.
        let mode = LSPSettings.confirmationMode { @Sendable _ in false }
        let status = await installer.install(
            languageId: languageId,
            approvePrerequisites: approve,
            confirmationMode: mode
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
    static let description = "Pre-start an LSP session for a workspace + languageId pair. Optionally pre-opens an initial set of files so subsequent position/range/file tools can dispatch immediately."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "files": AnyCodable([
                "type": AnyCodable("array"),
                "description": AnyCodable(
                    "Optional list of files (absolute paths or file:// URIs) to pre-open via textDocument/didOpen as soon as the session is running. Missing files are silently skipped."
                ),
                "items": AnyCodable([
                    "type": AnyCodable("string"),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
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

        // Optional `files` payload: an array of strings (paths or file://
        // URIs). Pre-opens each file via `ensureFileOpen`, which already
        // handles dedup, missing-on-disk, and non-file URIs gracefully.
        // Malformed payloads (`files` present but not an array of
        // strings) are surfaced as `invalidArgument` so callers can fix
        // the call rather than silently lose warmup work.
        if let filesAny = arguments["files"] {
            let paths: [String] = try MCPLSPBridge.decodeFromAnyCodable(
                filesAny,
                as: [String].self,
                argumentName: "files"
            )
            for path in paths {
                let uri = MCPLSPBridge.documentUri(fromPathOrUri: path)
                try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
            }
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
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

// MARK: - CompletionResolveTool

enum CompletionResolveTool: MCPLSPTool {
    static let name = "lsp_completion_resolve"
    static let description = "Resolve additional details (documentation, detail, additionalTextEdits) for a CompletionItem returned by lsp_completion (completionItem/resolve)."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemKey: "completion_item",
        itemDescription: "CompletionItem returned by lsp_completion. Forwarded verbatim to completionItem/resolve."
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
        guard let itemAny = arguments["completion_item"] else {
            throw MCPLSPBridgeError.missingArgument("completion_item")
        }
        let item = try MCPLSPBridge.decodeFromAnyCodable(
            itemAny,
            as: CompletionItem.self,
            argumentName: "completion_item"
        )
        do {
            let result: CompletionItem = try await session.sendRequest(
                method: "completionItem/resolve",
                params: item,
                resultType: CompletionItem.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CodeActionResolveTool

enum CodeActionResolveTool: MCPLSPTool {
    static let name = "lsp_code_action_resolve"
    static let description = "Resolve the edit / command of a CodeAction returned by lsp_code_action (codeAction/resolve)."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemKey: "code_action",
        itemDescription: "CodeAction returned by lsp_code_action. Forwarded verbatim to codeAction/resolve."
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
        guard let actionAny = arguments["code_action"] else {
            throw MCPLSPBridgeError.missingArgument("code_action")
        }
        let action = try MCPLSPBridge.decodeFromAnyCodable(
            actionAny,
            as: CodeAction.self,
            argumentName: "code_action"
        )
        do {
            let result: CodeAction = try await session.sendRequest(
                method: "codeAction/resolve",
                params: action,
                resultType: CodeAction.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - FormattingTool

enum FormattingTool: MCPLSPTool {
    static let name = "lsp_formatting"
    static let description = "Format a whole document (textDocument/formatting)."
    static let inputSchema: [String: AnyCodable] = formattingSchema(
        includeRange: false,
        includePositionAndCh: false
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
        let uri = try bridge.extractDocumentUri(arguments: arguments)
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
        let options = try extractFormattingOptions(arguments: arguments)
        let params = DocumentFormattingParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            options: options
        )
        do {
            let result: [TextEdit]? = try await session.sendRequest(
                method: "textDocument/formatting",
                params: params,
                resultType: [TextEdit]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - RangeFormattingTool

enum RangeFormattingTool: MCPLSPTool {
    static let name = "lsp_range_formatting"
    static let description = "Format a range in a document (textDocument/rangeFormatting)."
    static let inputSchema: [String: AnyCodable] = formattingSchema(
        includeRange: true,
        includePositionAndCh: false
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
        let options = try extractFormattingOptions(arguments: arguments)
        let params = DocumentRangeFormattingParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            range: range,
            options: options
        )
        do {
            let result: [TextEdit]? = try await session.sendRequest(
                method: "textDocument/rangeFormatting",
                params: params,
                resultType: [TextEdit]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - OnTypeFormattingTool

enum OnTypeFormattingTool: MCPLSPTool {
    static let name = "lsp_on_type_formatting"
    static let description = "Format around the character typed at a position (textDocument/onTypeFormatting)."
    static let inputSchema: [String: AnyCodable] = formattingSchema(
        includeRange: false,
        includePositionAndCh: true
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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
        let ch = try MCPLSPBridge.requireString(arguments: arguments, key: "ch")
        let options = try extractFormattingOptions(arguments: arguments)
        let params = DocumentOnTypeFormattingParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position,
            ch: ch,
            options: options
        )
        do {
            let result: [TextEdit]? = try await session.sendRequest(
                method: "textDocument/onTypeFormatting",
                params: params,
                resultType: [TextEdit]?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - WorkspaceSymbolResolveTool

enum WorkspaceSymbolResolveTool: MCPLSPTool {
    static let name = "lsp_workspace_symbol_resolve"
    static let description = "Resolve the full location of a WorkspaceSymbol returned by lsp_workspace_symbol (workspaceSymbol/resolve)."
    static let inputSchema: [String: AnyCodable] = itemBasedSchema(
        itemKey: "workspace_symbol",
        itemDescription: "WorkspaceSymbol returned by lsp_workspace_symbol. Forwarded verbatim to workspaceSymbol/resolve."
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
        guard let symbolAny = arguments["workspace_symbol"] else {
            throw MCPLSPBridgeError.missingArgument("workspace_symbol")
        }
        let symbol = try MCPLSPBridge.decodeFromAnyCodable(
            symbolAny,
            as: WorkspaceSymbol.self,
            argumentName: "workspace_symbol"
        )
        do {
            let result: WorkspaceSymbol = try await session.sendRequest(
                method: "workspaceSymbol/resolve",
                params: symbol,
                resultType: WorkspaceSymbol.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - WorkspaceDiagnosticPullTool

enum WorkspaceDiagnosticPullTool: MCPLSPTool {
    static let name = "lsp_workspace_diagnostic_pull"
    static let description = "Pull workspace-wide diagnostics (workspace/diagnostic)."
    static let inputSchema: [String: AnyCodable] = {
        let previousResultIdItemSchema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "uri": prop("string", "Document URI the prior result id belongs to"),
                "value": prop("string", "Previous resultId from the server"),
            ] as [String: AnyCodable]),
            "required": AnyCodable([AnyCodable("uri"), AnyCodable("value")]),
        ]
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "identifier": prop(
                "string",
                "Optional server-side identifier from registration"
            ),
            "previous_result_ids": AnyCodable([
                "type": AnyCodable("array"),
                "description": AnyCodable(
                    "Previously-known {uri, value} result ids. Optional; defaults to an empty list."
                ),
                "items": AnyCodable(previousResultIdItemSchema),
            ] as [String: AnyCodable]),
        ]
        let required = ["workspace_root", "language_id"]
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
        let identifier = try MCPLSPBridge.optionalString(
            arguments: arguments,
            key: "identifier"
        )
        let previousResultIds: [PreviousResultId]
        if let rawAny = arguments["previous_result_ids"] {
            previousResultIds = try MCPLSPBridge.decodeFromAnyCodable(
                rawAny,
                as: [PreviousResultId].self,
                argumentName: "previous_result_ids"
            )
        } else {
            previousResultIds = []
        }
        let params = WorkspaceDiagnosticParams(
            identifier: identifier,
            previousResultIds: previousResultIds
        )
        do {
            let result: WorkspaceDiagnosticReport? = try await session.sendRequest(
                method: "workspace/diagnostic",
                params: params,
                resultType: WorkspaceDiagnosticReport?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - WorkspaceExecuteCommandTool

enum WorkspaceExecuteCommandTool: MCPLSPTool {
    static let name = "lsp_workspace_execute_command"
    static let description = "Execute a server-side command (workspace/executeCommand)."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "command": prop("string", "Identifier of the command handler on the server"),
            "arguments": AnyCodable([
                "type": AnyCodable("array"),
                "description": AnyCodable(
                    "Optional arguments forwarded verbatim to the server-side command handler."
                ),
            ] as [String: AnyCodable]),
        ]
        let required = ["workspace_root", "language_id", "command"]
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
        let command = try MCPLSPBridge.requireString(arguments: arguments, key: "command")
        let commandArguments: [AnyCodable]?
        if let rawAny = arguments["arguments"] {
            commandArguments = try MCPLSPBridge.decodeFromAnyCodable(
                rawAny,
                as: [AnyCodable].self,
                argumentName: "arguments"
            )
        } else {
            commandArguments = nil
        }
        let params = ExecuteCommandParams(
            command: command,
            arguments: commandArguments
        )
        do {
            let result: AnyCodable? = try await session.sendRequest(
                method: "workspace/executeCommand",
                params: params,
                resultType: AnyCodable?.self
            )
            return try MCPLSPBridge.makeJSONContent(result)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - WorkspaceApplyEditTool

enum WorkspaceApplyEditTool: MCPLSPTool {
    static let name = "lsp_workspace_apply_edit"
    static let description = "Apply a WorkspaceEdit locally. Bridge-internal — no LSP request is sent. With commit:false, returns a dry-run failure; with commit:true, the minimal stub reports applied:true (the FS write is owned by a follow-up batch)."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "edit": AnyCodable([
                "type": AnyCodable("object"),
                "description": AnyCodable(
                    "WorkspaceEdit to apply (LSP WorkspaceEdit shape: changes / documentChanges / changeAnnotations)."
                ),
            ] as [String: AnyCodable]),
            "commit": prop(
                "boolean",
                "If true, commit the edit. If false, perform a dry-run that reports applied:false / failureReason:'dry-run'."
            ),
            "label": prop(
                "string",
                "Optional human-readable label for the edit (used by clients for undo UI)."
            ),
        ]
        let required = ["workspace_root", "language_id", "edit", "commit"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        // Intentionally NOT resolving an LSPSession: this tool is
        // bridge-internal and must never reach the language server.
        guard let editAny = arguments["edit"] else {
            throw MCPLSPBridgeError.missingArgument("edit")
        }
        // Validate by decoding. The decoded value is discarded for now —
        // the follow-up batch wires it into the workspace mutation surface.
        let _: WorkspaceEdit = try MCPLSPBridge.decodeFromAnyCodable(
            editAny,
            as: WorkspaceEdit.self,
            argumentName: "edit"
        )
        let commit = try MCPLSPBridge.requireBool(
            arguments: arguments,
            key: "commit"
        )
        let result: ApplyWorkspaceEditResult
        if commit {
            result = ApplyWorkspaceEditResult(applied: true)
        } else {
            result = ApplyWorkspaceEditResult(applied: false, failureReason: "dry-run")
        }
        return try MCPLSPBridge.makeJSONContent(result)
    }
}

// MARK: - WorkspaceConfigurationGetTool

enum WorkspaceConfigurationGetTool: MCPLSPTool {
    static let name = "lsp_workspace_configuration_get"
    static let description = "Read a bridge-side workspace configuration value previously written with lsp_workspace_configuration_set. No LSP request is sent."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "section": prop("string", "Configuration section identifier (e.g. 'editor.tabSize')"),
        ]
        let required = ["workspace_root", "language_id", "section"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let workspaceRoot = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "workspace_root"
        )
        let languageId = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "language_id"
        )
        let section = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "section"
        )
        let key = MCPLSPBridge.workspaceConfigurationKey(
            workspaceRoot: workspaceRoot,
            languageId: languageId,
            section: section
        )
        if let value = bridge.workspaceConfiguration(key: key) {
            return try MCPLSPBridge.makeJSONContent(value)
        }
        // Unknown section: return the bare JSON null literal. The
        // contract permits `null` / `{}` / `{"value":null}`; we ship the
        // narrowest form because it makes "section unset" unambiguous on
        // the wire.
        return MCPContent(type: "text", text: "null")
    }
}

// MARK: - WorkspaceConfigurationSetTool

enum WorkspaceConfigurationSetTool: MCPLSPTool {
    static let name = "lsp_workspace_configuration_set"
    static let description = "Write a bridge-side workspace configuration value visible to lsp_workspace_configuration_get. No LSP request is sent."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "section": prop("string", "Configuration section identifier (e.g. 'editor.tabSize')"),
            "value": AnyCodable([
                "description": AnyCodable(
                    "Value to store. Any JSON-shaped value is accepted and round-tripped verbatim."
                ),
            ] as [String: AnyCodable]),
        ]
        let required = ["workspace_root", "language_id", "section", "value"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let workspaceRoot = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "workspace_root"
        )
        let languageId = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "language_id"
        )
        let section = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "section"
        )
        guard let value = arguments["value"] else {
            throw MCPLSPBridgeError.missingArgument("value")
        }
        let key = MCPLSPBridge.workspaceConfigurationKey(
            workspaceRoot: workspaceRoot,
            languageId: languageId,
            section: section
        )
        bridge.setWorkspaceConfiguration(key: key, value: value)
        return MCPContent(type: "text", text: #"{"success":true}"#)
    }
}

// MARK: - File operations cluster

/// Shared body for the three `workspace/will{Create,Rename,Delete}Files`
/// request tools. Decodes the `files` argument into the typed `Params`
/// (CreateFilesParams / RenameFilesParams / DeleteFilesParams), dispatches
/// the request, and JSON-encodes the resulting `WorkspaceEdit?`.
private func handleWillFilesRequest<Params: Encodable & Sendable>(
    method: String,
    paramsBuilder: @Sendable ([FileDescriptor]) throws -> Params,
    arguments: [String: AnyCodable],
    bridge: MCPLSPBridge
) async throws -> MCPContent {
    let session: LSPSession
    do {
        session = try await bridge.resolveSession(arguments: arguments)
    } catch let err as MCPLSPBridgeError {
        throw err
    } catch {
        return MCPLSPBridge.makeErrorContent(error)
    }
    guard let filesAny = arguments["files"] else {
        throw MCPLSPBridgeError.missingArgument("files")
    }
    let files = try MCPLSPBridge.decodeFromAnyCodable(
        filesAny,
        as: [FileDescriptor].self,
        argumentName: "files"
    )
    let params = try paramsBuilder(files)
    do {
        let result: WorkspaceEdit? = try await session.sendRequest(
            method: method,
            params: params,
            resultType: WorkspaceEdit?.self
        )
        return try MCPLSPBridge.makeJSONContent(result)
    } catch {
        return MCPLSPBridge.makeErrorContent(error)
    }
}

/// Permissive decoder for one `files[i]` entry. Carries both the
/// create/delete `uri` key and the rename `oldUri` / `newUri` pair so a
/// single Codable type can handle all three file-operations clusters.
/// Missing keys decode to `nil`; the per-tool builder closure throws if
/// a required key is absent for that cluster.
private struct FileDescriptor: Sendable, Codable, Equatable {
    let uri: String?
    let oldUri: String?
    let newUri: String?
}

private func toFileCreates(_ files: [FileDescriptor]) throws -> [FileCreate] {
    try files.map { entry in
        guard let uri = entry.uri else {
            throw MCPLSPBridgeError.invalidArgument(
                name: "files",
                reason: "every entry must carry a 'uri' string"
            )
        }
        return FileCreate(uri: uri)
    }
}

private func toFileDeletes(_ files: [FileDescriptor]) throws -> [FileDelete] {
    try files.map { entry in
        guard let uri = entry.uri else {
            throw MCPLSPBridgeError.invalidArgument(
                name: "files",
                reason: "every entry must carry a 'uri' string"
            )
        }
        return FileDelete(uri: uri)
    }
}

private func toFileRenames(_ files: [FileDescriptor]) throws -> [FileRename] {
    try files.map { entry in
        guard let oldUri = entry.oldUri, let newUri = entry.newUri else {
            throw MCPLSPBridgeError.invalidArgument(
                name: "files",
                reason: "every entry must carry an 'oldUri' and 'newUri' pair"
            )
        }
        return FileRename(oldUri: oldUri, newUri: newUri)
    }
}

/// Shared body for the three `workspace/did{Create,Rename,Delete}Files`
/// notification tools. Resolves the session, decodes the `files` array,
/// ships an LSP notification (no response), and surfaces a tiny success
/// payload for the MCP caller.
private func handleDidFilesNotification<Params: Encodable & Sendable>(
    method: String,
    paramsBuilder: @Sendable ([FileDescriptor]) throws -> Params,
    arguments: [String: AnyCodable],
    bridge: MCPLSPBridge
) async throws -> MCPContent {
    let session: LSPSession
    do {
        session = try await bridge.resolveSession(arguments: arguments)
    } catch let err as MCPLSPBridgeError {
        throw err
    } catch {
        return MCPLSPBridge.makeErrorContent(error)
    }
    guard let filesAny = arguments["files"] else {
        throw MCPLSPBridgeError.missingArgument("files")
    }
    let files = try MCPLSPBridge.decodeFromAnyCodable(
        filesAny,
        as: [FileDescriptor].self,
        argumentName: "files"
    )
    let params = try paramsBuilder(files)
    do {
        try await session.sendGenericNotification(method: method, params: params)
    } catch {
        return MCPLSPBridge.makeErrorContent(error)
    }
    return MCPContent(type: "text", text: #"{"sent":true}"#)
}

// MARK: - WillCreateFilesTool

enum WillCreateFilesTool: MCPLSPTool {
    static let name = "lsp_will_create_files"
    static let description = "Notify the server of an impending file/folder creation (workspace/willCreateFiles). Returns an optional WorkspaceEdit the server wants applied before the create happens."
    static let inputSchema: [String: AnyCodable] = filesArraySchema(itemKeys: ["uri"])

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleWillFilesRequest(
            method: "workspace/willCreateFiles",
            paramsBuilder: { files in
                CreateFilesParams(files: try toFileCreates(files))
            },
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - DidCreateFilesTool

enum DidCreateFilesTool: MCPLSPTool {
    static let name = "lsp_did_create_files"
    static let description = "Notify the server that files/folders have been created (workspace/didCreateFiles). Sent as an LSP notification — no response."
    static let inputSchema: [String: AnyCodable] = filesArraySchema(itemKeys: ["uri"])

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleDidFilesNotification(
            method: "workspace/didCreateFiles",
            paramsBuilder: { files in
                CreateFilesParams(files: try toFileCreates(files))
            },
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - WillRenameFilesTool

enum WillRenameFilesTool: MCPLSPTool {
    static let name = "lsp_will_rename_files"
    static let description = "Notify the server of an impending file/folder rename (workspace/willRenameFiles). Returns an optional WorkspaceEdit the server wants applied before the rename happens."
    static let inputSchema: [String: AnyCodable] = filesArraySchema(itemKeys: ["oldUri", "newUri"])

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleWillFilesRequest(
            method: "workspace/willRenameFiles",
            paramsBuilder: { files in
                RenameFilesParams(files: try toFileRenames(files))
            },
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - DidRenameFilesTool

enum DidRenameFilesTool: MCPLSPTool {
    static let name = "lsp_did_rename_files"
    static let description = "Notify the server that files/folders have been renamed (workspace/didRenameFiles). Sent as an LSP notification — no response."
    static let inputSchema: [String: AnyCodable] = filesArraySchema(itemKeys: ["oldUri", "newUri"])

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleDidFilesNotification(
            method: "workspace/didRenameFiles",
            paramsBuilder: { files in
                RenameFilesParams(files: try toFileRenames(files))
            },
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - WillDeleteFilesTool

enum WillDeleteFilesTool: MCPLSPTool {
    static let name = "lsp_will_delete_files"
    static let description = "Notify the server of an impending file/folder deletion (workspace/willDeleteFiles). Returns an optional WorkspaceEdit the server wants applied before the delete happens."
    static let inputSchema: [String: AnyCodable] = filesArraySchema(itemKeys: ["uri"])

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleWillFilesRequest(
            method: "workspace/willDeleteFiles",
            paramsBuilder: { files in
                DeleteFilesParams(files: try toFileDeletes(files))
            },
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - DidDeleteFilesTool

enum DidDeleteFilesTool: MCPLSPTool {
    static let name = "lsp_did_delete_files"
    static let description = "Notify the server that files/folders have been deleted (workspace/didDeleteFiles). Sent as an LSP notification — no response."
    static let inputSchema: [String: AnyCodable] = filesArraySchema(itemKeys: ["uri"])

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleDidFilesNotification(
            method: "workspace/didDeleteFiles",
            paramsBuilder: { files in
                DeleteFilesParams(files: try toFileDeletes(files))
            },
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - BatchTool

enum BatchTool: MCPLSPTool {
    static let name = "lsp_batch"
    static let description = "Dispatch multiple MCP-LSP tools in a single MCP round-trip. Each entry specifies the inner tool name and its argument object; results are returned as an ordered array of {tool, result|error} entries."
    static let inputSchema: [String: AnyCodable] = {
        let requestItemSchema: [String: AnyCodable] = [
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "tool": prop("string", "Name of the bridge tool to dispatch (e.g. 'lsp_hover')"),
                "params": AnyCodable([
                    "type": AnyCodable("object"),
                    "description": AnyCodable(
                        "Argument payload forwarded verbatim to the inner tool"
                    ),
                ] as [String: AnyCodable]),
            ] as [String: AnyCodable]),
            "required": AnyCodable([AnyCodable("tool"), AnyCodable("params")]),
        ]
        let props: [String: AnyCodable] = [
            "requests": AnyCodable([
                "type": AnyCodable("array"),
                "description": AnyCodable(
                    "Ordered list of inner tool invocations to dispatch. Nested 'lsp_batch' entries are rejected per-entry. Capped at 64 entries per batch."
                ),
                "maxItems": AnyCodable(64),
                "items": AnyCodable(requestItemSchema),
            ] as [String: AnyCodable]),
        ]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable([AnyCodable("requests")]),
        ]
    }()

    /// JSON-decodable shape for one batch entry.
    private struct BatchRequest: Sendable, Codable {
        let tool: String
        let params: [String: AnyCodable]
    }

    /// One entry in the encoded response array. Either `result` (the inner
    /// tool's text payload, parsed back to its raw JSON shape so the
    /// outer JSON stays structured) or `error` is populated.
    private struct BatchResponseEntry: Encodable {
        let tool: String
        let result: AnyCodable?
        let error: String?

        init(tool: String, result: AnyCodable) {
            self.tool = tool
            self.result = result
            self.error = nil
        }

        init(tool: String, error: String) {
            self.tool = tool
            self.result = nil
            self.error = error
        }

        enum CodingKeys: String, CodingKey {
            case tool, result, error
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tool, forKey: .tool)
            if let result {
                try container.encode(result, forKey: .result)
            }
            if let error {
                try container.encode(error, forKey: .error)
            }
        }
    }

    /// Maximum number of inner requests one `lsp_batch` invocation may carry.
    /// Bounded so a single MCP round-trip cannot pin the bridge actor with an
    /// unbounded fan-out; combined with the nested-batch reject below this
    /// also caps total dispatches at a constant `O(maxRequestsPerBatch)`.
    static let maxRequestsPerBatch: Int = 64

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        guard let requestsAny = arguments["requests"] else {
            throw MCPLSPBridgeError.missingArgument("requests")
        }
        let requests = try MCPLSPBridge.decodeFromAnyCodable(
            requestsAny,
            as: [BatchRequest].self,
            argumentName: "requests"
        )
        guard requests.count <= maxRequestsPerBatch else {
            throw MCPLSPBridgeError.invalidArgument(
                name: "requests",
                reason: "max \(maxRequestsPerBatch) requests per batch (got \(requests.count))"
            )
        }
        var entries: [BatchResponseEntry] = []
        entries.reserveCapacity(requests.count)
        for request in requests {
            // Reject nested `lsp_batch` entries: allowing them turns a single
            // outer dispatch into an exponential fan-out (e.g. 100x100x100 =>
            // 1M inner dispatches), pins the @MainActor-isolated bridge, and
            // is a trivial DoS vector. Surface the rejection as a per-entry
            // error so peer entries still execute normally.
            if request.tool == BatchTool.name {
                entries.append(
                    BatchResponseEntry(
                        tool: request.tool,
                        error: "nested lsp_batch is not allowed"
                    )
                )
                continue
            }
            do {
                let inner = try await bridge.handleToolCall(
                    name: request.tool,
                    arguments: request.params
                )
                let parsed = parseInnerText(inner.text)
                entries.append(BatchResponseEntry(tool: request.tool, result: parsed))
            } catch {
                entries.append(
                    BatchResponseEntry(tool: request.tool, error: "\(error)")
                )
            }
        }
        return try MCPLSPBridge.makeJSONContent(entries)
    }

    /// Parse one inner tool's text payload back into structured JSON so it
    /// nests as a real array/object inside the outer batch response, not
    /// as an escaped string. Falls back to the raw text when the payload
    /// is not valid JSON (e.g. an `"LSP error: ..."` envelope).
    private static func parseInnerText(_ text: String) -> AnyCodable {
        guard let data = text.data(using: .utf8) else {
            return AnyCodable(text)
        }
        if let parsed = try? JSONDecoder().decode(AnyCodable.self, from: data) {
            return parsed
        }
        return AnyCodable(text)
    }
}

// MARK: - HoverBundleTool

enum HoverBundleTool: MCPLSPTool {
    static let name = "lsp_hover_bundle"
    static let description = "AI-friendly bundle of hover + definition + surrounding source for a position. Fans out textDocument/hover and textDocument/definition in parallel and surfaces them, along with a ±context_lines source snippet around the cursor, and (when discoverable) resolves up to 5 dependent type identifiers via workspace/symbol + follow-up hover lookups."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema(
        extraProperties: [
            "context_lines": prop(
                "integer",
                "Lines of source context to include around (line, column) in surrounding_code. Default 10, min 0, max 100."
            ),
        ]
    )

    /// One entry in the `dependent_types` array. Each entry pairs a
    /// non-primitive type identifier discovered in the cursor hover with
    /// the first matching `workspace/symbol` `Location` and a follow-up
    /// `textDocument/hover` payload (when available).
    struct DependentType: Encodable {
        let name: String
        let location: Location
        let hover: Hover?
    }

    /// JSON envelope returned by the bundle. `surrounding_code` is the
    /// formatted source snippet (line-numbered) covering ±context_lines
    /// around `(line, column)`; an empty string when the source file
    /// can't be read off disk. `dependent_types` is always present (may
    /// be empty); `doc_comment` is nil when the hover content does not
    /// have a fenced code block followed by descriptive prose.
    private struct Bundle: Encodable {
        let hover: Hover?
        let definition: DefinitionResult?
        let surroundingCode: String
        let dependentTypes: [DependentType]
        let docComment: String?

        enum CodingKeys: String, CodingKey {
            case hover
            case definition
            case surroundingCode = "surrounding_code"
            case dependentTypes = "dependent_types"
            case docComment = "doc_comment"
        }
    }

    /// Maximum number of dependent-type entries the bundle will surface.
    /// Caps the response payload so an AI consumer can't be spammed by a
    /// signature that references dozens of types.
    private static let dependentTypeCap = 5

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
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)

        // Read context_lines (default 10, clamped to [0, 100] so a
        // misbehaving caller can't ask for a snippet bigger than the
        // file). A `context_lines` value of the wrong shape surfaces as
        // `invalidArgument` to the caller — matching the rest of the
        // bridge rather than silently defaulting.
        let rawContext = try MCPLSPBridge.optionalInt(arguments: arguments, key: "context_lines") ?? 10
        let contextLines = min(max(rawContext, 0), 100)

        let hoverParams = HoverParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        let defParams = DefinitionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        async let hoverTask: Hover? = {
            do {
                return try await session.sendRequest(
                    method: "textDocument/hover",
                    params: hoverParams,
                    resultType: Hover?.self
                )
            } catch {
                return nil
            }
        }()
        async let definitionTask: DefinitionResult? = {
            do {
                return try await session.sendRequest(
                    method: "textDocument/definition",
                    params: defParams,
                    resultType: DefinitionResult?.self
                )
            } catch {
                return nil
            }
        }()
        let hover = await hoverTask
        let definition = await definitionTask

        let surroundingCode = renderSurroundingCode(
            uri: uri,
            centerLine: position.line,
            contextLines: contextLines
        )

        // Mine dependent-type identifiers from the cursor hover content
        // and fan out workspace/symbol + textDocument/hover lookups to
        // populate `dependent_types`. When the cursor hover is absent
        // there is nothing to mine, so the fan-out is skipped.
        let dependentTypes: [DependentType]
        let docComment: String?
        if let hover {
            let hoverText = extractHoverText(hover)
            let identifiers = extractDependentIdentifiers(hoverText)
            dependentTypes = await resolveDependentTypes(
                session: session,
                identifiers: identifiers
            )
            docComment = extractDocComment(hover)
        } else {
            dependentTypes = []
            docComment = nil
        }

        let bundle = Bundle(
            hover: hover,
            definition: definition,
            surroundingCode: surroundingCode,
            dependentTypes: dependentTypes,
            docComment: docComment
        )
        return try MCPLSPBridge.makeJSONContent(bundle)
    }

    /// Flatten a `Hover.contents` payload into a single plain-text
    /// string. All three `HoverContents` variants are handled so the
    /// identifier-mining regex sees the same surface regardless of
    /// which shape the server emitted. Code-block bodies (the typical
    /// rust-analyzer signature form) are included verbatim because they
    /// carry the bulk of the meaningful type identifiers.
    private static func extractHoverText(_ hover: Hover) -> String {
        switch hover.contents {
        case .markupContent(let mc):
            return mc.value
        case .markedString(let ms):
            return flatten(markedString: ms)
        case .markedStrings(let arr):
            return arr.map { flatten(markedString: $0) }.joined(separator: "\n")
        }
    }

    private static func flatten(markedString: MarkedString) -> String {
        switch markedString {
        case .string(let s):
            return s
        case .codeBlock(_, let value):
            return value
        }
    }

    /// Scan `text` for unique capitalized identifiers and return them in
    /// first-occurrence order, after dedup, capped at `dependentTypeCap`.
    ///
    /// The regex `\b[A-Z][A-Za-z0-9_]*\b` only matches identifiers that
    /// start with an uppercase letter, so lowercase primitives (`u32`,
    /// `bool`, `str`, …) are naturally skipped — Swift / Rust / Java
    /// conventions reserve leading-uppercase for the user-defined types
    /// we actually want to surface here.
    ///
    /// The regex deliberately scans through fenced code blocks as well as
    /// prose: signatures inside fenced code blocks are the PRIMARY source
    /// of dependent-type identifiers in markdown hovers
    /// (`pub fn foo() -> Vec<KeyValue>`), so excluding them would drop
    /// almost every useful match.
    private static func extractDependentIdentifiers(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // Cap the scanned region to bound regex work on pathologically
        // large hover payloads (some servers emit module-level docs that
        // run to hundreds of KiB). 32 KiB easily covers signatures and
        // their immediate doc-comment context; anything beyond is
        // overflow we can safely ignore for identifier mining.
        let scan = text.count > 32_768 ? String(text.prefix(32_768)) : text
        let pattern = #"\b[A-Z][A-Za-z0-9_]*\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let ns = scan as NSString
        let range = NSRange(location: 0, length: ns.length)
        var seen: Set<String> = []
        var ordered: [String] = []
        regex.enumerateMatches(in: scan, range: range) { match, _, stop in
            guard let match else { return }
            let id = ns.substring(with: match.range)
            if seen.contains(id) { return }
            seen.insert(id)
            ordered.append(id)
            if ordered.count >= dependentTypeCap {
                stop.pointee = true
            }
        }
        return ordered
    }

    /// Issue `workspace/symbol` for every identifier and, for the first
    /// matching `Location`, follow up with `textDocument/hover` to
    /// enrich the entry. Per-identifier failures (server error, no
    /// match, decode error) skip that entry only — the overall bundle
    /// always carries whatever could be resolved.
    ///
    /// Requests are issued sequentially, in the same order
    /// `extractDependentIdentifiers` produced, so the caller sees
    /// `dependent_types` in that order. A previous version of this
    /// helper used `withTaskGroup` to fan out, but because every
    /// underlying `session.sendRequest` already serialises through the
    /// `LSPSession` actor, the fan-out gained no real concurrency while
    /// making the per-identifier request order non-deterministic — which
    /// broke test drivers that match queued LSP replies to query
    /// identifiers by FIFO arrival order, and made debugging real-server
    /// traces unnecessarily harder.
    ///
    /// The cap is small (`dependentTypeCap`, currently 5), so the total
    /// sequential cost is bounded at 5 × (`workspace/symbol` +
    /// `textDocument/hover`) round-trips per `lsp_hover_bundle` call.
    private static func resolveDependentTypes(
        session: LSPSession,
        identifiers: [String]
    ) async -> [DependentType] {
        var resolved: [DependentType] = []
        resolved.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            if let entry = await resolveOneDependentType(
                identifier: identifier,
                session: session
            ) {
                resolved.append(entry)
            }
        }
        return resolved
    }

    /// Resolve a single dependent-type identifier: query
    /// `workspace/symbol`, filter for an exact-name hit, then enrich
    /// with `textDocument/hover` at the resolved location. Returns nil
    /// when any step yields no usable result.
    private static func resolveOneDependentType(
        identifier: String,
        session: LSPSession
    ) async -> DependentType? {
        let params = WorkspaceSymbolParams(query: identifier)
        let symbolResult: WorkspaceSymbolResult?
        do {
            symbolResult = try await session.sendRequest(
                method: "workspace/symbol",
                params: params,
                resultType: WorkspaceSymbolResult?.self
            )
        } catch {
            return nil
        }
        guard let firstLocation = firstFullLocation(
            in: symbolResult,
            matching: identifier
        ) else {
            return nil
        }
        // Best-effort `didOpen` on the resolved URI so the follow-up
        // hover has a chance to hit a parsed document. `ensureFileOpen`
        // can throw on an unparseable URI; the throw is swallowed via
        // `try?` because we still want to attempt the hover — the
        // server may serve it from a previously parsed source, and
        // failure to do so simply leaves the entry's `hover` as nil.
        try? await MCPLSPBridge.ensureFileOpen(session: session, uri: firstLocation.uri)
        let hoverParams = HoverParams(
            textDocument: TextDocumentIdentifier(uri: firstLocation.uri),
            position: firstLocation.range.start
        )
        let followUp: Hover?
        do {
            followUp = try await session.sendRequest(
                method: "textDocument/hover",
                params: hoverParams,
                resultType: Hover?.self
            )
        } catch {
            followUp = nil
        }
        return DependentType(
            name: identifier,
            location: firstLocation,
            hover: followUp
        )
    }

    /// Extract a usable `Location` from a `workspace/symbol` result,
    /// keeping only entries whose `name` exactly matches `identifier`.
    /// `workspace/symbol` is documented as a fuzzy / prefix search, so
    /// the first hit can be a sibling-name false positive (e.g. a query
    /// for `Vec` returning `VecDeque` first); the equality filter drops
    /// those before we commit to a location for the dependent type.
    ///
    /// Both result shapes are accepted:
    ///   - `[WorkspaceSymbol]`: requires the matching entry to carry a
    ///     full `Location` (the `{uri}`-only lazy form is skipped
    ///     because we cannot point an LSP `textDocument/hover` at a uri
    ///     without a range).
    ///   - `[SymbolInformation]`: always carries a full `Location`.
    private static func firstFullLocation(
        in result: WorkspaceSymbolResult?,
        matching identifier: String
    ) -> Location? {
        guard let result else { return nil }
        switch result {
        case .workspaceSymbols(let arr):
            for symbol in arr where symbol.name == identifier {
                if case .full(let loc) = symbol.location {
                    return loc
                }
            }
            return nil
        case .symbolInformations(let arr):
            for symbol in arr where symbol.name == identifier {
                return symbol.location
            }
            return nil
        }
    }

    /// Extract the descriptive prose from a hover payload, peeling off
    /// any fenced code blocks (the typical signature wrappers used by
    /// rust-analyzer and other servers). Returns nil when no usable
    /// prose remains. Handles every `HoverContents` shape:
    ///
    ///   - `.markupContent(.markdown)`: walk lines, concatenating
    ///     anything outside ``` fences. Multi-block hovers (signature →
    ///     prose → signature → prose) keep their inter-block prose
    ///     instead of being collapsed by a single `.backwards` search.
    ///     If there are no fences, the whole markdown is treated as
    ///     prose.
    ///   - `.markupContent(.plaintext)`: return the trimmed value if
    ///     non-empty.
    ///   - `.markedString(.string)`: return the trimmed value if
    ///     non-empty (prose-only marked strings carry useful doc text).
    ///   - `.markedString(.codeBlock)`: nil (pure code carries no
    ///     prose).
    ///   - `.markedStrings`: join the prose-only entries with a blank
    ///     line separator; nil when no prose entries are present.
    private static func extractDocComment(_ hover: Hover) -> String? {
        switch hover.contents {
        case .markupContent(let mc):
            switch mc.kind {
            case .markdown:
                return extractMarkdownProse(mc.value)
            case .plaintext:
                let trimmed = mc.value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        case .markedString(let ms):
            switch ms {
            case .string(let s):
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case .codeBlock:
                return nil
            }
        case .markedStrings(let arr):
            let proseEntries: [String] = arr.compactMap { entry in
                if case .string(let s) = entry { return s }
                return nil
            }
            guard !proseEntries.isEmpty else { return nil }
            let joined = proseEntries.joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
    }

    /// Walk a markdown payload line by line, collecting every line that
    /// is outside a ``` fence as prose. Multi-block hovers (signature →
    /// prose → signature → prose) are handled correctly because the
    /// state machine flips on every fence delimiter rather than seeking
    /// "the last fence". When the payload has no fences at all, the
    /// entire trimmed value is returned as prose.
    private static func extractMarkdownProse(_ text: String) -> String? {
        var insideFence = false
        var proseLines: [String] = []
        let lines = text.components(separatedBy: "\n")
        for line in lines {
            // Trim trailing \r so CRLF payloads behave the same as LF.
            let candidate = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let leading = candidate.trimmingCharacters(in: .whitespaces)
            if leading.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if !insideFence {
                proseLines.append(candidate)
            }
        }
        let joined = proseLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Slice the source file at `uri` and render a line-numbered snippet
    /// covering `[centerLine - contextLines, centerLine + contextLines]`.
    /// Returns "" when the URI doesn't point at a readable file on disk
    /// — the caller's bundle still surfaces hover + definition.
    private static func renderSurroundingCode(
        uri: DocumentUri,
        centerLine: Int,
        contextLines: Int
    ) -> String {
        let normalized = MCPLSPBridge.normalizeFileURI(uri)
        guard let url = normalized.fileURL, url.isFileURL else { return "" }
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        let raw: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            raw = utf8
        } else {
            var used = String.Encoding.utf8
            guard let sniffed = try? String(contentsOf: url, usedEncoding: &used) else {
                return ""
            }
            raw = sniffed
        }
        // Split on newline, dropping a final empty trailing entry from a
        // trailing "\n". `components(separatedBy:)` preserves empty
        // intermediates which the line-numbered format reproduces
        // faithfully.
        var lines = raw.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        // Normalise CRLF endings: strip a trailing \r from each line so
        // the rendered snippet doesn't carry stray carriage returns
        // through into the AI consumer's context.
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        guard !lines.isEmpty else { return "" }
        let lastIdx = lines.count - 1
        // Clamp `centerLine` into the valid index range BEFORE any
        // arithmetic. `centerLine` is supplied by an external
        // `Position` and is unconstrained — without the clamp a hostile
        // caller could ask for `Int.max` and trip a trap in the
        // `centerLine ± contextLines` arithmetic. The
        // addingReportingOverflow / subtractingReportingOverflow checks
        // then guard against the remaining edge where contextLines
        // (clamped to ≤ 100 in the handler, but a programmatic caller
        // could still pass something larger) overflows when added to a
        // very large clamped center.
        let clampedCenter = min(max(centerLine, 0), lastIdx)
        let (sumResult, sumOverflow) = clampedCenter.addingReportingOverflow(contextLines)
        let end = sumOverflow ? lastIdx : min(lastIdx, sumResult)
        let (diffResult, diffOverflow) = clampedCenter.subtractingReportingOverflow(contextLines)
        let start = diffOverflow ? 0 : max(0, diffResult)
        guard start <= end else { return "" }

        // Width of the line-number gutter so column alignment stays
        // stable across the snippet.
        let gutterWidth = String(end).count
        var out: [String] = []
        out.reserveCapacity(end - start + 1)
        for i in start...end {
            let lineNo = String(i)
            let pad = String(repeating: " ", count: max(0, gutterWidth - lineNo.count))
            out.append("\(pad)\(lineNo) | \(lines[i])")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - SymbolWalkTool

enum SymbolWalkTool: MCPLSPTool {
    static let name = "lsp_symbol_walk"
    static let description = "BFS a call or type hierarchy from a seed item. `kind` selects the walk direction: call_incoming (default) routes through callHierarchy/incomingCalls, call_outgoing through callHierarchy/outgoingCalls, type_supertypes / type_subtypes prepare via textDocument/prepareTypeHierarchy and then iterate typeHierarchy/{supertypes,subtypes}. Returns `{items: [{level, item, edge?}], depth_reached: Int}`."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'rust')"),
            "item": AnyCodable([
                "type": AnyCodable("object"),
                "description": AnyCodable(
                    "Seed item. For call_incoming / call_outgoing this is a CallHierarchyItem; for type_supertypes / type_subtypes a TypeHierarchyItem (structurally identical). Forwarded verbatim to the underlying LSP request."
                ),
            ] as [String: AnyCodable]),
            "kind": prop(
                "string",
                "Direction to walk. One of: call_incoming (default), call_outgoing, type_supertypes, type_subtypes."
            ),
            "depth": AnyCodable([
                "type": AnyCodable("integer"),
                "description": AnyCodable(
                    "BFS depth (number of hops to expand). Default 1, min 1, max 5 — a hard cap that guards against runaway server fan-out."
                ),
                "default": AnyCodable(1),
                "minimum": AnyCodable(1),
                "maximum": AnyCodable(5),
            ] as [String: AnyCodable]),
        ]
        let required = ["workspace_root", "language_id", "item"]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ]
    }()

    /// One BFS visit. `level` is the hop distance from the seed (0 for
    /// the seed itself); `item` is the visited node serialized as JSON;
    /// `edge` is the hop that introduced this entry (nil for the seed,
    /// and for type-hierarchy entries which have no edge metadata).
    /// Items + edges are stored as `AnyCodable` so a single result
    /// shape covers both the call-hierarchy and type-hierarchy walks.
    private struct WalkEntry: Encodable {
        let level: Int
        let item: AnyCodable
        let edge: AnyCodable?
    }

    private struct WalkResult: Encodable {
        let items: [WalkEntry]
        let depthReached: Int
        /// Surfaces the original error message when
        /// `textDocument/prepareTypeHierarchy` threw on a type-hierarchy
        /// walk. Always nil for call-hierarchy walks. Encoded only when
        /// non-nil so the response shape stays minimal for the common
        /// success path.
        let prepareError: String?

        enum CodingKeys: String, CodingKey {
            case items
            case depthReached = "depth_reached"
            case prepareError = "prepare_error"
        }

        init(
            items: [WalkEntry],
            depthReached: Int,
            prepareError: String? = nil
        ) {
            self.items = items
            self.depthReached = depthReached
            self.prepareError = prepareError
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(items, forKey: .items)
            try container.encode(depthReached, forKey: .depthReached)
            try container.encodeIfPresent(prepareError, forKey: .prepareError)
        }
    }

    /// Hard cap on the number of entries the walk emits. Same as the
    /// historical implementation — guards against runaway servers that
    /// return enormous fan-out from a single hop.
    private static let nodeCap = 100

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        // The `kind` parameter is the modern way to select the walk
        // direction. The historical `direction` parameter is kept as a
        // backwards-compatible alias for the only value it ever
        // accepted (`call_incoming`); any other `direction` value
        // continues to throw `invalidArgument` so existing callers
        // that relied on the strict-rejection behaviour stay green.
        //
        // Passing BOTH `kind` and `direction` is ambiguous and rejected
        // outright — silently preferring one would mask a caller bug.
        let kindArg = try MCPLSPBridge.optionalString(arguments: arguments, key: "kind")
        let directionArg = try MCPLSPBridge.optionalString(arguments: arguments, key: "direction")
        let walkKind: String
        if kindArg != nil, directionArg != nil {
            throw MCPLSPBridgeError.invalidArgument(
                name: "direction",
                reason: "cannot pass both 'kind' and 'direction'; use 'kind' only"
            )
        } else if let kind = kindArg {
            walkKind = kind
        } else if let direction = directionArg {
            guard direction == "call_incoming" else {
                throw MCPLSPBridgeError.invalidArgument(
                    name: "direction",
                    reason: "legacy 'direction' alias only supports 'call_incoming' (got '\(direction)'); use 'kind' for other walk directions"
                )
            }
            walkKind = direction
        } else {
            walkKind = "call_incoming"
        }

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
        let rawDepth = try MCPLSPBridge.optionalInt(arguments: arguments, key: "depth") ?? 1
        // Clamp to [1, 5] — values outside the range are accepted but
        // pinned so a runaway caller can't stampede the LSP server.
        let depth = min(max(rawDepth, 1), 5)

        let result: WalkResult
        switch walkKind {
        case "call_incoming":
            let seed = try MCPLSPBridge.decodeFromAnyCodable(
                itemAny,
                as: CallHierarchyItem.self,
                argumentName: "item"
            )
            result = await walkCallHierarchy(
                seeds: [seed],
                depth: depth,
                session: session,
                outgoing: false
            )
        case "call_outgoing":
            let seed = try MCPLSPBridge.decodeFromAnyCodable(
                itemAny,
                as: CallHierarchyItem.self,
                argumentName: "item"
            )
            result = await walkCallHierarchy(
                seeds: [seed],
                depth: depth,
                session: session,
                outgoing: true
            )
        case "type_supertypes":
            let seed = try MCPLSPBridge.decodeFromAnyCodable(
                itemAny,
                as: TypeHierarchyItem.self,
                argumentName: "item"
            )
            let prepared = await prepareTypeHierarchy(seed: seed, session: session)
            let walked = await walkTypeHierarchy(
                seeds: prepared.frontier,
                depth: depth,
                session: session,
                subtypes: false
            )
            result = WalkResult(
                items: walked.items,
                depthReached: walked.depthReached,
                prepareError: prepared.prepareError
            )
        case "type_subtypes":
            let seed = try MCPLSPBridge.decodeFromAnyCodable(
                itemAny,
                as: TypeHierarchyItem.self,
                argumentName: "item"
            )
            let prepared = await prepareTypeHierarchy(seed: seed, session: session)
            let walked = await walkTypeHierarchy(
                seeds: prepared.frontier,
                depth: depth,
                session: session,
                subtypes: true
            )
            result = WalkResult(
                items: walked.items,
                depthReached: walked.depthReached,
                prepareError: prepared.prepareError
            )
        default:
            throw MCPLSPBridgeError.invalidArgument(
                name: "kind",
                reason: "unknown walk kind '\(walkKind)' (expected one of: call_incoming, call_outgoing, type_supertypes, type_subtypes)"
            )
        }

        return try MCPLSPBridge.makeJSONContent(result)
    }

    /// Shared BFS over a call hierarchy. `outgoing == true` selects
    /// `callHierarchy/outgoingCalls` (reading `call.to`); otherwise
    /// `callHierarchy/incomingCalls` (reading `call.from`).
    private static func walkCallHierarchy(
        seeds: [CallHierarchyItem],
        depth: Int,
        session: LSPSession,
        outgoing: Bool
    ) async -> WalkResult {
        var frontier: [CallHierarchyItem] = seeds
        var visited: Set<String> = []
        var results: [WalkEntry] = []
        var depthReached = 0
        let method = outgoing ? "callHierarchy/outgoingCalls" : "callHierarchy/incomingCalls"

        bfs: for level in 0..<depth {
            var nextFrontier: [CallHierarchyItem] = []
            for item in frontier {
                if results.count >= nodeCap { break bfs }
                let key = walkKey(forCall: item)
                if visited.contains(key) { continue }
                visited.insert(key)
                results.append(WalkEntry(
                    level: level,
                    item: AnyCodable.from(item),
                    edge: nil
                ))

                if outgoing {
                    let params = CallHierarchyOutgoingCallsParams(item: item)
                    let calls: [CallHierarchyOutgoingCall]?
                    do {
                        calls = try await session.sendRequest(
                            method: method,
                            params: params,
                            resultType: [CallHierarchyOutgoingCall]?.self
                        )
                    } catch {
                        // A server-side failure on a single frontier
                        // node must not abort the whole walk; skip the
                        // failed edge and keep going.
                        continue
                    }
                    guard let calls else { continue }
                    for call in calls {
                        if results.count >= nodeCap { break bfs }
                        results.append(WalkEntry(
                            level: level + 1,
                            item: AnyCodable.from(call.to),
                            edge: AnyCodable.from(call)
                        ))
                        nextFrontier.append(call.to)
                    }
                } else {
                    let params = CallHierarchyIncomingCallsParams(item: item)
                    let calls: [CallHierarchyIncomingCall]?
                    do {
                        calls = try await session.sendRequest(
                            method: method,
                            params: params,
                            resultType: [CallHierarchyIncomingCall]?.self
                        )
                    } catch {
                        continue
                    }
                    guard let calls else { continue }
                    for call in calls {
                        if results.count >= nodeCap { break bfs }
                        results.append(WalkEntry(
                            level: level + 1,
                            item: AnyCodable.from(call.from),
                            edge: AnyCodable.from(call)
                        ))
                        nextFrontier.append(call.from)
                    }
                }
            }
            depthReached = level + 1
            frontier = nextFrontier
            if frontier.isEmpty { break bfs }
        }

        return WalkResult(items: results, depthReached: depthReached)
    }

    /// Issue `textDocument/prepareTypeHierarchy` at the seed item's
    /// selection-range start position. LSP requires a prepare step
    /// before any `typeHierarchy/{supertypes,subtypes}` request; the
    /// returned items become the BFS's initial frontier.
    ///
    /// Failure modes:
    ///   - Server error: log via `os_log`, propagate the message back
    ///     to the caller in `prepareError` so it surfaces in the JSON
    ///     envelope. The frontier is empty so the walk yields an empty
    ///     items list alongside the error.
    ///   - Empty / nil result: fall back to the seed itself as the
    ///     frontier. Some servers tolerate skipping the prepare step
    ///     entirely when the caller already has a fully formed
    ///     `TypeHierarchyItem` (uri + selectionRange + range), so this
    ///     gives the walk a chance to fan out instead of returning a
    ///     hollow result.
    private static func prepareTypeHierarchy(
        seed: TypeHierarchyItem,
        session: LSPSession
    ) async -> (frontier: [TypeHierarchyItem], prepareError: String?) {
        let params = TypeHierarchyPrepareParams(
            textDocument: TextDocumentIdentifier(uri: seed.uri),
            position: seed.selectionRange.start
        )
        do {
            let result: [TypeHierarchyItem]? = try await session.sendRequest(
                method: "textDocument/prepareTypeHierarchy",
                params: params,
                resultType: [TypeHierarchyItem]?.self
            )
            let items = result ?? []
            if items.isEmpty {
                return (frontier: [seed], prepareError: nil)
            }
            return (frontier: items, prepareError: nil)
        } catch {
            let message = String(describing: error)
            bridgeLogger.error(
                "prepareTypeHierarchy failed for \(seed.uri, privacy: .public): \(message, privacy: .public)"
            )
            return (frontier: [], prepareError: message)
        }
    }

    /// Shared BFS over a type hierarchy. `subtypes == true` walks
    /// `typeHierarchy/subtypes`; otherwise `typeHierarchy/supertypes`.
    private static func walkTypeHierarchy(
        seeds: [TypeHierarchyItem],
        depth: Int,
        session: LSPSession,
        subtypes: Bool
    ) async -> WalkResult {
        var frontier: [TypeHierarchyItem] = seeds
        var visited: Set<String> = []
        var results: [WalkEntry] = []
        var depthReached = 0
        let method = subtypes ? "typeHierarchy/subtypes" : "typeHierarchy/supertypes"

        bfs: for level in 0..<depth {
            var nextFrontier: [TypeHierarchyItem] = []
            for item in frontier {
                if results.count >= nodeCap { break bfs }
                let key = walkKey(forType: item)
                if visited.contains(key) { continue }
                visited.insert(key)
                results.append(WalkEntry(
                    level: level,
                    item: AnyCodable.from(item),
                    edge: nil
                ))

                let children: [TypeHierarchyItem]?
                do {
                    if subtypes {
                        let params = TypeHierarchySubtypesParams(item: item)
                        children = try await session.sendRequest(
                            method: method,
                            params: params,
                            resultType: [TypeHierarchyItem]?.self
                        )
                    } else {
                        let params = TypeHierarchySupertypesParams(item: item)
                        children = try await session.sendRequest(
                            method: method,
                            params: params,
                            resultType: [TypeHierarchyItem]?.self
                        )
                    }
                } catch {
                    continue
                }
                guard let children else { continue }
                for child in children {
                    if results.count >= nodeCap { break bfs }
                    results.append(WalkEntry(
                        level: level + 1,
                        item: AnyCodable.from(child),
                        edge: nil
                    ))
                    nextFrontier.append(child)
                }
            }
            depthReached = level + 1
            frontier = nextFrontier
            if frontier.isEmpty { break bfs }
        }

        return WalkResult(items: results, depthReached: depthReached)
    }

    /// Stable identity for visited-set dedup. Uses uri + name + range +
    /// selectionRange because two distinct nested symbols can share a
    /// `range` (the enclosing block of code) while differing only by
    /// `selectionRange` (the name span). Including the selection range
    /// in the key keeps the BFS from treating nested-but-distinct
    /// symbols as one. Call- and type-hierarchy items have the same
    /// key shape (both expose `uri`, `name`, `range`, `selectionRange`),
    /// so they share the same key format.
    private static func walkKey(forCall item: CallHierarchyItem) -> String {
        let r = item.range
        let s = item.selectionRange
        return "\(item.uri)#\(item.name)#\(r.start.line):\(r.start.character)-\(r.end.line):\(r.end.character)#\(s.start.line):\(s.start.character)"
    }

    private static func walkKey(forType item: TypeHierarchyItem) -> String {
        let r = item.range
        let s = item.selectionRange
        return "\(item.uri)#\(item.name)#\(r.start.line):\(r.start.character)-\(r.end.line):\(r.end.character)#\(s.start.line):\(s.start.character)"
    }
}

// MARK: - GlobalWorkspaceSymbolTool

enum GlobalWorkspaceSymbolTool: MCPLSPTool {
    static let name = "lsp_global_workspace_symbol"
    static let description = "Search for symbols across every cached LSP session (any workspace, any languageId). Fans `workspace/symbol` out across `LSPService.allSessions()` and concatenates the results."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "query": prop("string", "Substring to match against symbol names"),
        ]
        return [
            "type": AnyCodable("object"),
            "properties": AnyCodable(props),
            "required": AnyCodable([AnyCodable("query")]),
        ]
    }()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        let query = try MCPLSPBridge.requireString(arguments: arguments, key: "query")
        let sessions = bridge.service.allSessions()
        var aggregated: [AnyCodable] = []
        for session in sessions {
            let params = WorkspaceSymbolParams(query: query)
            do {
                let result: WorkspaceSymbolResult? = try await session.sendRequest(
                    method: "workspace/symbol",
                    params: params,
                    resultType: WorkspaceSymbolResult?.self
                )
                guard let result else { continue }
                let data = try JSONEncoder().encode(result)
                if let parsed = try? JSONDecoder().decode(AnyCodable.self, from: data) {
                    aggregated.append(parsed)
                }
            } catch {
                // Per-session failures must not abort the whole walk —
                // surface what we can and let the caller correlate gaps
                // via `lsp_session_status`.
                continue
            }
        }
        return try MCPLSPBridge.makeJSONContent(aggregated)
    }
}

// MARK: - CrossWorkspaceDefinitionTool

enum CrossWorkspaceDefinitionTool: MCPLSPTool {
    static let name = "lsp_cross_workspace_definition"
    static let description = "Resolve a definition that may live in a sibling workspace. Dispatches textDocument/definition in the requested workspace first; when empty, asks textDocument/moniker for a portable identifier and fans workspace/symbol across every warm LSPService session."
    static let inputSchema: [String: AnyCodable] = positionRequestSchema()

    /// Permissive moniker shape used for the fan-out lookup. The full
    /// `Moniker` type requires `unique`, which servers don't always
    /// emit (and which we don't need): all we want is `identifier`.
    private struct MonikerLite: Decodable, Sendable {
        let identifier: String
    }

    /// JSON envelope returned by the tool.
    private struct CrossDefinitionBundle: Encodable {
        struct WorkspaceHit: Encodable {
            let workspace: String
            let locations: AnyCodable
        }
        let resolvedIn: String
        let definition: AnyCodable
        let crossWorkspace: [WorkspaceHit]

        enum CodingKeys: String, CodingKey {
            case resolvedIn = "resolved_in"
            case definition
            case crossWorkspace = "cross_workspace"
        }
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
        let (uri, position) = try bridge.extractPosition(arguments: arguments)
        try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)

        let workspaceRootString = try MCPLSPBridge.requireString(
            arguments: arguments,
            key: "workspace_root"
        )
        let originRoot = MCPLSPBridge.fileURL(fromPathOrUri: workspaceRootString)

        // 1. textDocument/definition in the origin session.
        let definitionParams = DefinitionParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            position: position
        )
        var definitionAny: AnyCodable = AnyCodable(NSNull())
        var definitionEmpty = true
        do {
            let result: DefinitionResult? = try await session.sendRequest(
                method: "textDocument/definition",
                params: definitionParams,
                resultType: DefinitionResult?.self
            )
            if let result {
                let data = try JSONEncoder().encode(result)
                if let parsed = try? JSONDecoder().decode(AnyCodable.self, from: data) {
                    definitionAny = parsed
                }
                switch result {
                case .single:
                    definitionEmpty = false
                case .array(let arr):
                    definitionEmpty = arr.isEmpty
                case .linkArray(let arr):
                    definitionEmpty = arr.isEmpty
                }
            }
        } catch {
            // Treat a server error as "no definition here" and proceed
            // to the moniker fan-out; the caller should see the broader
            // search rather than a hard failure.
        }

        // 2. If the local definition is empty, hop through moniker +
        //    workspace/symbol across every warm session.
        var crossHits: [CrossDefinitionBundle.WorkspaceHit] = []
        if definitionEmpty {
            let monikerParams = MonikerParams(
                textDocument: TextDocumentIdentifier(uri: uri),
                position: position
            )
            let monikers: [MonikerLite]?
            do {
                monikers = try await session.sendRequest(
                    method: "textDocument/moniker",
                    params: monikerParams,
                    resultType: [MonikerLite]?.self
                )
            } catch {
                monikers = nil
            }
            let identifier = monikers?.first?.identifier
            if let identifier {
                let warmSessions = bridge.service.allWarmSessions()
                for warm in warmSessions {
                    let symbolParams = WorkspaceSymbolParams(query: identifier)
                    do {
                        let result: WorkspaceSymbolResult? = try await warm.session.sendRequest(
                            method: "workspace/symbol",
                            params: symbolParams,
                            resultType: WorkspaceSymbolResult?.self
                        )
                        guard let result else { continue }
                        let data = try JSONEncoder().encode(result)
                        let parsed = try JSONDecoder().decode(AnyCodable.self, from: data)
                        crossHits.append(CrossDefinitionBundle.WorkspaceHit(
                            workspace: warm.workspaceRoot.absoluteString,
                            locations: parsed
                        ))
                    } catch {
                        // Per-session failure: skip this workspace and
                        // continue the fan-out so a single broken server
                        // doesn't blank the entire response.
                        continue
                    }
                }
            }
        }

        let bundle = CrossDefinitionBundle(
            resolvedIn: originRoot.absoluteString,
            definition: definitionAny,
            crossWorkspace: crossHits
        )
        return try MCPLSPBridge.makeJSONContent(bundle)
    }
}

// MARK: - DiagnosticsDiffTool

enum DiagnosticsDiffTool: MCPLSPTool {
    static let name = "lsp_diagnostics_diff"
    static let description = "Return the diagnostics that changed in a workspace since a previous snapshot id. Reads from the bridge-owned DiagnosticsStore — no LSP request is sent."
    static let inputSchema: [String: AnyCodable] = {
        let props: [String: AnyCodable] = [
            "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
            "language_id": prop(
                "string",
                "LSP languageId — accepted for parity with other tools but not used by the diff (the store keys on workspace only)."
            ),
            "since_snapshot_id": prop(
                "integer",
                "Snapshot id previously issued by the store; the diff returns URIs whose diagnostics changed strictly after this id."
            ),
        ]
        let required = ["workspace_root", "since_snapshot_id"]
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
        let since = try MCPLSPBridge.requireInt(
            arguments: arguments,
            key: "since_snapshot_id"
        )
        let workspaceURL = MCPLSPBridge.fileURL(fromPathOrUri: workspaceString)
        do {
            let diff = try await bridge.diagnosticsStore.diff(
                workspaceRoot: workspaceURL,
                since: since
            )
            return try MCPLSPBridge.makeJSONContent(diff)
        } catch {
            return MCPLSPBridge.makeErrorContent(error)
        }
    }
}

// MARK: - CapabilitiesTool

enum CapabilitiesTool: MCPLSPTool {
    static let name = "lsp_capabilities"
    static let description = "Return the server's static + dynamic capability snapshot for a workspace+language. Reads the session-resident CapabilityRegistry — no LSP request is sent."
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

    /// JSON envelope for the capability snapshot.
    /// `dynamic` is rendered as an array (rather than a `{id: Registration}`
    /// map) so the MCP caller can iterate registrations in registration
    /// order without depending on JSON-object key stability.
    private struct CapabilitySnapshot: Encodable {
        let staticCapabilities: ServerCapabilities?
        let dynamic: [Registration]

        enum CodingKeys: String, CodingKey {
            case staticCapabilities = "static"
            case dynamic
        }
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
        let registry = await session.capabilityRegistry()
        let staticCaps = await registry.currentStaticCapabilities()
        let dynamic = await registry.currentRegistrations()
        // Sort by registration id for a deterministic wire shape.
        let dynamicList = dynamic.values.sorted { $0.id < $1.id }
        let snapshot = CapabilitySnapshot(
            staticCapabilities: staticCaps,
            dynamic: dynamicList
        )
        return try MCPLSPBridge.makeJSONContent(snapshot)
    }
}

// MARK: - Notebook tools (shared helpers)

/// Build the JSON-Schema for a notebook synchronisation MCP tool. The
/// three notebook tools (`lsp_notebook_did_open` /
/// `lsp_notebook_did_change` / `lsp_notebook_did_close`) all share the
/// same outer argument shape: `workspace_root` + `language_id` + a single
/// `notebook` payload that the bridge decodes into the typed LSP params
/// struct.
private func notebookSchema() -> [String: AnyCodable] {
    let props: [String: AnyCodable] = [
        "workspace_root": prop("string", "Absolute path or file:// URI of the workspace root"),
        "language_id": prop("string", "LSP languageId (e.g. 'typescript', 'python')"),
        "notebook": AnyCodable([
            "type": AnyCodable("object"),
            "description": AnyCodable(
                "LSP notebook-document params payload. Shape matches"
                + " DidOpenNotebookDocumentParams / DidChangeNotebookDocumentParams /"
                + " DidCloseNotebookDocumentParams depending on the tool."
            ),
        ] as [String: AnyCodable]),
    ]
    let required = ["workspace_root", "language_id", "notebook"]
    return [
        "type": AnyCodable("object"),
        "properties": AnyCodable(props),
        "required": AnyCodable(required.map { AnyCodable($0) }),
    ]
}

/// Shared body for the three `notebookDocument/did*` notification tools.
/// Resolves the session, decodes the `notebook` argument into the typed
/// params struct, ships an LSP notification (no response), and surfaces a
/// tiny success payload for the MCP caller.
///
/// Argument-coercion errors propagate as `MCPLSPBridgeError` (so the MCP
/// caller sees the structured missing/invalid-argument variant), while
/// LSP transport errors are folded into the returned content via
/// `makeErrorContent` to match the rest of the bridge.
private func handleNotebookNotification<Params: Codable & Sendable>(
    method: String,
    paramsType: Params.Type,
    arguments: [String: AnyCodable],
    bridge: MCPLSPBridge
) async throws -> MCPContent {
    let session: LSPSession
    do {
        session = try await bridge.resolveSession(arguments: arguments)
    } catch let err as MCPLSPBridgeError {
        throw err
    } catch {
        return MCPLSPBridge.makeErrorContent(error)
    }
    guard let notebookAny = arguments["notebook"] else {
        throw MCPLSPBridgeError.missingArgument("notebook")
    }
    let params = try MCPLSPBridge.decodeFromAnyCodable(
        notebookAny,
        as: paramsType,
        argumentName: "notebook"
    )
    do {
        try await session.sendGenericNotification(method: method, params: params)
    } catch {
        return MCPLSPBridge.makeErrorContent(error)
    }
    return MCPContent(type: "text", text: #"{"success":true}"#)
}

// MARK: - NotebookDidOpenTool

enum NotebookDidOpenTool: MCPLSPTool {
    static let name = "lsp_notebook_did_open"
    static let description = "Notify the server that a notebook document has been opened (notebookDocument/didOpen). Sent as an LSP notification — no response."
    static let inputSchema: [String: AnyCodable] = notebookSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleNotebookNotification(
            method: "notebookDocument/didOpen",
            paramsType: DidOpenNotebookDocumentParams.self,
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - NotebookDidChangeTool

enum NotebookDidChangeTool: MCPLSPTool {
    static let name = "lsp_notebook_did_change"
    static let description = "Notify the server that a notebook document has changed (notebookDocument/didChange). Sent as an LSP notification — no response."
    static let inputSchema: [String: AnyCodable] = notebookSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleNotebookNotification(
            method: "notebookDocument/didChange",
            paramsType: DidChangeNotebookDocumentParams.self,
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - NotebookDidCloseTool

enum NotebookDidCloseTool: MCPLSPTool {
    static let name = "lsp_notebook_did_close"
    static let description = "Notify the server that a notebook document has been closed (notebookDocument/didClose). Sent as an LSP notification — no response."
    static let inputSchema: [String: AnyCodable] = notebookSchema()

    static func handle(arguments: [String: AnyCodable], bridge: MCPLSPBridge) async throws -> MCPContent {
        try await handleNotebookNotification(
            method: "notebookDocument/didClose",
            paramsType: DidCloseNotebookDocumentParams.self,
            arguments: arguments,
            bridge: bridge
        )
    }
}

// MARK: - Install / session DTOs
//
// `LSPInstaller` / `LSPService` ship value types that are deliberately not
// `Codable` (they include `URL?` maps and non-Codable associated values).
// These DTOs mirror only the fields the MCP surface needs to render, and
// add explicit Codable conformance with stable JSON shapes.

/// One prerequisite-status entry. Custom `encode(to:)` calls
/// `container.encode(_:forKey:)` rather than `encodeIfPresent` so a nil
/// path (the prereq is missing on PATH) still surfaces as
/// `"<name>": {"path": null}` in the JSON — without the explicit-null
/// shape the MCP caller can't distinguish "prereq absent" from "prereq
/// untested".
private struct PrereqStatusDTO: Codable, Sendable, Equatable {
    let path: String?

    init(path: String?) {
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case path
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
    }
}

/// JSON shape returned by `lsp_check_installation`.
private struct InstallationCheckDTO: Codable, Sendable, Equatable {
    let languageId: String
    let isInstalled: Bool
    let detectedPath: String?
    let detectedVersion: String?
    let prerequisiteStatuses: [String: PrereqStatusDTO]

    init(from check: InstallationCheck) {
        self.languageId = check.languageId
        self.isInstalled = check.isInstalled
        self.detectedPath = check.detectedPath?.absoluteString
        self.detectedVersion = check.detectedVersion
        var prereqs: [String: PrereqStatusDTO] = [:]
        for (key, value) in check.prerequisiteStatuses {
            prereqs[key] = PrereqStatusDTO(path: value?.absoluteString)
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
