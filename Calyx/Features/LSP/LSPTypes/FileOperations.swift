//
//  FileOperations.swift
//  Calyx
//
//  LSP 3.18 workspace file operations: create / rename / delete request and
//  registration types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willCreateFiles
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willRenameFiles
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_willDeleteFiles
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileOperationRegistrationOptions
//
//  Note: these types are distinct from the document-change resource
//  operations defined in `FileResourceChange.swift` (CreateFile/RenameFile/
//  DeleteFile). Those carry a discriminating `kind` and optional `options`
//  for use inside a `WorkspaceEdit.documentChanges`; the types here only
//  describe file URIs for the workspace/will{Create,Rename,Delete}Files
//  request bodies.
//

import Foundation

// MARK: - Create

/// Represents information on a file/folder create.
struct FileCreate: Sendable, Codable, Equatable {
    /// A file:// URI for the location of the file/folder being created.
    let uri: String

    init(uri: String) {
        self.uri = uri
    }
}

/// The parameters sent in notifications/requests for user-initiated
/// creation of files.
struct CreateFilesParams: Sendable, Codable, Equatable {
    /// An array of all files/folders created in this operation.
    let files: [FileCreate]

    init(files: [FileCreate]) {
        self.files = files
    }
}

// MARK: - Rename

/// Represents information on a file/folder rename.
struct FileRename: Sendable, Codable, Equatable {
    /// A file:// URI for the original location of the file/folder being renamed.
    let oldUri: String
    /// A file:// URI for the new location of the file/folder being renamed.
    let newUri: String

    init(oldUri: String, newUri: String) {
        self.oldUri = oldUri
        self.newUri = newUri
    }
}

/// The parameters sent in notifications/requests for user-initiated
/// renames of files.
struct RenameFilesParams: Sendable, Codable, Equatable {
    /// An array of all files/folders renamed in this operation. When a folder
    /// is renamed, only the folder is included and not its children.
    let files: [FileRename]

    init(files: [FileRename]) {
        self.files = files
    }
}

// MARK: - Delete

/// Represents information on a file/folder delete.
struct FileDelete: Sendable, Codable, Equatable {
    /// A file:// URI for the location of the file/folder being deleted.
    let uri: String

    init(uri: String) {
        self.uri = uri
    }
}

/// The parameters sent in notifications/requests for user-initiated
/// deletes of files.
struct DeleteFilesParams: Sendable, Codable, Equatable {
    /// An array of all files/folders deleted in this operation.
    let files: [FileDelete]

    init(files: [FileDelete]) {
        self.files = files
    }
}

// MARK: - Registration

/// A pattern kind describing if a glob pattern matches a file or a folder.
enum FileOperationPatternKind: String, Sendable, Codable, Equatable {
    /// The pattern matches a file only.
    case file
    /// The pattern matches a folder only.
    case folder
}

/// Matching options for `FileOperationPattern`.
struct FileOperationPatternOptions: Sendable, Codable, Equatable {
    /// The pattern should be matched ignoring casing.
    let ignoreCase: Bool?

    init(ignoreCase: Bool? = nil) {
        self.ignoreCase = ignoreCase
    }
}

/// A pattern to describe in which file operation requests or notifications
/// the server is interested in.
struct FileOperationPattern: Sendable, Codable, Equatable {
    /// The glob pattern to match. Glob patterns can have the following syntax:
    ///   * `*` to match one or more characters in a path segment
    ///   * `?` to match on one character in a path segment
    ///   * `**` to match any number of path segments, including none
    ///   * `{}` to group sub patterns into an OR expression
    ///   * `[]` to declare a range of characters to match
    ///   * `[!...]` to negate a range of characters
    let glob: String
    /// Whether to match files or folders with this pattern. Matches both if undefined.
    let matches: FileOperationPatternKind?
    /// Additional options used during matching.
    let options: FileOperationPatternOptions?

    init(
        glob: String,
        matches: FileOperationPatternKind? = nil,
        options: FileOperationPatternOptions? = nil
    ) {
        self.glob = glob
        self.matches = matches
        self.options = options
    }
}

/// A filter to describe in which file operation requests or notifications
/// the server is interested in.
struct FileOperationFilter: Sendable, Codable, Equatable {
    /// A Uri like `file` or `untitled`.
    let scheme: String?
    /// The actual file operation pattern.
    let pattern: FileOperationPattern

    init(scheme: String? = nil, pattern: FileOperationPattern) {
        self.scheme = scheme
        self.pattern = pattern
    }
}

/// The options to register for file operations.
struct FileOperationRegistrationOptions: Sendable, Codable, Equatable {
    /// The actual filters.
    let filters: [FileOperationFilter]

    init(filters: [FileOperationFilter]) {
        self.filters = filters
    }
}
