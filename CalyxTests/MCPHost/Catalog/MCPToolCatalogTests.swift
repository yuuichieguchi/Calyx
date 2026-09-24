//
//  MCPToolCatalogTests.swift
//  CalyxTests
//
//  Coverage: `MCPToolCatalog.build(serverTools:paneAppTools:)` -- the pure
//  batch resolver from contract §8 that turns per-server upstream tool
//  lists into the re-published catalog: exported names via
//  `MCPExportedName`, exclusion of `execution.taskSupport == "required"`
//  tools and tools carrying an invalid `x-mcp-header` (with reasons),
//  first-kept-wins on an upstream duplicate name, `x-mcp-header` stripped
//  from the exported schema, `ui://` resource URI rewriting via
//  `MCPUIResourceURI`, and app-only visibility gated by each server's
//  `clientDeclaredUI` flag.
//
//  API surface, taken verbatim from contract §8 (not invented):
//
//    enum MCPCatalogToolOrigin: Sendable, Equatable {
//        case server
//        case app(surfaceID: UUID, viewID: UUID)
//    }
//    struct MCPCatalogResolvedTool: Sendable, Equatable {
//        let exportedName: String
//        let serverID: MCPServerID
//        let upstreamToolName: String
//        let origin: MCPCatalogToolOrigin
//        let definition: MCPToolDefinition
//        let exportedRaw: [String: AnyCodable]
//    }
//    struct MCPCatalogExclusion: Sendable, Equatable {
//        let serverID: MCPServerID
//        let upstreamToolName: String
//        let reason: String
//    }
//    struct MCPCatalogResult: Sendable, Equatable {
//        let tools: [MCPCatalogResolvedTool]
//        let exclusions: [MCPCatalogExclusion]
//    }
//    struct MCPCatalogPaneAppTool: Sendable, Equatable {
//        let surfaceID: UUID
//        let viewID: UUID            // the view that registered the tool
//        let serverID: MCPServerID   // the server owning the view (alias is that server's)
//        let name: String
//        let definition: MCPToolDefinition
//    }
//    enum MCPToolCatalog {
//        static func build(
//            serverTools: [MCPServerID: (alias: MCPServerAlias, displayName: String, tools: [MCPToolDefinition], clientDeclaredUI: Bool)],
//            paneAppTools: [MCPCatalogPaneAppTool]
//        ) -> MCPCatalogResult
//    }
//
//  App tools (§8, resolved text): each `MCPCatalogPaneAppTool` entry
//  becomes an `MCPCatalogResolvedTool` with `origin: .app(surfaceID:viewID:)`,
//  `exportedName = MCPExportedName.name(alias:, upstreamToolName: "app_" +
//  name, isTaken:)`, and `upstreamToolName = name` (NOT "app_" + name --
//  the "app_" prefix is folded into the NAME GENERATION step only). A name
//  clash with a server tool means the server tool wins and the app tool is
//  excluded with a reason. The caller (Downstream's
//  `MCPCatalogProviding.currentCatalog(clientDeclaredUI:surfaceID:)`)
//  passes only the calling pane's own app tools into `paneAppTools`; a
//  pane-resolved client is expressed by that same caller passing
//  `clientDeclaredUI: false` to `build` (there is no separate
//  "paneResolved" parameter on `build` itself -- Catalog's only lever for
//  hiding app-only tools from the agent is `clientDeclaredUI`).
//  `app_context` is added outside the catalog (Downstream §10.5) and is
//  out of scope for this file, as is `MCPCatalogProviding.resolve(exportedName:surfaceID:)`
//  itself (§10.2, Downstream) -- this file tests the underlying exact-match
//  behavior directly against `MCPCatalogResult.tools`.
//
//  `taskSupport` is a TOP-LEVEL `execution.taskSupport` on the raw tool
//  definition (contract §8, resolved text, matching schema.json's
//  `$defs.Tool.properties.execution` -> `$defs.ToolExecution` in the
//  2025-11-25 fixture; the 2026-07-28 fixture has no `execution` property
//  at all, but the same raw key is honored if present).
//
//  Determinism note: `serverTools` is a `[MCPServerID: ...]` dictionary,
//  so cross-server ordering in `result.tools`/`result.exclusions` is not
//  guaranteed. Tests that use more than one server look up by
//  `exportedName`/`upstreamToolName` (or compare as a `Set`) instead of
//  indexing `[0]`. Tests that index `[0]` use exactly one server so the
//  within-server array order (which IS the input order) is deterministic.
//

import XCTest
@testable import Calyx

final class MCPToolCatalogTests: XCTestCase {

    // MARK: - Helpers

    private func tool(
        _ name: String,
        taskSupport: String? = nil,
        xMCPHeaderValue: AnyCodable? = nil
    ) throws -> MCPToolDefinition {
        var raw: [String: AnyCodable] = [
            "name": AnyCodable(name),
            "description": AnyCodable("d"),
        ]
        if let xMCPHeaderValue {
            // Per the 2026-07-28 Streamable HTTP spec's "Schema Extension"
            // section, `x-mcp-header` is a PER-PARAMETER annotation nested
            // at inputSchema.properties.<name>.x-mcp-header, never a
            // top-level key on the tool object itself.
            raw["inputSchema"] = AnyCodable([
                "type": AnyCodable("object"),
                "properties": AnyCodable([
                    "region": AnyCodable(["type": AnyCodable("string"), "x-mcp-header": xMCPHeaderValue]),
                ]),
            ])
        } else {
            raw["inputSchema"] = AnyCodable(["type": AnyCodable("object")])
        }
        if let taskSupport {
            // Top-level per schema.json's $defs.Tool.properties.execution
            // (see the top-of-file discrepancy note).
            raw["execution"] = AnyCodable(["taskSupport": AnyCodable(taskSupport)])
        }
        return try MCPToolDefinition(raw: raw)
    }

    private func appOnlyTool(_ name: String, resourceURI: String? = "ui://widget.html") throws -> MCPToolDefinition {
        var ui: [String: AnyCodable] = ["visibility": AnyCodable([AnyCodable("app")])]
        if let resourceURI {
            ui["resourceUri"] = AnyCodable(resourceURI)
        }
        return try MCPToolDefinition(raw: [
            "name": AnyCodable(name),
            "description": AnyCodable("d"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
            "_meta": AnyCodable(["ui": AnyCodable(ui)]),
        ])
    }

    private func alias(_ raw: String) -> MCPServerAlias {
        guard let alias = MCPServerAlias(rawValue: raw) else {
            fatalError("test fixture alias '\(raw)' must match ^[a-z][a-z0-9]{0,9}$")
        }
        return alias
    }

    private func build(
        _ tools: [MCPToolDefinition],
        alias: String = "srv",
        clientDeclaredUI: Bool = false
    ) -> (serverID: MCPServerID, result: MCPCatalogResult) {
        let serverID = MCPServerID()
        let result = MCPToolCatalog.build(
            serverTools: [serverID: (alias: self.alias(alias), displayName: "Test Server", tools: tools, clientDeclaredUI: clientDeclaredUI)],
            paneAppTools: []
        )
        return (serverID, result)
    }

    // MARK: - Basic export

    func test_singleTool_exportedWithAliasPrefixedName() throws {
        let (serverID, result) = build([try tool("get_weather")])
        XCTAssertEqual(result.tools.count, 1)
        XCTAssertEqual(result.tools[0].exportedName, "srv-get_weather")
        XCTAssertEqual(result.tools[0].serverID, serverID)
        XCTAssertEqual(result.tools[0].serverDisplayName, "Test Server", "serverDisplayName is the displayName passed for the server")
        XCTAssertEqual(result.tools[0].upstreamToolName, "get_weather")
        XCTAssertEqual(result.tools[0].origin, .server, "an upstream server tool must carry origin == .server")
        XCTAssertTrue(result.exclusions.isEmpty)
    }

    // MARK: - Exact-match lookup by exported name

    func test_exactExportedNameMatch_locatesServerIDUpstreamNameAndDefinition() throws {
        let (serverID, result) = build([try tool("get_weather")])
        let match = result.tools.first(where: { $0.exportedName == "srv-get_weather" })
        XCTAssertEqual(match?.serverID, serverID)
        XCTAssertEqual(match?.upstreamToolName, "get_weather")
        XCTAssertEqual(match?.definition.name, "get_weather")
        XCTAssertNil(result.tools.first(where: { $0.exportedName == "srv-does_not_exist" }),
                     "a name that was never exported must not match")
    }

    // MARK: - taskSupport: required is excluded

    func test_taskSupportRequired_excludedWithReason() throws {
        let (serverID, result) = build([try tool("run_task", taskSupport: "required")])
        XCTAssertTrue(result.tools.isEmpty, "a taskSupport: required tool must never be published (Tasks unimplemented)")
        XCTAssertEqual(result.exclusions.count, 1)
        XCTAssertEqual(result.exclusions[0].serverID, serverID)
        XCTAssertEqual(result.exclusions[0].upstreamToolName, "run_task")
        XCTAssertFalse(result.exclusions[0].reason.isEmpty)
    }

    func test_taskSupportForbidden_isNotExcluded() throws {
        let (_, result) = build([try tool("run_task", taskSupport: "forbidden")])
        XCTAssertEqual(result.tools.count, 1, "only taskSupport: required is excluded, not other values")
    }

    // MARK: - invalid x-mcp-header excluded, stripped from valid exports

    func test_invalidXMCPHeader_excludedWithReason() throws {
        // An empty string is not a usable header value (MCPXMCPHeaderValidationTests
        // pins the full constraint set; this only needs one discriminating case).
        let (serverID, result) = build([try tool("bad_header", xMCPHeaderValue: AnyCodable(""))])
        XCTAssertTrue(result.tools.isEmpty, "an invalid x-mcp-header tool must never be published")
        XCTAssertEqual(result.exclusions.count, 1)
        XCTAssertEqual(result.exclusions[0].serverID, serverID)
        XCTAssertEqual(result.exclusions[0].upstreamToolName, "bad_header")
    }

    func test_validXMCPHeader_strippedFromExportedSchema() throws {
        let (_, result) = build([try tool("has_header", xMCPHeaderValue: AnyCodable("X-Example"))])
        XCTAssertEqual(result.tools.count, 1)
        let exportedProperties = result.tools[0].exportedRaw["inputSchema"]?["properties"]?["region"]
        XCTAssertNil(exportedProperties?["x-mcp-header"],
                     "x-mcp-header must never reach the exported schema a client sees (MCPXMCPHeaderValidation.strippingXMCPHeaderAnnotations)")
        XCTAssertEqual(exportedProperties?["type"]?.stringValue, "string", "the rest of the property definition must survive stripping")
    }

    // MARK: - Duplicate upstream name within one server: first kept

    func test_duplicateUpstreamNameWithinOneServer_firstKeptSecondExcluded() throws {
        let first = try tool("dup")
        let second = try tool("dup")
        let (serverID, result) = build([first, second])
        XCTAssertEqual(result.tools.count, 1, "an upstream duplicate name must publish exactly once")
        XCTAssertEqual(result.exclusions.count, 1)
        XCTAssertEqual(result.exclusions[0].serverID, serverID)
        XCTAssertEqual(result.exclusions[0].upstreamToolName, "dup")
    }

    // MARK: - Sanitization collision within one server: verbatim name wins

    // A discriminating case, not merely two non-colliding names (which any
    // implementation passes regardless of order): "foo_bar" needs no
    // sanitization and must keep its plain exported name; "foo/bar"
    // sanitizes to that SAME string and must lose the plain slot to a
    // hashed name. Both tools live under one server, so the within-server
    // array order is deterministic (the input order) even though
    // cross-server dictionary order is not.
    func test_sanitizationCollisionWithinOneServer_verbatimNameWinsThePlainSlot() throws {
        let verbatim = try tool("foo_bar")
        let sanitizesToSame = try tool("foo/bar")
        let (_, result) = build([verbatim, sanitizesToSame])

        let byUpstreamName = Dictionary(uniqueKeysWithValues: result.tools.map { ($0.upstreamToolName, $0.exportedName) })
        XCTAssertEqual(byUpstreamName["foo_bar"], "srv-foo_bar", "the verbatim upstream name must always keep the plain exported name")
        XCTAssertNotEqual(byUpstreamName["foo/bar"], "srv-foo_bar", "the sanitization-colliding upstream name must never win the plain slot")
        XCTAssertEqual(result.tools.count, 2, "both tools must still be published, just under distinct names")
    }

    // MARK: - Two different servers never collide on the same tool name

    func test_sameToolNameUnderDifferentServers_bothPublishedDistinctly() throws {
        let serverOne = MCPServerID()
        let serverTwo = MCPServerID()
        let result = MCPToolCatalog.build(
            serverTools: [
                serverOne: (alias: alias("one"), displayName: "one", tools: [try tool("shared")], clientDeclaredUI: false),
                serverTwo: (alias: alias("two"), displayName: "two", tools: [try tool("shared")], clientDeclaredUI: false),
            ],
            paneAppTools: []
        )
        XCTAssertEqual(result.tools.count, 2)
        XCTAssertEqual(Set(result.tools.map { $0.exportedName }), ["one-shared", "two-shared"])
    }

    // MARK: - ui:// resource URI rewritten in exportedRaw, and reverses via MCPUIResourceURI

    func test_uiResourceURI_rewrittenInExportedRaw_andReverseLookupRoundTrips() throws {
        let widgetTool = try MCPToolDefinition(raw: [
            "name": AnyCodable("widget"),
            "description": AnyCodable("d"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
            "_meta": AnyCodable(["ui": AnyCodable(["resourceUri": AnyCodable("ui://weather/widget.html")])]),
        ])
        let (_, result) = build([widgetTool])
        XCTAssertEqual(result.tools.count, 1)
        let resolved = result.tools[0]

        let exportedURI = resolved.exportedRaw["_meta"]?["ui"]?["resourceUri"]?.stringValue
        XCTAssertEqual(exportedURI, "ui://srv/weather/widget.html")

        // The source definition retains the untouched upstream URI.
        XCTAssertEqual(resolved.definition.ui?.declaredResourceURI, "ui://weather/widget.html")

        // The rewrite must be reversible through the same MCPUIResourceURI
        // primitive Catalog is specified to call (§8: "逆引きは
        // MCPUIResourceURI.resolve(exportedURI:)").
        let reverse = try XCTUnwrap(MCPUIResourceURI.resolve(exportedURI: try XCTUnwrap(exportedURI)))
        XCTAssertEqual(reverse.alias, "srv")
        XCTAssertEqual(reverse.upstreamURI, "ui://weather/widget.html")
    }

    // MARK: - Visibility: app-only tools gated by clientDeclaredUI (§8, independent of resourceUri)

    func test_appOnlyTool_hiddenWhenClientDidNotDeclareUI() throws {
        let (_, result) = build([try appOnlyTool("widget")], clientDeclaredUI: false)
        XCTAssertTrue(result.tools.isEmpty, "an app-only tool must not be published to a client that never declared the UI extension")
        XCTAssertTrue(result.exclusions.isEmpty, "visibility gating is not one of the three exclusion reasons (taskSupport/x-mcp-header/duplicate); it must not appear as an exclusion")
    }

    func test_appOnlyTool_visibleWhenClientDeclaredUI() throws {
        let (_, result) = build([try appOnlyTool("widget")], clientDeclaredUI: true)
        XCTAssertEqual(result.tools.map { $0.exportedName }, ["srv-widget"])
    }

    // Visibility is independent of whether a resourceUri was ever declared
    // at all -- an app-only tool with NO `_meta.ui.resourceUri` (e.g. a
    // tool that performs a side effect a view triggers but has no view of
    // its own) must still be gated purely by `visibility`.
    func test_appOnlyToolWithNoResourceURI_gatedTheSameWayAsOneWithAResourceURI() throws {
        let hidden = build([try appOnlyTool("record_event", resourceURI: nil)], clientDeclaredUI: false)
        XCTAssertTrue(hidden.result.tools.isEmpty, "app-only visibility hides a tool even when it declares no resourceUri at all")

        let shown = build([try appOnlyTool("record_event", resourceURI: nil)], clientDeclaredUI: true)
        XCTAssertEqual(shown.result.tools.map { $0.exportedName }, ["srv-record_event"])
    }

    func test_modelVisibleTool_alwaysPublishedRegardlessOfClientDeclaredUI() throws {
        for declared in [true, false] {
            let (_, result) = build([try tool("plain_tool")], clientDeclaredUI: declared)
            XCTAssertEqual(result.tools.map { $0.exportedName }, ["srv-plain_tool"],
                           "a model-visible tool (no _meta.ui at all) must always be published, clientDeclaredUI=\(declared)")
        }
    }

    // MARK: - Pane app tools (§8 resolved text): "app_" + name export, origin == .app(surfaceID:)

    func test_paneAppTool_exportedWithAppPrefixedNameAndOwningSurfaceOrigin() throws {
        let serverID = MCPServerID()
        let surfaceID = UUID()
        let viewID = UUID()
        let appDefinition = try MCPToolDefinition(raw: [
            "name": AnyCodable("record_event"),
            "description": AnyCodable("d"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
        ])
        let paneAppTool = MCPCatalogPaneAppTool(surfaceID: surfaceID, viewID: viewID, serverID: serverID, name: "record_event", definition: appDefinition)

        let result = MCPToolCatalog.build(
            serverTools: [serverID: (alias: alias("srv"), displayName: "srv", tools: [], clientDeclaredUI: true)],
            paneAppTools: [paneAppTool]
        )

        XCTAssertEqual(result.tools.count, 1)
        let resolved = result.tools[0]
        XCTAssertEqual(resolved.exportedName, "srv-app_record_event",
                       "exportedName is MCPExportedName.name(alias:, upstreamToolName: \"app_\" + name, isTaken:)")
        XCTAssertEqual(resolved.upstreamToolName, "record_event",
                       "upstreamToolName is the bare name, NOT \"app_\" + name -- the app_ prefix is folded " +
                       "only into the exported-name generation step")
        XCTAssertEqual(resolved.origin, .app(surfaceID: surfaceID, viewID: viewID),
                       "the origin names the pane and the view that registered the tool")
        XCTAssertEqual(resolved.serverID, serverID)
    }

    func test_paneAppTool_clashingWithServerToolExportedName_excludedWithReason_serverToolWins() throws {
        let serverID = MCPServerID()
        let surfaceID = UUID()
        // Verbatim upstream name "app_widget" exports (unchanged, no hash)
        // to exactly "srv-app_widget" -- the same exported name an app
        // tool named "widget" would generate via the "app_" + name rule.
        let serverTool = try tool("app_widget")
        let appDefinition = try MCPToolDefinition(raw: [
            "name": AnyCodable("widget"),
            "description": AnyCodable("d"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
        ])
        let paneAppTool = MCPCatalogPaneAppTool(surfaceID: surfaceID, viewID: UUID(), serverID: serverID, name: "widget", definition: appDefinition)

        let result = MCPToolCatalog.build(
            serverTools: [serverID: (alias: alias("srv"), displayName: "srv", tools: [serverTool], clientDeclaredUI: true)],
            paneAppTools: [paneAppTool]
        )

        XCTAssertEqual(result.tools.map { $0.exportedName }, ["srv-app_widget"],
                       "only the server tool's plain exported name must survive the clash (no re-hashed app variant)")
        XCTAssertEqual(result.tools[0].origin, .server, "the server tool wins the exported-name clash")

        let appExclusion = result.exclusions.first(where: { $0.upstreamToolName == "widget" })
        XCTAssertNotNil(appExclusion, "the app tool must be excluded with a reason when its generated exported name clashes with a server tool")
        XCTAssertFalse(appExclusion?.reason.isEmpty ?? true)
    }
}
