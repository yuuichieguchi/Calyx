//
//  AppDelegateViewMenuWordWrapTests.swift
//  CalyxTests
//
//  Pins the View menu's "Word Wrap" item (VS Code
//  editor.action.toggleWordWrap, Alt+Z): action, key equivalent "z" with
//  [.option], and that NSMenu matches a synthesized Option+Z key-down
//  (characters "Ω", charactersIgnoringModifiers "z"). A disabled item must
//  not consume the event, so terminal tabs keep Option+Z.
//  Mirrors AppDelegateViewMenuChangeNavigationTests.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
private final class WordWrapRecorder: NSObject {
    var calls = 0
    @objc func toggleDiffWordWrap(_ sender: Any?) { calls += 1 }
}

@MainActor
final class AppDelegateViewMenuWordWrapTests: XCTestCase {

    private func optionZEvent() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
            windowNumber: 0, context: nil, characters: "Ω", charactersIgnoringModifiers: "z",
            isARepeat: false, keyCode: 6
        ))
    }

    private func wordWrapItem() throws -> (NSMenu, NSMenuItem) {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let viewMenu = try XCTUnwrap(mainMenu.items.compactMap(\.submenu).first { $0.title == "View" })
        let item = try XCTUnwrap(viewMenu.items.first { $0.title == "Word Wrap" }, "View menu must contain Word Wrap")
        return (viewMenu, item)
    }

    func test_viewMenu_wordWrapItem_actionAndKeyEquivalent() throws {
        let (_, item) = try wordWrapItem()
        XCTAssertEqual(item.action, #selector(CalyxWindowController.toggleDiffWordWrap(_:)))
        XCTAssertEqual(item.keyEquivalent, "z")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.option])
    }

    func test_viewMenu_optionZ_firesWordWrapItem() throws {
        let (viewMenu, item) = try wordWrapItem()
        let recorder = WordWrapRecorder()
        viewMenu.autoenablesItems = false
        item.target = recorder
        item.isEnabled = true

        XCTAssertTrue(viewMenu.performKeyEquivalent(with: try optionZEvent()))
        XCTAssertEqual(recorder.calls, 1)
    }

    func test_viewMenu_optionZ_disabledItem_doesNotConsumeEvent() throws {
        let (viewMenu, item) = try wordWrapItem()
        let recorder = WordWrapRecorder()
        viewMenu.autoenablesItems = false
        item.target = recorder
        item.isEnabled = false

        XCTAssertFalse(viewMenu.performKeyEquivalent(with: try optionZEvent()))
        XCTAssertEqual(recorder.calls, 0)
    }
}
