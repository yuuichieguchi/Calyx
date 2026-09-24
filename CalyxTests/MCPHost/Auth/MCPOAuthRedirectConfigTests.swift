//
//  MCPOAuthRedirectConfigTests.swift
//  CalyxTests
//
//  API contract section 6.4. `MCPOAuthRedirectConfig` is the single
//  place the fixed loopback OAuth callback port (41890) is defined.
//
//    enum MCPOAuthRedirectHost: String, Sendable, Equatable, Codable { case loopback, localhost }
//    enum MCPOAuthRedirectPort: Sendable, Equatable, Codable { case random; case calyxFixed }
//    struct MCPOAuthRedirectConfig: Sendable, Equatable, Codable {
//        let host: MCPOAuthRedirectHost
//        let port: MCPOAuthRedirectPort
//        static let calyxFixedPort = 41890
//    }
//

import XCTest
@testable import Calyx

final class MCPOAuthRedirectConfigTests: XCTestCase {

    // MARK: - 41890 is defined exactly once, here

    func test_calyxFixedPort_is41890() {
        XCTAssertEqual(MCPOAuthRedirectConfig.calyxFixedPort, 41890)
    }

    // MARK: - Equatable distinguishes host and port independently

    func test_equatable_sameHostAndPort_areEqual() {
        let a = MCPOAuthRedirectConfig(host: .loopback, port: .random)
        let b = MCPOAuthRedirectConfig(host: .loopback, port: .random)
        XCTAssertEqual(a, b)
    }

    func test_equatable_differentHost_areNotEqual() {
        let a = MCPOAuthRedirectConfig(host: .loopback, port: .random)
        let b = MCPOAuthRedirectConfig(host: .localhost, port: .random)
        XCTAssertNotEqual(a, b)
    }

    func test_equatable_differentPort_areNotEqual() {
        let a = MCPOAuthRedirectConfig(host: .loopback, port: .random)
        let b = MCPOAuthRedirectConfig(host: .loopback, port: .calyxFixed)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip preserves both cases

    func test_codable_roundTrip_calyxFixedPort_preservesHostAndPort() throws {
        let original = MCPOAuthRedirectConfig(host: .localhost, port: .calyxFixed)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPOAuthRedirectConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_codable_roundTrip_randomPort_preservesHostAndPort() throws {
        let original = MCPOAuthRedirectConfig(host: .loopback, port: .random)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPOAuthRedirectConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
