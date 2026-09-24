//
//  MCPServerAliasTests.swift
//  CalyxTests
//
//  Alias validation, derivation from a display name, and the
//  MCPServerID-based fallback used when derivation yields nothing
//  usable. Alias syntax: `^[a-z][a-z0-9]{0,9}$` -- lowercase, starts
//  with a letter, at most 10 characters total. Contract v2 SS7.2.
//

import XCTest
@testable import Calyx

final class MCPServerAliasTests: XCTestCase {

    private struct AliasBox: Codable { let alias: MCPServerAlias }

    // MARK: - Raw value validation

    func test_rawValue_validLowercaseAlphanumeric_accepted() {
        XCTAssertNotNil(MCPServerAlias(rawValue: "myserver1"))
        XCTAssertNotNil(MCPServerAlias(rawValue: "a"))
    }

    func test_rawValue_exactlyTenCharacters_accepted() {
        XCTAssertNotNil(MCPServerAlias(rawValue: "abcdefghij")) // 10 chars
    }

    func test_rawValue_elevenCharacters_rejected() {
        XCTAssertNil(MCPServerAlias(rawValue: "abcdefghijk")) // 11 chars
    }

    func test_rawValue_uppercase_rejected() {
        XCTAssertNil(MCPServerAlias(rawValue: "MyServer"))
    }

    func test_rawValue_startsWithDigit_rejected() {
        XCTAssertNil(MCPServerAlias(rawValue: "1server"))
    }

    func test_rawValue_containsHyphen_rejected() {
        XCTAssertNil(MCPServerAlias(rawValue: "my-server"))
    }

    func test_rawValue_empty_rejected() {
        XCTAssertNil(MCPServerAlias(rawValue: ""))
    }

    func test_rawValue_containsSpace_rejected() {
        XCTAssertNil(MCPServerAlias(rawValue: "my server"))
    }

    // MARK: - Derivation from display name

    func test_derive_simpleLowercaseName_usedVerbatim() {
        XCTAssertEqual(MCPServerAliasDeriver.derive(fromDisplayName: "weather"), "weather")
    }

    func test_derive_upperCaseAndSpaces_normalizedToLowercaseAlphanumeric() {
        XCTAssertEqual(MCPServerAliasDeriver.derive(fromDisplayName: "My Weather Server"), "myweathers")
    }

    func test_derive_truncatesToTenCharacters() {
        let derived = MCPServerAliasDeriver.derive(fromDisplayName: "abcdefghijklmnop")
        XCTAssertEqual(derived?.count, 10)
        XCTAssertEqual(derived, "abcdefghij")
    }

    func test_derive_nameWithNoAlphanumericCharacters_returnsNil() {
        XCTAssertNil(MCPServerAliasDeriver.derive(fromDisplayName: "!!! ??? ---"))
    }

    // MARK: - Leading digits are stripped (SS7.2: normalize, strip leading digits, then truncate)

    func test_derive_leadingDigitsBeforeALetter_stripped() {
        // "42 Server" -> lowercase "42 server" -> remove non-alnum "42server"
        // -> strip the leading digits "42" -> "server".
        XCTAssertEqual(MCPServerAliasDeriver.derive(fromDisplayName: "42 Server"), "server")
    }

    func test_derive_allDigits_returnsNil() {
        // Nothing survives once the leading (here, all) digits are stripped.
        XCTAssertNil(MCPServerAliasDeriver.derive(fromDisplayName: "42"))
    }

    // MARK: - Alias is Hashable (usable as a Set element / dictionary key)

    func test_alias_isHashable_usableInASet() {
        let a = MCPServerAlias(rawValue: "weather")!
        let b = MCPServerAlias(rawValue: "search")!
        let set: Set<MCPServerAlias> = [a, b, a]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Decoding an invalid raw value throws (does not silently produce nil)

    func test_decode_invalidRawValue_throws() {
        let json = #"{"alias":"Bad-Alias!"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(AliasBox.self, from: Data(json.utf8)))
    }

    func test_decode_validRawValue_roundTrips() throws {
        let json = #"{"alias":"weather"}"#
        let decoded = try JSONDecoder().decode(AliasBox.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.alias.rawValue, "weather")
    }

    // MARK: - MCPServerID fallback (SS2.0/SS7.1: MCPServerID wraps a UUID)

    func test_fallback_startsWithSrvPrefix() {
        let id = MCPServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        XCTAssertTrue(MCPServerAliasDeriver.fallback(forServerID: id).hasPrefix("srv"))
    }

    func test_fallback_isAValidAlias() {
        let id = MCPServerID(rawValue: UUID(uuidString: "12345678-1234-5678-1234-567812345678")!)
        let fallback = MCPServerAliasDeriver.fallback(forServerID: id)
        XCTAssertNotNil(MCPServerAlias(rawValue: fallback), "the fallback itself must satisfy the alias regex")
    }

    func test_fallback_isDeterministic_forTheSameServerID() {
        let id = MCPServerID(rawValue: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        XCTAssertEqual(MCPServerAliasDeriver.fallback(forServerID: id), MCPServerAliasDeriver.fallback(forServerID: id))
    }

    func test_fallback_distinctForDistinctServerIDs() {
        let a = MCPServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = MCPServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        XCTAssertNotEqual(MCPServerAliasDeriver.fallback(forServerID: a), MCPServerAliasDeriver.fallback(forServerID: b))
    }
}
