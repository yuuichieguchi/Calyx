// BrowserUITests.swift
// CalyxUITests
//
// Browser tab tests require network access (BrowserSecurity only allows http/https).

import XCTest

final class BrowserUITests: CalyxUITestCase {

    private func openBrowserTab(url: String) {
        // Open browser tab via menu
        menuAction("File", item: "New Browser Tab")

        // An NSAlert dialog should appear for URL input
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "URL input dialog should appear")

        // Find the text field in the dialog and type the URL
        let textField = dialog.textFields.firstMatch
        if textField.waitForExistence(timeout: 2) {
            textField.click()
            textField.typeText(url)
        }

        // Click Open button
        dialog.buttons["Open"].click()
    }

    func test_browserToolbarVisible() {
        openBrowserTab(url: "https://example.com")

        // Wait for toolbar to appear
        let toolbar = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.toolbar")
            .firstMatch
        XCTAssertTrue(waitFor(toolbar, timeout: 15), "Browser toolbar should be visible")

        // Verify navigation buttons exist
        let backButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.backButton")
            .firstMatch
        XCTAssertTrue(backButton.exists, "Back button should exist")

        let forwardButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.forwardButton")
            .firstMatch
        XCTAssertTrue(forwardButton.exists, "Forward button should exist")

        let reloadButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.reloadButton")
            .firstMatch
        XCTAssertTrue(reloadButton.exists, "Reload button should exist")

        let urlDisplay = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.urlDisplay")
            .firstMatch
        XCTAssertTrue(urlDisplay.exists, "URL display should exist")
    }

    func test_navigationButtons() {
        openBrowserTab(url: "https://example.com")

        let toolbar = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.toolbar")
            .firstMatch
        XCTAssertTrue(waitFor(toolbar, timeout: 15))

        // Back button should initially be disabled
        let backButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.backButton")
            .firstMatch
        XCTAssertTrue(backButton.exists)
        XCTAssertFalse(backButton.isEnabled, "Back button should be disabled on first page")
    }
}
