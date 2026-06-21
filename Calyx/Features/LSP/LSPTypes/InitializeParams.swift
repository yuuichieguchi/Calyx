//
//  InitializeParams.swift
//  Calyx
//
//  LSP 3.18 InitializeParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initializeParams
//
//  Several fields here are tri-state on the wire: they may be present with a
//  value, explicitly `null`, or absent entirely. The spec distinguishes these
//  semantically:
//      - `rootUri`:           string | null (required by older spec, deprecated 3.18);
//                              clients may now omit it entirely, so we treat it as
//                              present | null | absent.
//      - `workspaceFolders`:  WorkspaceFolder[] | null; null means "no folders",
//                              absent means "client does not support folders".
//
//  `processId` is `integer | null` (always present per spec; null means "no
//  parent process"). We mirror the `OptionalVersionedTextDocumentIdentifier`
//  pattern: nil round-trips as JSON `null` rather than being dropped.
//
//  `rootPath` is a deprecated `string?` (no null variant in the spec); it
//  is encoded only when present.
//

import Foundation

/// Parameters for the `initialize` request.
struct InitializeParams: Sendable, Codable, Equatable {
    /// The process Id of the parent process that started the server. Is
    /// `null` if the process has not been started by another process. If
    /// the parent process is not alive then the server should exit (see
    /// exit notification) its process.
    let processId: Int?
    /// Information about the client (LSP 3.15+).
    let clientInfo: ClientInfo?
    /// The locale the client is currently showing the user interface in.
    /// Must use the BCP 47 tag. LSP 3.16+.
    let locale: String?
    /// The rootPath of the workspace. Deprecated in favour of rootUri.
    let rootPath: String?
    /// The rootUri of the workspace. Deprecated in favour of
    /// `workspaceFolders`. Tri-state: value / null / absent.
    let rootUri: ThreeStateOptional<DocumentUri>
    /// The initial trace setting. If omitted defaults to `off`.
    let trace: TraceValue?
    /// User provided initialization options.
    let initializationOptions: AnyCodable?
    /// The capabilities provided by the client (editor or tool).
    let capabilities: ClientCapabilities
    /// The workspace folders configured in the client when the server starts.
    /// Tri-state: array / null / absent. LSP 3.6+.
    let workspaceFolders: ThreeStateOptional<[WorkspaceFolder]>

    init(
        processId: Int?,
        capabilities: ClientCapabilities,
        clientInfo: ClientInfo? = nil,
        locale: String? = nil,
        rootPath: String? = nil,
        rootUri: ThreeStateOptional<DocumentUri> = .absent,
        trace: TraceValue? = nil,
        initializationOptions: AnyCodable? = nil,
        workspaceFolders: ThreeStateOptional<[WorkspaceFolder]> = .absent
    ) {
        self.processId = processId
        self.capabilities = capabilities
        self.clientInfo = clientInfo
        self.locale = locale
        self.rootPath = rootPath
        self.rootUri = rootUri
        self.trace = trace
        self.initializationOptions = initializationOptions
        self.workspaceFolders = workspaceFolders
    }

    private enum CodingKeys: String, CodingKey {
        case processId
        case clientInfo
        case locale
        case rootPath
        case rootUri
        case trace
        case initializationOptions
        case capabilities
        case workspaceFolders
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // processId: `integer | null` (always present in the spec; we tolerate
        // absence for forwards-compat and treat it as nil).
        if c.contains(.processId) {
            if try c.decodeNil(forKey: .processId) {
                self.processId = nil
            } else {
                self.processId = try c.decode(Int.self, forKey: .processId)
            }
        } else {
            self.processId = nil
        }

        self.clientInfo = try c.decodeIfPresent(ClientInfo.self, forKey: .clientInfo)
        self.locale = try c.decodeIfPresent(String.self, forKey: .locale)
        self.rootPath = try c.decodeIfPresent(String.self, forKey: .rootPath)
        self.rootUri = try ThreeStateOptional<DocumentUri>(from: c, forKey: .rootUri)
        self.trace = try c.decodeIfPresent(TraceValue.self, forKey: .trace)
        self.initializationOptions = try c.decodeIfPresent(AnyCodable.self, forKey: .initializationOptions)
        self.capabilities = try c.decode(ClientCapabilities.self, forKey: .capabilities)
        self.workspaceFolders = try ThreeStateOptional<[WorkspaceFolder]>(from: c, forKey: .workspaceFolders)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        // processId is always emitted; nil becomes JSON null.
        if let pid = processId {
            try c.encode(pid, forKey: .processId)
        } else {
            try c.encodeNil(forKey: .processId)
        }

        try c.encodeIfPresent(clientInfo, forKey: .clientInfo)
        try c.encodeIfPresent(locale, forKey: .locale)
        try c.encodeIfPresent(rootPath, forKey: .rootPath)
        try rootUri.encode(to: &c, forKey: .rootUri)
        try c.encodeIfPresent(trace, forKey: .trace)
        try c.encodeIfPresent(initializationOptions, forKey: .initializationOptions)
        try c.encode(capabilities, forKey: .capabilities)
        try workspaceFolders.encode(to: &c, forKey: .workspaceFolders)
    }
}

// MARK: - ThreeStateOptional

/// Models a field with the LSP wire form `T | null | absent` where each of
/// the three states is semantically distinct and must round-trip losslessly.
enum ThreeStateOptional<Wrapped: Codable & Equatable & Sendable>: Sendable, Equatable {
    /// The key is present with a non-null value.
    case present(Wrapped)
    /// The key is present with an explicit JSON `null` value.
    case null
    /// The key is absent from the encoded JSON.
    case absent

    /// Decode from a keyed container. Distinguishes the three states by
    /// inspecting both `contains(key)` and `decodeNil(forKey:)`.
    init<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws {
        guard container.contains(key) else {
            self = .absent
            return
        }
        if try container.decodeNil(forKey: key) {
            self = .null
        } else {
            self = .present(try container.decode(Wrapped.self, forKey: key))
        }
    }

    /// Encode into a keyed container, emitting the key only for `.present`
    /// and `.null`; `.absent` causes the key to be skipped entirely.
    func encode<K: CodingKey>(to container: inout KeyedEncodingContainer<K>, forKey key: K) throws {
        switch self {
        case .present(let value):
            try container.encode(value, forKey: key)
        case .null:
            try container.encodeNil(forKey: key)
        case .absent:
            break
        }
    }
}
