//
//  LSPSession.swift
//  Calyx
//
//  Actor sitting above `LSPClient` that owns the full LSP 3.18 lifecycle for
//  a single (workspace root, languageId) pair:
//
//    1. `start()`        — drives the `initialize` request, captures the
//                          server capabilities into a `CapabilityRegistry`,
//                          installs server-initiated request handlers for
//                          `client/registerCapability`,
//                          `client/unregisterCapability` and
//                          `window/workDoneProgress/create`, and finally
//                          sends the `initialized` notification.
//    2. `didOpen` / `didChange` / `didClose` / `didSave` — the textDocument
//                          synchronization surface. Maintains an in-memory
//                          set of currently open URIs so duplicate opens are
//                          deduplicated and changes against unknown URIs
//                          fail loudly via `LSPSessionError.documentNotOpen`.
//    3. `shutdown()`     — sends `shutdown` then the `exit` notification and
//                          closes the underlying transport.
//
//  Spec entry points:
//    - initialize:                  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialize
//    - initialized:                 https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialized
//    - shutdown:                    https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#shutdown
//    - exit:                        https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#exit
//    - client/registerCapability:   https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#client_registerCapability
//    - client/unregisterCapability: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#client_unregisterCapability
//

import Foundation

// MARK: - SessionState

/// Lifecycle phase of an `LSPSession`. The `.running` arm carries the
/// server-reported `ServerInfo` (if any) for downstream telemetry / UI.
enum SessionState: Sendable, Equatable {
    case notStarted
    case initializing
    case running(serverInfo: ServerInfo?)
    case shuttingDown
    case shutdown
    case failed(reason: String)
}

// MARK: - LSPSessionError

/// Errors raised by `LSPSession`. Transport-level failures originating from
/// the embedded `LSPClient` are wrapped in `.clientError` so the caller can
/// recover the underlying `LSPClientError` cause when needed.
enum LSPSessionError: Error, Equatable {
    /// `start()` was called more than once on the same session.
    case alreadyStarted
    /// A textDocument operation was issued before `start()` reached
    /// `.running`.
    case notStarted
    /// A `didChange` / `didSave` / `didClose` referenced a URI that was
    /// never `didOpen`'d on this session (or has already been closed).
    case documentNotOpen(DocumentUri)
    /// The underlying `LSPClient` surfaced an error.
    case clientError(LSPClientError)
}

// MARK: - LSPSession

/// Actor owning the full LSP 3.18 lifecycle for one workspace + languageId.
actor LSPSession {

    // MARK: - Stored properties

    /// Workspace root URI used for `initialize.rootUri` / `workspaceFolders`.
    /// Set at init and never mutated, so it is safe to read without `await`.
    nonisolated let workspaceRoot: URL

    /// Default LSP `languageId` for this session (e.g. "swift", "rust"). Set
    /// at init and never mutated.
    nonisolated let languageId: String

    private let client: LSPClient
    private let clientCapabilities: ClientCapabilities
    private let clientInfo: ClientInfo
    private let capabilities: CapabilityRegistry
    private let progress: ProgressBroker

    private var sessionState: SessionState = .notStarted
    private var openDocs: Set<DocumentUri> = []

    // MARK: - Init

    init(
        workspaceRoot: URL,
        languageId: String,
        client: LSPClient,
        clientCapabilities: ClientCapabilities = ClientCapabilities(),
        clientInfo: ClientInfo = ClientInfo(name: "Calyx", version: "0.26.1")
    ) {
        self.workspaceRoot = workspaceRoot
        self.languageId = languageId
        self.client = client
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
        self.capabilities = CapabilityRegistry()
        self.progress = ProgressBroker()
    }

    // MARK: - Introspection

    /// Current lifecycle state.
    func state() -> SessionState {
        return sessionState
    }

    /// Set of URIs currently open on this session.
    func openDocuments() -> Set<DocumentUri> {
        return openDocs
    }

    /// Capability registry tracking the union of static + dynamic capabilities.
    func capabilityRegistry() -> CapabilityRegistry {
        return capabilities
    }

    /// Progress broker tracking work-done progress reservations and updates.
    func progressBroker() -> ProgressBroker {
        return progress
    }

    // MARK: - Lifecycle: start

    /// Run the `initialize` → `initialized` handshake.
    ///
    /// On success the session is left in `.running(serverInfo:)`. On any
    /// failure the session is left in `.failed(reason:)` and the underlying
    /// error is rethrown wrapped as `LSPSessionError.clientError(...)`.
    func start() async throws {
        guard case .notStarted = sessionState else {
            throw LSPSessionError.alreadyStarted
        }
        sessionState = .initializing

        do {
            // Begin pumping the transport so we can receive the initialize
            // response and any concurrent server-initiated traffic.
            try await client.start()

            // Install handlers for the server-initiated requests we care
            // about *before* sending initialize, in case the server
            // pipelines registrations onto the back of its response.
            await installServerRequestHandlers()

            let params = InitializeParams(
                processId: Int(ProcessInfo.processInfo.processIdentifier),
                capabilities: clientCapabilities,
                clientInfo: clientInfo,
                rootUri: .present(workspaceRoot.absoluteString),
                workspaceFolders: .present([
                    WorkspaceFolder(
                        uri: workspaceRoot.absoluteString,
                        name: workspaceRoot.lastPathComponent
                    )
                ])
            )

            let result = try await client.sendRequest(
                method: "initialize",
                params: params,
                resultType: InitializeResult.self
            )

            await capabilities.setStaticCapabilities(result.capabilities)
            sessionState = .running(serverInfo: result.serverInfo)

            try await client.sendNotification(
                method: "initialized",
                params: InitializedParams()
            )
        } catch let err as LSPClientError {
            sessionState = .failed(reason: String(describing: err))
            throw LSPSessionError.clientError(err)
        } catch {
            sessionState = .failed(reason: String(describing: error))
            throw error
        }
    }

    // MARK: - Lifecycle: shutdown

    /// Send `shutdown` then the `exit` notification, and close the
    /// underlying transport. Transitions the session to `.shutdown`.
    func shutdown() async throws {
        sessionState = .shuttingDown
        do {
            _ = try await client.sendRequest(
                method: "shutdown",
                resultType: AnyCodable.self
            )
            try await client.sendNotification(method: "exit")
            await client.close()
            sessionState = .shutdown
        } catch let err as LSPClientError {
            sessionState = .failed(reason: String(describing: err))
            throw LSPSessionError.clientError(err)
        } catch {
            sessionState = .failed(reason: String(describing: error))
            throw error
        }
    }

    // MARK: - textDocument lifecycle

    /// Notify the server of a freshly opened document. Re-opening a URI
    /// that is already tracked is a no-op (no duplicate notification).
    func didOpen(
        uri: DocumentUri,
        languageId: String,
        version: Int,
        text: String
    ) async throws {
        try ensureRunning()
        // Dedup: actor isolation only serialises non-suspending regions, so
        // we must mark the URI as open *before* the `await` below to block
        // reentrant callers from slipping past this contains-check while the
        // notification is in flight. On send failure we roll back so the
        // caller can retry.
        if openDocs.contains(uri) {
            return
        }
        openDocs.insert(uri)
        let params = DidOpenTextDocumentParams(
            textDocument: TextDocumentItem(
                uri: uri,
                languageId: languageId,
                version: version,
                text: text
            )
        )
        do {
            try await sendNotification(method: "textDocument/didOpen", params: params)
        } catch {
            openDocs.remove(uri)
            throw error
        }
    }

    /// Notify the server that an open document has changed. Throws
    /// `LSPSessionError.documentNotOpen` if the URI is not currently
    /// tracked.
    func didChange(
        uri: DocumentUri,
        version: Int,
        changes: [TextDocumentContentChangeEvent]
    ) async throws {
        try ensureRunning()
        guard openDocs.contains(uri) else {
            throw LSPSessionError.documentNotOpen(uri)
        }
        let params = DidChangeTextDocumentParams(
            textDocument: VersionedTextDocumentIdentifier(uri: uri, version: version),
            contentChanges: changes
        )
        try await sendNotification(method: "textDocument/didChange", params: params)
    }

    /// Notify the server that an open document has been closed.
    func didClose(uri: DocumentUri) async throws {
        try ensureRunning()
        guard openDocs.contains(uri) else {
            throw LSPSessionError.documentNotOpen(uri)
        }
        // Remove the URI from the open set *before* the `await` so concurrent
        // `didClose` calls don't both pass the guard and end up sending two
        // close notifications. Re-insert on send failure so the caller can
        // retry against a consistent in-memory state.
        openDocs.remove(uri)
        let params = DidCloseTextDocumentParams(
            textDocument: TextDocumentIdentifier(uri: uri)
        )
        do {
            try await sendNotification(method: "textDocument/didClose", params: params)
        } catch {
            openDocs.insert(uri)
            throw error
        }
    }

    /// Notify the server that an open document has been saved. `text` is
    /// passed verbatim — pass `nil` unless the server registered the
    /// `includeText: true` save option.
    func didSave(uri: DocumentUri, text: String?) async throws {
        try ensureRunning()
        guard openDocs.contains(uri) else {
            throw LSPSessionError.documentNotOpen(uri)
        }
        let params = DidSaveTextDocumentParams(
            textDocument: TextDocumentIdentifier(uri: uri),
            text: text
        )
        try await sendNotification(method: "textDocument/didSave", params: params)
    }

    // MARK: - Generic request / notification surface

    /// Send a typed LSP request through the embedded `LSPClient`. Used by
    /// higher layers (e.g. `MCPLSPBridge`) that map their own request
    /// vocabulary onto the LSP wire protocol. Transport-level failures
    /// from the client are surfaced as `LSPSessionError.clientError`.
    func sendRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params,
        resultType: Result.Type
    ) async throws -> Result {
        try ensureRunning()
        do {
            return try await client.sendRequest(
                method: method,
                params: params,
                resultType: resultType
            )
        } catch let err as LSPClientError {
            throw LSPSessionError.clientError(err)
        }
    }

    /// Send a parameterless LSP request through the embedded `LSPClient`.
    func sendRequest<Result: Decodable & Sendable>(
        method: String,
        resultType: Result.Type
    ) async throws -> Result {
        try ensureRunning()
        do {
            return try await client.sendRequest(
                method: method,
                resultType: resultType
            )
        } catch let err as LSPClientError {
            throw LSPSessionError.clientError(err)
        }
    }

    /// Public counterpart to the private `sendNotification(method:params:)`
    /// helper, exposed for callers that need to ship one-off notifications
    /// after the session has reached `.running`.
    func sendGenericNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws {
        try ensureRunning()
        try await sendNotification(method: method, params: params)
    }

    // MARK: - Private helpers

    private func ensureRunning() throws {
        switch sessionState {
        case .running:
            return
        default:
            throw LSPSessionError.notStarted
        }
    }

    private func sendNotification<Params: Encodable & Sendable>(
        method: String,
        params: Params
    ) async throws {
        do {
            try await client.sendNotification(method: method, params: params)
        } catch let err as LSPClientError {
            throw LSPSessionError.clientError(err)
        }
    }

    /// Install handlers for the server-originated requests the session
    /// reacts to (`client/registerCapability`,
    /// `client/unregisterCapability`, `window/workDoneProgress/create`).
    private func installServerRequestHandlers() async {
        let registry = self.capabilities
        let broker = self.progress

        await client.setRequestHandler(method: "client/registerCapability") { params in
            let raw = params ?? AnyCodable(NSNull())
            let data = try JSONEncoder().encode(raw)
            let regParams = try JSONDecoder().decode(RegistrationParams.self, from: data)
            await registry.register(regParams.registrations)
            return nil
        }

        await client.setRequestHandler(method: "client/unregisterCapability") { params in
            let raw = params ?? AnyCodable(NSNull())
            let data = try JSONEncoder().encode(raw)
            let unregParams = try JSONDecoder().decode(UnregistrationParams.self, from: data)
            await registry.unregister(unregParams.unregistrations)
            return nil
        }

        await client.setRequestHandler(method: "window/workDoneProgress/create") { params in
            let raw = params ?? AnyCodable(NSNull())
            let data = try JSONEncoder().encode(raw)
            let createParams = try JSONDecoder().decode(WorkDoneProgressCreateParams.self, from: data)
            await broker.registerToken(createParams.token)
            return nil
        }
    }
}

// MARK: - WorkDoneProgressCreateParams

/// LSP 3.18 `window/workDoneProgress/create` request params. Not previously
/// modelled in `LSPTypes/`; declared inline here because `LSPSession` is the
/// only consumer.
///
/// Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create
private struct WorkDoneProgressCreateParams: Sendable, Codable, Equatable {
    let token: ProgressToken
}
