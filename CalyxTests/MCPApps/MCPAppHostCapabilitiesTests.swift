//
//  MCPAppHostCapabilitiesTests.swift
//  CalyxTests
//
//  Version negotiation and the declared hostCapabilities record for
//  ui/initialize (plan §9 table, row 1, and §10's "取り除けない制約" #1: no
//  sampling because Calyx has no model). Calyx never rejects an
//  initialize: it echoes "2026-01-26" back when that's what the view
//  asked for, and otherwise still returns "2026-01-26" (never an error).
//
//  The wire shape is pinned against ext-apps v2.0.0 spec.types.ts
//  (McpUiHostCapabilities): `sandbox.permissions` is an object keyed by
//  permission name (`{clipboardWrite: {}}`, NOT an array of strings),
//  `sandbox.csp` mirrors McpUiResourceCsp's four domain-array fields, and
//  `message` / `updateModelContext` are McpUiSupportedContentBlockModalities
//  objects (`{text?: {}, image?: {}, audio?: {}, resource?: {}, ...}`).
//  Calyx advertises exactly `text` and `image` for both (plan §9's
//  ui/message row names only text and file-written images; whether Calyx
//  should also advertise audio/resource/resourceLink/structuredContent
//  modalities is not stated by the plan and is left for a decision, see
//  the test-writer handoff report).
//

import XCTest
@testable import Calyx

final class MCPAppHostCapabilitiesTests: XCTestCase {

    // MARK: - Version negotiation

    func test_negotiateVersion_matchingRequestedVersion_isEchoed() {
        XCTAssertEqual(MCPAppHostCapabilities.negotiateVersion(requested: "2026-01-26"), "2026-01-26")
    }

    func test_negotiateVersion_unknownOrOlderVersion_stillReturnsCurrentVersion_neverRejects() {
        XCTAssertEqual(MCPAppHostCapabilities.negotiateVersion(requested: "2024-01-01"), "2026-01-26")
        XCTAssertEqual(MCPAppHostCapabilities.negotiateVersion(requested: "not-a-version"), "2026-01-26")
        XCTAssertEqual(MCPAppHostCapabilities.negotiateVersion(requested: ""), "2026-01-26")
    }

    // MARK: - Declared capability shape (wire JSON, spec-shaped)

    private let emptyCSP = MCPAppCSPBuilder.CSPDomains(
        resourceDomains: [], connectDomains: [], frameDomains: [], baseUriDomains: []
    )

    func test_capabilities_openLinksAndDownloadFile_arePresentAsEmptyObjects() {
        let caps = MCPAppHostCapabilities.build(appliedCSP: emptyCSP)

        XCTAssertNotNil(caps["openLinks"]?.objectValue)
        XCTAssertNotNil(caps["downloadFile"]?.objectValue)
    }

    func test_capabilities_serverToolsAndServerResources_declareListChangedTrue() {
        let caps = MCPAppHostCapabilities.build(appliedCSP: emptyCSP)

        XCTAssertEqual(caps["serverTools"]?["listChanged"]?.boolValue, true)
        XCTAssertEqual(caps["serverResources"]?["listChanged"]?.boolValue, true)
    }

    func test_capabilities_logging_isPresentAsEmptyObject() {
        let caps = MCPAppHostCapabilities.build(appliedCSP: emptyCSP)

        XCTAssertNotNil(caps["logging"]?.objectValue)
    }

    func test_capabilities_updateModelContextAndMessage_advertiseTextAndImageModalities() {
        let caps = MCPAppHostCapabilities.build(appliedCSP: emptyCSP)

        for key in ["updateModelContext", "message"] {
            let modalities = caps[key]?.objectValue
            XCTAssertNotNil(modalities?["text"]?.objectValue, "\(key).text must be an empty object")
            XCTAssertNotNil(modalities?["image"]?.objectValue, "\(key).image must be an empty object")
        }
    }

    func test_capabilities_samplingIsNeverDeclared() {
        let caps = MCPAppHostCapabilities.build(appliedCSP: emptyCSP)

        XCTAssertNil(caps["sampling"], "Calyx has no model -- sampling must never appear in hostCapabilities")
    }

    func test_capabilities_sandboxPermissions_onlyClipboardWriteGranted_asObjectNotArray() {
        let caps = MCPAppHostCapabilities.build(appliedCSP: emptyCSP)
        let permissions = caps["sandbox"]?["permissions"]?.objectValue

        XCTAssertNotNil(permissions?["clipboardWrite"]?.objectValue)
        XCTAssertNil(permissions?["camera"])
        XCTAssertNil(permissions?["microphone"])
        XCTAssertNil(permissions?["geolocation"])
        XCTAssertEqual(permissions?.count, 1)
    }

    func test_capabilities_sandboxCSP_reflectsAppliedDomainsPerField() {
        let applied = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["https://cdn.example.com"],
            connectDomains: ["https://api.example.com"],
            frameDomains: ["https://player.example.com"],
            baseUriDomains: ["https://example.com"]
        )
        let caps = MCPAppHostCapabilities.build(appliedCSP: applied)
        let csp = caps["sandbox"]?["csp"]

        XCTAssertEqual(csp?["resourceDomains"]?.arrayValue?.compactMap(\.stringValue), ["https://cdn.example.com"])
        XCTAssertEqual(csp?["connectDomains"]?.arrayValue?.compactMap(\.stringValue), ["https://api.example.com"])
        XCTAssertEqual(csp?["frameDomains"]?.arrayValue?.compactMap(\.stringValue), ["https://player.example.com"])
        XCTAssertEqual(csp?["baseUriDomains"]?.arrayValue?.compactMap(\.stringValue), ["https://example.com"])
    }
}
