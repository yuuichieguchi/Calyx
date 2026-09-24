//
//  JSONRPCMessageTests.swift
//  CalyxTests
//
//  Coverage:
//    - `JSONRPCError.data` encodes/decodes and is omitted from JSON when nil
//    - `JSONRPCMessage.parse` classifies request / notification / response /
//      batch, and rejects malformed input with the specific
//      `JSONRPCMessageParseError` case
//    - `.response(id:)` allows a null id: a JSON-RPC error response for a
//      request whose id could not even be parsed carries `"id": null` per
//      the JSON-RPC 2.0 spec
//    - `0` is a valid id and must round-trip as a number, never be treated
//      as an absent id
//    - `JSONRPCError`/`JSONRPCMessage` are both `Equatable` (asserted
//      implicitly by every `guard case` pattern match plus a direct `==`
//      comparison below) and `Sendable` (asserted by crossing an
//      `@Sendable` closure boundary)
//

import XCTest
@testable import Calyx

final class JSONRPCMessageTests: XCTestCase {

    // MARK: - JSONRPCError.data

    func test_error_data_decodesWhenPresent() throws {
        let json = #"{"code":-32022,"message":"unsupported version","data":{"supported":["2026-07-28"]}}"#
        let error = try JSONDecoder().decode(JSONRPCError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, -32022)
        XCTAssertEqual(error.message, "unsupported version")
        XCTAssertEqual(error.data?["supported"]?.arrayValue?.first?.stringValue, "2026-07-28")
    }

    func test_error_data_isNilWhenAbsent() throws {
        let json = #"{"code":-32601,"message":"Method not found"}"#
        let error = try JSONDecoder().decode(JSONRPCError.self, from: Data(json.utf8))
        XCTAssertNil(error.data)
    }

    func test_error_encode_omitsDataKeyWhenNil() throws {
        let error = JSONRPCError(code: -32601, message: "Method not found", data: nil)
        let encoded = try JSONEncoder().encode(error)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(object)
        XCTAssertFalse(object?.keys.contains("data") ?? true, "data key must be omitted, not encoded as null, when nil")
    }

    func test_error_encode_includesDataWhenPresent() throws {
        let error = JSONRPCError(code: -32022, message: "unsupported", data: AnyCodable(["supported": AnyCodable([AnyCodable("2026-07-28")])]))
        let encoded = try JSONEncoder().encode(error)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertNotNil(object?["data"])
    }

    // MARK: - JSONRPCMessage.parse: request

    func test_parse_classifiesRequestByMethodAndId() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x"}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .request(let id, let method, let params) = message else {
            return XCTFail("expected .request, got \(message)")
        }
        XCTAssertEqual(id, .int(1))
        XCTAssertEqual(method, "tools/call")
        XCTAssertEqual(params?["name"]?.stringValue, "x")
    }

    func test_parse_request_supportsStringId() throws {
        let json = #"{"jsonrpc":"2.0","id":"req-42","method":"ping"}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .request(let id, let method, _) = message else {
            return XCTFail("expected .request, got \(message)")
        }
        XCTAssertEqual(id, .string("req-42"))
        XCTAssertEqual(method, "ping")
    }

    // MARK: - JSONRPCMessage.parse: notification

    func test_parse_classifiesNotificationByMethodWithoutId() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .notification(let method, let params) = message else {
            return XCTFail("expected .notification, got \(message)")
        }
        XCTAssertEqual(method, "notifications/cancelled")
        XCTAssertEqual(params?["requestId"]?.intValue, 1)
    }

    func test_parse_notification_withoutParams() throws {
        let json = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .notification(let method, let params) = message else {
            return XCTFail("expected .notification, got \(message)")
        }
        XCTAssertEqual(method, "notifications/initialized")
        XCTAssertNil(params)
    }

    // MARK: - JSONRPCMessage.parse: response

    func test_parse_classifiesSuccessResponseByAbsentMethod() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .response(let id, let result, let error) = message else {
            return XCTFail("expected .response, got \(message)")
        }
        XCTAssertEqual(id, .int(1))
        XCTAssertEqual(result?["ok"]?.boolValue, true)
        XCTAssertNil(error)
    }

    func test_parse_classifiesErrorResponse() throws {
        let json = #"{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .response(let id, let result, let error) = message else {
            return XCTFail("expected .response, got \(message)")
        }
        XCTAssertEqual(id, .int(2))
        XCTAssertNil(result)
        XCTAssertEqual(error?.code, -32601)
    }

    // MARK: - JSONRPCMessage.parse: batch

    func test_parse_classifiesTopLevelArrayAsBatch() throws {
        let json = #"[{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":1,"result":{}}]"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .batch(let messages) = message else {
            return XCTFail("expected .batch, got \(message)")
        }
        XCTAssertEqual(messages.count, 2)
        guard case .notification(let method, _) = messages[0] else {
            return XCTFail("expected first element to be .notification")
        }
        XCTAssertEqual(method, "notifications/initialized")
        guard case .response(let id, _, _) = messages[1] else {
            return XCTFail("expected second element to be .response")
        }
        XCTAssertEqual(id, .int(1))
    }

    func test_parse_emptyBatchArray_parsesToEmptyBatch() throws {
        let message = try JSONRPCMessage.parse(Data("[]".utf8))
        guard case .batch(let messages) = message else {
            return XCTFail("expected .batch, got \(message)")
        }
        XCTAssertTrue(messages.isEmpty)
    }

    // MARK: - JSONRPCMessage.parse: malformed input

    func test_parse_throwsNotObjectOrArray_onTopLevelString() {
        XCTAssertThrowsError(try JSONRPCMessage.parse(Data(#""just a string""#.utf8))) { error in
            XCTAssertEqual(error as? JSONRPCMessageParseError, .notObjectOrArray)
        }
    }

    func test_parse_throwsInvalidJSON_onMalformedJSON() {
        XCTAssertThrowsError(try JSONRPCMessage.parse(Data("{not json".utf8))) { error in
            XCTAssertEqual(error as? JSONRPCMessageParseError, .invalidJSON)
        }
    }

    func test_parse_throwsMissingMethodAndResult_whenNeitherMethodNorResultNorErrorPresent() {
        // An object with jsonrpc+id but no method/result/error is not a
        // valid request, notification, or response.
        XCTAssertThrowsError(try JSONRPCMessage.parse(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))) { error in
            XCTAssertEqual(error as? JSONRPCMessageParseError, .missingMethodAndResult)
        }
    }

    // MARK: - .response(id:) allows a null id

    func test_parse_response_withNullId_isAllowed() throws {
        let json = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .response(let id, let result, let error) = message else {
            return XCTFail("expected .response, got \(message)")
        }
        XCTAssertNil(id)
        XCTAssertNil(result)
        XCTAssertEqual(error?.code, -32700)
    }

    // MARK: - id 0 is a valid id, never treated as absent

    func test_parse_request_zeroId_isPreservedAsNumberNotTreatedAsMissing() throws {
        let json = #"{"jsonrpc":"2.0","id":0,"method":"tools/call"}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .request(let id, _, _) = message else {
            return XCTFail("expected .request with id 0, got \(message)")
        }
        XCTAssertEqual(id, .int(0))
    }

    func test_serialize_request_zeroId_roundTripsThroughParse() throws {
        let message = JSONRPCMessage.request(id: .int(0), method: "ping", params: nil)
        let data = try message.serialize()
        let parsed = try JSONRPCMessage.parse(data)
        XCTAssertEqual(parsed, message)
    }

    func test_serialize_response_zeroId_roundTripsThroughParse() throws {
        let message = JSONRPCMessage.response(id: .int(0), result: AnyCodable(["ok": AnyCodable(true)]), error: nil)
        let data = try message.serialize()
        let parsed = try JSONRPCMessage.parse(data)
        XCTAssertEqual(parsed, message)
    }

    // MARK: - Equatable / Sendable

    func test_response_isEquatable() {
        let a = JSONRPCMessage.response(id: .int(1), result: AnyCodable(["ok": AnyCodable(true)]), error: nil)
        let b = JSONRPCMessage.response(id: .int(1), result: AnyCodable(["ok": AnyCodable(true)]), error: nil)
        let c = JSONRPCMessage.response(id: .int(2), result: nil, error: nil)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func test_jsonrpcError_isEquatable() {
        XCTAssertEqual(
            JSONRPCError(code: -32601, message: "Method not found", data: nil),
            JSONRPCError(code: -32601, message: "Method not found", data: nil)
        )
        XCTAssertNotEqual(
            JSONRPCError(code: -32601, message: "Method not found", data: nil),
            JSONRPCError(code: -32602, message: "Invalid params", data: nil)
        )
    }

    func test_jsonrpcMessageAndError_areSendable() async {
        let message = JSONRPCMessage.response(id: .int(1), result: nil, error: JSONRPCError(code: -32601, message: "x", data: nil))
        let task = Task { @Sendable in message }
        _ = await task.value
    }
}
