// SessionRecoveryBarE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the Chrome-style in-app session-recovery bar
// (team-lead task: "in-app recovery bar + E2E"; see the sibling
// CalyxTests/RecoveryBarModelTests.swift for the view-model-level RED
// and this bar's full design-decision writeup). This is the E2E half
// SessionPersistenceE2ETests.swift did NOT cover: that suite only
// exercises a NORMAL, successful restore/reattach round trip. This
// suite instead manufactures the specific precondition the recovery
// bar exists for -- a PRESERVED-BUT-NOT-YET-RECOVERED snapshot already
// sitting on disk at launch (AppDelegate.hasPreservedSessionSnapshot ==
// true) -- and drives the bar's three real, user-visible behaviors:
// it appears, Restore actually restores a window and makes the bar
// disappear, and Dismiss hides the bar without deleting the underlying
// preserved file.
//
// PRECONDITION SETUP (investigated, chosen deliberately over the
// daemon-driven alternative -- stated precisely per task instructions):
// `SessionPersistenceActor.hasPreservedSnapshot()` is a PURE file-
// existence check against `$CALYX_UITEST_SESSION_DIR/sessions.recovery.json`
// (SessionPersistenceActor.swift's `recoverySnapshotPath`) -- it does
// not care whether that file's window/tab content came from a real
// calyx-session daemon-backed persistent session or an ordinary
// passthrough shell. `AppDelegate.restoreWindow(_:)` confirms this
// too: a `TabSnapshot` with no `sessionRefs` entry for a leaf restores
// as "an ordinary passthrough shell" via `createSurfaceWithPwd` (see
// that method's own doc comment) -- no calyx-session binary, no daemon
// socket, no `CALYX_SESSION_BIN` involved at all. So instead of
// standing up an isolated daemon (short-HOME trick, CALYX_SESSION_BIN,
// etc. -- see SessionPersistenceE2ETests.swift's much heavier setUp())
// only to satisfy a precondition this feature does not actually care
// about, this suite writes a plain, non-persistent-session
// `sessions.recovery.json` (schema v6, one window/one tab, no
// `sessionRefs` key) directly into a fresh `CALYX_UITEST_SESSION_DIR`
// BEFORE `app.launch()`. This is deterministic (no daemon startup
// latency/flakiness) and exercises exactly the code path this bar's
// contract is actually about: AppDelegate.hasPreservedSessionSnapshot /
// recoverPreservedSession() / finalizeRecoverPreservedSession(restoredAny:),
// all already covered at the unit level by
// AppDelegateRecoverPreservedSessionFinalizeTests.swift and friends
// (CalyxTests/, root) -- this suite adds the missing "the user can
// actually SEE and USE this from a real running app" layer on top.
//
// The JSON fixture below mirrors SessionSnapshotV6Tests.swift's own
// `v5JSONFixture` shape almost verbatim (same key set/nesting, same
// `{"leaf": {"id": ...}}` SplitNode encoding, same CGRect-as-two-arrays
// `frame` shape) -- that fixture is already proven to decode correctly
// by that unit suite, so reusing its exact shape (schemaVersion bumped
// to 6, current) here is a known-good starting point rather than a
// fresh, unverified guess at Codable's synthesized JSON shape.
//
// Isolation: `CALYX_UITEST_SESSION_DIR` only (mirrors the base
// CalyxUITestCase.setUp()'s own key) -- no HOME override, no
// CALYX_SESSION_BIN, no calyx-session daemon involved at all (see
// above), so this suite has none of SessionPersistenceE2ETests.swift's
// daemon-related setup/isolation requirements.
//
// Verification method: never types into the app, never reads pane
// content -- identical rationale to SessionPersistenceE2ETests.swift's
// own header (Ghostty renders on the GPU, outside the accessibility
// tree; XCUITest keystrokes are not reliably scoped to the app under
// test). This suite only queries the recovery bar's own
// `AccessibilityID.RecoveryBar` identifiers (SwiftUI chrome, real
// accessibility-tree elements, unlike terminal content) and the
// window count / preserved-file's continued existence on disk.

import XCTest

/// Precondition: a preserved-but-not-recovered snapshot already exists
/// at launch. Covers "bar appears + Restore actually restores a window
/// and the bar disappears" and "Dismiss hides the bar without deleting
/// the preserved file".
final class SessionRecoveryBarE2ETests: CalyxUITestCase {

    private var sessionDir: String!

    /// Does NOT call `super.setUp()`: the base class's `setUp()`
    /// launches `app` immediately with a fresh, empty session dir,
    /// before a subclass would have any chance to write
    /// `sessions.recovery.json` into it first. Mirrors
    /// SessionPersistenceE2ETests.swift's identical reasoning for its
    /// own full setUp() override.
    override func setUp() {
        continueAfterFailure = false

        sessionDir = NSTemporaryDirectory() + "CalyxUITests-recoverybar-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: sessionDir, withIntermediateDirectories: true
        )
        writePreservedSnapshotFile()

        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
        if let sessionDir {
            try? FileManager.default.removeItem(atPath: sessionDir)
        }
        super.tearDown()
    }

    /// Path `SessionPersistenceActor`'s `recoverySnapshotPath` resolves
    /// to under a `CALYX_UITEST_SESSION_DIR` override (see
    /// SessionPersistenceActor.swift's init): the directory itself IS
    /// `calyxDir` in that branch (unlike a real launch, which appends
    /// `.calyx` under `HOME` -- the test override skips that extra
    /// path component), so the recovery file lives directly at
    /// `<sessionDir>/sessions.recovery.json`, not
    /// `<sessionDir>/.calyx/sessions.recovery.json`.
    private var preservedSnapshotPath: String {
        "\(sessionDir!)/sessions.recovery.json"
    }

    /// Schema v6 `SessionSnapshot`, one window/one group/one plain
    /// terminal tab, deliberately with NO `sessionRefs` key anywhere
    /// (an absent key decodes as `nil` for that `Optional` property,
    /// confirmed by SessionSnapshotV6Tests.swift's own v5 fixture) --
    /// this is what makes the restored tab an ordinary passthrough
    /// shell with zero calyx-session/daemon involvement (see file
    /// header). `pwd: "/tmp"` is used instead of any per-machine `$HOME`
    /// path, since `/tmp` is guaranteed to exist on every macOS runner
    /// this suite could run on.
    private func writePreservedSnapshotFile() {
        let json = """
        {
            "schemaVersion": 6,
            "windows": [
                {
                    "id": "10000000-0000-0000-0000-000000000001",
                    "frame": [[100, 100], [900, 600]],
                    "groups": [
                        {
                            "id": "10000000-0000-0000-0000-000000000002",
                            "name": "Default",
                            "color": "blue",
                            "tabs": [
                                {
                                    "id": "10000000-0000-0000-0000-000000000003",
                                    "title": "Terminal",
                                    "titleOverride": null,
                                    "pwd": "/tmp",
                                    "splitTree": {
                                        "focusedLeafID": "10000000-0000-0000-0000-000000000004",
                                        "root": {"leaf": {"id": "10000000-0000-0000-0000-000000000004"}}
                                    },
                                    "browserURL": null
                                }
                            ],
                            "activeTabID": "10000000-0000-0000-0000-000000000003",
                            "isCollapsed": false
                        }
                    ],
                    "activeGroupID": "10000000-0000-0000-0000-000000000002",
                    "showSidebar": true,
                    "sidebarWidth": 260,
                    "isFullScreen": false
                }
            ]
        }
        """
        try? Data(json.utf8).write(to: URL(fileURLWithPath: preservedSnapshotPath))
    }

    // MARK: - Element lookups
    //
    // Literal `"calyx.recoveryBar.*"` strings, not `AccessibilityID.RecoveryBar.*`:
    // CalyxUITests runs the app-under-test as a SEPARATE process (no
    // `@testable import Calyx` anywhere in this target -- confirmed by
    // grepping every existing file here), so these identifiers are
    // queried the exact same literal-string way
    // SessionBrowserAttachKillE2ETests.swift's own
    // `app.buttons["calyx.sessionBrowser.row.\(id).attachButton"]`
    // already does, cross-referenced back to
    // Calyx/Helpers/AccessibilityID.swift by name in each comment.

    /// AccessibilityID.RecoveryBar.restoreButton
    private var restoreButton: XCUIElement {
        app.buttons["calyx.recoveryBar.restoreButton"]
    }

    /// AccessibilityID.RecoveryBar.dismissButton
    private var dismissButton: XCUIElement {
        app.buttons["calyx.recoveryBar.dismissButton"]
    }

    /// Root-caused via a throwaway diagnostic during this feature's own
    /// investigation: `waitFor`/`waitForExistence` polls a single,
    /// already-resolved `XCUIElement` snapshot repeatedly, and only
    /// re-snapshots when some OTHER, unrelated event (a later click, or
    /// XCTest's own post-timeout failure-diagnostics rescan) forces a
    /// fresh one -- this bar's OWN appearance/disappearance has no
    /// associated user input event to trigger that, since it is driven
    /// entirely by an internal `AppDelegate` `Task`, not a keystroke or
    /// click. A manual loop that reused one captured element the same
    /// way never found the bar in 10s/20 checks; rebuilding the element
    /// query fresh on every single iteration (never reusing a captured
    /// reference, matching Apple's own documented "re-query, don't
    /// cache" `XCUIElement` guidance) found it on the very first check.
    /// Used for every recovery-bar-container existence/absence check in
    /// this file, including the two after a real click (Restore/Dismiss),
    /// for consistency -- a click's own event flow may already force a
    /// fresh snapshot on its own, but rebuilding the query costs nothing
    /// extra and removes any doubt.
    @discardableResult
    private func pollForRecoveryBarContainer(exists: Bool, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let found = app.descendants(matching: .any)
                .matching(identifier: "calyx.recoveryBar.container")
                .firstMatch.exists
            if found == exists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    // MARK: - Bar appears on launch, Restore restores a window and hides it

    func test_recoveryBar_appearsOnLaunchWithPreservedSnapshot_restoreRestoresWindowAndHidesBar() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        XCTAssertTrue(
            pollForRecoveryBarContainer(exists: true),
            "The recovery bar must appear on a launch where a preserved snapshot already exists on " +
            "disk (AppDelegate.hasPreservedSessionSnapshot must become true), even though no macOS " +
            "system notification permission was ever granted in this sandboxed test run -- this bar " +
            "is the permission-independent, in-app signal this feature exists to add."
        )
        saveScreenshot(name: "recoveryBar_appearsOnLaunch")

        XCTAssertTrue(restoreButton.exists, "A Restore button must be present alongside the bar.")
        XCTAssertTrue(dismissButton.exists, "A Dismiss button must be present alongside the bar.")

        let windowCountBeforeRestore = app.windows.count
        restoreButton.click()

        // recoverPreservedSession() rebuilds windows/tabs asynchronously
        // (a Task, per AppDelegate.swift) -- poll rather than assume
        // it's immediate.
        let restoredWindowAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > \(windowCountBeforeRestore)"),
            object: app.windows
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [restoredWindowAppeared], timeout: 10), .completed,
            "Clicking Restore must actually rebuild the preserved snapshot's window (one additional " +
            "NSWindow beyond the launch-time window), proving it called through to the existing " +
            "recoverPreservedSession()/restoreWindow(_:) machinery rather than merely hiding the bar."
        )

        XCTAssertTrue(
            pollForRecoveryBarContainer(exists: false),
            "The bar must disappear once Restore actually recovers a window."
        )
        saveScreenshot(name: "recoveryBar_afterRestore")
    }

    // MARK: - Dismiss hides the bar WITHOUT clearing the preserved snapshot file

    func test_recoveryBar_dismiss_hidesBarWithoutDeletingPreservedSnapshotFile() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")
        XCTAssertTrue(pollForRecoveryBarContainer(exists: true), "precondition: the bar must appear first.")

        dismissButton.click()

        XCTAssertTrue(
            pollForRecoveryBarContainer(exists: false),
            "The bar must disappear once Dismiss is clicked."
        )
        saveScreenshot(name: "recoveryBar_afterDismiss")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: preservedSnapshotPath),
            "Dismiss must hide the bar for this app run WITHOUT clearing the preserved snapshot -- " +
            "the command palette's \"Recover Previous Session\" (session.recoverPreviousSession) " +
            "must remain available afterward as the non-time-critical fallback. If this file is " +
            "gone, Dismiss wrongly destroyed the user's last-resort backup."
        )
    }

    // MARK: - Command palette drives the same recovery machinery the bar fronts, end-to-end

    /// Polls a plain synchronous condition (never an AX/XCUIElement
    /// query -- those have their own re-snapshot rules, see
    /// `pollForRecoveryBarContainer`'s doc comment above) on a fixed
    /// interval until it returns true or `timeout` elapses.
    @discardableResult
    private func pollUntil(timeout: TimeInterval = 10, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    /// Proves the exact same underlying machinery the bar's Restore
    /// button calls into (`AppDelegate.recoverPreservedSession()` /
    /// `finalizeRecoverPreservedSession(restoredAny:)`) end-to-end
    /// through a DIFFERENT, input-driven UI surface: the command
    /// palette's own "Recover Previous Session" entry
    /// (`session.recoverPreviousSession`, registered in
    /// `CalyxWindowController.setupCommandRegistry()`). Unlike the bar,
    /// the palette is opened/typed/confirmed entirely via real
    /// keystrokes, so XCUITest's AX-notification-driven polling sees
    /// every state change live -- the same reasoning
    /// `CommandPaletteUITests.swift`'s own `test_executeCommand` already
    /// relies on. Proves three things a real user would notice: (a) a
    /// new window is actually rebuilt from the preserved snapshot, (b)
    /// the preserved file is cleared afterward (not merely hidden,
    /// unlike Dismiss -- see the test above), (c) the command itself
    /// disappears from the palette's own search results afterward:
    /// `CommandRegistry.search(query:)` filters out any command whose
    /// `isAvailable()` is false BEFORE fuzzy-matching (confirmed by
    /// reading CommandRegistry.swift), so once
    /// `hasPreservedSessionSnapshot` flips to false this command is not
    /// merely "shown disabled" -- it is entirely absent from the
    /// results table.
    func test_recoveryBar_paletteRecoverPreviousSession_restoresWindowClearsFileAndDisablesCommand() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        let windowCountBeforeRestore = app.windows.count

        openCommandPaletteViaMenu()
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette search field did not appear.")
        searchField.typeText("Recover Previous Session")
        searchField.typeKey(.enter, modifierFlags: [])

        let palette = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette")
            .firstMatch
        waitForNonExistence(palette)

        // recoverPreservedSession() rebuilds windows/tabs asynchronously
        // (a Task, per AppDelegate.swift) -- poll rather than assume
        // it's immediate, mirroring the bar's own Restore-button test.
        let restoredWindowAppeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count > \(windowCountBeforeRestore)"),
            object: app.windows
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [restoredWindowAppeared], timeout: 10), .completed,
            "Executing \"Recover Previous Session\" from the command palette must rebuild the " +
            "preserved snapshot's window (one additional NSWindow beyond the launch-time window), " +
            "proving it drove the same recoverPreservedSession()/restoreWindow(_:) machinery the " +
            "bar's own Restore button calls."
        )

        // finalizeRecoverPreservedSession(restoredAny:) clears the file
        // AFTER restoreWindow(_:) has already run (see
        // AppDelegate.recoverPreservedSession()'s own ordering), so the
        // file-clear can lag slightly behind the window appearing --
        // poll rather than assume it's already done.
        XCTAssertTrue(
            pollUntil(timeout: 10) { !FileManager.default.fileExists(atPath: self.preservedSnapshotPath) },
            "A successful recovery through the command palette must clear the preserved snapshot " +
            "file (unlike Dismiss, which deliberately leaves it in place)."
        )

        // Re-open the palette and search again: the command must now be
        // entirely absent from the results, not merely present-but-
        // disabled, per CommandRegistry.search(query:)'s own
        // isAvailable() pre-filter.
        openCommandPaletteViaMenu()
        let searchFieldAgain = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchFieldAgain), "Command palette search field did not reappear.")
        searchFieldAgain.typeText("Recover Previous Session")
        Thread.sleep(forTimeInterval: 0.3)

        let resultsTable = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.resultsTable")
            .firstMatch
        XCTAssertEqual(
            resultsTable.tableRows.count, 0,
            "\"Recover Previous Session\" must no longer be a search result once " +
            "hasPreservedSessionSnapshot is false -- CommandRegistry.search(query:) filters out " +
            "any command whose isAvailable() returns false before fuzzy-matching even runs."
        )
    }
}

/// Precondition: NO preserved snapshot on disk (a normal, fresh launch
/// -- the base `CalyxUITestCase.setUp()`'s own default session dir is
/// already empty, so this class deliberately does NOT override
/// setUp()/tearDown() at all, unlike the class above, to prove this
/// really is the plain, unmodified launch path every other existing
/// E2E suite already exercises).
final class SessionRecoveryBarAbsentE2ETests: CalyxUITestCase {

    func test_recoveryBar_doesNotAppear_onNormalLaunchWithNoPreservedSnapshot() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        // Give any (incorrect) unconditional-bar implementation a real
        // chance to appear before asserting absence, mirroring
        // `waitForNonExistence`'s own polling shape rather than a bare
        // instant `.exists` check racing the app's own launch work.
        let staysAbsent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.otherElements["calyx.recoveryBar.container"]
        )
        let result = XCTWaiter().wait(for: [staysAbsent], timeout: 3)
        XCTAssertEqual(
            result, .timedOut,
            "A normal launch with nothing preserved on disk must show no recovery bar at all " +
            "(contract point 4) -- AccessibilityID.RecoveryBar.container must never appear."
        )
    }
}
