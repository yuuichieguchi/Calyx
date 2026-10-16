// KeyEquivalentPassThroughMenu.swift
// Calyx
//
// NSMenu whose disabled items do not consume their key equivalent. AppKit's
// NSMenu reports a match for a disabled item as handled, which swallows
// keys such as Option+Z or Option+F5 that a terminal tab must receive
// (VS Code's integrated terminal likewise lets Alt+Z reach the shell).

import AppKit

final class KeyEquivalentPassThroughMenu: NSMenu {

    /// Declines the key only when every matching item is disabled. Items are
    /// validated (`update()`) only when a top-level match exists and the
    /// menu auto-enables its items.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let matches = Self.matchingItems(in: items, for: event)
        guard let first = matches.first else {
            return super.performKeyEquivalent(with: event)
        }
        if autoenablesItems { update() }
        guard let enabled = matches.first(where: \.isEnabled) else { return false }
        if enabled === first {
            return super.performKeyEquivalent(with: event)
        }
        // NSMenu stops at the first match, so a disabled earlier item would
        // swallow the key; dispatch the first enabled match instead.
        performActionForItem(at: index(of: enabled))
        return true
    }

    /// The top-level items whose key equivalent and modifier mask match
    /// `event`, in menu order. An uppercase key equivalent implies Shift, as
    /// in AppKit.
    static func matchingItems(in items: [NSMenuItem], for event: NSEvent) -> [NSMenuItem] {
        guard event.type == .keyDown, let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
            return []
        }
        let eventFlags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        return items.filter { item in
            let key = item.keyEquivalent
            guard !key.isEmpty, key.lowercased() == chars.lowercased() else { return false }
            var mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            if key != key.lowercased() { mask.insert(.shift) }
            return mask == eventFlags
        }
    }
}
