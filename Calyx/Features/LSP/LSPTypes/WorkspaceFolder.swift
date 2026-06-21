//
//  WorkspaceFolder.swift
//  Calyx
//
//  LSP 3.18 WorkspaceFolder. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceFolder
//

import Foundation

/// Represents a single workspace folder. A client may have multiple
/// workspace folders open at once; servers receive them via
/// `InitializeParams.workspaceFolders` and `workspace/didChangeWorkspaceFolders`.
struct WorkspaceFolder: Sendable, Codable, Equatable, Hashable {
    /// The associated URI for this workspace folder.
    let uri: URI
    /// The name of the workspace folder. Used to refer to this folder in the
    /// user interface.
    let name: String

    init(uri: URI, name: String) {
        self.uri = uri
        self.name = name
    }
}
