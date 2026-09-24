//
//  MCPUIResourceURI.swift
//  Calyx
//
//  Maps an upstream `ui://` resource URI to the re-exported form that
//  carries the server alias as its first segment, and back.
//

import Foundation

enum MCPUIResourceURI {

    private static let scheme = "ui://"

    /// `ui://<rest>` becomes `ui://<alias>/<rest>`. Nil for any other scheme.
    static func export(upstreamURI: String, alias: String) -> String? {
        guard upstreamURI.hasPrefix(scheme) else { return nil }
        return scheme + alias + "/" + upstreamURI.dropFirst(scheme.count)
    }

    /// `meta` (a tool's or a tool result's `_meta`) with `ui.resourceUri`
    /// and the deprecated flat `ui/resourceUri` exported under `alias` when
    /// they hold a `ui://` URI. Every other key and value is unchanged.
    static func exportingUIMeta(_ meta: [String: AnyCodable], alias: String) -> [String: AnyCodable] {
        var meta = meta
        if var ui = meta["ui"]?.objectValue,
           let uri = ui["resourceUri"]?.stringValue,
           let exported = export(upstreamURI: uri, alias: alias) {
            ui["resourceUri"] = AnyCodable(exported)
            meta["ui"] = AnyCodable(ui)
        }
        if let uri = meta["ui/resourceUri"]?.stringValue,
           let exported = export(upstreamURI: uri, alias: alias) {
            meta["ui/resourceUri"] = AnyCodable(exported)
        }
        return meta
    }

    /// `raw` (a tool definition or a `tools/call` result) with its
    /// `_meta` passed through `exportingUIMeta`. A `raw` without an object
    /// `_meta` is returned unchanged: nothing is added.
    static func exportingUIMeta(inRaw raw: [String: AnyCodable], alias: String) -> [String: AnyCodable] {
        guard let meta = raw["_meta"]?.objectValue else { return raw }
        var raw = raw
        raw["_meta"] = AnyCodable(exportingUIMeta(meta, alias: alias))
        return raw
    }

    /// Splits `ui://<alias>/<rest>` into the alias and `ui://<rest>`. Nil for
    /// any other scheme, and when there is no `/` after a non-empty alias.
    static func resolve(exportedURI: String) -> (alias: String, upstreamURI: String)? {
        guard exportedURI.hasPrefix(scheme) else { return nil }
        let afterScheme = exportedURI.dropFirst(scheme.count)
        guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
        let alias = afterScheme[..<slash]
        guard !alias.isEmpty else { return nil }
        return (String(alias), scheme + afterScheme[afterScheme.index(after: slash)...])
    }
}
