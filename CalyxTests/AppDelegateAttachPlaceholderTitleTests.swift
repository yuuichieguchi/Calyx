//
//  AppDelegateAttachPlaceholderTitleTests.swift
//  CalyxTests
//
//  TDD Red phase for a user-reported defect: attaching a Detached
//  session from the session browser opens a tab titled "Terminal" that
//  stays that way until the reattached shell's next prompt emits an OSC
//  title -- unlike a restore-at-launch tab, whose title is carried
//  forward from TabSnapshot. Both attach call sites construct their
//  placeholder Tab with no explicit `title:` argument (Tab.init's
//  default is the literal "Terminal", Calyx/Models/Session/Tab.swift),
//  even though the session's cwd is already known at attach time
//  (SessionBrowserRow.info.cwd flows into both attachWindow(cwd:) and
//  attachSessionAsTab(cwd:)) and unused for the title.
//
//  This file pins the CURRENT (buggy) behavior as a genuine, real
//  assertion failure -- not a compile error -- against real, unmodified
//  AppDelegate.attachWindow/.attachSessionAsTab, so it does not need
//  SessionTabTitle (the new pure helper proposed in
//  SessionTabTitleTests.swift) to exist or compile. The expected title
//  strings below are computed by hand from the fix's contract (zsh
//  `%~`-style tilde abbreviation), independent of any particular
//  implementation.
//
//  SAFETY: reuses this suite's own established fixtures/seams exactly --
//  `_attachWindowCreationHookForTesting`/`_attachWindowPlaceholderTabObserverForTesting`
//  (AppDelegateAttachWindowTests) bail `attachWindow` out immediately
//  after constructing the placeholder tab, before any real window/
//  surface is created. `_testInsertWindowController` plus a fresh,
//  unregistered sessionID (AppDelegateAttachSessionAsTabTests' Row-3
//  fixture) route `attachSessionAsTab` through the real `.attachAsTab`
//  branch (`attachSessionAsNewTab`, observed via the new
//  `_attachSessionAsNewTabPlaceholderTabObserverForTesting` seam added
//  alongside this file) -- that branch's real
//  `restoreTabSurfaces`/`fallbackCreateSurface`/`attachRestoredTab` work
//  is already exercised for real by that existing, passing test, so
//  running it again here for real is no new risk.
//
//  EXTENSION (overridden-HOME RED, E2E-proven + screenshot-confirmed):
//  both call sites derive the placeholder title via
//  `SessionTabTitle.fromCwd(cwd, home: NSHomeDirectory())`, and
//  `NSHomeDirectory()` does not follow a `HOME` environment override --
//  it resolves via the user database, not the env var (mirrors why
//  `SessionRootResolver.swift`'s own doc comment forbids
//  `FileManager.homeDirectoryForCurrentUser` for the identical reason).
//  So under an overridden `HOME` (the E2E harness, and by the P4
//  root-resolver lesson any environment where HOME differs from the
//  real user record), the tilde abbreviation never fires and a raw
//  absolute path shows as the tab title. The cases below `setenv`
//  `HOME` to a fixture path (save+restore in teardown, mirroring
//  `AppDelegateApplyGhosttyResourcesDirEnvironmentTests`' established
//  env-juggling convention) and assert the placeholder title
//  abbreviates against THAT overridden home, computed by hand from the
//  fix's contract, independent of any particular implementation. Both
//  fail today for a genuine reason: `NSHomeDirectory()` still returns
//  the real test host's home, which shares no path-prefix relationship
//  with the fixture `HOME`, so `SessionTabTitle.fromCwd` falls through
//  to returning the raw `cwd` unabbreviated.
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegateAttachWindowPlaceholderTitleTests: XCTestCase {

    // MARK: - Overridden-HOME fixture (env-juggling convention from
    // AppDelegateApplyGhosttyResourcesDirEnvironmentTests)

    private var originalHOME: String?

    override func setUp() {
        super.setUp()
        originalHOME = ProcessInfo.processInfo.environment["HOME"]
    }

    override func tearDown() {
        if let originalHOME {
            setenv("HOME", originalHOME, 1)
        } else {
            unsetenv("HOME")
        }
        super.tearDown()
    }

    /// A path guaranteed distinct from (and never a path-prefix relative
    /// of) the real test host's `NSHomeDirectory()`, so a title that
    /// abbreviates against it can only be correct if the production code
    /// actually consulted the overridden `HOME`, never `NSHomeDirectory()`.
    private func makeOverriddenHomePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateAttachPlaceholderTitleTests-HOME-override-\(UUID().uuidString)")
            .path
    }

    // MARK: - attachWindow's placeholder tab

    func test_attachWindow_placeholderTab_nestedCwd_titleIsAbbreviatedPath() {
        let appDelegate = AppDelegate()
        var observedTab: Tab?
        appDelegate._attachWindowPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._attachWindowCreationHookForTesting = { }

        let sessionID = "test-session-\(UUID().uuidString)"
        let home = NSHomeDirectory()
        let cwd = "\(home)/projects/Calyx"

        appDelegate.attachWindow(sessionID: sessionID, cwd: cwd)

        XCTAssertEqual(observedTab?.title, "~/projects/Calyx",
                       "The placeholder tab's title must derive from the attached session's cwd " +
                       "(tilde-abbreviated), not stay the generic default \"Terminal\"")
        XCTAssertEqual(observedTab?.pwd, cwd, "The placeholder tab's pwd must still be the raw cwd")
    }

    func test_attachWindow_placeholderTab_cwdIsExactlyHome_titleIsBareTilde() {
        let appDelegate = AppDelegate()
        var observedTab: Tab?
        appDelegate._attachWindowPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._attachWindowCreationHookForTesting = { }

        let sessionID = "test-session-\(UUID().uuidString)"
        let home = NSHomeDirectory()

        appDelegate.attachWindow(sessionID: sessionID, cwd: home)

        XCTAssertEqual(observedTab?.title, "~",
                       "A cwd exactly equal to the home directory must abbreviate to a bare \"~\"")
    }

    func test_attachWindow_placeholderTab_nestedCwd_underOverriddenHOME_titleIsAbbreviatedPath() {
        let overriddenHome = makeOverriddenHomePath()
        setenv("HOME", overriddenHome, 1)

        let appDelegate = AppDelegate()
        var observedTab: Tab?
        appDelegate._attachWindowPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._attachWindowCreationHookForTesting = { }

        let sessionID = "test-session-\(UUID().uuidString)"
        let cwd = "\(overriddenHome)/sub"

        appDelegate.attachWindow(sessionID: sessionID, cwd: cwd)

        XCTAssertEqual(observedTab?.title, "~/sub",
                       "Under an overridden HOME (as in the E2E harness), the placeholder title must " +
                       "abbreviate against THAT home, not the real NSHomeDirectory() -- NSHomeDirectory() " +
                       "does not follow a HOME environment override")
    }

    func test_attachWindow_placeholderTab_cwdIsExactlyOverriddenHOME_titleIsBareTilde() {
        let overriddenHome = makeOverriddenHomePath()
        setenv("HOME", overriddenHome, 1)

        let appDelegate = AppDelegate()
        var observedTab: Tab?
        appDelegate._attachWindowPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._attachWindowCreationHookForTesting = { }

        let sessionID = "test-session-\(UUID().uuidString)"

        appDelegate.attachWindow(sessionID: sessionID, cwd: overriddenHome)

        XCTAssertEqual(observedTab?.title, "~",
                       "A cwd exactly equal to the OVERRIDDEN home must abbreviate to a bare \"~\", " +
                       "which only holds if the overridden HOME (not NSHomeDirectory()) drove the comparison")
    }

    func test_attachWindow_placeholderTab_nilCwd_titleFallsBackToTerminal() {
        let appDelegate = AppDelegate()
        var observedTab: Tab?
        appDelegate._attachWindowPlaceholderTabObserverForTesting = { observedTab = $0 }
        appDelegate._attachWindowCreationHookForTesting = { }

        let sessionID = "test-session-\(UUID().uuidString)"

        appDelegate.attachWindow(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(observedTab?.title, "Terminal",
                       "With no cwd at all, the placeholder title has no better option than \"Terminal\"")
        XCTAssertNil(observedTab?.pwd, "With no cwd at all, pwd must stay nil")
    }

    // MARK: - attachSessionAsTab's `.attachAsTab` branch (attachSessionAsNewTab)'s placeholder tab

    /// Builds the Row-3 fixture from AppDelegateAttachSessionAsTabTests
    /// (an unrelated main window already open, sessionID unregistered),
    /// so `attachSessionAsTab` routes through `.attachAsTab` ->
    /// `attachSessionAsNewTab`, and bails that branch out at its creation
    /// seam right after the placeholder observer fires -- BEFORE the real
    /// ghostty-FFI surface + PTY creation, which is unsafe from this test
    /// host and leaks a live surface across the process-wide singletons
    /// (see `_attachSessionAsNewTabCreationHookForTesting`'s own doc
    /// comment on AppDelegate). The observed `Tab` these tests assert on is
    /// fully built before the bail, so the bail changes nothing they check.
    private func insertUnrelatedWindowController(into appDelegate: AppDelegate) {
        appDelegate._attachSessionAsNewTabCreationHookForTesting = { }
        let unrelatedTab = Tab(title: "Unrelated")
        let unrelatedGroup = TabGroup(name: "Default", tabs: [unrelatedTab], activeTabID: unrelatedTab.id)
        let unrelatedSession = WindowSession(groups: [unrelatedGroup], activeGroupID: unrelatedGroup.id)
        let unrelatedWindow = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let unrelatedController = CalyxWindowController(
            window: unrelatedWindow, windowSession: unrelatedSession, restoring: true
        )
        appDelegate._testInsertWindowController(unrelatedController)
    }

    func test_attachSessionAsNewTab_placeholderTab_nestedCwd_titleIsAbbreviatedPath() {
        let appDelegate = AppDelegate()
        insertUnrelatedWindowController(into: appDelegate)
        var observedTab: Tab?
        appDelegate._attachSessionAsNewTabPlaceholderTabObserverForTesting = { observedTab = $0 }

        let sessionID = "test-session-\(UUID().uuidString)"
        // Deliberately NOT registered in SessionSurfaceMap: an orphaned,
        // running-but-detached session (isOrphan == true browser row case).
        let home = NSHomeDirectory()
        let cwd = "\(home)/projects/Calyx"

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: cwd)

        XCTAssertEqual(observedTab?.title, "~/projects/Calyx",
                       "attachSessionAsNewTab's placeholder tab title must derive from the attached " +
                       "session's cwd (tilde-abbreviated), not stay the generic default \"Terminal\"")
        XCTAssertEqual(observedTab?.pwd, cwd, "The placeholder tab's pwd must still be the raw cwd")
    }

    func test_attachSessionAsNewTab_placeholderTab_cwdIsExactlyHome_titleIsBareTilde() {
        let appDelegate = AppDelegate()
        insertUnrelatedWindowController(into: appDelegate)
        var observedTab: Tab?
        appDelegate._attachSessionAsNewTabPlaceholderTabObserverForTesting = { observedTab = $0 }

        let sessionID = "test-session-\(UUID().uuidString)"
        let home = NSHomeDirectory()

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: home)

        XCTAssertEqual(observedTab?.title, "~",
                       "A cwd exactly equal to the home directory must abbreviate to a bare \"~\"")
    }

    func test_attachSessionAsNewTab_placeholderTab_nestedCwd_underOverriddenHOME_titleIsAbbreviatedPath() {
        let overriddenHome = makeOverriddenHomePath()
        setenv("HOME", overriddenHome, 1)

        let appDelegate = AppDelegate()
        insertUnrelatedWindowController(into: appDelegate)
        var observedTab: Tab?
        appDelegate._attachSessionAsNewTabPlaceholderTabObserverForTesting = { observedTab = $0 }

        let sessionID = "test-session-\(UUID().uuidString)"
        let cwd = "\(overriddenHome)/sub"

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: cwd)

        XCTAssertEqual(observedTab?.title, "~/sub",
                       "Under an overridden HOME (as in the E2E harness), attachSessionAsNewTab's " +
                       "placeholder title must abbreviate against THAT home, not the real NSHomeDirectory() " +
                       "-- NSHomeDirectory() does not follow a HOME environment override")
    }

    func test_attachSessionAsNewTab_placeholderTab_cwdIsExactlyOverriddenHOME_titleIsBareTilde() {
        let overriddenHome = makeOverriddenHomePath()
        setenv("HOME", overriddenHome, 1)

        let appDelegate = AppDelegate()
        insertUnrelatedWindowController(into: appDelegate)
        var observedTab: Tab?
        appDelegate._attachSessionAsNewTabPlaceholderTabObserverForTesting = { observedTab = $0 }

        let sessionID = "test-session-\(UUID().uuidString)"

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: overriddenHome)

        XCTAssertEqual(observedTab?.title, "~",
                       "A cwd exactly equal to the OVERRIDDEN home must abbreviate to a bare \"~\", " +
                       "which only holds if the overridden HOME (not NSHomeDirectory()) drove the comparison")
    }

    func test_attachSessionAsNewTab_placeholderTab_nilCwd_titleFallsBackToTerminal() {
        let appDelegate = AppDelegate()
        insertUnrelatedWindowController(into: appDelegate)
        var observedTab: Tab?
        appDelegate._attachSessionAsNewTabPlaceholderTabObserverForTesting = { observedTab = $0 }

        let sessionID = "test-session-\(UUID().uuidString)"

        appDelegate.attachSessionAsTab(sessionID: sessionID, cwd: nil)

        XCTAssertEqual(observedTab?.title, "Terminal",
                       "With no cwd at all, the placeholder title has no better option than \"Terminal\"")
        XCTAssertNil(observedTab?.pwd, "With no cwd at all, pwd must stay nil")
    }
}
