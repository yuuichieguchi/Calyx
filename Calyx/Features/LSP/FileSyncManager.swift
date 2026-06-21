//
//  FileSyncManager.swift
//  Calyx
//
//  Actor bridging file-system events to LSP 3.18 textDocument and
//  workspace synchronisation notifications on a per-(workspaceRoot,
//  session) basis.
//
//  In production a single `FileSyncManager` instance wraps an
//  `FSEventsEventSource`; tests inject a `MockFileSystemEventSource`
//  and drive events explicitly via `MockFileSystemEventSource.emit(_:)`.
//
//  Event translation:
//    - .created                    -> workspace/didChangeWatchedFiles (Created)
//    - .modified, URI open         -> textDocument/didChange (full)
//    - .modified, URI not open     -> workspace/didChangeWatchedFiles (Changed)
//    - .removed,  URI open         -> textDocument/didClose (+ open-set
//                                      eviction) followed by
//                                      workspace/didChangeWatchedFiles (Deleted)
//    - .removed,  URI not open     -> workspace/didChangeWatchedFiles (Deleted)
//    - .renamed,  URI open         -> textDocument/didClose (old) +
//                                      textDocument/didOpen (new) followed
//                                      by workspace/didChangeWatchedFiles
//                                      (Deleted, Created)
//    - .renamed,  URI not open     -> workspace/didChangeWatchedFiles
//                                      (Deleted, Created)
//
//  Spec entry points:
//    - workspace/didChangeWatchedFiles:
//        https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_didChangeWatchedFiles
//    - textDocument/didChange:
//        https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didChange
//    - textDocument/didOpen / didClose:
//        https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_didOpen
//

import Foundation
import CoreServices
import os

// MARK: - FileSystemEvent

/// Normalised file-system event surfaced to `FileSyncManager`. Production
/// callers populate these from FSEvents flags; tests construct them
/// directly through `MockFileSystemEventSource.emit(_:)`.
struct FileSystemEvent: Sendable, Equatable {
    let path: URL
    let kind: Kind

    enum Kind: Sendable, Equatable {
        case created
        case modified
        case removed
        case renamed(to: URL)
    }

    init(path: URL, kind: Kind) {
        self.path = path
        self.kind = kind
    }
}

// MARK: - FileSystemEventSource

/// Pluggable file-system event source. Production code uses
/// `FSEventsEventSource`; tests use `MockFileSystemEventSource` to drive
/// events deterministically.
protocol FileSystemEventSource: Sendable {
    /// Start watching `path` and deliver event batches to `handler`. The
    /// handler is retained for the lifetime of the watch (until `stop()`
    /// is called or another `start(...)` replaces it).
    func start(
        at path: URL,
        handler: @Sendable @escaping ([FileSystemEvent]) async -> Void
    ) async throws

    /// Stop the underlying watcher and drop the registered handler.
    func stop() async
}

// MARK: - LSP wire types for workspace/didChangeWatchedFiles

/// LSP 3.18 `FileChangeType` enum values used in
/// `workspace/didChangeWatchedFiles`. Modelled as raw ints to avoid
/// pulling in a public type for an internal helper.
private enum FileChangeType {
    static let created: Int = 1
    static let changed: Int = 2
    static let deleted: Int = 3
}

private struct FileEvent: Sendable, Codable, Equatable {
    let uri: String
    let type: Int
}

private struct DidChangeWatchedFilesParams: Sendable, Codable, Equatable {
    let changes: [FileEvent]
}

// MARK: - FileSyncManager

/// Actor that mediates between a `FileSystemEventSource` and one or more
/// `LSPSession`s, translating file-system events into the appropriate
/// textDocument / workspace notifications.
actor FileSyncManager {

    // MARK: - State

    private let eventSource: any FileSystemEventSource

    /// `workspaceRoot -> LSPSession` map of currently watched workspaces.
    /// Strong reference; callers MUST call `unwatch(workspaceRoot:)` or
    /// `stopAll()` to drop the session before tearing it down.
    private var watchedRoots_: [URL: LSPSession] = [:]

    /// Suppression counters keyed by path. `suppressNextEvent(at:)`
    /// increments the counter and `handleEvents(_:workspaceRoot:)`
    /// decrements it once per masked event for that path.
    private var suppressedEvents: [URL: Int] = [:]

    /// Monotonic version counter handed to `textDocument/didChange` and
    /// post-rename `textDocument/didOpen` payloads. LSP requires the
    /// version to be strictly increasing per document; reusing a single
    /// global counter is simpler than per-URI tracking and satisfies the
    /// spec since the counter only ever grows.
    private var versionCounter: Int = 1

    // MARK: - Init

    init(eventSource: any FileSystemEventSource = FSEventsEventSource()) {
        self.eventSource = eventSource
    }

    // MARK: - Introspection

    /// Snapshot of every workspace root currently registered with `watch`.
    func watchedRoots() -> [URL] {
        Array(watchedRoots_.keys)
    }

    // MARK: - Lifecycle

    /// Register `workspaceRoot` for monitoring. Subsequent file-system
    /// events under `workspaceRoot` are routed to `session`. Watching an
    /// already-watched root is a no-op.
    func watch(workspaceRoot: URL, session: LSPSession) async throws {
        if watchedRoots_[workspaceRoot] != nil {
            return
        }
        watchedRoots_[workspaceRoot] = session
        try await eventSource.start(at: workspaceRoot) { [weak self] events in
            guard let self else { return }
            await self.handleEvents(events, workspaceRoot: workspaceRoot)
        }
    }

    /// Stop monitoring `workspaceRoot`. Unwatching an unknown root is a
    /// no-op. When the last watched root is removed the underlying
    /// `eventSource` is stopped as well.
    func unwatch(workspaceRoot: URL) async {
        guard watchedRoots_[workspaceRoot] != nil else { return }
        watchedRoots_[workspaceRoot] = nil
        if watchedRoots_.isEmpty {
            await eventSource.stop()
        }
    }

    /// Drop every watched root, clear pending suppressions, and stop the
    /// underlying `eventSource`.
    func stopAll() async {
        watchedRoots_.removeAll()
        suppressedEvents.removeAll()
        await eventSource.stop()
    }

    /// Mask exactly one subsequent event for `path`. Calling this N times
    /// masks the next N events. Used by Calyx-side writers to avoid
    /// FSEvents echoes feeding back into LSP traffic.
    func suppressNextEvent(at path: URL) {
        suppressedEvents[path, default: 0] += 1
    }

    // MARK: - Event handling

    private func nextVersion() -> Int {
        versionCounter += 1
        return versionCounter
    }

    /// Returns `true` and decrements the suppression counter when an
    /// event for `path` should be masked; returns `false` otherwise.
    private func consumeSuppression(at path: URL) -> Bool {
        guard let count = suppressedEvents[path], count > 0 else {
            return false
        }
        if count == 1 {
            suppressedEvents[path] = nil
        } else {
            suppressedEvents[path] = count - 1
        }
        return true
    }

    private func handleEvents(
        _ events: [FileSystemEvent],
        workspaceRoot: URL
    ) async {
        guard let session = watchedRoots_[workspaceRoot] else { return }
        for event in events {
            if consumeSuppression(at: event.path) {
                continue
            }
            await dispatch(event: event, session: session)
        }
    }

    private func dispatch(event: FileSystemEvent, session: LSPSession) async {
        let uri = event.path.absoluteString
        let isOpen = await session.openDocuments().contains(uri)

        switch event.kind {
        case .created:
            await sendDidChangeWatchedFiles(
                session: session,
                changes: [FileEvent(uri: uri, type: FileChangeType.created)]
            )

        case .modified:
            if isOpen {
                guard let text = try? String(contentsOf: event.path, encoding: .utf8) else {
                    return
                }
                try? await session.didChange(
                    uri: uri,
                    version: nextVersion(),
                    changes: [.full(text: text)]
                )
            } else {
                await sendDidChangeWatchedFiles(
                    session: session,
                    changes: [FileEvent(uri: uri, type: FileChangeType.changed)]
                )
            }

        case .removed:
            if isOpen {
                // LSPSession.didClose both sends the notification and
                // evicts the URI from the open-document set.
                try? await session.didClose(uri: uri)
            }
            await sendDidChangeWatchedFiles(
                session: session,
                changes: [FileEvent(uri: uri, type: FileChangeType.deleted)]
            )

        case .renamed(let toURL):
            let toUri = toURL.absoluteString
            if isOpen {
                try? await session.didClose(uri: uri)
                if let text = try? String(contentsOf: toURL, encoding: .utf8) {
                    try? await session.didOpen(
                        uri: toUri,
                        languageId: session.languageId,
                        version: nextVersion(),
                        text: text
                    )
                }
            }
            await sendDidChangeWatchedFiles(
                session: session,
                changes: [
                    FileEvent(uri: uri, type: FileChangeType.deleted),
                    FileEvent(uri: toUri, type: FileChangeType.created),
                ]
            )
        }
    }

    private func sendDidChangeWatchedFiles(
        session: LSPSession,
        changes: [FileEvent]
    ) async {
        let params = DidChangeWatchedFilesParams(changes: changes)
        try? await session.sendGenericNotification(
            method: "workspace/didChangeWatchedFiles",
            params: params
        )
    }
}

// MARK: - FSEventsEventSource (production)

/// macOS FSEvents-backed `FileSystemEventSource`. Watches a single root
/// path at a time; calling `start(at:handler:)` while a stream is already
/// running is a no-op so the caller must `stop()` first to re-target.
final class FSEventsEventSource: FileSystemEventSource, @unchecked Sendable {

    /// Box that adopts `@unchecked Sendable` on behalf of the underlying
    /// `OpaquePointer`, which the standard library explicitly marks as
    /// not-Sendable. The pointer is only ever read by code holding the
    /// state lock, so smuggling it through `@Sendable` closures here is
    /// safe.
    private struct StreamBox: @unchecked Sendable {
        let value: FSEventStreamRef
    }

    /// Lock-protected mutable state. `OSAllocatedUnfairLock` is the
    /// async-safe replacement for `NSLock` recommended by Swift
    /// Concurrency: its `withLock` body is `@Sendable` and is permitted
    /// inside `async` functions.
    private struct State: Sendable {
        var stream: StreamBox?
        var handler: (@Sendable ([FileSystemEvent]) async -> Void)?
    }

    private let queue = DispatchQueue(label: "com.calyx.lsp.fseventseventsource")
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init() {}

    func start(
        at path: URL,
        handler: @Sendable @escaping ([FileSystemEvent]) async -> Void
    ) async throws {
        let alreadyRunning = state.withLock { $0.stream != nil }
        if alreadyRunning {
            return
        }

        let pathsToWatch = [path.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagNoDefer
        )
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            FSEventsEventSource.fsEventsCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            createFlags
        ) else {
            throw NSError(
                domain: "FSEventsEventSource",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "FSEventStreamCreate failed"]
            )
        }
        FSEventStreamSetDispatchQueue(s, queue)
        _ = FSEventStreamStart(s)
        let box = StreamBox(value: s)
        state.withLock { state in
            state.stream = box
            state.handler = handler
        }
    }

    func stop() async {
        let toRelease = state.withLock { state -> StreamBox? in
            let s = state.stream
            state.stream = nil
            state.handler = nil
            return s
        }
        if let box = toRelease {
            FSEventStreamStop(box.value)
            FSEventStreamInvalidate(box.value)
            FSEventStreamRelease(box.value)
        }
    }

    fileprivate func emitFromCallback(_ events: [FileSystemEvent]) {
        let h = state.withLock { $0.handler }
        guard let h else { return }
        Task { await h(events) }
    }

    /// C-convention callback dispatched on `queue`. Decodes the FSEvents
    /// flag bitmask into `FileSystemEvent.Kind`, then forwards the
    /// translated batch through `emitFromCallback`.
    private static let fsEventsCallback: FSEventStreamCallback = {
        (_, clientCallBackInfo, numEvents, eventPaths, eventFlags, _) in
        guard let info = clientCallBackInfo else { return }
        let mySelf = Unmanaged<FSEventsEventSource>
            .fromOpaque(info)
            .takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else {
            return
        }
        var events: [FileSystemEvent] = []
        events.reserveCapacity(Int(numEvents))
        for i in 0..<Int(numEvents) {
            let flags = eventFlags.advanced(by: i).pointee
            let url = URL(fileURLWithPath: paths[i])
            let kind: FileSystemEvent.Kind
            if (flags & UInt32(kFSEventStreamEventFlagItemRemoved)) != 0 {
                kind = .removed
            } else if (flags & UInt32(kFSEventStreamEventFlagItemCreated)) != 0 {
                kind = .created
            } else if (flags & UInt32(kFSEventStreamEventFlagItemRenamed)) != 0 {
                // FSEvents reports the touched path only; we don't know
                // the companion rename target from a single event.
                // Report it as a rename onto itself; production callers
                // that need pair-matching should disambiguate at a
                // higher layer using the FSEvents event-id ordering.
                kind = .renamed(to: url)
            } else {
                kind = .modified
            }
            events.append(FileSystemEvent(path: url, kind: kind))
        }
        mySelf.emitFromCallback(events)
    }
}

// MARK: - MockFileSystemEventSource (tests / harnesses)

/// In-memory `FileSystemEventSource` test double. Stores the most
/// recently registered handler and replays synthetic batches through it
/// when callers invoke `emit(_:)`.
actor MockFileSystemEventSource: FileSystemEventSource {

    private var handler: (@Sendable ([FileSystemEvent]) async -> Void)?

    init() {}

    func start(
        at path: URL,
        handler: @Sendable @escaping ([FileSystemEvent]) async -> Void
    ) async throws {
        self.handler = handler
    }

    func stop() async {
        handler = nil
    }

    /// Replay `events` through the registered handler. The handler runs
    /// to completion before this call returns, so test code can await
    /// `emit(_:)` and then immediately assert on the resulting LSP
    /// traffic.
    func emit(_ events: [FileSystemEvent]) async {
        guard let h = handler else { return }
        await h(events)
    }
}
