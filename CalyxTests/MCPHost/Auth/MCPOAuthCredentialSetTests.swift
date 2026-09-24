//
//  MCPOAuthCredentialSetTests.swift
//  CalyxTests
//
//  API contract section 6.1. File name avoids "token" per the Auth
//  module's filename constraint; the type itself is `MCPOAuthTokenSet`.
//
//    struct MCPOAuthTokenSet: Sendable, Equatable {
//        let accessToken: String
//        let refreshToken: String?
//        let expiresAt: Date?
//        let scope: String?
//    }
//    extension MCPOAuthTokenSet: CustomStringConvertible, CustomDebugStringConvertible {
//        var description: String {
//            "MCPOAuthTokenSet(accessToken: <redacted>, refreshToken: \(refreshToken == nil ? "nil" : "<redacted>"), expiresAt: \(String(describing: expiresAt)), scope: \(String(describing: scope)))"
//        }
//        var debugDescription: String { description }
//    }
//

import XCTest
@testable import Calyx

final class MCPOAuthCredentialSetTests: XCTestCase {

    // MARK: - Exact literal format, all optional fields nil

    func test_description_allOptionalFieldsNil_matchesExactLiteral() {
        let tokens = MCPOAuthTokenSet(accessToken: "abc", refreshToken: nil, expiresAt: nil, scope: nil)
        XCTAssertEqual(
            tokens.description,
            "MCPOAuthTokenSet(accessToken: <redacted>, refreshToken: nil, expiresAt: nil, scope: nil)"
        )
    }

    // MARK: - refreshToken present is redacted, not "nil"

    func test_description_refreshTokenPresent_isRedactedNotNil() {
        let tokens = MCPOAuthTokenSet(accessToken: "abc", refreshToken: "xyz", expiresAt: nil, scope: nil)
        XCTAssertEqual(
            tokens.description,
            "MCPOAuthTokenSet(accessToken: <redacted>, refreshToken: <redacted>, expiresAt: nil, scope: nil)"
        )
    }

    // MARK: - scope is not redacted, printed via String(describing:)

    func test_description_scopePresent_printedUnredacted() {
        let tokens = MCPOAuthTokenSet(accessToken: "abc", refreshToken: nil, expiresAt: nil, scope: "files:read")
        XCTAssertEqual(
            tokens.description,
            #"MCPOAuthTokenSet(accessToken: <redacted>, refreshToken: nil, expiresAt: nil, scope: Optional("files:read"))"#
        )
    }

    // MARK: - Neither description nor debugDescription leaks raw values

    func test_description_neverContainsRawAccessOrRefreshTokenValues() {
        let tokens = MCPOAuthTokenSet(accessToken: "access-abc", refreshToken: "refresh-xyz", expiresAt: nil, scope: "files:read")
        XCTAssertFalse(tokens.description.contains(tokens.accessToken))
        XCTAssertFalse(tokens.description.contains(tokens.refreshToken!))
    }

    func test_debugDescription_equalsDescription_neverLeaksRawValues() {
        let tokens = MCPOAuthTokenSet(accessToken: "access-abc", refreshToken: "refresh-xyz", expiresAt: nil, scope: nil)
        XCTAssertEqual(tokens.debugDescription, tokens.description)
        XCTAssertFalse(tokens.debugDescription.contains(tokens.accessToken))
        XCTAssertFalse(tokens.debugDescription.contains(tokens.refreshToken!))
    }

    func test_stringDescribing_and_stringReflecting_neverContainRawAccessToken() {
        let tokens = MCPOAuthTokenSet(accessToken: "access-abc", refreshToken: "refresh-xyz", expiresAt: nil, scope: nil)
        XCTAssertFalse(String(describing: tokens).contains(tokens.accessToken))
        XCTAssertFalse(String(reflecting: tokens).contains(tokens.accessToken))
    }

    // MARK: - Equatable

    func test_equatable_sameFields_areEqual() {
        let a = MCPOAuthTokenSet(accessToken: "abc", refreshToken: "xyz", expiresAt: Date(timeIntervalSince1970: 0), scope: "files:read")
        let b = MCPOAuthTokenSet(accessToken: "abc", refreshToken: "xyz", expiresAt: Date(timeIntervalSince1970: 0), scope: "files:read")
        XCTAssertEqual(a, b)
    }

    func test_equatable_differentAccessToken_areNotEqual() {
        let a = MCPOAuthTokenSet(accessToken: "abc", refreshToken: nil, expiresAt: nil, scope: nil)
        let b = MCPOAuthTokenSet(accessToken: "def", refreshToken: nil, expiresAt: nil, scope: nil)
        XCTAssertNotEqual(a, b)
    }
}
