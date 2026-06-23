//
//  LSPServiceBugSpecTests.swift
//  Calyx
//
//  TDD RED-phase regression tests covering six bugs in `LSPService`:
//
//    1. `SessionKey` workspaceRoot is not canonicalized, so two callers
//       reaching for the same workspace under symlink-equivalent spellings
//       (`/tmp/...` vs `/private/tmp/...`) get two distinct cache entries.
//    2. `evictOldestEntry` shuts the cached session down but does NOT
//       call `fileSyncManager.unwatch(...)`, leaking the FSEvents stream.
//    3. `buildSession` and `shutdownSession` both fire-and-forget their
//       `watch` / `unwatch` calls; their ordering is undefined, so a
//       warm-then-immediately-shut session can leave the workspace
//       registered with `FileSyncManager`.
//    4. `evictIdleSessions` snapshots the stale set once and never
//       rechecks freshness inside the loop, so a concurrent refresh
//       between iterations does not save the just-touched session.
//    5. Warm-cache hits ignore `SessionState`: a session that has
//       transitioned to `.failed` (server crashed / transport closed)
//       is handed back to the next caller verbatim.
//    6. The LRU cap check (`if sessions.count >= max { evict }`) is not
//       atomic with the insert that follows, so concurrent first-time
//       callers can each see count < max before any insert and the cache
//       overflows past `maxConcurrentSessions`.
//
//  All six tests are expected to FAIL against the current code.
//

import XCTest
@testable import Calyx

// MARK: - file-private MockLSPSessionFactory

/// In-memory `LSPSessionFactory` that hands back an `LSPClient` whose
/// `InMemoryLSPTransport` is driven by a sidecar Task answering the
/// `initialize` / `shutdown` requests. Mirrors the helper used in the
/// existing `LSPServiceTests` / `LSPServiceFileSyncWiringTests` so no real
/// server process is spawned during the suite.
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
            await Self.driveServerReplies(on: transport)
        }
        sidecars.append(sidecar)
        return client
    }

    /// Poll the outbound transport buffer and inject canned responses for
    /// the `initialize` / `shutdown` requests so `LSPSession` can resolve
    /// its handshake without a real server.
    private static func driveServerReplies(on transport: InMemoryLSPTransport) async {
        var initializeAnswered = false
        var shutdownAnsweredIds: Set<Int> = []

        for _ in 0..<2000 {
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

    private static func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        out.append(body)
        return out
    }

    private static func parseFramedJSON(_ data: Data) -> [String: Any]? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    private static func extractId(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}

// MARK: - LSPServiceBugSpecTests

@MainActor
final class LSPServiceBugSpecTests: XCTestCase {

    // MARK: - Constants

    private let languageId = "typescript"

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        LSPSettings.resetToDefaults()
    }

    override func tearDown() {
        LSPSettings.resetToDefaults()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Build an `LSPService` with no installer (so the missing-binary
    /// check is bypassed) and the supplied factory / config / file-sync.
    private func makeService(
        factory: MockLSPSessionFactory,
        fileSync: FileSyncManager? = nil,
        config: LSPServiceConfig = LSPServiceConfig()
    ) -> LSPService {
        LSPService(
            registry: .builtIn(),
            installer: nil,
            sessionFactory: factory,
            config: config,
            fileSyncManager: fileSync
        )
    }

    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        pollInterval: TimeInterval = 0.01,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await predicate()
    }

    // MARK: - Bug 1: SessionKey workspaceRoot is not canonicalized

    /// `/tmp/foo` and `/private/tmp/foo` are the same physical directory
    /// on macOS (`/tmp` is a symlink to `/private/tmp`). The cache key
    /// must canonicalize the workspace root so two callers reaching for
    /// the same workspace under different spellings share one session
    /// instead of spawning duplicate child processes.
    func test_bug1_sessionKey_canonicalizesWorkspaceRoot() async throws {
        let factory = MockLSPSessionFactory()
        let service = makeService(factory: factory)

        // Build two URL spellings of the same physical path. `/tmp` is a
        // symlink to `/private/tmp` on macOS, so both forms resolve to
        // the same place even when the leaf directory does not exist.
        let leaf = "calyx-lsp-svc-bug1-\(UUID().uuidString)"
        let varForm = URL(fileURLWithPath: "/tmp/\(leaf)")
        let privateForm = URL(fileURLWithPath: "/private/tmp/\(leaf)")
        XCTAssertNotEqual(
            varForm, privateForm,
            "precondition: the two URL spellings must differ as URL values"
        )

        let sessionVar = try await service.session(for: varForm, languageId: languageId)
        let sessionPrivate = try await service.session(for: privateForm, languageId: languageId)

        XCTAssertTrue(
            sessionVar === sessionPrivate,
            "SessionKey must canonicalize workspaceRoot; /tmp/... and /private/tmp/... map to the same workspace"
        )

        let infos = await service.currentSessions()
        XCTAssertEqual(
            infos.count,
            1,
            "expected exactly one cached session for one logical workspace; got \(infos.count) (\(infos.map(\.workspaceRoot)))"
        )

        let made = await factory.clientsMadeCount()
        XCTAssertEqual(
            made,
            1,
            "factory must build exactly one client when both callers point at the same logical workspace; got \(made)"
        )
    }

    // MARK: - Bug 2: evictOldestEntry leaks the FSEvents watch

    /// LRU eviction shuts the session down but forgets to call
    /// `fileSyncManager.unwatch(...)`. The FSEvents stream stays alive
    /// and the manager pins a reference to the dead session via its
    /// `watchedRoots_` map.
    func test_bug2_evictOldestEntry_callsUnwatchOnFileSyncManager() async throws {
        let fileSync = FileSyncManager(eventSourceFactory: { MockFileSystemEventSource() })
        let factory = MockLSPSessionFactory()
        let service = makeService(
            factory: factory,
            fileSync: fileSync,
            config: LSPServiceConfig(maxConcurrentSessions: 1)
        )

        let workspaceA = URL(fileURLWithPath: "/tmp/calyx-lsp-svc-bug2-A")
        let workspaceB = URL(fileURLWithPath: "/tmp/calyx-lsp-svc-bug2-B")

        _ = try await service.session(for: workspaceA, languageId: languageId)
        let aWatched = await waitUntil {
            await fileSync.watchedRoots().contains(workspaceA)
        }
        XCTAssertTrue(aWatched, "precondition: workspace A must be watched before forcing eviction")

        // Forcing maxConcurrentSessions=1 means inserting B must evict A.
        _ = try await service.session(for: workspaceB, languageId: languageId)
        let bWatched = await waitUntil {
            await fileSync.watchedRoots().contains(workspaceB)
        }
        XCTAssertTrue(bWatched, "precondition: workspace B must be watched after the second build")

        // Give the eviction path generous time to run an unwatch (which
        // the bug skips entirely).
        _ = await waitUntil(timeout: 1.5) {
            !(await fileSync.watchedRoots().contains(workspaceA))
        }

        let roots = await fileSync.watchedRoots()
        XCTAssertFalse(
            roots.contains(workspaceA),
            "evictOldestEntry must call fileSyncManager.unwatch for the evicted workspace; remaining roots=\(roots)"
        )
    }

    // MARK: - Bug 3: fire-and-forget watch/unwatch race

    /// `buildSession` enqueues `Task { fileSyncManager.watch(...) }` and
    /// `shutdownSession` enqueues `Task { fileSyncManager.unwatch(...) }`.
    /// When a caller warms a session and immediately shuts it down the
    /// ordering of those two background Tasks is undefined; if the
    /// unwatch lands first the watch wins the race and pins the dead
    /// session in the manager.
    func test_bug3_warmThenImmediatelyShutdown_settlesUnwatched() async throws {
        let fileSync = FileSyncManager(eventSourceFactory: { MockFileSystemEventSource() })
        let factory = MockLSPSessionFactory()
        let service = makeService(factory: factory, fileSync: fileSync)

        let workspace = URL(fileURLWithPath: "/tmp/calyx-lsp-svc-bug3")

        // Warm + immediately tear down with NO Task.yield gap so the two
        // fire-and-forget Tasks land on the actor queues back-to-back.
        _ = try await service.session(for: workspace, languageId: languageId)
        await service.shutdownSession(workspaceRoot: workspace, languageId: languageId)

        // After both calls return and any pending Tasks have settled the
        // workspace must NOT be watched. The race may resolve in either
        // direction; we wait long enough that the slow side has also run
        // before checking, so the assertion captures the steady state.
        let settled = await waitUntil(timeout: 2.0) {
            !(await fileSync.watchedRoots().contains(workspace))
        }

        let roots = await fileSync.watchedRoots()
        XCTAssertTrue(
            settled,
            "post warm+shutdown the FileSyncManager must not still be watching the workspace (watch/unwatch race left it watched); roots=\(roots)"
        )
        XCTAssertFalse(
            roots.contains(workspace),
            "fire-and-forget watch/unwatch ordering must converge to unwatched; roots=\(roots)"
        )
    }

    // MARK: - Bug 4: evictIdleSessions does not recheck freshness inside its loop

    /// `evictIdleSessions` snapshots the stale set once and iterates,
    /// shutting each entry down without rechecking `lastAccessed`. A
    /// concurrent `session(for:)` that refreshes one of the snapshot
    /// keys between iterations is ignored and the just-touched session
    /// is still evicted.
    ///
    /// Deterministically exercising this race requires a private hook on
    /// `LSPService` (the public surface lacks an `evictIdleSessions()`
    /// entry point and exposes neither the staleness snapshot nor the
    /// per-iteration shutdown hand-off). The shape of the test is
    /// recorded here so the swift-specialist can plug in the production
    /// accessors and unskip it.
    func test_bug4_evictIdleSessions_rechecksFreshnessPerIteration() async throws {
        throw XCTSkip(
            """
            Requires production-side test hooks not currently exposed by LSPService:
              - `evictIdleSessionsForTests()` to drive the eviction loop on demand,
              - per-iteration await injection (or a custom LSPSession factory hook) so
                a concurrent `session(for:)` refresh can land between two iterations.
            Mark this test for swift-specialist follow-up.
            """
        )
    }

    // MARK: - Bug 5: warm-cache hits return a dead session

    /// `session(for:)` returns the cached session reference without
    /// inspecting `SessionState`. If the underlying transport closed
    /// (server crashed, or the session was driven to `.failed` by an
    /// out-of-band error) the next caller receives the dead session and
    /// their first `sendRequest` throws.
    func test_bug5_warmCache_doesNotReturnFailedSession() async throws {
        let factory = MockLSPSessionFactory()
        let service = makeService(factory: factory)

        let workspace = URL(fileURLWithPath: "/tmp/calyx-lsp-svc-bug5")

        let first = try await service.session(for: workspace, languageId: languageId)

        // Force the session into `.failed` without driving the full
        // `shutdown()` path (which would also tear down the transport
        // and clear handlers). The cache entry survives, which is
        // exactly the dead-session state we want the next caller to
        // route around.
        await first.setSessionStateForTests(
            .failed(reason: "simulated transport closure for bug-spec test")
        )

        let second = try await service.session(for: workspace, languageId: languageId)

        let secondState = await second.state()
        XCTAssertFalse(
            first === second,
            """
            session(for:) must NOT return a dead session from the warm cache: \
            expected a fresh build, got the same instance back (state=\(secondState))
            """
        )

        let made = await factory.clientsMadeCount()
        XCTAssertEqual(
            made,
            2,
            "post-failure cache hit must trigger a fresh factory build; clientsMade=\(made)"
        )
    }

    // MARK: - Bug 6: LRU cap is not enforced under concurrent first-time calls

    /// The cap check (`if sessions.count >= max { evict }`) is not atomic
    /// with the insert that follows. Concurrent first-time callers each
    /// resume from `await session.start()` while the cache is still below
    /// the cap, run the (synchronous) count check independently, and
    /// then all insert — so the cache size can blow past
    /// `maxConcurrentSessions`.
    func test_bug6_concurrentColdCalls_respectMaxConcurrentSessions() async throws {
        let factory = MockLSPSessionFactory()
        let service = makeService(
            factory: factory,
            config: LSPServiceConfig(maxConcurrentSessions: 2)
        )

        let workspaces: [URL] = (0..<5).map {
            URL(fileURLWithPath: "/tmp/calyx-lsp-svc-bug6-\($0)")
        }

        // Spawn each request as a top-level `Task` (region-isolation
        // friendly) rather than via `withTaskGroup`'s explicit child
        // capture. All tasks inherit the @MainActor isolation of the
        // surrounding test, but the await points inside `session(for:)`
        // allow the build pipeline to interleave the LRU enforcement
        // path against fresh-build inserts.
        let svc = service
        let lang = languageId
        var tasks: [Task<Void, Never>] = []
        tasks.reserveCapacity(workspaces.count)
        for ws in workspaces {
            tasks.append(Task { @MainActor in
                _ = try? await svc.session(for: ws, languageId: lang)
            })
        }
        for task in tasks {
            await task.value
        }

        let infos = await service.currentSessions()
        XCTAssertLessThanOrEqual(
            infos.count,
            2,
            "cache must respect maxConcurrentSessions=2 even under concurrent cold callers; count=\(infos.count), roots=\(infos.map(\.workspaceRoot))"
        )
    }
}
