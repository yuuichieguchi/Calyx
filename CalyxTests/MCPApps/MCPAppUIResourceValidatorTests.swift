//
//  MCPAppUIResourceValidatorTests.swift
//  CalyxTests
//
//  Pure validation of a resources/read response against the MCP Apps
//  spec's Content Requirements (apps.mdx, stable 2026-01-26): exactly
//  one content item, mimeType "text/html;profile=mcp-app" with parameter
//  case/whitespace-insensitive matching and an optional charset, text OR
//  base64 blob, a 10 MiB cap, and a `ui://` URI. `_meta.ui` is read from
//  the content item first, falling back to the resources/list entry.
//  Each failure kind must be independently distinguishable so the error
//  card can report a specific reason.
//

import XCTest
@testable import Calyx

final class MCPAppUIResourceValidatorTests: XCTestCase {

    private func content(
        uri: String = "ui://server/view",
        mimeType: String? = "text/html;profile=mcp-app",
        text: String? = "<!DOCTYPE html><html></html>",
        blob: String? = nil,
        meta: AnyCodable? = nil
    ) -> AnyCodable {
        var dict: [String: AnyCodable] = ["uri": AnyCodable(uri)]
        if let mimeType { dict["mimeType"] = AnyCodable(mimeType) }
        if let text { dict["text"] = AnyCodable(text) }
        if let blob { dict["blob"] = AnyCodable(blob) }
        if let meta { dict["_meta"] = meta }
        return AnyCodable(dict)
    }

    // MARK: - Exactly one content item

    func test_zeroContentItems_isRejected() {
        let result = MCPAppUIResourceValidator.validate(contents: [], listEntryMeta: nil)
        guard case .failure(.contentCount(0)) = result else {
            return XCTFail("expected .contentCount(0), got \(result)")
        }
    }

    func test_twoContentItems_isRejected() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(), content()], listEntryMeta: nil)
        guard case .failure(.contentCount(2)) = result else {
            return XCTFail("expected .contentCount(2), got \(result)")
        }
    }

    func test_oneContentItem_validHTML_succeeds() {
        let result = MCPAppUIResourceValidator.validate(contents: [content()], listEntryMeta: nil)
        guard case .success(let resolved) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(resolved.uri, "ui://server/view")
        XCTAssertEqual(resolved.html, "<!DOCTYPE html><html></html>")
    }

    // MARK: - mimeType matching (case/whitespace-insensitive, charset allowed)

    func test_mimeType_differentCase_isAccepted() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(mimeType: "TEXT/HTML;PROFILE=mcp-app")], listEntryMeta: nil)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    func test_mimeType_extraWhitespace_isAccepted() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(mimeType: "text/html; profile=mcp-app")], listEntryMeta: nil)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    func test_mimeType_withCharsetParameter_isAccepted() {
        let result = MCPAppUIResourceValidator.validate(
            contents: [content(mimeType: "text/html;profile=mcp-app;charset=utf-8")], listEntryMeta: nil
        )
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    func test_mimeType_wrongType_isRejected() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(mimeType: "text/plain")], listEntryMeta: nil)
        guard case .failure(.mimeType("text/plain")) = result else {
            return XCTFail("expected .mimeType(\"text/plain\"), got \(result)")
        }
    }

    // MARK: - text or base64 blob

    func test_base64Blob_valid_decodesToHTML() {
        let html = "<!DOCTYPE html><html><body>hi</body></html>"
        let encoded = Data(html.utf8).base64EncodedString()
        let result = MCPAppUIResourceValidator.validate(contents: [content(text: nil, blob: encoded)], listEntryMeta: nil)
        guard case .success(let resolved) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(resolved.html, html)
    }

    func test_base64Blob_invalid_isRejected() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(text: nil, blob: "not valid base64!!")], listEntryMeta: nil)
        guard case .failure(.invalidBase64) = result else {
            return XCTFail("expected .invalidBase64, got \(result)")
        }
    }

    func test_neitherTextNorBlob_isRejected() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(text: nil, blob: nil)], listEntryMeta: nil)
        guard case .failure(.missingTextAndBlob) = result else {
            return XCTFail("expected .missingTextAndBlob, got \(result)")
        }
    }

    // MARK: - 10 MiB limit

    func test_contentUnder10MiB_isAccepted() {
        let html = "<!DOCTYPE html>" + String(repeating: "x", count: 1024)
        let result = MCPAppUIResourceValidator.validate(contents: [content(text: html)], listEntryMeta: nil)
        guard case .success = result else { return XCTFail("expected success, got \(result)") }
    }

    func test_contentOver10MiB_isRejected() {
        let oversized = String(repeating: "x", count: 10 * 1024 * 1024 + 1)
        let result = MCPAppUIResourceValidator.validate(contents: [content(text: oversized)], listEntryMeta: nil)
        guard case .failure(.tooLarge) = result else {
            return XCTFail("expected .tooLarge, got \(result)")
        }
    }

    // MARK: - ui:// required

    func test_uriWithoutUIScheme_isRejected() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(uri: "https://server/view")], listEntryMeta: nil)
        guard case .failure(.invalidURIScheme("https://server/view")) = result else {
            return XCTFail("expected .invalidURIScheme, got \(result)")
        }
    }

    // MARK: - _meta.ui precedence: content item first, list entry fallback

    func test_metaUI_readFromContentItem_whenPresent() {
        let contentMeta = AnyCodable(["ui": AnyCodable(["domain": AnyCodable("content-domain.example")])])
        let listMeta = AnyCodable(["ui": AnyCodable(["domain": AnyCodable("list-domain.example")])])

        let result = MCPAppUIResourceValidator.validate(contents: [content(meta: contentMeta)], listEntryMeta: listMeta)
        guard case .success(let resolved) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(resolved.meta?.domain, "content-domain.example")
    }

    func test_metaUI_fallsBackToListEntry_whenContentItemHasNone() {
        let listMeta = AnyCodable(["ui": AnyCodable(["domain": AnyCodable("list-domain.example")])])

        let result = MCPAppUIResourceValidator.validate(contents: [content(meta: nil)], listEntryMeta: listMeta)
        guard case .success(let resolved) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertEqual(resolved.meta?.domain, "list-domain.example")
    }

    func test_metaUI_absentEverywhere_isNilNotAnError() {
        let result = MCPAppUIResourceValidator.validate(contents: [content(meta: nil)], listEntryMeta: nil)
        guard case .success(let resolved) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertNil(resolved.meta)
    }

    func test_metaUI_explicitNull_isTreatedAsAbsent() {
        let nullMeta = AnyCodable(["ui": AnyCodable.null])
        let result = MCPAppUIResourceValidator.validate(contents: [content(meta: nullMeta)], listEntryMeta: nil)
        guard case .success(let resolved) = result else { return XCTFail("expected success, got \(result)") }
        XCTAssertNil(resolved.meta)
    }
}
