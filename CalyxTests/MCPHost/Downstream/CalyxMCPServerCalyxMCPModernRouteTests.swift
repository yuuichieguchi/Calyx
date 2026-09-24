//
//  CalyxMCPServerCalyxMCPModernRouteTests.swift
//  CalyxTests
//
//  Coverage: POST /calyx-mcp's modern-generation behavior (MCP
//  2026-07-28, "Streamable HTTP" + "Versioning and Compatibility" +
//  "Discovery" + "Caching" primary sources, fetched read-only from
//  https://modelcontextprotocol.io/specification/2026-07-28/ -- .md
//  sources -- and pinned here, not reconstructed from memory):
//
//  - A request is modern exactly when its body carries
//    `params._meta["io.modelcontextprotocol/protocolVersion"]`
//    (Versioning: "A request carrying modern per-request `_meta` is
//    served statelessly according to this revision"); legacy detection
//    (no such field) is covered by
//    CalyxMCPServerCalyxMCPLegacyRouteTests.swift.
//  - `MCP-Protocol-Version` header MUST equal the body's `_meta`
//    version; `Mcp-Method` MUST equal `method`; `Mcp-Name` MUST equal
//    `params.name`/`params.uri` and is REQUIRED for tools/call,
//    resources/read, prompts/get only. Any mismatch or a missing
//    required header -> 400 Bad Request, JSON-RPC `-32020`
//    (`HeaderMismatch`) (Streamable HTTP: "Server Validation").
//  - `_meta` missing `io.modelcontextprotocol/clientCapabilities`
//    (a required field) -> 400, `-32602` (Invalid params) (Base
//    Protocol: "A request missing any required field is malformed...
//    MUST reject it with JSON-RPC error code -32602").
//  - An unsupported/unknown protocol version -> 400,
//    `UnsupportedProtocolVersionError` `-32022`, `data.supported`
//    listing the server's own supported versions (Versioning:
//    "Protocol Version Negotiation").
//  - An unimplemented RPC method -> 404, JSON-RPC `-32601` (`Method not
//    found`) (Streamable HTTP: "Protocol Version Header" -- this is
//    what distinguishes a modern 404 from a legacy HTTP+SSE server's
//    unrelated 404).
//  - Every `resultType: "complete"` result from `server/discover`,
//    `tools/list`, `resources/list`, `resources/templates/list`,
//    `resources/read` (and `prompts/list`) MUST carry `ttlMs` (>= 0)
//    and `cacheScope` (Caching: "Cacheable Results" / "Cacheable
//    Model"). Calyx's own dynamic, per-client catalog chooses
//    `ttlMs: 0` (immediately stale) and `cacheScope: "private"`
//    (plan decision, not a spec-mandated value -- the spec's own
//    example uses 3600000/"public" for a static catalog).
//  - `server/discover`'s `capabilities.tools.listChanged` is `true`
//    (Calyx's catalog changes as upstream servers connect/disconnect).
//  - `_meta["io.modelcontextprotocol/serverInfo"]` is present on every
//    result (Base Protocol: "servers SHOULD include" -- Calyx commits
//    to always including it, since serverInfo is cheap and static).
//
//  Assumed API surface (this generation has no production code yet):
//  `route(request:)` continues to serve every buffered (non-SSE-Accept)
//  POST /calyx-mcp response, exactly as it does today for /mcp and for
//  legacy /calyx-mcp. `CalyxMCPServer` gains an injectable, empty-by-
//  default catalog (`calyxMCPUpstreamTools: [(alias: String, tool:
//  MCPToolDefinition)] = []` or equivalent) so `tools/list` here is
//  deterministic without any real upstream connection -- with zero
//  upstream tools registered, `tools/list` still returns at least the
//  always-present `app_context` static tool (plan §1/§6).
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerCalyxMCPModernRouteTests: XCTestCase {

    private var server: CalyxMCPServer!
    private let testToken = "modern-calyx-mcp-token"
    private var agentEndpointDir: String!

    /// The exact server-supported-version list the task's own contract
    /// specifies for `-32022`'s `data.supported`.
    private let supportedVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        server.setCalyxMCPRouter(MCPCalyxMCPRouterTestSupport.makeMinimalRouter(bearerToken: { [testToken] in testToken }))
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

    private let modernVersion = "2026-07-28"

    private func modernMeta(
        version: String = "2026-07-28",
        includeClientCapabilities: Bool = true
    ) -> [String: Any] {
        var meta: [String: Any] = [
            "io.modelcontextprotocol/protocolVersion": version,
            "io.modelcontextprotocol/clientInfo": ["name": "test-client", "version": "1.0.0"],
        ]
        if includeClientCapabilities {
            meta["io.modelcontextprotocol/clientCapabilities"] = [:] as [String: Any]
        }
        return meta
    }

    /// Builds a modern POST /calyx-mcp request. Every header defaults to
    /// the value that matches the body, so a single override parameter
    /// isolates exactly one validation failure per test.
    private func modernRequest(
        id: Any = 1,
        method: String,
        name: String? = nil,
        params: [String: Any] = [:],
        meta: [String: Any]? = nil,
        protocolVersionHeader: String? = "2026-07-28",
        mcpMethodHeader: String? = nil,
        mcpNameHeader: String? = nil,
        includeMcpMethodHeader: Bool = true,
        includeMcpNameHeader: Bool = true
    ) -> HTTPRequest {
        var fullParams = params
        fullParams["_meta"] = meta ?? modernMeta()
        if let name {
            fullParams["name"] = name
        }
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": fullParams]
        let body = try! JSONSerialization.data(withJSONObject: dict)

        var headers: [String: String] = [
            "Content-Type": "application/json",
            "Authorization": "Bearer \(testToken)",
        ]
        if let protocolVersionHeader {
            headers["MCP-Protocol-Version"] = protocolVersionHeader
        }
        if includeMcpMethodHeader {
            headers["Mcp-Method"] = mcpMethodHeader ?? method
        }
        if includeMcpNameHeader, let name {
            headers["Mcp-Name"] = mcpNameHeader ?? name
        }
        return HTTPRequest(method: "POST", path: "/calyx-mcp", headers: headers, body: body)
    }

    private func errorCode(_ resp: HTTPResponse) throws -> Int {
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let error = try XCTUnwrap(json?["error"] as? [String: Any])
        return try XCTUnwrap(error["code"] as? Int)
    }

    private func result(_ resp: HTTPResponse) throws -> [String: Any] {
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        return try XCTUnwrap(json?["result"] as? [String: Any])
    }

    // MARK: - HeaderMismatch (-32020): missing/mismatched MCP-Protocol-Version

    func test_missingMCPProtocolVersionHeader_returns400WithHeaderMismatch() async throws {
        let req = modernRequest(method: "server/discover", protocolVersionHeader: nil)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32020)
    }

    func test_headerVersionMismatchWithBodyMeta_returns400WithHeaderMismatch() async throws {
        // Header says 2025-11-25, body _meta says 2026-07-28 -- must not
        // silently pick one; this is exactly the HeaderMismatch scenario.
        let req = modernRequest(method: "server/discover", protocolVersionHeader: "2025-11-25")
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32020)
    }

    // MARK: - HeaderMismatch (-32020): missing/mismatched Mcp-Method

    func test_missingMcpMethodHeader_returns400WithHeaderMismatch() async throws {
        let req = modernRequest(method: "server/discover", includeMcpMethodHeader: false)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32020)
    }

    func test_mcpMethodHeaderMismatchWithBodyMethod_returns400WithHeaderMismatch() async throws {
        let req = modernRequest(method: "server/discover", mcpMethodHeader: "tools/list")
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32020)
    }

    // MARK: - HeaderMismatch (-32020): Mcp-Name required for tools/call and resources/read

    func test_toolsCall_missingMcpNameHeader_returns400WithHeaderMismatch() async throws {
        let req = modernRequest(method: "tools/call", name: "srv-get_weather", params: ["arguments": [:] as [String: Any]], includeMcpNameHeader: false)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32020)
    }

    func test_resourcesRead_missingMcpNameHeader_returns400WithHeaderMismatch() async throws {
        var params: [String: Any] = [:]
        params["uri"] = "ui://srv/widget.html"
        let req = HTTPRequest(
            method: "POST", path: "/calyx-mcp",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(testToken)",
                "MCP-Protocol-Version": "2026-07-28",
                "Mcp-Method": "resources/read",
            ],
            body: try! JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "resources/read",
                "params": ["uri": "ui://srv/widget.html", "_meta": modernMeta()],
            ])
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32020)
    }

    func test_toolsCall_mcpNameHeaderMismatchWithBodyName_returns400WithHeaderMismatch() async throws {
        let req = modernRequest(
            method: "tools/call", name: "srv-get_weather", params: ["arguments": [:] as [String: Any]],
            mcpNameHeader: "srv-something-else"
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32020)
    }

    func test_toolsList_doesNotRequireMcpNameHeader() async throws {
        // Mcp-Name is required only for tools/call, resources/read,
        // prompts/get -- tools/list must not be rejected for lacking it.
        let req = modernRequest(method: "tools/list")
        let resp = await server.route(request: req)
        XCTAssertNotEqual(resp.statusCode, 400)
    }

    // MARK: - Invalid params (-32602): missing required clientCapabilities

    func test_missingClientCapabilities_returns400WithDashError32602() async throws {
        let req = modernRequest(method: "server/discover", meta: modernMeta(includeClientCapabilities: false))
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32602)
    }

    // MARK: - UnsupportedProtocolVersionError (-32022)

    func test_unsupportedProtocolVersion_returns400WithDashError32022AndSupportedVersionsList() async throws {
        let req = modernRequest(
            method: "server/discover",
            meta: modernMeta(version: "1900-01-01"),
            protocolVersionHeader: "1900-01-01"
        )
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 400)
        XCTAssertEqual(try errorCode(resp), -32022)

        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let error = try XCTUnwrap(json?["error"] as? [String: Any])
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        let supported = try XCTUnwrap(data["supported"] as? [String])
        XCTAssertEqual(supported, supportedVersions)
    }

    // MARK: - Unknown method (-32601 / 404)

    func test_unknownMethod_returns404WithDashError32601() async throws {
        let req = modernRequest(method: "totally/unknown/method", mcpMethodHeader: "totally/unknown/method", includeMcpMethodHeader: true)
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 404,
                       "an unimplemented modern method must be 404 -- distinct from legacy /calyx-mcp's 200/-32601")
        XCTAssertEqual(try errorCode(resp), -32601)
    }

    // MARK: - resultType, serverInfo, and caching hints

    func test_toolsList_result_isCompleteWithServerInfoAndCachingHints() async throws {
        let req = modernRequest(method: "tools/list")
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        let result = try result(resp)

        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["ttlMs"] as? Int, 0)
        XCTAssertEqual(result["cacheScope"] as? String, "private")

        let meta = try XCTUnwrap(result["_meta"] as? [String: Any])
        XCTAssertNotNil(meta["io.modelcontextprotocol/serverInfo"])
    }

    func test_toolsList_alwaysIncludesAppContextTool_evenWithNoUpstreamServers() async throws {
        let req = modernRequest(method: "tools/list")
        let resp = await server.route(request: req)
        let result = try result(resp)
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("app_context"),
                      "app_context is a pane-scoped static tool always present, even with zero upstream servers registered")
    }

    func test_serverDiscover_result_isCompleteWithToolsListChangedTrueAndCachingHints() async throws {
        let req = modernRequest(method: "server/discover")
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        let result = try result(resp)

        XCTAssertEqual(result["resultType"] as? String, "complete")
        XCTAssertEqual(result["ttlMs"] as? Int, 0)
        XCTAssertEqual(result["cacheScope"] as? String, "private")

        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        let tools = try XCTUnwrap(capabilities["tools"] as? [String: Any])
        XCTAssertEqual(tools["listChanged"] as? Bool, true,
                       "calyx-mcp's catalog changes as upstream servers connect/reconnect, unlike /mcp's static one")

        let supported = try XCTUnwrap(result["supportedVersions"] as? [String])
        XCTAssertEqual(supported, supportedVersions)
    }
}
