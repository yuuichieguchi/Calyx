//
//  MCPLiveAppToolRegistryTests.swift
//  CalyxTests
//
//  `MCPLiveAppToolRegistry` (contract section 13a.1): the app tools each
//  view registered, listed per pane, and a `changes` stream that yields
//  the pane's surfaceID on every registration and removal.
//

import XCTest
@testable import Calyx

@MainActor
final class MCPLiveAppToolRegistryTests: XCTestCase {

    private func tool(_ name: String) throws -> MCPToolDefinition {
        try MCPToolDefinition(raw: [
            "name": AnyCodable(name),
            "inputSchema": AnyCodable(["type": AnyCodable("object")]),
        ])
    }

    func test_register_listsTheToolsUnderThePane() throws {
        let registry = MCPLiveAppToolRegistry()
        let serverID = MCPServerID()
        let pane = UUID()
        let otherPane = UUID()

        registry.registerAppTools([try tool("pick_color"), try tool("pick_size")], forSurface: pane, viewID: UUID(), serverID: serverID)

        XCTAssertEqual(registry.appTools(forSurface: pane).map(\.name), ["pick_color", "pick_size"])
        XCTAssertEqual(registry.appTools(forSurface: pane).map(\.serverID), [serverID, serverID])
        XCTAssertEqual(registry.appTools(forSurface: pane).map(\.surfaceID), [pane, pane])
        XCTAssertTrue(registry.appTools(forSurface: otherPane).isEmpty)
    }

    func test_registerAgain_replacesTheViewsTools() throws {
        let registry = MCPLiveAppToolRegistry()
        let pane = UUID()
        let viewID = UUID()

        registry.registerAppTools([try tool("pick_color")], forSurface: pane, viewID: viewID, serverID: MCPServerID())
        registry.registerAppTools([try tool("pick_size")], forSurface: pane, viewID: viewID, serverID: MCPServerID())

        XCTAssertEqual(registry.appTools(forSurface: pane).map(\.name), ["pick_size"])
    }

    func test_unregister_removesOnlyThatViewsTools() throws {
        let registry = MCPLiveAppToolRegistry()
        let pane = UUID()
        let removedView = UUID()

        registry.registerAppTools([try tool("pick_color")], forSurface: pane, viewID: removedView, serverID: MCPServerID())
        registry.registerAppTools([try tool("pick_size")], forSurface: pane, viewID: UUID(), serverID: MCPServerID())
        registry.unregisterAppTools(forView: removedView)

        XCTAssertEqual(registry.appTools(forSurface: pane).map(\.name), ["pick_size"])
    }

    func test_changes_yieldsThePaneOnRegistrationAndRemoval() async throws {
        let registry = MCPLiveAppToolRegistry()
        let paneA = UUID()
        let paneB = UUID()
        let viewA = UUID()
        var changes = registry.changes.makeAsyncIterator()

        registry.registerAppTools([try tool("pick_color")], forSurface: paneA, viewID: viewA, serverID: MCPServerID())
        registry.registerAppTools([try tool("pick_size")], forSurface: paneB, viewID: UUID(), serverID: MCPServerID())
        registry.unregisterAppTools(forView: viewA)

        let first = await changes.next()
        let second = await changes.next()
        let third = await changes.next()
        XCTAssertEqual([first, second, third], [paneA, paneB, paneA])
    }

    func test_unregister_unknownView_yieldsNothing() async throws {
        let registry = MCPLiveAppToolRegistry()
        let pane = UUID()
        var changes = registry.changes.makeAsyncIterator()

        registry.unregisterAppTools(forView: UUID())
        registry.registerAppTools([try tool("pick_color")], forSurface: pane, viewID: UUID(), serverID: MCPServerID())

        let first = await changes.next()
        XCTAssertEqual(first, pane, "removing a view that registered nothing changes no pane")
    }
}
