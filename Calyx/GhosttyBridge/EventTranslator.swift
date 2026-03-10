// EventTranslator.swift
// Calyx
//
// Converts NSEvent to ghostty input structs.

@preconcurrency import AppKit
import GhosttyKit

// MARK: - EventTranslator

enum EventTranslator {

    // MARK: - Key Events

    /// Translate an NSEvent key event into a ghostty_input_key_s.
    ///
    /// Note: The `text` and `composing` fields are NOT set by this method.
    /// The caller must set those based on IME state and interpretation results.
    ///
    /// - Parameters:
    ///   - event: The NSEvent to translate.
    ///   - action: The input action (press, release, repeat).
    ///   - translationMods: Optional override modifier flags for character translation.
    /// - Returns: A ghostty_input_key_s struct ready for submission.
    static func translateKeyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)

        // Text and composing must be set by the caller for proper lifetime management.
        keyEvent.text = nil
        keyEvent.composing = false

        // Set modifier keys.
        keyEvent.mods = translateModifiers(event.modifierFlags)

        // Consumed mods: control and command never contribute to text translation.
        // Everything else is assumed consumed.
        let effectiveMods = translationMods ?? event.modifierFlags
        keyEvent.consumed_mods = translateModifiers(
            effectiveMods.subtracting([.control, .command])
        )

        // Unshifted codepoint: the character with no modifiers applied.
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp {
            if let chars = event.characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first {
                keyEvent.unshifted_codepoint = codepoint.value
            }
        }

        return keyEvent
    }

    // MARK: - Modifier Translation

    /// Translate NSEvent.ModifierFlags to ghostty_input_mods_e.
    static func translateModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue

        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        if flags.contains(.numericPad) { mods |= GHOSTTY_MODS_NUM.rawValue }

        // Handle sided modifiers using raw device masks.
        let rawFlags = flags.rawValue
        if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }

        return ghostty_input_mods_e(mods)
    }

    /// Convert ghostty_input_mods_e back to NSEvent.ModifierFlags.
    static func modifierFlags(from mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }

    // MARK: - Mouse Button Translation

    /// Translate an NSEvent button number to ghostty_input_mouse_button_e.
    static func translateMouseButton(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 0: return GHOSTTY_MOUSE_LEFT
        case 1: return GHOSTTY_MOUSE_RIGHT
        case 2: return GHOSTTY_MOUSE_MIDDLE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    /// Translate an NSEvent to a mouse button enum based on event type.
    static func translateMouseButtonFromType(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            return GHOSTTY_MOUSE_LEFT
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return GHOSTTY_MOUSE_RIGHT
        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            return event.buttonNumber == 2 ? GHOSTTY_MOUSE_MIDDLE : GHOSTTY_MOUSE_UNKNOWN
        default:
            return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    // MARK: - Scroll Translation

    /// Translate scroll event modifiers into the ghostty packed scroll mods format.
    ///
    /// ghostty ScrollMods is packed struct(u8) (see ghostty/src/input/mouse.zig):
    /// - Bit 0: precision scrolling flag (trackpad/Magic Mouse = true)
    /// - Bits 1-3: momentum phase (shifted left by 1)
    /// - Bits 4-7: padding
    static func translateScrollMods(_ event: NSEvent) -> ghostty_input_scroll_mods_t {
        var mods: Int32 = 0

        // Bit 0: precision flag.
        if event.hasPreciseScrollingDeltas {
            mods |= 1
        }

        // Bits 1-3: momentum phase (shifted left by 1).
        let momentum = translateMomentumPhase(event.momentumPhase)
        mods |= Int32(momentum.rawValue) << 1

        return ghostty_input_scroll_mods_t(mods)
    }

    /// Translate NSEvent.Phase to ghostty_input_mouse_momentum_e.
    static func translateMomentumPhase(_ phase: NSEvent.Phase) -> ghostty_input_mouse_momentum_e {
        if phase.contains(.began) { return GHOSTTY_MOUSE_MOMENTUM_BEGAN }
        if phase.contains(.stationary) { return GHOSTTY_MOUSE_MOMENTUM_STATIONARY }
        if phase.contains(.changed) { return GHOSTTY_MOUSE_MOMENTUM_CHANGED }
        if phase.contains(.ended) { return GHOSTTY_MOUSE_MOMENTUM_ENDED }
        if phase.contains(.cancelled) { return GHOSTTY_MOUSE_MOMENTUM_CANCELLED }
        if phase.contains(.mayBegin) { return GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN }
        return GHOSTTY_MOUSE_MOMENTUM_NONE
    }

    // MARK: - Text Helpers

    /// Returns the text to set for a key event for ghostty.
    ///
    /// Contains logic to avoid control characters, since ghostty handles
    /// control character mapping internally via KeyEncoder.
    static func ghosttyCharacters(from event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }

        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            // Single control character: return characters without control pressed.
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }

            // Private Use Area (function keys): don't send to ghostty.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return characters
    }
}
