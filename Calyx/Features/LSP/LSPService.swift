//
//  LSPService.swift
//  Calyx
//
//  Main-actor facade the Calyx MCP layer uses to obtain a started,
//  ready-to-use `LSPSession` for a given (workspace root, languageId)
//  pair.
//
//  Responsibilities:
//    - Registry lookup: validates the `languageId` against the bundled
//      `LSPServerRegistry`.
//    - Auto-install bridge: when the server binary is not on PATH the
//      service consults `LSPInstaller` (respecting `config.autoInstall`
//      and `config.installConfirmation`).
//    - Session cache: warm `(workspaceRoot, languageId)` pairs reuse the
//      same `LSPSession`. Concurrent `session(for:)` calls dedup onto a
//      single in-flight build.
//    - LRU + idle eviction: capped by `config.maxConcurrentSessions`
//      with a background timer that retires sessions idle for longer
//      than `config.idleTimeoutSeconds`.
//
//  All five surface types co-habit this file by design — they form one
//  tight orchestration layer and are easier to read together.
//

import Foundation

// MARK: - LSPServiceConfig

/// Tuning knobs for `LSPService`. `installConfirmation` may carry a
/// closure (`.prompt`), so the config is intentionally not `Equatable`.
struct LSPServiceConfig: Sendable {
    /// Sessions untouched for this many seconds are shut down by the
    /// background idle timer.
    let idleTimeoutSeconds: Int
    /// Hard cap on cached sessions; exceeding the cap evicts the
    /// least-recently-used entry.
    let maxConcurrentSessions: Int
    /// When `true`, `session(for:)` will attempt an install via
    /// `LSPInstaller` if the executable is missing on PATH.
    let autoInstall: Bool
    /// Forwarded verbatim to `LSPInstaller.install(...)` when an
    /// install is required.
    let installConfirmation: ConfirmationMode

    init(
        idleTimeoutSeconds: Int = 1800,
        maxConcurrentSessions: Int = 16,
        autoInstall: Bool = true,
        installConfirmation: ConfirmationMode = .silent
    ) {
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.maxConcurrentSessions = maxConcurrentSessions
        self.autoInstall = autoInstall
        self.installConfirmation = installConfirmation
    }
}

// MARK: - LSPServiceError

/// Failures surfaced from `LSPService.session(for:languageId:)`.
enum LSPServiceError: Error, Equatable {
    /// `languageId` is not present in the configured `LSPServerRegistry`.
    case languageNotInRegistry(languageId: String)
    /// The language server executable is not on PATH and either
    /// `autoInstall` was disabled or the install attempt did not
    /// complete successfully.
    case languageServerNotAvailable(languageId: String, reason: String)
    /// The supplied workspace root is not usable as an LSP root URI
    /// (reserved for future validation; not raised by current code).
    case workspaceRootInvalid(URL)
    /// `LSPSession.start()` failed — the embedded `LSPClient` could not
    /// complete the `initialize` handshake.
    case sessionStartFailed(reason: String)
}

// MARK: - LSPSessionFactory

/// Indirection used by `LSPService` to construct an `LSPClient`.
/// Production code wires a real `Process`-backed stdio transport; tests
/// inject an in-memory transport so no external process is spawned.
protocol LSPSessionFactory: Sendable {
    func makeClient(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?
    ) async throws -> LSPClient
}

// MARK: - LSPSessionInfo

/// Snapshot of one cached session, returned by `currentSessions()`.
struct LSPSessionInfo: Sendable, Equatable {
    let workspaceRoot: URL
    let languageId: String
    let state: SessionState
    /// `ProcessInfo.processInfo.systemUptime` (in milliseconds) at the
    /// moment the session was inserted into the cache.
    let createdAtUptimeMillis: Int64
}

// MARK: - LSPService

/// Main-actor orchestrator owning the (workspace, language) → session
/// cache, install bridging, LRU policy and idle eviction.
@MainActor
final class LSPService {

    // MARK: Composite cache key

    private struct SessionKey: Hashable, Sendable {
        let workspaceRoot: URL
        let languageId: String
    }

    /// One cached session plus its LRU + uptime bookkeeping. Reference
    /// type so we can mutate `lastAccessed` in place without copying the
    /// dictionary value.
    private final class SessionEntry {
        let session: LSPSession
        var lastAccessed: Date
        let createdAtUptimeMillis: Int64

        init(session: LSPSession, lastAccessed: Date, createdAtUptimeMillis: Int64) {
            self.session = session
            self.lastAccessed = lastAccessed
            self.createdAtUptimeMillis = createdAtUptimeMillis
        }
    }

    // MARK: Stored properties

    private let registry: LSPServerRegistry
    private let installer: LSPInstaller?
    private let sessionFactory: any LSPSessionFactory
    private let config: LSPServiceConfig
    /// Optional file-system synchroniser. When non-nil every freshly
    /// built session registers its `workspaceRoot` with the manager so
    /// LSP `textDocument` / `workspace` notifications fire in response
    /// to on-disk changes. Tearing a session down (`shutdownSession`,
    /// `shutdownAll`) routes a matching `unwatch` / `stopAll` through
    /// the manager so the FSEvents stream is released.
    private let fileSyncManager: FileSyncManager?
    /// Optional session persistence store. When non-nil, every session
    /// built via `buildSession` is constructed with the same store, so
    /// post-build `didOpen` / `didClose` activity surfaces in the store
    /// returned by `availableSnapshots()`. When `nil`, persistence is
    /// disabled end-to-end and `availableSnapshots()` returns `[]`.
    private let persistence: LSPSessionPersistence?
    /// Optional diagnostics aggregator shared across every session built
    /// by this service. When non-nil, each session installs a
    /// `textDocument/publishDiagnostics` notification handler that
    /// ingests publishes into the store keyed on the session's own
    /// `workspaceRoot`. The store is owned externally (typically by the
    /// `MCPLSPBridge`) so reads via `lsp_diagnostics_diff` see a
    /// workspace-wide view that outlives any individual session.
    private let diagnosticsStore: DiagnosticsStore?

    private var sessions: [SessionKey: SessionEntry] = [:]
    /// In-flight builds keyed by `SessionKey` so concurrent
    /// `session(for:)` calls dedup onto one build.
    private var inProgressSessions: [SessionKey: Task<LSPSession, Error>] = [:]
    /// Background loop that retires idle sessions. Lazily started on
    /// first cache insertion.
    private var idleTimerTask: Task<Void, Never>?
    /// Set to `true` when `shutdownAll()` runs. `buildSession` consults this
    /// flag after `session.start()` returns; if shutdown ran while the
    /// handshake was still pending the freshly-started session is shut down
    /// in-place instead of being inserted into the cache. The flag is
    /// terminal — once set, no further `session(for:)` build will succeed,
    /// matching the documented semantics of `shutdownAll()` ("Shut down
    /// every cached session and stop the idle timer").
    private var isShutdown = false

    // MARK: Init

    init(
        registry: LSPServerRegistry = .builtIn(),
        installer: LSPInstaller? = nil,
        sessionFactory: any LSPSessionFactory,
        config: LSPServiceConfig = LSPServiceConfig(),
        fileSyncManager: FileSyncManager? = nil,
        persistence: LSPSessionPersistence? = nil,
        diagnosticsStore: DiagnosticsStore? = nil
    ) {
        self.registry = registry
        self.installer = installer
        self.sessionFactory = sessionFactory
        self.config = config
        self.fileSyncManager = fileSyncManager
        self.persistence = persistence
        self.diagnosticsStore = diagnosticsStore
    }

    // MARK: Public API

    /// Returns a `running` `LSPSession` for `(workspaceRoot, languageId)`.
    /// Reuses a cached instance when one is already open, dedups parallel
    /// build attempts, and triggers auto-install when configured.
    func session(for workspaceRoot: URL, languageId: String) async throws -> LSPSession {
        // Post-shutdown short-circuit. `shutdownAll()` is a terminal
        // transition — once it has run, the service must not spawn
        // additional `LSPClient` processes or FSEvents watches. Bail
        // before the cache lookup so a session(for:) call that lands
        // after `shutdownAll()` fails fast without touching the
        // factory or installer.
        if isShutdown {
            throw LSPServiceError.sessionStartFailed(
                reason: "LSPService has been shut down"
            )
        }

        let key = SessionKey(workspaceRoot: workspaceRoot, languageId: languageId)

        // 1. Warm cache hit — refresh LRU timestamp and return.
        if let entry = sessions[key] {
            entry.lastAccessed = Date()
            return entry.session
        }

        // 2. Build already in flight for this key — share it.
        if let inflight = inProgressSessions[key] {
            return try await inflight.value
        }

        // 3. Kick off a new build and remember the Task so concurrent
        //    callers can join.
        let task = Task<LSPSession, Error> { [self] in
            try await self.buildSession(for: key)
        }
        inProgressSessions[key] = task

        do {
            let session = try await task.value
            inProgressSessions[key] = nil
            return session
        } catch {
            inProgressSessions[key] = nil
            throw error
        }
    }

    /// Snapshot of every open session.
    func currentSessions() async -> [LSPSessionInfo] {
        var out: [LSPSessionInfo] = []
        out.reserveCapacity(sessions.count)
        for (key, entry) in sessions {
            let state = await entry.session.state()
            out.append(LSPSessionInfo(
                workspaceRoot: key.workspaceRoot,
                languageId: key.languageId,
                state: state,
                createdAtUptimeMillis: entry.createdAtUptimeMillis
            ))
        }
        return out
    }

    /// Snapshots persisted to the configured `LSPSessionPersistence`
    /// store, suitable for restoring open documents on a fresh launch.
    /// Returns `[]` when this service was constructed without a
    /// persistence store, so callers can opt out of restoration without
    /// branching on the configuration.
    func availableSnapshots() async -> [LSPSessionPersistence.SessionSnapshot] {
        await persistence?.load() ?? []
    }

    /// Direct snapshot of every cached `LSPSession` value. Distinct from
    /// `currentSessions()` (which returns metadata DTOs); this accessor
    /// hands back the live session references so MCP bridge tools that
    /// fan out across every workspace (`lsp_global_workspace_symbol`) can
    /// dispatch requests without going through the keyed `session(for:)`
    /// path. Does not bump LRU timestamps and does not touch the cache.
    func allSessions() -> [LSPSession] {
        sessions.values.map { $0.session }
    }

    /// Shut down and forget the session for `(workspaceRoot, languageId)`.
    /// A subsequent `session(for:)` call will rebuild from scratch.
    func shutdownSession(workspaceRoot: URL, languageId: String) async {
        let key = SessionKey(workspaceRoot: workspaceRoot, languageId: languageId)

        // Cancel any in-flight build for this key. We do NOT await the
        // cancelled task here: `LSPClient.sendRequest` parks on a
        // non-cancellation-aware continuation, so a build stuck on
        // `initialize` would deadlock the caller of `shutdownSession`.
        // The `Task.isCancelled` check `buildSession` runs after
        // `session.start()` returns guarantees the freshly-built session
        // is torn down in-place instead of slipping into the cache.
        if let pending = inProgressSessions.removeValue(forKey: key) {
            pending.cancel()
        }

        guard let entry = sessions.removeValue(forKey: key) else { return }
        if let fileSyncManager {
            Task {
                await fileSyncManager.unwatch(workspaceRoot: workspaceRoot)
            }
        }
        try? await entry.session.shutdown()
    }

    /// Shut down every cached session and stop the idle timer.
    func shutdownAll() async {
        // Mark the service as shut down *before* cancelling pending tasks so
        // any build that resumes mid-tear-down sees the flag and bails via
        // the post-`start` check in `buildSession`.
        isShutdown = true

        // Cancel every in-flight build. Same rationale as
        // `shutdownSession`: do not await the cancelled tasks — the LSP
        // client's request continuation isn't cancellation-aware and a
        // hung `initialize` would deadlock shutdownAll().
        let pendingBuilds = Array(inProgressSessions.values)
        inProgressSessions.removeAll()
        for task in pendingBuilds {
            task.cancel()
        }

        // Snapshot the actor references (Sendable) — `SessionEntry` is a
        // MainActor-accessible reference type, so we must not capture it
        // inside a concurrent child task.
        let liveSessions: [LSPSession] = sessions.values.map { $0.session }
        sessions.removeAll()
        idleTimerTask?.cancel()
        idleTimerTask = nil

        // Tear down every registered watch in one shot. `stopAll`
        // clears the manager's internal `watchedRoots_` map and stops
        // the underlying event source, so we don't need to snapshot
        // individual workspace keys.
        if let fileSyncManager {
            Task {
                await fileSyncManager.stopAll()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for session in liveSessions {
                group.addTask {
                    try? await session.shutdown()
                }
            }
        }
    }

    // MARK: - Private: build pipeline

    private func buildSession(for key: SessionKey) async throws -> LSPSession {
        // Registry lookup ----------------------------------------------------
        guard let entry = registry.entry(forLanguageId: key.languageId) else {
            throw LSPServiceError.languageNotInRegistry(languageId: key.languageId)
        }

        // Availability + (optional) install ---------------------------------
        if let installer {
            let check = await installer.checkInstallation(forLanguageId: key.languageId)
            if !check.isInstalled {
                // Honor the user-facing master switch *before* the code-level
                // `config.autoInstall`. `LSPSettings.autoInstallEnabled` is
                // the toggle exposed in the Settings UI, so if the user has
                // disabled auto-install we must not run any install command
                // even when the code-level `LSPServiceConfig` would allow it.
                if !LSPSettings.autoInstallEnabled {
                    throw LSPServiceError.languageServerNotAvailable(
                        languageId: key.languageId,
                        reason: "executable '\(entry.executable)' not on PATH and auto-install is disabled in settings"
                    )
                }
                if !config.autoInstall {
                    throw LSPServiceError.languageServerNotAvailable(
                        languageId: key.languageId,
                        reason: "executable '\(entry.executable)' not on PATH and autoInstall is disabled"
                    )
                }
                // Collapse the two UI-facing settings knobs
                // (`autoInstallEnabled`, `requireInstallConfirmation`)
                // into the `ConfirmationMode` the installer expects.
                // The code-level `config.installConfirmation` is
                // intentionally NOT consulted on this branch — the
                // Settings UI toggle is the source of truth at install
                // time. Until a UI bridge wires a real prompt handler
                // through to this point, the handler argument is a
                // closure that refuses every step, so a session that
                // lands here with `requireInstallConfirmation == true`
                // fails with `user declined: ...` instead of running
                // an install command behind the user's back.
                let mode = LSPSettings.confirmationMode(
                    confirmationHandler: { @Sendable _ in false }
                )
                let status = await installer.install(
                    languageId: key.languageId,
                    approvePrerequisites: true,
                    confirmationMode: mode
                )
                guard case .completed = status else {
                    let reason: String
                    if case .failed(let r) = status {
                        reason = r
                    } else {
                        reason = "install did not complete (status: \(status))"
                    }
                    throw LSPServiceError.languageServerNotAvailable(
                        languageId: key.languageId,
                        reason: reason
                    )
                }
            }
        }

        // Client + session ---------------------------------------------------
        let client: LSPClient
        do {
            client = try await sessionFactory.makeClient(
                executable: entry.executable,
                arguments: entry.arguments,
                environment: nil,
                workingDirectory: key.workspaceRoot
            )
        } catch {
            throw LSPServiceError.sessionStartFailed(reason: String(describing: error))
        }

        let session = LSPSession(
            workspaceRoot: key.workspaceRoot,
            languageId: key.languageId,
            client: client,
            persistence: persistence,
            diagnosticsStore: diagnosticsStore
        )

        do {
            try await session.start()
        } catch {
            throw LSPServiceError.sessionStartFailed(reason: String(describing: error))
        }

        // Shutdown race guard ----------------------------------------------
        // `session.start()` parks on a non-cancellation-aware continuation
        // inside `LSPClient.sendRequest`, so a `shutdownAll()` /
        // `shutdownSession(...)` that lands while the handshake is in flight
        // cannot interrupt the await directly. Once the await resumes we
        // consult both the per-task cancellation flag (set by
        // `shutdownSession`) and the service-wide `isShutdown` flag (set by
        // `shutdownAll`) and tear the freshly-started session down in-place
        // rather than letting it slip into the cache.
        if isShutdown || Task.isCancelled {
            try? await session.shutdown()
            throw LSPServiceError.sessionStartFailed(
                reason: "session shutdown cancelled in-flight build"
            )
        }

        // LRU enforcement ---------------------------------------------------
        if sessions.count >= config.maxConcurrentSessions {
            await evictOldestEntry()
        }

        let cacheEntry = SessionEntry(
            session: session,
            lastAccessed: Date(),
            createdAtUptimeMillis: Self.currentUptimeMillis()
        )
        sessions[key] = cacheEntry

        // FileSyncManager wiring — fire-and-forget so the build pipeline
        // is not blocked on the FSEvents stream coming up. `buildSession`
        // is dedup'd by `inProgressSessions[key]`, so this Task is
        // scheduled exactly once per (workspaceRoot, languageId) build;
        // warm-cache hits in `session(for:)` short-circuit before this
        // point and therefore do not re-arm the watch.
        if let fileSyncManager {
            let root = key.workspaceRoot
            let sessionRef = session
            Task {
                try? await fileSyncManager.watch(
                    workspaceRoot: root,
                    session: sessionRef
                )
            }
        }

        ensureIdleTimerRunning()
        return session
    }

    // MARK: - Private: LRU + idle eviction

    /// Removes the entry with the smallest `lastAccessed` timestamp and
    /// shuts it down. Caller has already confirmed the cache is at
    /// capacity.
    private func evictOldestEntry() async {
        guard let oldest = sessions.min(by: { $0.value.lastAccessed < $1.value.lastAccessed }) else {
            return
        }
        sessions.removeValue(forKey: oldest.key)
        try? await oldest.value.session.shutdown()
    }

    /// Starts the background idle-eviction loop if it's not running.
    /// Polls at half the idle window (capped at 100ms minimum) so the
    /// real-world latency between "idle" and "actually shut down" stays
    /// within one polling tick.
    private func ensureIdleTimerRunning() {
        if idleTimerTask != nil { return }

        let halfWindowNanos = UInt64(max(config.idleTimeoutSeconds, 1)) * 500_000_000
        let minimumNanos: UInt64 = 100_000_000 // 100ms
        let intervalNanos = max(halfWindowNanos, minimumNanos)

        idleTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanos)
                if Task.isCancelled { return }
                await self?.evictIdleSessions()
            }
        }
    }

    /// Drops any session whose `lastAccessed` is older than
    /// `idleTimeoutSeconds`.
    private func evictIdleSessions() async {
        let cutoff = Date().addingTimeInterval(-Double(config.idleTimeoutSeconds))
        let staleKeys = sessions.compactMap { (key, entry) -> SessionKey? in
            entry.lastAccessed < cutoff ? key : nil
        }
        for key in staleKeys {
            await shutdownSession(
                workspaceRoot: key.workspaceRoot,
                languageId: key.languageId
            )
        }
    }

    // MARK: - Private: uptime

    /// Process uptime in milliseconds, monotonic across the lifetime of
    /// the host process — does not jump when the wall clock changes.
    private static func currentUptimeMillis() -> Int64 {
        Int64(ProcessInfo.processInfo.systemUptime * 1000)
    }
}
