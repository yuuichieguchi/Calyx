//
//  SettingsPaneAlignmentTests.swift
//  CalyxTests
//
//  The MCP Apps pane is laid out exactly like the Agents pane: in the
//  real Settings window, its heading starts at the same point as the AI
//  Agent IPC heading, and the gaps between heading, description, first
//  control row, switch row, status text and buttons are the gaps the AI
//  Agent IPC section has. Every value is measured in window coordinates
//  on both panes, never assumed.
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
private final class AlignmentNoOpSettingsActions: MCPServerSettingsActions {
    func retry(serverID: MCPServerID) async throws {}
    func signIn(serverID: MCPServerID) async throws {}
    func signOut(serverID: MCPServerID) async throws {}
    func authState(for serverID: MCPServerID) async throws -> MCPServerAuthState { .notRequired }
}

@MainActor
final class SettingsPaneAlignmentTests: XCTestCase {

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

    /// Positions measured on one pane, in the window's content view with
    /// y growing downward from the top of the content, so panes of
    /// different heights compare directly.
    private struct Measurement {
        let headingX: CGFloat
        let headingTop: CGFloat
        let headingToDescription: CGFloat
        let descriptionToFirstControlRow: CGFloat
        let buttonX: CGFloat
        /// From the element above the switch row to the switch row.
        let aboveSwitchRow: CGFloat
        /// From the switch row to the status text.
        let switchRowToStatus: CGFloat
        /// From the status text to the button row.
        let statusToButtons: CGFloat
    }

    // MARK: - View lookup

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

    private func label(in root: NSView, text: String) -> NSTextField? {
        if let field = root as? NSTextField, field.stringValue == text {
            return field
        }
        for subview in root.subviews {
            if let found = label(in: subview, text: text) {
                return found
            }
        }
        return nil
    }

    // MARK: - Geometry

    /// `view`'s frame in the window's content view, flipped so `minY` is
    /// the distance from the top of the content.
    private func topDownFrame(_ view: NSView, in window: NSWindow) throws -> CGRect {
        let contentView = try XCTUnwrap(window.contentView)
        let rect = view.convert(view.bounds, to: contentView)
        let height = contentView.bounds.height
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    private func select(_ pane: SettingsPane, in window: NSWindow) throws -> NSView {
        let tabViewController = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        let index = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: pane))
        tabViewController.selectedTabViewItemIndex = index
        let paneView = try XCTUnwrap(tabViewController.tabViewItems[index].viewController?.view)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        return paneView
    }

    // MARK: - Test

    func test_mcpAppsPane_isLaidOutLikeTheAgentsPane() async throws {
        let controller = SettingsWindowController.shared
        let window = try XCTUnwrap(controller.window)

        // Agents pane: the AI Agent IPC section.
        let agentsPane = try select(.agents, in: window)
        let ipcStatus = try XCTUnwrap(
            view(in: agentsPane, identifier: AccessibilityID.Settings.agentIPCStatusLabel) as? NSTextField
        )
        // The status line only shows while IPC reports a state; give it
        // the running text so the switch -> status -> Refresh gaps exist.
        ipcStatus.isHidden = false
        ipcStatus.attributedStringValue = SettingsLayout.statusText("Running on port 41000\n3 agents connected")
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        let agentsHeading = try XCTUnwrap(label(in: agentsPane, text: "AI Agent IPC"))
        let agentsDescription = try XCTUnwrap(label(in: agentsPane, text: "Connects installed agent CLIs to Calyx over MCP."))
        let ipcSwitch = try XCTUnwrap(view(in: agentsPane, identifier: AccessibilityID.Settings.agentIPCSwitch))
        let ipcSwitchRow = try XCTUnwrap(ipcSwitch.superview)
        let refresh = try XCTUnwrap(view(in: agentsPane, identifier: AccessibilityID.Settings.agentIPCRefreshButton))
        let refreshRow = try XCTUnwrap(refresh.superview)

        let aHeading = try topDownFrame(agentsHeading, in: window)
        let aDescription = try topDownFrame(agentsDescription, in: window)
        let aSwitchRow = try topDownFrame(ipcSwitchRow, in: window)
        let aSwitch = try topDownFrame(ipcSwitch, in: window)
        let aStatus = try topDownFrame(ipcStatus, in: window)
        let aRefresh = try topDownFrame(refresh, in: window)
        let aRefreshRow = try topDownFrame(refreshRow, in: window)
        let agents = Measurement(
            headingX: aHeading.minX,
            headingTop: aHeading.minY,
            headingToDescription: aDescription.minY - aHeading.maxY,
            descriptionToFirstControlRow: aSwitchRow.minY - aDescription.maxY,
            buttonX: aRefresh.minX,
            aboveSwitchRow: aSwitch.minY - aDescription.maxY,
            switchRowToStatus: aStatus.minY - aSwitch.maxY,
            statusToButtons: aRefreshRow.minY - aStatus.maxY
        )

        // MCP Apps pane with one stdio server.
        let directory = try XCTUnwrap(registryDirectory)
        let registry = MCPServerRegistry(directory: directory.path, secretStore: InMemoryMCPSecretStore())
        let serverID = MCPServerID()
        try await registry.add(MCPServerConfig(
            id: serverID,
            alias: try XCTUnwrap(MCPServerAlias(rawValue: "fixture")),
            displayName: "fixture",
            isEnabled: false,
            transport: .stdio(command: "/bin/cat", args: [], envNames: [], cwd: nil),
            auth: nil
        ))
        SettingsWindowController.configureMCPServers(MCPServerSettingsModel.Dependencies(
            registry: registry,
            connections: FakeConnectionLookup(),
            catalog: FakeCatalogProviding(),
            secretStore: InMemoryMCPSecretStore(),
            actions: AlignmentNoOpSettingsActions()
        ))
        let mcpPane = try select(.mcpServers, in: window)
        let rowSwitchID = AccessibilityID.MCPServersSettings.rowEnabledSwitch(serverID.rawValue)
        let deadline = Date().addingTimeInterval(5)
        while view(in: mcpPane, identifier: rowSwitchID) == nil {
            guard Date() < deadline else {
                XCTFail("the server row never appeared in the MCP Apps pane")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()

        let mcpHeading = try XCTUnwrap(label(in: mcpPane, text: "MCP Apps"))
        let mcpDescription = try XCTUnwrap(label(
            in: mcpPane, text: "MCP servers whose tools show interactive apps next to the agent that calls them."
        ))
        let addButton = try XCTUnwrap(view(in: mcpPane, identifier: AccessibilityID.MCPServersSettings.addButton))
        let addRow = try XCTUnwrap(addButton.superview)
        let rowSwitch = try XCTUnwrap(view(in: mcpPane, identifier: rowSwitchID))
        let rowStatus = try XCTUnwrap(view(in: mcpPane, identifier: AccessibilityID.MCPServersSettings.rowStatus(serverID.rawValue)))
        let editButton = try XCTUnwrap(view(in: mcpPane, identifier: AccessibilityID.MCPServersSettings.rowEditButton(serverID.rawValue)))
        let rowButtons = try XCTUnwrap(editButton.superview)

        let mHeading = try topDownFrame(mcpHeading, in: window)
        let mDescription = try topDownFrame(mcpDescription, in: window)
        let mAddRow = try topDownFrame(addRow, in: window)
        let mAdd = try topDownFrame(addButton, in: window)
        let mSwitch = try topDownFrame(rowSwitch, in: window)
        let mStatus = try topDownFrame(rowStatus, in: window)
        let mRowButtons = try topDownFrame(rowButtons, in: window)
        let mcp = Measurement(
            headingX: mHeading.minX,
            headingTop: mHeading.minY,
            headingToDescription: mDescription.minY - mHeading.maxY,
            descriptionToFirstControlRow: mAddRow.minY - mDescription.maxY,
            buttonX: mAdd.minX,
            aboveSwitchRow: mSwitch.minY - mAddRow.maxY,
            switchRowToStatus: mStatus.minY - mSwitch.maxY,
            statusToButtons: mRowButtons.minY - mStatus.maxY
        )

        print("SettingsPaneAlignment agents=\(agents)")
        print("SettingsPaneAlignment mcp=\(mcp)")
        print("SettingsPaneAlignment agentsFrames heading=\(aHeading) description=\(aDescription) switchRow=\(aSwitchRow) switch=\(aSwitch) status=\(aStatus) refreshRow=\(aRefreshRow) refresh=\(aRefresh)")
        print("SettingsPaneAlignment mcpFrames heading=\(mHeading) description=\(mDescription) addRow=\(mAddRow) add=\(mAdd) switch=\(mSwitch) status=\(mStatus) rowButtons=\(mRowButtons)")

        XCTAssertEqual(mcp.headingX, agents.headingX, accuracy: 0.5, "heading x")
        XCTAssertEqual(mcp.headingTop, agents.headingTop, accuracy: 0.5, "heading y")
        XCTAssertEqual(mcp.headingToDescription, agents.headingToDescription, accuracy: 0.5, "heading -> description")
        XCTAssertEqual(mcp.descriptionToFirstControlRow, agents.descriptionToFirstControlRow, accuracy: 0.5, "description -> first control row")
        XCTAssertEqual(mcp.buttonX, agents.buttonX, accuracy: 0.5, "button x")
        XCTAssertEqual(mcp.aboveSwitchRow, agents.aboveSwitchRow, accuracy: 0.5, "element above -> switch")
        XCTAssertEqual(mcp.switchRowToStatus, agents.switchRowToStatus, accuracy: 0.5, "switch -> status")
        XCTAssertEqual(mcp.statusToButtons, agents.statusToButtons, accuracy: 0.5, "status -> buttons")
    }
}
