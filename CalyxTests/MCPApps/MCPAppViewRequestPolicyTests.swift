//
//  MCPAppViewRequestPolicyTests.swift
//  CalyxTests
//
//  Pure policy for the ui/* request table (plan §9): ui/open-link accepts
//  only http, https, mailto; sampling/createMessage is never declared, so
//  every request for it is -32601; a view's tools/call is gated on the
//  tool's declared visibility (absent visibility defaults to
//  ["model","app"], so it's callable unless a server explicitly narrows
//  it to "model" only); ui/request-display-mode follows the MCP Apps
//  spec verbatim: "Host MUST return the resulting mode (whether updated
//  or not)" and "Host MUST NOT switch the View to a display mode that
//  does not appear in its appCapabilities.availableDisplayModes" -- a
//  VALID mode that is simply unavailable where the view is placed is
//  NOT an error, it is a silent no-op that still returns the (unchanged)
//  current mode. Only a string that isn't one of the three defined
//  modes is invalid params (-32602).
//

import XCTest
@testable import Calyx

final class MCPAppViewRequestPolicyTests: XCTestCase {

    // MARK: - ui/open-link scheme allowlist

    func test_openLink_https_isAllowed() {
        XCTAssertTrue(MCPAppOpenLinkPolicy.isAllowedScheme(URL(string: "https://example.com")!))
    }

    func test_openLink_http_isAllowed() {
        XCTAssertTrue(MCPAppOpenLinkPolicy.isAllowedScheme(URL(string: "http://example.com")!))
    }

    func test_openLink_mailto_isAllowed() {
        XCTAssertTrue(MCPAppOpenLinkPolicy.isAllowedScheme(URL(string: "mailto:someone@example.com")!))
    }

    func test_openLink_file_isRejected() {
        XCTAssertFalse(MCPAppOpenLinkPolicy.isAllowedScheme(URL(string: "file:///etc/passwd")!))
    }

    func test_openLink_javascript_isRejected() {
        XCTAssertFalse(MCPAppOpenLinkPolicy.isAllowedScheme(URL(string: "javascript:alert(1)")!))
    }

    func test_openLink_customScheme_isRejected() {
        XCTAssertFalse(MCPAppOpenLinkPolicy.isAllowedScheme(URL(string: "calyx-mcp-app://x")!))
    }

    // MARK: - URL-mode elicitation opens only what ui/open-link may open

    @MainActor
    func test_urlElicitation_httpsAndMailto_areOpenable() {
        XCTAssertEqual(MCPElicitationURLState(text: "https://example.com/verify").url, URL(string: "https://example.com/verify"))
        XCTAssertEqual(MCPElicitationURLState(text: "http://example.com/verify").url, URL(string: "http://example.com/verify"))
        XCTAssertEqual(MCPElicitationURLState(text: "mailto:someone@example.com").url, URL(string: "mailto:someone@example.com"))
    }

    @MainActor
    func test_urlElicitation_otherSchemes_areNotOpenable() {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "calyx-mcp-app://x", "ssh://host", "x-apple.systempreferences:com.apple.preference"] {
            XCTAssertNil(MCPElicitationURLState(text: text).url, "\(text) must not enable Open")
        }
    }

    // MARK: - sampling/createMessage: never declared, always -32601

    func test_sampling_isAlwaysMinus32601() {
        let error = MCPAppUnsupportedMethods.errorForSampling()
        XCTAssertEqual(error.code, -32601)
    }

    // MARK: - Tool visibility gating (view's own tools/call)

    private func tool(name: String, visibility: Set<MCPToolVisibility>?) throws -> MCPToolDefinition {
        var raw: [String: AnyCodable] = ["name": AnyCodable(name)]
        if let visibility {
            raw["_meta"] = AnyCodable([
                "ui": AnyCodable([
                    "resourceUri": AnyCodable("ui://server/view"),
                    "visibility": AnyCodable(visibility.map { AnyCodable($0.rawValue) }),
                ])
            ])
        }
        return try MCPToolDefinition(raw: raw)
    }

    func test_visibilityAbsent_defaultsToModelAndApp_isCallableByApp() throws {
        let definition = try tool(name: "dashboard", visibility: nil)
        XCTAssertTrue(MCPAppViewToolAccess.isCallable(tool: definition, byApp: true))
    }

    func test_visibilityIncludesApp_isCallableByApp() throws {
        let definition = try tool(name: "dashboard", visibility: [.model, .app])
        XCTAssertTrue(MCPAppViewToolAccess.isCallable(tool: definition, byApp: true))
    }

    func test_visibilityModelOnly_isNotCallableByApp() throws {
        let definition = try tool(name: "internal_only", visibility: [.model])
        XCTAssertFalse(MCPAppViewToolAccess.isCallable(tool: definition, byApp: true))
    }

    func test_visibilityAppOnly_isCallableByApp() throws {
        let definition = try tool(name: "app_only", visibility: [.app])
        XCTAssertTrue(MCPAppViewToolAccess.isCallable(tool: definition, byApp: true))
    }

    func test_visibilityAppOnly_withNoResourceURI_isStillCallableByApp() throws {
        // Mirrors the E2E fixture's own `record_event` tool (finding 4):
        // an app-registered tool has `_meta.ui = {visibility: ["app"]}`
        // and NO resourceUri at all (it has no view of its own -- it is
        // called BY a view, never rendered). Visibility gating must read
        // `tool.visibility` independently of whether `tool.ui` decoded to
        // non-nil.
        let raw: [String: AnyCodable] = [
            "name": AnyCodable("record_event"),
            "_meta": AnyCodable(["ui": AnyCodable(["visibility": AnyCodable([AnyCodable("app")])])])
        ]
        let definition = try MCPToolDefinition(raw: raw)
        XCTAssertNil(definition.ui, "no resourceUri means tool.ui decodes to nil entirely")
        XCTAssertEqual(definition.visibility, [.app])
        XCTAssertTrue(MCPAppViewToolAccess.isCallable(tool: definition, byApp: true))
    }

    func test_visibilityModelOnly_mustNotAppearInAgentToolList() throws {
        // Finding 4: "Host MUST NOT include tools in the agent's tool list
        // when their visibility does not include 'model'." A model-only
        // tool (declared for the agent) must never be callable by an app.
        let definition = try tool(name: "internal_only", visibility: [.model])
        XCTAssertEqual(definition.visibility, [.model])
        XCTAssertFalse(MCPAppViewToolAccess.isCallable(tool: definition, byApp: true))
    }

    // MARK: - ui/request-display-mode: MUST return the resulting mode (updated or not);
    //         MUST NOT switch to a mode outside availableDisplayModes

    func test_requestDisplayMode_availableMode_resolvesToRequestedMode() {
        let result = MCPAppDisplayModeRequest.resolve(requested: "fullscreen", available: ["inline", "fullscreen", "pip"], current: "inline")
        guard case .success(let mode) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(mode, "fullscreen")
    }

    func test_requestDisplayMode_validButUnavailableMode_forStandalonePanel_isNotAnError_returnsCurrentUnchanged() {
        // Spec: "Host MUST NOT switch the View to a display mode that does
        // not appear in its appCapabilities.availableDisplayModes" -- this
        // is a silent no-op, not a protocol error, so the request still
        // succeeds and reports the mode that actually applies (the
        // unchanged current one). A standalone panel's availableDisplayModes
        // never includes "pip", but "pip" is still a VALID defined mode.
        let result = MCPAppDisplayModeRequest.resolve(requested: "pip", available: ["inline", "fullscreen"], current: "inline")
        guard case .success(let mode) = result else { return XCTFail("expected success (spec: MUST return the resulting mode, whether updated or not), got \(result)") }
        XCTAssertEqual(mode, "inline", "an unavailable mode must not switch the view -- the resulting mode is the unchanged current one")
    }

    func test_requestDisplayMode_unknownModeString_isRejected() {
        let result = MCPAppDisplayModeRequest.resolve(requested: "teleport", available: ["inline", "fullscreen", "pip"], current: "inline")
        guard case .failure(let error) = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertEqual(error.code, -32602)
    }

    func test_requestDisplayMode_sameAsCurrent_stillResolvesSuccessfully() {
        let result = MCPAppDisplayModeRequest.resolve(requested: "inline", available: ["inline", "fullscreen"], current: "inline")
        guard case .success(let mode) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(mode, "inline")
    }
}
