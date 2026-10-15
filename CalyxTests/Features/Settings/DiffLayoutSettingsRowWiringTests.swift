//
//  DiffLayoutSettingsRowWiringTests.swift
//  CalyxTests
//
//  Settings -> Appearance "Changes" section rows for the diff layout
//  (plan §5): gitDiffLayout (popup), gitDiffHideUnchangedRegions and
//  gitDiffIgnoreTrimWhitespace (switches). Mirrors
//  GlassOpacityCellsSettingsToggleWiringTests: (A) target/action wiring on
//  the real singleton's Appearance view tree located by accessibility id,
//  (B) initial-state seams, plus row declaration order/pane.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class DiffLayoutSettingsRowWiringTests: XCTestCase {

    private let suiteName = "com.calyx.tests.DiffLayoutSettingsRowWiringTests"

    override func setUp() {
        super.setUp()
        DiffLayoutSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        DiffLayoutSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    // MARK: - View tree helpers

    private func appearancePaneView() throws -> NSView {
        let tabViewController = try XCTUnwrap(
            SettingsWindowController.shared.window?.contentViewController as? NSTabViewController
        )
        let appearanceIndex = try XCTUnwrap(SettingsPane.allCases.firstIndex(of: .appearance))
        let tabItem = tabViewController.tabViewItems[appearanceIndex]
        return try XCTUnwrap(tabItem.viewController?.view)
    }

    private func find<T: NSView>(_ type: T.Type, identifier: String, in view: NSView) -> T? {
        for subview in view.subviews {
            if let match = subview as? T, match.accessibilityIdentifier() == identifier {
                return match
            }
            if let found = find(type, identifier: identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Accessibility identifiers

    func test_accessibilityIdentifiers_haveDocumentedValues() {
        XCTAssertEqual(AccessibilityID.Settings.gitDiffLayoutPopup,
                       "calyx.settings.appearance.gitDiffLayoutPopup")
        XCTAssertEqual(AccessibilityID.Settings.gitDiffHideUnchangedRegionsSwitch,
                       "calyx.settings.appearance.gitDiffHideUnchangedRegionsSwitch")
        XCTAssertEqual(AccessibilityID.Settings.gitDiffIgnoreTrimWhitespaceSwitch,
                       "calyx.settings.appearance.gitDiffIgnoreTrimWhitespaceSwitch")
    }

    // MARK: - (A) wiring

    func test_layoutPopup_existsWithTargetActionAndItemsInOrder() throws {
        let popup = try XCTUnwrap(
            find(NSPopUpButton.self, identifier: AccessibilityID.Settings.gitDiffLayoutPopup, in: try appearancePaneView()),
            "the Appearance pane must contain the gitDiffLayoutPopup"
        )
        XCTAssertTrue(popup.target === SettingsWindowController.shared)
        XCTAssertNotNil(popup.action)
        XCTAssertEqual(popup.itemTitles, ["Automatic", "Inline", "Side by Side"])
    }

    func test_hideUnchangedRegionsSwitch_existsWithTargetAndAction() throws {
        let toggle = try XCTUnwrap(
            find(NSSwitch.self, identifier: AccessibilityID.Settings.gitDiffHideUnchangedRegionsSwitch, in: try appearancePaneView())
        )
        XCTAssertTrue(toggle.target === SettingsWindowController.shared)
        XCTAssertNotNil(toggle.action)
    }

    func test_ignoreTrimWhitespaceSwitch_existsWithTargetAndAction() throws {
        let toggle = try XCTUnwrap(
            find(NSSwitch.self, identifier: AccessibilityID.Settings.gitDiffIgnoreTrimWhitespaceSwitch, in: try appearancePaneView())
        )
        XCTAssertTrue(toggle.target === SettingsWindowController.shared)
        XCTAssertNotNil(toggle.action)
    }

    // MARK: - (B) initial-state seams

    func test_diffLayoutInitialSelectionIndex_matchesPersistedPreference() {
        DiffLayoutSettings.preference = .automatic
        XCTAssertEqual(SettingsWindowController.diffLayoutInitialSelectionIndex(), 0)
        DiffLayoutSettings.preference = .inline
        XCTAssertEqual(SettingsWindowController.diffLayoutInitialSelectionIndex(), 1)
        DiffLayoutSettings.preference = .sideBySide
        XCTAssertEqual(SettingsWindowController.diffLayoutInitialSelectionIndex(), 2)
    }

    func test_sessionToggleInitialState_hideUnchangedRegions_readsSetting() {
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .gitDiffHideUnchangedRegions),
                       "default is false")
        DiffLayoutSettings.hideUnchangedRegionsEnabled = true
        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .gitDiffHideUnchangedRegions))
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .gitDiffHideUnchangedRegions))
    }

    func test_sessionToggleInitialState_ignoreTrimWhitespace_readsSetting() {
        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .gitDiffIgnoreTrimWhitespace),
                      "default is true")
        DiffLayoutSettings.ignoreTrimWhitespace = false
        XCTAssertFalse(SettingsWindowController.sessionToggleInitialState(for: .gitDiffIgnoreTrimWhitespace))
        DiffLayoutSettings.ignoreTrimWhitespace = true
        XCTAssertTrue(SettingsWindowController.sessionToggleInitialState(for: .gitDiffIgnoreTrimWhitespace))
    }

    // MARK: - Row declaration

    func test_rows_belongToAppearancePane() {
        XCTAssertEqual(SettingsRow.gitDiffLayout.pane, .appearance)
        XCTAssertEqual(SettingsRow.gitDiffHideUnchangedRegions.pane, .appearance)
        XCTAssertEqual(SettingsRow.gitDiffIgnoreTrimWhitespace.pane, .appearance)
    }

    func test_rows_followGitDiffPreviewTabInOrder() throws {
        let all = SettingsRow.allCases
        let preview = try XCTUnwrap(all.firstIndex(of: .gitDiffPreviewTab))
        XCTAssertEqual(all.firstIndex(of: .gitDiffLayout), preview + 1)
        XCTAssertEqual(all.firstIndex(of: .gitDiffHideUnchangedRegions), preview + 2)
        XCTAssertEqual(all.firstIndex(of: .gitDiffIgnoreTrimWhitespace), preview + 3)
    }

    func test_rows_continueChangesSection_noOwnHeading() {
        XCTAssertNil(SettingsWindowController.sectionHeading(for: .gitDiffLayout))
        XCTAssertNil(SettingsWindowController.sectionHeading(for: .gitDiffHideUnchangedRegions))
        XCTAssertNil(SettingsWindowController.sectionHeading(for: .gitDiffIgnoreTrimWhitespace))
    }
}
