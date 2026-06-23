//
//  FileResourceChange.swift
//  Calyx
//
//  LSP 3.18 file-level resource operations (Create/Rename/Delete) plus their
//  options. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#resourceChanges
//

import Foundation

// MARK: - CreateFile

/// Options to control file creation.
struct CreateFileOptions: Sendable, Codable, Equatable, Hashable {
    /// Overwrite existing file. Overwrite wins over `ignoreIfExists`.
    let overwrite: Bool?
    /// Ignore if exists.
    let ignoreIfExists: Bool?

    init(overwrite: Bool? = nil, ignoreIfExists: Bool? = nil) {
        self.overwrite = overwrite
        self.ignoreIfExists = ignoreIfExists
    }
}

/// Create file operation.
struct CreateFile: Sendable, Codable, Equatable, Hashable {
    /// A create operation; always the literal string `"create"`.
    let kind: String
    /// The resource to create.
    let uri: DocumentUri
    /// Additional options.
    let options: CreateFileOptions?
    /// An optional annotation identifier describing the operation.
    let annotationId: ChangeAnnotationIdentifier?

    init(
        uri: DocumentUri,
        options: CreateFileOptions? = nil,
        annotationId: ChangeAnnotationIdentifier? = nil
    ) {
        self.kind = "create"
        self.uri = uri
        self.options = options
        self.annotationId = annotationId
    }
}

// MARK: - RenameFile

/// Rename file options.
struct RenameFileOptions: Sendable, Codable, Equatable, Hashable {
    let overwrite: Bool?
    let ignoreIfExists: Bool?

    init(overwrite: Bool? = nil, ignoreIfExists: Bool? = nil) {
        self.overwrite = overwrite
        self.ignoreIfExists = ignoreIfExists
    }
}

/// Rename file operation.
struct RenameFile: Sendable, Codable, Equatable, Hashable {
    /// A rename operation; always the literal string `"rename"`.
    let kind: String
    /// The old (existing) location.
    let oldUri: DocumentUri
    /// The new location.
    let newUri: DocumentUri
    /// Rename options.
    let options: RenameFileOptions?
    /// An optional annotation identifier describing the operation.
    let annotationId: ChangeAnnotationIdentifier?

    init(
        oldUri: DocumentUri,
        newUri: DocumentUri,
        options: RenameFileOptions? = nil,
        annotationId: ChangeAnnotationIdentifier? = nil
    ) {
        self.kind = "rename"
        self.oldUri = oldUri
        self.newUri = newUri
        self.options = options
        self.annotationId = annotationId
    }
}

// MARK: - DeleteFile

/// Delete file options.
struct DeleteFileOptions: Sendable, Codable, Equatable, Hashable {
    /// Delete the content recursively if a folder is denoted.
    let recursive: Bool?
    /// Ignore the operation if the file doesn't exist.
    let ignoreIfNotExists: Bool?

    init(recursive: Bool? = nil, ignoreIfNotExists: Bool? = nil) {
        self.recursive = recursive
        self.ignoreIfNotExists = ignoreIfNotExists
    }
}

/// Delete file operation.
struct DeleteFile: Sendable, Codable, Equatable, Hashable {
    /// A delete operation; always the literal string `"delete"`.
    let kind: String
    /// The file to delete.
    let uri: DocumentUri
    /// Delete options.
    let options: DeleteFileOptions?
    /// An optional annotation identifier describing the operation.
    let annotationId: ChangeAnnotationIdentifier?

    init(
        uri: DocumentUri,
        options: DeleteFileOptions? = nil,
        annotationId: ChangeAnnotationIdentifier? = nil
    ) {
        self.kind = "delete"
        self.uri = uri
        self.options = options
        self.annotationId = annotationId
    }
}
