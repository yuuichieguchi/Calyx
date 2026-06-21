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

// MARK: - ServerLogEntry

/// A single entry in the session-local server message log. Captures the
/// payload of `window/showMessage`, `window/logMessage`,
/// `window/showMessageRequest` and `window/showDocument` traffic so callers
/// (CLI, MCP bridge, UI) can review what the server has reported.
///
/// `type` follows the LSP `MessageType` enum: `1=Error 2=Warning 3=Info
/// 4=Log`. `showDocument` does not carry a `MessageType`, so the session
/// records it as `0` and stores the requested URI in `message`.
struct ServerLogEntry: Sendable, Equatable {
    enum Source: String, Sendable, Codable {
        case showMessage
        case showMessageRequest
        case showDocument
        case logMessage
    }
    let source: Source
    let type: Int
    let message: String
}

// MARK: - PendingApplyEdit

/// A `workspace/applyEdit` request that the server has issued and the
/// session has buffered for downstream review. The session always responds
/// to the wire request with `{ "applied": false }` so the AI / UI can opt
/// in to applying the edit out-of-band; the buffered entries live here
/// until `consumePendingApplyEdit(id:)` drains them.
struct PendingApplyEdit: Sendable {
    /// Monotonically increasing, session-local identifier. Distinct from
    /// the JSON-RPC request id (which is owned by `LSPClient`).
    let id: Int
    /// Optional human-readable label supplied by the server.
    let label: String?
    /// Raw `WorkspaceEdit` payload.
    let edit: AnyCodable
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
    /// Optional persistence store. When non-nil the session writes a fresh
    /// snapshot (workspace + language + currently-open URIs) on every
    /// `didOpen` / `didClose` and removes the entry on `shutdown()`, so
    /// callers can rebuild the open-file set across application launches.
    private let persistence: LSPSessionPersistence?

    private var sessionState: SessionState = .notStarted
    private var openDocs: Set<DocumentUri> = []

    /// Buffered server-originated message log (showMessage / logMessage /
    /// showMessageRequest / showDocument). FIFO, capped at
    /// `serverMessagesCap`.
    private var serverMessages: [ServerLogEntry] = []
    private let serverMessagesCap = 100

    /// `workspace/applyEdit` requests the server has issued, in arrival
    /// order. Drained by callers via `consumePendingApplyEdit(id:)`.
    private var pendingApplyEditQueue: [PendingApplyEdit] = []

    /// Monotonic id source for `PendingApplyEdit.id`. Session-local.
    private var nextApplyEditId: Int = 1

    // MARK: - Init

    init(
        workspaceRoot: URL,
        languageId: String,
        client: LSPClient,
        clientCapabilities: ClientCapabilities = ClientCapabilities.calyxDefault(),
        clientInfo: ClientInfo = ClientInfo(name: "Calyx", version: "0.26.1"),
        persistence: LSPSessionPersistence? = nil
    ) {
        self.workspaceRoot = workspaceRoot
        self.languageId = languageId
        self.client = client
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
        self.capabilities = CapabilityRegistry()
        self.progress = ProgressBroker()
        self.persistence = persistence
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

    /// Snapshot of the buffered server message log (FIFO, capped at the
    /// session-configured maximum). Oldest-first.
    func recentServerMessages() -> [ServerLogEntry] {
        return serverMessages
    }

    /// Snapshot of the pending `workspace/applyEdit` queue.
    func pendingApplyEdits() -> [PendingApplyEdit] {
        return pendingApplyEditQueue
    }

    /// Drop every buffered server message. Used by callers (CLI / MCP /
    /// UI) that have rendered the log and want a fresh window.
    func clearServerMessages() {
        serverMessages.removeAll()
    }

    /// Remove the pending `workspace/applyEdit` entry whose session-local
    /// id matches `id`. No-op if no such entry exists.
    func consumePendingApplyEdit(id: Int) {
        pendingApplyEditQueue.removeAll { $0.id == id }
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
        scheduleRemoveSnapshot()
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
        schedulePersistSnapshot()
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
        schedulePersistSnapshot()
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

    // MARK: - Persistence helpers

    /// Build a `SessionSnapshot` describing this session's current
    /// (workspaceRoot, languageId, openFiles) tuple. `initializationOptions`
    /// is reserved for a future extension that surfaces user-supplied
    /// init options; the session emits `nil` today. `savedAtUptimeMillis`
    /// is sampled from `ProcessInfo.processInfo.systemUptime` so callers
    /// can perform staleness checks across launches.
    private func currentSnapshot() -> LSPSessionPersistence.SessionSnapshot {
        LSPSessionPersistence.SessionSnapshot(
            workspaceRoot: workspaceRoot,
            languageId: languageId,
            openFiles: Array(openDocs),
            initializationOptions: nil,
            savedAtUptimeMillis: Int64(ProcessInfo.processInfo.systemUptime * 1000)
        )
    }

    /// Fire-and-forget persist of the current snapshot. No-op when the
    /// session was constructed without a persistence store. The snapshot is
    /// captured synchronously while the actor is held, then handed to a
    /// detached Task so the persist I/O does not block the calling
    /// notification path.
    private func schedulePersistSnapshot() {
        guard let persistence else { return }
        let snap = currentSnapshot()
        Task {
            try? await persistence.persist(snap)
        }
    }

    /// Fire-and-forget removal of this session's persisted entry. No-op
    /// when the session was constructed without a persistence store.
    /// Captures `workspaceRoot` / `languageId` into Sendable locals so the
    /// background Task does not need to reach back into the actor.
    private func scheduleRemoveSnapshot() {
        guard let persistence else { return }
        let ws = workspaceRoot
        let lang = languageId
        Task {
            try? await persistence.remove(workspaceRoot: ws, languageId: lang)
        }
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

        // The handlers below capture `self` strongly so the session — and
        // by transitive ownership the underlying `LSPClient` and its
        // receive task — stay alive for as long as the server can deliver
        // traffic. The intentional retain cycle `LSPSession ↔ LSPClient ↔
        // handler closure ↔ LSPSession` is broken when the application
        // calls `shutdown()`, which closes the transport so the receive
        // task drains and exits and then transitions the session to
        // `.shutdown`. The existing handlers above use sub-actor captures
        // (`registry`, `broker`) and so do not contribute to the cycle.

        // window/showMessage — notification. Buffer into the server log.
        // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessage
        await client.setNotificationHandler(method: "window/showMessage") { [self] params in
            guard let params = params else { return }
            let parsed = await self.decodeMessageParams(params)
            await self.appendServerMessage(
                ServerLogEntry(source: .showMessage, type: parsed.type, message: parsed.message)
            )
        }

        // window/logMessage — notification. Buffer into the server log.
        // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_logMessage
        await client.setNotificationHandler(method: "window/logMessage") { [self] params in
            guard let params = params else { return }
            let parsed = await self.decodeMessageParams(params)
            await self.appendServerMessage(
                ServerLogEntry(source: .logMessage, type: parsed.type, message: parsed.message)
            )
        }

        // window/showMessageRequest — request. Buffer into the server log
        // and reply with `null` (no user selection at the session level).
        // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showMessageRequest
        await client.setRequestHandler(method: "window/showMessageRequest") { [self] params in
            guard let params = params else { return nil }
            let parsed = await self.decodeMessageParams(params)
            await self.appendServerMessage(
                ServerLogEntry(source: .showMessageRequest, type: parsed.type, message: parsed.message)
            )
            return nil
        }

        // window/showDocument — request. Buffer the URI into the server log
        // and acknowledge with `{ "success": true }`. The session does not
        // actually open the document; downstream layers decide.
        // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_showDocument
        await client.setRequestHandler(method: "window/showDocument") { [self] params in
            let uri = await self.extractURIFromParams(params)
            await self.appendServerMessage(
                ServerLogEntry(source: .showDocument, type: 0, message: uri)
            )
            return AnyCodable(["success": AnyCodable(true)] as [String: AnyCodable])
        }

        // workspace/configuration — request. Reply with a JSON array of
        // `null`s, one per requested item. Higher layers may later supply
        // real configuration values.
        // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_configuration
        await client.setRequestHandler(method: "workspace/configuration") { [self] params in
            let count = await self.configurationItemCount(params)
            let nulls: [AnyCodable] = (0..<count).map { _ in AnyCodable(NSNull()) }
            return AnyCodable(nulls)
        }

        // workspace/applyEdit — request. The session does not apply edits
        // directly; it buffers them onto `pendingApplyEditQueue` and
        // responds `{ "applied": false }`. The AI / UI consumes the queue
        // and applies edits out-of-band.
        // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_applyEdit
        await client.setRequestHandler(method: "workspace/applyEdit") { [self] params in
            let response = AnyCodable(["applied": AnyCodable(false)] as [String: AnyCodable])
            guard let params = params else { return response }
            let label = await self.extractLabel(from: params)
            let edit = await self.extractEdit(from: params) ?? AnyCodable([String: AnyCodable]())
            _ = await self.enqueueApplyEdit(label: label, edit: edit)
            return response
        }

        // workspace/workspaceFolders — request. Report the single folder
        // this session was constructed against.
        // Spec: https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_workspaceFolders
        await client.setRequestHandler(method: "workspace/workspaceFolders") { [self] _ in
            let root = self.workspaceRoot
            let folder: [String: AnyCodable] = [
                "uri": AnyCodable(root.absoluteString),
                "name": AnyCodable(root.lastPathComponent)
            ]
            return AnyCodable([AnyCodable(folder)])
        }
    }

    // MARK: - Server message log helpers

    /// Append `entry` to the buffered server message log, evicting the
    /// oldest entries when the cap is exceeded.
    private func appendServerMessage(_ entry: ServerLogEntry) {
        serverMessages.append(entry)
        if serverMessages.count > serverMessagesCap {
            serverMessages.removeFirst(serverMessages.count - serverMessagesCap)
        }
    }

    /// Append a new `PendingApplyEdit` to the queue and return its
    /// session-local id.
    @discardableResult
    private func enqueueApplyEdit(label: String?, edit: AnyCodable) -> Int {
        let id = nextApplyEditId
        nextApplyEditId += 1
        pendingApplyEditQueue.append(PendingApplyEdit(id: id, label: label, edit: edit))
        return id
    }

    /// Pull `(type, message)` out of an LSP `ShowMessageParams` /
    /// `LogMessageParams` / `ShowMessageRequestParams` payload. Falls back
    /// to `(4, "")` (Log severity, empty message) when the payload can't
    /// be parsed at all — see the test plan, which pins this behaviour.
    private func decodeMessageParams(_ params: AnyCodable) -> (type: Int, message: String) {
        guard let data = try? JSONEncoder().encode(params),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (4, "")
        }
        let type: Int
        if let i = json["type"] as? Int {
            type = i
        } else if let d = json["type"] as? Double {
            type = Int(d)
        } else {
            type = 4
        }
        let message = (json["message"] as? String) ?? ""
        return (type, message)
    }

    /// Extract `uri` from a `ShowDocumentParams` payload. Returns the empty
    /// string when the URI is missing or the payload is malformed.
    private func extractURIFromParams(_ params: AnyCodable?) -> String {
        guard let params,
              let data = try? JSONEncoder().encode(params),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return (json["uri"] as? String) ?? ""
    }

    /// Count the `items` array in a `workspace/configuration` payload.
    /// Returns 0 when `items` is missing.
    private func configurationItemCount(_ params: AnyCodable?) -> Int {
        guard let params,
              let data = try? JSONEncoder().encode(params),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [Any] else {
            return 0
        }
        return items.count
    }

    /// Extract the optional `label` field from an `ApplyWorkspaceEditParams`
    /// payload.
    private func extractLabel(from params: AnyCodable) -> String? {
        guard let data = try? JSONEncoder().encode(params),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["label"] as? String
    }

    /// Extract the `edit` field (a `WorkspaceEdit`) from an
    /// `ApplyWorkspaceEditParams` payload, preserving its structure as
    /// `AnyCodable` so downstream callers can re-encode it verbatim.
    private func extractEdit(from params: AnyCodable) -> AnyCodable? {
        guard let data = try? JSONEncoder().encode(params),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let edit = json["edit"] else {
            return nil
        }
        return AnyCodable(edit)
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

// MARK: - ClientCapabilities.calyxDefault

extension ClientCapabilities {
    /// Calyx default: declares support for the full surface that
    /// `MCPLSPBridge` exposes. Used as the default value for
    /// `LSPSession.init(clientCapabilities:)` so production sessions always
    /// negotiate the complete capability set rather than the empty
    /// `ClientCapabilities()` placeholder.
    ///
    /// Mirrors the LSP 3.18 "maximal client" capability JSON. Sub-trees are
    /// modelled as `AnyCodable` literals because `ClientCapabilities` keeps
    /// each field as `AnyCodable?` pending fine-grained Codable modelling.
    static func calyxDefault() -> ClientCapabilities {
        let workspace: AnyCodable = AnyCodable([
            "applyEdit": AnyCodable(true),
            "workspaceEdit": AnyCodable([
                "documentChanges": AnyCodable(true),
                "resourceOperations": AnyCodable([AnyCodable("create"), AnyCodable("rename"), AnyCodable("delete")]),
                "failureHandling": AnyCodable("textOnlyTransactional"),
                "normalizesLineEndings": AnyCodable(true),
                "changeAnnotationSupport": AnyCodable(["groupsOnLabel": AnyCodable(true)]),
            ] as [String: AnyCodable]),
            "didChangeConfiguration": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "didChangeWatchedFiles": AnyCodable(["dynamicRegistration": AnyCodable(true), "relativePatternSupport": AnyCodable(true)]),
            "symbol": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "symbolKind": AnyCodable([
                    "valueSet": AnyCodable((1...26).map { AnyCodable($0) }),
                ]),
                "tagSupport": AnyCodable(["valueSet": AnyCodable([AnyCodable(1)])]),
                "resolveSupport": AnyCodable(["properties": AnyCodable([AnyCodable("location.range")])]),
            ] as [String: AnyCodable]),
            "executeCommand": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "workspaceFolders": AnyCodable(true),
            "configuration": AnyCodable(true),
            "semanticTokens": AnyCodable(["refreshSupport": AnyCodable(true)]),
            "codeLens": AnyCodable(["refreshSupport": AnyCodable(true)]),
            "fileOperations": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "didCreate": AnyCodable(true),
                "willCreate": AnyCodable(true),
                "didRename": AnyCodable(true),
                "willRename": AnyCodable(true),
                "didDelete": AnyCodable(true),
                "willDelete": AnyCodable(true),
            ] as [String: AnyCodable]),
            "inlineValue": AnyCodable(["refreshSupport": AnyCodable(true)]),
            "inlayHint": AnyCodable(["refreshSupport": AnyCodable(true)]),
            "diagnostics": AnyCodable(["refreshSupport": AnyCodable(true)]),
        ] as [String: AnyCodable])

        let textDocument: AnyCodable = AnyCodable([
            "synchronization": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "willSave": AnyCodable(true),
                "willSaveWaitUntil": AnyCodable(true),
                "didSave": AnyCodable(true),
            ] as [String: AnyCodable]),
            "completion": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "completionItem": AnyCodable([
                    "snippetSupport": AnyCodable(true),
                    "commitCharactersSupport": AnyCodable(true),
                    "documentationFormat": AnyCodable([AnyCodable("markdown"), AnyCodable("plaintext")]),
                    "deprecatedSupport": AnyCodable(true),
                    "preselectSupport": AnyCodable(true),
                    "tagSupport": AnyCodable(["valueSet": AnyCodable([AnyCodable(1)])]),
                    "insertReplaceSupport": AnyCodable(true),
                    "resolveSupport": AnyCodable(["properties": AnyCodable([AnyCodable("documentation"), AnyCodable("detail"), AnyCodable("additionalTextEdits")])]),
                    "insertTextModeSupport": AnyCodable(["valueSet": AnyCodable([AnyCodable(1), AnyCodable(2)])]),
                    "labelDetailsSupport": AnyCodable(true),
                ] as [String: AnyCodable]),
                "completionItemKind": AnyCodable(["valueSet": AnyCodable((1...25).map { AnyCodable($0) })]),
                "contextSupport": AnyCodable(true),
                "insertTextMode": AnyCodable(2),
                "completionList": AnyCodable(["itemDefaults": AnyCodable([AnyCodable("commitCharacters"), AnyCodable("editRange"), AnyCodable("insertTextFormat"), AnyCodable("insertTextMode"), AnyCodable("data")])]),
            ] as [String: AnyCodable]),
            "hover": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "contentFormat": AnyCodable([AnyCodable("markdown"), AnyCodable("plaintext")]),
            ] as [String: AnyCodable]),
            "signatureHelp": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "signatureInformation": AnyCodable([
                    "documentationFormat": AnyCodable([AnyCodable("markdown"), AnyCodable("plaintext")]),
                    "parameterInformation": AnyCodable(["labelOffsetSupport": AnyCodable(true)]),
                    "activeParameterSupport": AnyCodable(true),
                ] as [String: AnyCodable]),
                "contextSupport": AnyCodable(true),
            ] as [String: AnyCodable]),
            "declaration": AnyCodable(["dynamicRegistration": AnyCodable(true), "linkSupport": AnyCodable(true)]),
            "definition": AnyCodable(["dynamicRegistration": AnyCodable(true), "linkSupport": AnyCodable(true)]),
            "typeDefinition": AnyCodable(["dynamicRegistration": AnyCodable(true), "linkSupport": AnyCodable(true)]),
            "implementation": AnyCodable(["dynamicRegistration": AnyCodable(true), "linkSupport": AnyCodable(true)]),
            "references": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "documentHighlight": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "documentSymbol": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "symbolKind": AnyCodable(["valueSet": AnyCodable((1...26).map { AnyCodable($0) })]),
                "hierarchicalDocumentSymbolSupport": AnyCodable(true),
                "tagSupport": AnyCodable(["valueSet": AnyCodable([AnyCodable(1)])]),
                "labelSupport": AnyCodable(true),
            ] as [String: AnyCodable]),
            "codeAction": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "codeActionLiteralSupport": AnyCodable([
                    "codeActionKind": AnyCodable([
                        "valueSet": AnyCodable([AnyCodable(""), AnyCodable("quickfix"), AnyCodable("refactor"), AnyCodable("refactor.extract"), AnyCodable("refactor.inline"), AnyCodable("refactor.rewrite"), AnyCodable("source"), AnyCodable("source.organizeImports"), AnyCodable("source.fixAll")]),
                    ] as [String: AnyCodable]),
                ] as [String: AnyCodable]),
                "isPreferredSupport": AnyCodable(true),
                "disabledSupport": AnyCodable(true),
                "dataSupport": AnyCodable(true),
                "resolveSupport": AnyCodable(["properties": AnyCodable([AnyCodable("edit")])]),
                "honorsChangeAnnotations": AnyCodable(true),
            ] as [String: AnyCodable]),
            "codeLens": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "documentLink": AnyCodable(["dynamicRegistration": AnyCodable(true), "tooltipSupport": AnyCodable(true)]),
            "colorProvider": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "formatting": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "rangeFormatting": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "onTypeFormatting": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "rename": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "prepareSupport": AnyCodable(true),
                "prepareSupportDefaultBehavior": AnyCodable(1),
                "honorsChangeAnnotations": AnyCodable(true),
            ] as [String: AnyCodable]),
            "publishDiagnostics": AnyCodable([
                "relatedInformation": AnyCodable(true),
                "tagSupport": AnyCodable(["valueSet": AnyCodable([AnyCodable(1), AnyCodable(2)])]),
                "versionSupport": AnyCodable(true),
                "codeDescriptionSupport": AnyCodable(true),
                "dataSupport": AnyCodable(true),
            ] as [String: AnyCodable]),
            "foldingRange": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "rangeLimit": AnyCodable(5000),
                "lineFoldingOnly": AnyCodable(false),
                "foldingRangeKind": AnyCodable(["valueSet": AnyCodable([AnyCodable("comment"), AnyCodable("imports"), AnyCodable("region")])]),
                "foldingRange": AnyCodable(["collapsedText": AnyCodable(true)]),
            ] as [String: AnyCodable]),
            "selectionRange": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "linkedEditingRange": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "callHierarchy": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "semanticTokens": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "requests": AnyCodable([
                    "range": AnyCodable(true),
                    "full": AnyCodable(["delta": AnyCodable(true)]),
                ] as [String: AnyCodable]),
                "tokenTypes": AnyCodable([
                    AnyCodable("namespace"), AnyCodable("type"), AnyCodable("class"), AnyCodable("enum"), AnyCodable("interface"), AnyCodable("struct"), AnyCodable("typeParameter"), AnyCodable("parameter"), AnyCodable("variable"), AnyCodable("property"), AnyCodable("enumMember"), AnyCodable("event"), AnyCodable("function"), AnyCodable("method"), AnyCodable("macro"), AnyCodable("keyword"), AnyCodable("modifier"), AnyCodable("comment"), AnyCodable("string"), AnyCodable("number"), AnyCodable("regexp"), AnyCodable("operator"), AnyCodable("decorator"),
                ]),
                "tokenModifiers": AnyCodable([
                    AnyCodable("declaration"), AnyCodable("definition"), AnyCodable("readonly"), AnyCodable("static"), AnyCodable("deprecated"), AnyCodable("abstract"), AnyCodable("async"), AnyCodable("modification"), AnyCodable("documentation"), AnyCodable("defaultLibrary"),
                ]),
                "formats": AnyCodable([AnyCodable("relative")]),
                "overlappingTokenSupport": AnyCodable(false),
                "multilineTokenSupport": AnyCodable(false),
                "serverCancelSupport": AnyCodable(true),
                "augmentsSyntaxTokens": AnyCodable(true),
            ] as [String: AnyCodable]),
            "moniker": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "typeHierarchy": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "inlineValue": AnyCodable(["dynamicRegistration": AnyCodable(true)]),
            "inlayHint": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "resolveSupport": AnyCodable(["properties": AnyCodable([AnyCodable("tooltip"), AnyCodable("textEdits"), AnyCodable("label.tooltip"), AnyCodable("label.location"), AnyCodable("label.command")])]),
            ] as [String: AnyCodable]),
            "diagnostic": AnyCodable([
                "dynamicRegistration": AnyCodable(true),
                "relatedDocumentSupport": AnyCodable(true),
            ] as [String: AnyCodable]),
        ] as [String: AnyCodable])

        let window: AnyCodable = AnyCodable([
            "workDoneProgress": AnyCodable(true),
            "showMessage": AnyCodable(["messageActionItem": AnyCodable(["additionalPropertiesSupport": AnyCodable(true)])]),
            "showDocument": AnyCodable(["support": AnyCodable(true)]),
        ] as [String: AnyCodable])

        let general: AnyCodable = AnyCodable([
            "staleRequestSupport": AnyCodable(["cancel": AnyCodable(true), "retryOnContentModified": AnyCodable([] as [AnyCodable])]),
            "regularExpressions": AnyCodable(["engine": AnyCodable("ECMAScript"), "version": AnyCodable("ES2020")]),
            "markdown": AnyCodable(["parser": AnyCodable("marked"), "version": AnyCodable("1.1.0")]),
            "positionEncodings": AnyCodable([AnyCodable("utf-16")]),
        ] as [String: AnyCodable])

        return ClientCapabilities(
            workspace: workspace,
            textDocument: textDocument,
            notebookDocument: nil,
            window: window,
            general: general,
            experimental: nil
        )
    }
}
