//
//  CalyxWindowControllerSnapshotBranchCoverageTests.swift
//  CalyxTests
//
//  TDD Red phase, round 12 (r12-fix-spec.md, sweep addendum item 3):
//  windowSnapshot()'s two special-case branches had ZERO test coverage
//  before this file:
//
//    1. The live-browserURL-override branch (browserControllers[tab.id]
//       non-nil with a URL different from the tab's configured
//       `content` URL) -- CalyxWindowControllerSnapshotCompletenessTests
//       only exercises the configured-URL FALLBACK arm, because
//       `browserControllers` is private and empty for a freshly
//       constructed controller in every existing test.
//    2. The diff-tab exclusion branch (`if case .diff = tab.content
//       { return nil }`) -- no existing test constructs a `.diff`
//       tab and asserts it is absent from windowSnapshot()'s persisted
//       tabs.
//
//  Uses the new `_setBrowserControllerForTesting(tabID:controller:)`
//  DEBUG seam (CalyxWindowController.swift) to inject a live
//  BrowserTabController without driving a real navigation through
//  BrowserView/WebKit.
//
//  Both assertions below PASS today (verified against a941b245d): they
//  cover EXISTING production behavior that predates this round's R12-C
//  refactor (which collapses windowSnapshot() to delegate to
//  Tab.snapshot()). These are therefore REGRESSION GUARDS, not RED
//  proof -- the point, per the sweep addendum, is locking both branches
//  down BEFORE the refactor touches them, so any accidental behavior
//  change during the collapse (e.g. the live override silently losing
//  precedence, or a diff tab leaking into a persisted snapshot) is
//  caught immediately.
//
//  Coverage:
//  - A browser tab with a live BrowserTabController whose URL differs
//    from the tab's configured content URL: windowSnapshot()'s
//    TabSnapshot.browserURL carries the LIVE url, not the configured one
//  - A .diff-content tab does not appear in windowSnapshot()'s
//    persisted tabs at all
//

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class CalyxWindowControllerSnapshotBranchCoverageTests: XCTestCase {

    private func makeController(tab: Tab) -> CalyxWindowController {
        let group = TabGroup(name: "Round 12 Branch Coverage", tabs: [tab], activeTabID: tab.id)
        let windowSession = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: windowSession, restoring: true)
    }

    // MARK: - Live browserURL override wins over the configured URL

    /// Regression guard (sweep addendum item 3a): existing production
    /// behavior, not a round-12 change -- locks it down before R12-C's
    /// delegation refactor touches this branch.
    func test_windowSnapshot_browserTabWithLiveController_usesLiveURL_notConfiguredURL() throws {
        let registry = SurfaceRegistry()
        let leafID = UUID()
        registry._testInsert(view: SurfaceView(frame: .zero), id: leafID)
        let splitTree = SplitTree(root: .leaf(id: leafID), focusedLeafID: leafID)

        let configuredURL = try XCTUnwrap(URL(string: "https://example.com/configured"))
        let liveURL = try XCTUnwrap(URL(string: "https://example.com/live-navigated-away"))

        let tab = Tab(
            splitTree: splitTree,
            content: .browser(url: configuredURL),
            registry: registry
        )
        let controller = makeController(tab: tab)

        let liveController = BrowserTabController(url: liveURL)
        controller._setBrowserControllerForTesting(tabID: tab.id, controller: liveController)

        let tabSnapshot = try XCTUnwrap(
            controller.windowSnapshot().groups.first?.tabs.first,
            "windowSnapshot() must produce a TabSnapshot for the single browser tab in this fixture"
        )

        XCTAssertEqual(
            tabSnapshot.browserURL, liveURL,
            "windowSnapshot() must carry the LIVE browserControllers URL, not the tab's configured content " +
            "URL, when a live BrowserTabController is registered for the tab -- regression guard for the " +
            "R12-C delegation, not RED proof (this precedence already exists today); see this file's header " +
            "comment"
        )
    }

    // MARK: - Diff tabs are excluded from the persisted snapshot

    /// Regression guard (sweep addendum item 3b): existing production
    /// behavior, not a round-12 change -- locks it down before R12-C's
    /// delegation refactor touches this branch.
    func test_windowSnapshot_diffTab_isExcludedFromPersistedTabs() {
        let registry = SurfaceRegistry()
        let diffTab = Tab(content: .diff(source: .unstaged(path: "file.txt", workDir: "/tmp")), registry: registry)
        let controller = makeController(tab: diffTab)

        let groupSnapshot = controller.windowSnapshot().groups.first

        XCTAssertEqual(
            groupSnapshot?.tabs.count, 0,
            "windowSnapshot() must exclude .diff-content tabs from the persisted snapshot entirely -- " +
            "regression guard for the R12-C delegation, not RED proof (diff tabs are already skipped today); " +
            "see this file's header comment"
        )
    }
}
