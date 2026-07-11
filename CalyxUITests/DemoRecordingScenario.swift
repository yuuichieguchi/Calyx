// DemoRecordingScenario.swift
// CalyxUITests
//
// NOT a test -- a scripted DRIVER for a ~90-second product-demo screen
// recording. A human starts a screen recording, runs this scenario, and
// records real Claude Code agents running in Calyx panes (including a
// real approval-banner interaction) without having to operate the app
// by hand. Two-part never-abort-mid-recording contract: (1) every WAIT
// goes through `awaitOrContinue` (logs and proceeds instead of failing
// on a timeout); (2) `continueAfterFailure = true` (set in `setUp()`
// below) so an unguarded inherited interaction -- `menuAction`'s and
// `enableAIAgentIPCViaCommandPalette`'s own `.click()` calls, which do
// NOT route through `awaitOrContinue` -- records a failure on a missing
// element instead of throwing and aborting the take mid-recording.
// Contains NO XCTAssert anywhere for the same reason: the human retakes
// if something visibly went wrong, this driver never does.
//
// Skipped by default (see the CALYX_DEMO_RECORDING guard, first line of
// the test method) so it never runs as part of a normal CalyxUITests
// pass -- only `scripts/record-demo.sh` sets that env var (propagated to
// the test runner process via project.yml's own
// `schemes.CalyxUITests.test.environmentVariables` entry, the same
// propagation `CALYX_SESSION_BIN` already needs there: a plain shell
// prefix on `xcodebuild test` does not otherwise reach the runner).
//
// LAUNCH CONFIGURATION, and why this does NOT use CalyxUITestCase's own
// `setUp()`: that base implementation launches the app immediately,
// before this scenario gets a chance to add its own extra launch
// argument (`--demo-window-frame=1440x900`). This scenario instead
// builds and launches its own `XCUIApplication` inline in the test
// method, after the CALYX_DEMO_RECORDING skip guard, so `setUp()`/
// `tearDown()` below are both overridden to skip the base class's own
// launch/cleanup entirely (see each override's own comment).
//
// `CockpitSettings.agentHookApprovalEnabled` (the approval-banner
// centerpiece of BEATs 2-3) is forced on via an NSArgumentDomain launch
// argument (`-calyx.cockpit.agentHookApprovalEnabled YES`) rather than a
// runner-side `UserDefaults(suiteName:).set(...)` write: the
// CalyxUITests runner is itself App-Sandboxed (see
// SessionPersistenceE2ETests.swift's own header), so a write from THIS
// process to a suite by name would land in the RUNNER's own sandbox
// container plist -- invisible to the non-sandboxed app-under-test,
// which reads `~/Library/Preferences/<suite>.plist` directly.
// NSArgumentDomain sits atop the search list of EVERY UserDefaults
// instance, suite-backed ones included (SettingsTogglesE2ETests.swift's
// own header documents this exact shadowing behavior), which is why it
// works here where a suite pre-seed cannot -- safe because this
// scenario never itself toggles the setting, so shadowing writes to it
// is a no-op in practice. The defaults suite name is therefore just a
// per-run UUID (CalyxUITestCase.setUp()'s own convention), cleaned up in
// `tearDown()` below.
//
// PANE LAYOUT AND FOCUS MECHANISM: the 2x2 split is built via File >
// Split Right then File > Split Down on each column (see the PRE-ROLL
// section below for the exact click order and the resulting quadrant
// layout). Panes are focused throughout via `clickQuadrant(_:)` --
// position-based coordinate taps on the four window quadrants -- rather
// than Window > Focus Split Up/Down/Left/Right: those menu items only
// move focus to an immediate SPATIAL neighbor of whichever pane
// currently has focus, so jumping between arbitrary, non-adjacent panes
// (e.g. pane 3 straight to pane 1, as BEAT 5 does) would need a chain of
// direction-dependent moves whose correctness depends on which pane was
// last focused -- fragile for a scripted, no-assertion driver. A
// quadrant coordinate click is robust to all of that: it always lands on
// whichever pane currently occupies that screen position, independent of
// focus history.
//
// STORYBOARD (~90s):
//   PRE-ROLL  -- enable AI Agent IPC, build the 2x2 split, start
//                `claude` in panes 1-3 (plus a trust-dialog Return),
//                `cd`+`clear` in pane 4, print the "start recording"
//                marker, hold 15s.
//   BEAT 1    -- send one prompt to each of panes 1-3.
//   BEAT 2    -- first approval banner: wait, hold, click Allow.
//   BEAT 3    -- second approval banner: wait, hold, click the
//                cross-actions menu's "Allow All Pending" item.
//   BEAT 4    -- open Agent Mode in the sidebar, click the first agent
//                row.
//   BEAT 5    -- run the test script in pane 4, ask pane 1 to summarize
//                it, hold for the agent to respond.
//   BEAT 6    -- final calm hold, then terminate.

import XCTest

final class DemoRecordingScenario: CalyxUITestCase {

    /// This scenario's own isolated session temp dir, cleaned up by this
    /// file's own `tearDown()` (see that override's comment for why the
    /// base class's cleanup never runs here).
    private var sessionDir: String?

    /// Per-run UUID defaults suite (CalyxUITestCase.setUp()'s own
    /// convention), cleaned up by `tearDown()` below. NOT how
    /// `agentHookApprovalEnabled` gets forced on -- see this file's
    /// header for why a suite pre-seed from the (sandboxed) test runner
    /// can never reach the app-under-test, and the NSArgumentDomain
    /// launch argument used instead. This suite still exists so any
    /// OTHER setting the app-under-test happens to write during a run
    /// lands somewhere throwaway rather than a shared/fixed domain.
    private var defaultsSuiteName: String?

    override func setUp() {
        // Deliberately does NOT call super.setUp() -- see this file's
        // header for why CalyxUITestCase's own launch flow conflicts
        // with what this scenario needs. All launch configuration
        // happens inline in the test method below, after the
        // CALYX_DEMO_RECORDING skip guard.
        //
        // continueAfterFailure = true (NOT the usual E2E-suite `false`):
        // half of this file's own never-abort-mid-recording contract
        // (see header) -- an inherited helper's unguarded `.click()` on
        // a missing element must record a failure and carry on, not
        // throw and abort the take.
        continueAfterFailure = true
    }

    override func tearDown() {
        // Self-contained, and deliberately does NOT call
        // super.tearDown(): CalyxUITestCase.tearDown() force-unwraps
        // `app` (implicitly-unwrapped `XCUIApplication!`) -- safe there
        // only because its own setUp() always assigns it first. This
        // scenario's setUp() never calls that base setUp(), so if the
        // CALYX_DEMO_RECORDING guard skips before `app` is ever assigned,
        // that force-unwrap would crash. Terminate/clean up only this
        // scenario's own state, guarding against a never-assigned `app`.
        if let app {
            app.terminate()
        }
        if let sessionDir {
            try? FileManager.default.removeItem(atPath: sessionDir)
        }
        if let defaultsSuiteName {
            // Same best-effort cfprefsd-flush caveat as
            // CalyxUITestCase.tearDown()'s own identical cleanup.
            Thread.sleep(forTimeInterval: 1.0)
            UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
            let suitePlistPath = "\(NSHomeDirectory())/Library/Preferences/\(defaultsSuiteName).plist"
            try? FileManager.default.removeItem(atPath: suitePlistPath)
        }
    }

    func test_demoRecordingScenario() throws {
        guard ProcessInfo.processInfo.environment["CALYX_DEMO_RECORDING"] == "1" else {
            throw XCTSkip("Set CALYX_DEMO_RECORDING=1 to run the demo recording scenario")
        }

        // MARK: - Launch configuration

        // Per-run UUID suite name (CalyxUITestCase.setUp()'s own
        // convention) -- see this file's header for why
        // agentHookApprovalEnabled is forced on via the NSArgumentDomain
        // launch argument below instead of a pre-seeded suite.
        let suiteName = "com.calyx.tests.e2e.DemoRecordingScenario-\(UUID().uuidString)"
        defaultsSuiteName = suiteName

        let tempDir = NSTemporaryDirectory() + "CalyxDemoRecording-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        sessionDir = tempDir

        app = XCUIApplication()
        app.launchArguments = [
            "--uitesting", "-AppleLanguages", "(en)", "--demo-window-frame=1440x900",
            // NSArgumentDomain override -- raw key verbatim from
            // CockpitSettings.agentHookApprovalEnabledKey
            // (Calyx/Features/ApprovalInbox/CockpitSettings.swift; this
            // target has no @testable import Calyx linkage). See this
            // file's header for why this must be an NSArgumentDomain
            // argument, not a suite pre-seed from the test runner.
            "-calyx.cockpit.agentHookApprovalEnabled", "YES"
        ]
        app.launchEnvironment["CALYX_UITEST_SESSION_DIR"] = tempDir
        app.launchEnvironment["CALYX_UITEST_DEFAULTS_SUITE"] = suiteName
        app.launch()

        // MARK: - PRE-ROLL

        awaitOrContinue(app.windows.firstMatch, timeout: 10)
        awaitOrContinue(app.menuBars.firstMatch, timeout: 10)

        enableAIAgentIPCViaCommandPalette()

        // 2x2 split: File > Split Right (creates the right column, B,
        // which becomes focused -- ghostty's own
        // handleNewSplitNotification makes the just-created surface
        // first responder, same behavior MenuShortcutsUITests'
        // test_focusSplitDirections_moveFocusBetweenSurfaces documents),
        // then File > Split Down while B is focused (creates D below
        // B), then clickQuadrant(1) back to A and File > Split Down
        // again (creates C below A). Resulting layout, fixed for the
        // rest of this method regardless of split-creation order:
        //   quadrant 1 (top-left)     = pane A (original)
        //   quadrant 2 (top-right)    = pane B
        //   quadrant 3 (bottom-left)  = pane C
        //   quadrant 4 (bottom-right) = pane D
        let dividersBeforeRight = app.windows.firstMatch.descendants(matching: .splitter).count
        menuAction("File", item: "Split Right")
        let dividersAfterRight = waitForSplitterCount(timeout: 10) { $0 > dividersBeforeRight }

        menuAction("File", item: "Split Down")
        let dividersAfterFirstDown = waitForSplitterCount(timeout: 10) { $0 > dividersAfterRight }

        clickQuadrant(1)
        menuAction("File", item: "Split Down")
        _ = waitForSplitterCount(timeout: 10) { $0 > dividersAfterFirstDown }

        clickQuadrant(1)
        panePasteAndReturn("cd /tmp/calyx-demo-workspace && claude")
        clickQuadrant(2)
        panePasteAndReturn("cd /tmp/calyx-demo-workspace && claude")
        clickQuadrant(3)
        panePasteAndReturn("cd /tmp/calyx-demo-workspace && claude")
        // Single combined wait for all three Claude Code startups rather
        // than one per pane -- they were kicked off back-to-back above
        // and start up concurrently.
        Thread.sleep(forTimeInterval: 12)

        // Claude Code shows a blocking "Do you trust the files in this
        // folder?" dialog on the FIRST run of a given absolute path on a
        // given machine (the trust decision is stored in ~/.claude.json
        // keyed by path, so it can still resurface on a fresh machine or
        // a cleared ~/.claude.json even though this fixture directory
        // itself is recreated on every run). A bare Return accepts that
        // dialog's default "Yes, proceed" choice, and is a no-op at an
        // already-idle Claude Code input prompt otherwise -- safe to
        // send unconditionally to all three panes either way.
        for quadrant in 1...3 {
            clickQuadrant(quadrant)
            app.typeKey(.return, modifierFlags: [])
        }

        // Pane 4 stays in the workspace directory (needed for BEAT 5's
        // own `./scripts/test.sh`) but never starts an agent.
        clickQuadrant(4)
        panePasteAndReturn("cd /tmp/calyx-demo-workspace && clear")

        print("DEMO: PRE-ROLL COMPLETE — START RECORDING")
        Thread.sleep(forTimeInterval: 15)

        // MARK: - BEAT 1: one prompt per pane (1-3)

        clickQuadrant(1)
        panePasteAndReturn("Run ./scripts/test.sh and fix any failure")
        clickQuadrant(2)
        panePasteAndReturn("Summarize the git log of this repo")
        clickQuadrant(3)
        panePasteAndReturn("List TODO comments in src/")

        // MARK: - BEAT 2: first approval banner -> Allow

        let banner = app.descendants(matching: .any)
            .matching(identifier: "calyx.approvalBanner.container")
            .firstMatch
        awaitOrContinue(banner, timeout: 60)
        Thread.sleep(forTimeInterval: 2)

        let allowButton = app.buttons["calyx.approvalBanner.allowButton"]
        if awaitOrContinue(allowButton, timeout: 10) {
            allowButton.click()
        }

        // MARK: - BEAT 3: second approval banner -> cross-actions menu -> Allow All Pending

        awaitOrContinue(banner, timeout: 60)
        Thread.sleep(forTimeInterval: 1.5)
        clickAllowAllPending()

        // MARK: - BEAT 4: Agent Mode sidebar

        let sidebarContainer = app.descendants(matching: .any)
            .matching(identifier: "calyx.sidebar")
            .firstMatch
        if !sidebarContainer.exists {
            toggleSidebarViaMenu()
            awaitOrContinue(sidebarContainer, timeout: 10)
        }

        let agentModeButton = app.descendants(matching: .any)
            .matching(identifier: "calyx.sidebar.agentModeButton")
            .firstMatch
        if awaitOrContinue(agentModeButton, timeout: 10) {
            agentModeButton.click()
        }
        Thread.sleep(forTimeInterval: 2)

        let firstAgentRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.agentRow."))
            .firstMatch
        if awaitOrContinue(firstAgentRow, timeout: 10) {
            firstAgentRow.click()
        }
        Thread.sleep(forTimeInterval: 2)

        // MARK: - BEAT 5: run the test script, ask pane 1 to summarize it

        clickQuadrant(4)
        panePasteAndReturn("./scripts/test.sh")
        clickQuadrant(1)
        panePasteAndReturn("Wait for the test run in the other pane and summarize the result")
        Thread.sleep(forTimeInterval: 20)

        // MARK: - BEAT 6: calm final hold

        // Settings is deliberately NOT opened here -- keeping the closing
        // beat simple and calm reads better on camera than one more UI
        // hop. Just hold -- tearDown() (below) terminates the app; no
        // second app.terminate() call here to avoid the two sites
        // drifting apart.
        Thread.sleep(forTimeInterval: 11)
    }

    // MARK: - Helpers

    /// `waitForExistence` that logs and returns `false` on timeout
    /// instead of failing the test -- this scenario is a recording
    /// driver, not a test: a slow machine or a missed anchor must never
    /// abort a recording in progress. The human operator retakes if
    /// something visibly went wrong.
    @discardableResult
    private func awaitOrContinue(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let found = waitFor(element, timeout: timeout)
        if !found {
            print("DEMO: wait timed out after \(timeout)s for \(element.debugDescription) -- continuing anyway")
        }
        return found
    }

    /// Position-based pane focus -- see this file's header for why a
    /// coordinate click on one of the four window quadrants is used
    /// instead of Window > Focus Split Up/Down/Left/Right. `index` is
    /// 1-based: 1 = top-left, 2 = top-right, 3 = bottom-left,
    /// 4 = bottom-right, matching the fixed pane layout documented in
    /// the PRE-ROLL section.
    private func clickQuadrant(_ index: Int) {
        let normalizedOffsets: [(dx: CGFloat, dy: CGFloat)] = [
            (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)
        ]
        guard (1...4).contains(index) else { return }
        let offset = normalizedOffsets[index - 1]
        let coordinate = app.windows.firstMatch.coordinate(
            withNormalizedOffset: CGVector(dx: offset.dx, dy: offset.dy)
        )
        coordinate.click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Polls the first window's own `.splitter` descendant count until
    /// `predicate` is satisfied or `timeout` elapses -- near-duplicate of
    /// MenuShortcutsUITests.waitForSplitterCount (that one is `private`
    /// to its own file, so not reusable from here; kept as a
    /// near-duplicate rather than promoted onto CalyxUITestCase itself,
    /// matching this directory's own established convention for small
    /// per-file helpers, see e.g. PaneCLIExec.swift's header).
    @discardableResult
    private func waitForSplitterCount(timeout: TimeInterval, where predicate: (Int) -> Bool) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var observed = app.windows.firstMatch.descendants(matching: .splitter).count
        while !predicate(observed), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            observed = app.windows.firstMatch.descendants(matching: .splitter).count
        }
        return observed
    }

    /// Opens the Command Palette, runs "Enable AI Agent IPC", and
    /// dismisses the resulting NSAlert.runModal() confirmation --
    /// near-duplicate of CockpitApprovalE2ETests'/CommandLogE2ETests' own
    /// helper of the same name (both already document this as a kept
    /// near-duplicate rather than a shared call), adapted here to
    /// `awaitOrContinue` instead of XCTAssert since this file asserts
    /// nothing.
    private func enableAIAgentIPCViaCommandPalette() {
        openCommandPaletteViaMenu()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        guard awaitOrContinue(searchField, timeout: 10) else { return }

        searchField.typeText("Enable AI Agent IPC")
        searchField.typeKey(.enter, modifierFlags: [])

        let alert = app.dialogs.firstMatch
        if awaitOrContinue(alert, timeout: 10) {
            alert.buttons["OK"].click()
        }
    }

    /// BEAT 3: clicks the approval banner's cross-actions menu, then its
    /// "Allow All Pending" item -- looked up PRIMARILY by a
    /// "Allow All Pending" title-prefix match (the item's visible label
    /// includes a live pending count, e.g. "Allow All Pending (3)", so
    /// an exact-title match would never be stable), falling back to the
    /// accessibility-identifier lookup only if that fails. This order is
    /// deliberate: whether this particular SwiftUI Menu's item
    /// identifiers even propagate to the underlying NSMenuItem is
    /// unproven anywhere in this suite, so trying the ID FIRST would
    /// risk burning a full on-camera stall on an unproven lookup before
    /// ever trying the title match that's known to work. The ID fallback
    /// keeps a short 2s timeout for the same reason: if the title lookup
    /// already found nothing, this menu is genuinely unusual, and a long
    /// wait on the fallback wouldn't help.
    private func clickAllowAllPending() {
        let crossActionsMenu = app.descendants(matching: .any)
            .matching(identifier: "calyx.approvalBanner.crossActionsMenu")
            .firstMatch
        guard awaitOrContinue(crossActionsMenu, timeout: 10) else { return }
        crossActionsMenu.click()

        let itemByTitle = app.menuItems
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Allow All Pending"))
            .firstMatch
        if awaitOrContinue(itemByTitle, timeout: 10) {
            itemByTitle.click()
            return
        }

        let itemByID = app.menuItems["calyx.approvalBanner.allowAllPendingItem"]
        if awaitOrContinue(itemByID, timeout: 2) {
            itemByID.click()
        }
    }
}
