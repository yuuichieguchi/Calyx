//
//  MCPToolDefinitionTests.swift
//  CalyxTests
//
//  Coverage: `MCPToolDefinition(raw:)` -- UI metadata extraction (nested
//  `_meta.ui` form preferred over the deprecated flat `_meta["ui/resourceUri"]`
//  fallback), visibility defaulting, non-`ui://` URI handling, and
//  `execution.taskSupport` pass-through via `raw`.
//
//  Rules exercised here:
//    - `visibility` is parsed from `_meta.ui.visibility` INDEPENDENTLY of
//      whether a `resourceUri` is present at all -- an app-only tool with
//      no `resourceUri` (e.g. the E2E fixture's `record_event`) still
//      carries `visibility == [.app]` so the catalog can exclude it from
//      the agent's tool list per the MCP Apps spec's host MUST.
//    - `ui: MCPToolUIMeta?` is non-nil whenever ANY `resourceUri` is
//      declared (nested or the deprecated flat form), even a non-`ui://`
//      one -- the plan (§12) requires rendering an error card naming the
//      invalid scheme, which needs the declared URI preserved, not
//      discarded into `nil`. Only a wholly ABSENT declaration (no
//      `_meta.ui` key and no flat fallback key) makes `ui` nil.
//

import XCTest
@testable import Calyx

final class MCPToolDefinitionTests: XCTestCase {

    private func rawTool(_ meta: [String: AnyCodable]? = nil, extra: [String: AnyCodable] = [:]) -> [String: AnyCodable] {
        var dict: [String: AnyCodable] = [
            "name": AnyCodable("get_weather"),
            "description": AnyCodable("Fetch the weather"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
        ]
        if let meta {
            dict["_meta"] = AnyCodable(meta)
        }
        for (k, v) in extra { dict[k] = v }
        return dict
    }

    // MARK: - Basic construction

    func test_init_extractsNameAndTitle() throws {
        var raw = rawTool()
        raw["title"] = AnyCodable("Get Weather")
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.name, "get_weather")
        XCTAssertEqual(tool.title, "Get Weather")
    }

    func test_init_titleAbsent_isNil() throws {
        let tool = try MCPToolDefinition(raw: rawTool())
        XCTAssertNil(tool.title)
    }

    func test_init_throwsWhenNameMissing() {
        let raw: [String: AnyCodable] = ["description": AnyCodable("no name")]
        XCTAssertThrowsError(try MCPToolDefinition(raw: raw))
    }

    func test_init_doesNotThrowWhenInputSchemaMissing() throws {
        // The contract limits the throw condition to a missing `name`; a
        // missing `inputSchema` (also in Tool.required per the schema) must
        // not throw, and headerMirrors, which is derived from
        // inputSchema.properties, must simply be empty.
        let raw: [String: AnyCodable] = ["name": AnyCodable("no_input_schema")]
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.name, "no_input_schema")
        XCTAssertTrue(tool.headerMirrors.isEmpty)
    }

    func test_init_preservesRawVerbatim() throws {
        let raw = rawTool()
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.raw, raw)
    }

    // MARK: - visibility: default and independent of resourceUri presence

    func test_visibility_defaultsToModelAndApp_whenNoMetaPresent() throws {
        let tool = try MCPToolDefinition(raw: rawTool())
        XCTAssertEqual(tool.visibility, [.model, .app])
    }

    func test_visibility_appOnly_withNoResourceUriDeclaredAtAll() throws {
        // Mirrors the E2E fixture's `record_event`: app-only visibility,
        // no `resourceUri` anywhere. Must still be excludable from the
        // agent's tool list -- and must NOT synthesize a `ui` value.
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable(["visibility": AnyCodable([AnyCodable("app")])]),
        ]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        XCTAssertEqual(tool.visibility, [.app])
        XCTAssertNil(tool.ui, "no resourceUri was declared, so ui stays nil even though visibility was read from the same _meta.ui object")
    }

    func test_visibility_modelOnly_withNoResourceUriDeclaredAtAll() throws {
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable(["visibility": AnyCodable([AnyCodable("model")])]),
        ]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        XCTAssertEqual(tool.visibility, [.model])
        XCTAssertNil(tool.ui)
    }

    func test_visibility_explicitOverride_withResourceUriAlsoPresent() throws {
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable([
                "resourceUri": AnyCodable("ui://weather/widget.html"),
                "visibility": AnyCodable([AnyCodable("app")]),
            ]),
        ]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        XCTAssertEqual(tool.visibility, [.app])
    }

    // MARK: - ui: nested form (preferred)

    func test_ui_nestedForm_parsesDeclaredResourceURIAndUIScheme() throws {
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable(["resourceUri": AnyCodable("ui://weather/widget.html")]),
        ]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        XCTAssertEqual(tool.ui?.declaredResourceURI, "ui://weather/widget.html")
        XCTAssertEqual(tool.ui?.isUIScheme, true)
        XCTAssertEqual(tool.visibility, [.model, .app], "default visibility applies even when a resourceUri is present")
    }

    func test_ui_nestedFormTakesPrecedenceOverFlatFallback() throws {
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable(["resourceUri": AnyCodable("ui://nested/widget.html")]),
            "ui/resourceUri": AnyCodable("ui://flat/widget.html"),
        ]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        XCTAssertEqual(tool.ui?.declaredResourceURI, "ui://nested/widget.html")
    }

    // MARK: - ui: deprecated flat fallback

    func test_ui_flatFallback_usedWhenNestedFormAbsent() throws {
        let meta: [String: AnyCodable] = [
            "ui/resourceUri": AnyCodable("ui://weather/widget.html"),
        ]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        XCTAssertEqual(tool.ui?.declaredResourceURI, "ui://weather/widget.html")
        XCTAssertEqual(tool.ui?.isUIScheme, true)
        XCTAssertEqual(tool.visibility, [.model, .app])
    }

    // MARK: - ui: absence and invalid scheme

    func test_ui_absentWhenNoMetaPresent() throws {
        let tool = try MCPToolDefinition(raw: rawTool())
        XCTAssertNil(tool.ui)
    }

    func test_ui_absentWhenMetaPresentButNoUIKey() throws {
        let meta: [String: AnyCodable] = ["other": AnyCodable("value")]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        XCTAssertNil(tool.ui)
    }

    func test_ui_nonUISchemeURI_isStillDeclared_butIsUISchemeFalse() throws {
        let meta: [String: AnyCodable] = [
            "ui": AnyCodable(["resourceUri": AnyCodable("https://not-a-ui-scheme.example/widget.html")]),
        ]
        let tool = try MCPToolDefinition(raw: rawTool(meta))
        let ui = try XCTUnwrap(tool.ui, "a declared (even invalid) resourceUri must produce a non-nil MCPToolUIMeta so the plan §12 error card can name the scheme")
        XCTAssertEqual(ui.declaredResourceURI, "https://not-a-ui-scheme.example/widget.html")
        XCTAssertFalse(ui.isUIScheme)
        XCTAssertEqual(tool.name, "get_weather", "the rest of the tool definition remains usable")
    }

    // MARK: - execution.taskSupport pass-through

    func test_rawPreservesExecutionTaskSupportForDownstreamFiltering() throws {
        let raw = rawTool(nil, extra: [
            "execution": AnyCodable(["taskSupport": AnyCodable("required")]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.raw["execution"]?["taskSupport"]?.stringValue, "required")
    }

    func test_rawPreservesExecutionTaskSupportForbidden() throws {
        let raw = rawTool(nil, extra: [
            "execution": AnyCodable(["taskSupport": AnyCodable("forbidden")]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.raw["execution"]?["taskSupport"]?.stringValue, "forbidden")
    }

    // MARK: - raw preserves _meta and unknown keys verbatim

    func test_rawPreservesMetaAndUnknownKeysVerbatim() throws {
        let raw = rawTool(
            ["ui": AnyCodable(["resourceUri": AnyCodable("ui://weather/widget.html")])],
            extra: ["futureField": AnyCodable("unknown-value")]
        )
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.raw["_meta"]?["ui"]?["resourceUri"]?.stringValue, "ui://weather/widget.html")
        XCTAssertEqual(tool.raw["futureField"]?.stringValue, "unknown-value")
    }

    // MARK: - headerMirrors: derived from properties reachable only through
    // a chain of `properties` keys (nested object properties included),
    // per the Streamable HTTP 2026-07-28 primary source.

    func test_headerMirrors_extractsTopLevelPropertyWithXMcpHeader() throws {
        let raw = rawTool(nil, extra: [
            "inputSchema": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "region": AnyCodable([
                        "type": AnyCodable("string"),
                        "x-mcp-header": AnyCodable("Region"),
                    ]),
                ]),
            ]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.headerMirrors.count, 1)
        XCTAssertEqual(tool.headerMirrors.first?.headerName, "Region")
        XCTAssertEqual(tool.headerMirrors.first?.propertyPath, ["region"])
    }

    func test_headerMirrors_ignoresPropertiesWithoutXMcpHeader() throws {
        let raw = rawTool(nil, extra: [
            "inputSchema": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "count": AnyCodable(["type": AnyCodable("integer")]),
                ]),
            ]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertTrue(tool.headerMirrors.isEmpty)
    }

    func test_headerMirrors_extractsNestedPropertyReachableThroughPropertiesChain() throws {
        // A property whose own schema is an object with a nested
        // `properties` map is reachable purely through a chain of
        // `properties` keys, so a `x-mcp-header` on the inner property
        // counts, and `propertyPath` carries the full key path.
        let raw = rawTool(nil, extra: [
            "inputSchema": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "options": AnyCodable([
                        "type": AnyCodable("object"),
                        "properties": AnyCodable([
                            "region": AnyCodable([
                                "type": AnyCodable("string"),
                                "x-mcp-header": AnyCodable("Region"),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertEqual(tool.headerMirrors.count, 1)
        XCTAssertEqual(tool.headerMirrors.first?.headerName, "Region")
        XCTAssertEqual(tool.headerMirrors.first?.propertyPath, ["options", "region"])
    }

    func test_headerMirrors_ignoresXMcpHeaderNestedInsideItems() throws {
        // `items`-mediated x-mcp-header declarations are out of scope:
        // `items` is not a `properties` chain hop.
        let raw = rawTool(nil, extra: [
            "inputSchema": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "tags": AnyCodable([
                        "type": AnyCodable("array"),
                        "items": AnyCodable(["x-mcp-header": AnyCodable("ShouldBeIgnored")]),
                    ]),
                ]),
            ]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertTrue(tool.headerMirrors.isEmpty)
    }

    func test_headerMirrors_ignoresXMcpHeaderNestedInsideOneOf() throws {
        // `oneOf`-mediated x-mcp-header declarations are out of scope:
        // `oneOf` is not a `properties` chain hop either.
        let raw = rawTool(nil, extra: [
            "inputSchema": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "target": AnyCodable([
                        "oneOf": AnyCodable([
                            AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("ShouldBeIgnored")]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertTrue(tool.headerMirrors.isEmpty)
    }

    func test_headerMirrors_ignoresNonStringXMcpHeaderValue() throws {
        let raw = rawTool(nil, extra: [
            "inputSchema": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "region": AnyCodable([
                        "type": AnyCodable("string"),
                        "x-mcp-header": AnyCodable(1),
                    ]),
                ]),
            ]),
        ])
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertTrue(tool.headerMirrors.isEmpty)
    }

    func test_headerMirrors_emptyWhenInputSchemaHasNoProperties() throws {
        let raw = rawTool()
        let tool = try MCPToolDefinition(raw: raw)
        XCTAssertTrue(tool.headerMirrors.isEmpty)
    }
}
