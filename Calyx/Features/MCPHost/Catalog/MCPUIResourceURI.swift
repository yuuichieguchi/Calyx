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
