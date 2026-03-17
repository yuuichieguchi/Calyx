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

    // MARK: - Group Rename Tests

    /// Helper: creates a second group via command palette and waits for it to appear.
    private func createSecondGroup() {
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette search field should appear")

        searchField.typeText("New Group")
        searchField.typeKey(.enter, modifierFlags: [])

        let palette = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette")
            .firstMatch
        waitForNonExistence(palette)

        Thread.sleep(forTimeInterval: 0.5)

        let groupCount = countElements(matching: "calyx.sidebar.group.")
        XCTAssertEqual(groupCount, 2, "Should have two groups after creating a new one")
    }

    func test_renameGroupByDoubleClick() {
        // Arrange: create a second group
        createSecondGroup()

        // Find the second group element
        let groups = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.group."))
        let secondGroup = groups.element(boundBy: 1)
        XCTAssertTrue(secondGroup.exists, "Second group should exist")

        // Act: double-click to enter rename mode
        secondGroup.doubleClick()

        // Wait for the rename text field to appear
        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.groupNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear after double-clicking group header"
        )

        // Select all existing text, type the new name and confirm
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("My Custom Group")
        renameField.typeKey(.enter, modifierFlags: [])

        // Wait for the text field to dismiss
        waitForNonExistence(renameField)

        // Assert: the sidebar should now show "My Custom Group"
        Thread.sleep(forTimeInterval: 0.5)
        let renamedLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "My Custom Group"))
            .firstMatch
        XCTAssertTrue(
            waitFor(renamedLabel, timeout: 3),
            "Sidebar should display the renamed group 'My Custom Group'"
        )
    }

    func test_renameGroupCancel() {
        // Arrange: create a second group
        createSecondGroup()

        // Find the second group element
        let groups = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.group."))
        let secondGroup = groups.element(boundBy: 1)
        XCTAssertTrue(secondGroup.exists, "Second group should exist")

        // Act: double-click to enter rename mode
        secondGroup.doubleClick()

        // Wait for the rename text field to appear
        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.groupNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear after double-clicking group header"
        )

        // Type something then cancel with Escape
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Should Not Save")
        renameField.typeKey(.escape, modifierFlags: [])

        // Assert: the text field should disappear
        waitForNonExistence(renameField)

        // Assert: original name "Group 2" should still be displayed
        Thread.sleep(forTimeInterval: 0.5)
        let originalLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Group 2"))
            .firstMatch
        XCTAssertTrue(
            waitFor(originalLabel, timeout: 3),
            "Original group name 'Group 2' should still be displayed after cancelling rename"
        )
    }

    func test_renameGroupEmptyString() {
        // Arrange: create a second group
        createSecondGroup()

        // Find the second group element
        let groups = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.group."))
        let secondGroup = groups.element(boundBy: 1)
        XCTAssertTrue(secondGroup.exists, "Second group should exist")

        // Act: double-click to enter rename mode
        secondGroup.doubleClick()

        // Wait for the rename text field to appear
        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.groupNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear after double-clicking group header"
        )

        // Select all text and delete to create an empty string
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeKey(.delete, modifierFlags: [])

        // Confirm the empty name
        renameField.typeKey(.enter, modifierFlags: [])

        // Assert: original name "Group 2" should be preserved (empty name rejected)
        Thread.sleep(forTimeInterval: 0.5)
        let originalLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Group 2"))
            .firstMatch
        XCTAssertTrue(
            waitFor(originalLabel, timeout: 3),
            "Original group name 'Group 2' should be preserved when submitting empty string"
        )
    }
}
