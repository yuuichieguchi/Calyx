//
//  AppDelegateSessionBrowserMenuItemTests.swift
//  CalyxTests
//
//  TDD Red phase (user-reported gap, same area as the attach-as-tab fix):
//  there is NO menu bar item to open the session browser at all today --
//  grepped setupMainMenu (AppDelegate.swift) for any addItem referencing
//  SessionBrowserWindowController/showBrowser and found none; the only
//  paths in are the command-palette entries (session.attach,
//  session.newRemote, CalyxWindowController.swift ~537/594) and a button
//  inside Settings. A menu item is the conventional, discoverable way to
//  reach an app-level panel on macOS.
//
//  PLACEMENT: the View menu, right after "Quick Terminal" -- the closest
//  existing siblings for "reveal an app-level panel" are already there
//  ("Toggle Sidebar", "Command Palette", "Quick Terminal"); Window menu
//  is exclusively window/tab/group arrangement (Minimize, Zoom, Select
//  Tab, Group, Bring All to Front) with nothing resembling an app-level
//  panel-revealer. Flagged for review as a judgment call, not a hard
//  investigated fact.
//
//  SHORTCUT: Cmd+Shift+B. Enumerated every keyEquivalent +
//  keyEquivalentModifierMask pair setupMainMenu currently registers (by
//  reading the method start to finish, not by running it) to rule out
//  a conflict by hand first:
//    Cmd+, (Preferences) Cmd+H (Hide) Cmd+Opt+H (Hide Others) Cmd+Q (Quit)
//    Cmd+N (New Window) Cmd+T (New Tab) Cmd+D (Split Right)
//    Cmd+Shift+D (Split Down) Cmd+W (Close Tab)
//    Cmd+Z (Undo) Cmd+Shift+Z (Redo) Cmd+C (Copy) Cmd+V (Paste)
//    Cmd+A (Select All) Cmd+F (Find) Cmd+G (Find Next)
//    Cmd+Shift+G (Find Previous) Cmd+Shift+E (Compose Input)
//    Cmd+Opt+S (Toggle Sidebar) Cmd+Shift+P (Command Palette)
//    Cmd+M (Minimize) Cmd+Ctrl+F (Toggle Full Screen)
//    Cmd+Opt+<Up/Down/Left/Right> (Focus Split *)
//    Cmd+Shift+] (Select Next Tab) Cmd+Shift+[ (Select Previous Tab)
//    Cmd+Shift+U (Jump to Unread Tab) Cmd+1..Cmd+9 (Select Tab N)
//    Ctrl+Shift+N (New Group) Ctrl+Shift+W (Close Group)
//    Ctrl+Shift+] (Next Group) Ctrl+Shift+[ (Previous Group)
//  NOTE: the task brief's own suggested alternative, Cmd+Shift+E, is
//  already taken (Compose Input) -- confirmed by this enumeration, which
//  is exactly why this file also pins a SECOND, general test (every
//  keyEquivalent+modifierMask pair menu-tree-wide is unique) rather than
//  relying solely on hand-enumeration staying accurate over time.
//  Cmd+Shift+B is free in the list above.
//
//  PROPOSED API: a new `@objc` AppDelegate method (name pinned by this
//  file via a selector-name STRING, not a live `#selector` reference, so
//  this file compiles today without the method existing yet -- see
//  "Testability" below): `openSessionBrowser(_:)`, calling
//  `SessionBrowserWindowController.shared.showBrowser()` (same call
//  every existing entry point already makes). A new `NSMenuItem(title:
//  "Session Browser", action: #selector(openSessionBrowser(_:)),
//  keyEquivalent: "b")` with `keyEquivalentModifierMask = [.command,
//  .shift]`, appended to the View menu after the existing "Quick
//  Terminal" item.
//
//  Testability: `setupMainMenu()` was `private`; un-privated (see its own
//  updated doc comment in AppDelegate.swift) following this codebase's
//  established "un-privated for direct test access" precedent. It only
//  builds NSMenu/NSMenuItem objects and assigns `NSApp.mainMenu` at the
//  very end -- no ghostty surface, no window, no async work -- so
//  calling it directly on a bare `AppDelegate()` in this test host is
//  safe (unlike `attachWindow`/`showWindow`, which hang the process; see
//  `AppDelegateAttachWindowTests`'s header for that contrast).
//
//  Neither the menu item nor `openSessionBrowser(_:)` exist yet -- this
//  file compiles against TODAY's code (it references no not-yet-existing
//  Swift symbol; the expected action name is a string literal) and fails
//  via genuine runtime assertion failures (item not found) instead, so
//  no held-out/compile-RED file was needed.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateSessionBrowserMenuItemTests: XCTestCase {

    /// Recursively collects every `NSMenuItem` in `menu` and all of its
    /// submenus (depth-first), mirroring how a user could reach any item
    /// regardless of nesting (e.g. "Focus Split Up" three levels down).
    private func allItems(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu {
                return [item] + allItems(in: submenu)
            }
            return [item]
        }
    }

    func test_setupMainMenu_containsSessionBrowserMenuItem_titledExactlyAndShortcutCmdShiftB() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()

        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let items = allItems(in: mainMenu)

        let sessionBrowserItem = try XCTUnwrap(
            items.first(where: { $0.title == "Session Browser" }),
            "setupMainMenu must add a menu item titled exactly \"Session Browser\" somewhere in the menu " +
            "bar -- there is currently no way to open the session browser from the menu bar at all"
        )

        XCTAssertEqual(sessionBrowserItem.keyEquivalent, "b",
                       "The Session Browser menu item's key equivalent must be \"b\" (for Cmd+Shift+B)")
        XCTAssertEqual(sessionBrowserItem.keyEquivalentModifierMask, [.command, .shift],
                       "The Session Browser menu item's shortcut must be Cmd+Shift+B")
        XCTAssertEqual(sessionBrowserItem.action.map(NSStringFromSelector), "openSessionBrowser:",
                       "The Session Browser menu item must be wired to AppDelegate.openSessionBrowser(_:), " +
                       "which opens SessionBrowserWindowController.shared")
    }

    /// General invariant, not tied to any one hand-picked shortcut: no
    /// two items anywhere in the whole menu tree share the same
    /// (keyEquivalent, keyEquivalentModifierMask) pair. Proves the new
    /// Cmd+Shift+B assignment above doesn't collide with anything
    /// (today or in the future, if other shortcuts change), without
    /// relying solely on the header comment's hand enumeration staying
    /// accurate. Items with an empty keyEquivalent (submenu parents like
    /// "Find"/"Group", and items with genuinely no shortcut like "Zoom")
    /// are excluded -- an empty keyEquivalent is "no shortcut", not a
    /// conflict target.
    func test_setupMainMenu_everyShortcutInTheMenuTree_isUnique() throws {
        let appDelegate = AppDelegate()
        appDelegate.setupMainMenu()

        let mainMenu = try XCTUnwrap(NSApp.mainMenu, "setupMainMenu must assign NSApp.mainMenu")
        let shortcutItems = allItems(in: mainMenu).filter { !$0.keyEquivalent.isEmpty }

        // Grouped by the physical shortcut ONLY (title deliberately
        // excluded from the key) -- two DIFFERENT-titled items sharing
        // the same keyEquivalent+modifierMask is exactly the conflict
        // this test exists to catch; grouping by title too would let
        // that slip through undetected.
        //
        // keyEquivalent's CASE is significant and must NOT be folded:
        // this codebase encodes "needs Shift" two different ways --
        // either explicitly via keyEquivalentModifierMask (e.g. Split
        // Down: "d" + [.command, .shift]) or implicitly via an uppercase
        // character with no explicit .shift in the mask (e.g. Redo: "Z"
        // + [.command] alone -- AppKit itself resolves the real shortcut
        // as Cmd+Shift+Z, since typing "Z" needs Shift on any keyboard
        // layout, independent of the mask). Folding case first was
        // tried and produces a FALSE collision between Undo ("z") and
        // Redo ("Z"), which do not actually conflict.
        let grouped = Dictionary(grouping: shortcutItems) { item in
            "\(item.keyEquivalent)+\(item.keyEquivalentModifierMask.rawValue)"
        }
        let duplicates = grouped.filter { $0.value.count > 1 }

        XCTAssertTrue(duplicates.isEmpty,
                      "Every keyEquivalent+modifier combination in the menu bar must be unique; found " +
                      "colliding entries: \(duplicates.mapValues { $0.map(\.title) })")
    }
}
