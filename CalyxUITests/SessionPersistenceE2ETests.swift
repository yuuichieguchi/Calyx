// SessionPersistenceE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the persistent-session pipeline: a shell
// process running in a persistent-session pane must survive an app
// restart (calyx-session's daemon keeps the child process running
// independent of Calyx.app's lifetime), and the pane restored after
// relaunch must reattach to that SAME shell with working I/O, rather
// than a fresh replacement shell being spawned.
//
// Verification method: Ghostty renders terminal content on the GPU,
// so anything echoed into a pane is never exposed through the
// accessibility tree; `app.staticTexts` can never observe it, no
// matter how the persistent-session pipeline actually behaves.
// `BrowserScriptingUITests.terminalExec` already establishes the
// precedent for working around this: it redirects a command's output
// to a file and reads that file back from disk, instead of reading
// `app.staticTexts`. This test follows the same precedent: each phase
// has the shell write its own PID (`echo $$`) to a file under this
// test's session temp dir, and the file is read back from disk. The
// two PIDs matching before and after restart is the strongest proof
// available to XCUITest that calyx-session's daemon kept the exact
// same shell process alive across Calyx.app's termination, and that
// the restored pane reattached to it with working I/O.
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
    /// Calyx.app with the app-under-test. Used below to independently
    /// confirm the frontmost app is actually this test's own
    /// app-under-test before any keystroke is sent.
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

    // MARK: - Keystroke-leak guards
    //
    // Layer-2 defense (see incident writeup in this file's header
    // comment): even with bundle-ID isolation (project.yml's
    // `DebugUITesting` config), these guards independently re-verify
    // the app-under-test is actually frontmost immediately before any
    // keystroke is sent, and fail the test rather than type blindly.

    /// Activates `app` and fails the test immediately if it cannot be
    /// confirmed as the actual frontmost app. Call before any action
    /// that will send keyboard events.
    private func ensureAppIsFrontmost(file: StaticString = #filePath, line: UInt = #line) {
        app.activate()
        let isFrontmost = NSPredicate { _, _ in
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.testAppBundleIdentifier
        }
        let expectation = XCTNSPredicateExpectation(predicate: isFrontmost, object: nil)
        let result = XCTWaiter().wait(for: [expectation], timeout: 5)
        guard result == .completed, app.state == .runningForeground else {
            XCTFail(
                "Refusing to proceed: could not confirm the app-under-test as frontmost " +
                "(frontmost bundle ID: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"), " +
                "expected: \(Self.testAppBundleIdentifier), app.state: \(app.state)). " +
                "Aborting to avoid leaking keystrokes to another app.",
                file: file,
                line: line
            )
            return
        }
    }

    /// Sends `text` via `app.typeText` only after re-confirming,
    /// immediately beforehand, that `app` is both running in the
    /// foreground and the actual frontmost app system-wide. If either
    /// check fails, fails the test instead of typing.
    private func typeTextSafely(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard app.state == .runningForeground else {
            XCTFail(
                "Refusing to type: app-under-test is not running in the foreground " +
                "(state: \(app.state)). Aborting to avoid leaking keystrokes.",
                file: file,
                line: line
            )
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.testAppBundleIdentifier else {
            XCTFail(
                "Refusing to type: frontmost app is " +
                "\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"), " +
                "expected \(Self.testAppBundleIdentifier). Aborting to avoid leaking keystrokes.",
                file: file,
                line: line
            )
            return
        }
        app.typeText(text)
    }

    // MARK: - PID-file polling

    /// Polls `path` until its contents parse as a bare integer PID, or
    /// `timeout` elapses, returning the parsed PID or nil on timeout.
    /// The shell's `echo $$ > path` redirection is not synchronous with
    /// respect to XCUITest's `typeText`, so the file may not exist yet
    /// (or may still be mid-write) for a short while after the
    /// keystrokes are sent.
    private func waitForPID(atPath path: String, timeout: TimeInterval) -> Int? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int(trimmed) {
                    return pid
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }

    // MARK: - Restart replay

    /// Full round trip: confirm a persistent-session pane hosts a live,
    /// input-accepting shell by reading that shell's own PID back from
    /// a file; terminate the app; relaunch with the same
    /// HOME/session-dir; and confirm the restored pane's shell reports
    /// the SAME PID (see file header for why PID identity, not
    /// `app.staticTexts`, is the verification method here).
    func test_persistentSession_survivesRestart_sameShellStaysAlive() {
        let pidFile1 = "\(sessionDir!)/pid1.txt"
        let pidFile2 = "\(sessionDir!)/pid2.txt"

        createNewTabViaMenu()
        waitFor(app.windows.firstMatch)

        // The daemon-spawned shell's PTY isn't necessarily draining input
        // the instant the pane appears, the same asynchrony phase 2
        // already accounts for after restart. A single early keystroke
        // can land before the shell is ready and be lost, so retry the
        // echo up to 4 times over ~20s rather than relying on one attempt.
        var pid1: Int?
        for _ in 1...4 {
            ensureAppIsFrontmost()
            typeTextSafely("echo $$ > \(pidFile1)\n")
            if let pid = waitForPID(atPath: pidFile1, timeout: 5) {
                pid1 = pid
                break
            }
        }

        guard let confirmedPID1 = pid1 else {
            XCTFail(
                "The pane's shell never wrote its PID to \(pidFile1) after 4 attempts " +
                "over ~20s, meaning the persistent-session pane never became an " +
                "interactive shell that accepts input, so there is nothing to compare " +
                "after restart."
            )
            return
        }

        app.terminate()
        relaunchWithSameEnvironment()
        waitFor(app.windows.firstMatch)

        // The restored pane's reattach to the daemon-held shell completes
        // asynchronously after the window appears, with no XCUITest-visible
        // signal for "reattach done." Keystrokes sent immediately after
        // relaunch can land before the reattach completes and be dropped,
        // so retry the echo up to 3 times over ~15s rather than relying on
        // a single fixed sleep before the first attempt.
        var pid2: Int?
        for _ in 1...3 {
            ensureAppIsFrontmost()
            typeTextSafely("echo $$ > \(pidFile2)\n")
            if let pid = waitForPID(atPath: pidFile2, timeout: 5) {
                pid2 = pid
                break
            }
        }

        guard let confirmedPID2 = pid2 else {
            XCTFail(
                "The restored pane never wrote its PID to \(pidFile2) after 3 attempts " +
                "over ~15s, meaning the restored pane never reattached to a working, " +
                "input-accepting shell after restart."
            )
            return
        }

        XCTAssertEqual(
            confirmedPID2, confirmedPID1,
            "The restored pane's shell PID (\(confirmedPID2)) must equal the original " +
            "pane's shell PID (\(confirmedPID1)); this proves calyx-session's daemon kept the " +
            "SAME shell process alive across Calyx.app's termination and the restored " +
            "pane reattached to it with working I/O, rather than a fresh replacement " +
            "shell being spawned."
        )
    }
}
