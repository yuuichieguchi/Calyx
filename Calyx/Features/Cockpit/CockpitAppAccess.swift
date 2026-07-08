// CockpitAppAccess.swift
// Calyx
//
// TDD Red-phase stub: the Cockpit MCP tool boundary's view onto the
// live app -- pane enumeration, pane commands, splitting, tab creation,
// and command-palette execution. `SplitDirection` is deliberately NOT
// redeclared here: Calyx/Models/SplitTree.swift already defines a
// Swift (not C) `SplitDirection` enum (.horizontal/.vertical) used by
// SplitTree.insert(at:direction:) and CalyxWindowController.performSplit
// -- exactly the "cockpit-facing direction type" this boundary needs,
// so it's reused directly rather than introducing a second, colliding
// `right`/`down` type that would just need translating back and forth.
//
// LiveCockpitAppAccess's real implementation (NSApp.delegate ->
// AppDelegate.appSession walk, mirroring pane_list's own) is deferred
// to a later Green phase -- see
// CalyxTests/Cockpit/CockpitAppAccessSeamTests.swift, which instead
// drives the CalyxWindowController seams (performSplit,
// resolveNewTabSpawnCwd, cockpitSendCommand) this type will eventually
// call, since LiveCockpitAppAccess itself has no app to drive in this
// unit-test host.

import AppKit
import Foundation
import GhosttyKit

struct CockpitPaneInfo: Sendable {
    let surfaceID: UUID
    let windowID: UUID
    let groupName: String
    let tabID: UUID
    let tabTitle: String
    let title: String?
    /// The pane's own working directory, from its own OSC 7 report
    /// (`SurfacePropertyStore`). Falls back to the owning tab's `pwd`
    /// ONLY when the tab has exactly one pane (the only case that `pwd`
    /// is unambiguously this pane's own); with multiple panes and no
    /// OSC 7 report of its own yet, `nil` -- on this agent-facing read
    /// path, silently omitting is safer than silently misattributing a
    /// sibling pane's cwd.
    let cwd: String?
    let isFocused: Bool
    let agentKind: String?
    let calyxSessionID: String?
}

struct CockpitNewTab: Sendable {
    let tabID: UUID
    let surfaceID: UUID
    let groupName: String
}

struct CockpitPaletteCommand: Sendable {
    let id: String
    let title: String
    let category: String
    let isAvailable: Bool
}

enum CockpitAccessError: Error, Equatable {
    case appUnavailable
    case paneNotFound(UUID)
    case commandFailed
    case tabCreationFailed
    case paletteCommandNotFound(String)
    case paletteCommandUnavailable(String)
}

/// Pane identity = split-tree leaf membership: `paneExists` and every
/// pane operation below resolve a `surfaceID` the SAME way
/// (`CalyxWindowController.ownsSplitLeaf`/`findTab(bySplitLeaf:)`), the
/// same source of truth `listPanes()` itself enumerates from -- a pane
/// `listPanes()` reports is guaranteed operable by construction, not by
/// two independently-maintained membership checks staying in sync.
@MainActor
protocol CockpitAppAccessing: AnyObject {
    func listPanes() -> [CockpitPaneInfo]
    func paneExists(_ id: UUID) -> Bool
    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws
    func sendKeys(surfaceID: UUID, text: String) throws
    func splitPane(surfaceID: UUID, direction: SplitDirection) throws -> UUID
    func createTab(groupName: String?, cwd: String?) throws -> CockpitNewTab
    func availablePaletteCommands() -> [CockpitPaletteCommand]
    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand
}

/// Live, app-wide implementation. Resolves `NSApp.delegate as? AppDelegate`
/// fresh on every call (never cached as a stored property) since the
/// delegate/its window list can change between two MCP tool calls.
///
/// Not unit-tested this round -- driving it needs a live `AppDelegate`
/// with real windows, which this project's unit-test host cannot safely
/// construct (see CockpitAppAccessSeamTests.swift's header for why the
/// `CalyxWindowController` seams this delegates to are tested directly
/// instead). Covered end-to-end in P6.
@MainActor
final class LiveCockpitAppAccess: CockpitAppAccessing {

    private var appDelegate: AppDelegate? {
        NSApp.delegate as? AppDelegate
    }

    private func keyWindowController(_ appDelegate: AppDelegate) -> CalyxWindowController? {
        appDelegate.allWindowControllers.first { $0.window?.isKeyWindow == true }
    }

    /// The single window controller whose `windowSession` owns
    /// `surfaceID` as a split-tree leaf -- the same membership test
    /// `paneExists`/`listPanes()` use (see `CockpitAppAccessing`'s own
    /// doc comment on why this is the one pane-identity source of
    /// truth). Each surface is a leaf in exactly one tab's `splitTree`
    /// for its whole lifetime, so at most one window ever matches.
    private func owningController(for surfaceID: UUID, in appDelegate: AppDelegate) -> CalyxWindowController? {
        appDelegate.allWindowControllers.first { $0.ownsSplitLeaf(surfaceID) }
    }

    func listPanes() -> [CockpitPaneInfo] {
        guard let appDelegate else { return [] }

        var panes: [CockpitPaneInfo] = []
        for controller in appDelegate.allWindowControllers {
            let windowSession = controller.windowSession
            let isKeyWindow = controller.window?.isKeyWindow ?? false
            for group in windowSession.groups {
                let isActiveGroup = group.id == windowSession.activeGroupID
                for tab in group.tabs {
                    let isActiveTab = tab.id == group.activeTabID
                    let leafIDs = tab.splitTree.allLeafIDs()
                    for leafID in leafIDs {
                        let isFocused = isKeyWindow && isActiveGroup && isActiveTab
                            && leafID == tab.splitTree.focusedLeafID
                        let cwd: String?
                        if let recorded = SurfacePropertyStore.shared.cwd(for: leafID) {
                            cwd = recorded
                        } else if leafIDs.count == 1 {
                            cwd = tab.pwd
                        } else {
                            cwd = nil
                        }
                        panes.append(CockpitPaneInfo(
                            surfaceID: leafID,
                            windowID: windowSession.id,
                            groupName: group.name,
                            tabID: tab.id,
                            tabTitle: tab.title,
                            title: SurfacePropertyStore.shared.title(for: leafID),
                            cwd: cwd,
                            isFocused: isFocused,
                            agentKind: AgentRegistry.shared.entries[leafID]?.kind,
                            calyxSessionID: SessionSurfaceMap.shared.sessionID(for: leafID)
                        ))
                    }
                }
            }
        }
        return panes
    }

    func paneExists(_ id: UUID) -> Bool {
        guard let appDelegate else { return false }
        return owningController(for: id, in: appDelegate) != nil
    }

    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws {
        guard let appDelegate else { throw CockpitAccessError.appUnavailable }
        guard let controller = owningController(for: surfaceID, in: appDelegate) else {
            throw CockpitAccessError.paneNotFound(surfaceID)
        }
        guard controller.cockpitSendCommand(surfaceID: surfaceID, command: command, doubleReturn: doubleReturn) else {
            throw CockpitAccessError.paneNotFound(surfaceID)
        }
    }

    func sendKeys(surfaceID: UUID, text: String) throws {
        guard let appDelegate else { throw CockpitAccessError.appUnavailable }
        guard let controller = owningController(for: surfaceID, in: appDelegate) else {
            throw CockpitAccessError.paneNotFound(surfaceID)
        }
        guard controller.cockpitSendKeys(surfaceID: surfaceID, text: text) else {
            throw CockpitAccessError.paneNotFound(surfaceID)
        }
    }

    func splitPane(surfaceID: UUID, direction: SplitDirection) throws -> UUID {
        guard let appDelegate else { throw CockpitAccessError.appUnavailable }
        guard let app = GhosttyAppController.shared.app else { throw CockpitAccessError.appUnavailable }
        guard let controller = owningController(for: surfaceID, in: appDelegate) else {
            throw CockpitAccessError.paneNotFound(surfaceID)
        }
        guard let newSurfaceID = controller.performSplit(surfaceID: surfaceID, direction: direction, app: app) else {
            throw CockpitAccessError.paneNotFound(surfaceID)
        }
        return newSurfaceID
    }

    func createTab(groupName: String?, cwd: String?) throws -> CockpitNewTab {
        guard let appDelegate else { throw CockpitAccessError.appUnavailable }
        guard let controller = keyWindowController(appDelegate) else { throw CockpitAccessError.appUnavailable }

        let windowSession = controller.windowSession
        let group: TabGroup
        if let groupName {
            if let existing = windowSession.groups.first(where: { $0.name == groupName }) {
                group = existing
            } else {
                let newGroup = TabGroup(name: groupName)
                windowSession.addGroup(newGroup)
                group = newGroup
            }
        } else {
            guard let activeGroup = windowSession.activeGroup else { throw CockpitAccessError.tabCreationFailed }
            group = activeGroup
        }
        windowSession.activeGroupID = group.id

        let tabCountBefore = group.tabs.count
        controller.createNewTab(spawnCwd: cwd)

        guard group.tabs.count > tabCountBefore, let newTab = group.tabs.last else {
            throw CockpitAccessError.tabCreationFailed
        }
        guard let newSurfaceID = newTab.splitTree.allLeafIDs().first else {
            throw CockpitAccessError.tabCreationFailed
        }

        return CockpitNewTab(tabID: newTab.id, surfaceID: newSurfaceID, groupName: group.name)
    }

    func availablePaletteCommands() -> [CockpitPaletteCommand] {
        guard let appDelegate, let controller = keyWindowController(appDelegate) else { return [] }
        return controller.commandRegistry.allCommands.map {
            CockpitPaletteCommand(id: $0.id, title: $0.title, category: $0.category, isAvailable: $0.isAvailable())
        }
    }

    /// Unlike `CommandPaletteView.executeSelected()` (which relies on
    /// `search(query:)` having already filtered unavailable commands out
    /// before the user could select one), an MCP caller can name any
    /// command id directly with no such filter upstream -- gates on
    /// `isAvailable()` via `cockpitExecutePaletteCommand`, throwing
    /// `.paletteCommandUnavailable` rather than ever running a handler
    /// with unmet preconditions (crash risk). P5 re-checks again after
    /// the human-approval gate; this base layer must never execute an
    /// unavailable handler regardless.
    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand {
        guard let appDelegate else { throw CockpitAccessError.appUnavailable }
        guard let controller = keyWindowController(appDelegate) else { throw CockpitAccessError.appUnavailable }
        guard let (command, executed) = controller.cockpitExecutePaletteCommand(id: id) else {
            throw CockpitAccessError.paletteCommandNotFound(id)
        }
        guard executed else {
            throw CockpitAccessError.paletteCommandUnavailable(id)
        }

        return CockpitPaletteCommand(id: command.id, title: command.title, category: command.category, isAvailable: command.isAvailable())
    }
}
