// ShortcutManager.swift
// Calyx
//
// Manages keyboard shortcuts with precedence rules.

import AppKit

@MainActor
class ShortcutManager {

    struct Shortcut {
        let modifiers: NSEvent.ModifierFlags
        let keyCode: UInt16
        let action: @MainActor () -> Void
    }

    private var shortcuts: [Shortcut] = []

    func register(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, action: @escaping @MainActor () -> Void) {
        shortcuts.append(Shortcut(modifiers: modifiers, keyCode: keyCode, action: action))
    }

    /// Check if the event should be intercepted based on precedence rules.
    /// Returns false for IME composing, text fields, etc.
    func shouldIntercept(event: NSEvent, firstResponder: NSResponder?) -> Bool {
        // Rule 1: IME composing — bypass all shortcuts
        if let textInput = firstResponder as? NSTextInputClient, textInput.hasMarkedText() {
            return false
        }

        // Rule 2: Standard text editing controls — let normal menu handling process
        if firstResponder is NSTextView || firstResponder is NSTextField {
            return false
        }

        // Rule 3: Check if we have a matching shortcut
        return matchingShortcut(for: event) != nil
    }

    /// Try to handle the event. Returns true if a shortcut was executed.
    func handleEvent(_ event: NSEvent) -> Bool {
        guard let shortcut = matchingShortcut(for: event) else { return false }
        shortcut.action()
        return true
    }

    private func matchingShortcut(for event: NSEvent) -> Shortcut? {
        let relevantMods: NSEvent.ModifierFlags = [.command, .shift, .control, .option]
        let eventMods = event.modifierFlags.intersection(relevantMods)

        return shortcuts.first { shortcut in
            let shortcutMods = shortcut.modifiers.intersection(relevantMods)
            return shortcut.keyCode == event.keyCode && shortcutMods == eventMods
        }
    }
}
