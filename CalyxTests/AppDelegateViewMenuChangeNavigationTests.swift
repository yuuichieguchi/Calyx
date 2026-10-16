//
//  AppDelegateViewMenuChangeNavigationTests.swift
//  CalyxTests
//
//  Pins the View menu's "Go to Next/Previous Change" key equivalents
//  (VS Code Alt+F5 / Shift+Alt+F5). AppKit reports function keys with
//  `.function` in the event's modifier flags, so the menu must match a
//  synthesized F5 key-down carrying [.option, .function] /
//  [.option, .shift, .function]. Same direct-call safety argument as
//  `AppDelegateHelpMenuTests`: `setupMainMenu()` only builds menu objects.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
private final class ChangeNavigationRecorder: NSObject {
    var calls: [String] = []
    @objc func goToNextChange(_ sender: Any?) { calls.append("next") }
    @objc func goToPreviousChange(_ sender: Any?) { calls.append("previous") }
}

@MainActor
final class AppDelegateViewMenuChangeNavigationTests: XCTestCase {

    private func f5Event(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        let f5 = String(try XCTUnwrap(UnicodeScalar(NSF5FunctionKey)))
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: f5, charactersIgnoringModifiers: f5,
            isARepeat: false, keyCode: 96
        ))
    }

    func test_viewMenu_optionF5_and_shiftOptionF5_matchChangeNavigationItems() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let viewMenu = try XCTUnwrap(mainMenu.items.compactMap(\.submenu).first { $0.title == "View" })
        let next = try XCTUnwrap(viewMenu.items.first { $0.title == "Go to Next Change" })
        let previous = try XCTUnwrap(viewMenu.items.first { $0.title == "Go to Previous Change" })
        XCTAssertEqual(next.action, #selector(CalyxWindowController.goToNextChange(_:)))
        XCTAssertEqual(previous.action, #selector(CalyxWindowController.goToPreviousChange(_:)))

        // Route the actions to a recorder (no window controller in tests).
        let recorder = ChangeNavigationRecorder()
        viewMenu.autoenablesItems = false
        next.target = recorder
        previous.target = recorder

        XCTAssertTrue(viewMenu.performKeyEquivalent(with: try f5Event([.option, .function])))
        XCTAssertTrue(viewMenu.performKeyEquivalent(with: try f5Event([.option, .shift, .function])))
        XCTAssertEqual(recorder.calls, ["next", "previous"])
    }
}
