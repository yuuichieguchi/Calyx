//
//  MCPServersSettingsViewTests.swift
//  CalyxTests
//
//  `MCPServersSettingsView` (Settings > MCP Apps) follows its model: the
//  empty state while no server is registered, then the server list once
//  one is added, each change reported through `onContentChange` so the
//  pane can measure its height again. A server row starts with its name
//  and enable switch.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
private final class NoOpSettingsActions: MCPServerSettingsActions {
    func retry(serverID: MCPServerID) async throws {}
    func signIn(serverID: MCPServerID) async throws {}
    func signOut(serverID: MCPServerID) async throws {}
    func authState(for serverID: MCPServerID) async throws -> MCPServerAuthState { .notRequired }
}

@MainActor
final class MCPServersSettingsViewTests: XCTestCase {

    private var registryDirectory: URL?

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registryDirectory = directory
    }

    override func tearDown() async throws {
        if let registryDirectory {
            try FileManager.default.removeItem(at: registryDirectory)
        }
    }

    private func view(in root: NSView, identifier: String) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let found = view(in: subview, identifier: identifier) {
                return found
            }
        }
        return nil
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else {
                return XCTFail("\(what) never happened within \(timeout)s")
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_emptyStateThenList_followTheRegistry_andReportEachChange() async throws {
        let directory = try XCTUnwrap(registryDirectory)
        let registry = MCPServerRegistry(directory: directory.path, secretStore: InMemoryMCPSecretStore())
        let model = MCPServerSettingsModel()
        model.configure(MCPServerSettingsModel.Dependencies(
            registry: registry,
            connections: FakeConnectionLookup(),
            catalog: FakeCatalogProviding(),
            secretStore: InMemoryMCPSecretStore(),
            actions: NoOpSettingsActions()
        ))
        var contentChanges = 0
        let settingsView = MCPServersSettingsView(model: model) { contentChanges += 1 }

        let emptyState = try XCTUnwrap(view(in: settingsView, identifier: AccessibilityID.MCPServersSettings.emptyState))
        XCTAssertTrue(emptyState.isAccessibilityElement(), "the empty state must be a group XCUITest can find by identifier")
        XCTAssertNotNil(view(in: settingsView, identifier: AccessibilityID.MCPServersSettings.addButton))
        XCTAssertNil(view(in: settingsView, identifier: AccessibilityID.MCPServersSettings.list))

        let serverID = MCPServerID()
        try await registry.add(MCPServerConfig(
            id: serverID,
            alias: try XCTUnwrap(MCPServerAlias(rawValue: "weather")),
            displayName: "Weather",
            isEnabled: false,
            transport: .stdio(command: "/bin/cat", args: [], envNames: [], cwd: nil),
            auth: nil
        ))

        try await waitUntil("the server list appearing") {
            view(in: settingsView, identifier: AccessibilityID.MCPServersSettings.list) != nil
        }
        XCTAssertNil(view(in: settingsView, identifier: AccessibilityID.MCPServersSettings.emptyState))
        XCTAssertGreaterThan(contentChanges, 0, "a rebuild must be reported so the pane measures its height again")

        let enabledSwitch = try XCTUnwrap(view(
            in: settingsView, identifier: AccessibilityID.MCPServersSettings.rowEnabledSwitch(serverID.rawValue)
        ) as? NSSwitch)
        XCTAssertEqual(enabledSwitch.state, .off)
        let nameRow = try XCTUnwrap(enabledSwitch.superview as? NSStackView)
        let row = try XCTUnwrap(nameRow.superview as? NSStackView)
        XCTAssertTrue(row.arrangedSubviews.first === nameRow, "a row starts with the name and its enable switch")
        XCTAssertEqual(row.spacing, SettingsLayout.itemSpacing)
        let status = try XCTUnwrap(view(
            in: settingsView, identifier: AccessibilityID.MCPServersSettings.rowStatus(serverID.rawValue)
        ) as? NSTextField)
        XCTAssertTrue(row.arrangedSubviews.dropFirst().first === status, "the status follows the name")
        XCTAssertTrue(status.stringValue.hasPrefix("Disabled\nweather · stdio · /bin/cat"))
    }
}
