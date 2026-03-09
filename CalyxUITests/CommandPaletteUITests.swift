// CommandPaletteUITests.swift
// CalyxUITests

import XCTest

final class CommandPaletteUITests: CalyxUITestCase {

    func test_openAndDismiss() {
        // Open command palette
        openCommandPaletteViaMenu()

        // Use searchField as the presence indicator (NSView container identifier
        // may not be exposed in XCUITest accessibility hierarchy)
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette should appear")

        // Dismiss with Escape
        app.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(searchField)
    }

    func test_searchFiltersResults() {
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField))

        let resultsTable = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.resultsTable")
            .firstMatch
        XCTAssertTrue(waitFor(resultsTable))

        // Get initial row count (all commands)
        let initialRowCount = resultsTable.tableRows.count

        // Type a filter query
        searchField.typeText("tab")
        Thread.sleep(forTimeInterval: 0.3)

        // Filtered count should be less than or equal to initial
        let filteredRowCount = resultsTable.tableRows.count
        XCTAssertLessThanOrEqual(filteredRowCount, initialRowCount, "Filtering should reduce or maintain result count")
        XCTAssertGreaterThan(filteredRowCount, 0, "Some commands should match 'tab'")
    }

    func test_executeCommand() {
        let initialTabCount = countTabBarTabs()

        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField))

        // Type "New Tab" and execute
        searchField.typeText("New Tab")
        searchField.typeKey(.enter, modifierFlags: [])

        // Palette should dismiss
        let palette = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette")
            .firstMatch
        waitForNonExistence(palette)

        // Tab count should increase
        Thread.sleep(forTimeInterval: 0.5)
        let newTabCount = countTabBarTabs()
        XCTAssertEqual(newTabCount, initialTabCount + 1, "Executing 'New Tab' should add a tab")
    }
}
