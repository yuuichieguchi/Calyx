//
//  AppDelegatePendingTerminationSnapshotTests.swift
//  CalyxTests
//
//  TDD Red phase (save-reliability C2 -- terminate-path snapshot capture).
//  ROOT CAUSE (traced against the CURRENT code, confirmed live-incident
//  narrative: 3 windows genuinely open, sessions.json read back as
//  {"windows":[]}): closing the LAST managed window via the red button
//  (or any windowShouldClose confirm-quit success path) runs through a
//  sequence where NO save ever actually reaches disk with real content:
//
//    1. windowShouldClose confirms -> markTerminationConfirmedAndSetClosingForShutdown()
//       sets appDelegate.isTerminationConfirmed = true and this window's
//       own isClosingForShutdown = true.
//    2. AppKit closes the window -> windowWillClose fires. Its own save
//       (appDelegate.saveImmediately()) is gated on
//       `appDelegate.isClosingLastManagedWindow(self) && !isAppActuallyTerminating`
//       (see CalyxWindowControllerLastWindowCloseSaveTests, already
//       GREEN) -- isAppActuallyTerminating reads AppDelegate.isTerminating
//       (isApplicationTerminating || isTerminationConfirmed), which is
//       now true, so this save is correctly SKIPPED. The comment at that
//       call site explicitly defers to "the only legitimate snapshot
//       writer is applicationWillTerminate's protected saveAtTermination".
//    3. windowWillClose then calls appDelegate.removeWindowController(self):
//       appSession.removeWindow + windowControllers.removeAll -- BOTH now
//       empty -- then, since windowControllers.isEmpty and no quick
//       terminal is open, calls NSApp.terminate(nil).
//    4. applicationShouldTerminate sees isTerminationConfirmed already
//       true, takes that branch, sets isApplicationTerminating = true,
//       returns .terminateNow.
//    5. applicationWillTerminate fires. Its OWN guard --
//       `if windowControllers.isEmpty || appSession.windows.isEmpty { return }`
//       (AppDelegate.swift ~295-297) -- is now true, because step 3
//       already emptied both. It returns immediately. saveAtTermination
//       is NEVER CALLED. No save happens at all on this entire route.
//
//  THE FIX: capture the CURRENT (pre-teardown) window state the moment
//  termination is CONFIRMED (before any of the above emptying can
//  happen), and have the termination-time save consult that captured
//  snapshot instead of re-deriving from the (by-then-emptied) live
//  windowControllers/appSession.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): AppDelegate
//  .pendingTerminationSnapshot, ._setPendingTerminationSnapshotForTesting(_:),
//  and .saveForTermination() do not exist yet, and isTerminationConfirmed
//  is not yet a didSet-observed property. This file fails to compile
//  until the Green phase adds all of it. That compile failure IS this
//  file's RED evidence.
//
//  Proposed API (AppDelegate.swift additions):
//
//    /// Captured the moment termination is confirmed
//    /// (isTerminationConfirmed's didSet, false -> true transition only),
//    /// BEFORE any window teardown or removeWindowController(_:) call can
//    /// empty windowControllers/appSession. applicationWillTerminate (via
//    /// saveForTermination()) consults this instead of re-deriving
//    /// buildSnapshot() from the possibly-already-emptied live state, so
//    /// the confirm-quit-by-closing-the-last-window route always saves a
//    /// real snapshot. Covers BOTH termination routes: windowShouldClose's
//    /// confirm branch and applicationShouldTerminate's own Cmd+Q branch
//    /// both set isTerminationConfirmed = true.
//    private(set) var pendingTerminationSnapshot: SessionSnapshot?
//
//    #if DEBUG
//    /// Test seam: force pendingTerminationSnapshot directly instead of
//    /// only via isTerminationConfirmed's didSet, so saveForTermination()'s
//    /// own "prefers the captured snapshot over a live rebuild" contract
//    /// is testable in isolation from the capture mechanism itself. DO
//    /// NOT use from production code.
//    func _setPendingTerminationSnapshotForTesting(_ snapshot: SessionSnapshot?) {
//        pendingTerminationSnapshot = snapshot
//    }
//    #endif
//
//    var isTerminationConfirmed = false {
//        didSet {
//            guard isTerminationConfirmed, !oldValue else { return }
//            pendingTerminationSnapshot = buildSnapshot()
//        }
//    }
//
//    /// Extracted from applicationWillTerminate's save step so it is
//    /// directly unit-testable: applicationWillTerminate itself is gated
//    /// behind LaunchEnvironmentPolicy.isUnitTestHost() and always
//    /// early-returns in the CalyxTests process (see that gate's own doc
//    /// comment), so no test can drive it directly. Saves
//    /// pendingTerminationSnapshot when present, falling back to
//    /// buildSnapshot() otherwise (the existing behavior for e.g. a Cmd+Q
//    /// with no window-close race). Routes through saveAtTermination(_:),
//    /// which itself refuses to let an empty snapshot clobber a non-empty
//    /// on-disk one, and resets the crash-loop counter exactly as
//    /// applicationWillTerminate's own Task body already does.
//    func saveForTermination() {
//        let snapshot = pendingTerminationSnapshot ?? buildSnapshot()
//        let actor = _sessionPersistenceActorForTesting ?? SessionPersistenceActor.shared
//        var done = false
//        Task {
//            await actor.saveAtTermination(snapshot)
//            await actor.resetRecoveryCounter()
//            done = true
//        }
//        let deadline = Date().addingTimeInterval(1.0)
//        while !done, Date() < deadline {
//            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
//        }
//    }
//
//  applicationWillTerminate's own body (AppDelegate.swift ~256-315) must
//  then call saveForTermination() in place of its current inline
//  guard+snapshot-build+Task block, and the
//  `windowControllers.isEmpty || appSession.windows.isEmpty` early return
//  must no longer unconditionally skip the save when pendingTerminationSnapshot
//  is non-nil (saveAtTermination's own empty-snapshot protection already
//  covers the "genuinely nothing to save" case, so this outer guard's
//  ONLY remaining job is avoiding pointless work when there is neither a
//  pending snapshot nor any live window, not gatekeeping correctness).
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): this file drives
//  isTerminationConfirmed's didSet and saveForTermination() directly
//  against a bare AppDelegate() with _testInsertWindowController-seeded
//  fixture controllers (mirrors CalyxWindowControllerLastWindowCloseSaveTests'
//  own no-live-ghostty-surface fixture) and a temp-dir-backed
//  SessionPersistenceActor (mirrors AppDelegateRecoveryCounterResetTests'
//  own pattern), so it CAN pin the capture-on-confirm mechanism and
//  saveForTermination()'s snapshot preference exactly. It CANNOT pin that
//  applicationWillTerminate's own body actually calls saveForTermination()
//  at its call site -- that notification handler is gated behind
//  LaunchEnvironmentPolicy.isUnitTestHost() and always early-returns in
//  this process (confirmed by reading that gate's own header). The Green
//  phase implementer and code review must verify that call-site wiring by
//  reading the diff; no test in this file substitutes for that reading.
//
//  Coverage:
//  - isTerminationConfirmed = true captures a snapshot matching the
//    CURRENTLY test-inserted window controllers' real windowSnapshot()
//    content
//  - a REDUNDANT second isTerminationConfirmed = true (already true) does
//    NOT re-capture, even if windowControllers changed in between --
//    proves the fix only captures on the genuine false -> true transition
//  - resetting isTerminationConfirmed back to false (mirrors
//    applicationShouldTerminate's own "already confirmed" branch, which
//    does exactly this) does NOT clear the already-captured snapshot
//  - saveForTermination() with a pending snapshot present saves THAT
//    content, not a fresh (empty) rebuild from live (empty)
//    windowControllers
//  - saveForTermination() with NO pending snapshot falls back to a live
//    buildSnapshot() rebuild, unchanged from applicationWillTerminate's
//    existing Cmd+Q-with-no-race behavior
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class AppDelegatePendingTerminationSnapshotTests: XCTestCase {

    // MARK: - Fixtures / Helpers

    /// Mirrors AppDelegateRecoveryCounterResetTests.makeSessionDirActor()'s
    /// per-test-method teardown-block convention.
    private func makeSessionDirActor() throws -> SessionPersistenceActor {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegatePendingTerminationSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let dir = raw.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", dir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return SessionPersistenceActor()
    }

    /// Single-tab/single-group window, no live ghostty surface -- mirrors
    /// CalyxWindowControllerLastWindowCloseSaveTests.makeFixture()
    /// exactly, parameterized by title so multiple fixture controllers
    /// are distinguishable in a captured snapshot.
    private func makeFixtureController(title: String) -> CalyxWindowController {
        let tab = Tab(title: title)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    // MARK: - 1. isTerminationConfirmed = true captures the current window state

    func test_isTerminationConfirmed_setToTrue_capturesCurrentWindowStateBeforeTeardown() {
        let appDelegate = AppDelegate()
        let controller = makeFixtureController(title: "First")
        appDelegate._testInsertWindowController(controller)

        XCTAssertNil(appDelegate.pendingTerminationSnapshot,
                     "precondition: nothing has been captured before termination is confirmed")

        appDelegate.isTerminationConfirmed = true

        let expected = SessionSnapshot(windows: [controller.windowSnapshot()])
        XCTAssertEqual(appDelegate.pendingTerminationSnapshot, expected,
                       "confirming termination must capture the CURRENT window state (matching " +
                       "buildSnapshot()'s own windowControllers.map { $0.windowSnapshot() } shape) " +
                       "before any teardown can empty windowControllers")
    }

    // MARK: - 2. A redundant re-set does not re-capture

    func test_isTerminationConfirmed_redundantSecondSetTrue_doesNotRecapture() {
        let appDelegate = AppDelegate()
        let firstController = makeFixtureController(title: "First")
        appDelegate._testInsertWindowController(firstController)

        appDelegate.isTerminationConfirmed = true
        let capturedAfterFirstSet = appDelegate.pendingTerminationSnapshot
        XCTAssertEqual(capturedAfterFirstSet?.windows.count, 1,
                      "precondition: the first confirm captured exactly the one inserted controller")

        // Simulate more window state existing by the time a SECOND,
        // redundant confirm happens (e.g. a Cmd+Q race arriving after
        // windowShouldClose already confirmed once).
        let secondController = makeFixtureController(title: "Second")
        appDelegate._testInsertWindowController(secondController)

        appDelegate.isTerminationConfirmed = true

        XCTAssertEqual(appDelegate.pendingTerminationSnapshot, capturedAfterFirstSet,
                       "a redundant isTerminationConfirmed = true (already true) must NOT " +
                       "re-capture -- only the genuine false -> true transition captures, so a " +
                       "later, already-in-progress teardown's partial state can never silently " +
                       "replace the original confirm-time snapshot")
    }

    // MARK: - 3. Resetting the flag back to false does not clear the capture

    func test_isTerminationConfirmed_resetToFalse_doesNotClearCapturedSnapshot() {
        // Mirrors applicationShouldTerminate's own "already confirmed"
        // branch (AppDelegate.swift ~226-231), which sets
        // isTerminationConfirmed = false as part of ITS OWN handling,
        // strictly BEFORE applicationWillTerminate (and therefore
        // saveForTermination()) ever runs. If resetting the flag wiped
        // the captured snapshot, this fix would defeat itself on its own
        // primary route.
        let appDelegate = AppDelegate()
        let controller = makeFixtureController(title: "Only")
        appDelegate._testInsertWindowController(controller)

        appDelegate.isTerminationConfirmed = true
        let captured = appDelegate.pendingTerminationSnapshot
        XCTAssertNotNil(captured, "precondition: confirming termination must have captured something")

        appDelegate.isTerminationConfirmed = false

        XCTAssertEqual(appDelegate.pendingTerminationSnapshot, captured,
                       "resetting isTerminationConfirmed back to false (as " +
                       "applicationShouldTerminate's own already-confirmed branch does) must NOT " +
                       "clear the captured pendingTerminationSnapshot -- saveForTermination() still " +
                       "needs it once applicationWillTerminate runs")
    }

    // MARK: - 4. saveForTermination() prefers the captured snapshot over a live rebuild

    func test_saveForTermination_pendingSnapshotPresent_savesPendingSnapshotNotLiveEmptyState() async throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor

        // windowControllers is deliberately left EMPTY (never inserted),
        // so buildSnapshot() would yield SessionSnapshot(windows: []) --
        // simulating the exact post-teardown race (removeWindowController
        // already emptied everything) the root cause above traces.
        let windowID = UUID()
        let pending = SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 1, y: 2, width: 3, height: 4))])
        appDelegate._setPendingTerminationSnapshotForTesting(pending)

        appDelegate.saveForTermination()

        let restored = await actor.restore()
        XCTAssertEqual(restored, SessionSnapshot.migrate(pending),
                       "saveForTermination() must save the CAPTURED pendingTerminationSnapshot, not " +
                       "an empty rebuild from the live (already-emptied) windowControllers")
        XCTAssertEqual(restored?.windows.first?.id, windowID)
    }

    // MARK: - 5. saveForTermination() falls back to a live rebuild when nothing was captured

    func test_saveForTermination_noPendingSnapshot_fallsBackToLiveBuildSnapshot() async throws {
        let actor = try makeSessionDirActor()
        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        let controller = makeFixtureController(title: "Only")
        appDelegate._testInsertWindowController(controller)

        XCTAssertNil(appDelegate.pendingTerminationSnapshot,
                     "precondition: nothing was ever captured (e.g. a plain Cmd+Q with no " +
                     "window-close race, which never sets isTerminationConfirmed via that route)")

        appDelegate.saveForTermination()

        let restored = await actor.restore()
        let expected = SessionSnapshot(windows: [controller.windowSnapshot()])
        XCTAssertEqual(restored, SessionSnapshot.migrate(expected),
                       "with no captured snapshot, saveForTermination() must fall back to a live " +
                       "buildSnapshot() rebuild, unchanged from today's applicationWillTerminate " +
                       "behavior for a race-free termination")
    }
}
