// SessionPersistenceE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the persistent-session pipeline: a shell
// command run in a persistent-session pane must survive an app
// restart (calyx-session's daemon keeps the child process running
// independent of Calyx.app's lifetime) and replay its output into the
// restored pane.
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

        do {
            guard try Self.isDeveloperModeEnabled() else {
                XCTFail("Developer mode is not enabled; run `sudo DevToolsSecurity -enable` first, " +
                         "then re-run this test. (Without it, XCUITest hangs waiting for an " +
                         "automation-permission dialog instead of failing visibly.)")
                return
            }
        } catch {
            XCTFail("Could not check developer-mode status via `DevToolsSecurity -status`: \(error)")
            return
        }

        homeDir = NSTemporaryDirectory() + "CalyxSessionE2E-Home-\(UUID().uuidString)"
        sessionDir = NSTemporaryDirectory() + "CalyxSessionE2E-Session-\(UUID().uuidString)"
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

    /// Checks `DevToolsSecurity -status` so a missing automation
    /// authorization fails this test immediately with a clear message
    /// instead of hanging on an unattended permission dialog. Verified
    /// output strings: "Developer mode is currently enabled." /
    /// "...disabled." — the disabled string never contains "enabled" as
    /// a substring, so this check is unambiguous either way.
    private static func isDeveloperModeEnabled() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/DevToolsSecurity")
        process.arguments = ["-status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("enabled")
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

    // MARK: - Restart replay

    /// Full round trip: type a unique marker into a persistent-session
    /// pane, terminate the app, relaunch with the same
    /// HOME/session-dir, and confirm the marker reappears (the daemon
    /// kept the shell alive and replayed its scrollback into the
    /// reattached pane).
    func test_persistentSession_survivesRestart_replaysOutput() {
        let marker = "CALYX_E2E_MARKER_\(UUID().uuidString)"

        createNewTabViaMenu()
        waitFor(app.windows.firstMatch)
        ensureAppIsFrontmost()

        typeTextSafely("echo \(marker)\n")

        let markerText = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(waitFor(markerText, timeout: 10), "The marker must appear in the pane after being echoed")

        app.terminate()
        relaunchWithSameEnvironment()

        let replayedMarkerText = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(waitFor(replayedMarkerText, timeout: 10),
                     "After restart, the restored pane must replay the same marker via calyx-session's " +
                     "reattach + Replay frame — proving the shell survived Calyx.app's termination")
    }
}
