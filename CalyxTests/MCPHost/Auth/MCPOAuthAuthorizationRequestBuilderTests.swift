//
//  MCPOAuthAuthorizationRequestBuilderTests.swift
//  CalyxTests
//
//  API contract section 6.5.
//
//    enum MCPOAuthAuthorizationRequestBuilder {
//        static func buildURL(
//            authorizationEndpoint: URL,
//            clientID: String,
//            redirectURI: String,
//            codeChallenge: String,
//            state: String,
//            canonicalResourceURI: String,
//            scope: String?
//        ) -> URL
//    }
//
//  The `resource` parameter (RFC 8707) has no trailing slash and no
//  fragment; `scope` is omitted entirely when nil.
//

import XCTest
@testable import Calyx

final class MCPOAuthAuthorizationRequestBuilderTests: XCTestCase {

    private func query(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: - response_type, PKCE challenge, client_id, state

    func test_buildURL_containsResponseTypeCodeAndS256Challenge() {
        let url = MCPOAuthAuthorizationRequestBuilder.buildURL(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            clientID: "client-123",
            redirectURI: "http://127.0.0.1:54321/callback",
            codeChallenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            state: "abc123state",
            canonicalResourceURI: "https://mcp.example.com/mcp",
            scope: "files:read"
        )
        XCTAssertEqual(url.host, "auth.example.com")
        XCTAssertEqual(url.path, "/authorize")
        let params = query(of: url)
        XCTAssertEqual(params["response_type"], "code")
        XCTAssertEqual(params["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["client_id"], "client-123")
        XCTAssertEqual(params["state"], "abc123state")
        XCTAssertEqual(params["redirect_uri"], "http://127.0.0.1:54321/callback")
    }

    // MARK: - resource: no trailing slash, no fragment (RFC 8707)

    func test_buildURL_resourceParameter_canonicalNoTrailingSlashNoFragment() {
        let url = MCPOAuthAuthorizationRequestBuilder.buildURL(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            clientID: "client-123",
            redirectURI: "http://127.0.0.1:54321/callback",
            codeChallenge: "challenge",
            state: "state",
            canonicalResourceURI: "https://mcp.example.com/mcp",
            scope: nil
        )
        let params = query(of: url)
        XCTAssertEqual(params["resource"], "https://mcp.example.com/mcp")
        XCTAssertFalse(params["resource"]!.hasSuffix("/"))
        XCTAssertFalse(params["resource"]!.contains("#"))
    }

    // MARK: - scope omitted when nil

    func test_buildURL_scope_omittedWhenNil() {
        let url = MCPOAuthAuthorizationRequestBuilder.buildURL(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            clientID: "client-123",
            redirectURI: "http://127.0.0.1:54321/callback",
            codeChallenge: "challenge",
            state: "state",
            canonicalResourceURI: "https://mcp.example.com/mcp",
            scope: nil
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertNil((components.queryItems ?? []).first(where: { $0.name == "scope" }))
    }

    // MARK: - scope present is carried verbatim

    func test_buildURL_scope_presentIsCarriedVerbatim() {
        let url = MCPOAuthAuthorizationRequestBuilder.buildURL(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            clientID: "client-123",
            redirectURI: "http://127.0.0.1:54321/callback",
            codeChallenge: "challenge",
            state: "state",
            canonicalResourceURI: "https://mcp.example.com/mcp",
            scope: "files:read files:write"
        )
        XCTAssertEqual(query(of: url)["scope"], "files:read files:write")
    }
}
