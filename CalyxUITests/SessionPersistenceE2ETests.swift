// SessionPersistenceE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the persistent-session pipeline: a shell
// process running in a persistent-session pane must survive an app
// restart (calyx-session's daemon keeps the child process running
// independent of Calyx.app's lifetime), and the pane restored after
// relaunch must reattach to that SAME shell, rather than a fresh
// replacement shell being spawned.
//
// Verification method: this test never types into the app and never
// reads pane content, so keystroke leakage is structurally
// impossible. An earlier version of this test drove the pane with
// `app.typeText`, but that API synthesizes global key events that
// land on whatever window is truly frontmost system-wide, not
// something scoped to the app under test -- an xctest-launched app
// cannot reliably hold focus, so a stray keystroke could leak into
// whatever the developer running this suite had focused on their
// real desktop. It also had to work around Ghostty rendering terminal
// content on the GPU, which keeps it out of the accessibility tree
// entirely (so `app.staticTexts` can never observe it).
//
// A subsequent version queried the daemon by spawning
// `calyx-session ls --all --json` as an out-of-process `Process` from
// inside the test runner. That approach is unusable here: the
// `CalyxUITests` runner is itself App-Sandboxed (`codesign -d
// --entitlements` on the test runner shows
// `com.apple.security.app-sandbox` set to true, with only a read-only
// files temporary exception granted), and a sandboxed process cannot
// connect to the daemon's unix domain socket. Spawning
// `calyx-session ls` from the runner therefore always returns empty
// stdout, even while the daemon is alive, healthy, and holding
// sessions (confirmed by running the identical query unsandboxed
// against the same `HOME` during this run, which succeeded). This is
// exactly the constraint that `BrowserScriptingUITests`' file-readback
// pattern (`terminalExec`, which redirects command output to a file
// and reads it back with `Data(contentsOf:)`) already works around:
// the sandboxed runner can READ but cannot open new outbound
// connections.
//
// So this test reads the daemon's own on-disk ledger file directly,
// `$HOME/.calyx/state/sessions.json` (see
// `calyx-session/crates/daemon/src/ledger.rs`), the same file the
// daemon writes atomically (temp file + rename) on every registry
// change, and the same array `calyx-session ls` would otherwise print,
// to confirm the SAME session id keeps the SAME pid and
// created_at_ms across an app restart. That is the strongest proof
// available, from a sandboxed runner, that the daemon kept the exact
// same child process alive across Calyx.app's termination, and that
// the restored pane reattached to it rather than a fresh session
// being created. Identity survival alone would not prove reattach
// though: a daemon keeps a session alive with zero attached clients,
// so `attached_clients` (which `conn.rs`'s `attach`/`detach`
// increment/decrement and persist to this same ledger on every
// attach/detach) is asserted at >= 1 on BOTH sides of the restart,
// proving a client was actually attached before termination and that
// a client (the restored pane) actually reattached afterward.
//
// Isolation:
// - Window/tab session persistence: `CalyxUITestCase`'s existing
//   `CALYX_UITEST_SESSION_DIR` (per-test temp dir) — reused here via
//   its own launchEnvironment key, unchanged.
// - calyx-session daemon state (`$HOME/.calyx/run`,
//   `$HOME/.calyx/state` — see
//   `calyx-session/crates/cli/src/commands/mod.rs`'s
//   `resolve_runtime_dir`): the daemon consults `$HOME` directly and
//   has no independent `CALYX_SESSION_*` runtime-dir override wired
//   through the bundled `Calyx.app` launch path, so `HOME` itself is
//   overridden to a per-test temp directory instead.
// - `CALYX_SESSION_BIN` points `SessionBinaryResolver` at a
//   specific, already-built `calyx-session` binary rather than the
//   bundled `Resources/bin` copy, so this test can pin an exact
//   binary independent of what's currently bundled into the `.app`
//   under test.
//
// Constraint discovered while writing this (flagged for the
// Green/test-runner phase to verify empirically, since this test does
// not run yet): `Calyx.app`'s ghostty-spawned `calyx-session attach`
// child process inherits its environment from `Calyx.app`'s own
// process, which is what makes overriding `HOME` on `app
// .launchEnvironment` (rather than some Calyx-internal setting) enough
// to redirect the daemon's on-disk state — but this assumes ghostty's
// `command` execution doesn't scrub/replace the environment before
// spawning. That assumption needs empirical confirmation the first
// time this test actually runs.

import XCTest

final class SessionPersistenceE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!

    override var additionalLaunchArguments: [String] {
        ["-calyx.session.persistentSessionsEnabled", "YES"]
    }

    /// Does NOT call `super.setUp()`: the base class's `setUp()`
    /// launches `app` immediately with its own environment, before a
    /// subclass would have any chance to set `HOME`/`CALYX_SESSION_BIN`
    /// on `launchEnvironment` first. This re-implements the base
    /// class's launch, adding the two extra environment overrides this
    /// suite needs.
    override func setUp() {
        continueAfterFailure = false

        // Short root REQUIRED: the daemon's socket lives at
        // $HOME/.calyx/run/sessiond.sock (see
        // `calyx-session/crates/cli/src/commands/mod.rs`'s
        // `default_home_subdir`, which joins the literal `HOME` env var
        // with no canonicalization), and macOS's sockaddr_un limits
        // `sun_path` to 104 bytes (SUN_LEN). NSTemporaryDirectory()
        // (`/var/folders/.../T/...`) is long enough on its own to blow
        // past that limit once `.calyx/run/sessiond.sock` is appended.
        // Do NOT move this back to NSTemporaryDirectory(). Worst case
        // here: "/tmp/cxe2e-" (11 bytes) + 8-char UUID prefix (8 bytes)
        // + "-h" (2 bytes) = 21 bytes for homeDir, plus
        // "/.calyx/run/sessiond.sock" (25 bytes) = 46 bytes total,
        // comfortably under the 104-byte SUN_LEN limit.
        let homeSuffix = String(UUID().uuidString.prefix(8))
        let sessionSuffix = String(UUID().uuidString.prefix(8))
        homeDir = "/tmp/cxe2e-\(homeSuffix)-h"
        sessionDir = "/tmp/cxe2e-\(sessionSuffix)-s"
        try? FileManager.default.createDirectory(atPath: homeDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

        launchApp()
    }

    override func tearDown() {
        // `app?.terminate()`, not `app!.terminate()`: this override's
        // setUp() has no early-bailout path today, but nothing in
        // XCTestCase's contract rules out a future setUp() failure
        // leaving `app` unassigned before tearDown() runs.
        app?.terminate()
        // `removeItem` can fail here under the runner's App Sandbox
        // (already tolerated via `try?`); that is fine because
        // `homeDir`/`sessionDir` are freshly UUID-named per run, so a
        // leftover directory from a failed cleanup can never collide
        // with, or contaminate, a later run.
        if let homeDir {
            try? FileManager.default.removeItem(atPath: homeDir)
        }
        if let sessionDir {
            try? FileManager.default.removeItem(atPath: sessionDir)
        }
        super.tearDown()
    }

    /// Path to a pre-built `calyx-session` binary this test points
    /// `CALYX_SESSION_BIN` at. RED-phase placeholder: the actual
    /// resolution (an env var supplied by the `/e2e-test` skill
    /// invocation, vs. a `cargo build --release` step run ahead of the
    /// UI test bundle) is a test-runner-phase concern.
    private static func builtSessionBinaryPath() -> String {
        ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"] ?? ""
    }

    /// Configures and launches a fresh `XCUIApplication` with this
    /// suite's HOME/session-dir/binary environment. Used identically
    /// by `setUp()` and `relaunchWithSameEnvironment()` (the latter
    /// simulating the user quitting and reopening Calyx, not a fresh
    /// test environment) so the two launch paths can never drift
    /// apart from each other.
    private func launchApp() {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = Self.builtSessionBinaryPath()
        app.launch()
    }

    private func relaunchWithSameEnvironment() {
        launchApp()
    }

    // MARK: - Daemon-ledger polling
    //
    // Verification is daemon-ledger-based, not keystroke-based: this
    // test never calls `app.typeText` or reads pane content, so
    // keystroke leakage into the developer's real terminal (see this
    // file's header comment) is structurally impossible. The ledger is
    // read directly from disk, never through a spawned
    // `calyx-session ls` process, because the sandboxed test runner
    // cannot open the unix domain socket that would require (see file
    // header).

    /// Reads and parses the daemon's on-disk session ledger at
    /// `$HOME/.calyx/state/sessions.json` (see
    /// `calyx-session/crates/daemon/src/ledger.rs`), the same array
    /// `calyx-session ls` would otherwise print. Each entry mirrors
    /// `SessionInfo` (`calyx-session/crates/proto/src/control.rs`):
    /// `"id"` (String), `"pid"` (Int, the daemon-side child PID),
    /// `"created_at_ms"` (Int), `"attached_clients"` (Int, incremented
    /// on every daemon `attach` and decremented on every `detach`, see
    /// `calyx-session/crates/daemon/src/conn.rs`), and `"state"`,
    /// which is either the bare string `"Running"` or the dictionary
    /// `{"Exited": {"code": Int}}` once the child has exited. Returns
    /// an empty session array (rather than failing the test) if the
    /// file doesn't exist yet or contains no parseable JSON array of
    /// objects: the daemon only writes the file atomically after its
    /// first registry change, so a missing file simply means nothing
    /// has registered yet. The paired `raw` string is the exact bytes
    /// this read parsed (or a placeholder describing why parsing
    /// failed), returned alongside the sessions rather than stashed in
    /// a mutable property, so a caller's `XCTFail` message always
    /// describes the SAME read its assertion failed against, never a
    /// later read that raced past it. The caller's polling loop is
    /// expected to fail the test with diagnostics once it gives up.
    private func daemonSessions() -> (sessions: [[String: Any]], raw: String) {
        let ledgerURL = URL(fileURLWithPath: "\(homeDir!)/.calyx/state/sessions.json")

        guard let data = try? Data(contentsOf: ledgerURL) else {
            return ([], "<no ledger file at \(ledgerURL.path)>")
        }
        let raw = String(data: data, encoding: .utf8) ?? "<non-UTF8 ledger, \(data.count) bytes>"

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let sessions = jsonObject as? [[String: Any]] else {
            return ([], raw)
        }
        return (sessions, raw)
    }

    /// True if `session`'s `"state"` field is the bare string
    /// `"Running"` (as opposed to `{"Exited": {"code": n}}`, which
    /// decodes as a dictionary rather than a string, see
    /// `SessionState`'s serde derive).
    private func isRunning(_ session: [String: Any]) -> Bool {
        (session["state"] as? String) == "Running"
    }

    /// One session's identity- and attachment-relevant ledger fields,
    /// parsed once from a raw ledger entry (see `daemonSessions()`)
    /// so the pre-restart and post-restart capture code paths read
    /// exactly the same fields the exact same way and can never drift
    /// from each other.
    private struct SessionSnapshot {
        let pid: Int
        let createdAtMs: Int
        let attachedClients: Int
        let isRunning: Bool
    }

    /// Parses one raw ledger entry into a `SessionSnapshot`, or `nil`
    /// if any of the expected fields is missing or the wrong type.
    private func snapshot(from session: [String: Any]) -> SessionSnapshot? {
        guard let pid = session["pid"] as? Int,
              let createdAtMs = session["created_at_ms"] as? Int,
              let attachedClients = session["attached_clients"] as? Int else {
            return nil
        }
        return SessionSnapshot(
            pid: pid,
            createdAtMs: createdAtMs,
            attachedClients: attachedClients,
            isRunning: isRunning(session)
        )
    }

    /// Parses every raw ledger entry that has a string `"id"` and a
    /// fully parseable `SessionSnapshot` (see `snapshot(from:)`) into
    /// an id-keyed dictionary, dropping entries that don't parse.
    private func snapshots(from sessions: [[String: Any]]) -> [String: SessionSnapshot] {
        Dictionary(
            uniqueKeysWithValues: sessions.compactMap { session -> (String, SessionSnapshot)? in
                guard let id = session["id"] as? String,
                      let snap = snapshot(from: session) else { return nil }
                return (id, snap)
            }
        )
    }

    /// Polls `daemonSessions()` (up to `timeoutAttempts` reads,
    /// sleeping `sleepInterval` between each), transforming every raw
    /// read via `transform`, until `isDone` accepts the transformed
    /// value. Checks BEFORE sleeping, so a caller whose expected state
    /// is already true on the first read returns immediately without
    /// ever sleeping. Always returns the LAST transformed value and
    /// the raw ledger text it came from, whether or not `isDone` ever
    /// matched, so a caller that times out can still build a failure
    /// message describing the exact read that failed.
    private func pollLedger<T>(
        timeoutAttempts: Int,
        sleepInterval: TimeInterval,
        transform: ([[String: Any]]) -> T,
        until isDone: (T) -> Bool
    ) -> (value: T, raw: String) {
        var (sessions, raw) = daemonSessions()
        var value = transform(sessions)
        var attempt = 1
        while !isDone(value) && attempt < timeoutAttempts {
            Thread.sleep(forTimeInterval: sleepInterval)
            (sessions, raw) = daemonSessions()
            value = transform(sessions)
            attempt += 1
        }
        return (value, raw)
    }

    // MARK: - Restart replay

    /// Full round trip: confirm at least one `Running` session is
    /// registered with the daemon after creating a persistent-session
    /// tab (the initial window's own tab is itself a persistent pane,
    /// so up to two `Running` entries can legitimately be present, not
    /// just the one created here) and that its `attached_clients` is
    /// >= 1 (proving the pane actually attached, not merely that a
    /// session with that id exists); terminate the app; relaunch with
    /// the same HOME/session-dir; and confirm every session id
    /// captured before restart is still `Running` with the SAME pid
    /// and created_at_ms, AND that its `attached_clients` is >= 1
    /// again afterward (proving the restored pane actually reattached,
    /// not just that the child process happened to survive; see file
    /// header for why daemon-ledger identity plus attachment, not pane
    /// content, is the verification method here).
    func test_persistentSession_survivesRestart_sameShellStaysAlive() {
        createNewTabViaMenu()
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not appear after creating a new tab.")

        // Creating the persistent-session tab makes the pane run
        // `calyx-session attach --create`, which registers a session
        // with the daemon asynchronously; poll rather than assume it's
        // immediate.
        let sawRunningSession = pollLedger(
            timeoutAttempts: 15,
            sleepInterval: 2,
            transform: { sessions in sessions.contains(where: isRunning) },
            until: { $0 }
        )

        guard sawRunningSession.value else {
            XCTFail(
                "No \"Running\" session appeared in the daemon's ledger within ~30s of " +
                "creating the persistent-session tab, meaning no pane's " +
                "`calyx-session attach --create` ever established a live daemon session. " +
                "Last ledger contents: \(sawRunningSession.raw)"
            )
            return
        }

        // Captures the running-session set AND waits for every one of
        // them to reach attached_clients >= 1 in the same poll: the
        // menu-created tab's registration can lag slightly behind the
        // initial window's own persistent pane, and the daemon
        // persists attached_clients asynchronously after AttachOk (see
        // conn.rs's attach), so this checks BEFORE sleeping and only
        // sleeps (1s at a time, up to ~10s) if the expected state
        // isn't there yet. It is fine for one or two sessions to be
        // present; whichever set is actually there is what restart
        // must preserve.
        let preRestartPoll = pollLedger(
            timeoutAttempts: 10,
            sleepInterval: 1,
            transform: { sessions in snapshots(from: sessions).filter { $0.value.isRunning } },
            until: { snaps in !snaps.isEmpty && snaps.values.allSatisfy { $0.attachedClients >= 1 } }
        )
        let preRestart = preRestartPoll.value

        guard !preRestart.isEmpty else {
            XCTFail(
                "No \"Running\" session with a parseable id/pid/created_at_ms/" +
                "attached_clients was found even though an earlier poll saw one, meaning " +
                "the ledger's shape is unexpected. Last ledger contents: \(preRestartPoll.raw)"
            )
            return
        }

        for (id, snap) in preRestart {
            XCTAssertGreaterThanOrEqual(
                snap.attachedClients, 1,
                "Session \(id)'s attached_clients never reached >= 1 within ~10s of the " +
                "tab appearing, meaning the pane's `calyx-session attach --create` " +
                "connection never actually attached to the daemon-held session (a " +
                "\"Running\" session can exist with zero attached clients, so identity " +
                "alone would not prove the original pane was attached before restart). " +
                "Last ledger contents: \(preRestartPoll.raw)"
            )
        }

        app.terminate()
        relaunchWithSameEnvironment()
        XCTAssertTrue(waitFor(app.windows.firstMatch), "App window did not reappear after relaunch.")

        // The restored panes' reattach to their daemon-held sessions
        // completes asynchronously after the window appears, with no
        // XCUITest-visible signal for "reattach done"; poll rather than
        // assume it's immediate.
        let postRestartPoll = pollLedger(
            timeoutAttempts: 15,
            sleepInterval: 2,
            transform: { sessions in snapshots(from: sessions) },
            until: { snaps in preRestart.keys.allSatisfy { id in snaps[id]?.isRunning ?? false } }
        )
        let postRestart = postRestartPoll.value

        for (id, before) in preRestart {
            guard let after = postRestart[id] else {
                XCTFail(
                    "Session \(id) was absent from the daemon's ledger within ~30s of " +
                    "restarting the app, meaning the session was lost: the daemon did not " +
                    "keep it alive across Calyx.app's termination. Last ledger contents: " +
                    "\(postRestartPoll.raw)"
                )
                continue
            }
            XCTAssertTrue(
                after.isRunning,
                "Session \(id)'s state is no longer \"Running\" after restart, meaning " +
                "the daemon-held child process died instead of surviving Calyx.app's " +
                "termination."
            )
            XCTAssertEqual(
                after.pid, before.pid,
                "Session \(id)'s pid changed after restart (was \(before.pid), now " +
                "\(after.pid)), meaning a fresh shell replaced the original instead of " +
                "the daemon keeping the same child alive: persistence is broken."
            )
            XCTAssertEqual(
                after.createdAtMs, before.createdAtMs,
                "Session \(id)'s created_at_ms changed after restart (was " +
                "\(before.createdAtMs), now \(after.createdAtMs)), meaning a new session " +
                "was created under the same id instead of the original one being " +
                "reattached."
            )
        }

        // Identity survival alone does not prove the RESTORED PANES
        // actually reattached to the daemon: a daemon keeps a session
        // alive with zero attached clients (conn.rs's detach only
        // decrements attached_clients, it never kills the session), so
        // poll separately for every captured id's attached_clients
        // reaching >= 1, which only happens once a client (the
        // restored pane) attaches (conn.rs's attach).
        let reattachedPoll = pollLedger(
            timeoutAttempts: 10,
            sleepInterval: 1,
            transform: { sessions in snapshots(from: sessions) },
            until: { snaps in preRestart.keys.allSatisfy { id in (snaps[id]?.attachedClients ?? 0) >= 1 } }
        )
        let reattached = reattachedPoll.value

        for id in preRestart.keys {
            XCTAssertGreaterThanOrEqual(
                reattached[id]?.attachedClients ?? 0, 1,
                "Session \(id)'s attached_clients never reached >= 1 within ~10s of " +
                "relaunching, meaning its identity survived the restart but no client " +
                "ever actually reattached to the daemon-held session (a \"Running\" " +
                "session can persist with zero attached clients, so surviving " +
                "pid/created_at_ms alone does not prove the restored pane reattached " +
                "rather than leaving the original session orphaned). Last ledger " +
                "contents: \(reattachedPoll.raw)"
            )
        }
    }
}
