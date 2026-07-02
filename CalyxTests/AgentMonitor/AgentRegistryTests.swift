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

    // MARK: - PermissionRequest (Phase 2: Codex)

    func test_permissionRequest_registeredSameSession_setsBlocked() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)
    }

    func test_permissionRequest_unregisteredSurface_autoRegistersAsBlocked() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleHookEvent(
            event("PermissionRequest", sessionID: "session-a", cwd: "/Users/dev/repo-a"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries.count, 1)
        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .blocked)
        XCTAssertEqual(entry?.sessionID, "session-a")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-a")
    }

    func test_permissionRequest_sessionMismatch_discardedAndNotForwardMoving() {
        // A PermissionRequest for a session the registry hasn't seen must be
        // discarded (state unchanged) rather than treated as forward-moving
        // like UserPromptSubmit/PreToolUse/PostToolUse — see the doc comment
        // on handleHookEvent's forwardMovingEventNames guard.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-b"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-a",
                       "A mismatched PermissionRequest must be discarded, not replace the entry")
        XCTAssertEqual(entry?.state, .working,
                       "State must remain unchanged when the mismatched PermissionRequest is discarded")

        // Sanity: confirm PermissionRequest is actually wired up to .blocked
        // for the *matching* session — otherwise the discard above would be
        // indistinguishable from "PermissionRequest is simply unrecognized".
        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)
    }

    // MARK: - PermissionRequest session-mismatch rescue (Phase 2: Codex has no SessionEnd)

    func test_permissionRequest_sessionMismatch_entryIdle_replacesEntryAsBlocked() {
        // Regression: Codex has no SessionEnd hook, so a missed
        // SessionStart for a new session (IPC enabled mid-session, or
        // Calyx restarted) can leave a stale-but-idle entry sitting on a
        // pane. A mismatched PermissionRequest for the real new session
        // must rescue (replace) an idle entry rather than being discarded
        // — otherwise the approval-waiting state is invisible in the
        // sidebar. See `test_permissionRequest_sessionMismatch_discardedAndNotForwardMoving`
        // for the complementary case where the existing entry is `.working`
        // and must stay protected instead.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)

        registry.handleHookEvent(
            event("PermissionRequest", sessionID: "session-b", cwd: "/Users/dev/repo-b"),
            surfaceID: surfaceID
        )

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-b",
                       "A mismatched PermissionRequest must replace an idle entry")
        XCTAssertEqual(entry?.state, .blocked)
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-b")
    }

    func test_permissionRequest_sessionMismatch_entryDone_replacesEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done)

        registry.handleHookEvent(
            event("PermissionRequest", sessionID: "session-b", cwd: "/Users/dev/repo-b"),
            surfaceID: surfaceID
        )

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-b",
                       "A mismatched PermissionRequest must replace a done entry")
        XCTAssertEqual(entry?.state, .blocked)
    }

    func test_permissionRequest_sessionMismatch_entryBlocked_discardsEvent() {
        // Direct regression coverage (final review suggestion) for the
        // fourth combination alongside the idle/done rescue tests and
        // test_permissionRequest_sessionMismatch_discardedAndNotForwardMoving's
        // `.working` case: a `.blocked` entry must never be rescued by a
        // mismatched PermissionRequest either — the idle-only rescue guard
        // (`isPermissionRequestIdleRescue`) is `false` here, and `.blocked`
        // is not `.done`, so the event must be discarded and the entry left
        // exactly as it was.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleHookEvent(
            event("PermissionRequest", sessionID: "session-b", cwd: "/Users/dev/repo-b"),
            surfaceID: surfaceID
        )

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-a",
                       "A mismatched PermissionRequest must not replace a blocked entry")
        XCTAssertEqual(entry?.state, .blocked,
                       "State must remain unchanged when the mismatched PermissionRequest is discarded")
        XCTAssertEqual(entry?.cwd, "/Users/dev/project",
                       "cwd must remain unchanged too, confirming the entry was untouched, not just its state")
    }

    // MARK: - Agent kind (Phase 2: Codex / OpenCode)

    func test_handleHookEvent_kindParameter_appliesToNewEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleHookEvent(
            event("SessionStart", sessionID: "session-a"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )

        XCTAssertEqual(registry.entries[surfaceID]?.kind, AgentEntry.codexKind,
                       "An explicit kind must be applied to a freshly registered entry")
    }

    func test_handleHookEvent_kindParameter_defaultsToClaudeCodeAndIsPreservedAcrossSameSessionContinuation() {
        let registry = AgentRegistry()

        // No kind argument -> defaults to claude-code.
        let claudeSurfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: claudeSurfaceID)
        XCTAssertEqual(registry.entries[claudeSurfaceID]?.kind, AgentEntry.claudeCodeKind)

        // A different surface, given an explicit kind at SessionStart...
        let codexSurfaceID = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "session-b"),
            surfaceID: codexSurfaceID,
            kind: AgentEntry.codexKind
        )
        XCTAssertEqual(registry.entries[codexSurfaceID]?.kind, AgentEntry.codexKind,
                       "Precondition: SessionStart must apply the given kind")

        // ...must have that kind preserved by a same-session continuation
        // event that passes no kind argument (defaulting to claude-code).
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-b"), surfaceID: codexSurfaceID)

        XCTAssertEqual(registry.entries[codexSurfaceID]?.kind, AgentEntry.codexKind,
                       "Same-session continuation must preserve the entry's existing kind, " +
                       "not overwrite it with the continuation event's default kind")
    }

    func test_handleHookEvent_kindParameter_updatesOnSessionMismatchForwardMovingReplace() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.kind, AgentEntry.claudeCodeKind)

        registry.handleHookEvent(
            event("PreToolUse", sessionID: "session-b", cwd: "/Users/dev/repo-b"),
            surfaceID: surfaceID,
            kind: AgentEntry.openCodeKind
        )

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.sessionID, "session-b",
                       "Precondition: a forward-moving session mismatch must replace the entry")
        XCTAssertEqual(entry?.kind, AgentEntry.openCodeKind,
                       "A forward-moving session-mismatch replace must adopt the new event's kind")
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

    // MARK: - Round 3: handleScreenClassification (Herdr layer 2)

    func test_handleScreenClassification_hooksEntryUnaffected_titleHeuristicEntryReflectsClassification() {
        let registry = AgentRegistry()
        let hooksSurface = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: hooksSurface)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: hooksSurface)
        XCTAssertEqual(registry.entries[hooksSurface]?.state, .working,
                       "Precondition: a hooks-sourced entry must be working")

        let heuristicSurface = UUID()
        registry.handleTitleChange(surfaceID: heuristicSurface, title: "✳ Compacting conversation")
        XCTAssertEqual(registry.entries[heuristicSurface]?.source, .titleHeuristic,
                       "Precondition: a titleHeuristic entry must exist")

        registry.handleScreenClassification(surfaceID: hooksSurface, state: .blocked)
        registry.handleScreenClassification(surfaceID: heuristicSurface, state: .blocked)

        XCTAssertEqual(registry.entries[hooksSurface]?.state, .working,
                       "A screen classification must never override a hooks-sourced entry")
        XCTAssertEqual(registry.entries[heuristicSurface]?.state, .blocked,
                       "A screen classification must update a titleHeuristic-sourced entry")
    }

    func test_handleScreenClassification_titleHeuristicEntry_reflectsWorkingThenNilBecomesIdle() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "Precondition: a titleHeuristic entry starts working")

        registry.handleScreenClassification(surfaceID: surfaceID, state: .blocked)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A .blocked screen classification must update a titleHeuristic entry")

        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "A .working screen classification must update a titleHeuristic entry")

        registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A nil screen classification (no known pattern matched) must fall back to idle")
    }

    func test_handleScreenClassification_unregisteredSurface_createsEntryOnlyForBlockedOrWorking() {
        let registry = AgentRegistry()

        let blockedSurface = UUID()
        registry.handleScreenClassification(surfaceID: blockedSurface, state: .blocked)
        XCTAssertEqual(registry.entries[blockedSurface]?.state, .blocked,
                       "An unregistered surface classified as blocked must create a heuristic entry")

        let workingSurface = UUID()
        registry.handleScreenClassification(surfaceID: workingSurface, state: .working)
        XCTAssertEqual(registry.entries[workingSurface]?.state, .working,
                       "An unregistered surface classified as working must create a heuristic entry")

        let plainSurface = UUID()
        registry.handleScreenClassification(surfaceID: plainSurface, state: nil)
        XCTAssertNil(registry.entries[plainSurface],
                    "An unregistered surface with no recognized pattern must not create a row at all")
    }

    // MARK: - Round 3: handleProgressReport (OSC 9;4)

    func test_handleProgressReport_hooksEntryUnaffected_heuristicEntryReflectsActiveState() {
        let registry = AgentRegistry()
        let hooksSurface = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: hooksSurface)
        XCTAssertEqual(registry.entries[hooksSurface]?.state, .idle, "Precondition: hooks entry starts idle")

        let heuristicSurface = UUID()
        registry.handleTitleChange(surfaceID: heuristicSurface, title: "✳ Compacting conversation")
        XCTAssertEqual(registry.entries[heuristicSurface]?.state, .working,
                       "Precondition: heuristic entry starts working")

        registry.handleProgressReport(surfaceID: heuristicSurface, isActive: false)
        XCTAssertEqual(registry.entries[heuristicSurface]?.state, .idle,
                       "isActive=false must set a heuristic entry to idle")

        registry.handleProgressReport(surfaceID: heuristicSurface, isActive: true)
        XCTAssertEqual(registry.entries[heuristicSurface]?.state, .working,
                       "isActive=true must set a heuristic entry to working")

        registry.handleProgressReport(surfaceID: hooksSurface, isActive: true)
        XCTAssertEqual(registry.entries[hooksSurface]?.state, .idle,
                       "handleProgressReport must never override a hooks-sourced entry")
    }

    // MARK: - Round 3: hooksIssues

    func test_setHooksIssues_reflectsValue_andResetClears() {
        let registry = AgentRegistry()
        XCTAssertTrue(registry.hooksIssues.isEmpty, "Precondition: a fresh registry has no hooks issues")

        registry.setHooksIssues(["ClaudeHooksConfigManager: failed to write settings.json"])

        XCTAssertEqual(registry.hooksIssues, ["ClaudeHooksConfigManager: failed to write settings.json"],
                       "setHooksIssues must update the observable hooksIssues array")

        registry.reset()

        XCTAssertTrue(registry.hooksIssues.isEmpty, "reset() must clear hooksIssues")
    }

    // MARK: - Round 3: unread message badges (peer binding + updateInbox)

    func test_handleHookEvent_preToolUseWithIpcSelfPeerID_learnsBindingReflectedViaUpdateInbox() {
        let registry = AgentRegistry()
        let boundSurface = UUID()
        let peerID = UUID()
        // A PreToolUse for a calyx-ipc tool carries this surface's own
        // peer ID in ipcSelfPeerID — handleHookEvent must learn the
        // surface -> peer binding from it.
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: boundSurface
        )

        let unboundSurface = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-b"), surfaceID: unboundSurface)

        registry.updateInbox(peerID: peerID, count: 3)
        registry.updateInbox(peerID: UUID(), count: 99)  // an unknown / unbound peer

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 3,
                       "updateInbox must set unreadCount on the surface bound to this peer via PreToolUse")
        XCTAssertEqual(registry.entries[unboundSurface]?.unreadCount, 0,
                       "A peer with no bound surface must not affect any entry's unreadCount")
    }

    func test_updateInbox_bindingForgottenOnHandleSurfaceDestroyed() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.updateInbox(peerID: peerID, count: 5)
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 5,
                       "updateInbox must set unreadCount for the bound surface")

        registry.handleSurfaceDestroyed(surfaceID: surfaceID)
        XCTAssertNil(registry.entries[surfaceID], "Precondition: destroying the surface removes its entry")

        // Re-register the same surfaceID fresh and update the same peer's
        // inbox again: the old binding must have been forgotten, so the
        // fresh entry must not retroactively pick up the stale count.
        registry.handleHookEvent(event("SessionStart", sessionID: "session-c"), surfaceID: surfaceID)
        registry.updateInbox(peerID: peerID, count: 9)

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 0,
                       "A destroyed surface's peer binding must not survive its re-registration")
    }

    func test_updateInbox_bindingForgottenOnReset() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.updateInbox(peerID: peerID, count: 4)
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 4,
                       "updateInbox must set unreadCount for the bound surface before reset")

        registry.reset()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-d"), surfaceID: surfaceID)
        registry.updateInbox(peerID: peerID, count: 8)

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 0,
                       "reset() must forget peer bindings so a re-registered surface doesn't inherit the old peer's count")
    }

    // MARK: - Round 3 fix: register_peer PostToolUse binding + 1 peer = 1 surface

    func test_handleHookEvent_postToolUseRegisterPeerResponse_learnsBinding() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PostToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.updateInbox(peerID: peerID, count: 2)

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 2,
                       "A register_peer PostToolUse's self-reported peer ID must bind the surface " +
                       "immediately, before any other calyx-ipc tool call")
    }

    func test_bindSurface_newBindingForSamePeer_replacesOldSurfaceBinding() {
        // "1 peer = 1 surface": rebinding peerID to a new surface must
        // remove its previous surface's binding, not let both surfaces
        // receive updateInbox for the same peer.
        let registry = AgentRegistry()
        let peerID = UUID()
        let oldSurface = UUID()
        let newSurface = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: oldSurface
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-b", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: newSurface
        )

        registry.updateInbox(peerID: peerID, count: 7)

        XCTAssertEqual(registry.entries[newSurface]?.unreadCount, 7,
                       "The new surface must receive updateInbox for the rebound peer")
        XCTAssertEqual(registry.entries[oldSurface]?.unreadCount, 0,
                       "The old surface's stale binding must no longer receive updateInbox for this peer")
    }

    func test_bindSurface_doubleSteal_surfaceMovesToPeerThatHadADifferentSurface_endsAsCleanBijection() {
        // The "double-steal" case (post-review follow-up): surface A
        // moves off its own old peer P1 AND onto peer P2, where P2 was
        // itself already bound to a different surface B — both
        // invalidation branches of bindSurface fire in the same call.
        // The end state must be a true bijection: {A: P2} / {P2: A},
        // with P1 (A's stale peer) and B (P2's stale surface) fully
        // absent from both directions.
        let registry = AgentRegistry()
        let peer1 = UUID()
        let peer2 = UUID()
        let surfaceA = UUID()
        let surfaceB = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peer1.uuidString),
            surfaceID: surfaceA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-b", cwd: nil, message: nil,
                       ipcSelfPeerID: peer2.uuidString),
            surfaceID: surfaceB
        )

        // The double-steal: A rebinds to P2, the peer B is currently bound to.
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peer2.uuidString),
            surfaceID: surfaceA
        )

        registry.updateInbox(peerID: peer2, count: 9)
        registry.updateInbox(peerID: peer1, count: 99)

        XCTAssertEqual(registry.entries[surfaceA]?.unreadCount, 9,
                       "A must receive updateInbox for P2, the peer it just rebound to")
        XCTAssertEqual(registry.entries[surfaceB]?.unreadCount, 0,
                       "B's stale binding to P2 must be fully evicted — B must not receive P2's " +
                       "updateInbox anymore")

        XCTAssertEqual(Set(registry.boundPeerIDs), [peer2],
                       "Only P2 must remain bound after the double-steal: P1 (A's old peer) is fully " +
                       "evicted since A moved off it, proving both invalidation branches of " +
                       "bindSurface fired correctly in the same call")
    }

    // MARK: - Round 3: boundPeerIDs / syncInboxCounts (batch badge sync)

    func test_boundPeerIDs_reflectsEveryCurrentlyBoundPeer() {
        let registry = AgentRegistry()
        let peerA = UUID()
        let peerB = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerA.uuidString),
            surfaceID: UUID()
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-b", cwd: nil, message: nil,
                       ipcSelfPeerID: peerB.uuidString),
            surfaceID: UUID()
        )

        XCTAssertEqual(Set(registry.boundPeerIDs), Set([peerA, peerB]))
    }

    func test_syncInboxCounts_appliesCountPerBoundSurface_skipsUnboundPeers() {
        let registry = AgentRegistry()
        let boundSurfaceA = UUID()
        let boundSurfaceB = UUID()
        let peerA = UUID()
        let peerB = UUID()
        let unboundPeer = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerA.uuidString),
            surfaceID: boundSurfaceA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-b", cwd: nil, message: nil,
                       ipcSelfPeerID: peerB.uuidString),
            surfaceID: boundSurfaceB
        )

        registry.syncInboxCounts([peerA: 3, peerB: 5, unboundPeer: 99])

        XCTAssertEqual(registry.entries[boundSurfaceA]?.unreadCount, 3)
        XCTAssertEqual(registry.entries[boundSurfaceB]?.unreadCount, 5)
    }

    func test_syncInboxCounts_purgedPeerNotInCounts_leavesLastKnownCountUnchanged() {
        // Regression: syncing against a counts map that no longer
        // includes a since-purged peer must not silently reset that
        // surface's badge — the batch sync only ever applies counts it
        // was actually given for a peer it still has a binding for.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.updateInbox(peerID: peerID, count: 4)
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 4)

        registry.syncInboxCounts([:])

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 4,
                       "An empty/unrelated counts map must not zero out a surface's last known unreadCount")
    }

    // MARK: - Round 3 fix: heuristic row retirement (miss-streak)

    func test_handleScreenClassification_fiveConsecutiveNilMisses_removesHeuristicRow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        XCTAssertNotNil(registry.entries[surfaceID], "Precondition: a titleHeuristic row must exist")

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID],
                        "4 consecutive nil misses (below the 5-miss threshold) must not remove the row yet")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)

        registry.handleScreenClassification(surfaceID: surfaceID, state: nil)

        XCTAssertNil(registry.entries[surfaceID],
                     "The 5th consecutive nil miss must retire (remove) the heuristic row")
    }

    func test_handleScreenClassification_missStreakResetByPositiveScreenSignal() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID], "Precondition: row survives 4 misses")

        // A .blocked/.working screen classification is a "positive"
        // signal that resets the miss streak back to 0.
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID],
                        "The reset streak must require a fresh 5 consecutive misses, " +
                        "not continue accumulating from before the reset")
    }

    func test_handleScreenClassification_missStreakResetByTitleWorkingSignal() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID], "Precondition: row survives 4 misses")

        // A .working title classification (the spinner glyph) is also a
        // "positive" signal that resets the miss streak.
        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID],
                        "A title-heuristic working signal must reset the miss streak")
    }

    func test_handleScreenClassification_missStreakResetByProgressActiveSignal() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID], "Precondition: row survives 4 misses")

        // An isActive=true progress report is also a "positive" signal
        // that resets the miss streak.
        registry.handleProgressReport(surfaceID: surfaceID, isActive: true)

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID],
                        "A progress-report active signal must reset the miss streak")
    }

    func test_handleSurfaceDestroyed_forgetsMissStreak_freshRegistrationStartsClean() {
        // Regression ("REMOVE overwrite"): a destroyed surface's prior
        // miss-streak bookkeeping must not leak into a fresh registration
        // for the same surfaceID and cause it to be retired prematurely.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID], "Precondition: row survives 4 misses")

        registry.handleSurfaceDestroyed(surfaceID: surfaceID)
        XCTAssertNil(registry.entries[surfaceID])

        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }

        XCTAssertNotNil(registry.entries[surfaceID],
                        "A fresh registration after handleSurfaceDestroyed must start with a clean miss " +
                        "streak, not inherit the 4 misses accumulated before destruction")
    }

    func test_handleHookEvent_forgetsHeuristicMissStreak() {
        // A hook event promoting a titleHeuristic row (or registering a
        // fresh hooks row) must clear any stale heuristic miss-streak
        // bookkeeping for that surface.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.source, .hooks,
                       "Precondition: the hook event must promote/replace the row as .hooks-sourced")

        // Demote back to a fresh heuristic row the only way possible —
        // destroy and re-create — to observe whether the miss streak from
        // before the hook event leaked through.
        registry.handleSurfaceDestroyed(surfaceID: surfaceID)
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }

        XCTAssertNotNil(registry.entries[surfaceID],
                        "A fresh heuristic row must not inherit a miss streak left over from before " +
                        "the surface was promoted to .hooks")
    }

    // MARK: - Round 3 fix: heuristic signal arbitration (blocked protection)

    func test_applyHeuristicState_blockedNotClearedByNonAuthoritativeProgressReport() {
        // Regression: a titleHeuristic row's .blocked state (set by a
        // screen classification that saw an approval prompt) must not be
        // cleared by a lower-confidence progress-report signal going
        // inactive — only a screen classification's own non-blocked
        // result may clear it.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .blocked)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleProgressReport(surfaceID: surfaceID, isActive: false)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A progress-report isActive=false must not clear a .blocked heuristic row")
    }

    func test_applyHeuristicState_blockedNotClearedByNonAuthoritativeTitleChange() {
        // Regression: same protection against a title-heuristic signal
        // (spinner glyph, i.e. "still working") flapping a .blocked row
        // back to .working.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .blocked)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A title-heuristic working signal must not clear a .blocked heuristic row")
    }

    func test_applyHeuristicState_blockedClearedOnlyByAuthoritativeScreenNilResult() {
        // The complementary case: a screen classification's own miss
        // (nil, falling back to idle) — the authoritative source — DOES
        // clear .blocked, unlike the non-authoritative signals above.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .blocked)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleScreenClassification(surfaceID: surfaceID, state: nil)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A screen classification's own non-blocked (nil -> idle) result must clear .blocked")
    }

    func test_applyHeuristicState_sameStateWriteDoesNotRefreshLastEventAt() {
        // (a) "don't write an identical state" — verified indirectly via
        // lastEventAt, since AgentEntry equality would otherwise make a
        // same-state no-op write unobservable.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        let firstEventAt = registry.entries[surfaceID]?.lastEventAt

        // Re-applying the identical state must not bump lastEventAt.
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)

        XCTAssertEqual(registry.entries[surfaceID]?.lastEventAt, firstEventAt,
                       "Writing the same state again must not refresh lastEventAt (no-op write)")
    }
}
