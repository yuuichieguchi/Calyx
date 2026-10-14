//
//  CalyxMCPServerIPCWakeTests.swift
//  CalyxTests
//
//  Pins `POST /ipc-wake` on CalyxMCPServer: the request the client
//  long-polling `/ipc-wake` holds open, answered with 200 and a short note
//  when the surface's peer has messages it has not been told about yet,
//  otherwise 204. Same harness as CalyxMCPServerApprovalRequestTests: HTTPRequest
//  values driven straight through `server.route(request:)`, an isolated
//  `agent-endpoint.json` directory, a fresh AgentRegistry and an isolated
//  IPCWakeSettings suite. The server is started (`start()` on a
//  kernel-assigned port) because `start()` is what connects the store's
//  inbox-growth sink to the coordinator: a message reaching the store by
//  any path then requests a check.
//
//  Coverage:
//  - ipcWakeTimeoutMs defaults to IPCWakeHookTiming.serverTimeoutMs
//  - Bearer auth (401), unresolvable surface (400), and their order: the
//    bearer is checked before the surface, the surface before the kind
//  - X-Calyx-Agent-Kind present and not "claude-code": 204 at once
//  - IPCWakeSettings.enabled == false: 204 at once, no waiter registered
//  - Surface bound to nothing: 204 after the timeout
//  - X-Calyx-Wake-Nonce absent or not a canonical uppercase UUID: 400, no
//    waiter, message un-nudged; guard order bearer 401 -> surface 400 ->
//    kind 204 -> setting-off 204 -> nonce 400
//  - A wake: 200, Content-Type "text/plain; charset=utf-8", body of two
//    lines: the proof over nonce + "\n" + note under the server's key
//    (derived in the test from the two blocks start() wrote into
//    agent-endpoint.json), then the note; the note names the recipient's
//    own peer id and none of the sender's name, role or message content
//  - start() writes new blocks every time; after a restart the body is
//    proved with the new key; no response body or header carries a block
//  - A poll that is already waiting is woken by a send_message or
//    broadcast tools/call once initialize or register_peer bound its
//    surface, by a message put straight into the store (no tools/call at
//    all), and by a hook event that binds its surface to a peer that
//    already has un-nudged messages
//  - Each message wakes at most once; a newer message wakes again
//  - A second poll for the same surface makes the first return 204;
//    server.stop() and cancelling the route's Task end a waiting poll,
//    leaving the message un-nudged
//  - receive_messages output carries no `nudged` key
//
//  Synchronisation: "nothing happened" is never concluded from elapsed
//  time. A poll that must not be woken gets a 30 s timeout; the test waits
//  until it is registered and the coordinator's `_testChecksInFlight` is
//  0, asserts it is still waiting, and then ends it explicitly.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerIPCWakeTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private let testToken = "ipc-wake-test-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerIPCWakeTests"

    /// Test-isolated `agent-endpoint.json` directory, written by
    /// `start()` and removed by `stopAndWait()`.
    private var agentEndpointDir: String!

    /// Timeout of every poll that is ended by an event other than its
    /// timeout. Far beyond any test's runtime, so the timeout never wins.
    private let longTimeoutMs = 30_000
    /// Upper bound for "ended because of the event, not the 30 s timeout".
    private let promptBound: Duration = .seconds(10)

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        IPCWakeSettings._testUseSuite(named: settingsSuiteName)
        IPCWakeSettings.enabled = true
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        registry = AgentRegistry()
        server.agentRegistry = registry
        server.approvalInbox = ApprovalInboxStore()
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server.ipcWakeTimeoutMs = longTimeoutMs
        try await server.start(token: testToken, preferredPort: 0)
    }

    override func tearDown() async throws {
        await server.stopAndWait()
        server = nil
        registry = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        IPCWakeSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    // MARK: - Request-building helpers

    /// The nonce every poll sends unless a test chooses another: a
    /// canonical uppercase UUID, as the wake hook sends it.
    private let defaultNonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"

    /// The request header carrying the poll's nonce (spec A.3: the value of
    /// `IPCWakeResponse.nonceHeader`), spelled out so this file compiles
    /// before that constant exists.
    private let nonceHeaderName = "X-Calyx-Wake-Nonce"

    /// `nonce` nil sends no nonce header; the default sends `defaultNonce`.
    private func wakeRequest(
        token: String?,
        surfaceIDHeader: String?,
        kindHeader: String? = nil,
        nonce: String?? = .some(nil)
    ) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        if let kindHeader { headers["X-Calyx-Agent-Kind"] = kindHeader }
        switch nonce {
        case .some(.some(let value)): headers[nonceHeaderName] = value
        case .some(.none): headers[nonceHeaderName] = defaultNonce
        case .none: break
        }
        return HTTPRequest(method: "POST", path: "/ipc-wake", headers: headers, body: nil)
    }

    private func poll(_ surfaceID: UUID, nonce: String? = nil) async -> HTTPResponse {
        await server.route(request: wakeRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, nonce: .some(nonce)
        ))
    }

    /// A poll that sends no nonce header at all.
    private func pollWithoutNonce(_ surfaceID: UUID, kindHeader: String? = nil) async -> HTTPResponse {
        await server.route(request: wakeRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString, kindHeader: kindHeader, nonce: .none
        ))
    }

    private func startPoll(_ surfaceID: UUID, nonce: String? = nil) -> Task<HTTPResponse, Never> {
        Task { @MainActor in
            await self.poll(surfaceID, nonce: nonce)
        }
    }

    private func agentEventRequest(surfaceID: UUID, body: Data) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: "/agent-event",
            headers: ["Authorization": "Bearer \(testToken)", "X-Calyx-Surface-ID": surfaceID.uuidString],
            body: body
        )
    }

    private func rpcRequest(id: Int, method: String, params: [String: Any]) -> Data {
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        return try! JSONSerialization.data(withJSONObject: dict)
    }

    private func initializeRequestBody() -> Data {
        rpcRequest(id: 1, method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "test", "version": "1.0"],
        ])
    }

    /// Runs one `tools/call` through `handleJSONRPC` and returns the text
    /// of its result, failing if the call reported an error.
    @discardableResult
    private func callTool(
        _ toolName: String, _ arguments: [String: Any], surfaceID: UUID? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> String {
        let data = rpcRequest(id: 2, method: "tools/call", params: ["name": toolName, "arguments": arguments])
        let (statusCode, body) = await server.handleJSONRPC(data: data, authToken: testToken, surfaceID: surfaceID)
        XCTAssertEqual(statusCode, 200, file: file, line: line)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(body, file: file, line: line)) as? [String: Any],
            file: file, line: line
        )
        let result = try XCTUnwrap(json["result"] as? [String: Any], file: file, line: line)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]], file: file, line: line)
        let text = try XCTUnwrap(content.first?["text"] as? String, file: file, line: line)
        XCTAssertFalse(result["isError"] as? Bool ?? false, "\(toolName) failed: \(text)", file: file, line: line)
        return text
    }

    /// Registers a peer through the `register_peer` tool and returns its id.
    private func registerPeerViaTool(name: String, role: String = "terminal", surfaceID: UUID? = nil) async throws -> UUID {
        let text = try await callTool("register_peer", ["name": name, "role": role], surfaceID: surfaceID)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return try XCTUnwrap(UUID(uuidString: try XCTUnwrap(json["peerId"] as? String)))
    }

    /// Registers a peer straight in the store, with no tools/call.
    private func registerPeerInStore(_ name: String, role: String = "terminal") async -> UUID {
        await server.store.registerPeer(name: name, role: role).id
    }

    /// Delivers a message straight through the store, with no tools/call.
    /// The server was started, so the store's inbox sink requests a check
    /// for the recipient.
    private func deliverInStore(from sender: UUID, to recipient: UUID, _ content: String = "hello") async throws {
        _ = try await server.store.sendMessage(from: sender, to: recipient, content: content)
    }

    // MARK: - Waiting helpers

    /// Polls `condition` until it holds or `timeout` passes.
    private func waitUntil(timeout: TimeInterval = 10.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func waitForWaitingPoll(_ surfaceID: UUID) async -> Bool {
        await waitUntil { self.server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surfaceID) }
    }

    /// Waits until the poll for `surfaceID` is registered and every check
    /// requested so far has returned from the store, then asserts the poll
    /// is still waiting: nothing that has happened up to now ended it. A
    /// message delivered afterwards can only be noticed by a later check.
    private func assertWaitingAfterChecksIdle(
        _ surfaceID: UUID, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let registered = await waitForWaitingPoll(surfaceID)
        XCTAssertTrue(registered, "the poll must be registered while route(request:) is suspended",
                      file: file, line: line)
        let idle = await waitUntil { self.server.ipcWakeCoordinator._testChecksInFlight == 0 }
        XCTAssertTrue(idle, "every requested check must finish", file: file, line: line)
        XCTAssertTrue(server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surfaceID),
                      "the poll must still be waiting once every requested check has finished",
                      file: file, line: line)
    }

    private func expectedNote(peer: UUID, new: Int, senders: Int, unread: Int) -> String {
        IPCWakeResponse(
            peerID: peer,
            ticket: IPCWakeTicket(newCount: new, senderCount: senders, unreadCount: unread)
        ).note
    }

    /// The 200 body the server owes a poll that sent `nonce`: line 1 is the
    /// proof over `nonce + "\n" + note` under the server's current key,
    /// line 2 the note, no trailing newline. The proof is derived from the
    /// two blocks `start()` wrote into agent-endpoint.json
    /// (SHA256(outer || SHA256(inner || message))), so no accessor for the
    /// key itself is needed. nil when the endpoint file carries no blocks.
    private func expectedBody(nonce: String? = nil, peer: UUID, new: Int, senders: Int, unread: Int) -> Data? {
        let note = expectedNote(peer: peer, new: new, senders: senders, unread: unread)
        guard let blocks = IPCWakeTestCrypto.readEndpointBlocks(directory: agentEndpointDir),
              let proof = IPCWakeTestCrypto.proofFromBlocks(
                  innerHex: blocks.inner, outerHex: blocks.outer, nonce: nonce ?? defaultNonce, note: note
              )
        else { return nil }
        return Data((proof + "\n" + note).utf8)
    }

    private func flags(_ peerID: UUID) async -> [Bool] {
        await server.store._testNudgedFlags(for: peerID)
    }

    // MARK: - Default timeout

    func test_defaultTimeout_isIPCWakeHookTimingServerTimeout() {
        let freshServer = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)

        XCTAssertEqual(freshServer.ipcWakeTimeoutMs, IPCWakeHookTiming.serverTimeoutMs)
        XCTAssertEqual(freshServer.ipcWakeTimeoutMs, 570_000,
                       "the default /ipc-wake long-poll timeout must be 570_000 ms")
    }

    // MARK: - Authentication

    func test_route_missingOrWrongBearer_returns401() async throws {
        // The surface's peer has a message, so an authenticated poll
        // would answer 200: only the bearer check can produce the 401.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)
        let cases: [(label: String, token: String?)] = [
            ("missing", nil),
            ("wrong", "wrong-token"),
        ]

        for testCase in cases {
            let response = await server.route(
                request: wakeRequest(token: testCase.token, surfaceIDHeader: surface.uuidString)
            )

            XCTAssertEqual(response.statusCode, 401, "[\(testCase.label) bearer] must return 401")
            XCTAssertNil(response.body, "[\(testCase.label) bearer] a 401 must carry an empty body")
        }
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [], "a rejected poll registers no waiter")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "a rejected poll must not be told about the message")
    }

    /// The bearer is checked first: a request that is wrong in two ways
    /// (bad bearer, no surface header) is answered for the bearer.
    func test_route_wrongBearerAndNoSurfaceHeader_returns401() async {
        let response = await server.route(request: wakeRequest(token: "wrong-token", surfaceIDHeader: nil))

        XCTAssertEqual(response.statusCode, 401, "the bearer check must come before surface resolution")
        XCTAssertNil(response.body)
    }

    // MARK: - Surface resolution

    /// The surface is resolved before the agent kind is looked at: a
    /// non-claude-code kind gets its 204 only for a resolvable surface.
    func test_route_unresolvableSurfaceAndNonClaudeKind_returns400() async {
        let cases: [(label: String, header: String?)] = [
            ("missing header", nil),
            ("unknown calyx-session id", "not-a-surface-or-known-session"),
        ]

        for testCase in cases {
            let response = await server.route(request: wakeRequest(
                token: testToken, surfaceIDHeader: testCase.header, kindHeader: "codex"
            ))

            XCTAssertEqual(response.statusCode, 400,
                           "[\(testCase.label)] surface resolution must come before the agent-kind check")
        }
    }

    func test_route_unresolvableSurface_returns400() async {
        let cases: [(label: String, header: String?)] = [
            ("missing header", nil),
            ("unknown calyx-session id", "not-a-surface-or-known-session"),
        ]

        for testCase in cases {
            let response = await server.route(
                request: wakeRequest(token: testToken, surfaceIDHeader: testCase.header)
            )

            XCTAssertEqual(response.statusCode, 400, "[\(testCase.label)] must return 400")
        }
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    // MARK: - Agent kind

    func test_route_nonClaudeKindHeader_returns204Immediately() async throws {
        // The surface's peer has a message, so a Claude Code poll would
        // answer 200 and a poll that waited would take 30 s.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        for kind in ["codex", "grok", "opencode"] {
            let clock = ContinuousClock()
            let start = clock.now
            let response = await server.route(
                request: wakeRequest(token: testToken, surfaceIDHeader: surface.uuidString, kindHeader: kind)
            )
            let elapsed = clock.now - start

            XCTAssertEqual(response.statusCode, 204, "[\(kind)] a non-claude-code kind must get 204")
            XCTAssertNil(response.body, "[\(kind)] a 204 must carry an empty body")
            XCTAssertLessThan(elapsed, promptBound, "[\(kind)] the 204 must come at once, not after the timeout")
        }
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "a non-claude-code poll must not consume the message's wake")
    }

    func test_route_explicitClaudeCodeKindHeader_isServedLikeNoHeader() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let response = await server.route(
            request: wakeRequest(token: testToken, surfaceIDHeader: surface.uuidString, kindHeader: "claude-code")
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - Setting off

    func test_route_settingOff_returns204Immediately_andRegistersNoWaiter() async throws {
        IPCWakeSettings.enabled = false
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let clock = ContinuousClock()
        let start = clock.now
        let response = await poll(surface)
        let elapsed = clock.now - start

        XCTAssertEqual(response.statusCode, 204, "with the setting off the poll must get 204")
        XCTAssertNil(response.body)
        XCTAssertLessThan(elapsed, promptBound, "the 204 must come at once, not after the 30 s timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [], "no waiter may be registered")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "with the setting off nothing may be marked")
    }

    // MARK: - Nonce header (spec A.3 routeIPCWake)

    /// One poll per case, each for its own surface whose peer has an
    /// un-nudged message, so a server that ignored the nonce would answer
    /// 200 at once: only the nonce check can produce the 400.
    private func assertNonceRejected(
        _ cases: [(label: String, nonce: String?)], file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for testCase in cases {
            let sender = await registerPeerInStore("sender")
            let peer = await registerPeerInStore("recipient")
            let surface = UUID()
            registry.bindSurface(surface, toPeer: peer)
            try await deliverInStore(from: sender, to: peer)

            let response: HTTPResponse
            if let nonce = testCase.nonce {
                response = await poll(surface, nonce: nonce)
            } else {
                response = await pollWithoutNonce(surface)
            }

            XCTAssertEqual(response.statusCode, 400,
                           "[\(testCase.label)] a poll without a canonical uppercase UUID nonce must get 400",
                           file: file, line: line)
            XCTAssertNil(response.body, "[\(testCase.label)] the 400 carries no body", file: file, line: line)
            XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [],
                           "[\(testCase.label)] a rejected poll registers no waiter", file: file, line: line)
            let flagsAfter = await flags(peer)
            XCTAssertEqual(flagsAfter, [false], "[\(testCase.label)] a rejected poll must not consume the wake",
                           file: file, line: line)
        }
    }

    func test_route_noNonceHeader_returns400_andRegistersNoWaiter() async throws {
        try await assertNonceRejected([("no header", nil)])
    }

    func test_route_nonceNotACanonicalUppercaseUUID_returns400() async throws {
        let valid = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"
        try await assertNonceRejected([
            ("lowercase", valid.lowercased()),
            ("one lowercase digit", "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F0011a"),
            ("braces", "{" + valid + "}"),
            ("garbage", "not-a-uuid"),
            ("empty", ""),
            ("no hyphens", "6F1C2A9E0B7D4E219A53C4D8E7F00112"),
            ("leading space", " " + valid),
            ("trailing space", valid + " "),
        ])
    }

    /// Spec order: bearer 401 -> surface 400 -> kind 204 -> setting-off 204
    /// -> nonce 400 -> await.
    func test_route_wrongBearerAndNoNonce_returns401() async throws {
        let response = await server.route(request: wakeRequest(
            token: "wrong-token", surfaceIDHeader: UUID().uuidString, nonce: .none
        ))
        XCTAssertEqual(response.statusCode, 401, "the bearer check comes before the nonce check")
    }

    func test_route_nonClaudeKindAndBadNonce_returns204() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let absent = await pollWithoutNonce(surface, kindHeader: "codex")
        let garbage = await server.route(request: wakeRequest(
            token: testToken, surfaceIDHeader: surface.uuidString, kindHeader: "codex", nonce: .some("garbage")
        ))

        XCTAssertEqual(absent.statusCode, 204, "the agent-kind check comes before the nonce check")
        XCTAssertEqual(garbage.statusCode, 204, "the agent-kind check comes before the nonce check")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    func test_route_settingOffAndBadNonce_returns204() async throws {
        IPCWakeSettings.enabled = false
        let surface = UUID()
        registry.bindSurface(surface, toPeer: await registerPeerInStore("recipient"))

        let absent = await pollWithoutNonce(surface)
        let lowercase = await poll(surface, nonce: defaultNonce.lowercased())

        XCTAssertEqual(absent.statusCode, 204, "the setting is checked before the nonce")
        XCTAssertEqual(lowercase.statusCode, 204, "the setting is checked before the nonce")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    func test_route_settingOnAndBadNonce_returns400() async throws {
        // A server that registered a waiter here would hold the poll until
        // this timeout and then answer 204; keep it short.
        server.ipcWakeTimeoutMs = 2_000
        IPCWakeSettings.enabled = true
        let surface = UUID()
        registry.bindSurface(surface, toPeer: await registerPeerInStore("recipient"))

        let response = await poll(surface, nonce: defaultNonce.lowercased())

        XCTAssertEqual(response.statusCode, 400, "with the setting on a bad nonce is rejected")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [], "and no waiter is registered")
    }

    // MARK: - Proof (spec A.1-9, I13, I14)

    private func endpointBlocks(file: StaticString = #filePath, line: UInt = #line) throws -> (inner: String, outer: String) {
        try XCTUnwrap(IPCWakeTestCrypto.readEndpointBlocks(directory: agentEndpointDir),
                      "start() must write wakeProofInner and wakeProofOuter into agent-endpoint.json",
                      file: file, line: line)
    }

    func test_start_writesTwo128HexBlocksIntoTheEndpointFile() throws {
        let blocks = try endpointBlocks()
        for block in [blocks.inner, blocks.outer] {
            XCTAssertEqual(block.count, 128)
            XCTAssertTrue(block.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) })
        }
        XCTAssertNotEqual(blocks.inner, blocks.outer)
    }

    func test_route_wakeBody_isTwoLines_proofOverNonceAndNote_thenTheNote() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let blocks = try endpointBlocks()

        try await deliverInStore(from: sender, to: peer, "one")
        let firstNonce = "0A1B2C3D-4E5F-4071-8293-A4B5C6D7E8F9"
        let first = await poll(surface, nonce: firstNonce)
        try await deliverInStore(from: sender, to: peer, "two")
        let secondNonce = "11111111-2222-4333-8444-555555555555"
        let second = await poll(surface, nonce: secondNonce)

        for (label, response, nonce, note) in [
            ("first", first, firstNonce, expectedNote(peer: peer, new: 1, senders: 1, unread: 1)),
            ("second", second, secondNonce, expectedNote(peer: peer, new: 1, senders: 1, unread: 2)),
        ] {
            XCTAssertEqual(response.statusCode, 200, "[\(label)]")
            let text = try XCTUnwrap(String(data: try XCTUnwrap(response.body), encoding: .utf8))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(lines.count, 2, "[\(label)] the body is exactly two lines with no trailing newline: \(text)")
            XCTAssertEqual(lines.last, note, "[\(label)] line 2 is the note")
            XCTAssertEqual(
                lines.first,
                IPCWakeTestCrypto.proofFromBlocks(innerHex: blocks.inner, outerHex: blocks.outer, nonce: nonce, note: note),
                "[\(label)] line 1 is HMAC-SHA256 under the server's key over nonce + \"\\n\" + note"
            )
        }
        let firstProof = String(data: first.body ?? Data(), encoding: .utf8)?.split(separator: "\n").first
        let secondProof = String(data: second.body ?? Data(), encoding: .utf8)?.split(separator: "\n").first
        XCTAssertNotEqual(firstProof, secondProof, "another nonce and note give another line 1")
    }

    func test_start_twice_writesDifferentBlocks() async throws {
        let first = try endpointBlocks()
        await server.stopAndWait()
        try await server.start(token: testToken, preferredPort: 0)
        let second = try endpointBlocks()

        XCTAssertNotEqual(first.inner, second.inner, "start() must create a new key every time")
        XCTAssertNotEqual(first.outer, second.outer, "start() must create a new key every time")
    }

    /// After a restart, the body is proved with the NEW key: the old
    /// blocks no longer verify it.
    func test_afterRestart_wakeBodyIsProvedWithTheNewKey() async throws {
        let old = try endpointBlocks()
        await server.stopAndWait()
        try await server.start(token: testToken, preferredPort: 0)
        let new = try endpointBlocks()
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let response = await poll(surface)

        let note = expectedNote(peer: peer, new: 1, senders: 1, unread: 1)
        let proof = String(data: response.body ?? Data(), encoding: .utf8)?.split(separator: "\n").first.map(String.init)
        XCTAssertEqual(proof, IPCWakeTestCrypto.proofFromBlocks(
            innerHex: new.inner, outerHex: new.outer, nonce: defaultNonce, note: note))
        XCTAssertNotEqual(proof, IPCWakeTestCrypto.proofFromBlocks(
            innerHex: old.inner, outerHex: old.outer, nonce: defaultNonce, note: note))
    }

    // MARK: - D20: no wake without a published key

    /// Restarts the server on its previous port and token (as
    /// `IPCEndpointReuse.decide` would) with the endpoint directory
    /// replaced by a regular file, so `AgentEndpointFile.write` cannot
    /// create agent-endpoint.json inside it. `write` skips
    /// `createDirectory` because the path exists, and the atomic write to
    /// "<file>/agent-endpoint.json" then fails (ENOTDIR). The test first
    /// proves that `write` throws against that path.
    private func restartWithUnwritableEndpointDirectory(
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let previousPort = server.port
        XCTAssertNotEqual(previousPort, 0, "the server must be listening before the restart", file: file, line: line)
        await server.stopAndWait()
        let fm = FileManager.default
        try? fm.removeItem(atPath: agentEndpointDir)
        XCTAssertTrue(fm.createFile(atPath: agentEndpointDir, contents: Data("not a directory".utf8)),
                      file: file, line: line)
        XCTAssertThrowsError(
            try writeTestEndpointFile(
                port: previousPort, token: testToken, wakeProofKey: IPCWakeProofKey.random(), directory: agentEndpointDir
            ),
            "precondition: writing the endpoint file into a regular file must fail", file: file, line: line
        )
        try await server.start(token: testToken, preferredPort: previousPort)
        XCTAssertEqual(server.port, previousPort, "the restart must reuse the previous port", file: file, line: line)
        XCTAssertTrue(server.isRunning, "a failed endpoint write must not stop the server", file: file, line: line)
    }

    /// D20: when start() could not write the current key into the endpoint
    /// file, a wake would be signed with a key no hook can read. The route
    /// answers 204 at once (right after the setting-off check), registers
    /// no waiter, and leaves the message unannounced.
    func test_route_whenTheKeyCouldNotBePublishedAtStart_returns204WithoutAWaiter_andLeavesMessagesUnannounced() async throws {
        try await restartWithUnwritableEndpointDirectory()
        server.ipcWakeTimeoutMs = 2_000
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let clock = ContinuousClock()
        let started = clock.now
        let response = await poll(surface)
        let elapsed = clock.now - started

        XCTAssertEqual(response.statusCode, 204,
                       "a wake must not be handed over while the current key is unpublished (D20)")
        XCTAssertNil(response.body, "a 204 carries no body")
        XCTAssertLessThan(elapsed, .milliseconds(1_500),
                          "the 204 must come at once, not from the 2 s timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [], "no waiter may be registered")
        let idle = await waitUntil { self.server.ipcWakeCoordinator._testChecksInFlight == 0 }
        XCTAssertTrue(idle)
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "the message must stay unannounced")
    }

    /// Mirror of the D20 case: a restart on the same port and token whose
    /// write succeeds publishes the key, and the wake is handed over.
    func test_route_afterASuccessfulRestart_keyIsPublished_andTheGateDoesNotWithholdWakes() async throws {
        let previousPort = server.port
        await server.stopAndWait()
        try await server.start(token: testToken, preferredPort: previousPort)
        XCTAssertEqual(server.port, previousPort)
        server.ipcWakeTimeoutMs = 2_000
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        let response = await poll(surface)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    func test_route_responses_containNeitherBlockInBodyOrHeaders() async throws {
        let blocks = try endpointBlocks()
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)

        var responses = [await poll(surface)]
        responses.append(await pollWithoutNonce(surface))
        responses.append(await server.route(request: wakeRequest(token: "wrong", surfaceIDHeader: surface.uuidString)))
        XCTAssertEqual(responses.map(\.statusCode), [200, 400, 401], "precondition: one of each answer")

        for response in responses {
            let body = String(data: response.body ?? Data(), encoding: .utf8) ?? ""
            let headers = response.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            for (name, secret) in [("inner block", blocks.inner), ("outer block", blocks.outer)] {
                XCTAssertFalse(body.lowercased().contains(secret), "[\(response.statusCode)] body must not carry the \(name)")
                XCTAssertFalse(headers.lowercased().contains(secret), "[\(response.statusCode)] headers must not carry the \(name)")
            }
        }
    }

    // MARK: - Timeout

    func test_route_surfaceBoundToNothing_returns204AfterTheTimeout() async throws {
        server.ipcWakeTimeoutMs = 400
        // A message exists, but for a peer this surface is not bound to.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        try await deliverInStore(from: sender, to: peer)
        let surface = UUID()

        let clock = ContinuousClock()
        let start = clock.now
        let response = await poll(surface)
        let elapsed = clock.now - start

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNil(response.body)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(300),
                                    "an unbound surface's poll must wait for the 400 ms timeout, not return at once")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false])
    }

    // MARK: - Wake response

    func test_route_peerHasMessage_returns200TextPlain_withTheExactNote_andNoSenderStrings() async throws {
        let senderName = "ZZ-SENDER-NAME-7731"
        let senderRole = "ZZ-SENDER-ROLE-4402"
        let content = "ZZ-MESSAGE-CONTENT-9958"
        let sender = await registerPeerInStore(senderName, role: senderRole)
        let peer = await registerPeerInStore("ZZ-RECIPIENT-NAME-1186", role: "ZZ-RECIPIENT-ROLE-3320")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer, content)

        let response = await poll(surface)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["Content-Type"], "text/plain; charset=utf-8")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1),
                       "the body must be exactly IPCWakeResponse's note for 1 new message from 1 peer")
        let text = try XCTUnwrap(String(data: try XCTUnwrap(response.body), encoding: .utf8))
        let noteLine = text.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        XCTAssertTrue(noteLine.hasPrefix("Calyx IPC: "), "line 2 is the note, got: \(text)")
        XCTAssertTrue(text.contains(peer.uuidString), "the note must name the recipient's own peer id")
        XCTAssertFalse(text.contains(senderName), "the note must not contain the sender's name")
        XCTAssertFalse(text.contains(senderRole), "the note must not contain the sender's role")
        XCTAssertFalse(text.contains(content), "the note must not contain the message content")
        XCTAssertFalse(text.contains("ZZ-"), "the note must contain no string chosen by a peer")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true], "the message the poll was woken for is nudged")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    // MARK: - Woken by a messaging tools/call

    func test_route_bindingFromInitialize_thenSendMessageToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting, its surface bound to nothing yet")

        let (initStatus, _) = await server.handleJSONRPC(
            data: initializeRequestBody(), authToken: testToken, surfaceID: surface
        )
        XCTAssertEqual(initStatus, 200)
        let peer = try XCTUnwrap(registry.boundPeerID(for: surface), "initialize must have bound the surface")
        let sender = try await registerPeerViaTool(name: "sender")
        XCTAssertTrue(server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surface),
                      "precondition: the binding alone, with no message, does not end the poll")

        try await callTool("send_message", ["from": sender.uuidString, "to": peer.uuidString, "content": "hi"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200, "a send_message tools/call must wake the waiting poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_route_bindingFromRegisterPeer_thenBroadcastToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting, its surface bound to nothing yet")

        let peer = try await registerPeerViaTool(name: "recipient", surfaceID: surface)
        XCTAssertEqual(registry.boundPeerID(for: surface), peer, "register_peer must have bound the surface")
        let sender = try await registerPeerViaTool(name: "sender")

        try await callTool("broadcast", ["from": sender.uuidString, "content": "to everyone"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200, "a broadcast tools/call must wake the waiting poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_route_bindingFromInitialize_thenBroadcastToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting")

        _ = await server.handleJSONRPC(data: initializeRequestBody(), authToken: testToken, surfaceID: surface)
        let peer = try XCTUnwrap(registry.boundPeerID(for: surface), "initialize must have bound the surface")
        let sender = try await registerPeerViaTool(name: "sender")

        try await callTool("broadcast", ["from": sender.uuidString, "content": "to everyone"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    func test_route_bindingFromRegisterPeer_thenSendMessageToolCall_wakesTheWaitingPoll() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting")

        let peer = try await registerPeerViaTool(name: "recipient", surfaceID: surface)
        let sender = try await registerPeerViaTool(name: "sender")

        try await callTool("send_message", ["from": sender.uuidString, "to": peer.uuidString, "content": "hi"])
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    /// The trigger follows the store, not the transport: once `start()`
    /// has run, a message put straight into the store wakes a poll that
    /// is already waiting, with no tools/call involved. The poll's
    /// timeout is short so that a missing trigger fails as a 204 after
    /// 2 s rather than a 30 s hang.
    func test_route_messageDeliveredStraightIntoTheStoreAfterStart_wakesTheWaitingPoll() async throws {
        server.ipcWakeTimeoutMs = 2_000
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let pollTask = startPoll(surface)
        // The registration check runs on an empty inbox, so only the
        // store's own report of the new message can wake the poll.
        await assertWaitingAfterChecksIdle(surface)

        try await deliverInStore(from: sender, to: peer)
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200,
                       "a message that reaches the store by any path must wake the waiting poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    /// Pins that `start()` reinstalls the store's inbox sink on every call
    /// and `stop()` does not remove it: after `stopAndWait()` and a second
    /// `start()`, a message put straight into the store, with no
    /// tools/call, still wakes a poll that is already waiting. The poll's
    /// timeout is short so that a missing trigger fails as a 204 after
    /// 2 s rather than a 30 s hang.
    func test_route_afterStopAndRestart_messageDeliveredStraightIntoTheStore_stillWakesTheWaitingPoll() async throws {
        await server.stopAndWait()
        try await server.start(token: testToken, preferredPort: 0)
        server.ipcWakeTimeoutMs = 2_000
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let pollTask = startPoll(surface)
        // The registration check runs on an empty inbox, so only the
        // store's own report of the new message can wake the poll.
        await assertWaitingAfterChecksIdle(surface)

        try await deliverInStore(from: sender, to: peer)
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200,
                       "after a stop and restart a message put straight into the store must still wake the poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [true])
    }

    // MARK: - Woken by a hook-derived binding

    func test_route_hookEventBindsSurfaceToExistingPeerWithMessages_wakesTheWaitingPoll() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        try await deliverInStore(from: sender, to: peer)
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting, its surface bound to nothing yet")
        // An unbound surface's poll keeps waiting.
        await assertWaitingAfterChecksIdle(surface)

        // A PreToolUse event for receive_messages carries the pane's own
        // peer id in tool_input.peer_id; the registry binds the surface
        // to it. No message is sent and no tools/call is made.
        let eventResponse = await server.route(request: agentEventRequest(
            surfaceID: surface,
            body: Data("""
            {"hook_event_name":"PreToolUse","session_id":"s1",
             "tool_name":"mcp__calyx-ipc__receive_messages",
             "tool_input":{"peer_id":"\(peer.uuidString)"}}
            """.utf8)
        ))
        XCTAssertEqual(eventResponse.statusCode, 204)
        XCTAssertEqual(registry.boundPeerID(for: surface), peer, "precondition: the hook event bound the surface")
        let response = await pollTask.value

        XCTAssertEqual(response.statusCode, 200,
                       "binding the surface to a peer that already has un-nudged messages must wake the poll")
        XCTAssertEqual(response.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - At most one wake per message

    func test_route_sameMessage_secondPollGets204_newerMessageGets200() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer, "one")
        let first = await poll(surface)
        XCTAssertEqual(first.statusCode, 200, "precondition: the first poll is woken for the message")
        XCTAssertEqual(first.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))

        let secondPoll = startPoll(surface)
        await assertWaitingAfterChecksIdle(surface)
        server.ipcWakeCoordinator.reevaluateAllWaiters()
        await assertWaitingAfterChecksIdle(surface)
        server.ipcWakeCoordinator.release(surfaceID: surface)
        let second = await secondPoll.value

        XCTAssertEqual(second.statusCode, 204, "the same message must not wake a second poll")
        XCTAssertNil(second.body)

        try await deliverInStore(from: sender, to: peer, "two")
        let third = await poll(surface)

        XCTAssertEqual(third.statusCode, 200, "a newer message must wake again")
        XCTAssertEqual(third.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 2),
                       "1 new message, 2 unread: the first message is still in the inbox")
    }

    // MARK: - Supersede

    func test_route_secondPollForTheSameSurface_makesTheFirstReturn204() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        let firstPoll = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the first poll is waiting")

        let clock = ContinuousClock()
        let start = clock.now
        let secondPoll = startPoll(surface)
        let first = await firstPoll.value
        let elapsed = clock.now - start

        XCTAssertEqual(first.statusCode, 204, "a second poll for the same surface must end the first with 204")
        XCTAssertNil(first.body)
        XCTAssertLessThan(elapsed, promptBound, "the first poll must end when superseded, not at its 30 s timeout")

        try await callTool("send_message", ["from": sender.uuidString, "to": peer.uuidString, "content": "hi"])
        let second = await secondPoll.value
        XCTAssertEqual(second.statusCode, 200, "the second poll is the one that is woken")
        XCTAssertEqual(second.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - Server stop

    func test_serverStop_makesAWaitingPollReturn204() async throws {
        let surface = UUID()
        let pollTask = startPoll(surface)
        let waiting = await waitForWaitingPoll(surface)
        XCTAssertTrue(waiting, "precondition: the poll is waiting")

        let clock = ContinuousClock()
        let start = clock.now
        server.stop()
        let response = await pollTask.value
        let elapsed = clock.now - start

        XCTAssertEqual(response.statusCode, 204)
        XCTAssertNil(response.body)
        XCTAssertLessThan(elapsed, promptBound, "stop() must end the poll at once, not leave it to its 30 s timeout")
        XCTAssertEqual(server.ipcWakeCoordinator.waitingSurfaceIDs, [])
    }

    // MARK: - Cancellation

    func test_route_taskCancelledWhileWaiting_removesTheWaiter_andLeavesTheMessageUnNudged() async throws {
        // The surface is bound and the message is un-nudged, so the poll
        // is wakeable. Its registration check is held in the coordinator's
        // `_testBeforeOffer` seam (after the taker was built, before the
        // store call) while the route's Task is cancelled, so the
        // cancellation always comes first and the check must then hand
        // nothing over.
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer)
        let pollBox = PollTaskBox()
        server.ipcWakeCoordinator._testBeforeOffer = {
            guard let pollTask = pollBox.task, !pollBox.cancelled else { return }
            pollBox.cancelled = true
            pollTask.cancel()
            pollBox.response = await pollTask.value
        }

        let clock = ContinuousClock()
        let start = clock.now
        let pollTask = startPoll(surface)
        pollBox.task = pollTask
        let response = await pollTask.value
        let elapsed = clock.now - start

        XCTAssertTrue(pollBox.cancelled, "precondition: the poll was cancelled inside its registration check")
        XCTAssertEqual(response.statusCode, 204, "a cancelled poll resolves as no wake")
        XCTAssertNil(response.body)
        XCTAssertLessThan(elapsed, promptBound, "cancellation must end the poll, not its 30 s timeout")
        let removed = await waitUntil { !self.server.ipcWakeCoordinator.waitingSurfaceIDs.contains(surface) }
        XCTAssertTrue(removed, "cancelling the Task running route(request:) must remove the waiter")
        server.ipcWakeCoordinator._testBeforeOffer = nil
        let idle = await waitUntil { self.server.ipcWakeCoordinator._testChecksInFlight == 0 }
        XCTAssertTrue(idle, "the held check must return from the store")
        let flagsAfter = await flags(peer)
        XCTAssertEqual(flagsAfter, [false], "the message must stay un-nudged")

        // The message is still owed its wake.
        let later = await poll(surface)
        XCTAssertEqual(later.statusCode, 200)
        XCTAssertEqual(later.body, expectedBody(peer: peer, new: 1, senders: 1, unread: 1))
    }

    // MARK: - receive_messages output

    func test_receiveMessagesToolCall_messageObjectsHaveNoNudgedKey() async throws {
        let sender = await registerPeerInStore("sender")
        let peer = await registerPeerInStore("recipient")
        let surface = UUID()
        registry.bindSurface(surface, toPeer: peer)
        try await deliverInStore(from: sender, to: peer, "one")
        let woken = await poll(surface)
        XCTAssertEqual(woken.statusCode, 200, "precondition: the first message caused a wake")
        try await deliverInStore(from: sender, to: peer, "two")
        let flagsBefore = await flags(peer)
        XCTAssertEqual(flagsBefore, [true, false], "precondition: one nudged and one un-nudged message")

        let text = try await callTool("receive_messages", ["peer_id": peer.uuidString])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["content"] as? String }, ["one", "two"])
        for message in messages {
            XCTAssertNil(message["nudged"], "the nudged flag is internal and must not appear in receive_messages")
            XCTAssertEqual(Set(message.keys), ["id", "from", "to", "content", "timestamp"],
                           "receive_messages must keep exactly its existing message keys")
        }
        XCTAssertFalse(text.contains("nudged"), "got: \(text)")
    }
}

/// The poll Task the `_testBeforeOffer` closure of the cancellation test
/// cancels, set once the Task exists. A main-actor box so the closure
/// captures no test case.
@MainActor
private final class PollTaskBox {
    var task: Task<HTTPResponse, Never>?
    var cancelled = false
    var response: HTTPResponse?
}
