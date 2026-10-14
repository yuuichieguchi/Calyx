//
//  CalyxMCPServerBearerComparisonTests.swift
//  CalyxTests
//
//  Pins J11 (spec C.2, C.3): every bearer check on CalyxMCPServer goes
//  through one `isAuthorized(_:)`, which compares in constant time with
//  `HTTPParser.constantTimeEquals`, instead of `authToken == token` at
//  each route.
//
//  Constant time is not observable from a test, so the pin is threefold:
//  - `isAuthorized` itself: exact token true; missing header, other
//    scheme, wrong, prefix, suffix-extended, case-changed and empty token
//    false
//  - every route answers a wrong token with 401 and the right token with
//    something other than 401 (these already hold before J11: they keep
//    the routes' behaviour fixed while the comparison moves)
//  - a source-level check on CalyxMCPServer.swift (read through this
//    file's #filePath, so it runs from the checkout that built the
//    tests): no `authToken == token` remains and `isAuthorized` is
//    defined once and calls `HTTPParser.constantTimeEquals`
//
//  Planned API used here:
//    extension CalyxMCPServer { func isAuthorized(_ request: HTTPRequest) -> Bool }
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerBearerComparisonTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var agentEndpointDir: String!
    private let testToken = "bearer-comparison-test-token"
    private let usageToken = "usage-bearer-comparison-token"
    private let settingsSuiteName = "com.calyx.tests.CalyxMCPServerBearerComparisonTests"

    override func setUp() async throws {
        try await super.setUp()
        CockpitSettings._testUseSuite(named: settingsSuiteName)
        agentEndpointDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server.commandLogStore = CommandLogStore()
        server.approvalInbox = ApprovalInboxStore()
        server.agentHookApprovalMemory = AgentHookApprovalMemory()
        server.approvalRequestTimeoutMs = 50
        server.ipcWakeTimeoutMs = 50
        let usageToken = self.usageToken
        server.usageIngest = UsageIngestEndpoint(
            token: { usageToken }, now: { Date(timeIntervalSince1970: 0) },
            ingest: { _, _ in .dropped }, note: { _, _ in }
        )
        server._testSetToken(testToken)
    }

    override func tearDown() async throws {
        server.usageIngest = nil
        server.stop()
        server = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        CockpitSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    private func request(_ method: String, _ path: String, authorization: String?, body: Data? = Data("{}".utf8)) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let authorization { headers["Authorization"] = authorization }
        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    private var wrongAuthorizations: [String?] {
        [
            nil,
            "Bearer wrong-token",
            "Bearer " + String(testToken.dropLast()),
            "Bearer " + testToken + "x",
            "Bearer " + testToken.uppercased(),
            "Bearer ",
            "Basic " + testToken,
            "bearer " + testToken,
        ]
    }

    // MARK: - isAuthorized

    func test_isAuthorized_acceptsOnlyTheExactBearerToken() {
        XCTAssertTrue(server.isAuthorized(request("POST", "/agent-event", authorization: "Bearer " + testToken)))
        for authorization in wrongAuthorizations {
            XCTAssertFalse(server.isAuthorized(request("POST", "/agent-event", authorization: authorization)),
                           "[\(authorization ?? "no header")] must not be authorized")
        }
    }

    // MARK: - Every route rejects a wrong token

    private var tokenRoutes: [(String, String)] {
        [
            ("POST", "/mcp"),
            ("POST", "/agent-event"),
            ("POST", "/command-event"),
            ("POST", "/approval-request"),
            ("POST", "/ipc-wake"),
            ("POST", HTTPParser.calyxMCPPath),
            ("GET", HTTPParser.calyxMCPPath),
            ("DELETE", HTTPParser.calyxMCPPath),
        ]
    }

    func test_everyTokenRoute_rejectsAWrongToken_with401() async {
        for (method, path) in tokenRoutes {
            for authorization in wrongAuthorizations {
                let response = await server.route(request: request(method, path, authorization: authorization))
                XCTAssertEqual(response.statusCode, 401, "[\(method) \(path), \(authorization ?? "no header")]")
            }
        }
    }

    func test_everyTokenRoute_acceptsTheRightToken() async {
        for (method, path) in tokenRoutes {
            let response = await server.route(request: request(method, path, authorization: "Bearer " + testToken))
            XCTAssertNotEqual(response.statusCode, 401, "[\(method) \(path)] the right token passes the bearer check")
        }
    }

    func test_usageRoute_rejectsAWrongToken_with401() async {
        let path = HTTPParser.usageMetricsPath
        for authorization in [nil, "Bearer " + testToken, "Bearer " + usageToken + "x", "Bearer " + String(usageToken.dropLast())] {
            let response = await server.route(request: request("POST", path, authorization: authorization))
            XCTAssertEqual(response.statusCode, 401, "[usage, \(authorization ?? "no header")]")
        }
        let accepted = await server.route(request: request("POST", path, authorization: "Bearer " + usageToken))
        XCTAssertNotEqual(accepted.statusCode, 401)
    }

    // MARK: - Source-level pin

    private func serverSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = root.appendingPathComponent("Calyx/Features/IPC/CalyxMCPServer.swift").path
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    /// The source without its comment lines, so a comment that mentions
    /// the old comparison does not count.
    private func serverCode() throws -> String {
        try serverSource()
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func test_source_noRouteComparesTheBearerWithEquals() throws {
        let source = try serverCode()
        XCTAssertEqual(source.components(separatedBy: "authToken == token").count - 1, 0,
                       "J11: every `authToken == token` is replaced by isAuthorized")
        XCTAssertEqual(source.components(separatedBy: "func isAuthorized(").count - 1, 1,
                       "J11: exactly one isAuthorized definition")
        XCTAssertEqual(source.components(separatedBy: "== token").count - 1, 0,
                       "J11: no bearer is compared with `== token`")
        XCTAssertEqual(source.components(separatedBy: "isAuthorized(request)").count - 1, 5,
                       "J11: the five routes /agent-event, /command-event, /approval-request, /ipc-wake and /calyx-mcp (calyxMCPRejection) each call isAuthorized(request) once")
    }

    /// `requestBodyLimit(forHeaderString:)` is private and has no test
    /// seam, so its 32 MiB bearer check is pinned at source level.
    func test_source_requestBodyLimitUsesConstantTimeEquals() throws {
        let source = try serverCode()
        let start = try XCTUnwrap(source.range(of: "private func requestBodyLimit("), "requestBodyLimit must exist")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        XCTAssertTrue(rest[..<end].contains("HTTPParser.constantTimeEquals(String(authorization.dropFirst(7)), token)"),
                      "J11: requestBodyLimit compares the bearer with HTTPParser.constantTimeEquals")
    }

    func test_source_isAuthorizedUsesConstantTimeEquals() throws {
        let source = try serverCode()
        let start = try XCTUnwrap(source.range(of: "func isAuthorized("), "isAuthorized must exist")
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        XCTAssertTrue(rest[..<end].contains("HTTPParser.constantTimeEquals"),
                      "isAuthorized compares with HTTPParser.constantTimeEquals")
    }
}
