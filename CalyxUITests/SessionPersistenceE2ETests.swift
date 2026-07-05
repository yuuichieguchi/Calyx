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
        app.terminate()
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

        app.typeText("echo \(marker)\n")

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
