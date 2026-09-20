//
//  AppDelegateHelpMenuTests.swift
//  CalyxTests
//
//  Pins the Help menu added to `setupMainMenu()`: Calyx had no Help menu
//  at all, so there was no menu-bar route to the hosted documentation
//  (https://help.getcalyx.app/) -- the only pointer to it lived in the
//  README. Modeled on Ghostty's own Help menu (MainMenu.xib: a
//  `systemMenu="help"` menu whose single item is "Ghostty Help" on
//  Cmd+?).
//
//  Four properties are worth pinning separately:
//    - the item EXISTS and is titled exactly "Calyx Help",
//    - it is wired to `openCalyxHelp(_:)` (pinned as a selector-name
//      STRING, matching `AppDelegateSessionBrowserMenuItemTests`' own
//      idiom, so this file never needs the private method to be visible),
//    - its action is NOT `showHelp:` and its target is NOT nil -- the
//      shipped-and-reported regression this file exists to prevent, and
//    - its menu is registered as `NSApp.helpMenu` -- that registration,
//      not merely the title "Help", is what makes macOS insert its own
//      Search field into the menu.
//
//  THE REGRESSION: the first cut of this menu item used
//  `#selector(showHelp(_:))` with a nil target. `NSApplication` itself
//  implements `showHelp:`, and `-[NSApplication targetForAction:]`
//  reaches NSApp (step 3) BEFORE NSApp's delegate (step 4), so the
//  AppDelegate method never ran: clicking "Calyx Help" put up AppKit's
//  own "Help isn't available for Calyx." alert instead of opening
//  https://help.getcalyx.app/. Two independent guards now exist (a
//  selector AppKit does not implement, and an explicit target), and the
//  test below pins both -- either one alone would keep working if the
//  other were removed by accident, which is exactly why neither may be
//  silently dropped.
//
//  Same direct-call safety argument as
//  `AppDelegateSessionBrowserMenuItemTests`: `setupMainMenu()` only
//  builds NSMenu/NSMenuItem objects and assigns `NSApp.mainMenu`.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateHelpMenuTests: XCTestCase {

    func test_setupMainMenu_addsHelpMenu_withCalyxHelpItemOnCmdQuestionMark() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()

        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let helpMenu = try XCTUnwrap(
            mainMenu.items.compactMap(\.submenu).first(where: { $0.title == "Help" }),
            "setupMainMenu must add a top-level \"Help\" menu"
        )

        let helpItem = try XCTUnwrap(
            helpMenu.items.first(where: { $0.title == "Calyx Help" }),
            "The Help menu must contain an item titled exactly \"Calyx Help\""
        )
        XCTAssertEqual(helpItem.keyEquivalent, "?",
                       "\"Calyx Help\" must use the system-standard Cmd+? help shortcut")
        XCTAssertEqual(helpItem.keyEquivalentModifierMask, [.command],
                       "\"Calyx Help\" must use Cmd+? -- no extra modifiers")
        XCTAssertEqual(helpItem.action.map(NSStringFromSelector), "openCalyxHelp:",
                       "\"Calyx Help\" must be wired to AppDelegate.openCalyxHelp(_:), which opens the docs site")
    }

    /// The reported regression, pinned from both sides (see this file's
    /// header): AppKit's own `NSApplication.showHelp(_:)` must never be
    /// what this item resolves to.
    func test_calyxHelpItem_doesNotUseAppKitShowHelpSelector_andHasExplicitTarget() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()

        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let helpMenu = try XCTUnwrap(
            mainMenu.items.compactMap(\.submenu).first(where: { $0.title == "Help" }),
            "setupMainMenu must add a top-level \"Help\" menu"
        )
        let helpItem = try XCTUnwrap(
            helpMenu.items.first(where: { $0.title == "Calyx Help" }),
            "The Help menu must contain an item titled exactly \"Calyx Help\""
        )

        XCTAssertNotEqual(
            helpItem.action.map(NSStringFromSelector), "showHelp:",
            "\"Calyx Help\" must NOT use the selector `showHelp:` -- NSApplication implements it, and " +
            "targetForAction: reaches NSApp before its delegate, so AppKit's \"Help isn't available\" " +
            "alert wins instead of opening the docs site."
        )
        XCTAssertTrue(
            helpItem.target as AnyObject? === appDelegate,
            "\"Calyx Help\" must target the AppDelegate explicitly, so resolution can never fall through " +
            "to NSApp's own help handling."
        )
    }

    /// Help must be the LAST top-level menu (macOS convention, and where
    /// AppKit itself expects to find it), and the menu registered as
    /// `NSApp.helpMenu` must be that same menu object.
    func test_setupMainMenu_helpMenuIsLast_andRegisteredAsAppHelpMenu() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()

        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let lastSubmenu = try XCTUnwrap(mainMenu.items.last?.submenu, "The last top-level menu must have a submenu")
        XCTAssertEqual(lastSubmenu.title, "Help", "Help must be the last top-level menu")
        XCTAssertTrue(NSApp.helpMenu === lastSubmenu,
                      "setupMainMenu must assign the Help menu to NSApp.helpMenu so macOS treats it as THE help menu")
    }
}
