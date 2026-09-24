//
//  MCPAppBridgeMessageTests.swift
//  CalyxTests
//
//  The view bridge has no dedicated JSON-RPC parser (contract v2 §11.13,
//  §16 deviation 4): it dispatches through Wire's JSONRPCMessage.parse,
//  the same parser used by the transport layer. A 16 MiB message cap and
//  per-method param validation (-32602) are the bridge's own concerns.
//
//  Pre-initialized requests from the view (including ui/initialize and
//  ping) are never rejected -- the spec's MUST NOT applies only to
//  host -> view sends, not view -> host (§16 deviation 4, §11.20 item 7).
//  This reverses an earlier draft's -32000 pre-init gate.
//

import XCTest
@testable import Calyx

final class MCPAppBridgeMessageTests: XCTestCase {

    // MARK: - JSONRPCMessage.parse is the only parser (Wire, shared with transport)

    func test_validRequest_withStringID_parsesAsRequest() throws {
        let json = #"{"jsonrpc":"2.0","id":"req-1","method":"ui/open-link","params":{"url":"https://example.com"}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .request(let id, let method, _) = message else { return XCTFail("expected .request, got \(message)") }
        XCTAssertEqual(id, .string("req-1"))
        XCTAssertEqual(method, "ui/open-link")
    }

    func test_validRequest_withNumericID_roundTripsAsJSONNumber_notString() throws {
        // The ext-apps SDK's App/AppBridge request ids are plain incrementing
        // JS numbers, so the bridge must round-trip a JSON number, not
        // coerce it to a string.
        let json = #"{"jsonrpc":"2.0","id":7,"method":"ui/open-link","params":{"url":"https://example.com"}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .request(let id, _, _) = message else { return XCTFail("expected .request, got \(message)") }
        XCTAssertEqual(id, .int(7))
    }

    func test_idZero_isValid_notTreatedAsMissing() throws {
        // 0 is a valid JSON-RPC id (Wire §1.3, revised decision); it must
        // not be treated as an absent id.
        let json = #"{"jsonrpc":"2.0","id":0,"method":"ping"}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .request(let id, _, _) = message else { return XCTFail("expected .request, got \(message)") }
        XCTAssertEqual(id, .int(0))
    }

    func test_validNotification_noID_parsesAsNotification() throws {
        let json = #"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":320}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .notification(let method, _) = message else { return XCTFail("expected .notification, got \(message)") }
        XCTAssertEqual(method, "ui/notifications/size-changed")
    }

    func test_validResponse_parsesAsResponse() throws {
        let json = #"{"jsonrpc":"2.0","id":"req-1","result":{"ok":true}}"#
        let message = try JSONRPCMessage.parse(Data(json.utf8))
        guard case .response(let id, _, let error) = message else { return XCTFail("expected .response, got \(message)") }
        XCTAssertEqual(id, .string("req-1"))
        XCTAssertNil(error)
    }

    func test_malformedJSON_throws() {
        XCTAssertThrowsError(try JSONRPCMessage.parse(Data("{not json".utf8)))
    }

    // MARK: - 16 MiB message cap (bridge-level)

    func test_maxMessageBytes_is16MiB() {
        XCTAssertEqual(MCPAppBridgeDispatch.maxMessageBytes, 16 * 1024 * 1024)
    }

    // MARK: - Pre-initialized requests from the view are never rejected

    func test_uiInitialize_beforeInitialized_isNotRejected() {
        XCTAssertNil(MCPAppBridgeDispatch.validate(initialized: false, method: "ui/initialize"))
    }

    func test_ping_beforeInitialized_isNotRejected() {
        XCTAssertNil(MCPAppBridgeDispatch.validate(initialized: false, method: "ping"))
    }

    func test_anyOtherViewRequest_beforeInitialized_isNotRejected() {
        // Contract v2 §16 deviation 4: the spec's MUST NOT constrains
        // host -> view sends only; the host never rejects a view -> host
        // request for being early.
        XCTAssertNil(MCPAppBridgeDispatch.validate(initialized: false, method: "ui/open-link"))
        XCTAssertNil(MCPAppBridgeDispatch.validate(initialized: false, method: "ui/message"))
    }

    func test_requestAfterInitialized_isAllowed() {
        XCTAssertNil(MCPAppBridgeDispatch.validate(initialized: true, method: "ui/open-link"))
    }

    // MARK: - errorForUnknownMethod: JSONRPCMessage.response, id echoed verbatim

    func test_errorForUnknownMethod_stringID_producesMinus32601Response() {
        let response = MCPAppBridgeDispatch.errorForUnknownMethod(id: .string("req-1"))
        guard case .response(let id, let result, let error) = response else {
            return XCTFail("expected .response, got \(response)")
        }
        XCTAssertEqual(id, .string("req-1"))
        XCTAssertNil(result)
        XCTAssertEqual(error?.code, -32601)
    }

    func test_errorForUnknownMethod_numericIDZero_echoesAsJSONNumberZero() {
        // Regression: 0 must not be dropped as if absent.
        let response = MCPAppBridgeDispatch.errorForUnknownMethod(id: .int(0))
        guard case .response(let id, _, _) = response else {
            return XCTFail("expected .response, got \(response)")
        }
        XCTAssertEqual(id, .int(0))
    }

    // MARK: - Per-method param validation -> -32602

    func test_uiMessage_missingRole_isMinus32602() {
        let params = AnyCodable(["content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("hi")])])])
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/message", params: params)
        XCTAssertEqual(error?.code, -32602)
    }

    func test_uiMessage_missingContent_isMinus32602() {
        let params = AnyCodable(["role": AnyCodable("user")])
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/message", params: params)
        XCTAssertEqual(error?.code, -32602)
    }

    func test_uiMessage_roleAndContentPresent_isValid() {
        let params = AnyCodable([
            "role": AnyCodable("user"),
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("hi")])]),
        ])
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/message", params: params)
        XCTAssertNil(error)
    }

    func test_uiOpenLink_missingURL_isMinus32602() {
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/open-link", params: AnyCodable([String: AnyCodable]()))
        XCTAssertEqual(error?.code, -32602)
    }

    func test_uiOpenLink_withURL_isValid() {
        let params = AnyCodable(["url": AnyCodable("https://example.com")])
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/open-link", params: params)
        XCTAssertNil(error)
    }

    func test_uiRequestDisplayMode_missingMode_isMinus32602() {
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/request-display-mode", params: AnyCodable([String: AnyCodable]()))
        XCTAssertEqual(error?.code, -32602)
    }

    func test_uiRequestDisplayMode_withMode_isValid() {
        let params = AnyCodable(["mode": AnyCodable("fullscreen")])
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/request-display-mode", params: params)
        XCTAssertNil(error)
    }

    func test_uiDownloadFile_missingContents_isMinus32602() {
        // McpUiDownloadFileRequest.params (spec.types.ts v2.0.0) is
        // `{contents: (EmbeddedResource | ResourceLink)[]}`, not a bespoke
        // `files` key.
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/download-file", params: AnyCodable([String: AnyCodable]()))
        XCTAssertEqual(error?.code, -32602)
    }

    func test_uiDownloadFile_withContents_isValid() {
        let params = AnyCodable(["contents": AnyCodable([AnyCodable([
            "uri": AnyCodable("file:///a.txt"),
            "mimeType": AnyCodable("text/plain"),
            "text": AnyCodable("hello"),
        ])])])
        let error = MCPAppBridgeDispatch.validateParams(method: "ui/download-file", params: params)
        XCTAssertNil(error)
    }

    func test_methodWithNoDeclaredParamValidation_returnsNil() {
        // ping and other zero-param methods have no per-method validation.
        XCTAssertNil(MCPAppBridgeDispatch.validateParams(method: "ping", params: nil))
    }
}
