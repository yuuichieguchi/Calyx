//
//  ShortcutManagerTests.swift
//  CalyxTests
//
//  Tests for ShortcutManager — verifies shortcut registration,
//  interception filtering, and event dispatch.
//
//  Coverage:
//  - shouldIntercept returns false when first responder is NSTextField
//  - shouldIntercept returns true when first responder is SurfaceView
//  - handleEvent returns true for registered shortcut
//  - handleEvent returns false for unregistered shortcut
//  - register + handleEvent executes the registered action
//

import XCTest
@testable import Calyx
@preconcurrency import AppKit

@MainActor
final class ShortcutManagerTests: XCTestCase {

    // MARK: - Fixtures

    private var manager: ShortcutManager!

    override func setUp() {
        super.setUp()
        manager = ShortcutManager()
    }

    override func tearDown() {
        manager = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a synthetic NSEvent for key-down with the given modifiers and keyCode.
    /// Returns nil if the event cannot be created (should not happen in tests).
    private func makeKeyEvent(
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // ==================== 1. shouldIntercept — NSTextField ====================

    func test_shouldIntercept_returns_false_when_firstResponder_is_NSTextField() {
        // Arrange
        let textField = NSTextField(frame: .zero)
        guard let event = makeKeyEvent(modifiers: [.command], keyCode: 0x09) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Register a shortcut so the manager has something to match
        manager.register(modifiers: [.command], keyCode: 0x09) { /* no-op */ }

        // Act
        let result = manager.shouldIntercept(event: event, firstResponder: textField)

        // Assert
        XCTAssertFalse(result,
                       "shouldIntercept must return false when the first responder is an NSTextField")
    }

    // ==================== 2. shouldIntercept — SurfaceView ====================

    func test_shouldIntercept_returns_true_when_firstResponder_is_SurfaceView() {
        // Arrange
        let surfaceView = SurfaceView(frame: .zero)
        guard let event = makeKeyEvent(modifiers: [.command], keyCode: 0x09) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Register a matching shortcut
        manager.register(modifiers: [.command], keyCode: 0x09) { /* no-op */ }

        // Act
        let result = manager.shouldIntercept(event: event, firstResponder: surfaceView)

        // Assert
        XCTAssertTrue(result,
                      "shouldIntercept must return true when the first responder is a SurfaceView")
    }

    // ==================== 3. handleEvent — Registered Shortcut ====================

    func test_handleEvent_returns_true_for_registered_shortcut() {
        // Arrange
        let keyCode: UInt16 = 0x09 // V key
        let modifiers: NSEvent.ModifierFlags = [.command]
        manager.register(modifiers: modifiers, keyCode: keyCode) { /* no-op */ }

        guard let event = makeKeyEvent(modifiers: modifiers, keyCode: keyCode) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Act
        let result = manager.handleEvent(event)

        // Assert
        XCTAssertTrue(result,
                      "handleEvent should return true for a registered shortcut")
    }

    // ==================== 4. handleEvent — Unregistered Shortcut ====================

    func test_handleEvent_returns_false_for_unregistered_shortcut() {
        // Arrange — register Cmd+V (0x09) but send Cmd+Z (0x06)
        manager.register(modifiers: [.command], keyCode: 0x09) { /* no-op */ }

        guard let event = makeKeyEvent(modifiers: [.command], keyCode: 0x06) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Act
        let result = manager.handleEvent(event)

        // Assert
        XCTAssertFalse(result,
                       "handleEvent should return false for an unregistered shortcut")
    }

    func test_handleEvent_returns_false_when_no_shortcuts_registered() {
        // Arrange — no shortcuts registered
        guard let event = makeKeyEvent(modifiers: [.command], keyCode: 0x09) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Act
        let result = manager.handleEvent(event)

        // Assert
        XCTAssertFalse(result,
                       "handleEvent should return false when no shortcuts are registered")
    }

    // ==================== 5. Register + HandleEvent Executes Action ====================

    func test_handleEvent_executes_action_for_registered_shortcut() {
        // Arrange
        var actionExecuted = false
        let keyCode: UInt16 = 0x0C // Q key
        let modifiers: NSEvent.ModifierFlags = [.command]

        manager.register(modifiers: modifiers, keyCode: keyCode) {
            actionExecuted = true
        }

        guard let event = makeKeyEvent(modifiers: modifiers, keyCode: keyCode) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Act
        _ = manager.handleEvent(event)

        // Assert
        XCTAssertTrue(actionExecuted,
                      "The registered action should be executed when handleEvent matches the shortcut")
    }

    func test_handleEvent_does_not_execute_action_for_mismatched_modifiers() {
        // Arrange
        var actionExecuted = false
        manager.register(modifiers: [.command], keyCode: 0x0C) {
            actionExecuted = true
        }

        // Event with Ctrl instead of Command
        guard let event = makeKeyEvent(modifiers: [.control], keyCode: 0x0C) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Act
        _ = manager.handleEvent(event)

        // Assert
        XCTAssertFalse(actionExecuted,
                       "Action should NOT execute when modifiers do not match")
    }

    func test_handleEvent_does_not_execute_action_for_mismatched_keyCode() {
        // Arrange
        var actionExecuted = false
        manager.register(modifiers: [.command], keyCode: 0x0C) {
            actionExecuted = true
        }

        // Same modifiers, different keyCode
        guard let event = makeKeyEvent(modifiers: [.command], keyCode: 0x00) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }

        // Act
        _ = manager.handleEvent(event)

        // Assert
        XCTAssertFalse(actionExecuted,
                       "Action should NOT execute when keyCode does not match")
    }

    // ==================== 8. Cmd+Shift+]/[ KeyCode Verification ====================

    func test_handleEvent_matches_cmdShift_rightBracket_keyCode30() {
        var executed = false
        manager.register(modifiers: [.command, .shift], keyCode: 30) {
            executed = true
        }
        guard let event = makeKeyEvent(modifiers: [.command, .shift], keyCode: 30) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }
        let result = manager.handleEvent(event)
        XCTAssertTrue(result, "handleEvent should return true for Cmd+Shift+] (keyCode 30)")
        XCTAssertTrue(executed, "Action should execute for Cmd+Shift+] (keyCode 30)")
    }

    func test_handleEvent_matches_cmdShift_leftBracket_keyCode33() {
        var executed = false
        manager.register(modifiers: [.command, .shift], keyCode: 33) {
            executed = true
        }
        guard let event = makeKeyEvent(modifiers: [.command, .shift], keyCode: 33) else {
            XCTFail("Failed to create synthetic NSEvent")
            return
        }
        let result = manager.handleEvent(event)
        XCTAssertTrue(result, "handleEvent should return true for Cmd+Shift+[ (keyCode 33)")
        XCTAssertTrue(executed, "Action should execute for Cmd+Shift+[ (keyCode 33)")
    }
}
