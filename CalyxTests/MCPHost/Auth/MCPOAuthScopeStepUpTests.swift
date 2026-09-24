//
//  MCPOAuthScopeStepUpTests.swift
//  CalyxTests
//
//  API contract section 6.7. A pure static union, not an actor (the old
//  contract's actor was a modeling error corrected here).
//
//    enum MCPOAuthScopeStepUp {
//        static func union(previouslyGrantedScope: String?, challengeScope: String?) -> String?
//    }
//
//  Scope strings are RFC 6749 3.3 space-delimited token sets; order is
//  not part of the contract, so assertions compare the token set, not
//  the exact string, except where only one side has content.
//

import XCTest
@testable import Calyx

final class MCPOAuthScopeStepUpTests: XCTestCase {

    private func tokens(_ scope: String?) -> Set<String> {
        Set((scope ?? "").split(separator: " ").map(String.init))
    }

    // MARK: - Both nil: nil

    func test_union_bothNil_isNil() {
        XCTAssertNil(MCPOAuthScopeStepUp.union(previouslyGrantedScope: nil, challengeScope: nil))
    }

    // MARK: - No previous scope: result is exactly the challenge scope

    func test_union_noPreviousScope_isExactlyTheChallengeScope() {
        let union = MCPOAuthScopeStepUp.union(previouslyGrantedScope: nil, challengeScope: "files:write")
        XCTAssertEqual(union, "files:write")
    }

    // MARK: - No challenge scope: result is exactly the previous scope

    func test_union_noChallengeScope_containsExactlyThePreviousScopeTokens() {
        let union = MCPOAuthScopeStepUp.union(previouslyGrantedScope: "files:read profile", challengeScope: nil)
        XCTAssertEqual(tokens(union), ["files:read", "profile"])
    }

    // MARK: - Disjoint scopes: union of both token sets

    func test_union_disjointScopes_containsAllTokensFromBoth() {
        let union = MCPOAuthScopeStepUp.union(previouslyGrantedScope: "files:read profile", challengeScope: "files:write")
        XCTAssertEqual(tokens(union), ["files:read", "profile", "files:write"])
    }

    // MARK: - Overlapping scopes: duplicates collapse

    func test_union_overlappingScopes_dedupes() {
        let union = MCPOAuthScopeStepUp.union(previouslyGrantedScope: "files:read", challengeScope: "files:read files:write")
        XCTAssertEqual(tokens(union), ["files:read", "files:write"])
    }
}
