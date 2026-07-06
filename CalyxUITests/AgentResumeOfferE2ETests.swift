// AgentResumeOfferE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the agent-resume-offer pipeline
// (`AppDelegate.offerAgentResume`, `SessionResumePlanner`,
// `AgentSessionMetaBridge`'s meta-key convention): once a reattached
// persistent-session pane's daemon-side session carries an
// `"agent.<kind>"` meta entry, `offerAgentResume` types
// `SessionResumePlanner.initialInput` into that pane via
// `sendText` -- "proposes" it (no trailing newline) when
// `SessionSettings.agentResumeAutoExecute` is off, or appends one when
// it's on.
//
// THERE IS NO DIALOG OR NOTIFICATION HERE (investigated per this
// task's brief, "find what the offer LOOKS like"): `offerAgentResume`
// (`Calyx/App/AppDelegate.swift:1928-1952`) calls
// `GhosttySurfaceController.sendText` directly, the same completion
// path a real clipboard paste goes through -- there is no
// user-facing surface at all beyond the pane itself gaining typed
// text. That text is Ghostty pane content, which
// `SessionPersistenceE2ETests.swift`'s header comment already
// establishes is GPU-rendered and invisible to XCUITest's
// accessibility tree (`app.staticTexts` can never observe it). This
// suite therefore reads the SAME observable side effect
// `SessionPersistenceE2ETests` reads for session identity: an on-disk
// file the daemon itself writes, in this case the per-session history
// file (`$HOME/.calyx/state/history/<id>.raw`, see
// `SessionHistoryFileReader`'s own header) rather than the ledger.
// History persistence must be explicitly on for that file to exist at
// all (`SessionSettings.historyPersistenceEnabled`), which this suite
// enables purely as a read-back channel, not as a feature under test.
//
// SCENARIO CHOICE, documented per this task's brief ("choose the
// honest minimal path and document it"): the brief's own wording
// ("a session with agent meta whose daemon died... kill the daemon
// abruptly") was investigated and NOT reproduced literally, for two
// reasons found by reading the daemon's own source:
//
//   1. `offerAgentResume` does not require the underlying process to
//      have died. `createSurfaceWithPwd` (AppDelegate.swift:1574-1609)
//      returns a non-nil `agentResumeSessionID` for ANY leaf that has
//      a `sessionRef`, Running or Exited -- the offer fires on every
//      reattach of a persistent-session pane with matching meta, not
//      specifically a resurrected one.
//   2. Killing a session and letting `--create` respawn it under the
//      same id does NOT preserve its meta: `conn.rs`'s
//      `create_session` (calyx-session/crates/daemon/src/conn.rs:466-
//      534) only takes the idempotent "already exists" path when
//      `state.sessions` (the LIVE, in-daemon-memory registry) still
//      has the id; once a killed session is reaped and removed from
//      that map, a `--create` reattach calls `spawn_session` fresh,
//      which starts a brand-new `SessionEntry` with
//      `meta: BTreeMap::new()` (`daemon/src/session.rs:528`) and
//      OVERWRITES the ledger's meta for that id
//      (`state.ledger.insert(spec.id.clone(), entry.info())`,
//      conn.rs:524). Setting meta before a kill-and-recreate cycle
//      would silently lose it before `offerAgentResume` ever got to
//      read it back.
//
// Given both, this suite sets meta on a session that is NEVER killed
// (Calyx.app is quit and relaunched, but the daemon-held session
// itself survives throughout, exactly like
// `SessionPersistenceE2ETests`'s own restart proof) and relies on
// finding (1) true from a straightforward menu-quit/relaunch, which is
// simpler AND avoids reproducing the meta-loss trap above.
//
// HISTORY-CAPTURE ORDERING (also investigated, not guessed):
// `session.rs` captures `history_enabled` ONCE, at a session's own
// `spawn_session` call, from the daemon's live `shared.history_enabled`
// flag at that instant -- never rechecked for the rest of that
// session's life. `AppDelegate.reassertHistoryPersistenceIfNeeded()`'s
// own doc comment (AppDelegate.swift:1848-1862) flags a race: it runs
// as a `Task` fired only AFTER `restoreSession()`'s synchronous surface
// creation already kicked off the FIRST persistent pane's own
// `attach --create`, so that first pane's history capture is NOT
// reliably on. Rather than trust that race, this suite explicitly runs
// `calyx-session history on` (via a pane, see `PaneCLIExec`'s header
// for why) and confirms its own `"on"` reply BEFORE creating the
// second tab whose session actually receives the agent meta -- that
// second session's `spawn_session` call happens strictly after the
// daemon-wide flag is confirmed on, so its own history capture is
// deterministic, not raced.

import XCTest

final class AgentResumeOfferE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!
    private var execCounter = 0

    override func setUp() {
        continueAfterFailure = false
        let homeSuffix = String(UUID().uuidString.prefix(8))
        let sessionSuffix = String(UUID().uuidString.prefix(8))
        homeDir = "/tmp/cxe2e-\(homeSuffix)-h"
        sessionDir = "/tmp/cxe2e-\(sessionSuffix)-s"
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        // Deliberately does NOT launch here (unlike
        // SessionPersistenceE2ETests/SessionBrowserAttachKillE2ETests):
        // this suite's two tests need different
        // `agentResumeAutoExecute` launch arguments, decided by each
        // test method itself via `launchApp(autoExecute:)` below.
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

    private func launchApp(autoExecute: Bool) {
        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "-AppleLanguages", "(en)",
            "-calyx.session.persistentSessionsEnabled", "YES",
            "-calyx.session.agentResumeEnabled", "YES",
            "-calyx.session.historyPersistenceEnabled", "YES",
            "-calyx.session.agentResumeAutoExecute", autoExecute ? "YES" : "NO",
        ]
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = CalyxUITestCase.builtSessionBinaryPath
        app.launch()
    }

    private func relaunchWithSameEnvironment(autoExecute: Bool) {
        launchApp(autoExecute: autoExecute)
    }

    /// Mirrors `SessionPersistenceE2ETests.quitAppViaMenu()` exactly
    /// (same doc comment applies: only a real menu quit, not
    /// `app.terminate()`, drives `applicationWillTerminate`'s
    /// synchronous snapshot save).
    private func quitAppViaMenu() {
        menuAction("Calyx", item: "Quit Calyx")
    }

    private var ledger: DaemonLedgerReader { DaemonLedgerReader(homeDir: homeDir) }
    private var history: SessionHistoryFileReader { SessionHistoryFileReader(homeDir: homeDir) }

    private static let resumeCommandText = "claude --resume fake-id"

    /// Runs the full setup shared by both tests: launch, confirm
    /// history-on, create a second tab (session under test), set its
    /// agent meta, quit, relaunch. Returns the under-test session's id.
    private func setUpResumableSessionAcrossRestart(autoExecute: Bool) -> String {
        launchApp(autoExecute: autoExecute)
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after launch.")

        let firstSessionPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in sessions.filter(self.ledger.isRunning) },
            until: { !$0.isEmpty }
        )
        guard let firstSessionRow = firstSessionPoll.value.first, let firstSessionID = ledger.id(of: firstSessionRow) else {
            XCTFail(
                "No \"Running\" session appeared in the daemon's ledger within ~30s of " +
                "launch. Last ledger contents: \(firstSessionPoll.raw)"
            )
            return ""
        }

        // Confirm history-on deterministically BEFORE the second tab
        // (whose session is the one actually under test) is created --
        // see this file's header, "HISTORY-CAPTURE ORDERING". Explicit
        // `--runtime-dir`/`--state-dir` flags (PaneCLIExec.swift's
        // header) are REQUIRED on every pane-executed calyx-session
        // call: without them this would silently flip history-on
        // against the developer's REAL daemon instead of this test's
        // isolated one.
        let historyOnOutput = paneExec(
            "\(CalyxUITestCase.builtSessionBinaryPath) \(calyxSessionRootFlags(homeDir: homeDir)) history on",
            counter: &execCounter
        )
        XCTAssertEqual(
            historyOnOutput, "on",
            "`calyx-session history on` did not reply \"on\" (got \(historyOnOutput.debugDescription)); " +
            "the daemon-wide history flag is not confirmed on, so the session created " +
            "next cannot reliably capture history."
        )

        createNewTabViaMenu()
        let secondSessionPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 1,
            transform: { sessions in sessions.filter { self.ledger.isRunning($0) && self.ledger.id(of: $0) != firstSessionID } },
            until: { !$0.isEmpty }
        )
        guard let secondSessionRow = secondSessionPoll.value.first, let sessionID = ledger.id(of: secondSessionRow) else {
            XCTFail(
                "The second tab's own persistent session never appeared as a distinct " +
                "\"Running\" ledger entry within ~15s of `createNewTabViaMenu()`. Last " +
                "ledger contents: \(secondSessionPoll.raw)"
            )
            return ""
        }

        _ = paneExec(
            "\(CalyxUITestCase.builtSessionBinaryPath) \(calyxSessionRootFlags(homeDir: homeDir)) " +
            "meta set \(sessionID) agent.claude-code=fake-id",
            counter: &execCounter
        )
        let metaPoll = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionID, in: sessions).map(self.ledger.meta) ?? [:] },
            until: { $0["agent.claude-code"] == "fake-id" }
        )
        XCTAssertEqual(
            metaPoll.value["agent.claude-code"], "fake-id",
            "Session \(sessionID)'s ledger meta never showed agent.claude-code=fake-id " +
            "within ~10s of `calyx-session meta set`. Last ledger contents: \(metaPoll.raw)"
        )

        quitAppViaMenu()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "App did not fully terminate within 10s of quitting via the menu.")
        relaunchWithSameEnvironment(autoExecute: autoExecute)
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not reappear after relaunch.")

        // Both sessions must still be the SAME ones (never killed, per
        // this file's header) for `offerAgentResume`'s meta lookup to
        // find what this test set on the correct session, not a
        // same-id impostor.
        let postRestartPoll = ledger.poll(
            timeoutAttempts: 15, sleepInterval: 2,
            transform: { sessions in self.ledger.session(withID: sessionID, in: sessions) },
            until: { session in session.map(self.ledger.isRunning) ?? false }
        )
        XCTAssertTrue(
            postRestartPoll.value.map(ledger.isRunning) ?? false,
            "Session \(sessionID) is no longer \"Running\" after restart. Last ledger " +
            "contents: \(postRestartPoll.raw)"
        )
        XCTAssertEqual(
            postRestartPoll.value.map(ledger.meta)?["agent.claude-code"],
            "fake-id",
            "Session \(sessionID)'s meta no longer carries agent.claude-code=fake-id " +
            "after restart, meaning it was lost across the restart rather than surviving " +
            "on the same live session."
        )

        return sessionID
    }

    /// Confirmation mode (`agentResumeAutoExecute == false`, the
    /// default): `SessionResumePlanner.initialInput` has NO trailing
    /// newline, so the reattached pane should show the resume command
    /// typed but not submitted.
    func test_agentResumeOffer_proposesResumeCommand_inConfirmationMode() {
        let sessionID = setUpResumableSessionAcrossRestart(autoExecute: false)
        guard !sessionID.isEmpty else { return }

        let historyPoll = history.poll(
            timeoutAttempts: 15, sleepInterval: 2, id: sessionID,
            until: { $0?.contains(Self.resumeCommandText) ?? false }
        )
        guard let content = historyPoll, content.contains(Self.resumeCommandText) else {
            XCTFail(
                "Session \(sessionID)'s history file never showed \"\(Self.resumeCommandText)\" " +
                "within ~30s of relaunching, meaning offerAgentResume either never fired " +
                "or its injected text never reached the PTY. History file contents: " +
                "\(historyPoll ?? "<no history file>")"
            )
            return
        }

        XCTAssertFalse(
            newlineFollowsShortly(after: Self.resumeCommandText, in: content),
            "In confirmation mode, the resume command should be typed WITHOUT a " +
            "trailing newline (SessionResumePlanner.initialInput's own contract), but " +
            "a newline/carriage-return appeared shortly after it in the history file. " +
            "History file contents: \(content)"
        )
    }

    /// Auto-execute mode (`agentResumeAutoExecute == true`):
    /// `SessionResumePlanner.initialInput` appends a trailing newline
    /// to the SAME command. NOTE (see this file's header, no
    /// duplicate rationale here): whether the target shell's bracketed
    /// -paste handling actually treats that trailing newline as Return
    /// is explicitly flagged as unverified by `offerAgentResume`'s own
    /// doc comment (AppDelegate.swift:1916-1922) -- this test asserts
    /// only that the INPUT BYTES were shaped correctly (trailing
    /// newline present), which is deterministic regardless of what the
    /// shell does with it, and does not assert on `claude` actually
    /// running. A best-effort cleanup kill runs afterward in case the
    /// shell DID submit it, so no `claude` subprocess (real, spawned by
    /// this system's own `claude` binary if present on PATH) is left
    /// running past this test.
    func test_agentResumeOffer_autoExecutesResumeCommand_whenAutoExecuteSettingIsOn() {
        let sessionID = setUpResumableSessionAcrossRestart(autoExecute: true)
        guard !sessionID.isEmpty else { return }

        let historyPoll = history.poll(
            timeoutAttempts: 15, sleepInterval: 2, id: sessionID,
            until: { $0?.contains(Self.resumeCommandText) ?? false }
        )
        guard let content = historyPoll, content.contains(Self.resumeCommandText) else {
            XCTFail(
                "Session \(sessionID)'s history file never showed \"\(Self.resumeCommandText)\" " +
                "within ~30s of relaunching, meaning offerAgentResume either never fired " +
                "or its injected text never reached the PTY. History file contents: " +
                "\(historyPoll ?? "<no history file>")"
            )
            return
        }

        XCTAssertTrue(
            newlineFollowsShortly(after: Self.resumeCommandText, in: content),
            "In auto-execute mode, the resume command should be typed WITH a trailing " +
            "newline (SessionResumePlanner.initialInput's own contract), but no " +
            "newline/carriage-return appeared shortly after it in the history file. " +
            "History file contents: \(content)"
        )

        // Best-effort safety net: see this test's own doc comment. Not
        // itself an assertion -- targets the session by explicit id,
        // so it's harmless regardless of which pane is currently
        // focused (kill.rs's `killpg` takes down the whole process
        // group, not just a direct child, so any `claude` process the
        // shell may have launched dies alongside it).
        panePasteAndReturn(
            "\(CalyxUITestCase.builtSessionBinaryPath) \(calyxSessionRootFlags(homeDir: homeDir)) kill \(sessionID)"
        )
        _ = ledger.poll(
            timeoutAttempts: 10, sleepInterval: 1,
            transform: { sessions in self.ledger.session(withID: sessionID, in: sessions) },
            until: { session in session.map(self.ledger.isExited) ?? false }
        )
    }

    /// True if a newline or carriage-return character appears within
    /// the 50 characters immediately following the first occurrence of
    /// `substring` in `text` -- a bounded, "shortly after" window
    /// rather than "anywhere later in the file" (which could produce a
    /// false positive from the reattached pane's own next shell
    /// prompt, unrelated to whether the PASTED text itself carried a
    /// trailing newline).
    private func newlineFollowsShortly(after substring: String, in text: String) -> Bool {
        guard let range = text.range(of: substring) else { return false }
        let after = text[range.upperBound...].prefix(50)
        return after.contains(where: { $0 == "\n" || $0 == "\r" })
    }
}
