//
//  CalyxMCPServerCommandEventTests.swift
//  CalyxTests
//
//  TDD Red Phase for CalyxMCPServer's new POST /command-event endpoint,
//  mirroring CalyxMCPServerAgentEventTests' structure for /agent-event.
//
//  Coverage:
//  - Wrong / missing bearer token -> 401
//  - Missing body / malformed JSON body -> 400
//  - Missing / empty X-Calyx-Surface-ID header -> 400 (malformed client)
//  - Body over 262_144 bytes -> 413
//  - Valid raw-UUID header -> 204, ingests a .running record
//  - A session-ID header registered in SessionSurfaceMap -> 204, ingests
//    against the resolved surfaceID
//  - An unresolvable (unregistered) session-ID header -> 204 drop, NOT
//    400 -- a detached persistent session keeps emitting after its pane
//    closes, which is normal steady-state, not a client error
//  - start then end through the endpoint -> a .finished record carrying
//    the script's exit code
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCommandEventTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private let testToken = "test-token-12345"

    /// Test-isolated `agent-endpoint.json` directory -- `tearDown`'s
    /// `server.stop()` still calls `AgentEndpointFile.remove(directory:)`,
    /// same rationale as `CalyxMCPServerAgentEventTests`.
    private var agentEndpointDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer()
        server.agentEndpointDirectory = agentEndpointDir
        server._testSetToken(testToken)
    }

    override func tearDown() {
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func b64(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
    }

    private func commandStartBody(cmdID: String, command: String = "ls -la", cwd: String = "/tmp") -> Data {
        Data("""
        {"phase":"start","cmd_id":"\(cmdID)","command_b64":"\(b64(command))","cwd_b64":"\(b64(cwd))"}
        """.utf8)
    }

    private func commandEndBody(cmdID: String, exitCode: Int32?) -> Data {
        let exitCodeJSON = exitCode.map(String.init) ?? "null"
        return Data("""
        {"phase":"end","cmd_id":"\(cmdID)","exit_code":\(exitCodeJSON)}
        """.utf8)
    }

    private func commandEventRequest(token: String?, surfaceIDHeader: String?, body: Data?) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        if let surfaceIDHeader { headers["X-Calyx-Surface-ID"] = surfaceIDHeader }
        return HTTPRequest(method: "POST", path: "/command-event", headers: headers, body: body)
    }

    // MARK: - Authentication

    func test_routeCommandEvent_wrongToken_returns401() async {
        let request = commandEventRequest(
            token: "wrong-token", surfaceIDHeader: UUID().uuidString, body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 401)
    }

    func test_routeCommandEvent_missingToken_returns401() async {
        let request = commandEventRequest(
            token: nil, surfaceIDHeader: UUID().uuidString, body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 401)
    }

    // MARK: - Body validation

    func test_routeCommandEvent_missingBody_returns400() async {
        let request = commandEventRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: nil)

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_routeCommandEvent_malformedJSONBody_returns400() async {
        let request = commandEventRequest(
            token: testToken, surfaceIDHeader: UUID().uuidString, body: Data("not json {{{".utf8)
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_routeCommandEvent_oversizedBody_returns413() async {
        // One byte over the 262_144 cap; the token and surface header are
        // otherwise valid, so this isolates the size-cap behavior alone.
        let oversized = Data(repeating: 0x41, count: 262_145)
        let request = commandEventRequest(token: testToken, surfaceIDHeader: UUID().uuidString, body: oversized)

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 413)
    }

    // MARK: - Surface ID header validation

    func test_routeCommandEvent_missingSurfaceIDHeader_returns400() async {
        let request = commandEventRequest(
            token: testToken, surfaceIDHeader: nil, body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    func test_routeCommandEvent_emptySurfaceIDHeader_returns400() async {
        let request = commandEventRequest(
            token: testToken, surfaceIDHeader: "", body: commandStartBody(cmdID: "cmd-x")
        )

        let response = await server.route(request: request)

        XCTAssertEqual(response.statusCode, 400)
    }

    // MARK: - Surface resolution + ingest

    func test_routeCommandEvent_validRawUUIDHeader_returns204AndIngestsRunningRecord() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let surfaceID = UUID()

        let response = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-1", command: "ls -la", cwd: "/tmp")
        ))

        XCTAssertEqual(response.statusCode, 204)
        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "A valid raw-UUID header must ingest exactly one record")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.cmdID, "cmd-1")
        XCTAssertEqual(record.command, "ls -la")
        XCTAssertEqual(record.cwd, "/tmp")
        XCTAssertEqual(record.state, .running)
    }

    func test_routeCommandEvent_sessionIDHeaderRegisteredInMap_returns204AndIngestsAtResolvedSurface() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let sessionMap = SessionSurfaceMap()
        server.sessionSurfaceMap = sessionMap
        let surfaceID = UUID()
        let sessionID = "session-\(UUID().uuidString)"
        sessionMap.register(sessionID: sessionID, surfaceID: surfaceID)

        let response = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: sessionID,
            body: commandStartBody(cmdID: "cmd-session", command: "npm test", cwd: "/Users/dev/repo")
        ))

        XCTAssertEqual(response.statusCode, 204)
        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1,
                       "A session-ID header registered in SessionSurfaceMap must ingest against the " +
                       "surfaceID it resolves to")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.cmdID, "cmd-session")
        XCTAssertEqual(record.command, "npm test")
        XCTAssertEqual(record.state, .running)
    }

    func test_routeCommandEvent_unresolvableSessionIDHeader_dropsSilently_returns204NoResidueOnceRegistered() async {
        let store = CommandLogStore()
        server.commandLogStore = store
        let sessionMap = SessionSurfaceMap()
        server.sessionSurfaceMap = sessionMap
        let unknownSessionID = "session-never-registered-\(UUID().uuidString)"

        let dropResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: unknownSessionID, body: commandStartBody(cmdID: "cmd-drop")
        ))

        XCTAssertEqual(dropResponse.statusCode, 204,
                       "An unresolvable X-Calyx-Surface-ID (a session ID with no SessionSurfaceMap entry) " +
                       "must be silently dropped -- 204, not an error -- since a detached persistent " +
                       "session can keep emitting after its pane closes")

        // Register that same session ID to a real surface and resend the
        // identical body: if the earlier (unresolvable) drop had left any
        // residue -- e.g. attributed to some wrong/default surfaceID this
        // registration happens to collide with -- this record's count
        // would be inflated above 1.
        let surfaceID = UUID()
        sessionMap.register(sessionID: unknownSessionID, surfaceID: surfaceID)

        let secondResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: unknownSessionID, body: commandStartBody(cmdID: "cmd-drop")
        ))
        XCTAssertEqual(secondResponse.statusCode, 204)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1,
                       "Exactly one record must exist once the session ID is registered and resent -- the " +
                       "earlier drop (while unregistered) must not have left any residue that inflates " +
                       "this count")
    }

    // MARK: - End-to-end lifecycle

    func test_routeCommandEvent_startThenEnd_producesFinishedRecordWithExitCode() async throws {
        let store = CommandLogStore()
        server.commandLogStore = store
        let surfaceID = UUID()

        let startResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandStartBody(cmdID: "cmd-e2e", command: "make build", cwd: "/Users/dev/repo")
        ))
        XCTAssertEqual(startResponse.statusCode, 204)

        let endResponse = await server.route(request: commandEventRequest(
            token: testToken, surfaceIDHeader: surfaceID.uuidString,
            body: commandEndBody(cmdID: "cmd-e2e", exitCode: 42)
        ))
        XCTAssertEqual(endResponse.statusCode, 204)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "start+end for the same cmd_id must merge into a single record")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.state, .finished)
        XCTAssertEqual(record.exitCode, 42)
    }
}
