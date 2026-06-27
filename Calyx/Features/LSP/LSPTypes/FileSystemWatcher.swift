//
//  FileSystemWatcher.swift
//  Calyx
//
//  LSP 3.18 file-system watcher types used by `workspace/didChangeWatchedFiles`
//  dynamic registration. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeWatchedFilesRegistrationOptions
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileSystemWatcher
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#globPattern
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#relativePattern
//
//  These types let the bridge consult the server's watch patterns when
//  deciding which file changes warrant a `workspace/didChangeWatchedFiles`
//  notification.
//

import Foundation

// MARK: - WatchKind

/// The kind of events the server is interested in. Per LSP 3.18 this is an
/// OptionSet over three bit-flags:
///   * `create` = 1
///   * `change` = 2
///   * `delete` = 4
///
/// Per spec the default (when `kind` is omitted) is `WatchKind.all`
/// (`create | change | delete`).
struct WatchKind: OptionSet, Sendable, Codable, Equatable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Interested in create events.
    static let create = WatchKind(rawValue: 1)
    /// Interested in change events.
    static let change = WatchKind(rawValue: 2)
    /// Interested in delete events.
    static let delete = WatchKind(rawValue: 4)

    /// The spec-default when `kind` is omitted: all three event kinds.
    static let all: WatchKind = [.create, .change, .delete]

    // Encode/decode as a JSON number (the underlying bitmask).
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(Int.self)
        self.rawValue = raw
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - RelativePattern

/// A relative glob pattern, anchored to a workspace folder or to a base URI.
/// LSP 3.18 `RelativePattern`:
///   https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#relativePattern
struct RelativePattern: Sendable, Codable, Equatable {
    /// A workspace folder or a base URI (encoded as a string per spec).
    /// The spec defines `baseUri: WorkspaceFolder | URI`, but the
    /// `WorkspaceFolder` arm is a `{ uri, name }` object. We keep the raw
    /// JSON via `AnyCodable` so both arms decode without lossy
    /// normalisation.
    let baseUri: AnyCodable
    /// The actual glob pattern.
    let pattern: String

    init(baseUri: AnyCodable, pattern: String) {
        self.baseUri = baseUri
        self.pattern = pattern
    }
}

// MARK: - GlobPattern

/// A file-system glob pattern. Per LSP 3.18 `GlobPattern = Pattern | RelativePattern`
/// where `Pattern = string`.
///   https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#globPattern
enum GlobPattern: Sendable, Codable, Equatable {
    /// A bare glob string, anchored to the workspace root.
    case string(String)
    /// A glob anchored to an explicit base URI / workspace folder.
    case relative(RelativePattern)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        let rel = try container.decode(RelativePattern.self)
        self = .relative(rel)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .relative(let r):
            try container.encode(r)
        }
    }
}

// MARK: - FileSystemWatcher

/// A single watcher entry inside `DidChangeWatchedFilesRegistrationOptions`.
///   https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#fileSystemWatcher
struct FileSystemWatcher: Sendable, Codable, Equatable {
    /// The glob pattern to watch.
    let globPattern: GlobPattern
    /// The kind of events of interest. When omitted, the spec default is
    /// `WatchKind.all` (`create | change | delete`).
    let kind: WatchKind?

    init(globPattern: GlobPattern, kind: WatchKind? = nil) {
        self.globPattern = globPattern
        self.kind = kind
    }
}

// MARK: - DidChangeWatchedFilesRegistrationOptions

/// Registration options for `workspace/didChangeWatchedFiles`. Per LSP 3.18:
///   https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#didChangeWatchedFilesRegistrationOptions
struct DidChangeWatchedFilesRegistrationOptions: Sendable, Codable, Equatable {
    /// The watchers to register.
    let watchers: [FileSystemWatcher]

    init(watchers: [FileSystemWatcher]) {
        self.watchers = watchers
    }
}
