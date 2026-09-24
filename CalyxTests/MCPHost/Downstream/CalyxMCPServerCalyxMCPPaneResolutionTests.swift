//
//  CalyxMCPServerCalyxMCPPaneResolutionTests.swift
//  CalyxTests
//
//  Coverage: item 9's route-level pane resolution for POST /calyx-mcp
//  (plan §4): herdr header first (`X-Calyx-Herdr-Pane-ID`, optional
//  `X-Calyx-Herdr-Socket-Path`), via an injected `HerdrPaneRegistry`;
//  when the herdr header is present it is FINAL even if it resolves to
//  nil (a stale `X-Calyx-Session-ID`/`X-Calyx-Surface-ID` must never be
//  consulted as a fallback in that case); otherwise the existing
//  session -> surface resolution applies, exactly as `/mcp` already
//  does (`CalyxMCPServer.resolveSurfaceID`).
//
//  Discriminated through the `app_context` tool's own resolved-pane
//  scoping (see MCPAppContextToolTests.swift for the pure function
//  itself): an injected fake `MCPAppModelContextProviding` returns a
//  DIFFERENT, recognizable entry per surface, so the route-level test
//  can tell exactly which surface the route resolved to by reading
//  which entry (if any) came back -- not merely a 200/404 status, which
//  a wrong implementation could satisfy by accident.
//
//  Assumed API surface: `CalyxMCPServer` gains two injectable
//  properties, defaulting to production singletons/instances, same
//  pattern as `agentRegistry`/`sessionSurfaceMap`:
//    var herdrPaneRegistry: HerdrPaneRegistry = .shared
//    var calyxMCPModelContextProvider: any MCPAppModelContextProviding
//  consulted by the /calyx-mcp route's own pane-resolution step before
//  falling back to the existing `resolveSurfaceID(from:)` used by `/mcp`.
//

import XCTest
@testable import Calyx

@MainActor
private final class RecordingModelContextProvider: MCPAppModelContextProviding {
    /// Maps a surface to a single recognizable tool name so a test can
    /// tell which surface (if any) the route actually resolved to,
    /// purely by reading app_context's own result content.
    var toolNameBySurface: [UUID: String] = [:]

    func modelContexts(forSurface surfaceID: UUID) -> [MCPAppModelContextEntry] {
        guard let toolName = toolNameBySurface[surfaceID] else { return [] }
        return [MCPAppModelContextEntry(
            viewID: UUID(), serverDisplayName: "srv", toolName: toolName,
            content: nil, structuredContent: AnyCodable(["marker": AnyCodable(toolName)])
        )]
    }
}

@MainActor
final class CalyxMCPServerCalyxMCPPaneResolutionTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var herdrRegistry: HerdrPaneRegistry!
    private var contextProvider: RecordingModelContextProvider!
    private let testToken = "pane-resolution-token"
    private var agentEndpointDir: String!

    override func setUp() {
        super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        herdrRegistry = HerdrPaneRegistry()
        server.herdrPaneRegistry = herdrRegistry
        contextProvider = RecordingModelContextProvider()
        server.calyxMCPModelContextProvider = contextProvider
        server.setCalyxMCPRouter(MCPCalyxMCPRouterTestSupport.makeMinimalRouter(bearerToken: { [testToken] in testToken }))
    }

    override func tearDown() {
        server.stop()
        server = nil
        herdrRegistry = nil
        contextProvider = nil
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func appContextRequest(headers extra: [String: String]) -> HTTPRequest {
        let body = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "app_context", "arguments": [:] as [String: Any]],
        ])
        var headers = extra
        headers["Content-Type"] = "application/json"
        headers["Authorization"] = "Bearer \(testToken)"
        return HTTPRequest(method: "POST", path: "/calyx-mcp", headers: headers, body: body)
    }

    private func resolvedMarker(_ resp: HTTPResponse) throws -> String? {
        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(resp.body)) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        let content = result["content"] as? [[String: Any]] ?? []
        guard let text = content.first?["text"] as? String else { return nil }
        let inner = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        return inner?["marker"] as? String
    }

    // MARK: - Herdr header present and resolves: final, used over a stale surface header

    func test_herdrHeaderResolves_usedOverStaleSessionOrSurfaceHeaders() async throws {
        let herdrSurfaceID = UUID()
        let staleSurfaceID = UUID()
        herdrRegistry.register(
            surfaceID: herdrSurfaceID,
            ref: HerdrPaneRef(socketPath: "/Users/dev/.config/herdr/herdr.sock", paneID: "wB:p1")
        )
        contextProvider.toolNameBySurface[herdrSurfaceID] = "from_herdr_pane"
        contextProvider.toolNameBySurface[staleSurfaceID] = "from_stale_surface_header"

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "wB:p1",
            "X-Calyx-Herdr-Socket-Path": "/Users/dev/.config/herdr/herdr.sock",
            // Deliberately mismatched -- must be ignored once the herdr
            // header is present and resolves, per plan §4.
            "X-Calyx-Surface-ID": staleSurfaceID.uuidString,
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(try resolvedMarker(resp), "from_herdr_pane",
                       "a resolving herdr header must win over a stale/mismatched X-Calyx-Surface-ID")
    }

    // MARK: - Herdr header present but resolves to nil: still final, no fallback

    func test_herdrHeaderPresentButUnresolved_isFinal_neverFallsBackToStaleSurfaceHeader() async throws {
        // No pane registered under this (socketPath, paneID) at all --
        // the herdr header is present but resolves to nil. A stale
        // X-Calyx-Surface-ID that WOULD otherwise resolve to a real,
        // distinguishable entry must still be ignored: the herdr
        // header's own unresolved answer is final, not a fallthrough
        // signal.
        let staleButRegisteredSurfaceID = UUID()
        contextProvider.toolNameBySurface[staleButRegisteredSurfaceID] = "from_stale_surface_header"

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "wZ:p9",
            "X-Calyx-Herdr-Socket-Path": "/Users/dev/.config/herdr/herdr.sock",
            "X-Calyx-Surface-ID": staleButRegisteredSurfaceID.uuidString,
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertNil(try resolvedMarker(resp),
                     "an unresolved herdr header must never fall back to a stale X-Calyx-Surface-ID, even " +
                     "when that header resolves to a real, registered surface")
    }

    // MARK: - No herdr header at all: existing session -> surface fallback applies

    func test_noHerdrHeader_fallsBackToSurfaceHeaderResolution() async throws {
        let surfaceID = UUID()
        contextProvider.toolNameBySurface[surfaceID] = "from_surface_header"

        let req = appContextRequest(headers: ["X-Calyx-Surface-ID": surfaceID.uuidString])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(try resolvedMarker(resp), "from_surface_header",
                       "with no herdr header at all, the existing X-Calyx-Surface-ID resolution (shared " +
                       "with /mcp's resolveSurfaceID) must still apply")
    }

    func test_noHerdrHeaderAndNoSessionOrSurfaceHeader_stillServed_paneLess() async throws {
        // A session-less caller (pi, or any client sending no identity
        // headers at all) must still be served -- app_context simply
        // reports for no pane.
        let req = appContextRequest(headers: [:])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertNil(try resolvedMarker(resp))
    }

    // MARK: - Empty/whitespace X-Calyx-Herdr-Pane-ID: absent, not final
    //
    // The injected config entry sends `X-Calyx-Herdr-Pane-ID: ${HERDR_PANE_ID:-}`,
    // which is the empty string on every non-herdr pane. Treating a
    // present-but-empty header as "final" (per the herdr-wins rule above)
    // would strand every ordinary pane with no resolution at all. A
    // present-but-empty or whitespace-only Pane-ID must be treated as
    // absent, exactly like the existing `resolveSurfaceID` trims and
    // treats an empty X-Calyx-Surface-ID as absent
    // (Calyx/Features/IPC/CalyxMCPServer.swift:344-358).

    func test_herdrPaneIDEmpty_treatedAsAbsent_fallsBackToSurfaceHeaderResolution() async throws {
        let surfaceID = UUID()
        contextProvider.toolNameBySurface[surfaceID] = "from_surface_header"

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "",
            "X-Calyx-Surface-ID": surfaceID.uuidString,
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(try resolvedMarker(resp), "from_surface_header",
                       "an empty X-Calyx-Herdr-Pane-ID (the unset-variable substitution outside herdr) must " +
                       "be treated as absent, not as a final-but-unresolved herdr answer")
    }

    func test_herdrPaneIDWhitespaceOnly_treatedAsAbsent_fallsBackToSurfaceHeaderResolution() async throws {
        let surfaceID = UUID()
        contextProvider.toolNameBySurface[surfaceID] = "from_surface_header"

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "   ",
            "X-Calyx-Surface-ID": surfaceID.uuidString,
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(try resolvedMarker(resp), "from_surface_header",
                       "a whitespace-only X-Calyx-Herdr-Pane-ID must be treated as absent, same as empty")
    }

    // MARK: - Empty X-Calyx-Herdr-Socket-Path: default discovery candidate, not an error

    func test_herdrPaneIDPresent_emptySocketPath_stillAttemptsResolutionViaDefaultCandidate() async throws {
        // Per plan §4: X-Calyx-Herdr-Socket-Path is sent only when
        // HERDR_SOCKET_PATH is set in the pane's environment (an
        // explicit low-level override); when empty, Calyx falls back to
        // its existing default socket discovery candidate rather than
        // treating the empty value as a malformed request.
        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "wA:p1",
            "X-Calyx-Herdr-Socket-Path": "",
        ])
        let resp = await server.route(request: req)
        XCTAssertNotEqual(resp.statusCode, 400,
                          "an empty X-Calyx-Herdr-Socket-Path must fall back to default discovery, not be rejected outright")
    }
}
