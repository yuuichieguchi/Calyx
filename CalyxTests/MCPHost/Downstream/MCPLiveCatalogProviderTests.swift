//
//  MCPLiveCatalogProviderTests.swift
//  CalyxTests
//
//  `MCPLiveCatalogProvider` (contract section 13a.1): the catalog of the
//  registry's enabled servers, each server's tools read from its
//  connection and named under its alias, plus the app tools of the
//  calling pane only. `resolve(exportedName:surfaceID:)` looks names up
//  in that pane's catalog, so another pane's app tool never resolves.
//

import XCTest
@testable import Calyx

@MainActor
final class MCPLiveCatalogProviderTests: XCTestCase {

    private func tool(_ name: String) throws -> MCPToolDefinition {
        try MCPToolDefinition(raw: [
            "name": AnyCodable(name),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
        ])
    }

    private func config(alias: String, displayName: String, isEnabled: Bool = true) throws -> MCPServerConfig {
        MCPServerConfig(
            id: MCPServerID(),
            alias: try XCTUnwrap(MCPServerAlias(rawValue: alias)),
            displayName: displayName,
            isEnabled: isEnabled,
            transport: .stdio(command: "/usr/bin/tool", args: [], envNames: [], cwd: nil),
            auth: nil
        )
    }

    private func makeRegistry(_ configs: [MCPServerConfig]) throws -> MCPServerRegistry {
        let registryDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: registryDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: registryDir) }
        let registry = MCPServerRegistry(directory: registryDir, secretStore: InMemoryMCPSecretStore())
        for config in configs {
            try registry.add(config)
        }
        return registry
    }

    private func connection(for config: MCPServerConfig, tools: [MCPToolDefinition]) -> FakeUpstreamConnection {
        FakeUpstreamConnection(serverID: config.id, initialTools: tools)
    }

    func test_currentCatalog_namesEachServerToolUnderItsAlias() async throws {
        let weather = try config(alias: "weather", displayName: "Weather Service")
        let registry = try makeRegistry([weather])
        let provider = MCPLiveCatalogProvider(
            registry: registry,
            connections: FakeConnectionLookup([weather.id: connection(for: weather, tools: [try tool("get_forecast")])]),
            appToolRegistry: RouterFakeAppToolRegistry()
        )

        let catalog = await provider.currentCatalog(clientDeclaredUI: false, surfaceID: nil)

        XCTAssertEqual(catalog.tools.map(\.exportedName), ["weather-get_forecast"])
        XCTAssertEqual(catalog.tools.first?.serverID, weather.id)
        XCTAssertEqual(catalog.tools.first?.serverDisplayName, "Weather Service")
        XCTAssertEqual(catalog.tools.first?.upstreamToolName, "get_forecast")
    }

    func test_currentCatalog_leavesOutADisabledServer() async throws {
        let enabled = try config(alias: "weather", displayName: "Weather Service")
        let disabled = try config(alias: "tickets", displayName: "Tickets", isEnabled: false)
        let registry = try makeRegistry([enabled, disabled])
        let provider = MCPLiveCatalogProvider(
            registry: registry,
            connections: FakeConnectionLookup([
                enabled.id: connection(for: enabled, tools: [try tool("get_forecast")]),
                disabled.id: connection(for: disabled, tools: [try tool("open_ticket")]),
            ]),
            appToolRegistry: RouterFakeAppToolRegistry()
        )

        let catalog = await provider.currentCatalog(clientDeclaredUI: false, surfaceID: nil)

        XCTAssertEqual(catalog.tools.map(\.exportedName), ["weather-get_forecast"])
    }

    func test_currentCatalog_reportsTheServersExclusions() async throws {
        let weather = try config(alias: "weather", displayName: "Weather Service")
        let registry = try makeRegistry([weather])
        let provider = MCPLiveCatalogProvider(
            registry: registry,
            connections: FakeConnectionLookup([
                weather.id: connection(for: weather, tools: [try tool("get_forecast"), try tool("get_forecast")]),
            ]),
            appToolRegistry: RouterFakeAppToolRegistry()
        )

        let catalog = await provider.currentCatalog(clientDeclaredUI: true, surfaceID: nil)

        XCTAssertEqual(catalog.tools.map(\.exportedName), ["weather-get_forecast"])
        XCTAssertEqual(catalog.exclusions.map(\.serverID), [weather.id])
        XCTAssertEqual(catalog.exclusions.map(\.upstreamToolName), ["get_forecast"])
    }

    func test_currentCatalog_includesOnlyTheCallingPanesAppTools() async throws {
        let weather = try config(alias: "weather", displayName: "Weather Service")
        let registry = try makeRegistry([weather])
        let paneA = UUID()
        let paneB = UUID()
        let appTools = RouterFakeAppToolRegistry()
        appTools.setAppTools([MCPCatalogPaneAppTool(surfaceID: paneA, serverID: weather.id, name: "pick_color", definition: try tool("pick_color"))], forSurface: paneA)
        appTools.setAppTools([MCPCatalogPaneAppTool(surfaceID: paneB, serverID: weather.id, name: "pick_size", definition: try tool("pick_size"))], forSurface: paneB)
        let provider = MCPLiveCatalogProvider(
            registry: registry,
            connections: FakeConnectionLookup([weather.id: connection(for: weather, tools: [try tool("get_forecast")])]),
            appToolRegistry: appTools
        )

        let paneACatalog = await provider.currentCatalog(clientDeclaredUI: false, surfaceID: paneA)
        let paneLessCatalog = await provider.currentCatalog(clientDeclaredUI: false, surfaceID: nil)

        XCTAssertEqual(paneACatalog.tools.map(\.exportedName), ["weather-get_forecast", "weather-app_pick_color"])
        XCTAssertEqual(paneACatalog.tools.last?.origin, .app(surfaceID: paneA))
        XCTAssertEqual(paneLessCatalog.tools.map(\.exportedName), ["weather-get_forecast"], "a caller without a pane sees no app tools")
    }

    func test_resolve_findsAServerToolAndTheOwnPanesAppTool_butNotAnotherPanesAppTool() async throws {
        let weather = try config(alias: "weather", displayName: "Weather Service")
        let registry = try makeRegistry([weather])
        let paneA = UUID()
        let paneB = UUID()
        let appTools = RouterFakeAppToolRegistry()
        appTools.setAppTools([MCPCatalogPaneAppTool(surfaceID: paneA, serverID: weather.id, name: "pick_color", definition: try tool("pick_color"))], forSurface: paneA)
        let provider = MCPLiveCatalogProvider(
            registry: registry,
            connections: FakeConnectionLookup([weather.id: connection(for: weather, tools: [try tool("get_forecast")])]),
            appToolRegistry: appTools
        )

        let serverTool = await provider.resolve(exportedName: "weather-get_forecast", surfaceID: paneB)
        let ownAppTool = await provider.resolve(exportedName: "weather-app_pick_color", surfaceID: paneA)
        let otherPanesAppTool = await provider.resolve(exportedName: "weather-app_pick_color", surfaceID: paneB)

        XCTAssertEqual(serverTool?.upstreamToolName, "get_forecast")
        XCTAssertEqual(ownAppTool?.origin, .app(surfaceID: paneA))
        XCTAssertNil(otherPanesAppTool, "an app tool is offered only to the agent of the pane that owns the view")
    }

    func test_resolve_findsAnAppOnlyServerTool_soTheRouterCanRejectIt() async throws {
        let weather = try config(alias: "weather", displayName: "Weather Service")
        let registry = try makeRegistry([weather])
        let appOnly = try MCPToolDefinition(raw: [
            "name": AnyCodable("refresh_card"),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
            "_meta": AnyCodable(["ui": AnyCodable(["visibility": AnyCodable([AnyCodable("app")])])]),
        ])
        let provider = MCPLiveCatalogProvider(
            registry: registry,
            connections: FakeConnectionLookup([weather.id: connection(for: weather, tools: [appOnly])]),
            appToolRegistry: RouterFakeAppToolRegistry()
        )

        let resolved = await provider.resolve(exportedName: "weather-refresh_card", surfaceID: nil)

        XCTAssertEqual(resolved?.definition.visibility, [.app])
    }
}
