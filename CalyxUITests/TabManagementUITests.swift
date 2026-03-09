// TabManagementUITests.swift
// CalyxUITests

import XCTest

final class TabManagementUITests: CalyxUITestCase {

    func test_initialState_hasOneTab() {
        let tabCount = countTabBarTabs()
        XCTAssertEqual(tabCount, 1, "Initial state should have exactly one tab")
    }

    func test_createNewTab_addsTab() {
        createNewTabViaMenu()

        // Wait for the second tab to appear
        Thread.sleep(forTimeInterval: 1.0)

        let tabCount = countTabBarTabs()
        XCTAssertEqual(tabCount, 2, "Should have two tabs after creating a new one")
    }

    func test_closeTab_removesTab() {
        // Create a second tab
        createNewTabViaMenu()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(countTabBarTabs(), 2, "Should have two tabs before closing")

        // Close the active tab via menu
        closeTabViaMenu()

        // Wait for tab removal
        Thread.sleep(forTimeInterval: 1.0)

        let tabCount = countTabBarTabs()
        XCTAssertEqual(tabCount, 1, "Should have one tab after closing")
    }

    func test_closeLastTab_closesWindow() {
        // Close the only tab
        closeTabViaMenu()

        // The window should close and the app should terminate
        waitForNonExistence(app.windows.firstMatch)
    }
}
