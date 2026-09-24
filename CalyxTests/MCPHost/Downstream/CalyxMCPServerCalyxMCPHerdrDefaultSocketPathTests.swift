//
//  CalyxMCPServerCalyxMCPHerdrDefaultSocketPathTests.swift
//  CalyxTests
//
//  Coverage: a discriminating test for the empty
//  `X-Calyx-Herdr-Socket-Path` case (plan §4: "空なら既存の既定探索候補
//  でソケットを決めます"). An empty header must not be treated as a
//  malformed request; it must resolve through Calyx's own default
//  discovery candidate. Proven here by actually injecting a candidate
//  and observing that the pane resolves THROUGH it -- not merely that
//  the request isn't rejected (a weak status-only check that a wrong
//  implementation ignoring the empty header entirely would also pass).
//
//  Assumed API surface: `CalyxMCPServer` gains an injectable
//  `herdrDefaultSocketPath: () -> String? = { nil }` (defaulting to the
//  real default-candidate discovery in production; test-overridable to
//  a fixed candidate path here), consulted by the /calyx-mcp route's
//  herdr-first pane resolution exactly when
//  `X-Calyx-Herdr-Socket-Path` is present but empty. A `nil` return
//  means no default candidate is available (e.g. no herdr socket found
//  anywhere) -- resolution then falls through to "no pane", same as an
//  unresolved (socketPath, paneID) pair.
//

import XCTest
@testable import Calyx

@MainActor
private final class RecordingModelContextProvider: MCPAppModelContextProviding {
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
final class CalyxMCPServerCalyxMCPHerdrDefaultSocketPathTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var herdrRegistry: HerdrPaneRegistry!
    private var contextProvider: RecordingModelContextProvider!
    private let testToken = "herdr-default-socket-path-token"
    private var agentEndpointDir: String!
    private let defaultCandidate = "/Users/dev/.config/herdr/herdr.sock"

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

    // MARK: - Empty socket path: resolves through the injected default candidate

    func test_emptySocketPath_resolvesThroughTheInjectedDefaultCandidate() async throws {
        let surfaceID = UUID()
        herdrRegistry.register(
            surfaceID: surfaceID,
            ref: HerdrPaneRef(socketPath: defaultCandidate, paneID: "wA:p1")
        )
        contextProvider.toolNameBySurface[surfaceID] = "from_default_candidate"
        server.herdrDefaultSocketPath = { [defaultCandidate] in defaultCandidate }

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "wA:p1",
            "X-Calyx-Herdr-Socket-Path": "",
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(try resolvedMarker(resp), "from_default_candidate",
                       "an empty X-Calyx-Herdr-Socket-Path must resolve through the default discovery " +
                       "candidate the server injects, not merely avoid a 400")
    }

    func test_emptySocketPath_defaultCandidateReturnsNil_resolvesToNoPane_notAnError() async throws {
        // No herdr socket anywhere -- the default-candidate closure
        // itself has nothing to offer.
        server.herdrDefaultSocketPath = { nil }

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "wA:p1",
            "X-Calyx-Herdr-Socket-Path": "",
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200, "no default candidate available must fall through to no pane, not an error")
        XCTAssertNil(try resolvedMarker(resp))
    }

    func test_emptySocketPath_defaultCandidateDoesNotMatchAnyRegisteredPane_resolvesToNoPane() async throws {
        // The default candidate resolves to a real path, but nothing is
        // registered under (that path, this paneID) -- must behave
        // exactly like any other unresolved herdr header: final,
        // no pane, not an error.
        let staleSurfaceID = UUID()
        contextProvider.toolNameBySurface[staleSurfaceID] = "should_never_be_returned"
        server.herdrDefaultSocketPath = { [defaultCandidate] in defaultCandidate }

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "wZ:pUnregistered",
            "X-Calyx-Herdr-Socket-Path": "",
            "X-Calyx-Surface-ID": staleSurfaceID.uuidString,
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertNil(try resolvedMarker(resp),
                     "an unresolved herdr header (even via the default candidate) must never fall back to " +
                     "a stale X-Calyx-Surface-ID")
    }

    // MARK: - A genuinely present, non-empty socket path never consults the default candidate

    func test_nonEmptySocketPath_neverConsultsTheDefaultCandidate() async throws {
        let explicitSurfaceID = UUID()
        let defaultCandidateSurfaceID = UUID()
        let explicitPath = "/Users/dev/.config/herdr/explicit-override.sock"

        herdrRegistry.register(surfaceID: explicitSurfaceID, ref: HerdrPaneRef(socketPath: explicitPath, paneID: "wA:p1"))
        herdrRegistry.register(surfaceID: defaultCandidateSurfaceID, ref: HerdrPaneRef(socketPath: defaultCandidate, paneID: "wA:p1"))
        contextProvider.toolNameBySurface[explicitSurfaceID] = "from_explicit_path"
        contextProvider.toolNameBySurface[defaultCandidateSurfaceID] = "from_default_candidate"

        var defaultCandidateCalled = false
        server.herdrDefaultSocketPath = { [defaultCandidate] in
            defaultCandidateCalled = true
            return defaultCandidate
        }

        let req = appContextRequest(headers: [
            "X-Calyx-Herdr-Pane-ID": "wA:p1",
            "X-Calyx-Herdr-Socket-Path": explicitPath,
        ])
        let resp = await server.route(request: req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(try resolvedMarker(resp), "from_explicit_path",
                       "HERDR_SOCKET_PATH, when set, is an explicit low-level override and must win over " +
                       "the default candidate even when both happen to resolve to a real registered pane")
        XCTAssertFalse(defaultCandidateCalled,
                       "the default-candidate closure must never be consulted when an explicit, non-empty " +
                       "socket path is present")
    }
}
