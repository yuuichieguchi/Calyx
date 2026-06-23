//
//  LSPServiceFileSyncWiringTests.swift
//  Calyx
//
//  TDD red-phase tests for the LSPService <-> FileSyncManager wiring.
//
//  The forthcoming change adds a new trailing optional parameter to
//  `LSPService.init(...)`:
//
//      init(
//          registry: LSPServerRegistry = .builtIn(),
//          installer: LSPInstaller? = nil,
//          sessionFactory: any LSPSessionFactory,
//          config: LSPServiceConfig = LSPServiceConfig(),
//          fileSyncManager: FileSyncManager? = nil
//      )
//
//  Semantics under test:
//    - When `fileSyncManager` is non-nil:
//        * Every freshly built (workspace, language) session schedules a
//          background `Task { try? await fileSyncManager.watch(...) }`
//          using the new session as the routing target.
//        * Warm-cache hits and concurrent dedup-share calls MUST NOT
//          fire a second `watch` for the same workspaceRoot.
//        * `shutdownSession(workspaceRoot:languageId:)` schedules a
//          background `Task { await fileSyncManager.unwatch(...) }`.
//        * `shutdownAll()` clears every watched workspace from the
//          `FileSyncManager`.
//    - When `fileSyncManager` is nil:
//        * The legacy warm-cache, dedup, and shutdown paths must keep
//          working unchanged (no observable file-sync side effects).
//
//  TDD phase: RED. The new parameter does not exist yet on
//  `LSPService.init(...)`, so this file is expected to fail to compile
//  until the implementation step is performed.
//

import XCTest
@testable import Calyx

// MARK: - file-private MockLSPSessionFactory

/// In-memory `LSPSessionFactory` that hands back an `LSPClient` whose
/// `InMemoryLSPTransport` is driven by a sidecar Task answering the
/// `initialize` and `shutdown` requests `LSPSession.start()` /
/// `LSPSession.shutdown()` issue. Lets us exercise the full
/// `LSPService.session(for:languageId:)` build pipeline without spawning
/// an external language-server process. Mirrors the helper used in
/// `LSPServiceTests`.
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
    /// the `initialize` and `shutdown` requests so `LSPSession` can resolve
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

// MARK: - LSPServiceFileSyncWiringTests

@MainActor
final class LSPServiceFileSyncWiringTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-lsp-svc-fs-wire-A")
    private let workspaceB = URL(fileURLWithPath: "/tmp/calyx-lsp-svc-fs-wire-B")
    private let languageId = "typescript"

    // MARK: - Helpers

    /// Poll `predicate` until it returns true or `timeout` expires.
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

    /// Build an `LSPService` configured to bypass installer-driven binary
    /// checks (the registry lookup still runs, so `languageId` must match
    /// a built-in entry — `"typescript"` is used throughout).
    private func makeService(
        factory: MockLSPSessionFactory,
        fileSync: FileSyncManager?,
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

    // MARK: - 1. New session creation triggers FileSyncManager.watch

    func test_newSession_triggersFileSyncWatch() async throws {
        let factory = MockLSPSessionFactory()
        let fileSync = FileSyncManager(eventSourceFactory: { MockFileSystemEventSource() })
        let service = makeService(factory: factory, fileSync: fileSync)
        let ws = workspaceA
        let lang = languageId

        _ = try await service.session(for: ws, languageId: lang)

        let watched = await waitUntil {
            let roots = await fileSync.watchedRoots()
            return roots.contains(ws)
        }
        XCTAssertTrue(
            watched,
            "creating a fresh LSPSession must register the workspace with FileSyncManager.watch"
        )
    }

    // MARK: - 2. Warm-cache hits skip an additional FileSync.watch

    func test_warmCache_skipsWatch() async throws {
        let factory = MockLSPSessionFactory()
        let fileSync = FileSyncManager(eventSourceFactory: { MockFileSystemEventSource() })
        let service = makeService(factory: factory, fileSync: fileSync)
        let ws = workspaceA
        let lang = languageId

        // First call: must establish the watch.
        _ = try await service.session(for: ws, languageId: lang)
        let firstSeen = await waitUntil {
            let roots = await fileSync.watchedRoots()
            return roots.contains(ws)
        }
        XCTAssertTrue(firstSeen, "precondition: first session(for:) must establish the watch")

        // Second call: warm cache, MUST NOT register an additional watch.
        _ = try await service.session(for: ws, languageId: lang)
        // Give any erroneously-fired background watch a chance to land.
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let roots = await fileSync.watchedRoots()
        let count = roots.filter { $0 == ws }.count
        XCTAssertEqual(
            count,
            1,
            "warm-cache hits must not trigger duplicate FileSyncManager.watch: roots=\(roots)"
        )
        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 1, "warm-cache hit must not rebuild the underlying LSPClient")
    }

    // MARK: - 3. Concurrent session(for:) calls dedup to a single watch

    func test_concurrentSession_callsWatchOnce() async throws {
        let factory = MockLSPSessionFactory()
        let fileSync = FileSyncManager(eventSourceFactory: { MockFileSystemEventSource() })
        let service = makeService(factory: factory, fileSync: fileSync)

        // Capture into locals so async-let bodies don't read MainActor self.
        let ws = workspaceA
        let lang = languageId
        let svc = service

        async let s1 = svc.session(for: ws, languageId: lang)
        async let s2 = svc.session(for: ws, languageId: lang)
        async let s3 = svc.session(for: ws, languageId: lang)
        let sessions = try await [s1, s2, s3]
        XCTAssertTrue(sessions[0] === sessions[1])
        XCTAssertTrue(sessions[1] === sessions[2])

        let watched = await waitUntil {
            let roots = await fileSync.watchedRoots()
            return roots.contains(ws)
        }
        XCTAssertTrue(watched, "precondition: at least one watch must have landed")
        // Allow any erroneous duplicate watches to surface.
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        let roots = await fileSync.watchedRoots()
        let count = roots.filter { $0 == ws }.count
        XCTAssertEqual(
            count,
            1,
            "concurrent dedup-sharing session(for:) callers must collapse to a single watch: roots=\(roots)"
        )
        let made = await factory.clientsMadeCount()
        XCTAssertEqual(
            made,
            1,
            "concurrent dedup must also collapse the LSPClient build to a single invocation"
        )
    }

    // MARK: - 4. shutdownSession triggers FileSyncManager.unwatch

    func test_shutdownSession_triggersUnwatch() async throws {
        let factory = MockLSPSessionFactory()
        let fileSync = FileSyncManager(eventSourceFactory: { MockFileSystemEventSource() })
        let service = makeService(factory: factory, fileSync: fileSync)
        let ws = workspaceA
        let lang = languageId

        _ = try await service.session(for: ws, languageId: lang)
        let watched = await waitUntil {
            let roots = await fileSync.watchedRoots()
            return roots.contains(ws)
        }
        XCTAssertTrue(watched, "precondition: workspace must be watched before shutdown")

        await service.shutdownSession(workspaceRoot: ws, languageId: lang)

        let unwatched = await waitUntil {
            let roots = await fileSync.watchedRoots()
            return !roots.contains(ws)
        }
        XCTAssertTrue(
            unwatched,
            "shutdownSession(workspaceRoot:languageId:) must invoke FileSyncManager.unwatch"
        )
    }

    // MARK: - 5. shutdownAll unwatches every workspace

    func test_shutdownAll_triggersUnwatchAll() async throws {
        let factory = MockLSPSessionFactory()
        let fileSync = FileSyncManager(eventSourceFactory: { MockFileSystemEventSource() })
        let service = makeService(factory: factory, fileSync: fileSync)
        let wsA = workspaceA
        let wsB = workspaceB
        let lang = languageId

        _ = try await service.session(for: wsA, languageId: lang)
        _ = try await service.session(for: wsB, languageId: lang)
        let bothWatched = await waitUntil {
            let roots = await fileSync.watchedRoots()
            return roots.contains(wsA) && roots.contains(wsB)
        }
        XCTAssertTrue(bothWatched, "precondition: both workspaces must be watched before shutdownAll")

        await service.shutdownAll()

        let cleared = await waitUntil {
            let roots = await fileSync.watchedRoots()
            return !roots.contains(wsA) && !roots.contains(wsB)
        }
        XCTAssertTrue(
            cleared,
            "shutdownAll must unwatch every previously-registered workspace from FileSyncManager"
        )
    }

    // MARK: - 6. nil fileSyncManager retains legacy semantics

    func test_nilFileSyncManager_legacyBehavior() async throws {
        let factory = MockLSPSessionFactory()
        // Explicit `nil` — exercises the legacy code path that must keep
        // functioning when callers opt out of FileSync wiring.
        let service = makeService(factory: factory, fileSync: nil)
        let ws = workspaceA
        let lang = languageId

        // Warm cache must still reuse the same LSPSession instance.
        let s1 = try await service.session(for: ws, languageId: lang)
        let s2 = try await service.session(for: ws, languageId: lang)
        XCTAssertTrue(
            s1 === s2,
            "warm-cache reuse must keep working when fileSyncManager is nil"
        )
        let made = await factory.clientsMadeCount()
        XCTAssertEqual(
            made,
            1,
            "warm-cache hit must not rebuild the LSPClient even with a nil fileSyncManager"
        )

        // shutdownSession must clear the cache without crashing.
        await service.shutdownSession(workspaceRoot: ws, languageId: lang)
        let after = await service.currentSessions()
        XCTAssertTrue(
            after.isEmpty,
            "shutdownSession must clear the cache when fileSyncManager is nil"
        )

        // A subsequent build must rebuild a fresh client.
        _ = try await service.session(for: ws, languageId: lang)
        let madeAfter = await factory.clientsMadeCount()
        XCTAssertEqual(
            madeAfter,
            2,
            "post-shutdown re-request must trigger a fresh client build under the nil-fileSync path"
        )
    }
}
