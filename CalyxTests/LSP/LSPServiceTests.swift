//
//  LSPServiceTests.swift
//  Calyx
//
//  Tests for `LSPService`, the @MainActor facade that the Calyx MCP layer
//  uses to obtain a started, ready-to-use `LSPSession` for a given
//  (workspace root, languageId) pair.
//
//  Responsibilities exercised here:
//    - Registry lookup: unknown languageIds throw .languageNotInRegistry.
//    - Executable presence: when the binary is not on PATH the service
//      either throws .languageServerNotAvailable (autoInstall disabled)
//      or attempts an install via `LSPInstaller` (autoInstall enabled).
//    - Warm cache: repeated (workspace, languageId) calls return the
//      same LSPSession instance.
//    - Concurrency dedup: parallel `session(for:)` calls share a single
//      in-flight build.
//    - Workspace isolation: different workspaces map to different sessions.
//    - Introspection: `currentSessions()` reports every open session.
//    - Shutdown: per-session and global shutdown clears the cache.
//    - Idle timeout: a session that has not been accessed for
//      `idleTimeoutSeconds` is shut down automatically.
//    - LRU eviction: when `maxConcurrentSessions` is exceeded the oldest
//      session is shut down.
//
//  TDD phase: RED. None of `LSPService`, `LSPServiceConfig`,
//  `LSPServiceError`, `LSPSessionFactory`, `LSPSessionInfo` exist yet —
//  this file is expected to fail to compile (unresolved identifiers)
//  until the swift-specialist creates `Calyx/Features/LSP/LSPService.swift`.
//

import XCTest
@testable import Calyx

// MARK: - file-private MockLSPSessionFactory

/// Tracks how many `LSPClient` instances were built and arranges for the
/// embedded `InMemoryLSPTransport` to auto-reply to `initialize` and
/// `shutdown` so the surrounding `LSPSession` can complete its handshake
/// without a real server process. The `clientsMade` counter lets tests
/// assert dedup behaviour.
fileprivate actor MockLSPSessionFactory: LSPSessionFactory {

    // MARK: State

    private(set) var clientsMade: Int = 0
    private(set) var executablesRequested: [String] = []
    /// Track every transport handed out so tests can introspect (and so
    /// the sidecar Tasks keep them retained for their lifetime).
    private var transports: [InMemoryLSPTransport] = []
    /// Sidecar tasks driving fake server replies. Retained so they don't
    /// get cancelled by ARC when the local variable falls out of scope.
    private var sidecars: [Task<Void, Never>] = []

    init() {}

    // MARK: Introspection

    func clientsMadeCount() -> Int { clientsMade }
    func executablesRequestedList() -> [String] { executablesRequested }

    // MARK: LSPSessionFactory

    func makeClient(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        workingDirectory: URL?
    ) async throws -> LSPClient {
        clientsMade += 1
        executablesRequested.append(executable)

        let transport = InMemoryLSPTransport()
        transports.append(transport)
        let client = LSPClient(transport: transport)

        // Sidecar Task: poll `transport.sentMessages()` and reply with
        // valid `initialize` / `shutdown` responses so `LSPSession.start()`
        // and `LSPSession.shutdown()` resolve without an external server.
        let sidecar = Task {
            await Self.driveServerReplies(on: transport)
        }
        sidecars.append(sidecar)

        return client
    }

    // MARK: Server simulator

    /// Repeatedly scan the outbound buffer for `initialize` / `shutdown`
    /// JSON-RPC requests and inject matching responses on the inbound
    /// stream. The loop exits when the transport is closed (sentMessages
    /// stops growing and shutdown has been answered).
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
                } else if method == "shutdown", let id = extractId(dict["id"]), !shutdownAnsweredIds.contains(id) {
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

// MARK: - LSPServiceTests

@MainActor
final class LSPServiceTests: XCTestCase {

    // MARK: - Constants

    private let workspaceA = URL(fileURLWithPath: "/tmp/calyx-lsp-service-test-A")
    private let workspaceB = URL(fileURLWithPath: "/tmp/calyx-lsp-service-test-B")
    private let workspaceC = URL(fileURLWithPath: "/tmp/calyx-lsp-service-test-C")

    // MARK: - Helpers

    /// Build a runner configured so `typescript-language-server` is on
    /// PATH and `npm` (its prerequisite) is also present. Tests that
    /// need a missing binary override these per case.
    private func makeReadyRunner() async -> MockCommandRunner {
        let runner = MockCommandRunner()
        await runner.setLocateResult(
            "typescript-language-server",
            url: URL(fileURLWithPath: "/usr/local/bin/typescript-language-server")
        )
        await runner.setLocateResult(
            "npm",
            url: URL(fileURLWithPath: "/usr/local/bin/npm")
        )
        return runner
    }

    private func makeInstaller(runner: any LSPCommandRunner) -> LSPInstaller {
        LSPInstaller(registry: .builtIn(), runner: runner)
    }

    /// Poll until `predicate` becomes true or `timeout` elapses.
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

    // MARK: - 1. Unknown language

    func test_session_unknownLanguage_throwsLanguageNotInRegistry() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig()
        )

        do {
            _ = try await service.session(for: workspaceA, languageId: "klingon")
            XCTFail("expected throw for unknown languageId")
        } catch let err as LSPServiceError {
            XCTAssertEqual(err, .languageNotInRegistry(languageId: "klingon"))
        }

        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 0, "factory must not be invoked for an unknown languageId")
    }

    // MARK: - 2. Executable missing, autoInstall disabled

    func test_session_executableMissing_autoInstallDisabled_throwsLanguageServerNotAvailable() async throws {
        let runner = MockCommandRunner()
        await runner.setLocateResult("typescript-language-server", url: nil)
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig(autoInstall: false)
        )

        do {
            _ = try await service.session(for: workspaceA, languageId: "typescript")
            XCTFail("expected throw when executable is missing and autoInstall is off")
        } catch let err as LSPServiceError {
            switch err {
            case .languageServerNotAvailable(let lang, _):
                XCTAssertEqual(lang, "typescript")
            default:
                XCTFail("expected .languageServerNotAvailable, got \(err)")
            }
        }

        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 0, "factory must not be invoked when executable is missing")
    }

    // MARK: - 3. Executable missing, autoInstall enabled → install attempted

    func test_session_executableMissing_autoInstallEnabled_attemptsInstall() async throws {
        let runner = MockCommandRunner()
        // First locate: missing. After install completes the service
        // should retry locate and find it. MockCommandRunner returns the
        // most recently set value, so we flip it after enqueueing the
        // install success below by using the runHook.
        await runner.setLocateResult("typescript-language-server", url: nil)
        await runner.setLocateResult(
            "npm",
            url: URL(fileURLWithPath: "/usr/local/bin/npm")
        )
        // Enqueue a success for the `npm` install command (the registry's
        // install command for typescript-language-server starts with `npm`).
        await runner.enqueueRunResult(
            "npm",
            result: .success(CommandResult(exitCode: 0, stdout: "", stderr: ""))
        )

        // Flip the locate result to "found" right before the install
        // command returns, so the post-install locate succeeds.
        await runner.setRunHook { exe, _ in
            if exe == "npm" {
                await runner.setLocateResult(
                    "typescript-language-server",
                    url: URL(fileURLWithPath: "/usr/local/bin/typescript-language-server")
                )
            }
        }

        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig(autoInstall: true, installConfirmation: .silent)
        )

        let session = try await service.session(for: workspaceA, languageId: "typescript")
        XCTAssertEqual(session.languageId, "typescript")

        // The installer must have actually run an `npm install`.
        let history = await runner.history()
        XCTAssertTrue(
            history.contains(where: { $0.executable == "npm" }),
            "installer must invoke `npm` for typescript-language-server install"
        )

        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 1, "factory must be invoked exactly once after a successful install")
    }

    // MARK: - 4. Warm cache reuses session

    func test_session_warmCache_reusesSession() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig()
        )

        let first = try await service.session(for: workspaceA, languageId: "typescript")
        let second = try await service.session(for: workspaceA, languageId: "typescript")

        XCTAssertTrue(first === second, "warm cache must return the same LSPSession instance")
        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 1, "factory must build exactly one client for a warm-cached session")
    }

    // MARK: - 5. Concurrent calls dedup

    func test_session_concurrentCalls_dedup() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig()
        )

        let ws = workspaceA
        async let a = service.session(for: ws, languageId: "typescript")
        async let b = service.session(for: ws, languageId: "typescript")
        async let c = service.session(for: ws, languageId: "typescript")

        let sessions = try await [a, b, c]
        XCTAssertTrue(sessions[0] === sessions[1])
        XCTAssertTrue(sessions[1] === sessions[2])

        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 1, "concurrent session(for:) calls must share a single in-flight build")
    }

    // MARK: - 6. Different workspaces produce different sessions

    func test_session_differentWorkspaces_returnsDifferent() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig()
        )

        let sessionA = try await service.session(for: workspaceA, languageId: "typescript")
        let sessionB = try await service.session(for: workspaceB, languageId: "typescript")

        XCTAssertFalse(sessionA === sessionB, "distinct workspaces must produce distinct sessions")
        XCTAssertEqual(sessionA.workspaceRoot, workspaceA)
        XCTAssertEqual(sessionB.workspaceRoot, workspaceB)

        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 2, "each new (workspace, language) pair must build a new client")
    }

    // MARK: - 7. currentSessions reports every open session

    func test_currentSessions_returnsAllOpenSessions() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig()
        )

        _ = try await service.session(for: workspaceA, languageId: "typescript")
        _ = try await service.session(for: workspaceB, languageId: "typescript")

        let infos = await service.currentSessions()
        XCTAssertEqual(infos.count, 2, "currentSessions must surface every open session")

        let roots = Set(infos.map { $0.workspaceRoot })
        XCTAssertEqual(roots, Set([workspaceA, workspaceB]))
        for info in infos {
            XCTAssertEqual(info.languageId, "typescript")
            XCTAssertGreaterThan(
                info.createdAtUptimeMillis,
                0,
                "createdAtUptimeMillis must be a positive process-uptime value"
            )
        }
    }

    // MARK: - 8. Specific shutdown removes from cache

    func test_shutdownSession_specific_removesFromCache() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig()
        )

        _ = try await service.session(for: workspaceA, languageId: "typescript")
        _ = try await service.session(for: workspaceB, languageId: "typescript")

        await service.shutdownSession(workspaceRoot: workspaceA, languageId: "typescript")

        let infos = await service.currentSessions()
        XCTAssertEqual(infos.count, 1, "only the unshut session must remain")
        XCTAssertEqual(infos.first?.workspaceRoot, workspaceB)

        // Re-requesting the shut workspace must rebuild a fresh session.
        _ = try await service.session(for: workspaceA, languageId: "typescript")
        let made = await factory.clientsMadeCount()
        XCTAssertEqual(made, 3, "post-shutdown re-request must trigger a fresh client build")
    }

    // MARK: - 9. shutdownAll clears all sessions

    func test_shutdownAll_clearsAllSessions() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig()
        )

        _ = try await service.session(for: workspaceA, languageId: "typescript")
        _ = try await service.session(for: workspaceB, languageId: "typescript")
        _ = try await service.session(for: workspaceC, languageId: "typescript")

        await service.shutdownAll()

        let infos = await service.currentSessions()
        XCTAssertTrue(infos.isEmpty, "shutdownAll must clear every cached session")
    }

    // MARK: - 10. Idle timeout triggers shutdown

    func test_idleTimeout_triggersShutdown() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig(idleTimeoutSeconds: 1)
        )

        _ = try await service.session(for: workspaceA, languageId: "typescript")
        let initialInfos = await service.currentSessions()
        XCTAssertEqual(initialInfos.count, 1, "session must be present immediately after creation")

        // Wait beyond the idle window. The service should observe the
        // last-access timestamp and shut the session down.
        let expired = await waitUntil(timeout: 4.0, pollInterval: 0.1) {
            let infos = await service.currentSessions()
            return infos.isEmpty
        }
        XCTAssertTrue(expired, "session must be shut down after idleTimeoutSeconds elapses")
    }

    // MARK: - 11. LRU eviction when over capacity

    func test_lru_evictsOldestWhenOverCapacity() async throws {
        let runner = await makeReadyRunner()
        let installer = makeInstaller(runner: runner)
        let factory = MockLSPSessionFactory()
        let service = LSPService(
            registry: .builtIn(),
            installer: installer,
            sessionFactory: factory,
            config: LSPServiceConfig(maxConcurrentSessions: 2)
        )

        _ = try await service.session(for: workspaceA, languageId: "typescript")
        // Small gap so the LRU timestamps are distinguishable.
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        _ = try await service.session(for: workspaceB, languageId: "typescript")
        try? await Task.sleep(nanoseconds: 20_000_000)
        _ = try await service.session(for: workspaceC, languageId: "typescript")

        let infos = await service.currentSessions()
        XCTAssertEqual(infos.count, 2, "cache must respect maxConcurrentSessions")

        let roots = Set(infos.map { $0.workspaceRoot })
        XCTAssertFalse(
            roots.contains(workspaceA),
            "oldest workspace (A) must have been evicted by LRU policy"
        )
        XCTAssertTrue(roots.contains(workspaceB))
        XCTAssertTrue(roots.contains(workspaceC))
    }
}
