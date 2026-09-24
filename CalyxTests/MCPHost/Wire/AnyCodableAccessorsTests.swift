//
//  AnyCodableAccessorsTests.swift
//  CalyxTests
//
//  Typed read accessors added to `AnyCodable` for MCP wire decoding:
//  objectValue, arrayValue, stringValue, intValue, doubleValue, boolValue,
//  isNull, and the `subscript(key:)` convenience for nested object reads.
//

import XCTest
@testable import Calyx

final class AnyCodableAccessorsTests: XCTestCase {

    func test_stringValue_returnsUnderlyingString() {
        let value = AnyCodable("hello")
        XCTAssertEqual(value.stringValue, "hello")
    }

    func test_stringValue_isNilForNonStringStorage() {
        let value = AnyCodable(42)
        XCTAssertNil(value.stringValue)
    }

    func test_intValue_returnsUnderlyingInt() {
        let value = AnyCodable(7)
        XCTAssertEqual(value.intValue, 7)
    }

    func test_intValue_isNilForDoubleStorage() {
        let value = AnyCodable(7.5)
        XCTAssertNil(value.intValue)
    }

    func test_doubleValue_returnsUnderlyingDouble() {
        let value = AnyCodable(3.14)
        XCTAssertEqual(value.doubleValue, 3.14)
    }

    func test_doubleValue_isNilForStringStorage() {
        let value = AnyCodable("3.14")
        XCTAssertNil(value.doubleValue)
    }

    func test_boolValue_returnsUnderlyingBool() {
        let value = AnyCodable(true)
        XCTAssertEqual(value.boolValue, true)
    }

    func test_boolValue_isNilForIntStorage() {
        // Regression guard for the AnyCodable(Any) NSNumber/Bool
        // discrimination bug documented in JSONRPC.swift: an Int(1)
        // must never read back as boolValue == true.
        let value = AnyCodable(1)
        XCTAssertNil(value.boolValue)
    }

    func test_arrayValue_returnsUnderlyingArray() {
        let value = AnyCodable([AnyCodable("a"), AnyCodable(1)])
        XCTAssertEqual(value.arrayValue, [AnyCodable("a"), AnyCodable(1)])
    }

    func test_arrayValue_isNilForObjectStorage() {
        let value = AnyCodable(["k": AnyCodable("v")])
        XCTAssertNil(value.arrayValue)
    }

    func test_objectValue_returnsUnderlyingDictionary() {
        let value = AnyCodable(["k": AnyCodable("v")])
        XCTAssertEqual(value.objectValue, ["k": AnyCodable("v")])
    }

    func test_objectValue_isNilForArrayStorage() {
        let value = AnyCodable([AnyCodable("a")])
        XCTAssertNil(value.objectValue)
    }

    func test_isNull_trueForNullStorage() throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data("null".utf8))
        XCTAssertTrue(decoded.isNull)
    }

    func test_isNull_falseForNonNullStorage() {
        XCTAssertFalse(AnyCodable(0).isNull)
    }

    func test_subscript_readsNestedObjectValueByKey() {
        let value = AnyCodable(["outer": AnyCodable(["inner": AnyCodable("x")])])
        XCTAssertEqual(value["outer"]?["inner"]?.stringValue, "x")
    }

    func test_subscript_isNilWhenStorageIsNotAnObject() {
        let value = AnyCodable([AnyCodable("a")])
        XCTAssertNil(value["anything"])
    }

    func test_subscript_isNilWhenKeyMissing() {
        let value = AnyCodable(["k": AnyCodable("v")])
        XCTAssertNil(value["missing"])
    }

    // MARK: - static let null

    func test_staticNull_isNullTrue() {
        XCTAssertTrue(AnyCodable.null.isNull)
    }

    func test_staticNull_encodesToJSONNullLiteral() throws {
        let encoded = try JSONEncoder().encode(AnyCodable.null)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "null")
    }

    func test_staticNull_equalsValueDecodedFromJSONNull() throws {
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: Data("null".utf8))
        XCTAssertEqual(decoded, AnyCodable.null)
    }
}
