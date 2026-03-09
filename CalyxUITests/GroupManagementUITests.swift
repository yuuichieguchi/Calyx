// GroupManagementUITests.swift
// CalyxUITests

import XCTest

final class GroupManagementUITests: CalyxUITestCase {

    func test_createNewGroup() {
        // Open command palette
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette search field should appear")

        // Type "New Group" and execute
        searchField.typeText("New Group")
        searchField.typeKey(.enter, modifierFlags: [])

        // Wait for palette to dismiss
        let palette = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette")
            .firstMatch
        waitForNonExistence(palette)

        // Should now have 2 groups
        Thread.sleep(forTimeInterval: 0.5)
        let groupCount = countElements(matching: "calyx.sidebar.group.")
        XCTAssertEqual(groupCount, 2, "Should have two groups after creating a new one")
    }

    func test_switchGroup() {
        // Create a second group via command palette
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField))

        searchField.typeText("New Group")
        searchField.typeKey(.enter, modifierFlags: [])

        // Wait for palette to dismiss and group to be created
        let palette = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette")
            .firstMatch
        waitForNonExistence(palette)
        Thread.sleep(forTimeInterval: 0.5)

        // Click the first group in the sidebar to switch
        let groups = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.group."))
        XCTAssertEqual(groups.count, 2, "Should have two groups")

        groups.element(boundBy: 0).click()
        Thread.sleep(forTimeInterval: 0.3)

        // Verify we can interact with it (the group click should succeed without error)
        XCTAssertTrue(groups.element(boundBy: 0).exists, "First group should still exist after clicking")
    }
}
