//
//  AppDelegateKeyMonitorTests.swift
//  CalyxTests
//
//  Tests for AppDelegate.matchKeyEvent(_:isUITesting:) — the pure static
//  function that translates an NSEvent into a KeyMonitorAction (or nil
//  when the event should be passed through to the responder chain).
//
//  Red phase (TDD): AppDelegate.matchKeyEvent and AppDelegate.KeyMonitorAction
//  do not exist yet. These tests MUST fail to compile until the Swift
//  specialist adds the extension in AppDelegate.swift.
//
//  Coverage:
//  - PRIMARY bug fix (Issue #27):
//      * Cmd+Shift+]  -> .nextTab
//      * Cmd+Shift+[  -> .previousTab
//  - Regression (existing key-monitor shortcuts):
//      * Cmd+Shift+P  -> .commandPalette
//      * Cmd+Shift+U  -> .unreadTab
//      * Cmd+1..Cmd+9 -> .selectTab(0..8)
//      * Ctrl+Shift+D (isUITesting: true)  -> .debugSelect
//      * Ctrl+Shift+D (isUITesting: false) -> nil
//  - Negative cases (no match -> nil):
//      * Plain "]" (no modifiers)
//      * Cmd+] (missing shift)
//      * Ctrl+Shift+] (wrong modifier set; handled by Window > Group menu)
//

import XCTest
@testable import Calyx
@preconcurrency import AppKit

@MainActor
final class AppDelegateKeyMonitorTests: XCTestCase {

    // MARK: - Helpers

    /// Keycodes relied upon in the assertions below.
    /// Values come from `HIToolbox/Events.h` (US layout) and are the same
    /// constants used by the Swift specialist's planned `matchKeyEvent`
    /// implementation.
    private enum KC {
        static let rightBracket: UInt16 = 30 // "]"
        static let leftBracket: UInt16 = 33  // "["
        static let p: UInt16 = 35
        static let u: UInt16 = 32
        static let d: UInt16 = 2
        // Number row 1..9 (0x12...0x19)
        static let one: UInt16 = 18
        static let two: UInt16 = 19
        static let three: UInt16 = 20
        static let four: UInt16 = 21
        static let five: UInt16 = 23
        static let six: UInt16 = 22
        static let seven: UInt16 = 26
        static let eight: UInt16 = 28
        static let nine: UInt16 = 25
    }

    /// Create a synthetic key-down NSEvent for use in tests.
    ///
    /// - Parameters:
    ///   - modifiers: modifier flag set (e.g. `[.command, .shift]`).
    ///   - keyCode: HIToolbox virtual key code.
    ///   - characters: printable characters the event would produce *with*
    ///     modifiers applied (the unused but required argument).
    ///   - charactersIgnoringModifiers: the canonical characters with the
    ///     modifier keys removed — the value that `matchKeyEvent` inspects.
    private func makeKeyEvent(
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        characters: String,
        charactersIgnoringModifiers: String
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    // ==================== PRIMARY bug-fix tests (Issue #27) ====================

    /// Cmd+Shift+] on a diff tab must resolve to `.nextTab` so the key
    /// monitor can bypass NSTextView's default `alignRight:` binding and
    /// forward the shortcut to `selectNextTab(_:)`.
    ///
    /// NOTE: `characters` / `charactersIgnoringModifiers` are set to the
    /// shifted form (`"}"`) because `NSEvent.charactersIgnoringModifiers`
    /// APPLIES Shift — so a real `Cmd+Shift+]` keystroke reports `"}"`, not
    /// `"]"`. The production matcher uses keyCode (30), so passing the
    /// realistic character string here also guards against any accidental
    /// re-introduction of character-based comparison.
    func test_matchKeyEvent_cmdShiftRightBracket_returnsNextTab() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .shift],
            keyCode: KC.rightBracket,
            characters: "}",
            charactersIgnoringModifiers: "}"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+Shift+]")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertEqual(
            result, .nextTab,
            "Cmd+Shift+] must resolve to .nextTab so diff tabs can navigate forward (Issue #27)"
        )
    }

    /// Cmd+Shift+[ on a diff tab must resolve to `.previousTab` so the
    /// key monitor can bypass NSTextView's default `alignLeft:` binding
    /// and forward the shortcut to `selectPreviousTab(_:)`.
    ///
    /// NOTE: Shifted character form (`"{"`) used for the same reason as
    /// `test_matchKeyEvent_cmdShiftRightBracket_returnsNextTab` above.
    func test_matchKeyEvent_cmdShiftLeftBracket_returnsPreviousTab() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .shift],
            keyCode: KC.leftBracket,
            characters: "{",
            charactersIgnoringModifiers: "{"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+Shift+[")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertEqual(
            result, .previousTab,
            "Cmd+Shift+[ must resolve to .previousTab so diff tabs can navigate backward (Issue #27)"
        )
    }

    /// The `isUITesting` flag must NOT suppress the Issue #27 fix — it only
    /// gates the debug-select hook. Regression test for Cmd+Shift+].
    func test_matchKeyEvent_cmdShiftRightBracket_withUITesting_stillReturnsNextTab() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .shift],
            keyCode: KC.rightBracket,
            characters: "}",
            charactersIgnoringModifiers: "}"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+Shift+]")
            return
        }

        XCTAssertEqual(
            AppDelegate.matchKeyEvent(event, isUITesting: true), .nextTab,
            "isUITesting must not suppress the Issue #27 fix for Cmd+Shift+]"
        )
    }

    /// Symmetric regression test for Cmd+Shift+[ under `isUITesting: true`.
    func test_matchKeyEvent_cmdShiftLeftBracket_withUITesting_stillReturnsPreviousTab() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .shift],
            keyCode: KC.leftBracket,
            characters: "{",
            charactersIgnoringModifiers: "{"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+Shift+[")
            return
        }

        XCTAssertEqual(
            AppDelegate.matchKeyEvent(event, isUITesting: true), .previousTab,
            "isUITesting must not suppress the Issue #27 fix for Cmd+Shift+["
        )
    }

    /// The `matchKeyEvent` docstring promises that incidental flags such as
    /// `.capsLock` are stripped by the modifier intersection. Prove it for
    /// Cmd+Shift+]. One CapsLock test is sufficient — the intersection
    /// logic is shared by every shortcut in the matcher.
    func test_matchKeyEvent_cmdShiftRightBracket_withCapsLock_stillReturnsNextTab() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .shift, .capsLock],
            keyCode: KC.rightBracket,
            characters: "}",
            charactersIgnoringModifiers: "}"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+Shift+] with CapsLock")
            return
        }

        XCTAssertEqual(
            AppDelegate.matchKeyEvent(event, isUITesting: false), .nextTab,
            "Incidental .capsLock must not block the Cmd+Shift+] match"
        )
    }

    // ==================== Regression tests for existing shortcuts ====================

    func test_matchKeyEvent_cmdShiftP_returnsCommandPalette() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .shift],
            keyCode: KC.p,
            characters: "P",
            charactersIgnoringModifiers: "P"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+Shift+P")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertEqual(
            result, .commandPalette,
            "Cmd+Shift+P must still resolve to .commandPalette after the refactor"
        )
    }

    func test_matchKeyEvent_cmdShiftU_returnsUnreadTab() {
        guard let event = makeKeyEvent(
            modifiers: [.command, .shift],
            keyCode: KC.u,
            characters: "U",
            charactersIgnoringModifiers: "U"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+Shift+U")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertEqual(
            result, .unreadTab,
            "Cmd+Shift+U must still resolve to .unreadTab after the refactor"
        )
    }

    func test_matchKeyEvent_cmd1_returnsSelectTabZero() {
        guard let event = makeKeyEvent(
            modifiers: [.command],
            keyCode: KC.one,
            characters: "1",
            charactersIgnoringModifiers: "1"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+1")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertEqual(
            result, .selectTab(0),
            "Cmd+1 must resolve to .selectTab(0) — indices are 0-based"
        )
    }

    func test_matchKeyEvent_cmd9_returnsSelectTabEight() {
        guard let event = makeKeyEvent(
            modifiers: [.command],
            keyCode: KC.nine,
            characters: "9",
            charactersIgnoringModifiers: "9"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+9")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertEqual(
            result, .selectTab(8),
            "Cmd+9 must resolve to .selectTab(8) — indices are 0-based"
        )
    }

    /// Mid-range coverage to defend against an off-by-one regression in the
    /// `0x31...0x39` scalar-range check. Cmd+1 and Cmd+9 alone do not prove
    /// that every intermediate digit also maps correctly.
    func test_matchKeyEvent_cmd5_returnsSelectTabFour() {
        guard let event = makeKeyEvent(
            modifiers: [.command],
            keyCode: KC.five,
            characters: "5",
            charactersIgnoringModifiers: "5"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+5")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertEqual(
            result, .selectTab(4),
            "Cmd+5 must resolve to .selectTab(4) — indices are 0-based"
        )
    }

    /// Cmd+0 is deliberately NOT registered (there is no 10th tab slot in
    /// the menu). The matcher must return `nil` so the event can flow
    /// through to any other binding. Boundary-negative for the Cmd+1..9
    /// range.
    func test_matchKeyEvent_cmd0_returnsNil() {
        // keyCode for "0" on US layout is 29 (kVK_ANSI_0); not in the KC
        // enum because it is not otherwise referenced.
        guard let event = makeKeyEvent(
            modifiers: [.command],
            keyCode: 29,
            characters: "0",
            charactersIgnoringModifiers: "0"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+0")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertNil(
            result,
            "Cmd+0 is not registered and must not match any KeyMonitorAction"
        )
    }

    // ==================== Negative tests (no match -> nil) ====================

    /// A bare "]" with no modifiers must not be intercepted — it should
    /// flow through to the first responder (e.g. SurfaceView or text field).
    func test_matchKeyEvent_plainRightBracket_returnsNil() {
        guard let event = makeKeyEvent(
            modifiers: [],
            keyCode: KC.rightBracket,
            characters: "]",
            charactersIgnoringModifiers: "]"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for plain ]")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertNil(
            result,
            "Plain ] (no modifiers) must not match any KeyMonitorAction"
        )
    }

    /// Cmd+] without shift is a different shortcut (potentially bound by
    /// the terminal itself). It must not resolve to `.nextTab`.
    func test_matchKeyEvent_cmdRightBracket_returnsNil() {
        guard let event = makeKeyEvent(
            modifiers: [.command],
            keyCode: KC.rightBracket,
            characters: "]",
            charactersIgnoringModifiers: "]"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Cmd+]")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertNil(
            result,
            "Cmd+] (without shift) must not match any KeyMonitorAction"
        )
    }

    /// Ctrl+Shift+] is owned by the Window > Group menu (group navigation).
    /// The AppDelegate key monitor must not claim it.
    func test_matchKeyEvent_ctrlShiftRightBracket_returnsNil() {
        guard let event = makeKeyEvent(
            modifiers: [.control, .shift],
            keyCode: KC.rightBracket,
            characters: "]",
            charactersIgnoringModifiers: "]"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Ctrl+Shift+]")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertNil(
            result,
            "Ctrl+Shift+] is handled by the Window > Group menu (group navigation); the key monitor must not claim it"
        )
    }

    // ==================== UI-testing hook (Ctrl+Shift+D) ====================

    /// Ctrl+Shift+D is only active when Calyx is launched with the
    /// --uitesting flag. In normal runs the same event must pass through.
    func test_matchKeyEvent_ctrlShiftD_withoutUITesting_returnsNil() {
        guard let event = makeKeyEvent(
            modifiers: [.control, .shift],
            keyCode: KC.d,
            characters: "D",
            charactersIgnoringModifiers: "D"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Ctrl+Shift+D")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: false)

        XCTAssertNil(
            result,
            "Ctrl+Shift+D must return nil when isUITesting is false — the debug hook is disabled in normal runs"
        )
    }

    func test_matchKeyEvent_ctrlShiftD_withUITesting_returnsDebugSelect() {
        guard let event = makeKeyEvent(
            modifiers: [.control, .shift],
            keyCode: KC.d,
            characters: "D",
            charactersIgnoringModifiers: "D"
        ) else {
            XCTFail("Failed to create synthetic NSEvent for Ctrl+Shift+D")
            return
        }

        let result = AppDelegate.matchKeyEvent(event, isUITesting: true)

        XCTAssertEqual(
            result, .debugSelect,
            "Ctrl+Shift+D must resolve to .debugSelect when isUITesting is true"
        )
    }
}
