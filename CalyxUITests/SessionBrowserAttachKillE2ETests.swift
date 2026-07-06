// SessionBrowserAttachKillE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the session browser's Attach/Kill actions
// (`Calyx/Features/SessionBrowser/SessionBrowserWindowController.swift`,
// `SessionBrowserModel.swift`, `SessionBrowserView.swift`): opening the
// browser via the command palette shows every daemon-tracked Running
// session, clicking "Attach" on a Detached row brings up a new window
// reattached to it, and clicking "Kill" removes a session from both the
// daemon ledger and the browser's own list.
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
        let sessionBID = paneExec(
            "\(CalyxUITestCase.builtSessionBinaryPath) \(calyxSessionRootFlags(homeDir: homeDir)) new --name sessionB",
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

        let sessionBPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionBID, in: sessions) },
            until: { $0 != nil }
        )
        guard let sessionBRow = sessionBPoll.value else {
            XCTFail(
                "Session B (id \(sessionBID), printed by `calyx-session new`) never " +
                "appeared in the daemon's ledger within ~15s. Last ledger contents: " +
                "\(sessionBPoll.raw)"
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

        // Attaching B opened a brand-new window for its reattached
        // pane (`SessionBrowserWindowController.attach(_:)`'s own doc
        // comment: "opens a brand-new window that reattaches to it"),
        // which may now sit on top of the Sessions browser window at
        // the same screen position. Re-invoking the palette command
        // re-raises the SAME shared `SessionBrowserWindowController
        // .shared` window (`showWindow(nil)` + `makeKeyAndOrderFront
        // (nil)`, not a duplicate) so the upcoming click lands on the
        // browser's row, not on whatever the new window put in the
        // same screen coordinates.
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
