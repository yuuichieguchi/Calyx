//
//  AgentRegistryTests.swift
//  CalyxTests
//
//  TDD Red Phase for AgentRegistry: hook-event state transitions, session
//  reconciliation, title-heuristic fallback, and sidebar sort order.
//
//  Coverage:
//  - SessionStart registration and same-surface replacement
//  - working transitions (UserPromptSubmit / PreToolUse / PostToolUse)
//  - Notification → blocked (pattern match required)
//  - Stop → idle, SessionEnd → done (entry retained)
//  - SubagentStop fully ignored
//  - Auto-registration of unregistered surfaces on non-SessionStart events
//  - session_id mismatch reconciliation (done → replace, else discard)
//  - handleSurfaceDestroyed removal
//  - Title-heuristic fallback entries and hooks promotion
//  - sortedEntries ordering
//

import XCTest
@testable import Calyx

@MainActor
final class AgentRegistryTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        _ name: String,
        sessionID: String? = "session-1",
        cwd: String? = "/Users/dev/project",
        message: String? = nil
    ) -> AgentEvent {
        AgentEvent(hookEventName: name, sessionID: sessionID, cwd: cwd, message: message)
    }

    // MARK: - SessionStart

    func test_sessionStart_newSurface_registersIdleWithSessionAndCwd() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleHookEvent(
            event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/repo-a"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries.count, 1)
        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .idle)
        XCTAssertEqual(entry?.sessionID, "session-a")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-a")
        XCTAssertEqual(entry?.source, .hooks)
    }

    func test_sessionStart_sameSurfaceDifferentSession_replacesEntryKeepingCountOne() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleHookEvent(
            event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/repo-a"),
            surfaceID: surfaceID
        )
        registry.handleHookEvent(
            event("SessionStart", sessionID: "session-b", cwd: "/Users/dev/repo-b"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries.count, 1,
                       "Re-SessionStart on the same surface must replace, not add")
        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-b")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-b")
        XCTAssertEqual(entry?.state, .idle)
    }

    func test_sessionStart_sameSurfaceSameSession_preservesStateAndRefreshesCwd() {
        // Claude Code re-sends SessionStart on `/compact` and `/resume`
        // without an intervening SessionEnd. Resetting to .idle in that
        // case would flash a working/blocked row back to idle for no
        // reason — only cwd/lastEventAt should refresh.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/repo-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/repo-a"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .working,
                       "A same-session SessionStart (compact/resume) must not reset state to idle")
        XCTAssertEqual(entry?.sessionID, "session-a")
        XCTAssertEqual(registry.entries.count, 1)
    }

    // MARK: - Working transitions

    func test_userPromptSubmit_matchingSession_setsWorking() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)
    }

    func test_preToolUse_matchingSession_setsWorking() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        registry.handleHookEvent(event("PreToolUse", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)
    }

    func test_postToolUse_matchingSession_setsWorking() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        registry.handleHookEvent(event("PostToolUse", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)
    }

    // MARK: - Notification / blocked

    func test_notification_matchingSessionAndPattern_setsBlocked() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        registry.handleHookEvent(
            event("Notification", sessionID: "session-a",
                  message: "Claude needs your permission to run this command"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)
    }

    func test_notification_matchingSessionNonMatchingPattern_stateUnchanged() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(
            event("Notification", sessionID: "session-a", message: "Unrelated notification text"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "A non-matching notification message must not change state")
    }

    func test_notification_matchingSessionNilMessage_setsBlocked() {
        // Contract updated post-review: the hooks config's
        // `matcher: "permission_prompt"` already restricts which
        // `Notification`s reach the registry at all, so a nil message is
        // trusted as blocked rather than left unchanged. The substring
        // check in `blockedNotificationPatterns` is only a backstop for a
        // non-nil message that fails to match, guarding against an older
        // Claude Code build that ignores the matcher.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(
            event("Notification", sessionID: "session-a", message: nil),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A nil notification message must be trusted as blocked")
    }

    // MARK: - Stop / SessionEnd

    func test_stop_matchingSession_setsIdle() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)
    }

    func test_sessionEnd_matchingSession_setsDoneAndKeepsEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries.count, 1, "SessionEnd must not remove the entry")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done)
    }

    // MARK: - SubagentStop ignored

    func test_subagentStop_unregisteredSurface_isIgnored() {
        let registry = AgentRegistry()

        // Sanity: registration does happen normally for other events,
        // proving the unchanged count below isn't just a permanently
        // no-op registry.
        let sanitySurface = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-sanity"), surfaceID: sanitySurface)
        XCTAssertEqual(registry.entries.count, 1, "Precondition: SessionStart must register normally")

        let surfaceID = UUID()
        registry.handleHookEvent(event("SubagentStop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries.count, 1, "SubagentStop must never auto-register a surface")
    }

    func test_subagentStop_registeredSurface_stateUnchanged() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        registry.handleHookEvent(event("SubagentStop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "SubagentStop must be fully ignored")
    }

    // MARK: - Auto-registration for non-SessionStart events

    func test_unregisteredSurface_userPromptSubmit_autoRegistersAsWorking() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleHookEvent(
            event("UserPromptSubmit", sessionID: "session-a", cwd: "/Users/dev/repo-a"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries.count, 1)
        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .working)
        XCTAssertEqual(entry?.sessionID, "session-a")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-a")
    }

    // MARK: - Session mismatch reconciliation

    func test_sessionMismatch_entryDone_replacesEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done)

        registry.handleHookEvent(
            event("UserPromptSubmit", sessionID: "session-b", cwd: "/Users/dev/repo-b"),
            surfaceID: surfaceID
        )

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-b",
                       "A done entry must be replaceable by a new session's event")
        XCTAssertEqual(entry?.state, .working)
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-b")
    }

    func test_sessionMismatch_entryNotDone_discardsEvent() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(event("SessionEnd", sessionID: "stale-session"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-a",
                       "A mismatched, non-done entry must discard the incoming event")
        XCTAssertEqual(entry?.state, .working,
                       "State must remain unchanged when the event is discarded")
    }

    func test_sessionMismatch_entryNotDoneButEventForwardMoving_replacesEntry() {
        // Contract added post-review: a forward-moving event
        // (UserPromptSubmit/PreToolUse/PostToolUse) for a different,
        // unseen session means a new Claude Code session is genuinely
        // under way on this pane — most likely because IPC was enabled
        // (or Calyx restarted) after the session's own SessionStart
        // already fired and was missed. Discarding it, as a non-done
        // mismatch normally would, permanently wedges the row on the old
        // session. Stop/SessionEnd/Notification mismatches are NOT
        // extended this way — see test_sessionMismatch_entryNotDone_discardsEvent
        // — since those are as likely to be a stale session's event
        // arriving late (e.g. /clear's old-session SessionEnd) as a new one.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(
            event("PreToolUse", sessionID: "session-b", cwd: "/Users/dev/repo-b"),
            surfaceID: surfaceID
        )

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-b",
                       "A forward-moving event for an unseen session must replace a non-done entry")
        XCTAssertEqual(entry?.state, .working)
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-b")
    }

    // MARK: - Surface destruction

    func test_handleSurfaceDestroyed_removesHooksEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries.count, 1)

        registry.handleSurfaceDestroyed(surfaceID: surfaceID)

        XCTAssertTrue(registry.entries.isEmpty)
    }

    func test_handleSurfaceDestroyed_removesTitleHeuristicEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")
        XCTAssertEqual(registry.entries.count, 1,
                       "Precondition: a titleHeuristic entry must have been created")

        registry.handleSurfaceDestroyed(surfaceID: surfaceID)

        XCTAssertTrue(registry.entries.isEmpty)
    }

    // MARK: - Title heuristic fallback

    func test_handleTitleChange_unregisteredSurfaceWorkingTitle_createsTitleHeuristicEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .titleHeuristic)
        XCTAssertEqual(entry?.state, .working)
    }

    func test_handleTitleChange_hooksEntryUnaffectedByTitleSignal() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)

        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .idle, "A title signal must never override a hooks-sourced entry")
        XCTAssertEqual(entry?.source, .hooks)
    }

    func test_titleHeuristicEntry_promotedToHooksOnSubsequentHookEvent() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")
        XCTAssertEqual(registry.entries[surfaceID]?.source, .titleHeuristic)

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .hooks,
                       "The first hook event must promote a titleHeuristic entry to hooks")
        XCTAssertEqual(registry.entries.count, 1, "Promotion must replace, not add, the entry")
    }

    // MARK: - Sort order

    func test_sortedEntries_ordersByStatePriorityThenCwdBasename() {
        let registry = AgentRegistry()

        let blockedSurface = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "s-blocked", cwd: "/Users/dev/zeta"),
            surfaceID: blockedSurface
        )
        registry.handleHookEvent(
            event("Notification", sessionID: "s-blocked",
                  message: "Claude needs your permission to run this command"),
            surfaceID: blockedSurface
        )

        let workingBravo = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "s-bravo", cwd: "/Users/dev/bravo"),
            surfaceID: workingBravo
        )
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "s-bravo"), surfaceID: workingBravo)

        let workingAlpha = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "s-alpha", cwd: "/Users/dev/alpha"),
            surfaceID: workingAlpha
        )
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "s-alpha"), surfaceID: workingAlpha)

        let idleSurface = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "s-idle", cwd: "/Users/dev/beta"),
            surfaceID: idleSurface
        )

        let doneSurface = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "s-done", cwd: "/Users/dev/gamma"),
            surfaceID: doneSurface
        )
        registry.handleHookEvent(event("SessionEnd", sessionID: "s-done"), surfaceID: doneSurface)

        let sorted = registry.sortedEntries

        XCTAssertEqual(sorted.map(\.id), [
            blockedSurface,
            workingAlpha, workingBravo,
            idleSurface,
            doneSurface,
        ], "Order must be blocked, then working (alpha before bravo), then idle, then done")
    }

    // MARK: - Agent kind

    func test_sessionStart_setsClaudeCodeKind() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.kind, "claude-code")
    }

    func test_handleTitleChange_setsClaudeCodeKind() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        XCTAssertEqual(registry.entries[surfaceID]?.kind, "claude-code")
    }

    // MARK: - Server lifecycle (isServerRunning / reset)

    func test_markServerStarted_setsIsServerRunning() {
        let registry = AgentRegistry()
        XCTAssertFalse(registry.isServerRunning, "Precondition: a fresh registry reports the server as not running")

        registry.markServerStarted()

        XCTAssertTrue(registry.isServerRunning)

        // markServerStarted() starts a 60-second periodic sweep Task; tear
        // it down so it doesn't outlive this test and keep running in the
        // test process.
        registry.reset()
    }

    func test_reset_clearsEntriesAndIsServerRunning() {
        let registry = AgentRegistry()
        registry.markServerStarted()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: UUID())
        XCTAssertEqual(registry.entries.count, 1, "Precondition: an entry must exist before reset")

        registry.reset()

        XCTAssertTrue(registry.entries.isEmpty, "reset() must clear every entry")
        XCTAssertFalse(registry.isServerRunning, "reset() must mark the server as not running")
    }

    // MARK: - Staleness sweep

    func test_sweepStaleEntries_downgradesStaleWorkingHooksEntryToIdle() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        let farFuture = Date().addingTimeInterval(16 * 60)
        registry.sweepStaleEntries(now: farFuture)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A .working entry idle past the threshold must be downgraded to .idle")
    }

    func test_sweepStaleEntries_leavesFreshWorkingEntryUnchanged() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)

        let almostStale = Date().addingTimeInterval(14 * 60)
        registry.sweepStaleEntries(now: almostStale)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "A .working entry under the threshold must not be downgraded")
    }

    func test_sweepStaleEntries_leavesStaleBlockedEntryUnchanged() {
        // A permission prompt left unanswered for a long time is a
        // legitimate wait, not staleness — blocked entries must never be
        // swept, however long they've been sitting.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(
            event("Notification", sessionID: "session-a",
                  message: "Claude needs your permission to run this command"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        let farFuture = Date().addingTimeInterval(60 * 60)
        registry.sweepStaleEntries(now: farFuture)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A stale .blocked entry must never be swept")
    }
}
