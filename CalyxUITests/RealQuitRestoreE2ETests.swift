// RealQuitRestoreE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the REAL quit path, as a variant of
// `SessionPersistenceE2ETests`'s restart test: that suite (like every
// other suite in this file's directory) quits via
// `menuAction("Calyx", item: "Quit Calyx")` while launched with
// `--uitesting`, which makes `AppDelegate.applicationShouldTerminate`
// (App/AppDelegate.swift:218-223) short-circuit straight to
// `.terminateNow` -- it never reaches `confirmQuitIfNeeded()`'s real
// `NSAlert`, and more importantly for THIS suite, it never drives
// `CalyxWindowController.windowShouldClose`/`windowWillClose` at all
// (menu Quit calls `NSApp.terminate`, which invokes
// `applicationShouldTerminate` directly). This suite instead closes the
// window (the red button), which routes through `windowShouldClose`
// regardless of `--uitesting` -- that flag only gates
// `applicationShouldTerminate` itself, a separate method -- pinning the
// exact path commit 3b1a6ca75 ("fix(session): terminating close no
// longer clobbers the snapshot") fixed:
// `CalyxWindowController.windowWillClose` used to save the snapshot on
// every last-managed-window close with no termination check, so a
// close that is PART OF app termination recorded the already-reduced,
// window-less state and destroyed the restore target before
// `applicationWillTerminate`'s own protected save could run. The fix
// gates that save on `isAppActuallyTerminating`
// (`CalyxWindowController.swift`) instead of the per-window
// `isClosingForShutdown` flag. The existing unit test for this
// (`CalyxTests/Views/CalyxWindowControllerLastWindowCloseSaveTests
// .swift`) drives `windowWillClose(_:)` directly with a bare
// `Notification` and a `_testInsert`-only fixture -- no live window, no
// real close, no real termination -- so it proves the GATING LOGIC but
// not the real, integrated path; this suite drives the real path this
// task's brief calls "the blind spot found today".
//
// WHY CLOSING THE WINDOW INSTEAD OF DROPPING `--uitesting` ENTIRELY
// (investigated per this task's brief, "approximate the real path as
// closely as the harness allows"): dropping `--uitesting` was
// considered and rejected after reading every production call site
// that checks for it (not just `applicationShouldTerminate`):
//   - `UpdateController.init` (Features/Update/UpdateController.swift
//     :24-33) skips Sparkle's `setupSparkle()` only under
//     `--uitesting`; without it, Sparkle's first-run "Check for
//     updates automatically?" modal pops in front of the app under
//     test and blocks every keystroke (that file's own comment).
//   - `NotificationManager` (Features/Notifications/
//     NotificationManager.swift:55-66) requests a REAL macOS
//     notification-permission prompt without it.
//   - `AppDelegate.installGlobalEventTap` (App/AppDelegate.swift:1988-
//     1990) enables a global CGEvent tap (Accessibility permission)
//     without it.
// All three are genuine, unrelated system-level side effects (modal
// dialogs outside the app's own accessibility hierarchy, real macOS
// permission grants) that would make a launch-without-`--uitesting`
// test flaky or, worse, durably change the test machine's own
// permission state. Closing the window instead keeps `--uitesting`
// (so none of the three fire) while still reaching
// `CalyxWindowController.windowShouldClose`'s OWN independent call to
// `appDelegate.confirmQuitIfNeeded()` (CalyxWindowController.swift:
// 3251-3284), completely unguarded by `--uitesting` -- the real
// confirm-quit `NSAlert.runModal()` this suite needs.
//
// WHY THIS TEST DELIBERATELY KEEPS THE PANE BUSY BEFORE CLOSING (an
// empirical correction, not the original plan): `Surface
// .needsConfirmQuit()` (ghostty/src/Surface.zig:923-941) returns true
// unless `cursorIsAtPrompt()` says the terminal is idle at a shell
// prompt, gated on the config's `confirm-close-surface`, whose default
// is `.true` (ghostty/src/config/Config.zig:2473, not overridden
// anywhere in Calyx). `cursorIsAtPrompt()`
// (ghostty/src/terminal/Terminal.zig:1324-1342) requires shell
// integration (OSC 133 semantic-prompt marks) and its own doc comment
// says "If the shell integration doesn't exist, this will always
// return false." `.claude/architecture.md`'s own documented gap (as of
// its 2026-07-04 update) says Calyx never sets `GHOSTTY_RESOURCES_DIR`,
// so this suite originally assumed shell integration is disabled
// everywhere and the dialog would therefore always appear
// unconditionally. A live run of this exact test showed otherwise: the
// window closed and the app fully quit with NO dialog ever appearing.
// Root cause found afterward: commit 34283b24a ("fix(session): inject
// ghostty shell integration into persistent-session shells", landed
// 2026-07-06, AFTER architecture.md's last update) specifically wires
// shell integration into calyx-session-managed shells -- exactly what
// `persistentSessionsEnabled` makes this test's own pane -- so
// architecture.md's blanket claim is now stale for THIS pane type: its
// shell settles at a real, semantically-marked prompt within a second
// or two of spawning, `cursorIsAtPrompt()` correctly reports true, and
// `needsConfirmQuit()` reports false, exactly the "nothing running,
// safe to quit silently" case the whole mechanism is designed for.
// Rather than depend on that timing (a close attempted right as the
// shell settles could go either way), this test pastes a
// deliberately-long-running foreground command into the pane first
// (`sleep 300`, via `panePasteAndReturn`, never awaited) so the cursor
// is provably NOT at an idle prompt at the moment of close, regardless
// of whether shell integration ends up active for this pane or not --
// covers both the "integration works" case (a running command's cursor
// state is not a prompt) and the "integration absent" case
// (`cursorIsAtPrompt()` always false either way) with one setup step.

import XCTest

final class RealQuitRestoreE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!

    override var additionalLaunchArguments: [String] {
        ["-calyx.session.persistentSessionsEnabled", "YES"]
    }

    /// Mirrors `SessionPersistenceE2ETests.setUp()` (see that file's
    /// own doc comment for the full rationale of each piece: short
    /// `/tmp` HOME for the daemon's `sockaddr_un` limit,
    /// `CALYX_UITEST_SESSION_DIR`, `CALYX_SESSION_BIN`).
    override func setUp() {
        continueAfterFailure = false
        let homeSuffix = String(UUID().uuidString.prefix(8))
        let sessionSuffix = String(UUID().uuidString.prefix(8))
        homeDir = "/tmp/cxe2e-\(homeSuffix)-h"
        sessionDir = "/tmp/cxe2e-\(sessionSuffix)-s"
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        launchApp()
    }

    override func tearDown() {
        app?.terminate()
        if let homeDir {
            try? FileManager.default.removeItem(atPath: homeDir)
        }
        if let sessionDir {
            try? FileManager.default.removeItem(atPath: sessionDir)
        }
        super.tearDown()
    }

    private func launchApp() {
        app = XCUIApplication()
        // `--uitesting` IS kept (see this file's header for why:
        // avoids Sparkle/notification/event-tap side effects unrelated
        // to what this suite tests) -- the real path under test is
        // reached via closing the window, not via dropping this flag.
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = CalyxUITestCase.builtSessionBinaryPath
        app.launch()
    }

    private func relaunchWithSameEnvironment() {
        launchApp()
    }

    private var ledger: DaemonLedgerReader { DaemonLedgerReader(homeDir: homeDir) }

    /// Mirrors `SessionBrowserAttachKillE2ETests.countMainWindows()`
    /// exactly (this suite never opens the session browser, so the title
    /// filter is inert here, but kept for consistency -- see
    /// `SessionPersistenceE2ETests`'s identical copy).
    private func countMainWindows() -> Int {
        app.windows.matching(NSPredicate(format: "NOT (title == %@)", "Sessions")).count
    }

    /// Mirrors `SessionBrowserAttachKillE2ETests.sidebarTabTitles()`
    /// exactly (see that file's own doc comment for why the sidebar,
    /// not the horizontal tab bar).
    private func sidebarTabTitles() -> Set<String> {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH %@", "calyx.sidebar.tab.", ".closeButton"))
        return Set(rows.allElementsBoundByIndex.map { row in
            row.descendants(matching: .staticText).firstMatch.value as? String ?? ""
        })
    }

    private func tildeAbbreviated(_ path: String, home: String) -> String {
        // Unlike SessionBrowserAttachKillE2ETests's own copy of this
        // helper (never called with `path == home` exactly, only
        // subdirectories), this suite's restored tab's cwd IS home
        // itself (no `cd` ever performed), which must map to the bare
        // "~" -- matching `SessionTabTitle.fromCwd`'s own identical
        // exact-match case.
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + String(path.dropFirst(prefix.count))
    }

    /// Candidate expected titles for the restored pane, given THIS
    /// suite's own specific setup.
    ///
    /// Field-verified (not assumed): unlike `SessionPersistenceE2ETests`
    /// (whose pane is idle at an actual shell prompt when it quits, so
    /// ghostty's zsh shell integration reports the cwd-derived `%~`
    /// title via its `_ghostty_precmd` hook, landing exactly on "~" for
    /// this suite's own isolated HOME), THIS suite deliberately pastes a
    /// long-running `sleep 300` into the pane before closing (see this
    /// file's header, "WHY THIS TEST DELIBERATELY KEEPS THE PANE BUSY"),
    /// which is still running at quit time. ghostty's `_ghostty_preexec`
    /// hook reports the COMMAND ITSELF as the OSC-2 title while it runs
    /// ("sleep 300" verbatim) -- `_ghostty_precmd`'s cwd-based title
    /// never fires again before quit, since that only happens once the
    /// shell returns to an idle prompt. The persisted `TabSnapshot`
    /// therefore literally carries whatever ghostty last reported
    /// ("sleep 300"), not a cwd-derived title -- restoreWindow() restores
    /// a Tab's title from the snapshot verbatim, with no recomputation
    /// (investigated: `SessionTabTitle.fromCwd` is only used by the
    /// session-browser attach flow, `AppDelegate.attachWindow`/
    /// `.attachSessionAsNewTab`, never by snapshot-based restore).
    private func expectedHomeTitleCandidates() -> Set<String> {
        var candidates: Set<String> = [tildeAbbreviated(homeDir, home: homeDir), "sleep 300"]
        let resolved = (homeDir as NSString).resolvingSymlinksInPath
        if resolved != homeDir {
            candidates.insert(tildeAbbreviated(resolved, home: resolved))
        }
        return candidates
    }

    /// Full round trip: confirm session A (the initial window's own
    /// persistent pane) is Running and attached, close the app's ONLY
    /// window via its red close button (routing through
    /// `windowShouldClose` -> the real `confirmQuitIfNeeded()` ->
    /// `NSAlert.runModal()`, all independent of `--uitesting`; see this
    /// file's header), click "Quit" on that real dialog, confirm the
    /// app fully terminates, relaunch, and confirm session A's pid and
    /// created_at_ms survived (same identity-proof technique as
    /// `SessionPersistenceE2ETests`) AND its attached_clients reaches
    /// >= 1 again (proving the restored pane actually reattached, not
    /// merely that the daemon-held process happened to survive) --
    /// exactly the observable symptom commit 3b1a6ca75's bug would have
    /// broken: with the pre-fix `windowWillClose` unconditionally
    /// saving on this close, the snapshot on disk at the moment of the
    /// real `applicationWillTerminate` save would already have been
    /// overwritten with a window-less state, so `restoreSession()`
    /// would find nothing to reattach and session A would be orphaned
    /// (Running in the daemon, but with attached_clients staying at 0
    /// forever after relaunch, and its pid/created_at_ms never surfacing
    /// in a restored tab at all).
    func test_realQuit_closingLastWindow_showsConfirmDialog_andSnapshotSurvivesForReattach() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        let preClosePoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in sessions.filter(self.ledger.isRunning) },
            until: { !$0.isEmpty }
        )
        guard let sessionRow = preClosePoll.value.first, let sessionID = ledger.id(of: sessionRow) else {
            XCTFail(
                "No \"Running\" session appeared in the daemon's ledger within ~30s of " +
                "launch, meaning the initial window's own persistent pane never " +
                "registered. Last ledger contents: \(preClosePoll.raw)"
            )
            return
        }

        let preAttachPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionID, in: sessions) },
            until: { ($0.flatMap(self.ledger.attachedClients) ?? 0) >= 1 }
        )
        let before = preAttachPoll.value
        XCTAssertGreaterThanOrEqual(
            before.flatMap(ledger.attachedClients) ?? 0, 1,
            "Session \(sessionID)'s attached_clients never reached >= 1 before closing " +
            "the window, meaning the initial pane never actually attached in the first " +
            "place. Last ledger contents: \(preAttachPoll.raw)"
        )
        guard let beforePid = before.flatMap({ $0["pid"] as? Int }),
              let beforeCreatedAtMs = before.flatMap({ $0["created_at_ms"] as? Int }) else {
            XCTFail("Session \(sessionID)'s ledger row is missing pid/created_at_ms. Row: \(String(describing: before))")
            return
        }

        // Baseline for the user-visible window-count assertion below,
        // captured immediately before closing the window (mirrors
        // SessionBrowserAttachKillE2ETests:353-361's own "capture right
        // before the action under test" placement).
        let mainWindowCountBeforeClose = countMainWindows()

        // Force needsConfirmQuit() == true regardless of whether this
        // pane's shell integration is active (see this file's header,
        // "WHY THIS TEST DELIBERATELY KEEPS THE PANE BUSY"): a
        // deliberately long-running foreground command, never awaited,
        // so the cursor is provably not at an idle prompt at the
        // moment of close.
        panePasteAndReturn("sleep 300")

        // Close the app's only window via its red close button --
        // NOT `app.terminate()` (SIGTERM, bypasses AppKit's whole
        // termination flow) and NOT the "Quit Calyx" menu item (calls
        // NSApp.terminate directly, skipping windowShouldClose
        // entirely) -- see this file's header for why this exact
        // action is the one that reaches the real, unguarded
        // `confirmQuitIfNeeded()`.
        app.windows.firstMatch.buttons[XCUIIdentifierCloseWindow].click()

        let confirmDialog = app.dialogs.firstMatch
        XCTAssertTrue(
            confirmDialog.waitForExistence(timeout: 8),
            "The real confirm-quit dialog (AppDelegate.confirmQuitIfNeeded(), driven via " +
            "windowShouldClose) did not appear within 8s of closing the last window, even " +
            "with a long-running `sleep 300` foreground command keeping the pane busy. " +
            "Per this file's header, ghostty's needsConfirmQuit() should be true whenever " +
            "a foreground command is running (regardless of shell-integration state), so " +
            "its absence here is itself a reportable finding, not just a timing miss."
        )
        XCTAssertTrue(
            confirmDialog.staticTexts["Quit Calyx?"].exists,
            "The confirm-quit dialog appeared but its title text did not match " +
            "confirmQuitIfNeeded()'s literal \"Quit Calyx?\" messageText."
        )
        confirmDialog.buttons["Quit"].click()

        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 10),
            "App did not fully terminate within 10s of clicking \"Quit\" on the real " +
            "confirm-quit dialog triggered by closing its last window."
        )

        relaunchWithSameEnvironment()
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not reappear after relaunch.")

        // USER-VISIBLE outcome (a): restoring must reopen the SAME
        // number of main windows as before closing, not more/fewer --
        // mirrors SessionBrowserAttachKillE2ETests:390-395's own
        // window-count assertion. The ledger-identity assertions below
        // only prove the daemon-side session survived, not that the
        // app's own window layout was restored correctly.
        XCTAssertEqual(
            countMainWindows(), mainWindowCountBeforeClose,
            "The number of Calyx main windows changed after the real-quit/relaunch round " +
            "trip (before: \(mainWindowCountBeforeClose), after: \(countMainWindows())); " +
            "restart is expected to restore the same window layout, not open a different " +
            "number of windows."
        )

        // USER-VISIBLE outcome (b): the restored tab's title must be
        // cwd-derived (this suite's own isolated HOME), NOT the
        // `Tab.init` default `"Terminal"` a title-less restore would
        // silently fall back to -- mirrors
        // SessionBrowserAttachKillE2ETests:397-447's own title
        // assertions. Read via the sidebar (`sidebarTabTitles()`'s own
        // doc comment), polled since the sidebar's restored row can lag
        // one beat behind the window reappearing.
        var restoredTitles = sidebarTabTitles()
        for _ in 0..<8 where restoredTitles.isEmpty {
            Thread.sleep(forTimeInterval: 1)
            restoredTitles = sidebarTabTitles()
        }
        XCTAssertFalse(
            restoredTitles.isEmpty,
            "Expected at least one restored sidebar tab after relaunch, got none."
        )
        XCTAssertFalse(
            restoredTitles.contains("Terminal"),
            "The restored tab should show a cwd-derived title, not the generic \"Terminal\" default. Titles: \(restoredTitles)"
        )
        let expectedTitleCandidates = expectedHomeTitleCandidates()
        for title in restoredTitles {
            XCTAssertTrue(
                expectedTitleCandidates.contains(title),
                "Restored tab title \"\(title)\" did not match any expected tilde-abbreviated " +
                "form of this suite's isolated HOME (\(homeDir!)): \(expectedTitleCandidates)"
            )
        }

        let postRestartPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in self.ledger.session(withID: sessionID, in: sessions) },
            until: { session in session.map(self.ledger.isRunning) ?? false }
        )
        guard let after = postRestartPoll.value, ledger.isRunning(after) else {
            XCTFail(
                "Session \(sessionID) was not \"Running\" in the daemon's ledger within " +
                "~30s of relaunching after a real, dialog-confirmed window close. If the " +
                "pre-fix bug (commit 3b1a6ca75) had regressed, this is exactly how it " +
                "would show: the terminating windowWillClose save would have already " +
                "overwritten the snapshot with a window-less state before " +
                "applicationWillTerminate's own save ran, leaving nothing for " +
                "restoreSession() to reattach. Last ledger contents: \(postRestartPoll.raw)"
            )
            return
        }
        XCTAssertEqual(
            after["pid"] as? Int, beforePid,
            "Session \(sessionID)'s pid changed after a real, dialog-confirmed window " +
            "close and relaunch (was \(beforePid), now \(String(describing: after["pid"]))), " +
            "meaning a fresh shell replaced the original instead of the daemon keeping " +
            "the same child alive."
        )
        XCTAssertEqual(
            after["created_at_ms"] as? Int, beforeCreatedAtMs,
            "Session \(sessionID)'s created_at_ms changed after a real, dialog-confirmed " +
            "window close and relaunch (was \(beforeCreatedAtMs), now " +
            "\(String(describing: after["created_at_ms"]))), meaning a new session was " +
            "created under the same id instead of the original one being restored from " +
            "the snapshot and reattached."
        )

        let postAttachPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionID, in: sessions) },
            until: { ($0.flatMap(self.ledger.attachedClients) ?? 0) >= 1 }
        )
        XCTAssertGreaterThanOrEqual(
            postAttachPoll.value.flatMap(ledger.attachedClients) ?? 0, 1,
            "Session \(sessionID)'s attached_clients never reached >= 1 within ~10s of " +
            "relaunching, meaning its identity survived but the RESTORED pane never " +
            "actually reattached to it -- exactly the symptom of the snapshot having " +
            "been silently clobbered before this session's own tab reference could be " +
            "written to it. Last ledger contents: \(postAttachPoll.raw)"
        )
    }
}
