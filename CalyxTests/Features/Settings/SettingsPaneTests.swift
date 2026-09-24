//
//  SettingsPaneTests.swift
//  CalyxTests
//
//  Covers the tabbed Settings window restructure: SettingsPane and
//  SettingsRow, the row -> pane model the restructure is built on.
//
//  WHY A ROW -> PANE MODEL: SettingsWindowController.swift currently
//  builds one long NSStackView with 14 UI elements (3 theme-color rows,
//  1 glass row, 1 scrolling row, 2 LSP rows, 5 session-toggle rows, 1
//  session-browser button, 1 open-config-file/help footer) with no seam
//  for grouping them into panes. SettingsRow enumerates every one of
//  those 14 elements explicitly and pins its target pane, so the tab
//  restructure cannot silently drop a setting in the shuffle -- the
//  regression risk the user flagged from the screenshot review.
//
//  FOOTER PLACEMENT (Appearance, not repeated on every pane): the Open
//  Config File + help footer edits ghostty's config file, and the help
//  popover it opens (GhosttyConfigManager.managedKeys) lists exactly
//  background-opacity, background-blur, background-opacity-cells,
//  font-codepoint-map, and foreground -- all glass/theme-color keys,
//  none LSP- or session-related. The footer's content is entirely about
//  what the Appearance pane manages, so that is its natural home.
//
//  PANE ORDER: Appearance, Sessions, LSP -- the order the user's own
//  restructure request listed them in. Agents (a user-directed
//  information-architecture fix) was inserted right after
//  Sessions: its rows (agentResume/agentResumeAutoExecute/
//  cockpitAutoApprove/commandTracking) all moved out of Sessions, which
//  had become a dumping ground with mismatched section typography (only
//  "Command Tracking" carried a full SectionHeading -- user-flagged).
//
//  STAGE E (approval-inbox-for-CLI-agents, two-scope Always-Allow
//  session memory): a new `agentHookApproval` row lands on the Agents
//  pane, right after `commandTracking` in SettingsRow's declared order --
//  it toggles CockpitSettings.agentHookApprovalEnabled, gating
//  CalyxMCPServer's POST /approval-request endpoint (see that setting's
//  own doc comment). expectedRows below is extended the same way
//  cockpitAutoApprove/commandTracking each were before it (see this
//  repo's own history on this file).
//
//  MCP APPS HOST: a new MCP Servers pane follows Agents (plan section 11,
//  contract v2 section 13), holding a single `mcpServers` row that hosts
//  the whole pane.
//
//  ICON COVERAGE (user-reported defect): the Settings
//  toolbar's tabStyle (.toolbar, SettingsWindowController.setupContent())
//  renders a degenerate fat header with sunk text when a tab item has no
//  icon -- NSTabViewController's toolbar style expects one. SettingsPane
//  gains an `icon` (SF Symbol name), pinned below. The
//  NSTabViewItem.image/window-title
//  wiring itself is not covered here (see AppDelegateAttachPlaceholderTitleTests's
//  sibling investigation note for why).
//

import XCTest
import AppKit
@testable import Calyx

final class SettingsPaneTests: XCTestCase {

    // MARK: - Pane identity, order, titles

    func test_settingsPane_orderIsAppearanceThenSessionsThenAgentsThenMCPServersThenLSP() {
        XCTAssertEqual(SettingsPane.allCases, [.appearance, .sessions, .agents, .mcpServers, .lsp],
                       "Pane order must match the user's requested restructure order -- Agents sits right " +
                       "after Sessions, since its rows moved out of that pane, and MCP Servers right after Agents")
    }

    func test_settingsPane_titles() {
        XCTAssertEqual(SettingsPane.appearance.title, "Appearance")
        XCTAssertEqual(SettingsPane.sessions.title, "Sessions")
        XCTAssertEqual(SettingsPane.agents.title, "Agents")
        XCTAssertEqual(SettingsPane.mcpServers.title, "MCP Servers")
        XCTAssertEqual(SettingsPane.lsp.title, "LSP")
    }

    // MARK: - Every existing setting row survives the shuffle

    // Hand-enumerated from SettingsWindowController.setupContent()'s
    // current vertical layout, in on-screen order. If a future edit
    // deletes a case, SettingsRow(rawValue:) below returns nil and the
    // test fails naming the missing row -- it is not enough for the
    // remaining mappings to merely pass.
    private static let expectedRows: [(rawValue: String, pane: SettingsPane)] = [
        ("themeColorPreset", .appearance),
        ("themeColorWell", .appearance),
        ("themeColorHex", .appearance),
        ("glassOpacity", .appearance),
        ("glassOpacityCells", .appearance),
        ("smoothScrolling", .appearance),
        ("lspAutoInstall", .lsp),
        ("lspRequireConfirmation", .lsp),
        ("persistentSessions", .sessions),
        ("historyPersistence", .sessions),
        ("agentIPC", .agents),
        ("agentResume", .agents),
        ("agentResumeAutoExecute", .agents),
        ("cockpitAutoApprove", .agents),
        ("commandTracking", .agents),
        ("agentHookApproval", .agents),
        ("mcpServers", .mcpServers),
        ("openSessionBrowserButton", .sessions),
        ("openConfigFileFooter", .appearance),
    ]

    func test_everyPreShuffleSettingRow_stillExistsAndMapsToItsExpectedPane() {
        for (rawValue, expectedPane) in Self.expectedRows {
            guard let row = SettingsRow(rawValue: rawValue) else {
                XCTFail("SettingsRow is missing a case for '\(rawValue)' -- " +
                        "a setting from the pre-tab layout was dropped")
                continue
            }
            XCTAssertEqual(row.pane, expectedPane,
                           "\(rawValue) must belong to \(expectedPane), not \(row.pane)")
        }
    }

    func test_settingsRow_hasExactlyTheExpectedCaseCount() {
        XCTAssertEqual(SettingsRow.allCases.count, Self.expectedRows.count,
                       "SettingsRow gained or lost a case without updating this pin's " +
                       "expectedRows -- update it deliberately, not by coincidence")
    }

    // MARK: - Pane icons (toolbar tabStyle requires one per tab item)

    func test_settingsPane_iconSymbolNames() {
        XCTAssertEqual(SettingsPane.appearance.icon, "paintbrush")
        XCTAssertEqual(SettingsPane.sessions.icon, "terminal")
        XCTAssertEqual(SettingsPane.agents.icon, "sparkles")
        XCTAssertEqual(SettingsPane.mcpServers.icon, "server.rack")
        XCTAssertEqual(SettingsPane.lsp.icon, "gearshape.2")
    }

    func test_settingsPane_icon_resolvesToARealSFSymbolOnThisDeploymentTarget() {
        for pane in SettingsPane.allCases {
            let image = NSImage(systemSymbolName: pane.icon, accessibilityDescription: nil)
            XCTAssertNotNil(
                image,
                "SF Symbol \"\(pane.icon)\" for \(pane) must resolve to a real NSImage on this " +
                "deployment target, or the toolbar tab item ends up with no icon again"
            )
        }
    }
}
