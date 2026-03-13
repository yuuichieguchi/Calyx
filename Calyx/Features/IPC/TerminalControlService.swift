//
//  TerminalControlService.swift
//  Calyx
//
//  Service layer bridging the MCP server to the window and tab management layer.
//  Provides pane introspection and split creation for terminal control MCP tools.
//

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "TerminalControlService")

// MARK: - PaneInfo

/// Metadata for a single terminal pane returned by list_panes.
struct PaneInfo: Codable {
    let id: String
    let title: String
    let pwd: String?
    let isFocused: Bool
}

// MARK: - TerminalControlProviding

/// Protocol for terminal control operations. Separate from the concrete implementation
/// to allow mock injection in tests.
@MainActor
protocol TerminalControlProviding: Sendable {
    /// Returns metadata for all panes in the active window.
    func listPanes() -> [PaneInfo]

    /// Creates a new split pane in the specified direction.
    /// - Parameters:
    ///   - direction: The split direction.
    ///   - targetPaneId: The pane to split. Defaults to the focused pane if nil.
    /// - Returns: The UUID of the newly created pane, or nil if creation failed.
    func createSplit(direction: SplitDirection, targetPaneId: UUID?) -> UUID?
}

// MARK: - TerminalControlService

/// Concrete implementation that accesses live app state via the key window.
@MainActor
final class TerminalControlService: TerminalControlProviding {

    // MARK: - TerminalControlProviding

    func listPanes() -> [PaneInfo] {
        guard let wc = keyWindowController(),
              let tab = wc.windowSession.activeGroup?.activeTab else {
            logger.info("listPanes: no key window or active tab")
            return []
        }

        let leafIDs = tab.splitTree.allLeafIDs()
        let focusedID = tab.splitTree.focusedLeafID

        return leafIDs.map { leafID in
            PaneInfo(
                id: leafID.uuidString,
                title: tab.title,
                pwd: tab.pwd,
                isFocused: leafID == focusedID
            )
        }
    }

    func createSplit(direction: SplitDirection, targetPaneId: UUID?) -> UUID? {
        guard let wc = keyWindowController() else {
            logger.error("createSplit: no key window controller")
            return nil
        }
        return wc.createSplit(direction: direction, targetPaneId: targetPaneId)
    }

    // MARK: - Private

    private func keyWindowController() -> CalyxWindowController? {
        NSApp.keyWindow?.windowController as? CalyxWindowController
    }
}
