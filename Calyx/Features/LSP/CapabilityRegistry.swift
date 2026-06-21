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
    func register(_ registrations: [Registration]) {
        for reg in registrations {
            self.registrations[reg.id] = reg
        }
    }

    /// Apply a batch of `client/unregisterCapability` unregistrations.
    /// Unknown ids are silently ignored — matching the spec's permissive
    /// "no-op on unknown" behaviour.
    func unregister(_ unregs: [Unregistration]) {
        for u in unregs {
            self.registrations.removeValue(forKey: u.id)
        }
    }

    /// Clear both static and dynamic state.
    func reset() {
        self.staticCapabilities = nil
        self.registrations.removeAll()
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

    /// Whether this server currently supports `method`, considering both the
    /// static `ServerCapabilities` and any live dynamic registrations.
    func isCapable(method: String) -> Bool {
        if isStaticallyCapable(method: method) {
            return true
        }
        return registrations.values.contains { $0.method == method }
    }

    // MARK: - Static capability lookup

    /// True iff the static `ServerCapabilities` advertises a provider for
    /// `method` that is present and not literally `false`. Unknown methods
    /// (not in the LSP-method → provider-field map) return false here and
    /// fall through to the dynamic-registration check in `isCapable`.
    private func isStaticallyCapable(method: String) -> Bool {
        guard let caps = staticCapabilities else { return false }
        guard let provider = Self.staticProvider(caps, for: method) else {
            return false
        }
        return Self.providerIsTruthy(provider)
    }

    /// Map an LSP method string to the matching `ServerCapabilities` provider
    /// slot. Returns `nil` either when the method is unmapped (e.g.
    /// `"textDocument/didChange"`) or when the slot itself is `nil`.
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
        case "textDocument/documentColor":       return caps.colorProvider
        case "workspace/symbol":                 return caps.workspaceSymbolProvider
        case "textDocument/formatting":          return caps.documentFormattingProvider
        case "textDocument/rangeFormatting":     return caps.documentRangeFormattingProvider
        case "textDocument/onTypeFormatting":    return caps.documentOnTypeFormattingProvider
        case "textDocument/rename":              return caps.renameProvider
        case "textDocument/foldingRange":        return caps.foldingRangeProvider
        case "textDocument/selectionRange":      return caps.selectionRangeProvider
        case "workspace/executeCommand":         return caps.executeCommandProvider
        case "textDocument/prepareCallHierarchy": return caps.callHierarchyProvider
        case "textDocument/linkedEditingRange":  return caps.linkedEditingRangeProvider
        case "textDocument/semanticTokens/full",
             "textDocument/semanticTokens/range",
             "textDocument/semanticTokens/full/delta":
            return caps.semanticTokensProvider
        case "textDocument/moniker":             return caps.monikerProvider
        case "textDocument/prepareTypeHierarchy": return caps.typeHierarchyProvider
        case "textDocument/inlineValue":         return caps.inlineValueProvider
        case "textDocument/inlayHint":           return caps.inlayHintProvider
        case "textDocument/diagnostic",
             "workspace/diagnostic":
            return caps.diagnosticProvider
        case "textDocument/completion":          return caps.completionProvider
        case "textDocument/signatureHelp":       return caps.signatureHelpProvider
        default:
            return nil
        }
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
            // Encoding failure on a value we constructed → treat as enabled,
            // because the value exists. (This branch is not expected to be
            // hit by any valid AnyCodable.)
            return true
        }
        guard let obj = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return true
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
