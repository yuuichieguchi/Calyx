//
//  SettingsWindowControllerTabIconTests.swift
//  CalyxTests
//
//  TDD Red phase for a user-reported defect (screenshot review): the
//  Settings window's toolbar tabStyle (NSTabViewController, tabStyle =
//  .toolbar, SettingsWindowController.setupContent()) renders a
//  degenerate fat header with sunk-looking text instead of proper
//  toolbar tab buttons. A toolbar-style NSTabViewController expects each
//  NSTabViewItem to carry an `image`; SettingsWindowController currently
//  only sets `tabItem.label`, never `tabItem.image`, for every pane.
//
//  TESTABILITY: SettingsWindowController.shared is a real singleton
//  (private init, real NSWindow/NSTabViewController/NSStackViews) with
//  no dedicated test file before this one, so this file investigates
//  it directly rather than assuming it is unsafe. Construction itself
//  (loadPresetIntoUI, per-pane NSStackViews) only reads UserDefaults and
//  plain Sendable settings structs (LSPSettings, SessionSettings,
//  ThemeColorPreset) -- no ghostty FFI, no network, no `showWindow`. The
//  window's `contentViewController` is public API
//  (`NSWindowController.window`, not a new test seam), so this test
//  reaches the real `NSTabViewController`/`NSTabViewItem`s Settings
//  wires up without needing `@testable` internals beyond what this file
//  already imports.
//
//  SCOPE: this file covers the image/label wiring only -- constructing
//  the controller once and inspecting its already-built tab items,
//  never calling `showWindow` or driving a real tab SELECTION change.
//  Whether changing `NSTabViewController.selectedTabViewItemIndex`
//  updates the window's title to the newly-selected pane's title
//  (the fix contract's other half, standard macOS Settings behavior) is
//  NOT covered here: driving a real tab transition off-screen, for the
//  first time in this suite, on a genuine singleton this file cannot
//  tear down between test runs, is exactly the kind of risk this
//  codebase's established seam precedents (AppDelegateAttachWindowTests'
//  own header) exist to avoid forcing untested. That half is
//  review-must-verify per this cycle's handoff instead.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class SettingsWindowControllerTabIconTests: XCTestCase {

    private func tabViewController() throws -> NSTabViewController {
        try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController,
            "SettingsWindowController's window must host an NSTabViewController as its content"
        )
    }

    func test_tabViewItems_oneItemPerSettingsPane_inOrder() throws {
        let controller = try tabViewController()
        XCTAssertEqual(controller.tabViewItems.count, SettingsPane.allCases.count,
                       "One NSTabViewItem must exist per SettingsPane case, no more, no fewer")
        for (item, pane) in zip(controller.tabViewItems, SettingsPane.allCases) {
            XCTAssertEqual(item.label, pane.title, "Tab item label must match \(pane)'s title")
        }
    }

    func test_tabViewItems_eachHasAnIconImage() throws {
        let controller = try tabViewController()
        for (item, pane) in zip(controller.tabViewItems, SettingsPane.allCases) {
            XCTAssertNotNil(
                item.image,
                "Tab item for \(pane) has no image -- a toolbar-style NSTabViewController renders " +
                "an item with no icon as a degenerate fat header with sunk text instead of a proper " +
                "toolbar tab button"
            )
        }
    }
}
