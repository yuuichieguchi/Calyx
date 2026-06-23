//
//  FileSyncManagerTests.swift
//  Calyx
//
//  Tests for `FileSyncManager`, the actor that bridges file-system events
//  (FSEvents in production, manual emission in tests) to LSP 3.18
//  textDocument and workspace synchronisation notifications on a
//  per-(workspaceRoot, session) basis.
//
//  Coverage:
//    - Lifecycle bookkeeping: watch / unwatch / stopAll mutate the set of
//      tracked workspace roots correctly.
//    - Event translation:
//      * `modified` on an open document  -> textDocument/didChange
//      * `modified` on an unopened path  -> workspace/didChangeWatchedFiles
//      * `removed`  on an open document  -> textDocument/didClose + open-set
//        eviction (plus workspace/didChangeWatchedFiles for the deletion)
//      * `created`                       -> workspace/didChangeWatchedFiles
//      * `renamed`                       -> didClose old + didOpen new
//    - `suppressNextEvent(at:)` masks exactly one subsequent event for
//      that path (e.g. Calyx-side writes echo back through FSEvents).
//    - Multiple watched workspaces route events to their own sessions
//      without bleed-through.
//    - `watch` for an already-watched root is a no-op; `unwatch` for an
//      unknown root is a no-op.
//
//  TDD phase: RED. None of `FileSyncManager`, `FileSystemEventSource`,
//  `FileSystemEvent`, `FSEventsEventSource`, or `MockFileSystemEventSource`
//  exist yet. This file is expected to fail to compile until the
//  swift-specialist implements them under
//  `Calyx/Features/LSP/FileSyncManager.swift`.
//

import XCTest
@testable import Calyx

/// Captures every `MockFileSystemEventSource` produced by an
/// `eventSourceFactory` closure. Lets the per-workspace event-source
/// regression test reach into the manager's internal sources without
/// exposing them on the production surface. Synchronised through an
/// `NSLock` so the factory closure stays `@Sendable`.
private final class MockEventSourceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _mocks: [MockFileSystemEventSource] = []

    func makeMock() -> MockFileSystemEventSource {
        let m = MockFileSystemEventSource()
        lock.lock()
        _mocks.append(m)
        lock.unlock()
        return m
    }

    func mocks() -> [MockFileSystemEventSource] {
        lock.lock()
        defer { lock.unlock() }
        return _mocks
    }
}

@MainActor
final class FileSyncManagerTests: XCTestCase {

    // MARK: - Constants

    private let testLanguageId = "swift"

    // MARK: - Framing & JSON helpers (mirror LSPSessionTests)

    private func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    private func jsonRPCResponse(id: Int, resultJSON: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#
    }

    private func initializeResultJSON() -> String {
        return #"{"capabilities":{},"serverInfo":{"name":"test-lsp","version":"0.0.1"}}"#
    }

    /// Parse every consecutive framed JSON message in `data` into dictionaries.
    private func parseAllFramedJSON(_ data: Data) throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let slice = data.subdata(in: cursor..<data.endIndex)
            guard let headerEnd = slice.range(of: Data("\r\n\r\n".utf8)) else { break }
            let headerData = slice.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else { break }
            var contentLength = 0
            for line in headerString.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLength = Int(parts[1]) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + contentLength
            guard bodyEnd <= slice.endIndex else { break }
            let body = slice.subdata(in: bodyStart..<bodyEnd)
            if let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                results.append(dict)
            }
            cursor = cursor + bodyEnd
        }
        return results
    }

    /// Collect the methods (in order) the session emitted to `transport`.
    private func sentMethods(_ transport: InMemoryLSPTransport) async throws -> [String] {
        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        return dicts.map { ($0["method"] as? String) ?? "" }
    }

    /// Collect every framed JSON message dict the session emitted to `transport`.
    private func sentDicts(_ transport: InMemoryLSPTransport) async throws -> [[String: Any]] {
        let sent = await transport.sentMessages()
        return try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
    }

    /// Poll until predicate becomes true or timeout elapses.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.005,
        _ predicate: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return await predicate()
    }

    // MARK: - Session setup

    /// Spin up a fully-initialised `LSPSession` with an `InMemoryLSPTransport`
    /// underneath. Returns once the session is in `.running`.
    private func makeStartedSession(
        workspaceRoot: URL
    ) async throws -> (LSPSession, InMemoryLSPTransport) {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        let session = LSPSession(
            workspaceRoot: workspaceRoot,
            languageId: testLanguageId,
            client: client
        )

        // Respond to the initialize request the session is about to send.
        let frame = self.lspFrame
        let respondTask = Task { [transport] in
            for _ in 0..<400 {
                let sent = await transport.sentMessages()
                for data in sent {
                    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
                    let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
                    guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                          (dict["method"] as? String) == "initialize",
                          let idAny = dict["id"]
                    else { continue }
                    let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                    let body2 = #"{"jsonrpc":"2.0","id":\#(idInt),"result":{"capabilities":{},"serverInfo":{"name":"test-lsp","version":"0.0.1"}}}"#
                    await transport.simulateServerMessage(frame(body2))
                    return
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        try await session.start()
        _ = await respondTask.value
        return (session, transport)
    }

    /// Build a unique workspace root URL under the temp directory.
    private func makeWorkspaceRoot(_ name: String = "ws") -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calyx-fs-sync-\(UUID().uuidString)")
            .appendingPathComponent(name)
        return base
    }

    // MARK: - 1. watch adds workspace to watchedRoots

    func test_watch_addsWorkspaceToWatchedRoots() async throws {
        let ws = makeWorkspaceRoot("alpha")
        let (session, _) = try await makeStartedSession(workspaceRoot: ws)

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })

        try await manager.watch(workspaceRoot: ws, session: session)

        let roots = await manager.watchedRoots()
        XCTAssertTrue(roots.contains(ws), "watch must add the workspace to watchedRoots(): got \(roots)")
    }

    // MARK: - 2. unwatch removes workspace from watchedRoots

    func test_unwatch_removesWorkspaceFromWatchedRoots() async throws {
        let ws = makeWorkspaceRoot("beta")
        let (session, _) = try await makeStartedSession(workspaceRoot: ws)

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })

        try await manager.watch(workspaceRoot: ws, session: session)
        await manager.unwatch(workspaceRoot: ws)

        let roots = await manager.watchedRoots()
        XCTAssertFalse(roots.contains(ws), "unwatch must remove the workspace from watchedRoots(): got \(roots)")
    }

    // MARK: - 3. stopAll clears every watched root

    func test_stopAll_clearsAllWatchedRoots() async throws {
        let wsA = makeWorkspaceRoot("a")
        let wsB = makeWorkspaceRoot("b")
        let (sessionA, _) = try await makeStartedSession(workspaceRoot: wsA)
        let (sessionB, _) = try await makeStartedSession(workspaceRoot: wsB)

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })

        try await manager.watch(workspaceRoot: wsA, session: sessionA)
        try await manager.watch(workspaceRoot: wsB, session: sessionB)

        await manager.stopAll()

        let roots = await manager.watchedRoots()
        XCTAssertTrue(roots.isEmpty, "stopAll must empty watchedRoots(): got \(roots)")
    }

    // MARK: - 4. modified on an open file -> textDocument/didChange

    func test_modified_eventForOpenFile_sendsDidChange() async throws {
        let ws = makeWorkspaceRoot("modOpen")
        let (session, transport) = try await makeStartedSession(workspaceRoot: ws)

        // Materialise the file so the manager can read its contents when it
        // builds the full-document replacement payload for didChange.
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let fileURL = ws.appendingPathComponent("main.swift")
        try "print(1)\n".write(to: fileURL, atomically: true, encoding: .utf8)

        try await session.didOpen(
            uri: fileURL.absoluteString,
            languageId: testLanguageId,
            version: 1,
            text: "print(1)\n"
        )

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: ws, session: session)

        // Update the file on disk (so any read inside the manager observes
        // the new content) and emit a `modified` event for it.
        try "print(2)\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await mock.emit([FileSystemEvent(path: fileURL, kind: .modified)])

        // Wait for the didChange notification to land in the transport.
        let saw = await waitUntil {
            let methods = (try? await self.sentMethods(transport)) ?? []
            return methods.contains("textDocument/didChange")
        }
        XCTAssertTrue(saw, "modified event for an open file must produce textDocument/didChange")

        let dicts = try await sentDicts(transport)
        let changes = dicts.filter { ($0["method"] as? String) == "textDocument/didChange" }
        XCTAssertEqual(changes.count, 1, "exactly one didChange must be sent for one modified event")
        let params = changes[0]["params"] as? [String: Any]
        let td = params?["textDocument"] as? [String: Any]
        XCTAssertEqual(td?["uri"] as? String, fileURL.absoluteString,
                       "didChange URI must match the modified file URI")
    }

    // MARK: - 5. modified on an unopened file -> workspace/didChangeWatchedFiles

    func test_modified_eventForUnopenedFile_sendsDidChangeWatchedFiles() async throws {
        let ws = makeWorkspaceRoot("modUnopen")
        let (session, transport) = try await makeStartedSession(workspaceRoot: ws)

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let fileURL = ws.appendingPathComponent("README.md")
        try "old".write(to: fileURL, atomically: true, encoding: .utf8)

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: ws, session: session)

        await mock.emit([FileSystemEvent(path: fileURL, kind: .modified)])

        let saw = await waitUntil {
            let methods = (try? await self.sentMethods(transport)) ?? []
            return methods.contains("workspace/didChangeWatchedFiles")
        }
        XCTAssertTrue(saw, "modified event for an unopened file must produce workspace/didChangeWatchedFiles")

        let methods = try await sentMethods(transport)
        XCTAssertFalse(methods.contains("textDocument/didChange"),
                       "no textDocument/didChange must be sent for an unopened file (got methods=\(methods))")
    }

    // MARK: - 6. removed on an open file -> didClose + open-set eviction

    func test_removed_eventForOpenFile_sendsDidClose_andRemovesFromOpenSet() async throws {
        let ws = makeWorkspaceRoot("rm")
        let (session, transport) = try await makeStartedSession(workspaceRoot: ws)

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let fileURL = ws.appendingPathComponent("doomed.swift")
        try "x".write(to: fileURL, atomically: true, encoding: .utf8)

        try await session.didOpen(
            uri: fileURL.absoluteString,
            languageId: testLanguageId,
            version: 1,
            text: "x"
        )
        let openBefore = await session.openDocuments()
        XCTAssertTrue(openBefore.contains(fileURL.absoluteString), "precondition: file is open")

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: ws, session: session)

        try? FileManager.default.removeItem(at: fileURL)
        await mock.emit([FileSystemEvent(path: fileURL, kind: .removed)])

        let saw = await waitUntil {
            let methods = (try? await self.sentMethods(transport)) ?? []
            return methods.contains("textDocument/didClose")
        }
        XCTAssertTrue(saw, "removed event for an open file must produce textDocument/didClose")

        // Open set must drop the URI.
        let openAfter = await session.openDocuments()
        XCTAssertFalse(openAfter.contains(fileURL.absoluteString),
                       "removed event must evict the URI from the session open set")
    }

    // MARK: - 7. created -> workspace/didChangeWatchedFiles

    func test_created_eventSendsDidChangeWatchedFiles() async throws {
        let ws = makeWorkspaceRoot("create")
        let (session, transport) = try await makeStartedSession(workspaceRoot: ws)

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let fileURL = ws.appendingPathComponent("new.swift")

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: ws, session: session)

        try "fresh".write(to: fileURL, atomically: true, encoding: .utf8)
        await mock.emit([FileSystemEvent(path: fileURL, kind: .created)])

        let saw = await waitUntil {
            let methods = (try? await self.sentMethods(transport)) ?? []
            return methods.contains("workspace/didChangeWatchedFiles")
        }
        XCTAssertTrue(saw, "created event must produce workspace/didChangeWatchedFiles")
    }

    // MARK: - 8. renamed -> didClose old + didOpen new

    func test_renamed_eventTranslatesToCloseAndOpen() async throws {
        let ws = makeWorkspaceRoot("rename")
        let (session, transport) = try await makeStartedSession(workspaceRoot: ws)

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let oldURL = ws.appendingPathComponent("old.swift")
        let newURL = ws.appendingPathComponent("new.swift")
        try "body".write(to: oldURL, atomically: true, encoding: .utf8)

        try await session.didOpen(
            uri: oldURL.absoluteString,
            languageId: testLanguageId,
            version: 1,
            text: "body"
        )

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: ws, session: session)

        // Move the file then emit a `renamed` event for the original path.
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        await mock.emit([FileSystemEvent(path: oldURL, kind: .renamed(to: newURL))])

        let saw = await waitUntil {
            let methods = (try? await self.sentMethods(transport)) ?? []
            return methods.contains("textDocument/didClose") && methods.contains("textDocument/didOpen")
        }
        XCTAssertTrue(saw, "renamed of an open file must yield both didClose (old) and didOpen (new)")

        let dicts = try await sentDicts(transport)
        let closeMsgs = dicts.filter { ($0["method"] as? String) == "textDocument/didClose" }
        let openMsgsAfterStart = dicts
            .filter { ($0["method"] as? String) == "textDocument/didOpen" }
            // Drop the original didOpen issued before the rename.
            .dropFirst()
        XCTAssertTrue(closeMsgs.contains { dict in
            let p = dict["params"] as? [String: Any]
            let td = p?["textDocument"] as? [String: Any]
            return (td?["uri"] as? String) == oldURL.absoluteString
        }, "didClose must reference the old URI")
        XCTAssertTrue(openMsgsAfterStart.contains { dict in
            let p = dict["params"] as? [String: Any]
            let td = p?["textDocument"] as? [String: Any]
            return (td?["uri"] as? String) == newURL.absoluteString
        }, "post-rename didOpen must reference the new URI")
    }

    // MARK: - 9. suppressNextEvent silences exactly one event for that path

    func test_suppressNextEvent_silencesOneEvent() async throws {
        let ws = makeWorkspaceRoot("suppress")
        let (session, transport) = try await makeStartedSession(workspaceRoot: ws)

        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let fileURL = ws.appendingPathComponent("foo.swift")
        try "v1".write(to: fileURL, atomically: true, encoding: .utf8)

        try await session.didOpen(
            uri: fileURL.absoluteString,
            languageId: testLanguageId,
            version: 1,
            text: "v1"
        )

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })
        try await manager.watch(workspaceRoot: ws, session: session)

        // First modification: should be suppressed by `suppressNextEvent`.
        await manager.suppressNextEvent(at: fileURL)
        try "v2".write(to: fileURL, atomically: true, encoding: .utf8)
        await mock.emit([FileSystemEvent(path: fileURL, kind: .modified)])

        // Give the manager time to (potentially) react.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let methodsAfterFirst = try await sentMethods(transport)
        XCTAssertFalse(methodsAfterFirst.contains("textDocument/didChange"),
                       "suppressNextEvent(at:) must mask the very next event for that path: methods=\(methodsAfterFirst)")

        // Second modification: must flow through normally.
        try "v3".write(to: fileURL, atomically: true, encoding: .utf8)
        await mock.emit([FileSystemEvent(path: fileURL, kind: .modified)])

        let saw = await waitUntil {
            let methods = (try? await self.sentMethods(transport)) ?? []
            return methods.contains("textDocument/didChange")
        }
        XCTAssertTrue(saw, "second modified event after suppression should produce didChange")

        let dicts = try await sentDicts(transport)
        let changes = dicts.filter { ($0["method"] as? String) == "textDocument/didChange" }
        XCTAssertEqual(changes.count, 1,
                       "exactly one didChange must be observed after one suppressed + one live event")
    }

    // MARK: - 10. multiple workspaces -> independent monitoring

    func test_multipleWorkspaces_independentMonitoring() async throws {
        let wsA = makeWorkspaceRoot("multA")
        let wsB = makeWorkspaceRoot("multB")
        let (sessionA, transportA) = try await makeStartedSession(workspaceRoot: wsA)
        let (sessionB, transportB) = try await makeStartedSession(workspaceRoot: wsB)

        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        let fileA = wsA.appendingPathComponent("a.swift")
        let fileB = wsB.appendingPathComponent("b.swift")
        try "a".write(to: fileA, atomically: true, encoding: .utf8)
        try "b".write(to: fileB, atomically: true, encoding: .utf8)

        // Independent managers + independent mocks, mirroring the
        // production wiring where each workspace gets its own FSEvents
        // stream owned by a single `FileSyncManager` instance.
        let mockA = MockFileSystemEventSource()
        let mockB = MockFileSystemEventSource()
        let managerA = FileSyncManager(eventSourceFactory: { mockA })
        let managerB = FileSyncManager(eventSourceFactory: { mockB })
        try await managerA.watch(workspaceRoot: wsA, session: sessionA)
        try await managerB.watch(workspaceRoot: wsB, session: sessionB)

        // Emit an event only on workspace A.
        await mockA.emit([FileSystemEvent(path: fileA, kind: .created)])

        let sawA = await waitUntil {
            let methods = (try? await self.sentMethods(transportA)) ?? []
            return methods.contains("workspace/didChangeWatchedFiles")
        }
        XCTAssertTrue(sawA, "workspace A must receive its event")

        // Workspace B must not see workspace A's traffic.
        let methodsB = try await sentMethods(transportB)
        XCTAssertFalse(methodsB.contains("workspace/didChangeWatchedFiles"),
                       "workspace B must not receive A's events: methodsB=\(methodsB)")
        XCTAssertFalse(methodsB.contains("textDocument/didChange"),
                       "workspace B must not receive A's didChange traffic")
    }

    // MARK: - 11. watch on an already-watched workspace is a no-op

    func test_watch_alreadyWatching_isNoOp() async throws {
        let ws = makeWorkspaceRoot("dupwatch")
        let (session, _) = try await makeStartedSession(workspaceRoot: ws)

        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })

        try await manager.watch(workspaceRoot: ws, session: session)
        // Second watch must not throw and must leave watchedRoots() unchanged.
        try await manager.watch(workspaceRoot: ws, session: session)

        let roots = await manager.watchedRoots()
        let count = roots.filter { $0 == ws }.count
        XCTAssertEqual(count, 1,
                       "watch on an already-watched root must not register a duplicate entry: roots=\(roots)")
    }

    // MARK: - 12. unwatch on an unknown workspace is a no-op

    func test_unwatch_unknownWorkspace_isNoOp() async throws {
        let ws = makeWorkspaceRoot("unknown")
        let mock = MockFileSystemEventSource()
        let manager = FileSyncManager(eventSourceFactory: { mock })

        // Must not throw / crash.
        await manager.unwatch(workspaceRoot: ws)

        let roots = await manager.watchedRoots()
        XCTAssertTrue(roots.isEmpty,
                      "unwatch on an unknown workspace must be a no-op and leave watchedRoots() empty: \(roots)")
    }

    // MARK: - 13. single manager watching two workspaces — second workspace
    //              still receives its events (per-workspace event source).

    /// Regression test for the "single FileSystemEventSource, multiple
    /// workspaces" bug: `FSEventsEventSource.start(...)` silently no-ops
    /// when a stream is already active, so a single shared source would
    /// drop every event for the second-and-later workspace registered
    /// against the same manager. The fix is that `FileSyncManager` builds
    /// one event source per `watch(workspaceRoot:session:)` call via the
    /// injected factory; this test asserts events emitted on the second
    /// workspace's source land on the second session's transport without
    /// bleeding through to the first.
    func test_watchSecondWorkspace_receivesEvents() async throws {
        let wsA = makeWorkspaceRoot("perWsA")
        let wsB = makeWorkspaceRoot("perWsB")
        let (sessionA, transportA) = try await makeStartedSession(workspaceRoot: wsA)
        let (sessionB, transportB) = try await makeStartedSession(workspaceRoot: wsB)

        try FileManager.default.createDirectory(at: wsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wsB, withIntermediateDirectories: true)
        let fileB = wsB.appendingPathComponent("only-on-b.swift")
        try "b".write(to: fileB, atomically: true, encoding: .utf8)

        // A single FileSyncManager. The factory hands out a fresh mock per
        // watch() call and the capture lets us reach the second mock so we
        // can drive an event into the wsB pipeline specifically.
        let capture = MockEventSourceCapture()
        let manager = FileSyncManager(eventSourceFactory: { capture.makeMock() })

        try await manager.watch(workspaceRoot: wsA, session: sessionA)
        try await manager.watch(workspaceRoot: wsB, session: sessionB)

        let mocks = capture.mocks()
        XCTAssertEqual(
            mocks.count,
            2,
            "FileSyncManager must build one event source per watch() call: got \(mocks.count)"
        )

        // Emit ONLY on the second workspace's mock. Under the old "single
        // shared eventSource" wiring this would land nowhere because the
        // second start(...) call was a no-op.
        await mocks[1].emit([FileSystemEvent(path: fileB, kind: .created)])

        let sawOnB = await waitUntil {
            let methods = (try? await self.sentMethods(transportB)) ?? []
            return methods.contains("workspace/didChangeWatchedFiles")
        }
        XCTAssertTrue(
            sawOnB,
            "an event emitted on the second workspace's source must reach the second session"
        )

        // Workspace A's transport must not have observed B's event.
        let methodsA = try await sentMethods(transportA)
        XCTAssertFalse(
            methodsA.contains("workspace/didChangeWatchedFiles"),
            "workspace A must not receive workspace B's events: methodsA=\(methodsA)"
        )
    }
}
