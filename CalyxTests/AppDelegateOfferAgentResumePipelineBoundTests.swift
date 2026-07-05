//
//  AppDelegateOfferAgentResumePipelineBoundTests.swift
//  CalyxTests
//
//  TDD Red phase for round-8 fix R8-D item 1 (r8-fix-spec.md; CONFIRMED
//  evidence in r7-verdicts.md's "Unbounded await (D1)" entry):
//  createSurfaceWithPwd's reattach-path dispatch Task awaits
//  agentResumeSessionsTask's value before calling offerAgentResume, but
//  that shared task itself has no deadline of its own since R6-C
//  removed the old 2.0s synchronous spin. With an unresponsive daemon,
//  the dispatch Task never completes at all (bounded only by
//  SystemCommandRunner's unrelated 600s subprocess watchdog, see
//  r7-verdicts.md), leaking a suspended Task per restored
//  persistent-session surface. The fix wraps the daemon call in a race
//  against a short (a few seconds) deadline so the shared task always
//  reaches a terminal state, completing with [:] on timeout.
//
//  Reuses AppDelegateFetchSessionsForAgentResumeTests's
//  NeverRespondingDaemonClient fake-daemon structure (a listAll() that
//  awaits a continuation this test never resumes) via
//  AppDelegate._sessionDaemonClientForTesting, and drives the real
//  restoreTabSurfaces/createSurfaceWithPwd pipeline (see
//  AppDelegateRestoreTabSurfacesOwnershipTests's header comment for why
//  a seam, AppDelegate._createSurfaceWithPwdHookForTesting, stands in
//  for the one actually-unsafe real-ghostty-surface call). The
//  dispatch Task's completion is otherwise unobservable from a test
//  (fire-and-forget), so this drives it through the new
//  _createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting seam
//  (see its own doc comment on createSurfaceWithPwd) rather than
//  hanging the test process waiting on something with no signal at
//  all. Waits via XCTWaiter with a generous, bounded timeout so the
//  test itself cannot hang even if the production bound is still
//  missing: a timed-out wait is exactly this test's RED result.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class AppDelegateOfferAgentResumePipelineBoundTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.AppDelegateOfferAgentResumePipelineBoundTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings.resetToDefaults()
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    /// A fake daemon whose listAll() awaits a continuation this test
    /// never resumes, standing in for a daemon that is unreachable for
    /// the whole test run. Mirrors
    /// AppDelegateFetchSessionsForAgentResumeTests's private fixture of
    /// the same name/shape (not shared across files, matching this
    /// codebase's established per-file fixture-duplication convention).
    private final class NeverRespondingDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
        func sessionState(id: String) async -> SessionQueryResult { .unreachable }

        func kill(id: String) async {}

        func listAll() async -> [SessionInfo] {
            await withCheckedContinuation { (_: CheckedContinuation<[SessionInfo], Never>) in
                // Deliberately never resumed.
            }
        }
    }

    /// R8-D item 1 (r8-fix-spec.md; r7-verdicts.md "Unbounded await
    /// (D1)"): against the CURRENT code, the per-surface dispatch Task
    /// createSurfaceWithPwd starts for a persistent-session leaf awaits
    /// agentResumeSessionsTask.value with no bound of its own, and the
    /// injected daemon's listAll() never resolves, so that Task never
    /// reaches offerAgentResume at all within any reasonable window.
    /// The completion hook therefore never fires, and the wait below
    /// times out (RED). The fix must give agentResumeSessionsTask its
    /// own short deadline so this pipeline always reaches a terminal
    /// state.
    func test_offerAgentResumePipeline_reachesTerminalState_evenWithUnresponsiveDaemon() {
        SessionSettings.agentResumeEnabled = true

        let appDelegate = AppDelegate()
        appDelegate._sessionDaemonClientForTesting = NeverRespondingDaemonClient()
        appDelegate.fetchSessionsForAgentResume()

        // CALYX_SESSION_BIN env override (SessionBinaryResolver's own
        // documented test-injection seam) makes
        // SessionCommandSynthesizer.reattachCommand resolve to a
        // non-nil command for this sessionID, without which
        // createSurfaceWithPwd would silently fall through to the
        // plain (non-reattach) path and never dispatch the Task this
        // test targets at all. The path need not exist: the seam below
        // intercepts before any command is ever actually executed.
        let originalBinPath = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        setenv("CALYX_SESSION_BIN", "/usr/bin/true", 1)
        defer {
            if let originalBinPath {
                setenv("CALYX_SESSION_BIN", originalBinPath, 1)
            } else {
                unsetenv("CALYX_SESSION_BIN")
            }
        }

        // A distinct ULID from AppDelegateRestoreTabSurfacesOwnershipTests's
        // duplicateSessionID: SessionSurfaceMap.shared is a process-wide
        // singleton shared across the whole test run, unregistered below
        // so this test never leaks a registration another test could
        // observe.
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAW"
        let oldLeafID = UUID()
        let newSurfaceID = UUID()
        appDelegate._createSurfaceWithPwdHookForTesting = { _ in newSurfaceID }
        defer { SessionSurfaceMap.shared.unregister(sessionID: sessionID) }

        var sendTextHookCallCount = 0
        appDelegate._offerAgentResumeSendTextHookForTesting = { _, _ in sendTextHookCallCount += 1 }

        let completionExpectation = XCTestExpectation(
            description: "createSurfaceWithPwd's offer-agent-resume dispatch Task reaches a terminal state"
        )
        appDelegate._createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting = {
            completionExpectation.fulfill()
        }

        let tab = Tab(
            splitTree: SplitTree(leafID: oldLeafID),
            sessionRefs: [oldLeafID: SessionRef(sessionID: sessionID)]
        )
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

        let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: window)
        XCTAssertTrue(restored, "Precondition: the single-leaf restore itself (the synchronous part) must succeed")

        let waiterResult = XCTWaiter.wait(for: [completionExpectation], timeout: 8.0)

        XCTAssertEqual(waiterResult, .completed,
                      "The per-surface offer-agent-resume pipeline must reach a terminal state within a " +
                      "generous bound, not hang past it waiting on an unresponsive daemon with no deadline " +
                      "of its own")
        XCTAssertEqual(sendTextHookCallCount, 0,
                      "With no daemon response ever available, there is no resumable session info to act " +
                      "on, sendText must never be called")
    }
}
