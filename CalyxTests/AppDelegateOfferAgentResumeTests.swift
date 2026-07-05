//
//  AppDelegateOfferAgentResumeTests.swift
//  CalyxTests
//
//  TDD Red phase for round-4 fix F14 (r4-fix-spec.md; evidence in
//  r4-verdicts.md V11/S3): behavioral coverage for
//  `AppDelegate.offerAgentResume(tab:surfaceID:sessionID:sessions:)`'s
//  decode/selection/sendText pipeline, which had no direct test coverage
//  before this round (only reachable indirectly through a live restore/
//  attach with a real ghostty surface and daemon round-trip).
//
//  Drives `offerAgentResume` directly (made non-private for this
//  purpose, see its own doc comment) rather than through
//  `restoreWindow`/`attachWindow`'s full restore pipeline, matching this
//  file's `handleSessionReconnectDecision`/`closeAllTabsInGroup`
//  precedent for testing a method whose real call sites need a live
//  ghostty app. Uses `AppDelegate._offerAgentResumeSendTextHookForTesting`
//  (also new, see its doc comment) to observe the exact text
//  `offerAgentResume` computed without a live `GhosttySurfaceController`:
//  `SurfaceRegistry.controller(for:)` only resolves real, ghostty-backed
//  entries, and a `_testInsert`-only fixture (this codebase's existing
//  no-live-surface test pattern) never has one.
//
//  Coverage:
//  - Resumable meta present (a `SessionInfo` in `sessions` carrying an
//    `"agent.<kind>"` meta key) -> the hook fires with
//    `SessionResumePlanner.initialInput`'s output.
//  - Meta absent (present `SessionInfo`, but no `"agent.*"` meta key) ->
//    the hook never fires.
//  - `SessionSettings.agentResumeEnabled == false` -> the hook never
//    fires, even with a fully resumable `sessions` entry present.
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateOfferAgentResumeTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.AppDelegateOfferAgentResumeTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings.resetToDefaults()
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    private func makeSessionInfo(id: String, meta: [String: String]) -> SessionInfo {
        SessionInfo(
            id: id,
            name: nil,
            cwd: nil,
            state: .running,
            createdAtMs: 0,
            attachedClients: 0,
            pid: 0,
            meta: meta
        )
    }

    /// Drains `offerAgentResume`'s fire-and-forget `Task` (the hook
    /// fires from inside it, see that method's doc comment) so the
    /// assertion below observes its result deterministically rather
    /// than racing it.
    private func waitForHook() async {
        await Task.yield()
        await Task.yield()
    }

    func test_offerAgentResume_resumableMetaPresent_sendsPlannerOutput() async throws {
        SessionSettings.agentResumeEnabled = true
        SessionSettings.agentResumeAutoExecute = false

        let appDelegate = AppDelegate()
        var capturedCalls: [(surfaceID: UUID, text: String)] = []
        appDelegate._offerAgentResumeSendTextHookForTesting = { surfaceID, text in
            capturedCalls.append((surfaceID, text))
        }

        let sessionID = "test-session-\(UUID().uuidString)"
        let surfaceID = UUID()
        let tab = Tab()
        let agentSessionID = "agent-session-abc123"
        let sessions = [
            sessionID: makeSessionInfo(
                id: sessionID,
                meta: [SessionResumePlanner.encodeMetaKey(kind: AgentEntry.claudeCodeKind): agentSessionID]
            )
        ]

        appDelegate.offerAgentResume(tab: tab, surfaceID: surfaceID, sessionID: sessionID, sessions: sessions)
        await waitForHook()

        let expectedInput = try XCTUnwrap(SessionResumePlanner.initialInput(
            agentKind: AgentEntry.claudeCodeKind,
            agentSessionID: agentSessionID,
            autoExecute: false
        ))
        XCTAssertEqual(capturedCalls.count, 1,
                       "offerAgentResume must send exactly once when resumable meta is present")
        XCTAssertEqual(capturedCalls.first?.surfaceID, surfaceID)
        XCTAssertEqual(capturedCalls.first?.text, expectedInput,
                       "offerAgentResume must send SessionResumePlanner's exact planner output")
    }

    func test_offerAgentResume_noResumableMeta_neverSends() async throws {
        SessionSettings.agentResumeEnabled = true

        let appDelegate = AppDelegate()
        var capturedCalls: [(surfaceID: UUID, text: String)] = []
        appDelegate._offerAgentResumeSendTextHookForTesting = { surfaceID, text in
            capturedCalls.append((surfaceID, text))
        }

        let sessionID = "test-session-\(UUID().uuidString)"
        let tab = Tab()
        let sessions = [sessionID: makeSessionInfo(id: sessionID, meta: [:])]

        appDelegate.offerAgentResume(tab: tab, surfaceID: UUID(), sessionID: sessionID, sessions: sessions)
        await waitForHook()

        XCTAssertTrue(capturedCalls.isEmpty,
                      "offerAgentResume must not send anything when the session's meta carries no " +
                      "resumable agent entry")
    }

    func test_offerAgentResume_agentResumeDisabled_neverSends() async throws {
        SessionSettings.agentResumeEnabled = false

        let appDelegate = AppDelegate()
        var capturedCalls: [(surfaceID: UUID, text: String)] = []
        appDelegate._offerAgentResumeSendTextHookForTesting = { surfaceID, text in
            capturedCalls.append((surfaceID, text))
        }

        let sessionID = "test-session-\(UUID().uuidString)"
        let tab = Tab()
        let sessions = [
            sessionID: makeSessionInfo(
                id: sessionID,
                meta: [SessionResumePlanner.encodeMetaKey(kind: AgentEntry.claudeCodeKind): "agent-session-xyz"]
            )
        ]

        appDelegate.offerAgentResume(tab: tab, surfaceID: UUID(), sessionID: sessionID, sessions: sessions)
        await waitForHook()

        XCTAssertTrue(capturedCalls.isEmpty,
                      "offerAgentResume must not send anything when agentResumeEnabled is false, even " +
                      "with a fully resumable sessions entry present")
    }
}
