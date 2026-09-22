// CockpitApprovalE2ETests.swift
// CalyxUITests
//
// End-to-end coverage for the Cockpit MCP tool surface: pane_list /
// pane_split / tab_create (P4, ungated) and pane_run (P5, gated by a
// REAL, clickable approval banner) driven through the real running
// app-under-test's real MCP server, exactly the path an MCP-connected
// coding agent uses. P1-P5 are already committed (Green) -- this suite
// is integration coverage for already-implemented behavior, not a RED
// stub: it is expected to PASS when correctly written.
//
// ISOLATION: launched with `--calyx-path-root=<scoped temp dir>` plus
// `-calyx.ipc.enabled YES` -- identical mechanism to
// CommandLogE2ETests.swift's own header, restated here since this
// suite depends on the exact same scoped path. `CalyxPathRoot.testRoot`
// scopes every Calyx-owned and agent-owned config path beneath the temp
// dir, and `AppDelegate.resyncAgentHooksIfInstalled` runs real
// launch-time activation against it. This suite's pane-side scripts
// read `CALYX_ENDPOINT_FILE` (injected by `GhosttySurfaceController`
// into every pane's own environment, scoped to wherever this launch
// actually wrote `agent-endpoint.json`) ahead of the literal, unscoped
// `~/Library/Application Support/Calyx/agent-endpoint.json` fallback --
// see `AgentEndpointFile.swift`/`GhosttySurface.swift`'s own doc
// comments for why a pane's shell (started via `login -flp
// <system-username> ...`, which resets `$HOME` to the real system user
// regardless of `CalyxPathRoot.testRoot`) could not otherwise resolve
// the scoped path at all. `CALYX_UITEST_SESSION_DIR` /
// `CALYX_UITEST_DEFAULTS_SUITE` (the base class's own isolation) still
// cover window/tab-session state and every UserDefaults-backed
// setting -- including CockpitSettings.autoApproveEnabled, which is why
// this suite can rely on a truly fresh "auto-approve OFF" default per
// run (see CockpitSettings.swift / SettingsStore.swift: `_testStore` is
// nil in this out-of-process app-under-test, so resolution falls to
// `uiTestSuite`, keyed by `CALYX_UITEST_DEFAULTS_SUITE`, never
// `.standard`).
//
// ENVIRONMENTAL PRECONDITION, now satisfied by `setUp()` rather than
// left to the host machine (identical mechanism to
// CommandLogE2ETests.swift's own header): `IPCConfigManager.enableIPC`'s
// `anySucceeded` gate requires at least one of `~/.claude`, `~/.codex`,
// `~/.config/opencode` (resolved beneath the scoped root here) to
// exist -- `setUp()` creates `<scopedPathRoot>/.claude` before
// `app.launch()` so this suite's activation always succeeds regardless
// of what CLIs happen to be installed on the machine running it.
//
// QUERY MECHANISM (PaneCLIExec pattern, mirrors CommandLogE2ETests.swift's
// own header on why: the CalyxUITests runner is itself App-Sandboxed and
// cannot open a new outbound connection, so all `/mcp` traffic must go
// through a real, unsandboxed pane process). Two call shapes are needed
// here, unlike CommandLogE2ETests' single one:
//
// - UNGATED tools (pane_list/pane_split/tab_create) return immediately,
//   so `toolCallSync` reuses CommandLogE2ETests' exact shape: write a
//   base64-encoded python3 script to /tmp via `paneExec`, wait for its
//   one-line JSON stdout.
// - The GATED tool (pane_run) BLOCKS the pane-side curl call until a
//   human answers the approval banner (or the bridge's own ~55s
//   internal timeout fires) -- `paneExec`'s own wait-for-output-file
//   loop cannot be used to ISSUE it (this test needs control back
//   immediately, to go click the banner). `toolCallBackgrounded`
//   instead pastes a command that backgrounds the same python3 script
//   inside a detached subshell (`(... &); disown` idiom, see
//   `toolCallBackgrounded`'s own doc comment) via `panePasteAndReturn`
//   (fire-and-forget, does not wait), and this test separately polls
//   the script's own /tmp output file with `waitForFileContent` (a
//   near-duplicate of `paneExec`'s own tail-polling loop, kept local
//   rather than promoted into `PaneCLIExec` -- same "kept as a
//   near-duplicate" rationale that file's own header already states
//   for its relationship to `BrowserScriptingUITests.terminalExec`)
//   IN BETWEEN clicking the banner's button and asserting the result,
//   so the XCUITest driver is free to interact with the banner while
//   the pane-side curl is still blocked waiting on it.
//

import XCTest
import AppKit

final class CockpitApprovalE2ETests: CalyxUITestCase {

    // MARK: - Accessibility identifiers

    /// Literal mirrors of `AccessibilityID.ApprovalBanner.*`
    /// (Calyx/Helpers/AccessibilityID.swift) -- the `CalyxUITests`
    /// target drives the app-under-test as a separate OS process via
    /// `XCUIApplication`, with no `@testable import Calyx` linkage, so
    /// that enum isn't visible here. Every other E2E suite in this
    /// directory (e.g. `SettingsSessionsToggleE2ETests`'s own
    /// `persistentSessionsSwitchIdentifier`) already hardcodes the
    /// same identifiers as string literals for the same reason; named
    /// here (rather than inlined at each call site) purely because this
    /// suite references them from more than one place.
    private static let approvalBannerAllowButtonID = "calyx.approvalBanner.allowButton"
    private static let approvalBannerPayloadID = "calyx.approvalBanner.payload"
    private static let approvalBannerPayloadExpandedID = "calyx.approvalBanner.payloadExpanded"
    private static let approvalBannerNextButtonID = "calyx.approvalBanner.nextButton"
    private static let approvalBannerPreviousButtonID = "calyx.approvalBanner.previousButton"
    private static let approvalBannerQueueMenuID = "calyx.approvalBanner.queueMenu"
    private static let approvalBannerContainerID = "calyx.approvalBanner.container"
    private static let approvalBannerOptionsMenuID = "calyx.approvalBanner.optionsMenu"
    private static let approvalBannerDismissButtonID = "calyx.approvalBanner.dismissButton"
    private static let approvalBannerTooltipID = "calyx.approvalBanner.tooltip"

    // MARK: - Scoped launch

    /// `--calyx-path-root=<this>` (see this file's header): a fresh
    /// per-test temp directory, created lazily on first access so it
    /// exists before `additionalLaunchArguments` is read by
    /// `CalyxUITestCase.setUp()`, ahead of `app.launch()`.
    private lazy var scopedPathRoot: String = {
        let root = NSTemporaryDirectory() + "CalyxUITests-pathroot-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        // Satisfies IPCConfigManager.enableIPC's anySucceeded gate (see
        // this file's header) without depending on what CLIs happen to
        // be installed on the machine running this suite.
        try? FileManager.default.createDirectory(atPath: root + "/.claude", withIntermediateDirectories: true)
        return root
    }()

    override var additionalLaunchArguments: [String] {
        ["--calyx-path-root=\(scopedPathRoot)", "-calyx.ipc.enabled", "YES"]
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(atPath: scopedPathRoot)
    }

    /// Polls for the scoped `agent-endpoint.json` (written by
    /// `AgentEndpointFile.write` once launch-time activation's real
    /// `CalyxMCPServer.start()` succeeds), mirroring
    /// `CommandLogE2ETests.waitForIPCActivation` exactly (kept as a
    /// near-duplicate, matching this suite's own established convention
    /// for small per-file helpers -- see this file's header).
    private func waitForIPCActivation(timeout: TimeInterval = 20) {
        let endpointPath = scopedPathRoot + "/Calyx/agent-endpoint.json"
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: endpointPath), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointPath),
                     "launch-time AI Agent IPC activation never wrote agent-endpoint.json under the scoped root")
    }

    // MARK: - Test

    func test_cockpitTools_endToEnd() throws {
        var counter = 0

        waitForIPCActivation()

        // MARK: 1. Resolve this pane's own surface_id

        let surfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertNotEqual(surfaceID, "(no output)", "could not read $CALYX_SURFACE_ID from the pane")
        XCTAssertFalse(surfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for every ghostty-spawned pane")

        // MARK: 2. pane_list -- this window's own pane is present, with a cwd, snake_case keys

        let firstList = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)
        let firstPanes = try XCTUnwrap(firstList["panes"] as? [[String: Any]], "pane_list must return a panes array")
        let ownPaneBeforeSplit = try XCTUnwrap(
            firstPanes.first { ($0["surface_id"] as? String) == surfaceID },
            "pane_list must include this window's own pane (surface_id \(surfaceID)) -- got: \(firstPanes)"
        )
        for key in ["surface_id", "window_id", "group_name", "tab_id", "tab_title", "is_focused"] {
            XCTAssertNotNil(ownPaneBeforeSplit[key], "pane_list entry must carry the snake_case key \"\(key)\"")
        }
        XCTAssertNotNil(ownPaneBeforeSplit["cwd"] as? String,
                        "the sole pane in a single-pane tab must report a cwd (falls back to the tab's own pwd)")
        let paneCountBeforeSplit = firstPanes.count

        // MARK: 3. pane_run, unregistered pane -> requires approval (auto-approve defaults OFF) -> Allow -> executes

        let allowOutFile = "/tmp/calyx-e2e-cockpit-run-allow-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo COCKPIT_MARKER_ALLOW\", \"await\": false}",
            outFile: allowOutFile, counter: &counter
        )

        let allowButton = app.buttons[Self.approvalBannerAllowButtonID]
        XCTAssertTrue(waitFor(allowButton, timeout: 15), "the approval banner's Allow button never appeared")

        let payloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(payloadText, timeout: 5), "the approval banner's payload text never appeared")
        XCTAssertTrue(elementText(payloadText).contains("COCKPIT_MARKER_ALLOW"),
                     "the banner must display the exact pending command -- got: \(elementText(payloadText))")

        allowButton.click()

        let allowResultText = waitForFileContent(atPath: allowOutFile)
        XCTAssertNotEqual(allowResultText, "(no output)", "the backgrounded pane_run (Allow) curl produced no output")
        let allowResult = try parseJSONObject(allowResultText, context: "pane_run Allow result")
        XCTAssertEqual(allowResult["status"] as? String, "sent",
                       "Allow must execute the command and report status \"sent\" -- got: \(allowResultText)")

        // Round-trips through the REAL shell integration -- proves the
        // command actually ran in the pane, not just that the bridge
        // claimed success.
        let allowMarkerRecord = try waitForTrackedCommand(
            containing: "COCKPIT_MARKER_ALLOW", surfaceID: surfaceID, counter: &counter
        )
        XCTAssertEqual(allowMarkerRecord["state"] as? String, "finished",
                       "the allowed marker command must finish and be tracked by the real shell integration")

        // MARK: 4. pane_run, second request -> Deny -> never executes

        let denyOutFile = "/tmp/calyx-e2e-cockpit-run-deny-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo COCKPIT_MARKER_DENY\", \"await\": false}",
            outFile: denyOutFile, counter: &counter
        )

        let container = app.descendants(matching: .any).matching(identifier: Self.approvalBannerContainerID).firstMatch
        XCTAssertTrue(waitFor(container, timeout: 15), "the approval banner never appeared for the second request")

        let denyPayloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(denyPayloadText, timeout: 5))
        XCTAssertTrue(elementText(denyPayloadText).contains("COCKPIT_MARKER_DENY"),
                     "the banner must now display the SECOND pending command -- got: \(elementText(denyPayloadText))")

        denyViaOptionsMenu()

        let denyResultText = waitForFileContent(atPath: denyOutFile)
        XCTAssertNotEqual(denyResultText, "(no output)", "the backgrounded pane_run (Deny) curl produced no output")
        let denyResult = try parseJSONObject(denyResultText, context: "pane_run Deny result")
        XCTAssertEqual(denyResult["status"] as? String, "denied",
                       "Deny must never execute -- must report status \"denied\" -- got: \(denyResultText)")

        // Bounded absence check: the denied marker must NEVER show up as
        // a tracked command (polls a short, fixed window rather than
        // waiting out a full timeout budget for something that must NOT
        // appear).
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 1)
            let list = toolCallSync(name: "terminal_list_commands", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\"}", counter: &counter)
            let commands = (list["commands"] as? [[String: Any]]) ?? []
            let found = commands.contains { ($0["command"] as? String)?.contains("COCKPIT_MARKER_DENY") == true }
            XCTAssertFalse(found, "a denied pane_run must never reach the real shell -- COCKPIT_MARKER_DENY must never be tracked")
        }

        // MARK: 4b. queue navigation -- two requests queued (the queue is
        // empty at this point, MARK 4's Deny having drained it), banner
        // shows a position label + Next/Previous chevrons, a Next/
        // Previous/Next round-trip exercises BOTH chevrons end-to-end
        // (Previous was otherwise only unit-covered), the position
        // label's own queue preview menu jumps straight to the
        // non-displayed request, and Allow resolves the NAVIGATED-TO
        // (displayed) request out of order.

        let navAOutFile = "/tmp/calyx-e2e-cockpit-run-nav-a-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo COCKPIT_MARKER_NAV_A\", \"await\": false}",
            outFile: navAOutFile, counter: &counter
        )

        let navPayloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(navPayloadText, timeout: 15), "the approval banner never appeared for the first queued (NAV_A) request")
        XCTAssertTrue(elementText(navPayloadText).contains("NAV_A"),
                     "the banner must display the first queued command -- got: \(elementText(navPayloadText))")

        let navBOutFile = "/tmp/calyx-e2e-cockpit-run-nav-b-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo COCKPIT_MARKER_NAV_B\", \"await\": false}",
            outFile: navBOutFile, counter: &counter
        )

        // The "N / M" position text is read off the queue preview menu
        // element itself, not the Text inside its label closure: macOS
        // collapses a SwiftUI Menu into a single element that carries
        // only the Menu's own identifier and accessibility label (see
        // ApprovalBannerView.queueNavigator(positionInfo:), which sets
        // that label explicitly for this reason). Queried
        // type-agnostically, since which element type SwiftUI collapses
        // that Menu into is its own choice, not this suite's.
        let positionLabel = app.descendants(matching: .any)
            .matching(identifier: Self.approvalBannerQueueMenuID)
            .firstMatch
        XCTAssertTrue(waitFor(positionLabel, timeout: 15), "the position label never appeared once a second request queued behind NAV_A")
        XCTAssertTrue(elementText(positionLabel).contains("1 / 2"),
                     "with two requests queued, the still-displayed first request must read \"1 / 2\" -- got: \(elementText(positionLabel))")

        app.buttons[Self.approvalBannerNextButtonID].click()

        // Bounded poll, same 5x1s pattern as MARK 4's denied-marker
        // absence check above: clicking Next must advance the banner to
        // the second (NAV_B) queued request.
        var advancedToNavB = false
        for _ in 0..<5 {
            if elementText(navPayloadText).contains("NAV_B") && elementText(positionLabel).contains("2 / 2") {
                advancedToNavB = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(advancedToNavB, "clicking Next must advance the banner to the second (NAV_B) queued request, reading \"2 / 2\"")

        app.buttons[Self.approvalBannerPreviousButtonID].click()

        // Bounded poll, same 5x1s pattern: clicking Previous must step
        // the banner back to the first (NAV_A) queued request.
        var steppedBackToNavA = false
        for _ in 0..<5 {
            if elementText(navPayloadText).contains("NAV_A") && elementText(positionLabel).contains("1 / 2") {
                steppedBackToNavA = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(steppedBackToNavA, "clicking Previous must step the banner back to the first (NAV_A) queued request, reading \"1 / 2\"")

        app.buttons[Self.approvalBannerNextButtonID].click()

        // Bounded poll, same 5x1s pattern: clicking Next again must
        // return the banner to the second (NAV_B) queued request,
        // completing the round-trip.
        var returnedToNavB = false
        for _ in 0..<5 {
            if elementText(navPayloadText).contains("NAV_B") && elementText(positionLabel).contains("2 / 2") {
                returnedToNavB = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(returnedToNavB, "clicking Next again must return the banner to the second (NAV_B) queued request, reading \"2 / 2\"")

        // Queue preview menu: clicking the position label opens it (the
        // label IS that Menu's own collapsed element, see the lookup
        // above), and picking another request's row jumps straight to
        // that request -- the ApprovalBannerModel.select(id:) path,
        // which the chevrons never exercise. A row's text reaches the
        // accessibility tree as its NSMenuItem `title`, never `label`
        // (field-verified), and reads "N. <tool>: <command>" (see
        // ApprovalBannerView.queueEntryLabel(_:)), so the NAV_A row is
        // matched on its command text rather than a whole title, which
        // carries a live position prefix.
        positionLabel.click()

        let navARow = app.menuItems
            .matching(NSPredicate(format: "title CONTAINS %@", "COCKPIT_MARKER_NAV_A"))
            .firstMatch
        XCTAssertTrue(waitFor(navARow, timeout: 10), "the queue preview menu never listed a row for the still-queued NAV_A request")
        navARow.click()

        // Bounded poll, same 5x1s pattern: picking the NAV_A row must
        // jump the banner to that request, position label included.
        var jumpedToNavA = false
        for _ in 0..<5 {
            if elementText(navPayloadText).contains("NAV_A") && elementText(positionLabel).contains("1 / 2") {
                jumpedToNavA = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(jumpedToNavA, "clicking the queue preview menu's NAV_A row must jump the banner to that request, reading \"1 / 2\"")

        app.buttons[Self.approvalBannerNextButtonID].click()

        // Bounded poll, same 5x1s pattern: back on NAV_B before the
        // Allow below, so that decision still resolves the request that
        // was queued SECOND.
        var restoredToNavB = false
        for _ in 0..<5 {
            if elementText(navPayloadText).contains("NAV_B") && elementText(positionLabel).contains("2 / 2") {
                restoredToNavB = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(restoredToNavB, "clicking Next after the queue-menu jump must put the banner back on the second (NAV_B) queued request")

        app.buttons[Self.approvalBannerAllowButtonID].click()

        let navBResultText = waitForFileContent(atPath: navBOutFile)
        XCTAssertNotEqual(navBResultText, "(no output)", "the backgrounded pane_run (NAV_B) curl produced no output")
        let navBResult = try parseJSONObject(navBResultText, context: "pane_run NAV_B result")
        XCTAssertEqual(navBResult["status"] as? String, "sent",
                       "Allow on the navigated-to (displayed) request must resolve NAV_B, even though it was queued second -- got: \(navBResultText)")

        XCTAssertTrue(elementText(navPayloadText).contains("NAV_A"),
                     "once NAV_B is resolved, the banner must fall back to displaying the still-pending NAV_A request")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: Self.approvalBannerQueueMenuID).firstMatch.exists,
                      "with only one request left pending, single-request rendering must show no position label")

        denyViaOptionsMenu()

        let navAResultText = waitForFileContent(atPath: navAOutFile)
        XCTAssertNotEqual(navAResultText, "(no output)", "the backgrounded pane_run (NAV_A) curl produced no output")
        let navAResult = try parseJSONObject(navAResultText, context: "pane_run NAV_A result")
        XCTAssertEqual(navAResult["status"] as? String, "denied",
                       "Deny must resolve the last remaining queued request (NAV_A), draining the queue so MARK 5 starts clean -- got: \(navAResultText)")

        // MARK: 5. pane_split -- one more pane in the same tab

        let splitResult = toolCallSync(
            name: "pane_split", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"direction\": \"right\"}", counter: &counter
        )
        XCTAssertNotNil(splitResult["surface_id"] as? String, "pane_split must return the newly created pane's surface_id")
        XCTAssertEqual(splitResult["direction"] as? String, "right")

        let secondList = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)
        let secondPanes = try XCTUnwrap(secondList["panes"] as? [[String: Any]])
        XCTAssertEqual(secondPanes.count, paneCountBeforeSplit + 1,
                       "pane_split must add exactly one pane to the same tab")

        // MARK: 6. tab_create -- a pane appears in the new group

        let newGroupName = "E2E-COCKPIT"
        let tabCreateResult = toolCallSync(
            name: "tab_create", argumentsJSON: "{\"group_name\": \"\(newGroupName)\"}", counter: &counter
        )
        XCTAssertEqual(tabCreateResult["group_name"] as? String, newGroupName)

        let thirdList = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)
        let thirdPanes = try XCTUnwrap(thirdList["panes"] as? [[String: Any]])
        XCTAssertTrue(
            thirdPanes.contains { ($0["group_name"] as? String) == newGroupName },
            "pane_list must reflect a pane in the newly created group \"\(newGroupName)\" -- got: \(thirdPanes)"
        )
    }

    // MARK: - Floating approval panel: top-right placement

    /// The approval banner is hosted in an independent,
    /// `ApprovalPanelArranger`-anchored floating panel
    /// (`ApprovalPanelController`/`ApprovalPanelWindow`,
    /// `Calyx/Features/ApprovalInbox/`) rather than inline inside the
    /// main window's own content -- its window sits at the screen's own
    /// visible top-right corner, independent of the main window's own
    /// frame. The WINDOW itself carries a `gutter` (12pt) transparent
    /// margin UNIFORMLY on all four sides: the glass sheet's own
    /// top-right corner sits `marginRight` (17pt) inside the screen's
    /// visible right edge and `marginTop` (16pt) inside its visible top
    /// edge, and the window's own top/right edges sit `gutter` further
    /// out than that. The banner's `.accessibilityElement(children:
    /// .contain)` container
    /// reports only the union of its accessible descendants, which
    /// excludes `ApprovalBannerView`'s own padding, so its frame sits
    /// 12pt inside the sheet's left and right edges and 10pt inside its
    /// top and bottom edges; the panel window's own frame is measured
    /// instead.
    func test_approvalBanner_isPositionedAtVisibleFrameTopRightCorner() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertFalse(surfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for every ghostty-spawned pane")

        let outFile = "/tmp/calyx-e2e-cockpit-panel-position-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo PANEL_POSITION_MARKER\", \"await\": false}",
            outFile: outFile, counter: &counter
        )

        let container = app.descendants(matching: .any).matching(identifier: Self.approvalBannerContainerID).firstMatch
        XCTAssertTrue(waitFor(container, timeout: 15), "the approval banner never appeared")

        let panelWindow = app.windows
            .containing(.any, identifier: Self.approvalBannerContainerID)
            .firstMatch
        XCTAssertTrue(waitFor(panelWindow, timeout: 5), "the floating approval panel window never appeared")
        let bannerFrame = panelWindow.frame
        XCTAssertEqual(bannerFrame.width, 368, accuracy: 1, "the floating approval panel's own window must be the fixed 344pt sheet width plus 2*gutter (24pt)")

        let windowFrame = app.windows.firstMatch.frame
        let screen = try XCTUnwrap(
            screenContaining(windowFrame),
            "could not resolve which NSScreen the app-under-test's window is displayed on"
        )

        // NSScreen.visibleFrame is bottom-left-origin AppKit space;
        // XCUIElement.frame is top-left-origin. XCUIElement frames are
        // flipped against the PRIMARY screen's frame.maxY (the menu-bar
        // screen), not the resolved screen's own frame.maxY -- the same
        // reference screenContaining() uses to convert screen frames into
        // top-left-origin global coordinates.
        let primaryHeight = try XCTUnwrap(NSScreen.screens.first, "no primary NSScreen").frame.maxY
        let visibleFrame = screen.visibleFrame
        let visibleRight = visibleFrame.maxX

        // Mirrors `ApprovalPanelArranger.marginRight` (17pt),
        // `.marginTop` (16pt), and `.gutter` (12pt) (there is no module
        // access to the real constants from this out-of-process UI test
        // target) -- the WINDOW's own right edge sits at
        // `visibleFrame.maxX - marginRight + gutter`, and its own top
        // edge sits at `visibleFrame.maxY - marginTop + gutter`.
        let marginRight: CGFloat = 17
        let marginTop: CGFloat = 16
        let gutter: CGFloat = 12
        let visibleTop = primaryHeight - visibleFrame.maxY
        let expectedWindowTop = visibleTop + marginTop - gutter
        let expectedWindowMaxX = visibleRight - marginRight + gutter

        XCTAssertEqual(bannerFrame.maxX, expectedWindowMaxX, accuracy: 2,
                       "the floating approval panel's right edge must sit at visibleFrame.maxX - marginRight + gutter -- got window frame \(bannerFrame), visible right edge \(visibleRight)")
        XCTAssertEqual(bannerFrame.minY, expectedWindowTop, accuracy: 2,
                       "the floating approval panel WINDOW's top edge must sit at visibleFrame.maxY - marginTop + gutter (visibleTop + marginTop - gutter in top-left-origin space) -- got window frame \(bannerFrame), expected top edge \(expectedWindowTop)")

        denyViaOptionsMenu()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded pane_run curl produced no output")
        let result = try parseJSONObject(resultText, context: "pane_run panel-position Deny result")
        XCTAssertEqual(result["status"] as? String, "denied", "Deny must report status \"denied\" -- got: \(resultText)")
    }

    /// The `NSScreen` (in the RUNNER process, sharing the same physical
    /// displays as the app-under-test) whose frame -- converted to
    /// top-left-origin global coordinates using the primary
    /// (`NSScreen.screens.first`, the menu-bar screen) as the flip
    /// reference -- contains `windowFrame`'s center point.
    private func screenContaining(_ windowFrame: CGRect) -> NSScreen? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryHeight = primary.frame.maxY
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return NSScreen.screens.first { screen in
            let topLeftFrame = CGRect(
                x: screen.frame.minX,
                y: primaryHeight - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            return topLeftFrame.contains(windowCenter)
        }
    }

    // MARK: - palette_execute header: designated-host tab title, not "this window"

    /// `palette_execute` submits a nil-`targetSurfaceID` (window-
    /// agnostic) approval request; its header must read
    /// `"palette_execute → <the designated host's active tab title>"`,
    /// never the literal placeholder `"palette_execute → this window"`
    /// (`ApprovalBannerView`'s `hostWindowTitle` parameter, threaded
    /// through from the designated host's own active tab title).
    func test_paletteExecute_headerShowsDesignatedHostTabTitle_notThisWindow() throws {
        var counter = 0
        waitForIPCActivation()

        // A real, UNGATED MCP round trip first (mirrors
        // `test_cockpitTools_endToEnd`'s own opening `pane_list` call):
        // `toolCallSync` blocks (with its own internal retry budget)
        // until the real MCP server actually answers over HTTP, so
        // `agent-endpoint.json` is guaranteed to exist and be readable by
        // the time the BACKGROUNDED `palette_execute` curl below fires --
        // without this, that curl can race the endpoint file's own
        // creation and fail immediately with a connection/parse error
        // instead of ever reaching the approval gate at all. A plain
        // pane-side `echo` (no MCP traffic at all) would not catch this.
        _ = toolCallSync(name: "pane_list", argumentsJSON: "{}", counter: &counter)

        let outFile = "/tmp/calyx-e2e-cockpit-palette-header-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "palette_execute",
            argumentsJSON: "{\"command_id\": \"view.sidebar\"}",
            outFile: outFile, counter: &counter
        )

        // `elementText()`'s own doc comment (below): a SwiftUI Text's
        // rendered content can surface via `.value` rather than `.label`
        // on this macOS version, so every static text under the
        // container is scanned rather than querying by `label` alone.
        let container = app.descendants(matching: .any)
            .matching(identifier: Self.approvalBannerContainerID)
            .firstMatch
        XCTAssertTrue(waitFor(container, timeout: 15), "the approval banner's own container element never appeared for the palette_execute request")

        var headerLabel: String?
        for _ in 0..<50 {
            let candidates = container.descendants(matching: .staticText).allElementsBoundByIndex
            if let match = candidates.first(where: { elementText($0).hasPrefix("palette_execute → ") }) {
                headerLabel = elementText(match)
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let header = try XCTUnwrap(headerLabel,
            "no static text under the approval banner's container ever read \"palette_execute → ...\" -- container tree: \(container.debugDescription)")
        XCTAssertNotEqual(header, "palette_execute → this window",
                          "a nil-targetSurfaceID request's header must show the designated host's own active tab title, not the literal placeholder \"this window\"")
        denyViaOptionsMenu()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded palette_execute curl produced no output")
        let result = try parseJSONObject(resultText, context: "palette_execute Deny result")
        XCTAssertEqual(result["status"] as? String, "denied", "Deny must report status \"denied\" -- got: \(resultText)")
    }

    // MARK: - Notification-style body: tap-to-expand payload

    /// The body row shows `payload` truncated to 2 lines with the FULL
    /// text as its accessibility label; clicking it reveals
    /// `payloadExpanded` (the full monospaced payload) below it, and
    /// clicking again collapses it away.
    func test_payloadTap_togglesExpandedPayload() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertFalse(surfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for every ghostty-spawned pane")

        let outFile = "/tmp/calyx-e2e-cockpit-payload-expand-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo PAYLOAD_EXPAND_MARKER\", \"await\": false}",
            outFile: outFile, counter: &counter
        )

        let payloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(payloadText, timeout: 15), "the approval banner's payload text never appeared")
        XCTAssertTrue(elementText(payloadText).contains("PAYLOAD_EXPAND_MARKER"),
                     "the payload text's accessibility label must carry the FULL command text even while visually truncated -- got: \(elementText(payloadText))")

        let payloadExpanded = app.staticTexts[Self.approvalBannerPayloadExpandedID]
        XCTAssertFalse(payloadExpanded.exists, "the expanded payload must not exist before the body is clicked")

        // The `ScrollView` itself now spans the glass sheet PLUS the
        // `gutter` on all four sides (the gutter moved inside it so the
        // × has in-bounds room to straddle the sheet's own corner, and
        // the sheet's own soft shadow room to blur outward on every edge
        // -- see ApprovalPanelContentView's own header), so its own
        // accessibility frame is no longer the 344pt sheet width; the
        // panel WINDOW's own frame is checked instead, same width
        // relationship `test_dismissButton_returnsStatusDismissed_removesBanner`
        // already asserts for its own geometry.
        let panelWindow = app.windows
            .containing(.any, identifier: Self.approvalBannerContainerID)
            .firstMatch
        XCTAssertTrue(waitFor(panelWindow, timeout: 5), "the floating approval panel window never appeared")
        XCTAssertEqual(panelWindow.frame.width, 344 + 24, accuracy: 1,
                       "the panel window must be the fixed 344pt sheet width plus 2*gutter (24pt)")

        payloadText.click()

        XCTAssertTrue(waitFor(payloadExpanded, timeout: 5), "clicking the payload text must reveal the expanded payload")
        XCTAssertTrue(elementText(payloadExpanded).contains("PAYLOAD_EXPAND_MARKER"),
                     "the expanded payload must carry the full command text -- got: \(elementText(payloadExpanded))")

        payloadText.click()

        waitForNonExistence(payloadExpanded, timeout: 5)

        denyViaOptionsMenu()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded pane_run curl produced no output")
        let result = try parseJSONObject(resultText, context: "pane_run payload-expand Deny result")
        XCTAssertEqual(result["status"] as? String, "denied", "Deny must report status \"denied\" -- got: \(resultText)")
    }

    // MARK: - Dismiss button: tool never executes, panel closes

    /// Clicking `dismissButton` (the panel's own top-left × button) must
    /// resolve the gated `pane_run` call with `{"status":"dismissed"}`
    /// and remove the banner -- the tool call is never told allow or
    /// deny, since Calyx never answers the question at all. The button
    /// itself is a 20pt circle straddling the glass sheet's own top-left
    /// corner, drawn into the WINDOW's transparent `gutter` (12pt,
    /// uniform on all four sides) -- its own frame and the panel window's own
    /// frame are both `XCUIElement.frame` (the same top-left-origin
    /// coordinate space), so no AppKit flip is needed to compare them,
    /// unlike `test_approvalBanner_isPositionedAtVisibleFrameTopRightCorner`'s
    /// own visibleFrame comparison.
    func test_dismissButton_returnsStatusDismissed_removesBanner() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertFalse(surfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for every ghostty-spawned pane")

        let outFile = "/tmp/calyx-e2e-cockpit-dismiss-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo DISMISS_MARKER\", \"await\": false}",
            outFile: outFile, counter: &counter
        )

        let container = app.descendants(matching: .any).matching(identifier: Self.approvalBannerContainerID).firstMatch
        XCTAssertTrue(waitFor(container, timeout: 15), "the approval banner never appeared")

        let dismissButton = app.buttons[Self.approvalBannerDismissButtonID]
        XCTAssertTrue(waitFor(dismissButton, timeout: 5), "the dismiss button never appeared in the accessibility tree")

        let panelWindow = app.windows
            .containing(.any, identifier: Self.approvalBannerContainerID)
            .firstMatch
        XCTAssertTrue(waitFor(panelWindow, timeout: 5), "the floating approval panel window never appeared")

        let buttonFrame = dismissButton.frame
        XCTAssertEqual(buttonFrame.width, 20, accuracy: 1, "the dismiss button must be a 20pt circle")
        XCTAssertEqual(buttonFrame.height, 20, accuracy: 1, "the dismiss button must be a 20pt circle")

        // The glass sheet's own top-left corner sits `gutter`
        // (12pt) inside the window's own top-left corner; the circle's
        // center sits at `(sheet.minX + 4, sheet.top + 5)` -- matching a
        // 1x pixel dump of macOS's own native notification × placement.
        // `panelWindow.frame`/`buttonFrame` are both `XCUIElement.frame`
        // (top-left-origin -- `minY` is the TOP edge, same convention
        // `test_approvalBanner_isPositionedAtVisibleFrameTopRightCorner`
        // treats `bannerFrame.minY` as), so the sheet's top-left corner
        // is `(minX + 12, minY + 12)` in that space, not `(minX + 12,
        // maxY - 12)` (an AppKit bottom-up reading of "top-left" that
        // does not apply to `XCUIElement.frame`).
        let sheetCorner = CGPoint(x: panelWindow.frame.minX + 12, y: panelWindow.frame.minY + 12)
        let expectedCenter = CGPoint(x: sheetCorner.x + 4, y: sheetCorner.y + 5)
        let buttonCenter = CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        XCTAssertEqual(buttonCenter.x, expectedCenter.x, accuracy: 2,
                       "the dismiss button's center must sit 4pt right of the glass sheet's top-left corner on the x axis")
        XCTAssertEqual(buttonCenter.y, expectedCenter.y, accuracy: 2,
                       "the dismiss button's center must sit 5pt below the glass sheet's top-left corner on the y axis")

        // The dismiss button is unpainted (`.clear`) until the glass
        // sheet is hovered; `ApprovalPanelWindow` is non-opaque, so a
        // click over unpainted pixels reaches the window behind it
        // instead of this button. Hovering the payload body (inside the
        // sheet) first paints the × in.
        let payloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(payloadText, timeout: 5), "the approval banner's payload text never appeared")
        payloadText.hover()

        // `isPanelHovered` is `@State`, so hovering only schedules the ×'s
        // repaint on the next main-queue turn -- wait for it before the
        // screenshot, or the attachment can still show the × unpainted.
        Thread.sleep(forTimeInterval: 0.5)

        // Permanent diagnostic aid, not a temporary print: attaches the
        // hovered (×-visible, pre-click) panel to the test result itself,
        // unconditionally -- an environment-variable-gated file write
        // does not reach this out-of-process UI test runner, but an
        // `XCTAttachment` always lands in the run's own `.xcresult`
        // bundle (`.keepAlways` so it survives a passing run, not only a
        // failure), exportable with `xcrun xcresulttool export attachments`.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "dismiss-hovered"
        attachment.lifetime = .keepAlways
        add(attachment)

        dismissButton.click()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded pane_run curl produced no output")
        let result = try parseJSONObject(resultText, context: "pane_run Dismiss result")
        XCTAssertEqual(result["status"] as? String, "dismissed", "Dismiss must report status \"dismissed\" -- got: \(resultText)")

        waitForNonExistence(container, timeout: 5)
    }

    // MARK: - Hover tooltip

    /// Hovering the payload body must surface Calyx's own drawn tooltip
    /// (`ApprovalTooltipWindow`, via `ApprovalTooltipPresenter`), even
    /// when the pointer enters the panel somewhere ELSE first (the
    /// system `.help` tooltip this replaces is armed only on the FIRST
    /// cursor registration on the window, which a hover starting
    /// elsewhere in a non-activating panel never gets -- see
    /// `ExpandableBodyText`'s own header) -- nothing in the panel moves:
    /// the panel window's own frame is identical before and after the
    /// hover, and `payloadExpanded` (the tap-to-pin-expanded text) never
    /// appears from hovering alone. Hovering a point outside the panel
    /// afterward must dismiss the tooltip.
    func test_hoverPayload_showsTooltip_panelNeverMoves() throws {
        var counter = 0
        waitForIPCActivation()

        let surfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertFalse(surfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for every ghostty-spawned pane")

        let outFile = "/tmp/calyx-e2e-cockpit-hover-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(surfaceID)\", \"command\": \"echo HOVER_MARKER\", \"await\": false}",
            outFile: outFile, counter: &counter
        )

        let payloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(payloadText, timeout: 15), "the approval banner's payload text never appeared")

        let payloadExpanded = app.staticTexts[Self.approvalBannerPayloadExpandedID]
        XCTAssertFalse(payloadExpanded.exists, "the expanded payload must not exist before the body is hovered")

        let panelWindow = app.windows
            .containing(.any, identifier: Self.approvalBannerContainerID)
            .firstMatch
        XCTAssertTrue(waitFor(panelWindow, timeout: 5), "the floating approval panel window never appeared")
        let frameBeforeHover = panelWindow.frame

        let tooltip = app.staticTexts[Self.approvalBannerTooltipID]

        // The pointer must enter the panel somewhere OTHER than the
        // payload text first, then slide onto it -- this is exactly the
        // case AppKit's own `.help` tooltip misses (never getting a
        // first-registration on the payload text's own view), and the
        // Calyx-drawn tooltip must still appear.
        let allowButton = app.buttons[Self.approvalBannerAllowButtonID]
        XCTAssertTrue(waitFor(allowButton, timeout: 5), "the allow button never appeared")
        allowButton.hover()
        Thread.sleep(forTimeInterval: 0.3)
        payloadText.hover()

        XCTAssertTrue(waitFor(tooltip, timeout: 3),
                     "hovering onto the payload body (after entering the panel elsewhere first) must surface the tooltip within 3s")
        // Records the rendered tooltip for visual comparison.
        let tooltipAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        tooltipAttachment.name = "tooltip-shown"
        tooltipAttachment.lifetime = .keepAlways
        add(tooltipAttachment)

        // `payloadText.hover()` above hovers the element's own center,
        // so that center is the pointer position `ApprovalTooltipPresenter
        // .show(text:at:)` placed the tooltip window relative to
        // (`ApprovalTooltipPresenter.frame(for:pointer:visibleFrame:)`:
        // top-left corner at `pointer.x`, `pointer.y + 18` below it).
        // `app.windows` does not expose the tooltip panel, so the box's
        // own origin is derived from the static text's own frame instead,
        // subtracting the chrome outside it (1pt border + 1pt inner line
        // + insets: 4pt leading, 0pt top -- `ApprovalTooltipContent`'s
        // own padding).
        let payloadCenter = CGPoint(x: payloadText.frame.midX, y: payloadText.frame.midY)
        let tooltipBoxOrigin = CGPoint(x: tooltip.frame.minX - 6, y: tooltip.frame.minY - 2)
        XCTAssertEqual(tooltipBoxOrigin.x, payloadCenter.x, accuracy: 2,
                       "the tooltip box's own left edge must be left-aligned with the pointer")
        XCTAssertEqual(tooltipBoxOrigin.y, payloadCenter.y + 18, accuracy: 2,
                       "the tooltip box's own top edge must sit 18pt below the pointer")

        XCTAssertEqual(panelWindow.frame, frameBeforeHover,
                       "the panel window's own frame must be identical before and after the hover -- a tooltip must never move anything in the panel")
        XCTAssertFalse(payloadExpanded.exists, "hovering the payload body must never show the tap-to-pin-expanded text")

        // Hovering a point clearly outside the panel must dismiss the
        // tooltip -- relative to the panel window itself (`app`'s own
        // frame is unusable here: XCUIApplication has no real frame,
        // and `app.coordinate(withNormalizedOffset:)` crashes with
        // "point.x != INFINITY").
        panelWindow.coordinate(withNormalizedOffset: CGVector(dx: -1, dy: 2)).hover()
        waitForNonExistence(tooltip, timeout: 2)

        denyViaOptionsMenu()

        let resultText = waitForFileContent(atPath: outFile)
        XCTAssertNotEqual(resultText, "(no output)", "the backgrounded pane_run curl produced no output")
        let result = try parseJSONObject(resultText, context: "pane_run hover-tooltip Deny result")
        XCTAssertEqual(result["status"] as? String, "denied", "Deny must report status \"denied\" -- got: \(resultText)")
    }

    // MARK: - Single, app-wide panel across two windows

    /// One gated `pane_run` request per window (two windows total) must
    /// still surface exactly ONE approval panel -- the panel is app-wide
    /// and page-style, never one per window. The still-displayed first
    /// request reads "1 / 2"; Next advances to the second window's own
    /// request, reading "2 / 2"; both are then denied.
    func test_twoWindows_onePendingRequestEach_singleAppWidePanel_pagesBetweenBoth() throws {
        var counter = 0
        waitForIPCActivation()

        let firstSurfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertFalse(firstSurfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for the first window's own pane")

        menuAction("File", item: "New Window")
        XCTAssertTrue(waitFor(app.windows.element(boundBy: 1), timeout: 8),
                     "a second window never appeared after File > New Window (Cmd+N)")

        // The newly-created window becomes key, so this reads ITS OWN
        // pane's surface id, not the first window's.
        let secondSurfaceID = paneExec("echo $CALYX_SURFACE_ID", counter: &counter)
        XCTAssertFalse(secondSurfaceID.isEmpty, "$CALYX_SURFACE_ID must be set for the second window's own pane")
        XCTAssertNotEqual(firstSurfaceID, secondSurfaceID, "the two windows must have distinct panes")

        // Both curl calls are issued from whichever pane is currently
        // key (the second window's) -- `surface_id` in each argument
        // payload is what targets the request at a given pane, not
        // which pane's own shell happens to run the curl.
        let firstOutFile = "/tmp/calyx-e2e-cockpit-twowin-first-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(firstSurfaceID)\", \"command\": \"echo COCKPIT_MARKER_TWOWIN_FIRST\", \"await\": false}",
            outFile: firstOutFile, counter: &counter
        )

        let payloadText = app.staticTexts[Self.approvalBannerPayloadID]
        XCTAssertTrue(waitFor(payloadText, timeout: 15), "the approval banner never appeared for the first window's request")
        XCTAssertTrue(elementText(payloadText).contains("TWOWIN_FIRST"),
                     "the banner must display the first window's own pending command -- got: \(elementText(payloadText))")

        let secondOutFile = "/tmp/calyx-e2e-cockpit-twowin-second-\(ProcessInfo.processInfo.processIdentifier).json"
        toolCallBackgrounded(
            name: "pane_run",
            argumentsJSON: "{\"surface_id\": \"\(secondSurfaceID)\", \"command\": \"echo COCKPIT_MARKER_TWOWIN_SECOND\", \"await\": false}",
            outFile: secondOutFile, counter: &counter
        )

        let positionLabel = app.descendants(matching: .any)
            .matching(identifier: Self.approvalBannerQueueMenuID)
            .firstMatch
        XCTAssertTrue(waitFor(positionLabel, timeout: 15), "the position label never appeared once the second window's request queued behind the first")
        XCTAssertTrue(elementText(positionLabel).contains("1 / 2"),
                     "with two requests queued (one per window), the still-displayed first request must read \"1 / 2\" -- got: \(elementText(positionLabel))")

        let containers = app.descendants(matching: .any).matching(identifier: Self.approvalBannerContainerID)
        XCTAssertEqual(containers.count, 1,
                       "with one pending request in EACH of two different windows, there must be exactly ONE approval panel -- it is app-wide and page-style, never one per window")

        app.buttons[Self.approvalBannerNextButtonID].click()

        var advancedToSecond = false
        for _ in 0..<5 {
            if elementText(payloadText).contains("TWOWIN_SECOND") && elementText(positionLabel).contains("2 / 2") {
                advancedToSecond = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(advancedToSecond, "clicking Next must advance the single app-wide panel to the second window's own request, reading \"2 / 2\"")

        denyViaOptionsMenu()

        let secondResultText = waitForFileContent(atPath: secondOutFile)
        XCTAssertNotEqual(secondResultText, "(no output)", "the backgrounded pane_run (second window) curl produced no output")
        let secondResult = try parseJSONObject(secondResultText, context: "two-window second-request Deny result")
        XCTAssertEqual(secondResult["status"] as? String, "denied",
                       "Deny must resolve the second window's own request -- got: \(secondResultText)")

        // The panel's own container never disappears here (it falls
        // straight back to the still-pending first request), so the
        // real gate is the payload text switching to the FIRST window's
        // own marker -- same bounded 10x1s poll pattern this file uses
        // elsewhere, not a container-existence sentinel that would pass
        // instantly against the stale second-request page.
        var fellBackToFirst = false
        for _ in 0..<10 {
            if elementText(payloadText).contains("TWOWIN_FIRST") {
                fellBackToFirst = true
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(fellBackToFirst, "once the second window's request is resolved, the panel must fall back to the still-pending first window's own request")

        denyViaOptionsMenu()

        let firstResultText = waitForFileContent(atPath: firstOutFile)
        XCTAssertNotEqual(firstResultText, "(no output)", "the backgrounded pane_run (first window) curl produced no output")
        let firstResult = try parseJSONObject(firstResultText, context: "two-window first-request Deny result")
        XCTAssertEqual(firstResult["status"] as? String, "denied",
                       "Deny must resolve the first window's own request -- got: \(firstResultText)")
    }

    // MARK: - Helpers

    /// Opens the notification-style banner's Options pulldown and clicks
    /// its "Deny" item -- Deny is no longer its own top-level button (see
    /// `AccessibilityID.ApprovalBanner.optionsMenu`'s own doc comment):
    /// it is one titled `NSMenuItem` inside the Options menu, found by
    /// title exactly the same way the queue preview menu's own rows
    /// already are (`navARow` above) -- macOS never exposes an
    /// `NSMenuItem`'s identifier to the accessibility tree.
    private func denyViaOptionsMenu() {
        let optionsMenu = app.descendants(matching: .any)
            .matching(identifier: Self.approvalBannerOptionsMenuID)
            .firstMatch
        XCTAssertTrue(waitFor(optionsMenu, timeout: 15), "the approval banner's Options menu never appeared")
        optionsMenu.click()

        let denyItem = app.menuItems.matching(NSPredicate(format: "title == %@", "Deny")).firstMatch
        XCTAssertTrue(waitFor(denyItem, timeout: 10), "the Options menu never listed a \"Deny\" item")
        denyItem.click()
    }

    private func parseJSONObject(_ text: String, context: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(context) was not a valid JSON object: \(text)")
            return [:]
        }
        return object
    }

    /// Field-verified fix (this suite's own first real run): a SwiftUI
    /// `Text(...).accessibilityIdentifier(...)` INSIDE a `ScrollView`
    /// (`ApprovalBannerView.swift`'s payload text) does not expose its
    /// rendered content via `.label` -- `.label` came back empty even
    /// though the element existed and the text was genuinely on screen.
    /// Joins `.label` and `.value as? String` (whichever is non-empty,
    /// or both concatenated if both are) so a content assertion is
    /// robust to either surfacing convention, without needing to know
    /// in advance which one a given SwiftUI container/modifier
    /// combination picks.
    private func elementText(_ element: XCUIElement) -> String {
        let label = element.label
        let value = element.value as? String ?? ""
        if label.isEmpty { return value }
        if value.isEmpty || value == label { return label }
        return label + " " + value
    }

    /// Synchronous tools/call: writes `toolCallScript`'s output to /tmp
    /// via `paneExec` and waits for it inline, same shape as
    /// `CommandLogE2ETests.queryScript`. Only safe for a tool that
    /// returns promptly (every P4 Cockpit tool, and any already-decided
    /// P5 poll) -- never for an UNANSWERED gated call, which would block
    /// the pane's curl (and therefore this call) for up to the bridge's
    /// own ~55s internal approval timeout.
    private func toolCallSync(name: String, argumentsJSON: String, counter: inout Int, timeoutAttempts: Int = 20) -> [String: Any] {
        let script = toolCallScript(name: name, argumentsJSON: argumentsJSON, maxTimeSeconds: 10)
        let encoded = Data(script.utf8).base64EncodedString()
        counter += 1
        let scriptPath = "/tmp/calyx-e2e-cockpit-sync-\(counter).py"
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && python3 \(scriptPath)"
        let resultText = paneExec(command, counter: &counter, timeoutAttempts: timeoutAttempts)

        guard resultText != "(no output)",
              let data = resultText.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("\(name) pane-side query produced no/invalid JSON output: \(resultText)")
            return [:]
        }
        if let scriptError = result["error"] as? String {
            XCTFail("\(name) pane-side script reported an error: \(scriptError)")
            return [:]
        }
        return result
    }

    /// Backgrounded tools/call: pastes a command that runs
    /// `toolCallScript`'s python3 script inside a detached subshell
    /// (`(cmd &); disown` -- backgrounds it, then disowns it from the
    /// interactive shell's own job control so no "[1]+ Done" job-control
    /// notification is later printed into the pane's scrollback) via
    /// `panePasteAndReturn`, which does not wait for any output --
    /// control returns to this test immediately, while the pane-side
    /// curl call is left running (and, for a gated tool, blocked on the
    /// approval banner this test is about to go answer). The script's
    /// own stdout goes to `outFile`; poll it separately with
    /// `waitForFileContent` once the banner has been answered.
    private func toolCallBackgrounded(name: String, argumentsJSON: String, outFile: String, counter: inout Int) {
        try? FileManager.default.removeItem(atPath: outFile)
        // >55s: comfortably longer than the bridge's own ~55s internal
        // approval-wait timeout, so THIS curl call is never the one that
        // cuts the round trip short -- the approval flow's own
        // .expired/.allowed/.denied resolution decides the outcome, not
        // an impatient client socket.
        let script = toolCallScript(name: name, argumentsJSON: argumentsJSON, maxTimeSeconds: 65)
        let encoded = Data(script.utf8).base64EncodedString()
        counter += 1
        let scriptPath = "/tmp/calyx-e2e-cockpit-bg-\(counter).py"
        let command = "printf '%s' '\(encoded)' | base64 -d > \(scriptPath) && " +
            "(python3 \(scriptPath) > \(outFile) 2>&1 &); disown"
        panePasteAndReturn(command)
    }

    /// Near-duplicate of `PaneCLIExec.paneExec`'s own tail-polling loop
    /// (see this file's header for why it is not shared): polls `path`
    /// until it has non-empty content or a bounded number of attempts
    /// elapse, returning the trimmed content (or "(no output)").
    /// `timeoutAttempts: 130` at the default 0.5s poll interval budgets
    /// ~65s -- matching `toolCallBackgrounded`'s own `maxTimeSeconds`
    /// ceiling for a gated call's curl, plus headroom for this test's
    /// own (expected sub-second) banner click.
    private func waitForFileContent(atPath path: String, timeoutAttempts: Int = 130) -> String {
        for _ in 0..<timeoutAttempts {
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: path),
               let content = try? String(contentsOfFile: path, encoding: .utf8),
               !content.isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no output)"
    }

    /// Polls `terminal_list_commands` (a synchronous, ungated tool) for
    /// up to ~20s for a command whose own text contains `marker`,
    /// returning its record once found.
    private func waitForTrackedCommand(containing marker: String, surfaceID: String, counter: inout Int) throws -> [String: Any] {
        for _ in 0..<20 {
            let list = toolCallSync(name: "terminal_list_commands", argumentsJSON: "{\"surface_id\": \"\(surfaceID)\"}", counter: &counter)
            let commands = (list["commands"] as? [[String: Any]]) ?? []
            if let found = commands.first(where: { ($0["command"] as? String)?.contains(marker) == true }) {
                return found
            }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("no tracked command containing \"\(marker)\" appeared for surface \(surfaceID) within the timeout budget")
        return [:]
    }

    /// Builds a python3 script that POSTs a single `tools/call` to the
    /// real MCP server (endpoint read from `CALYX_ENDPOINT_FILE`,
    /// falling back to the unscoped `agent-endpoint.json` path -- see
    /// this file's header) and prints
    /// the tool's own (already-decoded) JSON result text on one line, or
    /// `{"error": ...}` on any failure -- mirrors
    /// `CommandLogE2ETests.queryScript`'s `call_tool` helper exactly,
    /// generalized to an arbitrary tool name/arguments pair instead of a
    /// fixed sequence of terminal_* calls. `argumentsJSON` (already-valid
    /// JSON text this file's own callers build from simple,
    /// quote-free values -- UUIDs, "right"/"down", plain marker/group
    /// text) is embedded as a Python triple-single-quoted string literal
    /// and re-parsed with `json.loads` inside the script, rather than
    /// shell-escaped as a `sys.argv` element -- this sidesteps shell
    /// quoting entirely, at the cost of requiring `argumentsJSON` to
    /// never itself contain a `'''` sequence (true for every call site
    /// in this file).
    private func toolCallScript(name: String, argumentsJSON: String, maxTimeSeconds: Int) -> String {
        """
        import json
        import os
        import subprocess

        def main():
            endpoint_path = os.environ.get("CALYX_ENDPOINT_FILE") or os.path.expanduser(
                "~/Library/Application Support/Calyx/agent-endpoint.json"
            )
            with open(endpoint_path) as f:
                endpoint = json.load(f)
            port = endpoint["port"]
            token = endpoint["token"]

            arguments = json.loads('''\(argumentsJSON)''')
            body = json.dumps({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": {"name": "\(name)", "arguments": arguments},
            })
            proc = subprocess.run(
                [
                    "curl", "-s", "--max-time", "\(maxTimeSeconds)",
                    "-X", "POST",
                    "-H", "Authorization: Bearer " + token,
                    "-H", "Content-Type: application/json",
                    "--data-binary", body,
                    "http://127.0.0.1:%d/mcp" % port,
                ],
                capture_output=True, text=True,
            )
            envelope = json.loads(proc.stdout)
            text = envelope["result"]["content"][0]["text"]
            print(text)

        try:
            main()
        except Exception as e:
            print(json.dumps({"error": repr(e)}))
        """
    }
}
