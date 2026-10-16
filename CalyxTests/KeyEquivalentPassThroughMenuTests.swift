//
//  KeyEquivalentPassThroughMenuTests.swift
//  CalyxTests
//
//  KeyEquivalentPassThroughMenu: an enabled match fires and is consumed, a
//  disabled match is not consumed, and no match falls through to NSMenu.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
private final class PassThroughRecorder: NSObject {
    var calls = 0
    @objc func fire(_ sender: Any?) { calls += 1 }
}

/// Counts menu validations; enables items per `enabled`.
@MainActor
private final class ValidatingRecorder: NSObject, NSMenuItemValidation {
    var calls = 0
    var validations = 0
    let enabled: Bool
    init(enabled: Bool) { self.enabled = enabled }
    @objc func fire(_ sender: Any?) { calls += 1 }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validations += 1
        return enabled
    }
}

@MainActor
final class KeyEquivalentPassThroughMenuTests: XCTestCase {

    private func keyEvent(_ chars: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: 0
        ))
    }

    private func makeMenu(enabled: Bool) -> (KeyEquivalentPassThroughMenu, PassThroughRecorder) {
        let menu = KeyEquivalentPassThroughMenu(title: "Test")
        menu.autoenablesItems = false
        let recorder = PassThroughRecorder()
        let item = NSMenuItem(title: "Item", action: #selector(PassThroughRecorder.fire(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.option]
        item.target = recorder
        item.isEnabled = enabled
        menu.addItem(item)
        return (menu, recorder)
    }

    func test_enabledMatch_consumesAndFires() throws {
        let (menu, recorder) = makeMenu(enabled: true)
        XCTAssertTrue(menu.performKeyEquivalent(with: try keyEvent("k", [.option])))
        XCTAssertEqual(recorder.calls, 1)
    }

    func test_disabledMatch_doesNotConsume() throws {
        let (menu, recorder) = makeMenu(enabled: false)
        XCTAssertFalse(menu.performKeyEquivalent(with: try keyEvent("k", [.option])))
        XCTAssertEqual(recorder.calls, 0)
    }

    func test_noMatch_fallsThroughToSuper() throws {
        let (menu, recorder) = makeMenu(enabled: true)
        let event = try keyEvent("j", [.option])
        let plain = NSMenu(title: "Plain")
        XCTAssertEqual(menu.performKeyEquivalent(with: event), plain.performKeyEquivalent(with: event))
        XCTAssertFalse(menu.performKeyEquivalent(with: try keyEvent("k", [.command])))
        XCTAssertEqual(recorder.calls, 0)
    }

    func test_noTopLevelMatch_submenuStillSearchedBySuper() throws {
        let (sub, recorder) = makeMenu(enabled: true)
        let menu = KeyEquivalentPassThroughMenu(title: "Root")
        let holder = NSMenuItem(title: "Sub", action: nil, keyEquivalent: "")
        holder.submenu = sub
        menu.addItem(holder)
        XCTAssertTrue(menu.performKeyEquivalent(with: try keyEvent("k", [.option])))
        XCTAssertEqual(recorder.calls, 1)
    }

    /// A disabled item must not block a later enabled item with the same
    /// shortcut.
    func test_disabledThenEnabledSameShortcut_enabledFires() throws {
        let menu = KeyEquivalentPassThroughMenu(title: "Test")
        menu.autoenablesItems = false
        let disabledTarget = PassThroughRecorder()
        let enabledTarget = PassThroughRecorder()
        for (target, enabled) in [(disabledTarget, false), (enabledTarget, true)] {
            let item = NSMenuItem(title: "Item", action: #selector(PassThroughRecorder.fire(_:)), keyEquivalent: "k")
            item.keyEquivalentModifierMask = [.option]
            item.target = target
            item.isEnabled = enabled
            menu.addItem(item)
        }
        XCTAssertEqual(KeyEquivalentPassThroughMenu.matchingItems(in: menu.items,
                                                                  for: try keyEvent("k", [.option])).count, 2)
        XCTAssertTrue(menu.performKeyEquivalent(with: try keyEvent("k", [.option])))
        XCTAssertEqual(disabledTarget.calls, 0)
        XCTAssertEqual(enabledTarget.calls, 1)
    }

    private func makeValidatedMenu(_ menu: NSMenu, autoenables: Bool, enabled: Bool) -> ValidatingRecorder {
        menu.autoenablesItems = autoenables
        let recorder = ValidatingRecorder(enabled: enabled)
        let item = NSMenuItem(title: "Item", action: #selector(ValidatingRecorder.fire(_:)), keyEquivalent: "k")
        item.keyEquivalentModifierMask = [.option]
        item.target = recorder
        menu.addItem(item)
        return recorder
    }

    /// No top-level match: the pass-through check validates nothing beyond
    /// what plain NSMenu does.
    func test_noMatch_addsNoValidation() throws {
        let oursMenu = KeyEquivalentPassThroughMenu(title: "Ours")
        let ours = makeValidatedMenu(oursMenu, autoenables: true, enabled: true)
        let plainMenu = NSMenu(title: "Plain")
        let plain = makeValidatedMenu(plainMenu, autoenables: true, enabled: true)
        XCTAssertEqual(oursMenu.performKeyEquivalent(with: try keyEvent("j", [.option])),
                       plainMenu.performKeyEquivalent(with: try keyEvent("j", [.option])))
        XCTAssertEqual(ours.validations, plain.validations)
    }

    /// autoenablesItems false: no validation at all; the item's own
    /// isEnabled decides.
    func test_autoenablesOff_doesNotValidate() throws {
        let menu = KeyEquivalentPassThroughMenu(title: "Test")
        let recorder = makeValidatedMenu(menu, autoenables: false, enabled: false)
        XCTAssertTrue(menu.performKeyEquivalent(with: try keyEvent("k", [.option])))
        XCTAssertEqual(recorder.validations, 0)
        XCTAssertEqual(recorder.calls, 1)
    }

    /// autoenablesItems true: a validator-disabled match is not consumed.
    func test_autoenablesOn_validatorDisabled_doesNotConsume() throws {
        let menu = KeyEquivalentPassThroughMenu(title: "Test")
        let recorder = makeValidatedMenu(menu, autoenables: true, enabled: false)
        XCTAssertFalse(menu.performKeyEquivalent(with: try keyEvent("k", [.option])))
        XCTAssertEqual(recorder.calls, 0)
        XCTAssertGreaterThanOrEqual(recorder.validations, 1)
    }
}
