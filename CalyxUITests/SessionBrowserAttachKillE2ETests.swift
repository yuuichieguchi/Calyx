// SessionBrowserAttachKillE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the session browser's Attach/Kill actions
// (`Calyx/Features/SessionBrowser/SessionBrowserWindowController.swift`,
// `SessionBrowserModel.swift`, `SessionBrowserView.swift`): opening the
// browser via the command palette shows every daemon-tracked Running
// session, clicking "Attach" on a Detached row adds a new TAB reattached
// to it in the existing window (`AppDelegate.attachSessionAsTab`, titled
// from its cwd, tilde-abbreviated -- NOT a new window, and NOT the
// "Terminal" default), and clicking "Kill" removes a session from both
// the daemon ledger and the browser's own list. The attach assertions
// check BOTH the daemon ledger (a client actually connected) AND these
// two user-visible outcomes -- a prior version of this suite asserted
// only the ledger and shipped both defects unnoticed.
//
// Isolation: reuses `SessionPersistenceE2ETests`'s exact harness (short
// `/tmp` HOME so the daemon's `sockaddr_un` path stays under
// `SUN_LEN`, `CALYX_UITEST_SESSION_DIR` for window/tab persistence,
// `CALYX_SESSION_BIN` pinning a specific built `calyx-session` binary)
// rather than inventing a new one -- see that file's own setUp() doc
// comment for the full rationale of each piece.
//
// Row/button lookup: `SessionBrowserRowView` and `RemoteHostRowView`
// (Calyx/Features/SessionBrowser/SessionBrowserView.swift) each carry
// per-row `.accessibilityIdentifier`s from `AccessibilityID.SessionBrowser`
// (Calyx/Helpers/AccessibilityID.swift), the same pattern
// `SidebarContentView`'s tab/group rows use via
// `AccessibilityID.Sidebar`. With two or more simultaneously-Running
// sessions (the normal case: this suite's own session A + session B),
// the browser renders two identically-labeled "Attach" buttons and two
// identically-labeled "Kill" buttons, so tests below look each button
// up by its row-scoped identifier (`calyx.sessionBrowser.row.<id>
// .attachButton` / `.killButton`) rather than by label.

import XCTest

final class SessionBrowserAttachKillE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!
    private var execCounter = 0

    override var additionalLaunchArguments: [String] {
        ["-calyx.session.persistentSessionsEnabled", "YES"]
    }

    /// Mirrors `SessionPersistenceE2ETests.setUp()` exactly (see that
    /// file's own doc comment for why it does NOT call
    /// `super.setUp()`, why the root must stay short, and why `HOME`
    /// itself -- not some Calyx-internal setting -- is what redirects
    /// the daemon's on-disk state).
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
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = CalyxUITestCase.builtSessionBinaryPath
        app.launch()
    }

    private var ledger: DaemonLedgerReader { DaemonLedgerReader(homeDir: homeDir) }

    /// The macOS "abbreviate with tilde" convention, computed
    /// independently of whatever the app itself does internally: if
    /// `path` is `home` or a descendant of it, replace exactly that
    /// `home` prefix with `"~"`; otherwise return `path` unchanged.
    /// Deliberately NOT `(path as NSString).abbreviatingWithTildeInPath`
    /// -- that API resolves `~` against the CALLING process's own real
    /// `HOME` (this XCUITest runner's, not the isolated one this
    /// suite's `homeDir` launches Calyx.app with), so it would silently
    /// compare against the wrong home and never abbreviate here.
    private func tildeAbbreviated(_ path: String, home: String) -> String {
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + String(path.dropFirst(prefix.count))
    }

    /// Every currently-open window EXCEPT the session browser's own
    /// (title `"Sessions"`, set once in `SessionBrowserWindowController
    /// .init`'s `window.title = "Sessions"` and never renamed) -- i.e.
    /// the count of actual Calyx main (tab-hosting) windows, the thing
    /// E2E-A's window-count assertion below cares about. A tab created
    /// by attach must not change this count; only a brand-new WINDOW
    /// would.
    private func countMainWindows() -> Int {
        app.windows.matching(NSPredicate(format: "NOT (title == %@)", "Sessions")).count
    }

    /// Opens the session browser via the command palette's "Attach
    /// Session…" command (`CalyxWindowController.swift`'s
    /// `commandRegistry.register(PaletteCommand(id: "session.attach"
    /// ...))`, ungated -- unlike "New Remote Session…" it has no
    /// `isAvailable` closure, so it doesn't require
    /// `persistentSessionsEnabled` to be reachable, though this suite
    /// enables that setting anyway since the scenario itself needs
    /// persistent sessions). Filtering on a substring of the title
    /// (not the full "Attach Session…" including its ellipsis) mirrors
    /// `CommandPaletteUITests.test_executeCommand`'s own "New Tab"
    /// pattern.
    private func openSessionBrowserViaPalette() {
        openCommandPaletteViaMenu()
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette search field did not appear.")
        searchField.typeText("Attach Session")
        Thread.sleep(forTimeInterval: 0.3)
        searchField.typeKey(.enter, modifierFlags: [])
    }

    /// Full Attach/Kill round trip: session A (the initial window's
    /// own persistent pane) plus session B (created Detached via the
    /// calyx-session CLI, routed through A's own pane -- see
    /// `PaneCLIExec.paneExec`'s header for why a sandboxed XCUITest
    /// runner cannot spawn `calyx-session` itself). Opens the browser,
    /// confirms both rows render with the right Running/Detached
    /// state, attaches B (asserting the daemon ledger's
    /// `attached_clients` flips to >= 1, proving a NEW client actually
    /// connected -- not merely that the row was clicked), then kills A
    /// (asserting the ledger flips A to Exited and A's row disappears
    /// from the browser on its next 1s refresh, see
    /// `SessionBrowserView`'s `.task` poll loop).
    func test_sessionBrowser_attachDetachedSession_thenKillAnotherSession() {
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        // Baseline for the user-visible assertions added below (window
        // count, new tab's title): captured before session B even
        // exists, so a bug that opens an extra window OR changes the
        // wrong window's tab count can't hide behind a baseline taken
        // too late.
        let mainWindowCountBeforeAttach = countMainWindows()
        let tabCountBeforeAttach = countTabBarTabs()

        // Session A: the initial window's own persistent-session pane
        // registers with the daemon asynchronously; poll rather than
        // assume it's immediate (mirrors SessionPersistenceE2ETests).
        let initialPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in sessions.filter(self.ledger.isRunning) },
            until: { !$0.isEmpty }
        )
        guard let sessionARow = initialPoll.value.first, let sessionAID = ledger.id(of: sessionARow) else {
            XCTFail(
                "No \"Running\" session appeared in the daemon's ledger within ~30s of " +
                "launch, meaning the initial window's own persistent pane never " +
                "registered. Last ledger contents: \(initialPoll.raw)"
            )
            return
        }

        // Session B: created Detached (via `calyx-session new`, which
        // never attaches -- see calyx-session/crates/cli/src/commands/
        // new.rs's own doc comment) through session A's own pane.
        // `new` prints exactly the new session's id to stdout on
        // success (new.rs: `println!("{}", info.id)`), so the pasted
        // command's captured output IS session B's id -- matching the
        // ledger on this exact id (rather than "whichever OTHER
        // session showed up") rules out a false match against some
        // unrelated entry. Explicit `--runtime-dir`/`--state-dir` flags
        // (PaneCLIExec.swift's header) are REQUIRED here: without them
        // this would silently create session B against the developer's
        // REAL `~/.calyx`, not this test's isolated homeDir.
        //
        // `--cwd` is set explicitly to a directory UNDER this suite's
        // own isolated `homeDir` (created on disk first -- `new.rs`
        // spawns session B's shell immediately with this as its cwd,
        // via `Command::current_dir`, so a nonexistent path fails the
        // spawn) so this test can compute session B's expected
        // tilde-abbreviated title independently, from these two known
        // strings, without reading anything back from the daemon.
        //
        // Created from INSIDE the pane via `mkdir -p` -- the same
        // process context `calyx-session new`'s spawned child actually
        // chdirs into -- NOT from this XCUITest runner process.
        // Field-verified (not assumed): the runner IS App-Sandboxed
        // (this file's own header / PaneCLIExec.swift's header already
        // establish this for the daemon socket/HOME override) closely
        // enough that `FileManager.createDirectory` on a NEW subpath two
        // levels under `homeDir` fails with `NSCocoaErrorDomain Code=513
        // "Operation not permitted"` even though `homeDir` itself (created
        // the same way, one level up, in `setUp()`) succeeds -- so the
        // runner-side attempt was removed rather than kept as a
        // redundant no-op. `conn.rs`'s spawn-failed error formatting
        // always blames `argv[0]` even when the real ENOENT came from
        // `Command::current_dir` chdir'ing into a directory that doesn't
        // exist, which is exactly why this diagnostic output is captured
        // and attached to every failure message below rather than left
        // for a future debugging session to rediscover.
        let sessionBCwd = "\(homeDir!)/proj/nested"
        let paneMkdirOutput = paneExec(
            "mkdir -p \(sessionBCwd) && ls -ld \(sessionBCwd); echo rc=$?",
            counter: &execCounter
        )
        XCTAssertTrue(
            paneMkdirOutput.contains("rc=0"),
            "`mkdir -p \(sessionBCwd)` from inside the pane did not report rc=0: " +
            "\(paneMkdirOutput)"
        )
        let sessionBID = paneExec(
            "\(CalyxUITestCase.builtSessionBinaryPath) \(calyxSessionRootFlags(homeDir: homeDir)) new --name sessionB --cwd \(sessionBCwd)",
            counter: &execCounter
        )
        XCTAssertFalse(
            sessionBID.isEmpty || sessionBID == "(no output)",
            "`calyx-session new` produced no output when run through session A's pane, " +
            "meaning the CLI call routed through the pane never reached the daemon (or " +
            "CALYX_SESSION_BIN isn't inherited into the pane's environment -- see " +
            "SessionPersistenceE2ETests.swift's \"Constraint discovered while writing " +
            "this\")."
        )
        // `new.rs` prints ONLY a bare ULID on success; anything containing
        // "error" is the daemon's own error text (see conn.rs's
        // spawn-failed formatting), not a session id -- caught here,
        // with the pane's own `mkdir -p`/`ls -ld` output attached, rather
        // than surfacing 15s later as a more confusing "never appeared in
        // the ledger" failure.
        XCTAssertFalse(
            sessionBID.contains("error"),
            "`calyx-session new --cwd \(sessionBCwd)` returned an error instead of a " +
            "session id: \"\(sessionBID)\". Pane's own `mkdir -p`/`ls -ld` of that same " +
            "path: \(paneMkdirOutput)"
        )

        let sessionBPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionBID, in: sessions) },
            until: { $0 != nil }
        )
        guard let sessionBRow = sessionBPoll.value else {
            XCTFail(
                "Session B (id \(sessionBID), printed by `calyx-session new`) never " +
                "appeared in the daemon's ledger within ~15s. Last ledger contents: " +
                "\(sessionBPoll.raw). Pane's own `mkdir -p`/`ls -ld` of \(sessionBCwd): " +
                "\(paneMkdirOutput)"
            )
            return
        }
        XCTAssertEqual(
            ledger.attachedClients(of: sessionBRow), 0,
            "Session B should have 0 attached_clients right after `calyx-session new` " +
            "(it never attaches), so the browser's \"Detached\" badge has something " +
            "real to reflect. Row: \(sessionBRow)"
        )

        openSessionBrowserViaPalette()
        let browserWindow = app.windows["Sessions"]
        XCTAssertTrue(waitFor(browserWindow, timeout: 10), "Session browser window (\"Sessions\") did not open.")

        // Row presence: SessionBrowserRowView's identifying Text is
        // `row.info.name ?? row.info.id` -- A has no name (created by
        // Calyx itself, not this suite), so it renders its raw id; B
        // was explicitly named "sessionB" above.
        let rowAText = app.staticTexts[sessionAID]
        let rowBText = app.staticTexts["sessionB"]
        XCTAssertTrue(waitFor(rowAText, timeout: 10), "Session A's row (id \(sessionAID)) did not appear in the browser.")
        XCTAssertTrue(waitFor(rowBText, timeout: 10), "Session B's row (\"sessionB\") did not appear in the browser.")

        // Exactly one "Detached" badge: B (isOrphan, no local surface
        // anywhere in this Calyx process) but not A (isAttachedHere,
        // still the live main-window pane). SessionBrowserRow
        // .orphanBadgeLabel is the literal string this asserts against.
        // `.matching(identifier:)`, NOT a `label`-attribute predicate --
        // field-verified on this exact app that this hosted-SwiftUI
        // text exposes its string through a different accessibility
        // attribute than plain `label`. Polled (SessionBrowserView's
        // `.task` refreshes every 1s, and B's row can render on an
        // earlier pass than the one where SessionSurfaceMap's orphan
        // check has settled) rather than checked once immediately
        // after the row's own name text appears.
        var detachedBadgeCount = app.staticTexts.matching(identifier: "Detached").count
        for _ in 0..<8 where detachedBadgeCount != 1 {
            Thread.sleep(forTimeInterval: 1)
            detachedBadgeCount = app.staticTexts.matching(identifier: "Detached").count
        }
        XCTAssertEqual(
            detachedBadgeCount, 1,
            "Expected exactly one \"Detached\" badge (session B only) within ~8s of " +
            "both rows appearing; session A is still attached to the live main-window " +
            "pane and should not show one."
        )

        // Attach B: row-scoped lookup via its own accessibility
        // identifier (AccessibilityID.SessionBrowser.attachButton),
        // not the shared "Attach" label every row's button carries.
        let attachButtonForB = app.buttons["calyx.sessionBrowser.row.\(sessionBID).attachButton"]
        XCTAssertTrue(waitFor(attachButtonForB), "Session B's \"Attach\" button (id \(sessionBID)) did not appear in the browser.")
        attachButtonForB.click()

        let afterAttachPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionBID, in: sessions) },
            until: { ($0.flatMap(self.ledger.attachedClients) ?? 0) >= 1 }
        )
        XCTAssertGreaterThanOrEqual(
            afterAttachPoll.value.flatMap(ledger.attachedClients) ?? 0, 1,
            "Session B's attached_clients never reached >= 1 within ~10s of clicking " +
            "\"Attach\" on its row, meaning the browser's Attach action never actually " +
            "attached a client to the daemon-held session. Last ledger contents: " +
            "\(afterAttachPoll.raw)"
        )

        // USER-VISIBLE outcome (a): attaching B must land as a NEW TAB
        // in session A's existing window (`AppDelegate
        // .attachSessionAsTab`/`SessionAttachRoutingPolicy`), not a
        // second window -- the ledger assertion above only proves a
        // client connected, not where its surface actually appeared. A
        // regression back to "always open a new window" would leave the
        // ledger assertion green while this one catches it.
        XCTAssertEqual(
            countMainWindows(), mainWindowCountBeforeAttach,
            "The number of Calyx main windows changed after attaching session B " +
            "(before: \(mainWindowCountBeforeAttach), after: \(countMainWindows())); " +
            "attach is expected to add a TAB to the existing window, not open a new one."
        )

        // USER-VISIBLE outcome (b): the newly attached tab's title must
        // be session B's cwd, tilde-abbreviated -- NOT the `Tab.init`
        // default `"Terminal"` that a title-less attach silently falls
        // back to (`AppDelegate.attachSessionAsNewTab` constructs
        // `Tab(pwd: cwd, ...)` with no `title:` argument). `addTab`
        // always appends (`TabGroup.addTab`), so the new tab is the one
        // at `tabCountBeforeAttach` (the prior last index + 1, 0-based).
        // Polled rather than checked once: this suite's own established
        // idiom (`detachedBadgeCount` above) for a SwiftUI re-render
        // that may lag one beat behind the ledger state this line
        // itself just waited on.
        let expectedTabTitle = tildeAbbreviated(sessionBCwd, home: homeDir)
        let newTabValue = "calyx.tabBar.tab.index.\(tabCountBeforeAttach)"
        let newTabElement = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", newTabValue))
            .firstMatch
        XCTAssertTrue(
            waitFor(newTabElement, timeout: 10),
            "No tab-bar element with index value \(newTabValue) appeared after attaching " +
            "session B, meaning the tab count in session A's window never grew by one."
        )
        var newTabLabel = newTabElement.label
        for _ in 0..<8 where newTabLabel != expectedTabTitle {
            Thread.sleep(forTimeInterval: 1)
            newTabLabel = newTabElement.label
        }
        XCTAssertNotEqual(
            newTabLabel, "Terminal",
            "The tab attached for session B (cwd \(sessionBCwd)) still shows the " +
            "default title \"Terminal\" instead of a cwd-derived one."
        )
        XCTAssertEqual(
            newTabLabel, expectedTabTitle,
            "The tab attached for session B should show its cwd, tilde-abbreviated " +
            "against this suite's own isolated HOME (\(homeDir!)), as its title."
        )

        // For the team lead to eyeball: the attached tab's actual
        // rendered title, whatever it is right now.
        saveScreenshot(name: "session-browser-attach-result")

        // Re-invoking the palette command re-raises the SAME shared
        // `SessionBrowserWindowController.shared` window (`showWindow
        // (nil)` + `makeKeyAndOrderFront(nil)`, not a duplicate) so the
        // upcoming click lands on the browser's row, not on the tab bar
        // of the window attaching B just added a tab to (same screen
        // position).
        openSessionBrowserViaPalette()
        XCTAssertTrue(waitFor(browserWindow, timeout: 10), "Session browser window did not stay open/re-raise after attaching B.")

        // Kill A: a currently-attached (not just Running) session,
        // exercising the browser's Kill action against the more
        // demanding case (see this test's own doc comment for why A,
        // not B, is killed here). Row-scoped lookup via its own
        // accessibility identifier, same as the Attach button above.
        let killButtonForA = app.buttons["calyx.sessionBrowser.row.\(sessionAID).killButton"]
        XCTAssertTrue(waitFor(killButtonForA), "Session A's \"Kill\" button (id \(sessionAID)) did not appear in the browser.")
        killButtonForA.click()

        let afterKillPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionAID, in: sessions) },
            until: { session in session.map(self.ledger.isExited) ?? false }
        )
        XCTAssertTrue(
            afterKillPoll.value.map(ledger.isExited) ?? false,
            "Session A's ledger state never flipped to Exited within ~10s of clicking " +
            "\"Kill\" on its row. Last ledger contents: \(afterKillPoll.raw)"
        )

        // The browser filters Exited sessions out of `rows` entirely
        // (SessionBrowserModel.refresh()'s own doc comment), refreshed
        // on SessionBrowserView's 1s `.task` poll -- give it a couple
        // of cycles before asserting the row is gone.
        waitForNonExistence(rowAText, timeout: 8)
    }
}
