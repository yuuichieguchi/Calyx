//
//  MCPXMCPHeaderValidationTests.swift
//  CalyxTests
//
//  Coverage: full `x-mcp-header` validation per MCP 2026-07-28
//  Streamable HTTP's "Schema Extension" section (fetched read-only from
//  https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http.md
//  and quoted verbatim below, not reconstructed from memory):
//
//    "Constraints on x-mcp-header values:
//     - MUST NOT be empty
//     - MUST match HTTP field-name token syntax (1*tchar, RFC 9110
//       Section 5.1)
//     - MUST NOT contain control characters, including carriage return
//       (CR, \r) or line feed (LF, \n)
//     - MUST be case-insensitively unique among all x-mcp-header values
//       in the inputSchema
//     - MUST only be applied to parameters with primitive types
//       (integer, string, boolean). Parameters with type number are not
//       permitted. Integer values MUST be within the safe range for
//       JavaScript (-2^53+1 to 2^53-1)
//     - MUST only be applied to properties that are statically
//       reachable from the schema root: reachable via a chain
//       consisting solely of properties keys. The chain MUST NOT pass
//       through items (or any other array keyword), composition
//       keywords (oneOf, anyOf, allOf, not), conditional keywords
//       (if/then/else), or $ref. Nested object properties are permitted
//       as long as every step in the chain is a properties key. An
//       x-mcp-header annotation anywhere else makes the annotation --
//       and thus the tool definition -- invalid."
//
//    "Clients using the Streamable HTTP transport MUST reject tool
//     definitions where any x-mcp-header value violates these
//     constraints. Rejection means the client MUST exclude the invalid
//     tool from the result of tools/list."
//
//  RFC 9110 5.1's `tchar` (referenced, not independently fetched --
//  quoted by streamable-http.md's own text as "1*tchar"; RFC 9110's own
//  grammar, well-known and stable, is: `tchar = "!" / "#" / "$" / "%" /
//  "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" / "\`" / "|" / "~" /
//  DIGIT / ALPHA`).
//
//  Integer-value JS-safe-range validation (a VALUE constraint applied
//  when a call's actual argument is converted to a header, not a
//  SCHEMA-definition-validity constraint) is out of scope for this file
//  -- it belongs to the call-time header-encoding path, not catalog
//  exclusion, and is flagged as untested in the handoff report.
//
//  Resolved (contract §8, current text): "properties の連鎖だけで到達できる
//  プリミティブ型（string、integer、boolean）のプロパティのみ対象（一次資料
//  どおり入れ子のオブジェクトの中も有効。number、array、object 自体は除外、
//  items/oneOf/anyOf/allOf/not/if-then-else/$ref を経由する参照先には付けら
//  れない）". A property nested arbitrarily deep is valid as long as every
//  step in the chain is a `properties` key (matching the primary source
//  quoted above); `number`/`array`/`object` are rejected at any depth,
//  including nested. This supersedes an earlier draft of this file that
//  treated the nested case as unresolved.
//
//  Assumed API surface (this feature has no production code yet):
//    enum MCPXMCPHeaderValidation {
//        static func validationFailureReason(for tool: MCPToolDefinition) -> String?
//        static func strippingXMCPHeaderAnnotations(from raw: [String: AnyCodable]) -> [String: AnyCodable]
//    }
//

import XCTest
@testable import Calyx

final class MCPXMCPHeaderValidationTests: XCTestCase {

    // MARK: - Helpers

    private func inputSchema(properties: [String: AnyCodable], required: [String] = []) -> AnyCodable {
        AnyCodable([
            "type": AnyCodable("object"),
            "properties": AnyCodable(properties),
            "required": AnyCodable(required.map { AnyCodable($0) }),
        ])
    }

    private func toolWithSchema(_ schema: AnyCodable) throws -> MCPToolDefinition {
        try MCPToolDefinition(raw: [
            "name": AnyCodable("execute_sql"),
            "description": AnyCodable("d"),
            "inputSchema": schema,
        ])
    }

    // MARK: - Valid: top-level string property, plain token name

    func test_valid_topLevelStringProperty_plainTokenName_noFailure() throws {
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
            "query": AnyCodable(["type": AnyCodable("string")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    func test_valid_booleanAndIntegerTypes_noFailure() throws {
        let schema = inputSchema(properties: [
            "dryRun": AnyCodable(["type": AnyCodable("boolean"), "x-mcp-header": AnyCodable("DryRun")]),
            "limit": AnyCodable(["type": AnyCodable("integer"), "x-mcp-header": AnyCodable("Limit")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    // MARK: - MUST NOT be empty

    func test_emptyValue_isInvalid() throws {
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    // MARK: - MUST match HTTP field-name token syntax (1*tchar)

    func test_valueContainingASpace_isInvalid() throws {
        // Space is not a tchar.
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region Name")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    func test_valueContainingAColon_isInvalid() throws {
        // ":" is not a tchar (it is a delimiter reserved for the
        // header's own name/value separator).
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region:Name")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    func test_valueContainingNonASCIILetter_isInvalid() throws {
        // Non-ASCII is never a tchar (tchar is ASCII-only per RFC 9110).
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Régión")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    func test_valueWithOnlyValidTcharPunctuation_isValid() throws {
        // "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_",
        // "`", "|", "~" are all valid tchar punctuation.
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("X-Region_1.field")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    // MARK: - MUST NOT contain control characters (CR/LF)

    func test_valueContainingCarriageReturn_isInvalid() throws {
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region\r")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    func test_valueContainingLineFeed_isInvalid() throws {
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region\nInjected: evil")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    // MARK: - MUST be case-insensitively unique within the inputSchema

    func test_caseInsensitiveDuplicateAcrossTwoProperties_isInvalid() throws {
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
            "otherRegion": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("region")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "\"Region\" and \"region\" collide case-insensitively -- the whole tool definition is invalid")
    }

    func test_distinctNames_areValid() throws {
        let schema = inputSchema(properties: [
            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
            "zone": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Zone")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    // MARK: - MUST only apply to primitive types (not "number")

    func test_numberType_isInvalid() throws {
        let schema = inputSchema(properties: [
            "temperature": AnyCodable(["type": AnyCodable("number"), "x-mcp-header": AnyCodable("Temperature")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "type: number is explicitly excluded from x-mcp-header eligibility")
    }

    func test_objectType_isInvalid() throws {
        let schema = inputSchema(properties: [
            "config": AnyCodable(["type": AnyCodable("object"), "x-mcp-header": AnyCodable("Config")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool))
    }

    func test_arrayType_isInvalid() throws {
        // A property whose OWN declared type is "array" is not a
        // primitive type (integer/string/boolean), independent of the
        // separate "reachable only through items" rule below.
        let schema = inputSchema(properties: [
            "regions": AnyCodable(["type": AnyCodable("array"), "x-mcp-header": AnyCodable("Regions")]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "type: array is not one of the permitted primitive types (integer/string/boolean)")
    }

    // MARK: - MUST only be reachable via a chain of "properties" keys
    // (nested object properties ARE permitted, contract §8 resolved text)

    func test_nestedObjectProperty_reachableSolelyViaProperties_isValid() throws {
        let schema = inputSchema(properties: [
            "connection": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
                ]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                     "nested object properties are permitted as long as every step is a properties key")
    }

    func test_deeplyNestedObjectProperty_reachableSolelyViaProperties_isValid() throws {
        let schema = inputSchema(properties: [
            "connection": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "network": AnyCodable([
                        "type": AnyCodable("object"),
                        "properties": AnyCodable([
                            "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                     "any depth of nesting is permitted as long as every step is a properties key")
    }

    func test_nestedNumberType_isInvalid() throws {
        // number/array/object are excluded at ANY depth, not just top level.
        let schema = inputSchema(properties: [
            "connection": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "temperature": AnyCodable(["type": AnyCodable("number"), "x-mcp-header": AnyCodable("Temperature")]),
                ]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "type: number is excluded even when reached solely through a properties chain")
    }

    func test_nestedArrayType_isInvalid() throws {
        let schema = inputSchema(properties: [
            "connection": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "regions": AnyCodable(["type": AnyCodable("array"), "x-mcp-header": AnyCodable("Regions")]),
                ]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "type: array is excluded even when reached solely through a properties chain")
    }

    func test_reachableOnlyThroughArrayItems_isInvalid() throws {
        let schema = inputSchema(properties: [
            "regions": AnyCodable([
                "type": AnyCodable("array"),
                "items": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "the chain must not pass through items (or any other array keyword)")
    }

    func test_reachableOnlyThroughOneOf_isInvalid() throws {
        let schema = inputSchema(properties: [
            "target": AnyCodable([
                "oneOf": AnyCodable([
                    AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
                    AnyCodable(["type": AnyCodable("integer")]),
                ]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "the chain must not pass through composition keywords (oneOf/anyOf/allOf/not)")
    }

    func test_reachableOnlyThroughIfThenElse_isInvalid() throws {
        let schema = inputSchema(properties: [
            "target": AnyCodable([
                "if": AnyCodable(["const": AnyCodable("a")]),
                "then": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "the chain must not pass through conditional keywords (if/then/else)")
    }

    func test_reachableOnlyThroughRef_isInvalid() throws {
        // The only annotation lives under $defs and is reachable solely
        // through the $ref.
        let schema = AnyCodable([
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "target": AnyCodable(["$ref": AnyCodable("#/$defs/RegionParam")]),
            ]),
            "required": AnyCodable([AnyCodable]()),
            "$defs": AnyCodable([
                "RegionParam": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        XCTAssertNotNil(MCPXMCPHeaderValidation.validationFailureReason(for: tool),
                        "the chain must not pass through $ref")
    }

    // MARK: - Stripping: the annotation never reaches the exported schema,
    // and nothing else in the schema's structure changes (byte-identical
    // aside from the removed key).

    func test_strippingXMCPHeaderAnnotations_removesOnlyTheAnnotationKey_restIsStructurallyIdentical() throws {
        let schema = inputSchema(
            properties: [
                "region": AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("The region"), "x-mcp-header": AnyCodable("Region")]),
                "query": AnyCodable(["type": AnyCodable("string")]),
            ],
            required: ["query"]
        )
        let tool = try toolWithSchema(schema)
        let stripped = MCPXMCPHeaderValidation.strippingXMCPHeaderAnnotations(from: tool.raw)

        // Hand-build the expected dictionary: identical to `tool.raw`
        // except the "x-mcp-header" key is removed from "region". Full
        // dictionary equality (not a handful of spot-checked keys) is the
        // only way to catch an implementation that also drops "required"
        // or "description" while stripping.
        let expectedRegion: AnyCodable = AnyCodable(["type": AnyCodable("string"), "description": AnyCodable("The region")])
        var expected = tool.raw
        expected["inputSchema"] = AnyCodable([
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "region": expectedRegion,
                "query": AnyCodable(["type": AnyCodable("string")]),
            ]),
            "required": AnyCodable([AnyCodable("query")]),
        ])

        XCTAssertEqual(stripped, expected,
                       "stripping must remove only the x-mcp-header key; everything else in the raw " +
                       "definition (including sibling properties, `required`, and `description`) must be " +
                       "structurally identical")
    }

    func test_strippingXMCPHeaderAnnotations_removesNestedAnnotationsToo() throws {
        let schema = inputSchema(properties: [
            "connection": AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": AnyCodable("Region")]),
                    "port": AnyCodable(["type": AnyCodable("integer")]),
                ]),
            ]),
        ])
        let tool = try toolWithSchema(schema)
        let stripped = MCPXMCPHeaderValidation.strippingXMCPHeaderAnnotations(from: tool.raw)

        var expected = tool.raw
        expected["inputSchema"] = AnyCodable([
            "type": AnyCodable("object"),
            "properties": AnyCodable([
                "connection": AnyCodable([
                    "type": AnyCodable("object"),
                    "properties": AnyCodable([
                        "region": AnyCodable(["type": AnyCodable("string")]),
                        "port": AnyCodable(["type": AnyCodable("integer")]),
                    ]),
                ]),
            ]),
            "required": AnyCodable([AnyCodable]()),
        ])

        XCTAssertEqual(stripped, expected,
                       "a nested x-mcp-header annotation must be removed too, with the rest of the " +
                       "nested structure (including the sibling \"port\" property) left identical")
    }

    func test_strippingXMCPHeaderAnnotations_noAnnotationPresent_isANoOp() throws {
        let schema = inputSchema(properties: [
            "query": AnyCodable(["type": AnyCodable("string")]),
        ])
        let tool = try toolWithSchema(schema)
        let stripped = MCPXMCPHeaderValidation.strippingXMCPHeaderAnnotations(from: tool.raw)
        XCTAssertEqual(stripped, tool.raw, "with no x-mcp-header annotations present, stripping must leave the raw definition unchanged")
    }
}
