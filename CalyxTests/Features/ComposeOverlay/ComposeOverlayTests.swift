//
//  ComposeOverlayTests.swift
//  CalyxTests
//
//  Tests for ComposeOverlayView, trusted paste, and WindowSession compose state.
//  Written before implementation (TDD Red phase) -- all tests must FAIL.
//
//  Coverage:
//  - ComposeOverlayView: Enter sends text via onSend
//  - ComposeOverlayView: Shift+Enter inserts newline without sending
//  - ComposeOverlayView: Escape forwards via onEscapePressed, does NOT dismiss
//  - ComposeOverlayView: Empty text is not sent
//  - GhosttyAppController: trustedPasteContent defaults nil
//  - GhosttyAppController: trustedPasteContent round-trip
//  - WindowSession: showComposeOverlay defaults false
//  - WindowSession: showComposeOverlay toggleable
//

import XCTest
@testable import Calyx

// MARK: - ComposeOverlayView Tests

@MainActor
final class ComposeOverlayViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT() -> ComposeOverlayView {
        ComposeOverlayView()
    }

    // ==================== 1. Enter Sends Text via onSend ====================

    func test_should_invoke_onSend_when_insertNewline_called() {
        // Arrange
        let sut = makeSUT()
        var receivedText: String?
        sut.onSend = { text in
            receivedText = text
            return true
        }

        // Simulate typing "hello" into the internal text view
        sut.textView.string = "hello"

        // Act -- insertNewline is the NSResponder selector triggered by Enter
        sut.insertNewline(nil)

        // Assert
        XCTAssertEqual(receivedText, "hello",
                       "onSend should receive the current text when Enter is pressed")
    }

    // ==================== 2. Shift+Enter Inserts Newline Without Sending ====================

    func test_should_insert_actual_newline_for_shift_enter() {
        // Arrange
        let sut = makeSUT()
        var sendCalled = false
        sut.onSend = { _ in
            sendCalled = true
            return true
        }

        sut.textView.string = "line1"

        // Act -- insertNewlineIgnoringFieldEditor is the selector for Shift+Enter
        sut.insertNewlineIgnoringFieldEditor(nil)

        // Assert
        XCTAssertTrue(sut.textView.string.contains("\n"),
                      "Shift+Enter should insert a literal newline into the text")
        XCTAssertFalse(sendCalled,
                       "onSend must NOT be called for Shift+Enter")
    }

    // ==================== 3. Escape Forwards to Terminal, Does NOT Dismiss ====================

    func test_escape_should_forward_not_dismiss() {
        // Arrange
        let sut = makeSUT()
        var escapeCalled = false
        var dismissCalled = false
        sut.onEscapePressed = {
            escapeCalled = true
        }
        sut.onDismiss = {
            dismissCalled = true
        }

        // Act -- cancelOperation is the NSResponder selector triggered by Escape
        sut.cancelOperation(nil)

        // Assert
        XCTAssertTrue(escapeCalled,
                      "onEscapePressed should fire when Escape (cancelOperation) is invoked")
        XCTAssertFalse(dismissCalled,
                       "onDismiss must NOT fire on Escape -- only Cmd+Shift+E should dismiss")
    }

    // ==================== 3.5. Enter Clears Text After Send ====================

    func test_should_clear_text_after_send() {
        // Arrange
        let sut = makeSUT()
        sut.onSend = { _ in true }
        sut.textView.string = "hello"

        // Act
        sut.insertNewline(nil)

        // Assert
        XCTAssertTrue(sut.textView.string.isEmpty,
                      "Text should be cleared after Enter sends")
    }

    // ==================== 4. Empty Text Is Not Sent ====================

    func test_should_not_send_empty_text() {
        // Arrange
        let sut = makeSUT()
        var sendCalled = false
        sut.onSend = { _ in
            sendCalled = true
            return true
        }

        // Leave text empty (default state)
        sut.textView.string = ""

        // Act
        sut.insertNewline(nil)

        // Assert
        XCTAssertFalse(sendCalled,
                       "onSend should NOT be called when the text is empty")
    }
}

// MARK: - Trusted Paste Tests

@MainActor
final class TrustedPasteTests: XCTestCase {

    // ==================== 5. trustedPasteContent Defaults to nil ====================

    func test_trustedPasteContent_should_be_nil_by_default() {
        // Arrange & Act
        let controller = GhosttyAppController.shared

        // Assert
        XCTAssertNil(controller.trustedPasteContent,
                     "trustedPasteContent should be nil when no paste is pending")
    }

    // ==================== 6. trustedPasteContent Round-Trip ====================

    func test_trustedPasteContent_should_be_settable_and_readable() {
        // Arrange
        let controller = GhosttyAppController.shared
        let testContent = "echo 'dangerous command'"

        // Act
        controller.trustedPasteContent = testContent

        // Assert
        XCTAssertEqual(controller.trustedPasteContent, testContent,
                       "trustedPasteContent should return the value that was set")

        // Cleanup -- restore nil so other tests are not affected
        controller.trustedPasteContent = nil
    }
}

// MARK: - WindowSession Compose Overlay Tests

@MainActor
final class WindowSessionComposeOverlayTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT() -> WindowSession {
        WindowSession()
    }

    // ==================== 7. showComposeOverlay Defaults to false ====================

    func test_showComposeOverlay_should_default_to_false() {
        // Arrange & Act
        let sut = makeSUT()

        // Assert
        XCTAssertFalse(sut.showComposeOverlay,
                       "showComposeOverlay should be false by default")
    }

    // ==================== 8. showComposeOverlay Is Toggleable ====================

    func test_showComposeOverlay_should_be_toggleable() {
        // Arrange
        let sut = makeSUT()

        // Act
        sut.showComposeOverlay = true

        // Assert
        XCTAssertTrue(sut.showComposeOverlay,
                      "showComposeOverlay should be true after being set to true")
    }
}
