//
//  SurfaceViewKeyWindowMenuValidationTests.swift
//  CalyxTests
//
//  GitHub issue #45 follow-up (Focus Split key-window
//  gap). Full root-cause writeup: `CalyxWindowController.swift`'s
//  `keyWindowGatedActions` doc comment ("Known gap" paragraph, right next
//  to that Set's declaration) and `NSWindow+CalyxClose.swift`'s header
//  comment.
//
//  `SurfaceView.validateMenuItem(_:)` ("MARK: - Menu Actions" extension,
//  SurfaceView.swift) is reached DIRECTLY via the responder chain
//  whenever a terminal surface is focused -- `SurfaceView` sits earlier
//  in that chain than `CalyxWindowController`, so `-[NSApplication
//  targetForAction:]`'s key-window-chain-then-main-window-fallback
//  resolution (the exact mechanism issue #45 exploits) never reaches
//  `CalyxWindowController.validateMenuItem(_:)`'s own matching
//  `focusSplitLeft/Right/Up/Down(_:)` branch for these four selectors.
//  Today `SurfaceView.validateMenuItem(_:)` gates them ONLY on
//  `isActiveTabSplit` (has the active tab been split at all), with no
//  key-window check of its own -- so while a non-`CalyxWindow` panel
//  (e.g. About) is key, Cmd+Option+Arrow can still move focus inside a
//  DIFFERENT, background terminal window's split pane. Defense in depth,
//  mirroring `CalyxWindowController`'s `keyWindowGatedActions`/
//  `_isKeyWindowOverrideForTesting` shape (see `SurfaceView.swift`'s own
//  `_isKeyWindowOverrideForTesting` doc comment for the full wiring
//  rationale): gate `focusSplitLeft/Right/Up/Down(_:)` on "is THIS
//  surface's own window actually the key window", via that seam (a real
//  key-window transition needs the window server; unsafe/unavailable in
//  this test host -- see `CalyxWindowControllerCloseWindowTests`'s own
//  precondition assertion that a freshly constructed, never-shown
//  `CalyxWindow` is never key).
//
//  Against the CURRENT code, `validateMenuItem(_:)` never reads
//  `_isKeyWindowOverrideForTesting` at all (the property exists purely as
//  an unused stub seam), so:
//
//  Exactly 4 tests pin the gate itself --
//  `test_validateMenuItem_focusSplit{Left,Right,Up,Down}_
//  disabledWhenNotKeyWindow_evenWhenSplit`. Each uses a fixture whose
//  active tab IS split (`isActiveTabSplit == true`, so the PRE-EXISTING
//  gate alone would already say "enabled"), isolating that the
//  key-window gate -- not `isActiveTabSplit` -- is what must force
//  `false` here. Every other test in this first batch (through
//  `findNext:`/`findPrevious:` and the split-action guards) is a
//  regression guard: it asserts exactly what the
//  override-blind code already did, and must keep doing now that
//  the gate exists. See the paragraph below for a further 4
//  gate-pinning tests.
//
//  A second group:
//  `paste(_:)`/`copy(_:)`/`selectAll(_:)`/`pasteAsPlainText(_:)` close
//  the actual on-device defect this whole gate exists to prevent --
//  AppDelegate's Edit menu registers "Copy"/"Paste"/"Select All" via
//  `#selector(NSText.copy(_:))`/`#selector(NSText.paste(_:))`/
//  `#selector(NSText.selectAll(_:))` (AppDelegate.swift, "Edit menu"
//  section), which are the SAME Objective-C selectors (`copy:`/`paste:`/
//  `selectAll:`) as `SurfaceView`'s own identically-named `@IBAction`s
//  below -- selector-name identity, not a shared declaring type, is what
//  lets `-[NSApplication targetForAction:]` resolve those menu items to
//  `SurfaceView`'s implementations at all. Confirmed on-device: with a
//  non-`CalyxWindow` `NSPanel` reporting `canBecomeMain == false` key
//  (the standard About panel at the time; About is a plain `NSWindow`
//  today, `AboutWindowController.swift`, but the mechanism belongs to
//  `NSPanel`, not to About),
//  `NSApp.mainWindow` stays whatever `CalyxWindow` was last main, so
//  Cmd+V there silently sends the clipboard into that BACKGROUND window's
//  shell -- no visible feedback, unlike issue #45's Cmd+W (a closed tab is
//  obvious; injected shell input is not). `pasteAsPlainText(_:)` has no
//  menu item wired to it today (a dangling `@IBAction`) but is gated
//  defensively so a future menu item is covered without a second
//  follow-up. None of these four are in `keyWindowGatedActions` today, and
//  `validateMenuItem(_:)` has no per-selector branch for any of them
//  either, so all four currently fall through to the unconditional
//  `return true` at the bottom of that method -- exactly 4 more tests
//  below therefore pin the gate:
//  `test_validateMenuItem_{paste,copy,selectAll,pasteAsPlainText}_
//  disabledWhenNotKeyWindow`. Their "enabled when key" counterparts are
//  regression guards, same rationale as the focusSplit ones above,
//  proving the pre-existing return-true fallback survives once the gate
//  is added. `performFindAction(_:)` (opens the search UI -- a NEW-state
//  action, same category as `splitRight(_:)`) gets a single regression
//  guard pinning that it must NEVER be gated at all.
//
//  `findNext:`/`findPrevious:` are also exercised below ("disabled when
//  NOT key window" only -- whether to gate them at all is deliberately
//  left to the implementation). Unlike the 4 tests above, these CANNOT be
//  isolated the same way:
//  `SurfaceView.isSearchBarVisible` (`SurfaceScrollView.enclosing
//  (superview)?.isSearchBarPresented`) only ever answers `true` once a
//  `SurfaceScrollView` has actually shown its search bar, which (via
//  `.ghosttyStartSearch`) is delivered through a `queue: .main`-
//  registered observer -- an ASYNCHRONOUS hop that never fires within a
//  synchronous test body without pumping the run loop. This fixture has
//  no `SurfaceScrollView` at all, so `isSearchBarVisible` is always
//  `false` here regardless of key-window state; these two tests are
//  therefore regression guards only (mirrors
//  `CalyxWindowControllerKeyWindowMenuValidationTests`'s own `findNext`/
//  `findPrevious` tests, which carry an analogous caveat for a different
//  underlying reason -- see that file's
//  `test_validateMenuItem_findNext_disabledWhenKeyWindow_withNoVisibleSearchBar`
//  doc comment).
//
//  Fixture note: `makeFixture(split:)` attaches its `SurfaceView` into
//  the real `CalyxWindow.contentView` hierarchy so `surfaceView.window`
//  resolves back to the owning `CalyxWindowController` --
//  `isActiveTabSplit`'s own `window?.windowController as?
//  CalyxWindowController` lookup requires this. See that method's doc
//  comment below, and `test_fixture_surfaceViewWindow_resolvesToOwningController`,
//  for why this linkage is load-bearing.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class SurfaceViewKeyWindowMenuValidationTests: XCTestCase {

    // MARK: - Fixture

    private struct SurfaceFixture {
        let controller: CalyxWindowController
        let surfaceView: SurfaceView
    }

    /// Builds a `CalyxWindowController` whose active tab's split tree
    /// is (`split == true`) or is not (`split == false`) split, with
    /// `surfaceView` attached into the window's real content view
    /// hierarchy -- `SurfaceView.isActiveTabSplit`'s `window?
    /// .windowController as? CalyxWindowController` lookup (SurfaceView
    /// .swift, "MARK: - Menu Actions" extension) requires `surfaceView
    /// .window` to actually resolve to this fixture's own `CalyxWindow`,
    /// which only happens once the view is part of that window's view
    /// hierarchy -- unlike `window.windowController` itself, which
    /// `CalyxWindowController.init`'s `super.init(window:)` already sets
    /// reciprocally regardless of view hierarchy (see
    /// `CalyxWindowCalyxPerformCloseRoutingTests` for a fixture that
    /// relies on exactly that reciprocal link without ever touching
    /// `contentView`).
    ///
    /// `window.contentView` already holds `setupUI()`'s real
    /// `NSHostingView` (added synchronously inside `CalyxWindowController
    /// .init`) by the time this runs; `addSubview` below adds
    /// `surfaceView` as an extra SIBLING rather than replacing anything,
    /// so it never disturbs that hierarchy. Safe because `surfaceView`
    /// has no `surfaceController` (nil, since `initializeSurface` is
    /// never called), so `viewDidMoveToWindow()`'s ghostty-facing calls
    /// are all `?.`-guarded no-ops, and `updateTrackingAreas()` merely
    /// registers a zero-rect tracking area (mirrors `SurfaceScrollView
    /// .init`'s own unconditional `addSubview(surfaceView)`, exercised
    /// safely by `SurfaceScrollViewTests`).
    ///
    /// `restoring: true` (mirrors every other fixture in this codebase
    /// that builds a `CalyxWindowController` directly) skips `init`'s
    /// `setupTerminalSurface(host:)` call, which would otherwise create a
    /// REAL ghostty surface and hang the XCTest process (`SurfaceLocator
    /// .swift`'s header comment).
    private func makeFixture(split: Bool) -> SurfaceFixture {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        let surfaceView = SurfaceView(frame: .zero)
        registry._testInsert(view: surfaceView, id: leafID)

        let splitTree: SplitTree
        if split {
            let siblingID = UUID()
            registry._testInsert(view: SurfaceView(frame: .zero), id: siblingID)
            let root = SplitNode.split(SplitData(
                direction: .horizontal,
                ratio: 0.5,
                first: .leaf(id: leafID),
                second: .leaf(id: siblingID)
            ))
            splitTree = SplitTree(root: root, focusedLeafID: leafID)
        } else {
            splitTree = SplitTree(leafID: leafID)
        }

        let tab = Tab(splitTree: splitTree, registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)

        guard let contentView = window.contentView else {
            XCTFail("Precondition: CalyxWindowController.init must leave window.contentView non-nil")
            return SurfaceFixture(controller: controller, surfaceView: surfaceView)
        }
        contentView.addSubview(surfaceView)

        return SurfaceFixture(controller: controller, surfaceView: surfaceView)
    }

    private func menuItem(action: Selector) -> NSMenuItem {
        NSMenuItem(title: "Test", action: action, keyEquivalent: "")
    }

    // MARK: - Fixture precondition

    /// If `surfaceView.window` failed to resolve back to this fixture's
    /// own `CalyxWindowController` (e.g. the `addSubview` linkage in
    /// `makeFixture(split:)` silently broke), `isActiveTabSplit` would
    /// answer `false` UNCONDITIONALLY regardless of `split:` -- which
    /// would make every "disabledWhenNotKeyWindow_evenWhenSplit" test
    /// below pass VACUOUSLY (already `false`, for the wrong reason)
    /// instead of pinning the key-window gate. This test
    /// pins the fixture's own wiring so a broken linkage fails HERE,
    /// loudly, not silently inside an unrelated assertion (mirrors
    /// `CalyxWindowControllerCloseWindowTests`'s own precondition-
    /// assertion discipline).
    func test_fixture_surfaceViewWindow_resolvesToOwningController() {
        let fixture = makeFixture(split: true)

        XCTAssertTrue(
            fixture.surfaceView.window === fixture.controller.window,
            "Precondition: surfaceView must be part of its owning CalyxWindowController's window hierarchy"
        )
    }

    // MARK: - Focus Split disabled when NOT the key window

    func test_validateMenuItem_focusSplitLeft_disabledWhenNotKeyWindow_evenWhenSplit() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitLeft(_:))))

        XCTAssertFalse(
            result,
            "Focus Split Left must be disabled while this window is not the key window, even when the active tab is split"
        )
    }

    func test_validateMenuItem_focusSplitRight_disabledWhenNotKeyWindow_evenWhenSplit() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitRight(_:))))

        XCTAssertFalse(
            result,
            "Focus Split Right must be disabled while this window is not the key window, even when the active tab is split"
        )
    }

    func test_validateMenuItem_focusSplitUp_disabledWhenNotKeyWindow_evenWhenSplit() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitUp(_:))))

        XCTAssertFalse(
            result,
            "Focus Split Up must be disabled while this window is not the key window, even when the active tab is split"
        )
    }

    func test_validateMenuItem_focusSplitDown_disabledWhenNotKeyWindow_evenWhenSplit() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitDown(_:))))

        XCTAssertFalse(
            result,
            "Focus Split Down must be disabled while this window is not the key window, even when the active tab is split"
        )
    }

    // MARK: - Regression guards: enabled when key, isActiveTabSplit unchanged

    func test_validateMenuItem_focusSplitLeft_enabledWhenKeyWindow_withSplitTab() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitLeft(_:))))

        XCTAssertTrue(result, "Focus Split Left must stay enabled while this window IS the key window, with the active tab split")
    }

    /// Same selector, but the active tab is NOT split -- the pre-existing
    /// `isActiveTabSplit` gate must still be the thing disabling this
    /// even though the window IS key.
    func test_validateMenuItem_focusSplitLeft_disabledWhenKeyWindow_withSingleTab() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitLeft(_:))))

        XCTAssertFalse(result, "Focus Split Left must stay disabled while key, with the active tab NOT split")
    }

    func test_validateMenuItem_focusSplitRight_enabledWhenKeyWindow_withSplitTab() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitRight(_:))))

        XCTAssertTrue(result, "Focus Split Right must stay enabled while this window IS the key window, with the active tab split")
    }

    func test_validateMenuItem_focusSplitRight_disabledWhenKeyWindow_withSingleTab() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitRight(_:))))

        XCTAssertFalse(result, "Focus Split Right must stay disabled while key, with the active tab NOT split")
    }

    func test_validateMenuItem_focusSplitUp_enabledWhenKeyWindow_withSplitTab() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitUp(_:))))

        XCTAssertTrue(result, "Focus Split Up must stay enabled while this window IS the key window, with the active tab split")
    }

    func test_validateMenuItem_focusSplitUp_disabledWhenKeyWindow_withSingleTab() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitUp(_:))))

        XCTAssertFalse(result, "Focus Split Up must stay disabled while key, with the active tab NOT split")
    }

    func test_validateMenuItem_focusSplitDown_enabledWhenKeyWindow_withSplitTab() {
        let fixture = makeFixture(split: true)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitDown(_:))))

        XCTAssertTrue(result, "Focus Split Down must stay enabled while this window IS the key window, with the active tab split")
    }

    func test_validateMenuItem_focusSplitDown_disabledWhenKeyWindow_withSingleTab() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.focusSplitDown(_:))))

        XCTAssertFalse(result, "Focus Split Down must stay disabled while key, with the active tab NOT split")
    }

    // MARK: - findNext:/findPrevious: (disabled when NOT key window; see file header caveat)

    func test_validateMenuItem_findNext_disabledWhenNotKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.findNext(_:))))

        XCTAssertFalse(result, "Find Next must be disabled while this window is not the key window")
    }

    func test_validateMenuItem_findPrevious_disabledWhenNotKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.findPrevious(_:))))

        XCTAssertFalse(result, "Find Previous must be disabled while this window is not the key window")
    }

    // MARK: - Regression guards: split actions (create a NEW pane) are never key-window-gated

    func test_validateMenuItem_splitRight_enabledRegardlessOfKeyWindow() {
        let fixture = makeFixture(split: false)
        let item = menuItem(action: #selector(SurfaceView.splitRight(_:)))

        fixture.surfaceView._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Right must stay enabled while not key")

        fixture.surfaceView._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Right must stay enabled while key")
    }

    func test_validateMenuItem_splitLeft_enabledRegardlessOfKeyWindow() {
        let fixture = makeFixture(split: false)
        let item = menuItem(action: #selector(SurfaceView.splitLeft(_:)))

        fixture.surfaceView._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Left must stay enabled while not key")

        fixture.surfaceView._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Left must stay enabled while key")
    }

    func test_validateMenuItem_splitDown_enabledRegardlessOfKeyWindow() {
        let fixture = makeFixture(split: false)
        let item = menuItem(action: #selector(SurfaceView.splitDown(_:)))

        fixture.surfaceView._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Down must stay enabled while not key")

        fixture.surfaceView._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Down must stay enabled while key")
    }

    func test_validateMenuItem_splitUp_enabledRegardlessOfKeyWindow() {
        let fixture = makeFixture(split: false)
        let item = menuItem(action: #selector(SurfaceView.splitUp(_:)))

        fixture.surfaceView._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Up must stay enabled while not key")

        fixture.surfaceView._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Split Up must stay enabled while key")
    }

    // MARK: - Paste/Copy/Select All/Paste as Plain Text disabled when NOT key window
    //
    // These four close the actual on-device defect (see file header):
    // AppDelegate's Edit menu registers "Copy"/"Paste"/"Select All" with
    // `#selector(NSText.copy(_:))`/`#selector(NSText.paste(_:))`/
    // `#selector(NSText.selectAll(_:))`, target nil -- the SAME
    // Objective-C selectors (`copy:`/`paste:`/`selectAll:`) SurfaceView's
    // own `@IBAction`s below answer to. `pasteAsPlainText(_:)` has no menu
    // item today but is gated for the same reason `focusSplit*` is: so a
    // future caller can never re-introduce the gap. `split: false` because
    // none of these four selectors are gated on `isActiveTabSplit`.

    func test_validateMenuItem_paste_disabledWhenNotKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.paste(_:))))

        XCTAssertFalse(
            result,
            "Paste must be disabled while this window is not the key window -- this is what stops Cmd+V, pressed while a non-CalyxWindow panel like About is key, from silently pasting into a background terminal's shell"
        )
    }

    func test_validateMenuItem_copy_disabledWhenNotKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.copy(_:))))

        XCTAssertFalse(
            result,
            "Copy must be disabled while this window is not the key window"
        )
    }

    func test_validateMenuItem_selectAll_disabledWhenNotKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.selectAll(_:))))

        XCTAssertFalse(
            result,
            "Select All must be disabled while this window is not the key window"
        )
    }

    func test_validateMenuItem_pasteAsPlainText_disabledWhenNotKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = false

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.pasteAsPlainText(_:))))

        XCTAssertFalse(
            result,
            "Paste as Plain Text must be disabled while this window is not the key window, even though no menu item is wired to it today"
        )
    }

    // MARK: - Regression guards: Paste/Copy/Select All/Paste as Plain Text enabled when key window
    //
    // `validateMenuItem(_:)` has no per-selector branch for any of these
    // four today, so it falls through to the unconditional `return true`
    // at the bottom -- these four already pass. Once the key-window gate
    // above is implemented, a key window must still leave that fallback
    // reachable, so these must keep passing unchanged.

    func test_validateMenuItem_paste_enabledWhenKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.paste(_:))))

        XCTAssertTrue(result, "Paste must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_copy_enabledWhenKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.copy(_:))))

        XCTAssertTrue(result, "Copy must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_selectAll_enabledWhenKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.selectAll(_:))))

        XCTAssertTrue(result, "Select All must stay enabled while this window IS the key window")
    }

    func test_validateMenuItem_pasteAsPlainText_enabledWhenKeyWindow() {
        let fixture = makeFixture(split: false)
        fixture.surfaceView._isKeyWindowOverrideForTesting = true

        let result = fixture.surfaceView.validateMenuItem(menuItem(action: #selector(SurfaceView.pasteAsPlainText(_:))))

        XCTAssertTrue(result, "Paste as Plain Text must stay enabled while this window IS the key window")
    }

    // MARK: - Regression guard: performFindAction opens NEW UI, so it is never key-window-gated

    /// `performFindAction(_:)` (wired to the Edit > Find > Find… menu item,
    /// AppDelegate.swift) opens the in-terminal search bar -- it creates a
    /// new piece of UI rather than mutating this window's existing state,
    /// the same category `splitRight/Left/Down/Up(_:)` fall into above.
    /// Fixes this codebase's shape for those: a single test asserting
    /// `true` on both sides of the override, pinning that this selector
    /// must NEVER be added to `keyWindowGatedActions`.
    func test_validateMenuItem_performFindAction_enabledRegardlessOfKeyWindow() {
        let fixture = makeFixture(split: false)
        let item = menuItem(action: #selector(SurfaceView.performFindAction(_:)))

        fixture.surfaceView._isKeyWindowOverrideForTesting = false
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Find… must stay enabled while not key")

        fixture.surfaceView._isKeyWindowOverrideForTesting = true
        XCTAssertTrue(fixture.surfaceView.validateMenuItem(item), "Find… must stay enabled while key")
    }
}
