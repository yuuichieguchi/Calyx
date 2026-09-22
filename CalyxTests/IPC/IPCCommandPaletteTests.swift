//
//  IPCCommandPaletteTests.swift
//  CalyxTests
//
//  The three IPC palette commands were removed entirely: `ipc.enable`
//  (logically unreachable from an agent, since MCPCockpitBridge's
//  palette_execute only runs inside CalyxMCPServer, which cannot be
//  running yet for this command to matter), `ipc.reconfigure` (lets an
//  agent rewrite the user's own CLI configs unattended), and
//  `ipc.disable` (an agent cutting its own connection). AI Agent IPC is
//  now a persistent Settings > Agents toggle (SettingsRow.agentIPC)
//  instead of a one-shot palette action, so none of the three commands
//  -- their registration, their titles, or their availability gates --
//  exist anymore. This file now pins their ABSENCE.
//
//  showIPCAlert (CalyxWindowController.swift:5944) is NOT removed: two
//  of its four call sites (:5839, :5873) belong to the review-send flow,
//  independent of IPC enable/disable. It stays `private`, so it is not
//  reachable through `@testable import` from this file and cannot be
//  pinned here -- its survival is a production-code fact for code
//  review, not a testable one.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class IPCCommandPaletteTests: XCTestCase {

    /// Minimal controller for direct registry inspection, mirroring
    /// `SessionCommandPaletteTests.makeController()`. `restoring: true`
    /// skips `setupTerminalSurface()`, which needs a live Ghostty app
    /// instance; `setupCommandRegistry()` runs regardless of `restoring`.
    private func makeController() -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    // MARK: - The three IPC palette commands must not be registered

    func test_ipcEnableCommand_isNotRegistered() {
        let controller = makeController()

        XCTAssertNil(controller.commandRegistry.allCommands.first(where: { $0.id == "ipc.enable" }),
                     "ipc.enable must no longer be registered -- IPC is now a persistent Settings toggle, not " +
                     "a palette action an agent could invoke on itself")
    }

    func test_ipcReconfigureCommand_isNotRegistered() {
        let controller = makeController()

        XCTAssertNil(controller.commandRegistry.allCommands.first(where: { $0.id == "ipc.reconfigure" }),
                     "ipc.reconfigure must no longer be registered -- it let an agent rewrite the user's own " +
                     "CLI configs unattended")
    }

    func test_ipcDisableCommand_isNotRegistered() {
        let controller = makeController()

        XCTAssertNil(controller.commandRegistry.allCommands.first(where: { $0.id == "ipc.disable" }),
                     "ipc.disable must no longer be registered -- an agent could use it to cut its own connection")
    }

    func test_noCommandInIPCCategory_remainsRegistered() {
        let controller = makeController()

        let ipcCategoryCommands = controller.commandRegistry.allCommands.filter { $0.category == "IPC" }

        XCTAssertTrue(ipcCategoryCommands.isEmpty,
                      "The entire \"IPC\" palette category must be empty once all three commands are removed")
    }
}
