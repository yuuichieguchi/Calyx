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

        // Dismiss with Cmd+Shift+E
        app.typeKey("e", modifierFlags: [.command, .shift])
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

    func test_escapeDoesNotDismissOverlay() {
        menuAction("Edit", item: "Compose Input")

        let textView = composeTextView()
        XCTAssertTrue(waitFor(textView, timeout: 3))

        // Press Escape -- should NOT dismiss the overlay
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Overlay should still be visible
        XCTAssertTrue(textView.exists, "Escape should not dismiss compose overlay")

        // Dismiss with Cmd+Shift+E
        app.typeKey("e", modifierFlags: [.command, .shift])
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
        app.typeKey("e", modifierFlags: [.command, .shift])
    }

    func test_shiftEnterInsertsNewline() {
        menuAction("Edit", item: "Compose Input")

        let textView = composeTextView()
        XCTAssertTrue(waitFor(textView, timeout: 3))

        // Type text and press Shift+Enter for newline
        textView.typeText("line1")
        app.typeKey(.return, modifierFlags: [.shift])
        textView.typeText("line2")
        Thread.sleep(forTimeInterval: 0.3)

        // Compose overlay should still be open (not sent)
        XCTAssertTrue(textView.exists, "Shift+Enter should not dismiss compose overlay")

        // Text should contain the newline (value includes both lines)
        let value = textView.value as? String ?? ""
        XCTAssertTrue(value.contains("line1"), "Text should contain first line")
        XCTAssertTrue(value.contains("line2"), "Text should contain second line")

        app.typeKey("e", modifierFlags: [.command, .shift])
    }

    func test_enterSendsAndClearsText() {
        menuAction("Edit", item: "Compose Input")

        let textView = composeTextView()
        XCTAssertTrue(waitFor(textView, timeout: 3))

        // Type text and press Enter to send
        textView.typeText("hello world")
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Compose overlay should still be open (no dismiss on send)
        XCTAssertTrue(textView.exists, "Compose overlay should stay open after send")

        // Text should be cleared after send
        let value = textView.value as? String ?? ""
        XCTAssertTrue(value.isEmpty, "Text field should be cleared after Enter send")

        // Placeholder should reappear
        let placeholder = app.descendants(matching: .any)
            .matching(identifier: "calyx.compose.placeholder")
            .firstMatch
        XCTAssertTrue(waitFor(placeholder, timeout: 2), "Placeholder should reappear after text is cleared")

        app.typeKey("e", modifierFlags: [.command, .shift])
    }
}
