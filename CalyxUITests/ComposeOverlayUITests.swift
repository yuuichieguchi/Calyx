// ComposeOverlayUITests.swift
// CalyxUITests

import XCTest

final class ComposeOverlayUITests: CalyxUITestCase {

    private func composeTextView() -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "calyx.compose.textView")
            .firstMatch
    }

    /// Polls `path` until it has non-empty content or `timeout` elapses,
    /// mirroring `SelectionEditUITests.pollFile`'s own established
    /// polling idiom (kept as a near-duplicate rather than a shared
    /// call, matching this codebase's precedent of not cross-linking
    /// unrelated UI test files, e.g. `PaneCLIExec.swift`'s own header).
    private func pollFile(_ path: String, timeout: TimeInterval = 10) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: path),
               let s = try? String(contentsOfFile: path, encoding: .utf8),
               !s.isEmpty {
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

        // Send a command through compose whose effect is only observable
        // if the text actually reached the terminal and executed there
        // (CalyxWindowController.sendComposeText calls
        // `controller.sendText(text)` then synthesizes Return) --
        // proves "Sends" for real, not just that the compose text view's
        // own value cleared afterward.
        let outFile = "/tmp/calyx-e2e-compose-\(ProcessInfo.processInfo.processIdentifier).txt"
        try? FileManager.default.removeItem(atPath: outFile)
        let marker = "COMPOSE_SEND_\(UUID().uuidString.prefix(8))"

        // Type text and press Enter to send
        textView.typeText("echo \(marker) > \(outFile)")
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

        // The composed text must have actually reached the terminal and
        // executed there, not merely cleared from the compose text view.
        let output = pollFile(outFile)
        XCTAssertTrue(
            output.contains(marker),
            "Compose's sent text should have reached the terminal and executed there " +
            "(expected marker \"\(marker)\" in \(outFile), got: \"\(output)\")"
        )

        app.typeKey("e", modifierFlags: [.command, .shift])
    }
}
