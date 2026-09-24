//
//  MCPWireTypesDecodeTests.swift
//  CalyxTests
//
//  Minimal-payload decode tests (only the fields the pinned schema.json
//  marks `required`) and explicit-null tests for every type mirrored from
//  CalyxTests/Fixtures/MCPSchema/{2026-07-28,2025-11-25}/schema.json.
//
//  A field NOT in the schema's `required` list must be declared optional
//  in the mirrored Swift type (enforced structurally here by round-tripping
//  the minimal payload); a field whose schema entry allows omission must
//  decode identically whether the key is absent or present with JSON null.
//

import XCTest
@testable import Calyx

final class MCPWireTypesDecodeTests_Implementation: XCTestCase {

    // Implementation: required = [name, version] (both 2026-07-28 and 2025-11-25).

    func test_decode_minimalPayload_onlyRequiredFields() throws {
        let json = #"{"name":"acme-tool","version":"1.0.0"}"#
        let value = try JSONDecoder().decode(MCPImplementation.self, from: Data(json.utf8))
        XCTAssertEqual(value.name, "acme-tool")
        XCTAssertEqual(value.version, "1.0.0")
        XCTAssertNil(value.title)
    }

    func test_decode_title_absentKey_decodesToNil() throws {
        let json = #"{"name":"acme-tool","version":"1.0.0"}"#
        let value = try JSONDecoder().decode(MCPImplementation.self, from: Data(json.utf8))
        XCTAssertNil(value.title)
    }

    func test_decode_title_explicitNull_decodesToNil() throws {
        let json = #"{"name":"acme-tool","version":"1.0.0","title":null}"#
        let value = try JSONDecoder().decode(MCPImplementation.self, from: Data(json.utf8))
        XCTAssertNil(value.title)
    }
}

final class MCPWireTypesDecodeTests_ClientCapabilities: XCTestCase {

    // ClientCapabilities: no required fields; every property optional.

    func test_decode_emptyObject_allFieldsNil() throws {
        let value = try JSONDecoder().decode(MCPClientCapabilities.self, from: Data("{}".utf8))
        XCTAssertNil(value.extensions)
        XCTAssertNil(value.elicitation)
        XCTAssertNil(value.roots)
    }

    func test_decode_extensions_readsPerExtensionSettingsObject() throws {
        let json = #"{"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]}}}"#
        let value = try JSONDecoder().decode(MCPClientCapabilities.self, from: Data(json.utf8))
        let mimeTypes = value.extensions?["io.modelcontextprotocol/ui"]?["mimeTypes"]?.arrayValue
        XCTAssertEqual(mimeTypes?.first?.stringValue, "text/html;profile=mcp-app")
    }

    func test_decode_extensions_absentKey_decodesToNil() throws {
        let value = try JSONDecoder().decode(MCPClientCapabilities.self, from: Data("{}".utf8))
        XCTAssertNil(value.extensions)
    }

    func test_decode_extensions_explicitNull_decodesToNil() throws {
        let value = try JSONDecoder().decode(MCPClientCapabilities.self, from: Data(#"{"extensions":null}"#.utf8))
        XCTAssertNil(value.extensions)
    }

    func test_decode_elicitation_formAndUrl() throws {
        let json = #"{"elicitation":{"form":{},"url":{}}}"#
        let value = try JSONDecoder().decode(MCPClientCapabilities.self, from: Data(json.utf8))
        XCTAssertEqual(value.elicitation?.form, [:])
        XCTAssertEqual(value.elicitation?.url, [:])
    }

    func test_encode_extensions_isEmittedAsJSONObject() throws {
        let value = MCPClientCapabilities(
            extensions: ["io.modelcontextprotocol/ui": ["mimeTypes": AnyCodable([AnyCodable("text/html;profile=mcp-app")])]],
            elicitation: nil,
            roots: nil
        )
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let extensions = object?["extensions"] as? [String: Any]
        let ui = extensions?["io.modelcontextprotocol/ui"] as? [String: Any]
        let mimeTypes = ui?["mimeTypes"] as? [String]
        XCTAssertEqual(mimeTypes, ["text/html;profile=mcp-app"])
    }
}

final class MCPWireTypesDecodeTests_ServerCapabilities: XCTestCase {

    // ServerCapabilities: no required fields.

    func test_decode_emptyObject_allFieldsNil() throws {
        let value = try JSONDecoder().decode(MCPServerCapabilities.self, from: Data("{}".utf8))
        XCTAssertNil(value.tools)
        XCTAssertNil(value.prompts)
        XCTAssertNil(value.resources)
        XCTAssertNil(value.extensions)
    }

    func test_decode_tools_listChangedTrue() throws {
        let json = #"{"tools":{"listChanged":true}}"#
        let value = try JSONDecoder().decode(MCPServerCapabilities.self, from: Data(json.utf8))
        XCTAssertEqual(value.tools?.listChanged, true)
    }

    func test_decode_resources_subscribeAndListChanged() throws {
        let json = #"{"resources":{"subscribe":true,"listChanged":false}}"#
        let value = try JSONDecoder().decode(MCPServerCapabilities.self, from: Data(json.utf8))
        XCTAssertEqual(value.resources?.subscribe, true)
        XCTAssertEqual(value.resources?.listChanged, false)
    }
}

final class MCPWireTypesDecodeTests_InitializeResult: XCTestCase {

    // InitializeResult (legacy, 2025-11-25): required = [capabilities, protocolVersion, serverInfo].

    func test_decode_minimalPayload_onlyRequiredFields() throws {
        let json = #"""
        {"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"srv","version":"1.0"}}
        """#
        let value = try JSONDecoder().decode(MCPInitializeResult.self, from: Data(json.utf8))
        XCTAssertEqual(value.protocolVersion, "2025-11-25")
        XCTAssertEqual(value.serverInfo.name, "srv")
        XCTAssertNil(value.instructions)
    }

    func test_decode_instructions_explicitNull_decodesToNil() throws {
        let json = #"""
        {"protocolVersion":"2025-11-25","capabilities":{},"serverInfo":{"name":"srv","version":"1.0"},"instructions":null}
        """#
        let value = try JSONDecoder().decode(MCPInitializeResult.self, from: Data(json.utf8))
        XCTAssertNil(value.instructions)
    }
}

final class MCPWireTypesDecodeTests_DiscoverResult: XCTestCase {

    // DiscoverResult (modern, 2026-07-28): required =
    // [cacheScope, capabilities, resultType, supportedVersions, ttlMs].

    func test_decode_minimalPayload_onlyRequiredFields() throws {
        let json = #"""
        {"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}
        """#
        let value = try JSONDecoder().decode(MCPDiscoverResult.self, from: Data(json.utf8))
        XCTAssertEqual(value.resultType, "complete")
        XCTAssertEqual(value.supportedVersions, ["2026-07-28"])
        XCTAssertEqual(value.cacheScope, "public")
        XCTAssertEqual(value.ttlMs, 0)
        XCTAssertNil(value.instructions)
    }

    func test_decode_instructions_explicitNull_decodesToNil() throws {
        let json = #"""
        {"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"private","ttlMs":60000,"instructions":null}
        """#
        let value = try JSONDecoder().decode(MCPDiscoverResult.self, from: Data(json.utf8))
        XCTAssertNil(value.instructions)
    }

    func test_decode_metaServerInfo_presentDecodes_absentDecodesToNil() throws {
        let present = #"""
        {"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0,"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"upstream","version":"2.1"}}}
        """#
        let withServerInfo = try JSONDecoder().decode(MCPDiscoverResult.self, from: Data(present.utf8))
        XCTAssertEqual(
            withServerInfo.serverInfo,
            MCPImplementation(name: "upstream", version: "2.1", title: nil, description: nil, websiteUrl: nil)
        )

        let metaWithoutServerInfo = #"""
        {"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0,"_meta":{}}
        """#
        XCTAssertNil(try JSONDecoder().decode(MCPDiscoverResult.self, from: Data(metaWithoutServerInfo.utf8)).serverInfo)

        let noMeta = #"""
        {"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"cacheScope":"public","ttlMs":0}
        """#
        XCTAssertNil(try JSONDecoder().decode(MCPDiscoverResult.self, from: Data(noMeta.utf8)).serverInfo)
    }
}

final class MCPWireTypesDecodeTests_InputRequiredResult: XCTestCase {

    // InputRequiredResult (MRTR): required = [resultType]. At least one of
    // inputRequests/requestState MUST be present per spec prose, but the
    // schema itself only requires resultType, so both are optional Swift
    // fields; this test exercises the requestState-only minimal shape.

    func test_decode_minimalPayload_resultTypeInputRequired() throws {
        let json = #"{"resultType":"input_required","requestState":"opaque-state-token"}"#
        let value = try JSONDecoder().decode(MCPInputRequiredResult.self, from: Data(json.utf8))
        XCTAssertEqual(value.resultType, "input_required")
        XCTAssertEqual(value.requestState, "opaque-state-token")
        XCTAssertNil(value.inputRequests)
    }

    func test_decode_inputRequests_isKeyedMapOfServerAssignedIds_elicit() throws {
        // schema.json's InputRequest is anyOf [CreateMessageRequest,
        // ListRootsRequest, ElicitRequest], all of the shape {method, params}.
        let json = #"""
        {"resultType":"input_required","inputRequests":{"req-1":{"method":"elicitation/create","params":{"message":"need info"}}}}
        """#
        let value = try JSONDecoder().decode(MCPInputRequiredResult.self, from: Data(json.utf8))
        let request = try XCTUnwrap(value.inputRequests?["req-1"])
        XCTAssertEqual(request.method, "elicitation/create")
        XCTAssertEqual(request.params?["message"]?.stringValue, "need info")
    }

    func test_decode_inputRequests_isKeyedMapOfServerAssignedIds_rootsList() throws {
        let json = #"""
        {"resultType":"input_required","inputRequests":{"req-2":{"method":"roots/list","params":{}}}}
        """#
        let value = try JSONDecoder().decode(MCPInputRequiredResult.self, from: Data(json.utf8))
        let request = try XCTUnwrap(value.inputRequests?["req-2"])
        XCTAssertEqual(request.method, "roots/list")
    }

    func test_decode_requestState_explicitNull_decodesToNil() throws {
        let json = #"{"resultType":"input_required","requestState":null,"inputRequests":{}}"#
        let value = try JSONDecoder().decode(MCPInputRequiredResult.self, from: Data(json.utf8))
        XCTAssertNil(value.requestState)
    }
}

final class MCPWireTypesDecodeTests_ElicitRequest: XCTestCase {

    // ElicitRequestFormParams (2026-07-28): required = [message, requestedSchema]
    // -- NOT `mode` (finding 18: the field is required for the URL variant
    // but NOT the form variant, so one Swift type serving both makes `mode`
    // optional; absent means form).
    // ElicitRequestURLParams (2026-07-28): required = [message, mode, url].
    // elicitationId is required only in the 2025-11-25 schema, so it is
    // modeled as an optional field here.

    func test_decode_formMode_minimalPayload_modeAbsent() throws {
        let json = #"""
        {"message":"Enter your name","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}
        """#
        let value = try JSONDecoder().decode(MCPElicitRequestParams.self, from: Data(json.utf8))
        XCTAssertNil(value.mode, "mode is absent for the minimal form-mode payload per the schema's required list")
        XCTAssertEqual(value.message, "Enter your name")
        XCTAssertNotNil(value.requestedSchema)
        XCTAssertNil(value.url)
    }

    func test_decode_formMode_explicitModeStillDecodes() throws {
        let json = #"""
        {"mode":"form","message":"Enter your name","requestedSchema":{"type":"object","properties":{}}}
        """#
        let value = try JSONDecoder().decode(MCPElicitRequestParams.self, from: Data(json.utf8))
        XCTAssertEqual(value.mode, "form")
    }

    func test_decode_urlMode_minimalPayload() throws {
        let json = #"{"mode":"url","message":"Sign in to continue","url":"https://example.com/authorize"}"#
        let value = try JSONDecoder().decode(MCPElicitRequestParams.self, from: Data(json.utf8))
        XCTAssertEqual(value.mode, "url")
        XCTAssertEqual(value.url, "https://example.com/authorize")
        XCTAssertNil(value.requestedSchema)
    }

    func test_decode_urlMode_legacyElicitationId_decodesAsOptional() throws {
        let json = #"{"mode":"url","message":"Sign in","url":"https://example.com","elicitationId":"elicit-1"}"#
        let value = try JSONDecoder().decode(MCPElicitRequestParams.self, from: Data(json.utf8))
        XCTAssertEqual(value.elicitationId, "elicit-1")
    }

    func test_decode_elicitationId_absent_decodesToNil() throws {
        let json = #"{"mode":"url","message":"Sign in","url":"https://example.com"}"#
        let value = try JSONDecoder().decode(MCPElicitRequestParams.self, from: Data(json.utf8))
        XCTAssertNil(value.elicitationId)
    }
}

final class MCPWireTypesDecodeTests_ListRootsResult: XCTestCase {

    // ListRootsResult: required = [roots]. Root: required = [uri].

    func test_decode_minimalPayload_singleRootUriOnly() throws {
        let json = #"{"roots":[{"uri":"file:///Users/dev/project"}]}"#
        let value = try JSONDecoder().decode(MCPListRootsResult.self, from: Data(json.utf8))
        XCTAssertEqual(value.roots.count, 1)
        XCTAssertEqual(value.roots[0].uri, "file:///Users/dev/project")
        XCTAssertNil(value.roots[0].name)
    }

    func test_decode_root_name_explicitNull_decodesToNil() throws {
        let json = #"{"roots":[{"uri":"file:///a","name":null}]}"#
        let value = try JSONDecoder().decode(MCPListRootsResult.self, from: Data(json.utf8))
        XCTAssertNil(value.roots[0].name)
    }

    func test_decode_emptyRootsArray() throws {
        let value = try JSONDecoder().decode(MCPListRootsResult.self, from: Data(#"{"roots":[]}"#.utf8))
        XCTAssertTrue(value.roots.isEmpty)
    }
}

final class MCPWireTypesDecodeTests_ProgressNotification: XCTestCase {

    // ProgressNotificationParams: required = [progress, progressToken].

    func test_decode_minimalPayload_intProgressToken() throws {
        let json = #"{"progress":0.5,"progressToken":1}"#
        let value = try JSONDecoder().decode(MCPProgressNotificationParams.self, from: Data(json.utf8))
        XCTAssertEqual(value.progress, 0.5)
        XCTAssertNil(value.total)
        XCTAssertNil(value.message)
    }

    func test_decode_minimalPayload_stringProgressToken() throws {
        let json = #"{"progress":0.5,"progressToken":"token-a"}"#
        let value = try JSONDecoder().decode(MCPProgressNotificationParams.self, from: Data(json.utf8))
        XCTAssertEqual(value.progressToken, .string("token-a"))
    }

    func test_decode_total_explicitNull_decodesToNil() throws {
        let json = #"{"progress":0.5,"progressToken":1,"total":null}"#
        let value = try JSONDecoder().decode(MCPProgressNotificationParams.self, from: Data(json.utf8))
        XCTAssertNil(value.total)
    }
}

final class MCPWireTypesDecodeTests_CancelledNotification: XCTestCase {

    // CancelledNotificationParams: requestId is required in the 2026-07-28
    // schema but absent from the 2025-11-25 schema's required list (fixture-
    // pinned above). One Swift type mirrors both eras, so requestId must be
    // optional to stay a superset-compatible subset of both `required`
    // arrays; cover both the present and absent shapes.

    func test_decode_minimalPayload_requestIdOnly() throws {
        let json = #"{"requestId":1}"#
        let value = try JSONDecoder().decode(MCPCancelledNotificationParams.self, from: Data(json.utf8))
        XCTAssertEqual(value.requestId, .int(1))
        XCTAssertNil(value.reason)
    }

    func test_decode_requestId_absent_decodesToNil() throws {
        let json = #"{"reason":"user cancelled"}"#
        let value = try JSONDecoder().decode(MCPCancelledNotificationParams.self, from: Data(json.utf8))
        XCTAssertNil(value.requestId)
        XCTAssertEqual(value.reason, "user cancelled")
    }

    func test_decode_reason_explicitNull_decodesToNil() throws {
        let json = #"{"requestId":1,"reason":null}"#
        let value = try JSONDecoder().decode(MCPCancelledNotificationParams.self, from: Data(json.utf8))
        XCTAssertNil(value.reason)
    }
}

final class MCPWireTypesDecodeTests_ErrorData: XCTestCase {

    // HeaderMismatchError (-32020): data has no fixed schema shape here
    // (error-specific), decode as opaque AnyCodable via JSONRPCError.data.

    func test_decode_headerMismatch_minusThirtyTwoThousandTwenty() throws {
        let json = #"{"code":-32020,"message":"MCP-Protocol-Version header mismatch"}"#
        let error = try JSONDecoder().decode(JSONRPCError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, -32020)
    }

    // MissingRequiredClientCapabilityError (-32021): data.requiredCapabilities required.

    func test_decode_missingRequiredClientCapability_minusThirtyTwoThousandTwentyOne() throws {
        let json = #"""
        {"code":-32021,"message":"missing capability","data":{"requiredCapabilities":{"elicitation":{}}}}
        """#
        let error = try JSONDecoder().decode(JSONRPCError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, -32021)
        XCTAssertNotNil(error.data?["requiredCapabilities"])
    }

    // UnsupportedProtocolVersionError (-32022): data.supported required array.

    func test_decode_unsupportedProtocolVersion_minusThirtyTwoThousandTwentyTwo_dataSupported() throws {
        let json = #"""
        {"code":-32022,"message":"unsupported version","data":{"supported":["2026-07-28","2025-11-25"]}}
        """#
        let error = try JSONDecoder().decode(JSONRPCError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, -32022)
        let supported = error.data?["supported"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertEqual(supported, ["2026-07-28", "2025-11-25"])
    }

    // URLElicitationRequiredError (-32042, 2025-11-25 schema only):
    // data.elicitations required array of ElicitRequestURLParams.

    func test_decode_urlElicitationRequired_minusThirtyTwoThousandFortyTwo_dataElicitations() throws {
        let json = #"""
        {"code":-32042,"message":"url elicitation required","data":{"elicitations":[{"mode":"url","message":"Sign in","url":"https://example.com","elicitationId":"e1"}]}}
        """#
        let error = try JSONDecoder().decode(JSONRPCError.self, from: Data(json.utf8))
        XCTAssertEqual(error.code, -32042)
        XCTAssertEqual(error.data?["elicitations"]?.arrayValue?.count, 1)
        XCTAssertEqual(error.data?["elicitations"]?.arrayValue?.first?["url"]?.stringValue, "https://example.com")
    }
}

final class MCPWireTypesDecodeTests_ElicitResult: XCTestCase {

    // ElicitResult: required = [action] (both schema versions).

    func test_decode_minimalPayload_actionDecline() throws {
        let value = try JSONDecoder().decode(MCPElicitResult.self, from: Data(#"{"action":"decline"}"#.utf8))
        XCTAssertEqual(value.action, "decline")
        XCTAssertNil(value.content)
    }

    func test_decode_accept_withFormContent() throws {
        let json = #"{"action":"accept","content":{"name":"Ada"}}"#
        let value = try JSONDecoder().decode(MCPElicitResult.self, from: Data(json.utf8))
        XCTAssertEqual(value.action, "accept")
        XCTAssertEqual(value.content?["name"]?.stringValue, "Ada")
    }

    func test_decode_content_absentKey_decodesToNil() throws {
        let value = try JSONDecoder().decode(MCPElicitResult.self, from: Data(#"{"action":"cancel"}"#.utf8))
        XCTAssertNil(value.content)
    }
}

final class MCPWireTypesDecodeTests_ElicitRequestedSchema: XCTestCase {

    // ElicitRequestedSchema: required = [type]. The JSON key `$schema` maps
    // to the Swift property `schemaDialect` via a custom CodingKeys.

    func test_decode_minimalPayload_typeOnly() throws {
        let value = try JSONDecoder().decode(MCPElicitRequestedSchema.self, from: Data(#"{"type":"object"}"#.utf8))
        XCTAssertEqual(value.type, "object")
        XCTAssertNil(value.schemaDialect)
        XCTAssertNil(value.properties)
        XCTAssertNil(value.required)
    }

    func test_decode_dollarSchemaKey_mapsToSchemaDialectProperty() throws {
        let json = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object"}"#
        let value = try JSONDecoder().decode(MCPElicitRequestedSchema.self, from: Data(json.utf8))
        XCTAssertEqual(value.schemaDialect, "https://json-schema.org/draft/2020-12/schema")
    }

    func test_decode_propertiesAndRequired() throws {
        let json = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#
        let value = try JSONDecoder().decode(MCPElicitRequestedSchema.self, from: Data(json.utf8))
        XCTAssertEqual(value.properties?["name"]?["type"]?.stringValue, "string")
        XCTAssertEqual(value.required, ["name"])
    }
}

final class MCPWireTypesDecodeTests_RequestMetaObject: XCTestCase {

    // RequestMetaObject: dotted-prefix keys, custom CodingKeys.
    // required (2026-07-28) = [io.modelcontextprotocol/clientCapabilities,
    // io.modelcontextprotocol/protocolVersion]; progressToken has no
    // namespace prefix (inherited from MetaObject) and is optional.

    func test_decode_dottedKeys_mapToNamedProperties() throws {
        let json = #"""
        {
          "io.modelcontextprotocol/protocolVersion": "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities": {
            "extensions": { "io.modelcontextprotocol/ui": { "mimeTypes": ["text/html;profile=mcp-app"] } },
            "elicitation": { "form": {}, "url": {} },
            "roots": {}
          },
          "io.modelcontextprotocol/clientInfo": { "name": "Calyx", "version": "0.42.0" },
          "progressToken": 7
        }
        """#
        let value = try JSONDecoder().decode(MCPRequestMetaObject.self, from: Data(json.utf8))
        XCTAssertEqual(value.protocolVersion, "2026-07-28")
        XCTAssertEqual(value.clientInfo?.name, "Calyx")
        XCTAssertEqual(value.clientInfo?.version, "0.42.0")
        XCTAssertNotNil(value.clientCapabilities?.roots)
        XCTAssertEqual(value.progressToken, .int(7))
    }

    func test_decode_logLevel_dottedKey() throws {
        let json = #"{"io.modelcontextprotocol/logLevel":"debug"}"#
        let value = try JSONDecoder().decode(MCPRequestMetaObject.self, from: Data(json.utf8))
        XCTAssertEqual(value.logLevel, "debug")
    }

    func test_decode_emptyObject_allFieldsNil() throws {
        let value = try JSONDecoder().decode(MCPRequestMetaObject.self, from: Data("{}".utf8))
        XCTAssertNil(value.clientCapabilities)
        XCTAssertNil(value.clientInfo)
        XCTAssertNil(value.logLevel)
        XCTAssertNil(value.protocolVersion)
        XCTAssertNil(value.progressToken)
    }

    func test_encode_usesDottedNamespaceKeys() throws {
        let value = MCPRequestMetaObject(
            clientCapabilities: nil,
            clientInfo: nil,
            logLevel: nil,
            protocolVersion: "2026-07-28",
            progressToken: .int(7)
        )
        let encoded = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        XCTAssertEqual(object?["io.modelcontextprotocol/protocolVersion"] as? String, "2026-07-28")
        XCTAssertEqual(object?["progressToken"] as? Int, 7)
        XCTAssertNil(object?["io.modelcontextprotocol/clientCapabilities"])
    }
}

final class MCPWireTypesDecodeTests_CallToolResult: XCTestCase {

    // MCPCallToolResult has no Codable conformance in the contract; it is
    // constructed from a `[String: AnyCodable]` decoded generically, and
    // simply holds that dictionary verbatim (no closed structure, no field
    // filtering), including keys the schema does not name.

    func test_raw_preservesMetaAndUnknownKeysVerbatim() throws {
        let json = #"""
        {"content":[{"type":"text","text":"ok"}],"resultType":"complete","isError":false,
         "_meta":{"io.modelcontextprotocol/ui":{"instance":"abc"}},"futureField":"unknown-value"}
        """#
        let dict = try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
        let result = MCPCallToolResult(raw: dict)
        XCTAssertEqual(result.raw["resultType"]?.stringValue, "complete")
        XCTAssertEqual(result.raw["isError"]?.boolValue, false)
        XCTAssertEqual(result.raw["_meta"]?["io.modelcontextprotocol/ui"]?["instance"]?.stringValue, "abc")
        XCTAssertEqual(result.raw["futureField"]?.stringValue, "unknown-value")
    }

    func test_raw_resultTypeAbsent_isPreservedAsAbsent() throws {
        // A pre-2026 server's CallToolResult has no resultType key at all;
        // Wire does not synthesize one, it only carries what was decoded.
        let json = #"{"content":[{"type":"text","text":"ok"}]}"#
        let dict = try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
        let result = MCPCallToolResult(raw: dict)
        XCTAssertNil(result.raw["resultType"])
    }

    func test_equatable_comparesByRawDictionary() throws {
        let a = MCPCallToolResult(raw: ["ok": AnyCodable(true)])
        let b = MCPCallToolResult(raw: ["ok": AnyCodable(true)])
        let c = MCPCallToolResult(raw: ["ok": AnyCodable(false)])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
