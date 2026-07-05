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
// something scoped to the app under test — an xctest-launched app
// cannot reliably hold focus, so a stray keystroke could leak into
// whatever the developer running this suite had focused on their
// real desktop. It also had to work around Ghostty rendering terminal
// content on the GPU, which keeps it out of the accessibility tree
// entirely (so `app.staticTexts` can never observe it).
//
// Instead, this test queries calyx-session's own daemon ledger
// directly — `calyx-session ls --all --json`, run out-of-process
// against this test's isolated `HOME` — to confirm the SAME session
// id keeps the SAME pid and created_at_ms across an app restart. That
// is the strongest proof available that the daemon kept the exact
// same child process alive across Calyx.app's termination, and that
// the restored pane reattached to it rather than a fresh session
// being created.
//
// RED phase note (P4): this test is written to compile against
// `CalyxUITestCase` and the app's existing `--uitesting` /
// command-line UserDefaults conventions, but is NOT executed as part
// of this phase's Red confirmation — E2E runs are `/e2e-test`-only
// (no background double-launch of a real calyx-session daemon while
// other suites run). Building the CalyxUITests target confirms this
// file compiles; actual execution happens once in the test-runner
// phase.
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

import AppKit
import XCTest

final class SessionPersistenceE2ETests: CalyxUITestCase {

    private var homeDir: String!
    private var sessionDir: String!

    override var additionalLaunchArguments: [String] {
        ["-calyx.session.persistentSessionsEnabled", "YES"]
    }

    /// Bundle identifier set ONLY on the `DebugUITesting` config used by
    /// the `CalyxUITests` scheme's test action (see project.yml) —
    /// deliberately distinct from production's `com.calyx.terminal` so
    /// LaunchServices can never conflate a locally-installed production
    /// Calyx.app with the app-under-test. Used in `tearDown()` to
    /// confirm the app-under-test was still the actual frontmost app
    /// immediately before termination.
    private static let testAppBundleIdentifier = "com.calyx.terminal.e2e"

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

        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = Self.builtSessionBinaryPath()
        app.launch()
    }

    override func tearDown() {
        // `app` may still be nil if setUp() bailed out early (developer
        // mode disabled) before reaching `app = XCUIApplication()`.
        if let app, app.state == .runningForeground {
            XCTAssertEqual(
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                Self.testAppBundleIdentifier,
                "The app-under-test was no longer frontmost immediately before termination " +
                "— investigate before trusting that this run's keystrokes stayed isolated."
            )
        }
        app?.terminate()
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

    /// Relaunches `app` with the same HOME/session-dir/binary
    /// environment as `setUp()` — simulating the user quitting and
    /// reopening Calyx, not a fresh test environment.
    private func relaunchWithSameEnvironment() {
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-AppleLanguages", "(en)"] + additionalLaunchArguments
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = sessionDir
        app.launchEnvironment["HOME"] = homeDir
        app.launchEnvironment["CALYX_SESSION_BIN"] = Self.builtSessionBinaryPath()
        app.launch()
    }

    // MARK: - Daemon-ledger polling
    //
    // Verification is daemon-ledger-based, not keystroke-based: this
    // test never calls `app.typeText` or reads pane content, so
    // keystroke leakage into the developer's real terminal (see this
    // file's header comment) is structurally impossible.

    /// Raw stdout text from the most recent `daemonSessions()` call,
    /// kept only to fold into `XCTFail` messages below when a poll
    /// times out.
    private var lastLsOutput = ""

    /// Runs `calyx-session ls --all --json` out-of-process against
    /// this test's isolated `HOME`, returning the parsed session list.
    /// Each entry mirrors `SessionInfo`
    /// (`calyx-session/crates/proto/src/control.rs`): `"id"` (String),
    /// `"pid"` (Int, the daemon-side child PID), `"created_at_ms"`
    /// (Int), and `"state"`, which is either the bare string
    /// `"Running"` or the dictionary `{"Exited": {"code": Int}}` once
    /// the child has exited. Returns an empty array (rather than
    /// failing the test) if it produced no parseable JSON array of
    /// objects — the caller's polling loop is expected to fail the
    /// test with diagnostics once it gives up.
    private func daemonSessions() -> [[String: Any]] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.builtSessionBinaryPath())
        process.arguments = ["ls", "--all", "--json"]

        var environment = ["HOME": homeDir!]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            environment["PATH"] = path
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            XCTFail("Failed to launch `calyx-session ls --all --json`: \(error)")
            return []
        }
        process.waitUntilExit()

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        lastLsOutput = String(data: data, encoding: .utf8) ?? "<non-UTF8 output, \(data.count) bytes>"

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let sessions = jsonObject as? [[String: Any]] else {
            return []
        }
        return sessions
    }

    /// True if `session`'s `"state"` field is the bare string
    /// `"Running"` (as opposed to `{"Exited": {"code": n}}`, which
    /// decodes as a dictionary rather than a string — see
    /// `SessionState`'s serde derive).
    private func isRunning(_ session: [String: Any]) -> Bool {
        (session["state"] as? String) == "Running"
    }

    // MARK: - Restart replay

    /// Full round trip: confirm the persistent-session pane registered
    /// exactly one live session with the daemon; terminate the app;
    /// relaunch with the same HOME/session-dir; and confirm the SAME
    /// session id is still `Running` with the SAME pid and
    /// created_at_ms (see file header for why daemon-ledger identity,
    /// not pane content, is the verification method here).
    func test_persistentSession_survivesRestart_sameShellStaysAlive() {
        createNewTabViaMenu()
        waitFor(app.windows.firstMatch)

        // Creating the persistent-session tab makes the pane run
        // `calyx-session attach --create`, which registers a session
        // with the daemon asynchronously; poll rather than assume it's
        // immediate.
        var preRestartID: String?
        var preRestartPID: Int?
        var preRestartCreatedAtMs: Int?
        for _ in 1...10 {
            let sessions = daemonSessions()
            if sessions.count == 1, let session = sessions.first, isRunning(session),
               let id = session["id"] as? String,
               let pid = session["pid"] as? Int,
               let createdAtMs = session["created_at_ms"] as? Int {
                preRestartID = id
                preRestartPID = pid
                preRestartCreatedAtMs = createdAtMs
                break
            }
            Thread.sleep(forTimeInterval: 2)
        }

        guard let sessionID = preRestartID,
              let pid1 = preRestartPID,
              let createdAtMs1 = preRestartCreatedAtMs else {
            XCTFail(
                "No single \"Running\" session appeared in the daemon's ledger within ~20s " +
                "of creating the persistent-session tab, meaning the pane's " +
                "`calyx-session attach --create` never established a live daemon session. " +
                "Last `ls --all --json` output: \(lastLsOutput)"
            )
            return
        }

        app.terminate()
        relaunchWithSameEnvironment()
        waitFor(app.windows.firstMatch)

        // The restored pane's reattach to the daemon-held session
        // completes asynchronously after the window appears, with no
        // XCUITest-visible signal for "reattach done"; poll rather than
        // assume it's immediate.
        var postRestartSession: [String: Any]?
        for _ in 1...10 {
            if let session = daemonSessions().first(where: { ($0["id"] as? String) == sessionID }) {
                postRestartSession = session
                break
            }
            Thread.sleep(forTimeInterval: 2)
        }

        guard let session2 = postRestartSession else {
            XCTFail(
                "Session \(sessionID) was absent from the daemon's ledger within ~20s of " +
                "restarting the app, meaning the session was lost — the daemon did not " +
                "keep it alive across Calyx.app's termination. Last `ls --all --json` " +
                "output: \(lastLsOutput)"
            )
            return
        }

        XCTAssertTrue(
            isRunning(session2),
            "Session \(sessionID)'s state is no longer \"Running\" after restart " +
            "(state: \(String(describing: session2["state"]))), meaning the daemon-held " +
            "child process died instead of surviving Calyx.app's termination."
        )
        XCTAssertEqual(
            session2["pid"] as? Int, pid1,
            "Session \(sessionID)'s pid changed after restart (was \(pid1), now " +
            "\(String(describing: session2["pid"]))), meaning a new shell process replaced " +
            "the original instead of the daemon keeping the same child alive."
        )
        XCTAssertEqual(
            session2["created_at_ms"] as? Int, createdAtMs1,
            "Session \(sessionID)'s created_at_ms changed after restart (was \(createdAtMs1), " +
            "now \(String(describing: session2["created_at_ms"]))), meaning this is a freshly " +
            "created session rather than the same one reattached across restart."
        )
    }
}
