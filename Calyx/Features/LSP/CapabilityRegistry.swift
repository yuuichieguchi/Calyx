//
//  CapabilityRegistry.swift
//  Calyx
//
//  Actor that tracks an LSP server's combined static + dynamic capabilities,
//  i.e. the `ServerCapabilities` returned by `initialize` plus any later
//  `client/registerCapability` / `client/unregisterCapability` deltas.
//
//  Spec references:
//    - ServerCapabilities (static, from `initialize` response):
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#serverCapabilities
//    - client/registerCapability / client/unregisterCapability (dynamic):
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#client_registerCapability
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#client_unregisterCapability
//
//  `isCapable(method:)` is the union of the two sources: a method is capable
//  iff the static `ServerCapabilities` advertises a non-nil, not-literally-
//  `false` provider for the method, OR a live dynamic registration exists
//  whose `method` matches.
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.calyx", category: "lsp.capability")

/// Tracks the static `ServerCapabilities` from the `initialize` response
/// together with the dynamic registrations applied via
/// `client/registerCapability` and `client/unregisterCapability`.
actor CapabilityRegistry {

    // MARK: - State

    /// Static capabilities from the most recent `initialize` response, or
    /// `nil` if `setStaticCapabilities` has never been called.
    private var staticCapabilities: ServerCapabilities?

    /// Live dynamic registrations keyed by registration `id`.
    private var registrations: [String: Registration] = [:]

    /// Typed sidecar payloads keyed by registration `id`, decoded from each
    /// `Registration.registerOptions` per method. The original
    /// `Registration` in `registrations` is preserved unchanged for
    /// backwards compatibility; this map exposes the structured shape so
    /// consumers (e.g. `FileSyncManager` deciding which paths warrant a
    /// `workspace/didChangeWatchedFiles` notification) can dispatch on the
    /// typed value without re-decoding the raw `AnyCodable`.
    private var registerOptions: [String: RegisterOptions] = [:]

    // MARK: - Init

    init() {}

    // MARK: - Mutators

    /// Replace the static capability slot. Typically called once after the
    /// `initialize` response is received.
    func setStaticCapabilities(_ caps: ServerCapabilities) {
        self.staticCapabilities = caps
    }

    /// Apply a batch of `client/registerCapability` registrations. Each entry
    /// is keyed by its `id`; existing entries with the same id are
    /// overwritten (the spec treats id collisions as undefined; last-wins
    /// matches what most clients do).
    ///
    /// In addition to storing the raw `Registration`, this also decodes the
    /// `registerOptions` payload into the typed `RegisterOptions` sidecar
    /// matching the registration's method. Unknown methods (and decode
    /// failures) fall through to `.raw`, preserving the original payload.
    func register(_ registrations: [Registration]) {
        for reg in registrations {
            self.registrations[reg.id] = reg
            self.registerOptions[reg.id] = RegisterOptions.decode(
                method: reg.method,
                registerOptions: reg.registerOptions
            )
        }
    }

    /// Apply a batch of `client/unregisterCapability` unregistrations.
    /// Unknown ids are silently ignored — matching the spec's permissive
    /// "no-op on unknown" behaviour.
    func unregister(_ unregs: [Unregistration]) {
        for u in unregs {
            self.registrations.removeValue(forKey: u.id)
            self.registerOptions.removeValue(forKey: u.id)
        }
    }

    /// Clear both static and dynamic state.
    func reset() {
        self.staticCapabilities = nil
        self.registrations.removeAll()
        self.registerOptions.removeAll()
    }

    // MARK: - Read-only

    /// Returns the most recent static capability snapshot, or nil if never set.
    func currentStaticCapabilities() -> ServerCapabilities? {
        return staticCapabilities
    }

    /// Returns the current dynamic registration table keyed by id.
    func currentRegistrations() -> [String: Registration] {
        return registrations
    }

    /// Returns the typed-options sidecar table keyed by registration id.
    /// Each entry corresponds to the same-id entry in
    /// `currentRegistrations()`. Useful for consumers that want to dispatch
    /// on the typed shape without re-decoding the raw `AnyCodable`.
    func currentRegisterOptions() -> [String: RegisterOptions] {
        return registerOptions
    }

    /// Whether this server currently supports `method`, considering both the
    /// static `ServerCapabilities` and any live dynamic registrations.
    func isCapable(method: String) -> Bool {
        if isStaticallyCapable(method: method) {
            return true
        }
        return registrations.values.contains { $0.method == method }
    }

    /// Returns the union of all `FileSystemWatcher` entries from every
    /// live registration whose method equals `method`. Intended for
    /// `method == "workspace/didChangeWatchedFiles"`, where the bridge
    /// needs to know which globs the server cares about. Returns an empty
    /// array when no matching registration exists or when no matching
    /// registration carries a typed `didChangeWatchedFiles` payload.
    ///
    /// Order: registrations are iterated in dictionary-iteration order,
    /// which is not stable across runs; callers that need stable ordering
    /// should sort the result.
    func watchers(forMethod method: String) -> [FileSystemWatcher] {
        var result: [FileSystemWatcher] = []
        for (id, reg) in registrations where reg.method == method {
            guard case .didChangeWatchedFiles(let typed) = registerOptions[id] else {
                continue
            }
            result.append(contentsOf: typed.watchers)
        }
        return result
    }

    // MARK: - Static capability lookup

    /// True iff the static `ServerCapabilities` advertises a provider for
    /// `method` that is present and not literally `false`. Unknown methods
    /// (not in the LSP-method → provider-field map) return false here and
    /// fall through to the dynamic-registration check in `isCapable`.
    private func isStaticallyCapable(method: String) -> Bool {
        guard let caps = staticCapabilities else { return false }

        // `textDocument/publishDiagnostics` is a server-to-client notification
        // and the LSP spec does not gate it behind any provider slot — any
        // server is free to push diagnostics. Treat it as always capable once
        // static caps have been set.
        if method == "textDocument/publishDiagnostics" {
            return true
        }

        guard let provider = Self.staticProvider(caps, for: method) else {
            return false
        }
        return Self.providerIsTruthy(provider)
    }

    /// Map an LSP method string to the matching `ServerCapabilities` provider
    /// slot. Returns `nil` either when the method is unmapped (e.g.
    /// `"textDocument/didChange"`) or when the slot itself is `nil`.
    ///
    /// For LSP methods whose capability sits inside a sub-flag of a parent
    /// provider (e.g. `completionItem/resolve` → `completionProvider.resolveProvider`,
    /// `textDocument/prepareRename` → `renameProvider.prepareProvider`,
    /// `workspace/willCreateFiles` → `workspace.fileOperations.willCreate`),
    /// this function extracts the sub-flag and returns it wrapped as a
    /// fresh `AnyCodable` so the standard `providerIsTruthy` machinery can
    /// evaluate it uniformly. A missing sub-flag is treated as the slot
    /// being unadvertised and yields `nil`.
    private static func staticProvider(
        _ caps: ServerCapabilities,
        for method: String
    ) -> AnyCodable? {
        switch method {
        case "textDocument/hover":               return caps.hoverProvider
        case "textDocument/definition":          return caps.definitionProvider
        case "textDocument/declaration":         return caps.declarationProvider
        case "textDocument/typeDefinition":      return caps.typeDefinitionProvider
        case "textDocument/implementation":      return caps.implementationProvider
        case "textDocument/references":          return caps.referencesProvider
        case "textDocument/documentHighlight":   return caps.documentHighlightProvider
        case "textDocument/documentSymbol":      return caps.documentSymbolProvider
        case "textDocument/codeAction":          return caps.codeActionProvider
        case "textDocument/codeLens":            return caps.codeLensProvider
        case "textDocument/documentLink":        return caps.documentLinkProvider
        case "textDocument/documentColor",
             "textDocument/colorPresentation":
            // Both `documentColor` and `colorPresentation` share the same
            // `colorProvider` slot per LSP 3.18.
            return caps.colorProvider
        case "workspace/symbol":                 return caps.workspaceSymbolProvider
        case "textDocument/formatting":          return caps.documentFormattingProvider
        case "textDocument/rangeFormatting":     return caps.documentRangeFormattingProvider
        case "textDocument/onTypeFormatting":    return caps.documentOnTypeFormattingProvider
        case "textDocument/rename":              return caps.renameProvider
        case "textDocument/prepareRename":
            // `prepareRename` is gated by `renameProvider.prepareProvider`.
            // When `renameProvider` is the bare boolean form (`true`), the
            // spec leaves `prepareProvider` undefined — treat that as
            // "not advertised" so we do not over-claim.
            return subFlagProvider(caps.renameProvider, key: "prepareProvider")
        case "textDocument/foldingRange":        return caps.foldingRangeProvider
        case "textDocument/selectionRange":      return caps.selectionRangeProvider
        case "workspace/executeCommand":         return caps.executeCommandProvider
        case "textDocument/prepareCallHierarchy",
             "callHierarchy/incomingCalls",
             "callHierarchy/outgoingCalls":
            // All three call-hierarchy methods sit under `callHierarchyProvider`.
            return caps.callHierarchyProvider
        case "textDocument/linkedEditingRange":  return caps.linkedEditingRangeProvider
        case "textDocument/semanticTokens/full",
             "textDocument/semanticTokens/range",
             "textDocument/semanticTokens/full/delta":
            return caps.semanticTokensProvider
        case "textDocument/moniker":             return caps.monikerProvider
        case "textDocument/prepareTypeHierarchy",
             "typeHierarchy/supertypes",
             "typeHierarchy/subtypes":
            // All three type-hierarchy methods sit under `typeHierarchyProvider`.
            return caps.typeHierarchyProvider
        case "textDocument/inlineValue":         return caps.inlineValueProvider
        case "textDocument/inlayHint":           return caps.inlayHintProvider
        case "textDocument/diagnostic",
             "workspace/diagnostic":
            return caps.diagnosticProvider
        case "textDocument/completion":          return caps.completionProvider
        case "textDocument/signatureHelp":       return caps.signatureHelpProvider

        // MARK: Resolve-variant methods (sub-flag `resolveProvider`).
        case "completionItem/resolve":
            return subFlagProvider(caps.completionProvider, key: "resolveProvider")
        case "codeAction/resolve":
            return subFlagProvider(caps.codeActionProvider, key: "resolveProvider")
        case "codeLens/resolve":
            return subFlagProvider(caps.codeLensProvider, key: "resolveProvider")
        case "documentLink/resolve":
            return subFlagProvider(caps.documentLinkProvider, key: "resolveProvider")
        case "inlayHint/resolve":
            return subFlagProvider(caps.inlayHintProvider, key: "resolveProvider")
        case "workspaceSymbol/resolve":
            return subFlagProvider(caps.workspaceSymbolProvider, key: "resolveProvider")

        // MARK: Notebook document lifecycle.
        case "notebookDocument/didOpen",
             "notebookDocument/didChange",
             "notebookDocument/didClose",
             "notebookDocument/didSave":
            return caps.notebookDocumentSync

        // MARK: Workspace file-operation notifications/requests.
        case "workspace/willCreateFiles":
            return fileOperationProvider(caps.workspace, key: "willCreate")
        case "workspace/willRenameFiles":
            return fileOperationProvider(caps.workspace, key: "willRename")
        case "workspace/willDeleteFiles":
            return fileOperationProvider(caps.workspace, key: "willDelete")
        case "workspace/didCreateFiles":
            return fileOperationProvider(caps.workspace, key: "didCreate")
        case "workspace/didRenameFiles":
            return fileOperationProvider(caps.workspace, key: "didRename")
        case "workspace/didDeleteFiles":
            return fileOperationProvider(caps.workspace, key: "didDelete")

        default:
            return nil
        }
    }

    /// Extract a top-level sub-flag (e.g. `resolveProvider`, `prepareProvider`)
    /// from a parent provider whose `boolean | Options` union is stored in
    /// `AnyCodable`. Returns:
    ///   - `nil` if the parent is `nil` or literally `false` (capability not
    ///     advertised at all, so the sub-flag cannot be advertised either);
    ///   - `nil` if the parent is an options object that does not contain
    ///     `key` (sub-flag not advertised);
    ///   - a fresh `AnyCodable` wrapping the sub-flag's JSON value otherwise,
    ///     so the standard `providerIsTruthy` machinery can evaluate it.
    ///
    /// A bare boolean `true` parent intentionally yields `nil` here: the LSP
    /// spec does not let bare-`true` providers advertise sub-flags such as
    /// `resolveProvider` or `prepareProvider`, and silently treating it as
    /// truthy would over-claim capabilities the server never offered.
    private static func subFlagProvider(
        _ parent: AnyCodable?,
        key: String
    ) -> AnyCodable? {
        guard let parent else { return nil }
        guard let data = try? JSONEncoder().encode(parent),
              let obj = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ) else {
            logger.error("subFlagProvider: failed to introspect parent provider for key '\(key)'")
            return nil
        }
        guard let dict = obj as? [String: Any] else {
            // Bare boolean / null / scalar / array parent. No sub-flag map.
            return nil
        }
        guard let raw = dict[key] else {
            return nil
        }
        return AnyCodable(raw)
    }

    /// Extract a `workspace.fileOperations.<key>` sub-entry from the
    /// `workspace` capability slot. The exact shape of each entry is
    /// `FileOperationRegistrationOptions` (an object with a `filters` array),
    /// but for capability gating only the presence/truthiness of the entry
    /// matters. Returns `nil` if `workspace` is unset, lacks a
    /// `fileOperations` object, or that object lacks the requested key.
    private static func fileOperationProvider(
        _ workspace: AnyCodable?,
        key: String
    ) -> AnyCodable? {
        guard let workspace else { return nil }
        guard let data = try? JSONEncoder().encode(workspace),
              let obj = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ) else {
            logger.error("fileOperationProvider: failed to introspect workspace slot for key '\(key)'")
            return nil
        }
        guard let dict = obj as? [String: Any],
              let fileOps = dict["fileOperations"] as? [String: Any],
              let raw = fileOps[key] else {
            return nil
        }
        return AnyCodable(raw)
    }

    /// Decide whether an `AnyCodable` provider value enables the capability.
    ///
    /// LSP providers use the union `boolean | Options`:
    ///   - literal `true`  → enabled
    ///   - literal `false` → disabled
    ///   - any object/array/non-bool scalar → enabled (server is offering
    ///     concrete options for the capability)
    ///
    /// `AnyCodable`'s storage is private, so we encode it to JSON once and
    /// inspect the resulting Foundation object. This is a fast path: the
    /// value is small (a bool, or a tiny options dictionary) and only happens
    /// during `isCapable` checks, which are not on a hot per-character path.
    private static func providerIsTruthy(_ provider: AnyCodable) -> Bool {
        // Fast path: encode to JSON and parse the top-level value.
        guard let data = try? JSONEncoder().encode(provider) else {
            // Encoding failure means we cannot introspect the provider
            // value. Default to disabled — silently advertising a
            // capability the server may not actually serve causes
            // downstream MCP tools to dispatch unsupported methods.
            logger.error("providerIsTruthy: failed to introspect provider value, defaulting to false")
            return false
        }
        guard let obj = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            logger.error("providerIsTruthy: failed to introspect provider value, defaulting to false")
            return false
        }
        if let n = obj as? NSNumber {
            // JSONSerialization bridges JSON booleans to NSNumber with the
            // Bool objCType. Distinguish bool from numeric here.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue
            }
            // Numeric provider → unusual, but per spec only `boolean | Options`
            // are defined; treat any present non-bool value as enabled.
            return true
        }
        if obj is NSNull {
            return false
        }
        // Dictionary / array / string → server has supplied options, enabled.
        return true
    }
}
