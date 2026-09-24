//
//  MCPHTTPBearerChallengeTests.swift
//  CalyxTests
//
//  RFC 6750 `WWW-Authenticate: Bearer ...` challenge parsing (API
//  contract section 5.7, same directory as StreamableHTTPMCPTransport.swift):
//
//    struct MCPHTTPBearerChallenge: Sendable, Equatable {
//        let scheme: String              // always "Bearer", matched case-insensitively
//        let resourceMetadata: String?
//        let scope: String?              // multiple values stay space-separated
//        let error: String?
//        let errorDescription: String?
//        static func parse(_ headerValue: String) -> [MCPHTTPBearerChallenge]   // non-Bearer challenges excluded; param order ignored
//    }
//
//  `StreamableHTTPMCPTransport` calls
//  `parse(wwwAuthenticate).first?.error == "insufficient_scope"` to decide
//  whether to invoke `on403InsufficientScope(challenge.scope)`.
//

import XCTest
@testable import Calyx

final class MCPHTTPBearerChallengeTests: XCTestCase {

    // MARK: - Quoted values, all fields present

    func test_parse_quotedParams_allFieldsCaptured() {
        let header = #"Bearer error="insufficient_scope", error_description="More permissions required", scope="tools:execute", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource""#
        let challenges = MCPHTTPBearerChallenge.parse(header)
        XCTAssertEqual(challenges.count, 1)
        let challenge = challenges[0]
        XCTAssertEqual(challenge.scheme, "Bearer")
        XCTAssertEqual(challenge.error, "insufficient_scope")
        XCTAssertEqual(challenge.errorDescription, "More permissions required")
        XCTAssertEqual(challenge.scope, "tools:execute")
        XCTAssertEqual(challenge.resourceMetadata, "https://mcp.example.com/.well-known/oauth-protected-resource")
    }

    // MARK: - Missing optional params decode as nil

    func test_parse_realmOnly_optionalFieldsAreNil() {
        let challenges = MCPHTTPBearerChallenge.parse(#"Bearer realm="mcp""#)
        XCTAssertEqual(challenges.count, 1)
        let challenge = challenges[0]
        XCTAssertEqual(challenge.scheme, "Bearer")
        XCTAssertNil(challenge.error)
        XCTAssertNil(challenge.errorDescription)
        XCTAssertNil(challenge.scope)
        XCTAssertNil(challenge.resourceMetadata)
    }

    // MARK: - Case-insensitive scheme match, always normalized to "Bearer"

    func test_parse_lowercaseScheme_stillMatchesAndNormalizesTo_Bearer() {
        let challenges = MCPHTTPBearerChallenge.parse(#"bearer error="insufficient_scope""#)
        XCTAssertEqual(challenges.count, 1)
        XCTAssertEqual(challenges[0].scheme, "Bearer")
        XCTAssertEqual(challenges[0].error, "insufficient_scope")
    }

    func test_parse_mixedCaseScheme_stillMatches() {
        let challenges = MCPHTTPBearerChallenge.parse(#"BeArEr scope="read""#)
        XCTAssertEqual(challenges.count, 1)
        XCTAssertEqual(challenges[0].scheme, "Bearer")
    }

    // MARK: - Unquoted token values

    func test_parse_unquotedTokenValue_isCaptured() {
        let challenges = MCPHTTPBearerChallenge.parse("Bearer error=insufficient_scope")
        XCTAssertEqual(challenges.count, 1)
        XCTAssertEqual(challenges[0].error, "insufficient_scope")
    }

    // MARK: - Parameter order is ignored

    func test_parse_paramsInReverseOrder_sameResultAsForwardOrder() {
        let forward = MCPHTTPBearerChallenge.parse(#"Bearer error="insufficient_scope", scope="tools:execute""#)
        let reversed = MCPHTTPBearerChallenge.parse(#"Bearer scope="tools:execute", error="insufficient_scope""#)
        XCTAssertEqual(forward, reversed)
    }

    // MARK: - Multiple challenges: non-Bearer schemes are excluded

    func test_parse_bearerAndBasicChallenges_onlyBearerReturned() {
        let header = #"Bearer error="insufficient_scope", Basic realm="fallback""#
        let challenges = MCPHTTPBearerChallenge.parse(header)
        XCTAssertEqual(challenges.count, 1)
        XCTAssertEqual(challenges[0].scheme, "Bearer")
        XCTAssertEqual(challenges[0].error, "insufficient_scope")
    }

    func test_parse_onlyNonBearerChallenge_returnsEmpty() {
        let challenges = MCPHTTPBearerChallenge.parse(#"Basic realm="fallback""#)
        XCTAssertEqual(challenges, [])
    }

    func test_parse_emptyHeaderValue_returnsEmpty() {
        XCTAssertEqual(MCPHTTPBearerChallenge.parse(""), [])
    }

    // MARK: - Multiple space-separated scope values stay joined

    func test_parse_multipleScopeValues_stayAsOneSpaceSeparatedString() {
        let challenges = MCPHTTPBearerChallenge.parse(#"Bearer scope="tools:execute resources:read""#)
        XCTAssertEqual(challenges.count, 1)
        XCTAssertEqual(challenges[0].scope, "tools:execute resources:read")
    }
}
