//
//  Configuration.swift
//  Calyx
//
//  LSP 3.18 workspace/configuration request types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_configuration
//

import Foundation

/// Parameters of a `workspace/configuration` request.
struct ConfigurationParams: Sendable, Codable, Equatable {
    let items: [ConfigurationItem]

    init(items: [ConfigurationItem]) {
        self.items = items
    }
}

/// A single configuration request item.
struct ConfigurationItem: Sendable, Codable, Equatable {
    /// The scope to get the configuration section for.
    let scopeUri: DocumentUri?
    /// The configuration section asked for.
    let section: String?

    init(scopeUri: DocumentUri? = nil, section: String? = nil) {
        self.scopeUri = scopeUri
        self.section = section
    }
}
