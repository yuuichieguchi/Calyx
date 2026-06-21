//
//  CommandPaletteViewTests.swift
//  CalyxTests
//
//  Tests for CommandPaletteView behavior, verified through public API
//  and observable side effects (handler calls, onDismiss invocations).
//
//  Coverage:
//  - executeSelected with empty registry → no crash, handler not called
//  - executeSelected with 1 command → handler called
//  - onDismiss closure invocation
//  - Escape key → onDismiss fires
//

import XCTest
@testable import Calyx

@MainActor
final class CommandPaletteViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeRegistry(commands: [PaletteCommand] = []) -> CommandRegistry {
        let registry = CommandRegistry()
        for command in commands {
            registry.register(command)
        }
        return registry
    }

    private func makeCommand(
        id: String = "test.cmd",
        title: String = "Test Command",
        handler: @escaping @MainActor @Sendable () -> Void = {}
    ) -> PaletteCommand {
        PaletteCommand(id: id, title: title, handler: handler)
    }

    // ==================== 1. executeSelected with Empty Registry → No Crash ====================

    func test_should_not_crash_when_executeSelected_on_empty_registry() {
        // Arrange — registry has no commands, so filteredCommands will be empty
        let registry = makeRegistry()
        let view = CommandPaletteView(registry: registry)
        var handlerCalled = false
        view.onDismiss = { handlerCalled = true }

        // Act — should be guarded by filteredCommands.indices.contains(selectedIndex)
        view.executeSelected()

        // Assert — guard should prevent any handler from running
        XCTAssertFalse(handlerCalled,
                       "onDismiss should NOT be called when executeSelected has no commands to execute")
    }

    // ==================== 2. executeSelected with 1 Command → Handler Called ====================

    func test_should_call_handler_when_executeSelected_with_valid_command() {
        // Arrange
        var handlerCalled = false
        let command = makeCommand(id: "action", title: "Do Action") {
            handlerCalled = true
        }
        let registry = makeRegistry(commands: [command])
        let view = CommandPaletteView(registry: registry)

        // Act — the view initializes with empty search (all commands shown),
        // selectedIndex starts at 0, so executeSelected should run the handler
        view.executeSelected()

        // Assert
        XCTAssertTrue(handlerCalled,
                      "Handler should be called when executeSelected targets a valid command")
    }

    // ==================== 3. onDismiss Closure Invocation ====================

    func test_should_invoke_onDismiss_when_set() {
        // Arrange
        var dismissCalled = false
        let command = makeCommand(id: "cmd", title: "Some Command") {}
        let registry = makeRegistry(commands: [command])
        let view = CommandPaletteView(registry: registry)
        view.onDismiss = { dismissCalled = true }

        // Act — executeSelected calls onDismiss before the handler
        view.executeSelected()

        // Assert
        XCTAssertTrue(dismissCalled,
                      "onDismiss should be called during executeSelected")
    }

    // ==================== 4. Escape Key → onDismiss Fires ====================

    func test_should_call_onDismiss_when_escape_key_pressed() {
        // Arrange
        var dismissCalled = false
        let registry = makeRegistry()
        let view = CommandPaletteView(registry: registry)
        view.onDismiss = { dismissCalled = true }

        // Act — simulate Escape key (keyCode 0x35)
        let escapeEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 0x35
        )

        if let event = escapeEvent {
            view.keyDown(with: event)
        } else {
            XCTFail("Failed to create NSEvent for Escape key — test environment may not support it")
            return
        }

        // Assert
        XCTAssertTrue(dismissCalled,
                      "onDismiss should be called when Escape key is pressed")
    }
}
