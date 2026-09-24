//
//  MCPSchemaConformanceTests.swift
//  CalyxTests
//
//  Loads the pinned MCP schema.json fixtures and asserts, for each mirrored
//  wire type, that its non-optional stored properties are exactly a subset
//  of the schema definition's `required` array. This is the mechanical
//  enforcement of "a field the schema does not mark required must not be
//  non-optional in Swift" (see AGENTS.md primary-source integration rule).
//
//  It intentionally does NOT assert the reverse (that every `required`
//  field is non-optional in Swift): a Swift type is allowed to be more
//  defensive than the schema requires.
//

import XCTest
@testable import Calyx

final class MCPSchemaConformanceTests: XCTestCase {

    private enum SchemaVersion: String {
        case v2026 = "2026-07-28"
        case v2025 = "2025-11-25"
    }

    /// Fixtures are loaded from the checked-out source tree, not from the
    /// test bundle's Copy Bundle Resources phase: xcodegen's default
    /// `group`-style folder membership for `sources: [path: CalyxTests]`
    /// does not guarantee nested subdirectories survive as a bundle
    /// subdirectory, so `Bundle(for:).url(forResource:subdirectory:)` is
    /// not a reliable lookup here. `#filePath` of this very test file is
    /// stable relative to `CalyxTests/Fixtures/MCPSchema/...` in the repo.
    ///
    /// Not cached: a `static var` cache would be a shared mutable data race
    /// under Swift 6 strict concurrency for a value that is not `Sendable`.
    /// The fixture files are small; reloading per call is cheap.
    private func loadSchema(_ version: SchemaVersion) throws -> [String: Any] {
        let thisFile = URL(fileURLWithPath: #filePath)
        // #filePath -> .../CalyxTests/MCPHost/Wire/MCPSchemaConformanceTests.swift
        let calyxTestsDir = thisFile
            .deletingLastPathComponent() // Wire/
            .deletingLastPathComponent() // MCPHost/
            .deletingLastPathComponent() // CalyxTests/
        let url = calyxTestsDir
            .appendingPathComponent("Fixtures/MCPSchema/\(version.rawValue)/schema.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Pinned schema fixture missing at \(url.path); this is the single source of truth for wire type shapes and must not be treated as optional")
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// Returns the `required` array (as a Set of field names) for a named
    /// `$defs` entry, or an empty set if the definition declares no
    /// required fields.
    private func requiredFields(_ defName: String, in version: SchemaVersion) throws -> Set<String> {
        let schema = try loadSchema(version)
        guard let defs = schema["$defs"] as? [String: Any],
              let def = defs[defName] as? [String: Any] else {
            XCTFail("$defs.\(defName) not found in \(version.rawValue) schema.json")
            return []
        }
        let required = (def["required"] as? [String]) ?? []
        return Set(required)
    }

    /// Reflects `instance`'s stored properties and returns the subset whose
    /// runtime type is non-Optional.
    private func nonOptionalStoredPropertyNames(of instance: Any) -> Set<String> {
        var names: Set<String> = []
        for child in Mirror(reflecting: instance).children {
            guard let label = child.label else { continue }
            let isOptional = Mirror(reflecting: child.value).displayStyle == .optional
            if !isOptional {
                names.insert(label)
            }
        }
        return names
    }

    private func assertConforms<T>(_ instance: T, defName: String, version: SchemaVersion, file: StaticString = #filePath, line: UInt = #line) throws {
        let required = try requiredFields(defName, in: version)
        let nonOptional = nonOptionalStoredPropertyNames(of: instance)
        XCTAssertTrue(
            nonOptional.isSubset(of: required),
            "\(String(describing: T.self)) declares non-optional properties \(nonOptional.subtracting(required)) that \(defName) (\(version.rawValue)) does not require",
            file: file,
            line: line
        )
    }

    func test_MCPImplementation_conformsToRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(MCPImplementation.self, from: Data(#"{"name":"srv","version":"1.0"}"#.utf8))
        try assertConforms(value, defName: "Implementation", version: .v2026)
    }

    func test_MCPImplementation_conformsToRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(MCPImplementation.self, from: Data(#"{"name":"srv","version":"1.0"}"#.utf8))
        try assertConforms(value, defName: "Implementation", version: .v2025)
    }

    func test_MCPInitializeResult_conformsToRequiredFields() throws {
        let value = try JSONDecoder().decode(
            MCPInitializeResult.self,
            from: Data(#"{"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"s","version":"1"}}"#.utf8)
        )
        try assertConforms(value, defName: "InitializeResult", version: .v2025)
    }

    func test_MCPDiscoverResult_conformsToRequiredFields() throws {
        let value = try JSONDecoder().decode(
            MCPDiscoverResult.self,
            from: Data(#"{"resultType":"complete","supportedVersions":[],"capabilities":{},"cacheScope":"public","ttlMs":0}"#.utf8)
        )
        try assertConforms(value, defName: "DiscoverResult", version: .v2026)
    }

    func test_MCPInputRequiredResult_conformsToRequiredFields() throws {
        let value = try JSONDecoder().decode(
            MCPInputRequiredResult.self,
            from: Data(#"{"resultType":"input_required"}"#.utf8)
        )
        try assertConforms(value, defName: "InputRequiredResult", version: .v2026)
    }

    func test_MCPListRootsResult_conformsToRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(
            MCPListRootsResult.self,
            from: Data(#"{"roots":[]}"#.utf8)
        )
        try assertConforms(value, defName: "ListRootsResult", version: .v2026)
    }

    func test_MCPListRootsResult_conformsToRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(
            MCPListRootsResult.self,
            from: Data(#"{"roots":[]}"#.utf8)
        )
        try assertConforms(value, defName: "ListRootsResult", version: .v2025)
    }

    func test_MCPRoot_conformsToRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(MCPRoot.self, from: Data(#"{"uri":"file:///a"}"#.utf8))
        try assertConforms(value, defName: "Root", version: .v2026)
    }

    func test_MCPRoot_conformsToRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(MCPRoot.self, from: Data(#"{"uri":"file:///a"}"#.utf8))
        try assertConforms(value, defName: "Root", version: .v2025)
    }

    func test_MCPProgressNotificationParams_conformsToRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(
            MCPProgressNotificationParams.self,
            from: Data(#"{"progress":1,"progressToken":1}"#.utf8)
        )
        try assertConforms(value, defName: "ProgressNotificationParams", version: .v2026)
    }

    func test_MCPProgressNotificationParams_conformsToRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(
            MCPProgressNotificationParams.self,
            from: Data(#"{"progress":1,"progressToken":1}"#.utf8)
        )
        try assertConforms(value, defName: "ProgressNotificationParams", version: .v2025)
    }

    // MARK: - Elicitation: `mode` is required by the URL variant only, so
    // the shared Swift type (which serves both the form and the URL arm of
    // the `ElicitRequestParams` anyOf) must not declare it non-optional.

    func test_MCPElicitRequestParams_conformsToElicitRequestFormParamsRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(
            MCPElicitRequestParams.self,
            from: Data(#"{"message":"m","requestedSchema":{"type":"object"}}"#.utf8)
        )
        try assertConforms(value, defName: "ElicitRequestFormParams", version: .v2026)
    }

    func test_MCPElicitRequestParams_conformsToElicitRequestFormParamsRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(
            MCPElicitRequestParams.self,
            from: Data(#"{"message":"m","requestedSchema":{"type":"object"}}"#.utf8)
        )
        try assertConforms(value, defName: "ElicitRequestFormParams", version: .v2025)
    }

    func test_MCPElicitRequestParams_conformsToElicitRequestURLParamsRequiredFields_v2026() throws {
        // ElicitRequestURLParams (2026-07-28) requires [message, mode, url];
        // this fixture supplies exactly those three, decoded through the
        // same shared Swift type used for the form arm.
        let value = try JSONDecoder().decode(
            MCPElicitRequestParams.self,
            from: Data(#"{"mode":"url","message":"m","url":"https://example.com"}"#.utf8)
        )
        try assertConforms(value, defName: "ElicitRequestURLParams", version: .v2026)
        XCTAssertEqual(value.mode, "url")
        XCTAssertEqual(value.message, "m")
        XCTAssertEqual(value.url, "https://example.com")
    }

    func test_MCPElicitRequestParams_conformsToElicitRequestURLParamsRequiredFields_v2025() throws {
        // ElicitRequestURLParams (2025-11-25) additionally requires
        // `elicitationId`; the shared Swift type keeps it optional (it does
        // not exist as a field in the 2026-07-28 URL variant), so this
        // fixture only asserts the decode succeeds and the fields present
        // are readable, not that the type declares elicitationId non-optional.
        let value = try JSONDecoder().decode(
            MCPElicitRequestParams.self,
            from: Data(#"{"mode":"url","message":"m","url":"https://example.com","elicitationId":"e1"}"#.utf8)
        )
        XCTAssertEqual(value.mode, "url")
        XCTAssertEqual(value.message, "m")
        XCTAssertEqual(value.url, "https://example.com")
        XCTAssertEqual(value.elicitationId, "e1")
    }

    func test_MCPElicitResult_conformsToRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(MCPElicitResult.self, from: Data(#"{"action":"decline"}"#.utf8))
        try assertConforms(value, defName: "ElicitResult", version: .v2026)
    }

    func test_MCPElicitResult_conformsToRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(MCPElicitResult.self, from: Data(#"{"action":"decline"}"#.utf8))
        try assertConforms(value, defName: "ElicitResult", version: .v2025)
    }

    func test_MCPCancelledNotificationParams_conformsToRequiredFields() throws {
        // requestId is required in the 2026-07-28 schema but the 2025-11-25
        // schema requires nothing at all -- the shared type must satisfy
        // the stricter (2026) required set to stay conservative, so it is
        // asserted against 2026-07-28; requestId stays optional in
        // Swift regardless (see MCPWireTypesDecodeTests_CancelledNotification).
        let value = try JSONDecoder().decode(
            MCPCancelledNotificationParams.self,
            from: Data(#"{"requestId":1}"#.utf8)
        )
        try assertConforms(value, defName: "CancelledNotificationParams", version: .v2026)
        XCTAssertEqual(value.requestId, .int(1))
    }

    func test_MCPCancelledNotificationParams_conformsToRequiredFields_v2025() throws {
        // The 2025-11-25 schema requires nothing, so an empty payload must
        // also decode and conform.
        let value = try JSONDecoder().decode(
            MCPCancelledNotificationParams.self,
            from: Data("{}".utf8)
        )
        try assertConforms(value, defName: "CancelledNotificationParams", version: .v2025)
    }

    func test_MCPClientCapabilities_conformsToRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(MCPClientCapabilities.self, from: Data("{}".utf8))
        try assertConforms(value, defName: "ClientCapabilities", version: .v2026)
    }

    func test_MCPClientCapabilities_conformsToRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(MCPClientCapabilities.self, from: Data("{}".utf8))
        try assertConforms(value, defName: "ClientCapabilities", version: .v2025)
    }

    func test_MCPServerCapabilities_conformsToRequiredFields_v2026() throws {
        let value = try JSONDecoder().decode(MCPServerCapabilities.self, from: Data("{}".utf8))
        try assertConforms(value, defName: "ServerCapabilities", version: .v2026)
    }

    func test_MCPServerCapabilities_conformsToRequiredFields_v2025() throws {
        let value = try JSONDecoder().decode(MCPServerCapabilities.self, from: Data("{}".utf8))
        try assertConforms(value, defName: "ServerCapabilities", version: .v2025)
    }
}
