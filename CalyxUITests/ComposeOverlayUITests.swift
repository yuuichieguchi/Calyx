// ComposeOverlayUITests.swift
// CalyxUITests

import XCTest

final class ComposeOverlayUITests: CalyxUITestCase {

    private func composeTextView() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "calyx.compose.textView")
            .firstMatch
    }

    func test_openComposeViaMenu() {
        // Open compose overlay via Edit menu
        menuAction("Edit", item: "Compose Input")

        // Verify compose text view appears
        let textView = composeTextView()
        XCTAssertTrue(waitFor(textView, timeout: 3), "Compose overlay text view should appear after menu action")

        // Dismiss with Escape
        app.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(textView)
    }

    func test_openComposeViaShortcut() {
        // Open compose overlay via Cmd+Shift+E
        app.typeKey("e", modifierFlags: [.command, .shift])

        // Verify compose text view appears
        let textView = composeTextView()
        XCTAssertTrue(waitFor(textView, timeout: 3), "Compose overlay should appear after Cmd+Shift+E")

        // Toggle dismiss with Cmd+Shift+E again
        app.typeKey("e", modifierFlags: [.command, .shift])
        waitForNonExistence(textView)
    }

    func test_dismissWithEscape() {
        menuAction("Edit", item: "Compose Input")

        let textView = composeTextView()
        XCTAssertTrue(waitFor(textView, timeout: 3))

        // Dismiss with Escape
        app.typeKey(.escape, modifierFlags: [])
        waitForNonExistence(textView, timeout: 3)
    }

    func test_placeholderHidesWhenTyping() {
        // Open compose overlay via menu
        menuAction("Edit", item: "Compose Input")

        let textView = composeTextView()
        XCTAssertTrue(waitFor(textView, timeout: 3))

        // Placeholder should be visible before typing
        let placeholder = app.descendants(matching: .any)
            .matching(identifier: "calyx.compose.placeholder")
            .firstMatch
        XCTAssertTrue(waitFor(placeholder, timeout: 2), "Placeholder should be visible initially")

        // Type some text
        textView.typeText("hello")
        Thread.sleep(forTimeInterval: 0.3)

        // Placeholder should not be visible after typing
        XCTAssertFalse(placeholder.isHittable, "Placeholder should disappear after typing")

        // Dismiss
        app.typeKey(.escape, modifierFlags: [])
    }
}
