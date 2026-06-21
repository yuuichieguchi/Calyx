//
//  LSPSessionPersistenceWiringTests.swift
//  Calyx
//
//  TDD red-phase tests for the LSPSession <-> LSPSessionPersistence and
//  LSPService <-> LSPSessionPersistence wiring.
//
//  The forthcoming change adds a new trailing optional parameter to both
//  `LSPSession.init(...)` and `LSPService.init(...)`:
//
//      LSPSession.init(
//          workspaceRoot: URL,
//          languageId: String,
//          client: LSPClient,
//          clientCapabilities: ClientCapabilities = .calyxDefault(),
//          clientInfo: ClientInfo = .init(name: "Calyx", version: "0.26.1"),
//          persistence: LSPSessionPersistence? = nil
//      )
//
//      LSPService.init(
//          registry: LSPServerRegistry = .builtIn(),
//          installer: LSPInstaller? = nil,
//          sessionFactory: any LSPSessionFactory,
//          config: LSPServiceConfig = LSPServiceConfig(),
//          fileSyncManager: FileSyncManager? = nil,
//          persistence: LSPSessionPersistence? = nil
//      )
//
//  Semantics under test:
//    - LSPSession:
//        * On every `didOpen(uri:languageId:version:text:)` that mutates the
//          tracked open set, the session schedules a background
//          `Task { try? await persistence.persist(snapshot) }`. The snapshot
//          carries the session's own `workspaceRoot`, `languageId`, the full
//          current open-files array, `initializationOptions: nil` (placeholder
//          until LSPService surfaces user-supplied options), and a positive
//          `savedAtUptimeMillis` derived from
//          `ProcessInfo.processInfo.systemUptime`.
//        * `didClose(uri:)` similarly persists the updated snapshot.
//        * `shutdown()` schedules
//          `persistence.remove(workspaceRoot:languageId:)`.
//    - LSPService:
//        * New surface
//          `availableSnapshots() async -> [LSPSessionPersistence.SessionSnapshot]`
//          returns `persistence?.load() ?? []`. Calling this on a service
//          constructed with `persistence: nil` returns `[]` without crashing.
//        * `session(for:languageId:)` propagates the configured persistence
//          into the freshly built `LSPSession`, so post-build `didOpen`
//          activity surfaces in the same store the service can hand back
//          via `availableSnapshots()`.
//        * Two concurrent sessions on distinct workspaces produce two
//          independent entries in the persistence store.
//
//  TDD phase: RED. The new `persistence:` parameter does not exist yet on
//  `LSPSession.init(...)` or `LSPService.init(...)`, nor does
//  `LSPService.availableSnapshots()`. This file is expected to fail to
//  compile until the swift-specialist implements the wiring.
//

import XCTest
@testable import Calyx

// ====================================================================
// MARK: - file-private server simulator helpers
// ====================================================================
//
// Kept in a `fileprivate enum` namespace (rather than as methods on the
// `@MainActor`-isolated test class) so the helpers are implicitly
// `nonisolated` and can be invoked from Tasks that hop off the main
// actor. The simulator is intentionally identical in behaviour to the
// one in `LSPServiceTests` / `LSPServiceFileSyncWiringTests` so the
// wiring tests exercise the production code paths the way the rest of
// the suite does.
fileprivate enum LSPPersistenceWiringServerSim {

    /// Repeatedly scan the outbound buffer for `initialize` and `shutdown`
    /// JSON-RPC requests and inject matching responses on the inbound
    /// stream. Caps polling at ~10s of wall clock so the loop terminates
    /// even when the surrounding test forgets to cancel it.
    static func driveServerReplies(on transport: InMemoryLSPTransport) async {
        var initializeAnswered = false
        var shutdownAnsweredIds: Set<Int> = []

        for _ in 0..<2000 {
            if Task.isCancelled { return }
            let sent = await transport.sentMessages()
            for data in sent {
                guard let dict = parseFramedJSON(data) else { continue }
                let method = dict["method"] as? String

                if method == "initialize", !initializeAnswered {
                    if let id = extractId(dict["id"]) {
                        let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{},"serverInfo":{"name":"mock-lsp"}}}"#
                        await transport.simulateServerMessage(lspFrame(resp))
                        initializeAnswered = true
                    }
                } else if method == "shutdown",
                          let id = extractId(dict["id"]),
                          !shutdownAnsweredIds.contains(id) {
                    let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":null}"#
                    await transport.simulateServerMessage(lspFrame(resp))
                    shutdownAnsweredIds.insert(id)
                }
            }
            try? await Task.sleep(nanoseconds: 5_000_000) // 5ms
        }
    }

    static func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    static func parseFramedJSON(_ data: Data) -> [String: Any]? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    static func extractId(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// ====================================================================
// MARK: - file-private MockLSPSessionFactory
// ====================================================================

/// In-memory `LSPSessionFactory` that hands back an `LSPClient` driven by
/// a sidecar Task answering `initialize` / `shutdown` requests, mirroring
/// the helpers in `LSPServiceTests` and `LSPServiceFileSyncWiringTests`.
fileprivate actor MockLSPSessionFactory: LSPSessionFactory {

    private(set) var clientsMade: Int = 0
    private var transports: [InMemoryLSPTransport] = []
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    func clientsMadeCount() -> Int { clientsMade }

    func makeClient(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?
    ) async throws -> LSPClient {
        clientsMade += 1
        let transport = InMemoryLSPTransport()
        transports.append(transport)
        let client = LSPClient(transport: transport)
        let sidecar = Task {
            await LSPPersistenceWiringServerSim.driveServerReplies(on: transport)
        }
        sidecars.append(sidecar)
        return client
    }
}

// ====================================================================
// MARK: - LSPSessionPersistenceWiringTests
// ====================================================================

@MainActor
final class LSPSessionPersistenceWiringTests: XCTestCase {

    // ----------------------------------------------------------------
    // MARK: Constants
    // ----------------------------------------------------------------

    private let workspaceA = URL(
        fileURLWithPath: "/tmp/calyx-lsp-persist-wire-A",
        isDirectory: true
    )
    private let workspaceB = URL(
        fileURLWithPath: "/tmp/calyx-lsp-persist-wire-B",
        isDirectory: true
    )
    private let languageId = "typescript"

    // ----------------------------------------------------------------
    // MARK: Helpers — persistence + filesystem
    // ----------------------------------------------------------------

    /// Per-test isolated temp directory; the storage URL lives inside it so
    /// every test starts on a clean slate and the parent dir is torn down
    /// at the end of the test.
    private func makeTempDir(line: UInt = #line) throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LSPSessionPersistenceWiringTests-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: raw, withIntermediateDirectories: true
        )
        let url = raw.resolvingSymlinksInPath()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Build a fresh persistence backed by a clean per-test temp directory.
    private func makePersistence() throws -> LSPSessionPersistence {
        let dir = try makeTempDir()
        let storage = dir.appendingPathComponent("sessions.json")
        return LSPSessionPersistence(storageURL: storage)
    }

    /// Look up the snapshot for a (workspaceRoot, languageId) pair in the
    /// store. Returns `nil` if none persisted yet.
    private func snapshot(
        in persistence: LSPSessionPersistence,
        workspaceRoot: URL,
        languageId: String
    ) async -> LSPSessionPersistence.SessionSnapshot? {
        let all = await persistence.load()
        return all.first {
            $0.workspaceRoot == workspaceRoot && $0.languageId == languageId
        }
    }

    /// Poll until `predicate` returns true or `timeout` elapses. Returns
    /// the final predicate value (so callers can assert it).
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.01,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(
                nanoseconds: UInt64(pollInterval * 1_000_000_000)
            )
        }
        return await predicate()
    }

    // ----------------------------------------------------------------
    // MARK: Helpers — session / service construction
    // ----------------------------------------------------------------

    /// Construct an `LSPSession` wired to a fresh in-memory transport plus
    /// a sidecar Task answering `initialize` / `shutdown`. Returns the
    /// session and the live transport so tests can extend the simulator if
    /// needed. The session is left in `.running` once `start()` resolves.
    private func makeStartedSession(
        workspaceRoot: URL,
        languageId: String,
        persistence: LSPSessionPersistence?
    ) async throws -> (LSPSession, InMemoryLSPTransport) {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        let session = LSPSession(
            workspaceRoot: workspaceRoot,
            languageId: languageId,
            client: client,
            persistence: persistence
        )
        // Sidecar drives canned replies. Cancelled in teardown so leftover
        // polling doesn't keep the test runner waiting after assertions.
        let sidecar = Task {
            await LSPPersistenceWiringServerSim.driveServerReplies(on: transport)
        }
        addTeardownBlock {
            sidecar.cancel()
        }
        try await session.start()
        return (session, transport)
    }

    /// Build an `LSPService` that bypasses installer-driven binary checks
    /// (the registry lookup still runs, so `languageId` must match a
    /// built-in entry — `"typescript"` is used throughout these tests).
    private func makeService(
        factory: MockLSPSessionFactory,
        persistence: LSPSessionPersistence?,
        config: LSPServiceConfig = LSPServiceConfig()
    ) -> LSPService {
        LSPService(
            registry: .builtIn(),
            installer: nil,
            sessionFactory: factory,
            config: config,
            fileSyncManager: nil,
            persistence: persistence
        )
    }

    // ================================================================
    // MARK: - 1. didOpen persists a snapshot containing the new URI
    // ================================================================

    /// Contract: after `didOpen(uri:...)` the session schedules a persist
    /// against the wired `LSPSessionPersistence`. The persisted snapshot
    /// must reflect the session's identity (workspaceRoot, languageId) and
    /// contain the just-opened URI in its `openFiles` array.
    func test_didOpen_persistsSnapshot() async throws {
        let persistence = try makePersistence()
        let ws = workspaceA
        let lang = "swift"
        let (session, _) = try await makeStartedSession(
            workspaceRoot: ws,
            languageId: lang,
            persistence: persistence
        )

        let uri = "file:///tmp/calyx-lsp-persist-wire-A/a.swift"
        try await session.didOpen(uri: uri, languageId: lang, version: 1, text: "// a")

        // Persist is fire-and-forget from inside the session, so poll.
        let arrived = await waitUntil {
            let snap = await self.snapshot(
                in: persistence,
                workspaceRoot: ws,
                languageId: lang
            )
            return snap?.openFiles.contains(uri) == true
        }
        XCTAssertTrue(
            arrived,
            "didOpen must persist a snapshot containing the new URI for (workspaceRoot=\(ws.path), languageId=\(lang))"
        )

        let snap = await snapshot(
            in: persistence,
            workspaceRoot: ws,
            languageId: lang
        )
        XCTAssertEqual(
            snap?.workspaceRoot, ws,
            "snapshot.workspaceRoot must match the session"
        )
        XCTAssertEqual(
            snap?.languageId, lang,
            "snapshot.languageId must match the session"
        )
        XCTAssertEqual(
            snap?.openFiles, [uri],
            "snapshot.openFiles must reflect the single open URI"
        )
        // `initializationOptions` is reserved for a future extension; the
        // session passes `nil` today so the persisted value must also be nil.
        XCTAssertNil(
            snap?.initializationOptions,
            "initializationOptions has no plumbed source today; the wiring layer must pass nil"
        )
        XCTAssertGreaterThan(
            snap?.savedAtUptimeMillis ?? -1,
            0,
            "savedAtUptimeMillis must be derived from a positive ProcessInfo.systemUptime sample"
        )
    }

    // ================================================================
    // MARK: - 2. didClose persists an updated snapshot
    // ================================================================

    /// Contract: after `didClose(uri:)` removes the URI from the open set,
    /// the session persists the resulting (empty) `openFiles` array. The
    /// entry must still exist (identified by workspace + language) so a
    /// subsequent process restart can still reason about the session.
    func test_didClose_persistsUpdatedSnapshot() async throws {
        let persistence = try makePersistence()
        let ws = workspaceA
        let lang = "swift"
        let (session, _) = try await makeStartedSession(
            workspaceRoot: ws,
            languageId: lang,
            persistence: persistence
        )

        let uri = "file:///tmp/calyx-lsp-persist-wire-A/a.swift"
        try await session.didOpen(uri: uri, languageId: lang, version: 1, text: "// a")
        _ = await waitUntil {
            let snap = await self.snapshot(
                in: persistence,
                workspaceRoot: ws,
                languageId: lang
            )
            return snap?.openFiles.contains(uri) == true
        }

        try await session.didClose(uri: uri)

        let cleared = await waitUntil {
            let snap = await self.snapshot(
                in: persistence,
                workspaceRoot: ws,
                languageId: lang
            )
            return snap?.openFiles.isEmpty == true
        }
        XCTAssertTrue(
            cleared,
            "didClose must persist an updated snapshot with the URI removed"
        )

        let snap = await snapshot(
            in: persistence,
            workspaceRoot: ws,
            languageId: lang
        )
        XCTAssertNotNil(
            snap,
            "the (workspace, language) entry must still exist after didClose"
        )
        XCTAssertEqual(
            snap?.openFiles, [],
            "openFiles must be empty after closing the only document"
        )
    }

    // ================================================================
    // MARK: - 3. Multiple didOpens accumulate into one snapshot
    // ================================================================

    /// Contract: a session that opens N files persists a single entry whose
    /// `openFiles` array contains all N URIs (in some order). The
    /// persistence layer is identified by (workspace, language); multiple
    /// opens must overwrite the same entry rather than appending new ones.
    func test_didOpenMultipleFiles_persistsAllInSnapshot() async throws {
        let persistence = try makePersistence()
        let ws = workspaceA
        let lang = "swift"
        let (session, _) = try await makeStartedSession(
            workspaceRoot: ws,
            languageId: lang,
            persistence: persistence
        )

        let uris = [
            "file:///tmp/calyx-lsp-persist-wire-A/a.swift",
            "file:///tmp/calyx-lsp-persist-wire-A/b.swift",
            "file:///tmp/calyx-lsp-persist-wire-A/c.swift",
        ]
        for (i, uri) in uris.enumerated() {
            try await session.didOpen(
                uri: uri,
                languageId: lang,
                version: i + 1,
                text: "// \(uri)"
            )
        }

        let allArrived = await waitUntil {
            let snap = await self.snapshot(
                in: persistence,
                workspaceRoot: ws,
                languageId: lang
            )
            guard let files = snap?.openFiles else { return false }
            return Set(files) == Set(uris)
        }
        XCTAssertTrue(
            allArrived,
            "all opened URIs must be present in the persisted snapshot's openFiles"
        )

        let all = await persistence.load()
        let matching = all.filter {
            $0.workspaceRoot == ws && $0.languageId == lang
        }
        XCTAssertEqual(
            matching.count,
            1,
            "a single (workspace, language) pair must collapse to one entry, not append (count=\(matching.count))"
        )
    }

    // ================================================================
    // MARK: - 4. shutdown removes the snapshot
    // ================================================================

    /// Contract: `session.shutdown()` schedules a
    /// `persistence.remove(workspaceRoot:languageId:)` so terminated
    /// sessions do not leave stale entries behind for the next launch to
    /// "reopen".
    func test_shutdown_removesSnapshot() async throws {
        let persistence = try makePersistence()
        let ws = workspaceA
        let lang = "swift"
        let (session, _) = try await makeStartedSession(
            workspaceRoot: ws,
            languageId: lang,
            persistence: persistence
        )

        let uri = "file:///tmp/calyx-lsp-persist-wire-A/a.swift"
        try await session.didOpen(uri: uri, languageId: lang, version: 1, text: "// a")
        _ = await waitUntil {
            let snap = await self.snapshot(
                in: persistence,
                workspaceRoot: ws,
                languageId: lang
            )
            return snap?.openFiles.contains(uri) == true
        }

        try await session.shutdown()

        let removed = await waitUntil {
            let snap = await self.snapshot(
                in: persistence,
                workspaceRoot: ws,
                languageId: lang
            )
            return snap == nil
        }
        XCTAssertTrue(
            removed,
            "shutdown() must remove the (workspaceRoot, languageId) entry from persistence"
        )
    }

    // ================================================================
    // MARK: - 5. availableSnapshots() with nil persistence returns []
    // ================================================================

    /// Contract: when the service is constructed without a persistence
    /// store, `availableSnapshots()` returns an empty array without
    /// crashing — callers can opt out of session restoration entirely.
    func test_lspService_availableSnapshots_returnsEmpty_whenNilPersistence() async throws {
        let factory = MockLSPSessionFactory()
        let service = makeService(factory: factory, persistence: nil)

        let snaps = await service.availableSnapshots()

        XCTAssertEqual(
            snaps,
            [],
            "availableSnapshots() must return [] when LSPService.persistence is nil"
        )
    }

    // ================================================================
    // MARK: - 6. availableSnapshots() forwards persistence.load()
    // ================================================================

    /// Contract: when wired with a persistence store, `availableSnapshots()`
    /// returns whatever `persistence.load()` returns at call time, including
    /// snapshots persisted by previous process incarnations (modelled here
    /// by pre-populating the store directly).
    func test_lspService_availableSnapshots_returnsLoaded() async throws {
        let persistence = try makePersistence()
        let ws = workspaceA
        let lang = "typescript"

        let seeded = LSPSessionPersistence.SessionSnapshot(
            workspaceRoot: ws,
            languageId: lang,
            openFiles: ["file:///tmp/calyx-lsp-persist-wire-A/a.ts"],
            initializationOptions: nil,
            savedAtUptimeMillis: 12_345
        )
        try await persistence.persist(seeded)

        let factory = MockLSPSessionFactory()
        let service = makeService(factory: factory, persistence: persistence)

        let snaps = await service.availableSnapshots()
        XCTAssertEqual(
            snaps.count,
            1,
            "availableSnapshots() must surface exactly the entries returned by persistence.load()"
        )
        XCTAssertEqual(
            snaps.first,
            seeded,
            "availableSnapshots() must round-trip pre-existing snapshots verbatim"
        )
    }

    // ================================================================
    // MARK: - 7. session(for:) propagates persistence into the session
    // ================================================================

    /// Contract: a session built via `LSPService.session(for:languageId:)`
    /// must inherit the service's `persistence` reference. Verified by
    /// observing that `didOpen` on the returned session causes a snapshot
    /// to appear in `service.availableSnapshots()` (i.e. the same store
    /// the service exposes for restoration).
    func test_lspService_newSession_propagatesPersistenceToSession() async throws {
        let persistence = try makePersistence()
        let factory = MockLSPSessionFactory()
        let service = makeService(factory: factory, persistence: persistence)

        let ws = workspaceA
        let lang = languageId
        let session = try await service.session(for: ws, languageId: lang)

        let uri = "file:///tmp/calyx-lsp-persist-wire-A/a.ts"
        try await session.didOpen(uri: uri, languageId: lang, version: 1, text: "// a")

        let arrived = await waitUntil {
            let snaps = await service.availableSnapshots()
            return snaps.contains {
                $0.workspaceRoot == ws
                    && $0.languageId == lang
                    && $0.openFiles.contains(uri)
            }
        }
        XCTAssertTrue(
            arrived,
            "didOpen on a service-built session must surface in service.availableSnapshots()"
        )
    }

    // ================================================================
    // MARK: - 8. Concurrent sessions get distinct persistence entries
    // ================================================================

    /// Contract: opening files in two sessions on different workspaces
    /// (via the same `LSPService`) must produce two distinct persistence
    /// entries, each scoped to its own (workspaceRoot, languageId), with
    /// no cross-talk.
    func test_lspService_concurrent_sessions_distinctPersistedSnapshots() async throws {
        let persistence = try makePersistence()
        let factory = MockLSPSessionFactory()
        let service = makeService(factory: factory, persistence: persistence)

        let wsA = workspaceA
        let wsB = workspaceB
        let lang = languageId

        let sessionA = try await service.session(for: wsA, languageId: lang)
        let sessionB = try await service.session(for: wsB, languageId: lang)
        XCTAssertFalse(
            sessionA === sessionB,
            "precondition: distinct workspaces must yield distinct LSPSession instances"
        )

        let uriA = "file:///tmp/calyx-lsp-persist-wire-A/a.ts"
        let uriB = "file:///tmp/calyx-lsp-persist-wire-B/b.ts"
        try await sessionA.didOpen(uri: uriA, languageId: lang, version: 1, text: "// a")
        try await sessionB.didOpen(uri: uriB, languageId: lang, version: 1, text: "// b")

        let bothArrived = await waitUntil {
            let snaps = await service.availableSnapshots()
            let hasA = snaps.contains {
                $0.workspaceRoot == wsA
                    && $0.languageId == lang
                    && $0.openFiles == [uriA]
            }
            let hasB = snaps.contains {
                $0.workspaceRoot == wsB
                    && $0.languageId == lang
                    && $0.openFiles == [uriB]
            }
            return hasA && hasB
        }
        XCTAssertTrue(
            bothArrived,
            "concurrent sessions must each persist their own (workspaceRoot, languageId, openFiles) tuple"
        )

        let snaps = await service.availableSnapshots()
        // Total snapshot count for the two test workspaces must equal 2 —
        // i.e., neither side has accidentally overwritten the other.
        let testSnaps = snaps.filter {
            ($0.workspaceRoot == wsA || $0.workspaceRoot == wsB)
                && $0.languageId == lang
        }
        XCTAssertEqual(
            testSnaps.count,
            2,
            "distinct workspaces must yield 2 independent persistence entries (got \(testSnaps.count))"
        )

        let aSnap = testSnaps.first { $0.workspaceRoot == wsA }
        let bSnap = testSnaps.first { $0.workspaceRoot == wsB }
        XCTAssertEqual(
            aSnap?.openFiles, [uriA],
            "workspaceA snapshot must hold only uriA"
        )
        XCTAssertEqual(
            bSnap?.openFiles, [uriB],
            "workspaceB snapshot must hold only uriB"
        )
    }
}
