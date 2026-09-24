//
//  AgentRegistryTests.swift
//  CalyxTests
//
//  Tests for AgentRegistry: hook-event state transitions, session
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

    // MARK: - MCP connection presence

    func test_mcpConnection_registersIdleCodexEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .mcpConnection)
        XCTAssertEqual(entry?.kind, AgentEntry.codexKind)
        XCTAssertEqual(entry?.state, .idle)
        XCTAssertNil(entry?.sessionID)
    }

    func test_mcpConnection_screenClassificationUpdatesStateWithoutRetiringPresence() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working)

        for _ in 0..<6 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)
        XCTAssertEqual(
            registry.entries[surfaceID]?.source,
            .mcpConnection,
            "An initialized MCP connection is stronger presence evidence than an unrecognized idle screen"
        )
    }

    func test_hookEventPromotesMCPConnectionEntryToAuthoritativeHooksEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        registry.handleHookEvent(
            event("SessionStart", sessionID: "codex-session", cwd: "/Users/dev/repo"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .hooks)
        XCTAssertEqual(entry?.sessionID, "codex-session")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo")
    }

    func test_repeatedMCPConnectionDoesNotDowngradeSameAgentHooksEntry() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "codex-session"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        XCTAssertEqual(registry.entries[surfaceID]?.source, .hooks)
        XCTAssertEqual(registry.entries[surfaceID]?.sessionID, "codex-session")
    }

    func test_handleMCPConnection_doneHooksEntrySameKind_becomesLiveIdleEntryPreservingCwd() {
        // A `.hooks` entry can be `.done`: a pane holding a finished row
        // that starts a fresh agent whose hook entries have not run yet
        // reports only through this MCP `initialize` call, so
        // `handleMCPConnection`'s early return must not strand that live
        // agent at `.done`.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "codex-session", cwd: "/Users/dev/repo"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )
        registry.handleHookEvent(
            event("SessionEnd", sessionID: "codex-session"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the session ended")

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .idle,
                       "A same-kind MCP initialize must move a done row off done, not leave a live " +
                       "agent showing a finished session")
        XCTAssertEqual(entry?.source, .mcpConnection)
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo",
                       "cwd must carry over from the replaced entry (a fresh insert would set it nil), " +
                       "which is what distinguishes this from losing the pane's directory")
    }

    func test_handleMCPConnection_workingHooksEntrySameKind_isLeftUntouched() {
        // Companion to the done case above: a same-kind hooks entry that
        // is still genuinely active must keep the early-return protection
        // this method was written for.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "codex-session", cwd: "/Users/dev/repo"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )
        registry.handleHookEvent(
            event("UserPromptSubmit", sessionID: "codex-session"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition")

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .hooks,
                       "A same-kind hooks entry that is not done must remain authoritative over a " +
                       "repeated MCP initialize")
        XCTAssertEqual(entry?.state, .working)
        XCTAssertEqual(entry?.sessionID, "codex-session")
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

    func test_sessionStart_sameSurfaceSameSession_doneEntryRevivesToIdle() {
        // A Codex session that ended (SessionEnd -> .done) can be resumed
        // in the same pane (`codex resume --last`), which re-sends
        // SessionStart carrying the same session_id. A resumed session is
        // live again, so unlike working/blocked this same-session branch
        // must not preserve .done.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/repo-a"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .idle,
                       "A same-session SessionStart after SessionEnd is a resumed, live session and " +
                       "must not stay done")
        XCTAssertEqual(entry?.sessionID, "session-a")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-a")
        XCTAssertEqual(registry.entries.count, 1)
    }

    func test_sessionStart_sameSurfaceSameSession_workingEntryKeepsWorking() {
        // Companion to the done-revival case above: pins that giving
        // done its own handling does not touch the protection this
        // branch exists for. See
        // test_sessionStart_sameSurfaceSameSession_preservesStateAndRefreshesCwd.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition")

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/repo-a"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .working,
                       "A same-session SessionStart must still preserve a working entry's state")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-a")
    }

    func test_sessionStart_sameSurfaceSameSession_blockedEntryKeepsBlocked() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(
            event("Notification", sessionID: "session-a", message: "needs your permission"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked, "Precondition")

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/repo-a"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .blocked,
                       "A same-session SessionStart must still preserve a blocked entry's state")
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo-a")
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
        // The hooks config's
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

    func test_handleHookEvent_sameSessionStopAfterSessionEnd_leavesRowDone() {
        // calyx-agent-hook's command entries run "async": true, so a
        // turn's own Stop can land at the server after the exit path's
        // SessionEnd already arrived (the same out-of-order delivery the
        // 1.5s PreToolUse race guard in handleHookEvent protects .blocked
        // against). The unconditional `updated.state = newState` this
        // same-session path ends in must not let that late Stop roll a
        // done row back to idle: that is the stuck-green symptom
        // SessionEnd -> .done exists to fix. A same-session SessionStart
        // still revives a done row (see
        // test_sessionStart_sameSurfaceSameSession_doneEntryRevivesToIdle)
        // and a session mismatch still replaces one (see
        // test_sessionMismatch_entryDone_replacesEntry); neither is
        // affected by this guard.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "A same-session Stop arriving after SessionEnd must not roll a done row back to idle")
    }

    // MARK: - A child event under a settled or absent parent row creates no child

    /// `calyx-agent-hook` POSTs are independent fire-and-forget `curl`
    /// processes, so a child's own event can complete its POST AFTER the
    /// parent's terminal event, even though the child fired first. Once
    /// the parent has settled `.done`, nothing will ever sweep a child
    /// created under it: the CLI has exited, so no further Stop/
    /// SessionEnd/SessionStart will arrive, `resolveStaleSweep` never
    /// touches children, and a `.done` row itself needs no more writes.
    func test_handleHookEvent_subagentEvent_afterParentSettledDoneViaSessionEnd_createsNoChild() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the parent settled done")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )

        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                       "A subagent event arriving after the parent settled done must create no child")
    }

    func test_handleHookEvent_subagentEvent_afterParentSettledDoneViaPaneCommandFinished_createsNoChild() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handlePaneCommandFinished(surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the parent settled done")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )

        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                       "A subagent event arriving after the parent settled done via the pane-exit signal " +
                       "must create no child")
    }

    func test_handleHookEvent_subagentEvent_surfaceWithNoRowAtAll_createsNoChild() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        XCTAssertNil(registry.entries[surfaceID], "Precondition: no row at all for this surface")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )

        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                       "A subagent event for a surface with no row at all must create no child")
    }

    func test_handleHookEvent_parentScopedSweepEvent_stillClearsChildrenEvenWithNoRow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1, "Precondition: a live child")
        registry.handleSurfaceDestroyed(surfaceID: surfaceID)
        XCTAssertNil(registry.entries[surfaceID], "Precondition: the surface now has no row at all")

        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                       "A parent-scoped sweep event must still clear children even with no row, so the sweep " +
                       "path is not caught by the child-creation guard")
    }

    func test_handleHookEvent_subagentEvent_underLiveParentRow_stillCreatesAndUpdatesChild() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition: a live, non-done parent row")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "A subagent event under a live parent row must still create a child")
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).first?.state, .working)

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: nil, toolName: "Bash"),
            surfaceID: surfaceID
        )

        let child = registry.subagentRegistry.children(of: surfaceID).first
        XCTAssertEqual(child?.lastToolName, "Bash", "A subagent event under a live parent row must still update the child")
    }

    // MARK: - A parent-scoped sweep event the resolver rejects must not clear children

    // A child's lifetime follows the resolver's own acceptance of the
    // parent-scoped event that would retire it: `AgentStateResolver
    // .resolveHook` only marks a `SessionEnd`/`SessionStart` -- never a
    // `Stop`, which no longer retires children at all -- as retiring
    // the surface's children (`AgentResolution.retiresChildren`) when
    // it also accepted that event for the parent row. A
    // session-mismatched `SessionEnd` -- absent from
    // `forwardMovingEventNames`, and arriving for a row that is not
    // `.done` -- is exactly the case `AgentStateResolver.resolveHookRow`'s
    // session-mismatch guard rejects (`.keep`, parent row untouched):
    // Codex reports `agent_id` only on `SubagentStart`/`SubagentStop`,
    // so its `Stop`/`SessionEnd` carry no `agent_id` at all and reach
    // this guard directly. The children below must survive a sweep
    // event the resolver itself rejected.

    func test_handleHookEvent_rejectedMismatchedSessionSessionEnd_doesNotClearChildren() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("PreToolUse", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a live, non-done parent row")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1, "Precondition: a live child")

        // session-b never matches this row's own session-a: SessionEnd
        // is absent from forwardMovingEventNames, and the row is not
        // .done, so AgentStateResolver.resolveHookRow's session-mismatch
        // guard discards this event entirely.
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-b"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "Precondition: the resolver must actually reject the mismatched SessionEnd, leaving " +
                       "the parent row untouched -- otherwise this test proves nothing about the rejected case")
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "A SessionEnd AgentStateResolver rejected for the parent row must not clear the " +
                       "parent's children either -- SubagentRegistry.handleHookEvent's sweep must not run " +
                       "for an event the resolver discarded")
    }

    func test_handleHookEvent_rejectedMismatchedSessionStop_doesNotClearChildren() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("PreToolUse", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a live, non-done parent row")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1, "Precondition: a live child")

        // Stop is likewise absent from forwardMovingEventNames, so a
        // mismatched-session Stop on a non-done row is discarded the
        // same way.
        registry.handleHookEvent(event("Stop", sessionID: "session-b"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "Precondition: the resolver must actually reject the mismatched Stop, leaving the " +
                       "parent row untouched -- otherwise this test proves nothing about the rejected case")
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "A Stop AgentStateResolver rejected for the parent row must not clear the parent's " +
                       "children either -- SubagentRegistry.handleHookEvent's sweep must not run for an " +
                       "event the resolver discarded")
    }

    // MARK: - Same-session parent-scoped events: Stop leaves children in place, SessionStart still clears them

    // An accepted, same-session Stop settles the parent row to .idle
    // exactly as before but no longer sweeps the surface's children: a
    // still-running child is left in place, since the CLI itself keeps
    // reporting it running past its own turn ending (the real captured
    // Claude Code sequence this was found from). An accepted, same-
    // session SessionStart re-send is unconditionally accepted and
    // still clears every child of that parent.

    func test_handleHookEvent_acceptedSameSessionStop_settlesRowButLeavesChildrenInPlace() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1, "Precondition: a live child")

        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "An accepted, same-session Stop must still settle the row to idle")
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "An accepted, same-session Stop must no longer clear the parent's children")
    }

    /// The child a same-session Stop leaves in place is left wholly
    /// untouched by it, `startedAt` included: nothing about the parent's
    /// own turn ending is a report about when this child itself began.
    func test_handleHookEvent_acceptedSameSessionStop_leavesEveryChildsStartedAtUnchanged() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let creationTime = Date(timeIntervalSince1970: 1_000)
        let stopTime = Date(timeIntervalSince1970: 2_000)

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: creationTime)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID, now: creationTime
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-2", agentType: "explore"),
            surfaceID: surfaceID, now: creationTime
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 2, "Precondition: two live children")

        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: surfaceID, now: stopTime)

        let remaining = registry.subagentRegistry.children(of: surfaceID)
        XCTAssertEqual(remaining.count, 2,
                       "An accepted, same-session Stop must no longer clear the parent's children")
        for child in remaining {
            XCTAssertEqual(child.startedAt, creationTime, "A child's startedAt must be untouched by the parent Stop")
        }
    }

    func test_handleHookEvent_acceptedParentScopedStopWithNoRowAtAll_autoRegistersIdleRow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        XCTAssertNil(registry.entries[surfaceID], "Precondition: no row at all for this surface")

        // Stop is accepted even for a surface with no row at all --
        // AgentStateResolver.resolveHookRow's own auto-registration path
        // (`guard let existing = current, ... else { ... return
        // .write(makeEntry(state: newState), ...) }`) creates one.
        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A parent-scoped Stop the resolver accepts must still auto-register a fresh row " +
                       "for a surface that had none")
    }

    func test_handleHookEvent_acceptedSameSessionStart_clearsChildren() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1, "Precondition: a live child")

        // A re-sent SessionStart for the SAME session is unconditionally
        // accepted by AgentStateResolver.resolveHookRow -- no source
        // guard, no session guard, no terminal-state guard -- so it must
        // keep clearing children exactly as any other SessionStart does.
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "Precondition: the same-session SessionStart re-send is accepted")
        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                       "An accepted, same-session SessionStart re-send must still clear every child of " +
                       "the parent")
    }

    // MARK: - Accepted parent-scoped sweeps clear only that parent's children

    // A resolver-accepted parent-scoped sweep -- a same-session
    // SessionEnd/SessionStart, or a session-mismatch row replacement
    // that hands a surface to a different session -- must clear every
    // child of the parent whose row it wrote, and leave a DIFFERENT
    // parent's children completely untouched. Driven through the full
    // AgentRegistry pipeline (AgentRegistry.handleHookEvent), since the
    // children-retiring decision lives in AgentStateResolver.resolveHook
    // and SubagentRegistry itself knows no parent event name.

    func test_handleHookEvent_acceptedParentStop_leavesEveryParentsChildrenInPlace() {
        let registry = AgentRegistry()
        let parentA = UUID()
        let parentB = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: parentA)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-b"), surfaceID: parentB)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: parentA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-b", cwd: nil, message: nil,
                       agentID: "sub-2", agentType: "explore"),
            surfaceID: parentB
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: parentA).count, 1, "Precondition: a live child")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1, "Precondition: a live child")

        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: parentA)

        XCTAssertEqual(registry.entries[parentA]?.state, .idle,
                       "An accepted, same-session Stop must still settle the row to idle")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentA).count, 1,
                       "An accepted, same-session Stop must no longer remove any child of that parent")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1,
                       "A different parent's children must be untouched")
    }

    func test_handleHookEvent_acceptedParentSessionEnd_removesEveryChildOfThatParent_andNoOtherParents() {
        let registry = AgentRegistry()
        let parentA = UUID()
        let parentB = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: parentA)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-b"), surfaceID: parentB)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: parentA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-b", cwd: nil, message: nil,
                       agentID: "sub-2", agentType: "explore"),
            surfaceID: parentB
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: parentA).count, 1, "Precondition: a live child")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1, "Precondition: a live child")

        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: parentA)

        XCTAssertTrue(registry.subagentRegistry.children(of: parentA).isEmpty,
                      "An accepted, same-session SessionEnd must remove every child of that parent")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1,
                       "A different parent's children must be untouched")
    }

    /// A forward-moving event for a session that does not match the
    /// row's own -- accepted by `AgentStateResolver.resolveHookRow`'s
    /// session-mismatch branch, which replaces the row wholesale --
    /// must retire the OLD session's children: a different sessionID
    /// now owns the surface, so that CLI process is gone and its own
    /// `SubagentStop` can never arrive. This is the regression this
    /// branch introduced: before it, the next parent `Stop` bounded a
    /// lost `SessionStart`'s leak to one turn; now nothing but this
    /// sweep bounds it.
    func test_handleHookEvent_acceptedSessionMismatchReplacement_removesOldSessionsChildren_andNoOtherParents() {
        let registry = AgentRegistry()
        let parentA = UUID()
        let parentB = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: parentA)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-b"), surfaceID: parentB)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: parentA
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-b", cwd: nil, message: nil,
                       agentID: "sub-2", agentType: "explore"),
            surfaceID: parentB
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: parentA).count, 1, "Precondition: a live child")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1, "Precondition: a live child")

        // parentA's SessionStart POST was lost; its first PreToolUse for
        // the new session arrives instead and replaces the row.
        registry.handleHookEvent(event("PreToolUse", sessionID: "session-a2"), surfaceID: parentA)

        XCTAssertEqual(registry.entries[parentA]?.sessionID, "session-a2",
                       "Precondition: the mismatched, forward-moving event replaced the row")
        XCTAssertTrue(registry.subagentRegistry.children(of: parentA).isEmpty,
                      "An accepted session-mismatch row replacement must remove the OLD session's children")
        XCTAssertEqual(registry.subagentRegistry.children(of: parentB).count, 1,
                       "A different parent's children must be untouched")
    }

    /// The other half of `SubagentRegistryTests.test_subagentStopWithNoAgentID_removesNothing`'s
    /// original degrade case: a CLI that omits `agent_id` on its own
    /// `SubagentStop` still loses the lingering child once an ACCEPTED
    /// parent-scoped `SessionEnd`/`SessionStart` retires it, rather than
    /// leaking it forever. An accepted `Stop` no longer retires
    /// children at all, so it is deliberately NOT what closes this
    /// degrade case anymore -- the child must survive one first.
    func test_handleHookEvent_subagentStopWithNoAgentID_childSurvivesStopButGoesAwayOnAcceptedParentSessionEnd() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1, "Precondition: a live child")

        // A SubagentStop that carries no agentID is not a subagent event
        // and must remove nothing on its own.
        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStop", sessionID: "session-a", cwd: nil, message: nil, agentID: nil),
            surfaceID: surfaceID
        )
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "A SubagentStop with no agentID identifies no child, so nothing may be removed")

        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "An accepted parent Stop must no longer retire the lingering child")

        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                      "The lingering child still goes away once the parent's own accepted SessionEnd " +
                      "retires it -- degrade, not leak")
    }

    /// The corollary of the guard above: `handleMCPConnection` replacing
    /// a `.done` row with a live one must not surface a phantom child
    /// left over from the previous session. Nothing special is needed
    /// for this -- the guard already blocks every subagent event that
    /// arrives while the row reads `.done`, so no child can ever exist
    /// to surface once the row revives.
    func test_handleMCPConnection_reviveFromDone_neverSurfacesAPhantomChildFromThePreviousSession() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handlePaneCommandFinished(surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the parent settled done")

        registry.handleHookEvent(
            AgentEvent(hookEventName: "SubagentStart", sessionID: "session-a", cwd: nil, message: nil,
                       agentID: "sub-1", agentType: "explore"),
            surfaceID: surfaceID
        )
        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                       "Precondition: a subagent event after done creates no child")

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition: the row revived live")
        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                       "A row revived from .done must never surface a phantom child from the previous session")
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
        // A forward-moving event
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
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
        let surfaceID = UUID()
        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")
        XCTAssertEqual(registry.entries.count, 1,
                       "Precondition: a titleHeuristic entry must have been created")

        registry.handleSurfaceDestroyed(surfaceID: surfaceID)

        XCTAssertTrue(registry.entries.isEmpty)
        registry.reset()
    }

    // MARK: - Title heuristic fallback

    func test_handleTitleChange_unregisteredSurfaceWorkingTitle_createsTitleHeuristicEntry() {
        let registry = AgentRegistry()
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
        let surfaceID = UUID()

        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .titleHeuristic)
        XCTAssertEqual(entry?.state, .working)
        registry.reset()
    }

    func test_handleTitleChange_serverNotRunning_neverCreatesARow() {
        // Regression pin for the herdr-connected + IPC-disabled
        // combination: an external (herdr) row keeps the Agents sidebar
        // visible (AgentSidebarGate) even while isServerRunning is
        // false, so without the guard a title-change notification
        // arriving in that state would create a .titleHeuristic row with
        // no way to ever retire (see handleTitleChange's own doc comment
        // for the full reasoning).
        let registry = AgentRegistry()
        XCTAssertFalse(registry.isServerRunning, "Precondition: a fresh registry has the server stopped")
        registry.upsertExternalEntry(AgentEntry(
            surfaceID: UUID(), sessionID: nil, source: .external, state: .working,
            cwd: "/Users/dev/herdr-project", kind: AgentEntry.claudeCodeKind, lastEventAt: Date()
        ))
        XCTAssertTrue(registry.hasExternalEntries, "Precondition: a herdr row is present")
        let surfaceID = UUID()

        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        XCTAssertNil(registry.entries[surfaceID],
                     "handleTitleChange must not create a row while isServerRunning is false, " +
                     "even with a herdr row keeping the sidebar itself visible")
        XCTAssertTrue(registry.entries.isEmpty)
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
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
        let surfaceID = UUID()
        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")
        XCTAssertEqual(registry.entries[surfaceID]?.source, .titleHeuristic)

        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .hooks,
                       "The first hook event must promote a titleHeuristic entry to hooks")
        XCTAssertEqual(registry.entries.count, 1, "Promotion must replace, not add, the entry")
        registry.reset()
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
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
        let surfaceID = UUID()

        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        XCTAssertEqual(registry.entries[surfaceID]?.kind, "claude-code")
        registry.reset()
    }

    // MARK: - PermissionRequest (Codex)

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

    // MARK: - PermissionRequest session-mismatch rescue (missed SessionStart)

    func test_permissionRequest_sessionMismatch_entryIdle_replacesEntryAsBlocked() {
        // Regression: a missed SessionStart (IPC enabled mid-session or
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

    // MARK: - Agent kind (Codex / OpenCode)

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

    // MARK: - handleScreenClassification (Herdr layer 2)

    func test_handleScreenClassification_hooksEntryUnaffected_titleHeuristicEntryReflectsClassification() {
        let registry = AgentRegistry()
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
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
        registry.reset()
    }

    func test_handleScreenClassification_titleHeuristicEntry_reflectsWorkingThenNilBecomesIdle() {
        let registry = AgentRegistry()
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
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
        registry.reset()
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

    // MARK: - handleProgressReport (OSC 9;4)

    func test_handleProgressReport_hooksEntryUnaffected_heuristicEntryReflectsActiveState() {
        let registry = AgentRegistry()
        // handleTitleChange only creates a row while the server
        // is running -- see that method's own doc comment.
        registry.markServerStarted()
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
        registry.reset()
    }

    // MARK: - hooksIssues

    func test_setHooksIssues_reflectsValue_andResetClears() {
        let registry = AgentRegistry()
        XCTAssertTrue(registry.hooksIssues.isEmpty, "Precondition: a fresh registry has no hooks issues")

        registry.setHooksIssues(["ClaudeHooksConfigManager: failed to write settings.json"])

        XCTAssertEqual(registry.hooksIssues, ["ClaudeHooksConfigManager: failed to write settings.json"],
                       "setHooksIssues must update the observable hooksIssues array")

        registry.reset()

        XCTAssertTrue(registry.hooksIssues.isEmpty, "reset() must clear hooksIssues")
    }

    // MARK: - configIssues and integrationIssues

    func test_setConfigIssues_reflectsValue_andResetClears() {
        let registry = AgentRegistry()
        XCTAssertTrue(registry.configIssues.isEmpty, "Precondition: a fresh registry has no config issues")

        registry.setConfigIssues(["Claude Code config: permission denied"])

        XCTAssertEqual(registry.configIssues, ["Claude Code config: permission denied"],
                       "setConfigIssues must update the observable configIssues array")

        registry.reset()

        XCTAssertTrue(registry.configIssues.isEmpty, "reset() must clear configIssues")
    }

    func test_integrationIssues_combinesConfigAndHooksIndependently() {
        let registry = AgentRegistry()

        registry.setConfigIssues(["Claude Code config: permission denied"])
        registry.setHooksIssues(["Grok hooks: permission denied"])

        XCTAssertEqual(registry.integrationIssues, ["Claude Code config: permission denied", "Grok hooks: permission denied"],
                       "integrationIssues must union both domains, config first, with neither producer's write erasing the other's")

        registry.setHooksIssues([])

        XCTAssertEqual(registry.integrationIssues, ["Claude Code config: permission denied"],
                       "Clearing one domain must not erase the other domain's still-standing issues")

        registry.reset()
    }

    // MARK: - serverIssues (not cleared by reset())

    func test_setServerIssues_reflectsValue_andResetDoesNotClear() {
        let registry = AgentRegistry()
        XCTAssertTrue(registry.serverIssues.isEmpty, "Precondition: a fresh registry has no server issues")

        registry.setServerIssues(["Failed to generate secure token."])

        XCTAssertEqual(registry.serverIssues, ["Failed to generate secure token."],
                       "setServerIssues must update the observable serverIssues array")

        registry.reset()

        XCTAssertEqual(registry.serverIssues, ["Failed to generate secure token."],
                       "reset() must NOT clear serverIssues -- it is not called immediately after a start failure, " +
                       "so clearing it here would erase the banner while the failure is still true")
    }

    // MARK: - Unread message badges (peer binding + syncInboxCounts)

    func test_handleHookEvent_preToolUseWithIpcSelfPeerID_learnsBindingReflectedViaSyncInboxCounts() {
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

        registry.syncInboxCounts([peerID: 3])
        registry.syncInboxCounts([UUID(): 99])  // an unknown / unbound peer

        XCTAssertEqual(registry.entries[boundSurface]?.unreadCount, 3,
                       "syncInboxCounts must set unreadCount on the surface bound to this peer via PreToolUse")
        XCTAssertEqual(registry.entries[unboundSurface]?.unreadCount, 0,
                       "A peer with no bound surface must not affect any entry's unreadCount")
    }

    func test_peerBinding_forgottenOnHandleSurfaceDestroyed() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.syncInboxCounts([peerID: 5])
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 5,
                       "syncInboxCounts must set unreadCount for the bound surface")

        registry.handleSurfaceDestroyed(surfaceID: surfaceID)
        XCTAssertNil(registry.entries[surfaceID], "Precondition: destroying the surface removes its entry")

        // Re-register the same surfaceID fresh and update the same peer's
        // inbox again: the old binding must have been forgotten, so the
        // fresh entry must not retroactively pick up the stale count.
        registry.handleHookEvent(event("SessionStart", sessionID: "session-c"), surfaceID: surfaceID)
        registry.syncInboxCounts([peerID: 9])

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 0,
                       "A destroyed surface's peer binding must not survive its re-registration")
    }

    func test_peerBinding_forgottenOnReset() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.syncInboxCounts([peerID: 4])
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 4,
                       "syncInboxCounts must set unreadCount for the bound surface before reset")

        registry.reset()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-d"), surfaceID: surfaceID)
        registry.syncInboxCounts([peerID: 8])

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 0,
                       "reset() must forget peer bindings so a re-registered surface doesn't inherit the old peer's count")
    }

    // MARK: - register_peer PostToolUse binding + 1 peer = 1 surface

    func test_handleHookEvent_postToolUseRegisterPeerResponse_learnsBinding() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()

        registry.handleHookEvent(
            AgentEvent(hookEventName: "PostToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.syncInboxCounts([peerID: 2])

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 2,
                       "A register_peer PostToolUse's self-reported peer ID must bind the surface " +
                       "immediately, before any other calyx-ipc tool call")
    }

    func test_bindSurface_newBindingForSamePeer_replacesOldSurfaceBinding() {
        // "1 peer = 1 surface": rebinding peerID to a new surface must
        // remove its previous surface's binding, not let both surfaces
        // receive that peer's inbox count.
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

        registry.syncInboxCounts([peerID: 7])

        XCTAssertEqual(registry.entries[newSurface]?.unreadCount, 7,
                       "The new surface must receive the rebound peer's inbox count")
        XCTAssertEqual(registry.entries[oldSurface]?.unreadCount, 0,
                       "The old surface's stale binding must no longer receive this peer's inbox count")
    }

    func test_bindSurface_doubleSteal_surfaceMovesToPeerThatHadADifferentSurface_endsAsCleanBijection() {
        // The "double-steal" case: surface A
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

        registry.syncInboxCounts([peer2: 9])
        registry.syncInboxCounts([peer1: 99])

        XCTAssertEqual(registry.entries[surfaceA]?.unreadCount, 9,
                       "A must receive P2's inbox count, the peer it just rebound to")
        XCTAssertEqual(registry.entries[surfaceB]?.unreadCount, 0,
                       "B's stale binding to P2 must be fully evicted — B must not receive P2's " +
                       "inbox count anymore")

        XCTAssertEqual(Set(registry.boundPeerIDs), [peer2],
                       "Only P2 must remain bound after the double-steal: P1 (A's old peer) is fully " +
                       "evicted since A moved off it, proving both invalidation branches of " +
                       "bindSurface fired correctly in the same call")
    }

    // MARK: - boundPeerIDs / syncInboxCounts (batch badge sync)

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
        registry.syncInboxCounts([peerID: 4])
        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 4)

        registry.syncInboxCounts([:])

        XCTAssertEqual(registry.entries[surfaceID]?.unreadCount, 4,
                       "An empty/unrelated counts map must not zero out a surface's last known unreadCount")
    }

    // MARK: - Heuristic row retirement (miss-streak)

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
        // handleTitleChange (called below, on an already-existing
        // titleHeuristic row) only resets the miss streak while the
        // server is running -- see that method's own doc comment. The
        // row itself is created via handleScreenClassification, which
        // does not gate row creation on the server running.
        registry.markServerStarted()
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
        registry.reset()
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

    // MARK: - Heuristic signal arbitration (blocked protection)

    func test_heuristicApply_blockedNotClearedByNonAuthoritativeProgressReport() {
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

    func test_heuristicApply_blockedNotClearedByNonAuthoritativeTitleChange() {
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

    func test_heuristicApply_blockedClearedOnlyByAuthoritativeScreenNilResult() {
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

    func test_heuristicApply_sameStateWriteDoesNotRefreshLastEventAt() {
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

    // MARK: - Async-delivery race guard for a just-blocked entry

    func test_handleHookEvent_lateArrivingPreToolUseWithin1_5sOfBlocked_doesNotOverwriteBlocked() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        // A PreToolUse arriving 1.0s later (inside the 1.5s race window)
        // must not clobber the blocked state — see handleHookEvent's own
        // comment on the async-delivery race this guards against.
        registry.handleHookEvent(event("PreToolUse"), surfaceID: surfaceID, now: base.addingTimeInterval(1.0))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A PreToolUse landing within 1.5s of the blocked transition must be treated as " +
                       "a stale async-delivery race, not genuine progress")
    }

    // Pins down the *accepted trade-off* this guard makes — not just
    // that it correctly ignores a genuinely stale, out-of-order
    // `PreToolUse`, but that it also drops a *legitimate*, unrelated
    // tool call's `PreToolUse` landing in the same window, since
    // `AgentRegistry` has no `tool_name`/call-identity field to tell the
    // two apart at this layer. Mechanically identical to the "late
    // arriving" race test above; kept separate because it documents a
    // deliberately different property (an accepted false-drop, not just a
    // true-positive stale drop) — see handleHookEvent's own comment on
    // this trade-off.
    func test_handleHookEvent_legitimateDifferentToolPreToolUseWithin1_5sOfBlocked_isAlsoDropped() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        // A different, genuinely-new tool call's PreToolUse, indistinguishable
        // from a stale one at this layer, arriving 0.2s after the rejection.
        registry.handleHookEvent(event("PreToolUse"), surfaceID: surfaceID, now: base.addingTimeInterval(0.2))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "A legitimate different tool call's PreToolUse within the 1.5s window is also " +
                       "dropped — an accepted trade-off, not a bug — since the row self-corrects on " +
                       "the very next PostToolUse/Stop/UserPromptSubmit regardless")
    }

    // Pins the window's exact boundary contract (`<`, not `<=`) — a
    // PreToolUse arriving at *exactly* 1.5s must clear blocked, not be
    // dropped.
    func test_handleHookEvent_preToolUseAtExactly1_5sBoundary_clearsBlocked() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleHookEvent(event("PreToolUse"), surfaceID: surfaceID, now: base.addingTimeInterval(1.5))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "The guard's window is a strict `<` — a PreToolUse landing at exactly 1.5s is " +
                       "already outside it and must clear blocked, not be dropped")
    }

    func test_handleHookEvent_preToolUseAfter1_5sOfBlocked_clearsBlockedNormally() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        // Outside the 1.5s window — a genuine post-approval PreToolUse
        // must clear blocked exactly as before this guard existed.
        registry.handleHookEvent(event("PreToolUse"), surfaceID: surfaceID, now: base.addingTimeInterval(2.0))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "A PreToolUse arriving well after the race window must clear blocked as before")
    }

    func test_handleHookEvent_postToolUseWithin1_5sOfBlocked_stillClearsBlockedImmediately() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        // PostToolUse is not covered by the PreToolUse-only race guard:
        // it only fires once a tool has actually run, so it must keep
        // clearing .blocked immediately, even within the 1.5s window.
        registry.handleHookEvent(event("PostToolUse"), surfaceID: surfaceID, now: base.addingTimeInterval(0.5))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "PostToolUse must still clear blocked immediately, unlike PreToolUse")
    }

    func test_handleHookEvent_userPromptSubmitWithin1_5sOfBlocked_stillClearsBlockedImmediately() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleHookEvent(event("UserPromptSubmit"), surfaceID: surfaceID, now: base.addingTimeInterval(0.5))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "UserPromptSubmit must still clear blocked immediately, unlike PreToolUse")
    }

    func test_handleHookEvent_stopWithin1_5sOfBlocked_stillClearsToIdleImmediately() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleHookEvent(event("Stop"), surfaceID: surfaceID, now: base.addingTimeInterval(0.5))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "Stop must still clear blocked to idle immediately, unlike PreToolUse")
    }

    // The window is anchored to the moment the row entered .blocked, not
    // to the row's last accepted write. A second blocking Notification
    // re-stamps lastEventAt while leaving the row blocked, and anchoring
    // there would slide the window forward and swallow a PreToolUse that
    // is genuinely outside it.
    func test_handleHookEvent_repeatedBlockingNotification_doesNotSlideTheRaceWindow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()

        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"), surfaceID: surfaceID, now: base
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        // The same permission prompt reported again while the row is
        // already blocked. It changes no state, only lastEventAt.
        registry.handleHookEvent(
            event("Notification", message: "needs your permission"),
            surfaceID: surfaceID, now: base.addingTimeInterval(1.0)
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked)

        registry.handleHookEvent(event("PreToolUse"), surfaceID: surfaceID, now: base.addingTimeInterval(2.0))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "2.0s have elapsed since the row entered blocked, outside the 1.5s window, so this " +
                       "PreToolUse is genuine forward progress and must clear blocked no matter how many " +
                       "blocking Notifications re-stamped lastEventAt in between")
    }

    // MARK: - handlePaneCommandFinished (shell integration pane-exit signal)

    // A pane's shell integration sends /command-event with phase: end
    // when the pane's foreground command finishes and the prompt
    // returns. This is the only exit signal available for a CLI that
    // cannot self-report its own process exit (OpenCode's plugin event
    // vocabulary has no process-exit event; Hermes has no hooks at all),
    // and is also the backstop for a CLI whose hooks were never trusted
    // to run, or one that exits via SIGKILL/crash before a hook fires.

    func test_handlePaneCommandFinished_hooksEntry_becomesDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a live hooks-sourced row")

        registry.handlePaneCommandFinished(surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .done,
                       "The pane's foreground command finishing must settle a live hooks row to done")
        XCTAssertEqual(entry?.source, .hooks)
    }

    func test_handlePaneCommandFinished_mcpConnectionEntry_hermesKind_becomesDone() {
        // Hermes has no hooks at all; its row comes solely from MCP
        // initialize, so this pane signal is the only path that can ever
        // move it off idle/working.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        registry.handlePaneCommandFinished(surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .done)
        XCTAssertEqual(entry?.source, .mcpConnection)
        XCTAssertEqual(entry?.kind, AgentEntry.hermesKind)
    }

    func test_handlePaneCommandFinished_mcpConnectionEntry_openCodeKind_becomesDone() {
        // OpenCode's plugin event vocabulary (session.created / updated /
        // idle / compacted / error / deleted) has no process-exit event
        // either, so the same MCP-connection-only row shape applies.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.openCodeKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        registry.handlePaneCommandFinished(surfaceID: surfaceID)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .done)
        XCTAssertEqual(entry?.source, .mcpConnection)
        XCTAssertEqual(entry?.kind, AgentEntry.openCodeKind)
    }

    func test_handlePaneCommandFinished_titleHeuristicEntry_isLeftUntouched() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.source, .titleHeuristic, "Precondition")

        registry.handlePaneCommandFinished(surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A titleHeuristic row retires itself through its own miss-streak bookkeeping and " +
                       "must not be settled by the pane command signal")
    }

    func test_handlePaneCommandFinished_alreadyDoneEntry_isUntouched() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session already ended")

        registry.handlePaneCommandFinished(surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A row already done must not be rewritten -- including no lastEventAt churn, " +
                       "checked here by comparing the entire entry rather than state alone")
    }

    func test_handlePaneCommandFinished_unregisteredSurface_neverCreatesARow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handlePaneCommandFinished(surfaceID: surfaceID)

        XCTAssertNil(registry.entries[surfaceID])
        XCTAssertTrue(registry.entries.isEmpty, "A surface with no row must stay with no row")
    }

    func test_handlePaneCommandFinished_externalEntry_isNeverTouched() {
        let registry = AgentRegistry()
        let id = UUID()
        let seeded = AgentEntry(
            surfaceID: id, sessionID: nil, source: .external, state: .working,
            cwd: "/Users/dev/herdr-project", kind: AgentEntry.claudeCodeKind, lastEventAt: Date()
        )
        registry.upsertExternalEntry(seeded)

        registry.handlePaneCommandFinished(surfaceID: id)

        XCTAssertEqual(registry.externalEntries[id], seeded,
                       "A herdr-sourced external row must never be settled by this native pane signal")
        XCTAssertTrue(registry.entries.isEmpty,
                      "handlePaneCommandFinished must not create a native row for an externalEntries id either")
    }

    // MARK: - handlePaneCommandFinished: suspend vs. exit (stop-signal exit code)

    // A `phase: end` command event also fires when the pane's foreground
    // job is merely SUSPENDED, not exited: pressing Ctrl-Z on a running
    // process fires the shell's precmd with an exit code of 128 plus the
    // stop signal that suspended it (SIGSTOP 17, SIGTSTP 18, SIGTTIN 21,
    // SIGTTOU 22 on macOS) while the process is still alive, about to be
    // resumed with `fg`. A process can only be stopped by a stop signal,
    // never terminated by one, but that evidence is not certain: a
    // process that genuinely exits with status 145/146/149/150 is
    // indistinguishable from a suspend by this check alone. The mistake
    // is deliberately one-directional -- these tests pin that a matching
    // exit code only ever leaves a row live rather than settling it,
    // never the reverse of wrongly settling a row (and expiring its
    // pending approvals) out from under an agent that is actually still
    // running.

    func test_handlePaneCommandFinished_sigtstpExitCode146_leavesWorkingRowUntouched() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .working, "Precondition: a live working row")

        // 146 = 128 + SIGTSTP (18) -- Ctrl-Z on a running command.
        let settled = registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 146)

        XCTAssertFalse(settled, "A stop-signal exit code must not report the row as settled")
        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A stop-signal exit code means the command was suspended, not exited -- the row must " +
                       "stay exactly as it was, including no lastEventAt churn")
    }

    func test_handlePaneCommandFinished_otherStopSignalExitCodes_leaveWorkingRowUntouched() {
        // 145 = 128 + SIGSTOP (17), 149 = 128 + SIGTTIN (21), 150 = 128 +
        // SIGTTOU (22).
        let stopSignalExitCodes: [Int32] = [145, 149, 150]
        for exitCode in stopSignalExitCodes {
            let registry = AgentRegistry()
            let surfaceID = UUID()
            registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
            registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
            let before = registry.entries[surfaceID]

            registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: exitCode)

            XCTAssertEqual(registry.entries[surfaceID], before,
                           "Exit code \(exitCode) is a stop signal -- the row must stay untouched")
        }
    }

    func test_handlePaneCommandFinished_stopSignalExitCodes_leaveBlockedRowUntouched() {
        let stopSignalExitCodes: [Int32] = [145, 146, 149, 150]
        for exitCode in stopSignalExitCodes {
            let registry = AgentRegistry()
            let surfaceID = UUID()
            registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
            registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID)
            let before = registry.entries[surfaceID]
            XCTAssertEqual(before?.state, .blocked, "Precondition: a blocked row")

            registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: exitCode)

            XCTAssertEqual(registry.entries[surfaceID], before,
                           "A suspended foreground job (exit code \(exitCode)) must not settle a blocked row " +
                           "either -- the approval prompt it's blocked on is still live")
        }
    }

    func test_handlePaneCommandFinished_blockedRow_realTermination_settlesToDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked, "Precondition: a blocked row")

        // 130 = 128 + SIGINT: a real termination signal (Ctrl-C), not a
        // stop signal.
        registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 130)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "A genuine termination while blocked is a real death, not a suspend -- the row must " +
                       "settle even though it was blocked, same as any other live state")
    }

    func test_handlePaneCommandFinished_exitCodeZero_settlesToDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition")

        let settled = registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertTrue(settled, "A clean exit (0) must report the row as settled")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "A clean exit (0) must settle the row")
    }

    func test_handlePaneCommandFinished_ordinaryNonZeroExitCodes_settleToDone() {
        // 1: an ordinary command failure. 130 = 128 + SIGINT (Ctrl-C): a
        // real termination signal, deliberately in the same 128+n
        // numeric family as the stop-signal codes above, so this also
        // pins that the implementation distinguishes the SPECIFIC stop
        // signals rather than treating every exit code over 128 as
        // "still alive."
        let ordinaryExitCodes: [Int32] = [1, 130]
        for exitCode in ordinaryExitCodes {
            let registry = AgentRegistry()
            let surfaceID = UUID()
            registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
            registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)

            registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: exitCode)

            XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                           "Exit code \(exitCode) is a real termination, not a stop signal -- the row must settle")
        }
    }

    func test_handlePaneCommandFinished_nilExitCode_settlesToDone() {
        // A nil exit code means the shell integration reported no $? at
        // all, or CommandEvent.decode couldn't parse it as an Int32 --
        // there is no positive evidence of a stop signal either way:
        // stop-signal detection can only ever recognize specific known
        // values, never infer one it wasn't given. Settling is the safe
        // default: a row stuck at .working/.blocked forever because a
        // process that genuinely exited failed to report its code is a
        // worse failure than the reverse, and .done is not permanently
        // stuck either -- a later resumed session's own SessionStart or
        // MCP initialize still revives it.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)

        registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: nil)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "A nil exit code must settle the row")
    }

    // MARK: - handleGhosttyCommandFinished (ghostty's own OSC 133 pane-exit signal, fallback)

    // The tests below pin the settle contract handleGhosttyCommandFinished
    // must satisfy, the same way handlePaneCommandFinished's own tests
    // above pin that method.
    //
    // GHOSTTY_ACTION_COMMAND_FINISHED (apprt.action.CommandFinished, from
    // ghostty's own shell-integration OSC 133 C/D pairing) is a fallback
    // for the shells Calyx's own /command-event integration does not
    // cover (bash, elvish, nushell): it must settle a row exactly like
    // handlePaneCommandFinished, subject to the same stop-signal
    // exclusion, but never carries a suspended flag of its own -- ghostty
    // has no way to detect a suspend the way zsh's exit-code convention
    // or fish's own postexec jobs check can.

    func test_handleGhosttyCommandFinished_hooksEntry_becomesDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a live hooks-sourced row")

        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertTrue(settled)
        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .done,
                       "A ghostty-sourced pane-exit signal must settle a live hooks row to done, same as " +
                       "Calyx's own shell-integration signal")
        XCTAssertEqual(entry?.source, .hooks)
    }

    func test_handleGhosttyCommandFinished_nilExitCode_becomesDone() {
        // A nil exit code -- how ghostty's own -1 sentinel for "no exit
        // code reported" arrives at this entry point -- carries no
        // positive evidence of a suspend: isStopSignalExitCode can only
        // recognize a specific known value, never infer one it wasn't
        // given. The row settles rather than being treated
        // conservatively, the same as handlePaneCommandFinished's own
        // nil case above.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a live hooks-sourced row")

        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: nil)

        XCTAssertTrue(settled)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "A nil exit code must settle the row")
    }

    func test_handleGhosttyCommandFinished_mcpConnectionEntry_becomesDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition")

        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertTrue(settled)
        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .done)
        XCTAssertEqual(entry?.source, .mcpConnection)
    }

    func test_handleGhosttyCommandFinished_stopSignalExitCode146_leavesWorkingRowUntouched() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .working, "Precondition: a live working row")

        // 146 = 128 + SIGTSTP (18) -- Ctrl-Z on a running command.
        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 146)

        XCTAssertFalse(settled, "A stop-signal exit code must not report the row as settled")
        XCTAssertEqual(registry.entries[surfaceID], before,
                       "ghostty's own signal excludes the same stop-signal exit codes handlePaneCommandFinished " +
                       "does -- the pane's foreground job is still alive")
    }

    func test_handleGhosttyCommandFinished_stopSignalExitCode150_leavesWorkingRowUntouched() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]

        // 150 = 128 + SIGTTOU (22).
        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 150)

        XCTAssertFalse(settled)
        XCTAssertEqual(registry.entries[surfaceID], before)
    }

    func test_handleGhosttyCommandFinished_titleHeuristicEntry_isLeftUntouched() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.source, .titleHeuristic, "Precondition")

        registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A titleHeuristic row retires itself through its own miss-streak bookkeeping and " +
                       "must not be settled by the ghostty pane-exit signal either")
    }

    func test_handleGhosttyCommandFinished_alreadyDoneEntry_isUntouched() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session already ended")

        registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A row already done must not be rewritten by the ghostty signal either")
    }

    func test_handleGhosttyCommandFinished_unregisteredSurface_neverCreatesARow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertNil(registry.entries[surfaceID])
        XCTAssertTrue(registry.entries.isEmpty, "A surface with no row must stay with no row")
    }

    func test_handleGhosttyCommandFinished_externalEntry_isNeverTouched() {
        let registry = AgentRegistry()
        let id = UUID()
        let seeded = AgentEntry(
            surfaceID: id, sessionID: nil, source: .external, state: .working,
            cwd: "/Users/dev/herdr-project", kind: AgentEntry.claudeCodeKind, lastEventAt: Date()
        )
        registry.upsertExternalEntry(seeded)

        registry.handleGhosttyCommandFinished(surfaceID: id, exitCode: 0)

        XCTAssertEqual(registry.externalEntries[id], seeded,
                       "A herdr-sourced external row must never be settled by the ghostty pane-exit signal")
        XCTAssertTrue(registry.entries.isEmpty,
                      "handleGhosttyCommandFinished must not create a native row for an externalEntries id either")
    }

    // MARK: - handleGhosttyCommandFinished: deferring to Calyx's own /command-event

    // Once Calyx's own shell integration has reported a phase: end event
    // for a surface, that surface's shell is one Calyx's own zsh/fish
    // integration covers -- and that integration alone can tell a real
    // exit apart from a suspend for it (zsh's 128+signal convention, or
    // fish's own separate suspended flag). ghostty's fallback cannot
    // detect a suspend at all, so it must defer entirely once Calyx has
    // ever reported on a surface, rather than risk wrongly settling a row
    // (and expiring its pending approvals) out from under a merely
    // suspended job.

    func test_handleGhosttyCommandFinished_surfaceWithPriorCalyxStopSignalReport_doesNotSettle() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        // Calyx's own shell integration reports here through the real
        // entry point -- a stop-signal exit code, so the row itself is
        // left untouched, but the report must still be remembered.
        let calyxSettled = registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 146)
        XCTAssertFalse(calyxSettled, "Precondition: the stop-signal report itself must not settle the row")
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .working, "Precondition: still working after the suspend report")

        let ghosttySettled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertFalse(ghosttySettled,
                       "A surface Calyx's own /command-event has reported on must ignore a ghostty-sourced " +
                       "settle, even with an ordinary exit code that would otherwise settle it")
        XCTAssertEqual(registry.entries[surfaceID], before,
                       "The row must stay exactly as it was after the ignored ghostty settle")
    }

    func test_handleGhosttyCommandFinished_surfaceWithPriorCalyxFishSuspendReport_doesNotSettle() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        // fish's own $status cannot itself signal a suspend, so its
        // integration reports one through the separate suspended flag
        // instead -- an ordinary exit code accompanies it.
        let calyxSettled = registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 0, suspended: true)
        XCTAssertFalse(calyxSettled, "Precondition: fish's suspended flag must not settle the row either")
        let before = registry.entries[surfaceID]

        let ghosttySettled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertFalse(ghosttySettled,
                       "fish is exactly the case this memory exists to protect: ghostty's own signal has no " +
                       "way to detect fish's suspend at all, so it must defer to Calyx's own integration once " +
                       "that integration has reported on this surface")
        XCTAssertEqual(registry.entries[surfaceID], before)
    }

    func test_handleGhosttyCommandFinished_surfaceRevivedAfterCalyxSettle_stillIgnoresGhosttySettle() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertTrue(registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 0), "Precondition: settles")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition")
        // The same session resumes -- a same-session SessionStart revives
        // a done row to idle (test_sessionStart_sameSurfaceSameSession_doneEntryRevivesToIdle).
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .idle,
                       "Precondition: revived, not done -- a wrong implementation that merely refuses to " +
                       "resettle an already-done row could not explain this test on its own")

        let ghosttySettled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertFalse(ghosttySettled,
                       "Calyx reported on this surface once, before the revive -- the memory of that report " +
                       "must persist across later state changes unrelated to it")
        XCTAssertEqual(registry.entries[surfaceID], before)
    }

    func test_handleGhosttyCommandFinished_afterHandleSurfaceDestroyed_settlesAgainForANewRowOnTheSameID() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 146)
        XCTAssertFalse(registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0),
                       "Precondition: the ghostty settle is currently ignored")

        registry.handleSurfaceDestroyed(surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-b"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-b"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a fresh live row")

        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertTrue(settled,
                      "handleSurfaceDestroyed must drop the memory of Calyx's prior report -- a new " +
                      "registration on the same surfaceID must not inherit it")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done)
    }

    // MARK: - sweepStaleEntries: an unanswered ghostty deferral

    // The deferral above is only safe while Calyx's own shell
    // integration actually answers it. Its phase: end POST can be lost
    // (the shell body swallows a failed POST), and then nothing settles
    // the row at all: Calyx never reports the end, and ghostty's own
    // signal already deferred to the report that never came. The row
    // sits at whatever it was, red included, until the pane is
    // destroyed.
    //
    // ghostty's signal and Calyx's phase: end describe the same command
    // completing and so arrive within milliseconds of each other, which
    // makes a deferral Calyx never answered evidence that Calyx's report
    // was lost. The sweep settles on that evidence.

    func test_sweepStaleEntries_unansweredGhosttyDeferral_settlesTheRowToDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let started = Date()
        // A long-running foreground command: Calyx's integration reported
        // its phase: start five minutes before the command finished.
        let finished = started.addingTimeInterval(5 * 60)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: started)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID, now: started)
        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandStart, now: started)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a live hooks row")

        let ghosttySettled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0, now: finished)

        XCTAssertFalse(ghosttySettled,
                       "Precondition: ghostty still defers to Calyx's own integration for this surface")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working,
                       "Precondition: the deferred signal itself must leave the row alone")
        XCTAssertEqual(registry.entries[surfaceID]?.lastEventAt, started,
                       "Precondition: the deferred signal must not stamp the row either")

        // Calyx's matching phase: end never arrives.
        registry.sweepStaleEntries(now: finished.addingTimeInterval(90))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "A ghostty deferral Calyx never answered means Calyx's own end report was lost, so " +
                       "the sweep must settle the row -- without this nothing settles it by either route " +
                       "and the row stays stuck until the pane is destroyed")
        XCTAssertEqual(registry.entries[surfaceID]?.lastEventAt, started,
                       "The sweep never stamps lastEventAt: the timestamp still means when the agent last " +
                       "reported, and this settle is Calyx's own inference, not a report")
    }

    // MARK: - sweepStaleEntries: a later phase: start must not erase an unresolved deferral

    // A `.commandStart` report must never answer a ghostty deferral: only
    // `.commandEnd` says anything about whether a foreground job
    // finished, so `AgentStateResolver.resolveCalyxShellIntegrationReported`
    // leaves `deferredGhosttyFinishAt` untouched for `.commandStart`.
    // If that were not true, a NEW command starting within
    // `deferredGhosttySettleDelay` (30s) of an earlier command's own
    // lost `phase: end` would wipe the still-unresolved deferral that
    // earlier command recorded, leaving a `.blocked` row stuck red for
    // the rest of the pane's life, since nothing else would ever settle
    // it.

    func test_sweepStaleEntries_laterPhaseStart_mustNotEraseUnresolvedGhosttyDeferral() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: base)
        // A PermissionRequest blocks the row -- the visible state a
        // lost end report must not leave stuck red.
        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID, now: base)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked, "Precondition: a blocked hooks row")

        // Calyx's own shell integration has reported on this surface
        // well before the ghostty signal below, so ghostty defers to it.
        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandStart, now: base.addingTimeInterval(5))

        // The command's own ghostty pane-exit signal arrives outside the
        // grace window of that report, so it records a deferral rather
        // than being swallowed as already-answered.
        let ghosttySettled = registry.handleGhosttyCommandFinished(
            surfaceID: surfaceID, exitCode: 0, now: base.addingTimeInterval(15)
        )
        XCTAssertFalse(ghosttySettled, "Precondition: ghostty defers to Calyx's own integration for this surface")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "Precondition: the deferred signal itself must leave the row alone")

        // Sanity: a sweep well short of deferredGhosttySettleDelay (30s)
        // from the deferral recorded above must not settle the row --
        // this proves the deferral is genuinely still outstanding at
        // this point, before the interfering event below is introduced.
        registry.sweepStaleEntries(now: base.addingTimeInterval(25))
        XCTAssertNotEqual(registry.entries[surfaceID]?.state, .done,
                          "Precondition: the deferral is not yet old enough to settle on its own")

        // A brand new command starts on the same pane within 30s of the
        // still-unresolved deferral above. Its own phase: start --
        // CalyxMCPServer.routeCommandEvent calls exactly this method,
        // unconditionally, for both a start and an end -- must not erase
        // the PREVIOUS command's unresolved deferral.
        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandStart, now: base.addingTimeInterval(26))
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "Precondition: the new phase: start does not itself touch the row's state")

        // Calyx's phase: end for the FIRST command never arrives (the
        // shell body swallows a failed POST). Sweeping past
        // deferredGhosttySettleDelay from when the deferral was recorded
        // must still settle the row.
        registry.sweepStaleEntries(now: base.addingTimeInterval(15 + 31))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "A later command's phase: start must not erase an earlier command's still-unresolved " +
                       "ghostty deferral -- otherwise the deferral is wiped the instant the new command " +
                       "starts, and this blocked row never settles at all")
    }

    // MARK: - sweepStaleEntries: a short-lived command's own phase: start must not swallow its ghostty deferral

    // `AgentEvidence.lastCalyxCommandEndAt` is stamped only by a
    // `.commandEnd` report, never a `.commandStart` -- so a bare start
    // with no matching end can never satisfy `resolvePaneCommandFinished`'s
    // own grace-window check (`calyxReportGraceWindow`, 2s) as "Calyx
    // already spoke for this command". A short-lived command whose own
    // `phase: end` POST is lost, and whose ghostty pane-exit signal
    // lands within 2s of its OWN `phase: start`, must still have its
    // signal recorded as a deferral `sweepStaleEntries` can act on.

    func test_sweepStaleEntries_shortLivedCommand_ghosttySignalWithinStartGraceWindow_stillSettlesViaDeferral() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID, now: base)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked, "Precondition: a blocked hooks row")

        // The command's own phase: start.
        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandStart, now: base.addingTimeInterval(5))

        // The command exits almost immediately -- its ghostty pane-exit
        // signal lands within calyxReportGraceWindow (2s) of its OWN
        // phase: start, because its (never-arriving) phase: end would
        // ordinarily have landed around the same moment.
        let ghosttySettled = registry.handleGhosttyCommandFinished(
            surfaceID: surfaceID, exitCode: 0, now: base.addingTimeInterval(6)
        )
        XCTAssertFalse(ghosttySettled, "Precondition: ghostty defers to Calyx's own integration for this surface")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "Precondition: the deferred signal itself must leave the row alone")

        // Calyx's own phase: end for this command never arrives. Sweeping
        // well past deferredGhosttySettleDelay from the ghostty signal
        // must still settle the row: a lost end report must not leave a
        // command's own exit permanently unrecorded just because its
        // ghostty signal happened to race its own start.
        registry.sweepStaleEntries(now: base.addingTimeInterval(6 + 31))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "A ghostty pane-exit signal landing within the grace window of a command's OWN " +
                       "phase: start must still be recorded as a deferral sweepStaleEntries can settle -- " +
                       "otherwise nothing is ever recorded for it and the row stays blocked forever")
    }

    // The ordering trap. On a fish Ctrl-Z, Calyx's own suspend report and
    // ghostty's pane-exit signal race, and Calyx's can land FIRST. A
    // deferral recorded after Calyx already answered would then have
    // nothing left to clear it, and the sweep would retire a job that is
    // merely stopped. The grace window on how recently Calyx reported is
    // what makes the dangerous ordering safe.

    func test_sweepStaleEntries_calyxSuspendReportBeforeGhosttySignal_neverSettlesTheSuspendedRow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: base)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID, now: base)
        // fish's own $status cannot signal a suspend, so its integration
        // reports one through the separate suspended flag instead.
        let calyxSettled = registry.handlePaneCommandFinished(
            surfaceID: surfaceID, exitCode: 0, suspended: true, now: base
        )
        XCTAssertFalse(calyxSettled, "Precondition: fish's suspended flag must not settle the row")
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .working, "Precondition: still working after the suspend report")

        // ghostty's signal for the same Ctrl-Z lands a moment later.
        let ghosttySettled = registry.handleGhosttyCommandFinished(
            surfaceID: surfaceID, exitCode: 0, now: base.addingTimeInterval(1)
        )
        XCTAssertFalse(ghosttySettled, "Precondition: ghostty defers, as it always has for this surface")
        XCTAssertEqual(registry.entries[surfaceID], before, "Precondition: the deferred signal changes nothing")

        registry.sweepStaleEntries(now: base.addingTimeInterval(90))

        XCTAssertNotEqual(registry.entries[surfaceID]?.state, .done,
                          "Calyx answered this command already, milliseconds before ghostty's signal for it " +
                          "arrived -- treating that signal as unanswered would retire a job the user merely " +
                          "suspended and is about to resume with fg")
        XCTAssertEqual(registry.entries[surfaceID], before,
                       "The suspended row must come through the sweep exactly as it went in")
    }

    // The same ordering trap with a hook event in the middle. A hook
    // event and Calyx's own report are two independent POSTs describing
    // one moment, and the hook one says nothing about whether Calyx's
    // shell integration spoke. Losing that memory here would let the
    // ghostty signal right behind it be recorded as a deferral nothing
    // can ever answer, and the sweep would settle a row on it.

    func test_sweepStaleEntries_hookEventBetweenCalyxReportAndGhosttySignal_neverSettlesTheRow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let base = Date()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: base)
        // Calyx's own integration reports for the pane, and the agent's
        // own hook event lands milliseconds behind it.
        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandEnd, now: base)
        registry.handleHookEvent(
            event("UserPromptSubmit", sessionID: "session-a"),
            surfaceID: surfaceID, now: base.addingTimeInterval(0.05)
        )
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .working, "Precondition: a live hooks row")

        // ghostty's own signal for the same moment arrives last.
        let ghosttySettled = registry.handleGhosttyCommandFinished(
            surfaceID: surfaceID, exitCode: 0, now: base.addingTimeInterval(0.1)
        )
        XCTAssertFalse(ghosttySettled, "Precondition: ghostty defers for a surface Calyx has reported on")
        XCTAssertEqual(registry.entries[surfaceID], before, "Precondition: the deferred signal changes nothing")

        registry.sweepStaleEntries(now: base.addingTimeInterval(90))

        XCTAssertNotEqual(registry.entries[surfaceID]?.state, .done,
                          "Calyx spoke moments before ghostty's signal, so that signal is answered already " +
                          "and must never be recorded as a deferral -- a hook event arriving in between " +
                          "says nothing about when Calyx last reported and must not wipe it")
        XCTAssertEqual(registry.entries[surfaceID], before,
                       "The live row must come through the sweep exactly as it went in")
    }

    func test_sweepStaleEntries_calyxAnsweredTheGhosttyDeferral_doesNotReSettleOrChurnTheRow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let started = Date()
        let finished = started.addingTimeInterval(5 * 60)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: started)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID, now: started)
        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandStart, now: started)
        XCTAssertFalse(registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0, now: finished),
                       "Precondition: ghostty defers")

        // Calyx's own phase: end lands right behind it and is the one
        // that settles the row, exactly as it does today.
        let calyxSettled = registry.handlePaneCommandFinished(
            surfaceID: surfaceID, exitCode: 0, now: finished.addingTimeInterval(0.05)
        )
        XCTAssertTrue(calyxSettled, "Precondition: Calyx's own end report settles the row")
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition")

        registry.sweepStaleEntries(now: finished.addingTimeInterval(90))

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "Calyx answered the deferral, so the sweep has nothing left to act on -- it must not " +
                       "re-settle the row or churn its timestamp")
    }

    func test_sweepStaleEntries_settlingAnUnansweredDeferral_leavesPendingApprovalsAlone() {
        // Only a Calyx-sourced settle over /command-event expires a
        // surface's pending approvals, and only because it can tell a
        // suspend apart from a real exit. This settle is ghostty-sourced,
        // so it must stay bound to the row's colour and never cancel an
        // approval request an agent may still be waiting on.
        let registry = AgentRegistry()
        let inbox = ApprovalInboxStore()
        let surfaceID = UUID()
        let started = Date()
        let finished = started.addingTimeInterval(5 * 60)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID, now: started)
        registry.handleHookEvent(
            event("Notification", sessionID: "session-a",
                  message: "Claude needs your permission to run this command"),
            surfaceID: surfaceID, now: started
        )
        XCTAssertEqual(registry.entries[surfaceID]?.state, .blocked,
                       "Precondition: the stuck-red row this fix exists for, which the sweep's own " +
                       "working-only staleness clause would never reach")
        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: surfaceID,
            payload: "ls", createdAt: started
        )
        inbox.submit(request)
        XCTAssertEqual(inbox.pending.map(\.id), [request.id], "Precondition")

        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandStart, now: started)
        XCTAssertFalse(registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0, now: finished),
                       "Precondition: ghostty defers")

        registry.sweepStaleEntries(now: finished.addingTimeInterval(90))

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "Precondition: the unanswered deferral settles even a blocked row")
        XCTAssertEqual(inbox.pending.map(\.id), [request.id],
                       "A ghostty-sourced settle must never expire a pending approval")
    }

    // MARK: - Readers after a pane-signaled done (must not undo the settle)

    // handlePaneCommandFinished makes .done reachable for an
    // .mcpConnection row for the first time (previously only a .hooks
    // SessionEnd could produce it), so both readers that already treat
    // .mcpConnection specially need pinning against reverting that.

    func test_handleScreenClassification_nilOnDoneMCPConnectionEntry_leavesItDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        registry.handlePaneCommandFinished(surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "Precondition: the pane signal settled the row")
        XCTAssertEqual(registry.entries[surfaceID]?.source, .mcpConnection, "Precondition")

        registry.handleScreenClassification(surfaceID: surfaceID, state: nil)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done,
                       "A nil screen classification must not roll a pane-settled done row back to idle -- " +
                       "the Agents sidebar polls screen classification every two seconds")
    }

    func test_handleMCPConnection_doneMCPConnectionEntrySameKind_becomesLiveIdleEntryPreservingCwd() {
        // Companion to test_handleMCPConnection_doneHooksEntrySameKind_becomesLiveIdleEntryPreservingCwd,
        // for a row that reached .mcpConnection + .done through the pane
        // signal rather than through a .hooks SessionEnd.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "codex-session", cwd: "/Users/dev/repo"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )
        registry.handleHookEvent(
            event("SessionEnd", sessionID: "codex-session"),
            surfaceID: surfaceID,
            kind: AgentEntry.codexKind
        )
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)
        registry.handlePaneCommandFinished(surfaceID: surfaceID)
        let precondition = registry.entries[surfaceID]
        XCTAssertEqual(precondition?.state, .done, "Precondition: the pane signal settled the row")
        XCTAssertEqual(precondition?.source, .mcpConnection, "Precondition")
        XCTAssertEqual(precondition?.cwd, "/Users/dev/repo", "Precondition")

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .idle,
                       "A same-kind MCP initialize must move a done row off done -- a fresh initialize is " +
                       "evidence the agent is live again, not stranded behind the finished pane command")
        XCTAssertEqual(entry?.source, .mcpConnection)
        XCTAssertEqual(entry?.cwd, "/Users/dev/repo",
                       "cwd must carry over from the replaced entry, exactly as the existing hooks+done case requires")
    }

    // MARK: - handleHookEvent: a done .mcpConnection row is never wholesale-replaced

    // The non-SessionStart path below replaces any entry that isn't
    // .hooks-sourced (`existing.source == .hooks` is the only guard
    // letting a call fall through to the same-session update path
    // instead) so a not-yet-.hooks .mcpConnection row can be promoted
    // the moment a real hook event arrives -- see
    // test_hookEventPromotesMCPConnectionEntryToAuthoritativeHooksEntry.
    // That guard doesn't special-case .done, so a .done .mcpConnection
    // row -- exactly what handlePaneCommandFinished produces for
    // OpenCode and Hermes, which have no hooks of their own (or none
    // Calyx trusts) -- must not be wholesale-replaced by a stray hook
    // event the same way a not-yet-.hooks row is promoted: doing so
    // would silently undo the settle through a path meant only to
    // promote a live row, not resurrect a finished one.

    func test_handleHookEvent_doneMCPConnectionEntry_stragglingStop_staysDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        registry.handlePaneCommandFinished(surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the pane signal settled the row")
        XCTAssertEqual(before?.source, .mcpConnection, "Precondition")

        registry.handleHookEvent(event("Stop", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A straggling Stop must not wholesale-replace a done mcpConnection row -- including no " +
                       "lastEventAt churn, checked here by comparing the entire entry rather than state alone")
    }

    func test_handleHookEvent_doneMCPConnectionEntry_postToolUse_staysDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.openCodeKind)
        registry.handlePaneCommandFinished(surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the pane signal settled the row")
        XCTAssertEqual(before?.source, .mcpConnection, "Precondition")

        registry.handleHookEvent(event("PostToolUse", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A PostToolUse must not wholesale-replace a done mcpConnection row either -- including no " +
                       "lastEventAt churn, checked here by comparing the entire entry rather than state alone")
    }

    // MARK: - handleHookEvent: a done row is absolutely terminal

    // handlePaneCommandFinished excludes a stop-signal exit code (a
    // suspended, still-alive foreground job -- see the "suspend vs.
    // exit" tests above), so a .done row -- however it was produced, a
    // real SessionEnd or handlePaneCommandFinished's own pane-exit
    // signal -- is unambiguous evidence the session genuinely ended. The
    // same-session guard in handleHookEvent therefore refuses every
    // event once a row is .done, with no exception: each hook is an
    // independent fire-and-forget POST, so an event that raced its own
    // session's exit and lost is indistinguishable, at this guard, from
    // a genuinely resumed session's fresh activity.

    func test_handleHookEvent_sameSessionPreToolUseAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(event("PreToolUse", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A same-session PreToolUse after SessionEnd must not revive a done row -- including no " +
                       "lastEventAt churn, checked here by comparing the entire entry rather than state alone")
    }

    func test_handleHookEvent_sameSessionUserPromptSubmitAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A same-session UserPromptSubmit after SessionEnd must not revive a done row -- including " +
                       "no lastEventAt churn, checked here by comparing the entire entry rather than state alone")
    }

    func test_handleHookEvent_sameSessionPermissionRequestAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(event("PermissionRequest", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A same-session PermissionRequest after SessionEnd must not revive a done row -- including " +
                       "no lastEventAt churn, checked here by comparing the entire entry rather than state alone")
    }

    func test_handleHookEvent_sameSessionPostToolUseAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(event("PostToolUse", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A same-session PostToolUse after SessionEnd must not revive a done row -- including no " +
                       "lastEventAt churn, checked here by comparing the entire entry rather than state alone")
    }

    func test_handleHookEvent_sameSessionBlockedNotificationAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(
            event("Notification", sessionID: "session-a", message: "needs your permission"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A same-session blocked-matching Notification after SessionEnd must not revive a done row " +
                       "-- including no lastEventAt churn, checked here by comparing the entire entry rather than " +
                       "state alone")
    }

    func test_handleHookEvent_sameSessionNilMessageNotificationAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(
            event("Notification", sessionID: "session-a", message: nil),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A same-session nil-message Notification after SessionEnd must not revive a done row -- " +
                       "including no lastEventAt churn, checked here by comparing the entire entry rather than " +
                       "state alone")
    }

    func test_handleHookEvent_sameSessionNonMatchingNotificationAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(
            event("Notification", sessionID: "session-a", message: "Unrelated notification text"),
            surfaceID: surfaceID
        )

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A Notification whose message doesn't match blockedNotificationPatterns resolves to nil and " +
                       "returns before the done-row guard is ever reached, so it must not touch an already-done row " +
                       "-- including no lastEventAt churn, checked here by comparing the entire entry rather than " +
                       "state alone")
    }

    func test_handleHookEvent_sameSessionSessionEndAfterSessionEnd_leavesRowDone() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.state, .done, "Precondition: the session ended")

        registry.handleHookEvent(event("SessionEnd", sessionID: "session-a"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "SessionEnd resolves to .done, not a raising state, so a repeat same-session SessionEnd " +
                       "must not rewrite an already-done row -- including no lastEventAt churn, checked here by " +
                       "comparing the entire entry rather than state alone")
    }

    // MARK: - reset(): calyxShellIntegrationReportedSurfaces survives wholesale clearing

    func test_reset_doesNotClearCalyxShellIntegrationReportedSurfaces() {
        // calyxShellIntegrationReportedSurfaces's own doc comment states it
        // is deliberately never cleared wholesale, not even by reset(): a
        // pane whose shell already sourced Calyx's own zsh/fish integration
        // keeps reporting on that surface even after the IPC server
        // restarts. If a refactor folded this set into a store reset()
        // clears, handleGhosttyCommandFinished's fallback would start
        // settling rows for panes where Calyx's own integration is live and
        // CAN tell a suspend apart from a real exit -- a user hitting
        // Ctrl-Z would see their agent's row retire.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandStart)

        registry.reset()

        // Hook-driven row creation is not gated on isServerRunning, unlike
        // handleTitleChange's, so this registers cleanly after reset().
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: surfaceID)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle, "Precondition: a fresh live hooks row")
        XCTAssertEqual(registry.entries[surfaceID]?.source, .hooks,
                       "Precondition: the settle path is source-guarded, so a non-hooks row would satisfy " +
                       "the assertions below for the wrong reason, without exercising the memory at all")

        let settled = registry.handleGhosttyCommandFinished(surfaceID: surfaceID, exitCode: 0)

        XCTAssertFalse(settled,
                       "reset() must not clear calyxShellIntegrationReportedSurfaces -- ghostty's fallback must " +
                       "keep deferring to Calyx's own shell integration's memory for this surface")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "The row must stay idle, not be settled to done by ghostty's fallback signal")
    }

    // MARK: - reset(): AgentRegistry.evidence is cleared wholesale

    func test_reset_clearsAgentEvidence() {
        // The deliberate opposite of calyxShellIntegrationReportedSurfaces's
        // own survival above: AgentRegistry.evidence IS cleared by reset(),
        // so a leftover miss count from before a server restart can never
        // combine with fresh misses afterward to retire a row prematurely.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)

        for _ in 0..<4 {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }
        XCTAssertNotNil(registry.entries[surfaceID], "Precondition: row survives 4 misses, one below retirement")

        registry.reset()

        // The creation branch deliberately never touches the miss-streak
        // bookkeeping, so recreating the row this way cannot itself launder
        // a leftover streak -- only reset() clearing AgentRegistry.evidence
        // can.
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        registry.handleScreenClassification(surfaceID: surfaceID, state: nil)

        XCTAssertNotNil(registry.entries[surfaceID],
                        "reset() must clear AgentRegistry.evidence -- otherwise this one fresh miss since the row " +
                        "was recreated would combine with the 4 leaked misses from before reset() and retire a " +
                        "row that has only actually missed once since it came back")
    }

    // MARK: - sweepStaleEntries: source membership

    func test_sweepStaleEntries_downgradesStaleWorkingMCPConnectionEntryToIdle() {
        // Every existing sweep test uses a .hooks row, leaving the
        // .mcpConnection half of sweepStaleEntries's `.hooks ||
        // .mcpConnection` source guard completely unpinned.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition")
        XCTAssertEqual(registry.entries[surfaceID]?.source, .mcpConnection, "Precondition")

        let farFuture = Date().addingTimeInterval(16 * 60)
        registry.sweepStaleEntries(now: farFuture)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle,
                       "A stale working .mcpConnection entry must be downgraded to idle, same as a .hooks entry")
    }

    func test_sweepStaleEntries_leavesStaleWorkingTitleHeuristicEntryUnchanged() {
        // The other half of the same guard: a .titleHeuristic row must
        // never be swept -- it retires itself through its own miss-streak
        // bookkeeping (AgentRegistry.evidence's screenMissStreak) instead
        // of through staleness.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.source, .titleHeuristic, "Precondition")

        let farFuture = Date().addingTimeInterval(16 * 60)
        registry.sweepStaleEntries(now: farFuture)

        XCTAssertEqual(registry.entries[surfaceID], before,
                       "sweepStaleEntries must never touch a .titleHeuristic entry, however stale")
    }

    // MARK: - handleMCPConnection: cross-kind replacement over a live .hooks row

    func test_handleMCPConnection_differentKindOverLiveHooksEntry_replacesFieldsAndCarriesOverUnreadCount() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let peerID = UUID()
        registry.handleHookEvent(
            event("SessionStart", sessionID: "session-a", cwd: "/Users/dev/project-live"),
            surfaceID: surfaceID,
            kind: AgentEntry.claudeCodeKind
        )
        registry.handleHookEvent(
            AgentEvent(hookEventName: "PreToolUse", sessionID: "session-a", cwd: nil, message: nil,
                       ipcSelfPeerID: peerID.uuidString),
            surfaceID: surfaceID
        )
        registry.syncInboxCounts([peerID: 3])
        let precondition = registry.entries[surfaceID]
        XCTAssertEqual(precondition?.state, .working, "Precondition: a live .hooks row")
        XCTAssertEqual(precondition?.unreadCount, 3, "Precondition: unread badge set via the bound peer")

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.source, .mcpConnection)
        XCTAssertEqual(entry?.kind, AgentEntry.codexKind)
        XCTAssertEqual(entry?.state, .idle,
                       "A different-kind MCP initialize demotes even a LIVE .working .hooks row to idle -- " +
                       "surprising, but the early-return protection only covers a repeated same-kind initialize")
        XCTAssertEqual(entry?.cwd, "/Users/dev/project-live", "cwd must carry over from the replaced entry")
        XCTAssertNil(entry?.sessionID, "The replacement entry has no hooks session of its own")
        XCTAssertEqual(entry?.unreadCount, 3,
                       "unreadCount must carry over from the replaced entry -- a 'rebuild the entry from " +
                       "evidence' refactor is exactly the kind of change that would silently drop this carry-over")
    }

    // MARK: - handleTitleChange: leaves a .mcpConnection row untouched

    func test_handleTitleChange_mcpConnectionEntryUnaffectedByTitleSignal() {
        // Screen classification DOES update a .mcpConnection row (its own
        // branch in handleScreenClassification); a title change does NOT
        // -- that asymmetry is what a unified "heuristic signals" path
        // would flatten away.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.hermesKind)
        let before = registry.entries[surfaceID]
        XCTAssertEqual(before?.source, .mcpConnection, "Precondition")

        // "✳ Compacting conversation" is the same working-classified title
        // the existing title-heuristic tests use (a leading spinner glyph
        // maps to .working -- see ClaudeTitleHeuristic.classify).
        registry.handleTitleChange(surfaceID: surfaceID, title: "✳ Compacting conversation")

        // handleTitleChange still resets the miss-streak bookkeeping for a
        // .working title before its source guard runs, so this call is not
        // a total no-op -- only the entries row itself is untouched.
        XCTAssertEqual(registry.entries[surfaceID], before,
                       "A title signal must never update a .mcpConnection-sourced entry")
    }

    // MARK: - Injected clock: positive lastEventAt writes

    func test_handleMCPConnection_freshInsert_stampsLastEventAtWithInjectedNow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let injected = Date(timeIntervalSince1970: 1_700_000_000)

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind, now: injected)

        XCTAssertEqual(registry.entries[surfaceID]?.lastEventAt, injected,
                       "A fresh MCP connection insert must stamp lastEventAt with the injected now, not Date()")
    }

    func test_handleMCPConnection_sameKindRefresh_preservesStateAndAdvancesLastEventAt() {
        // A repeated same-kind MCP initialize refreshes lastEventAt
        // without disturbing the row's current state: a Hermes or
        // OpenCode pane the screen classifier has moved to .working must
        // not flash back to .idle every time its agent re-initializes.
        // The row has to be driven off .idle first for this to pin
        // anything, because for a freshly inserted .idle row the refresh
        // branch and the wholesale replace below it produce
        // byte-identical entries.
        let registry = AgentRegistry()
        let surfaceID = UUID()
        let firstNow = Date(timeIntervalSince1970: 1_700_000_000)
        let secondNow = Date(timeIntervalSince1970: 1_700_000_100)
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind, now: firstNow)
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "Precondition: a live working row")
        XCTAssertEqual(registry.entries[surfaceID]?.source, .mcpConnection, "Precondition")

        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind, now: secondNow)

        let entry = registry.entries[surfaceID]
        XCTAssertEqual(entry?.state, .working,
                       "The same-kind refresh branch must preserve the row's state -- falling through to the " +
                       "wholesale replace below it would reset a live working row to idle")
        XCTAssertEqual(entry?.lastEventAt, secondNow,
                       "The same-kind refresh branch must advance lastEventAt to the injected now, which is " +
                       "what distinguishes it from the bare return the .hooks branch above it takes")
    }

    func test_handlePaneCommandFinished_and_handleGhosttyCommandFinished_useInjectedNowOnSettle() {
        let registry = AgentRegistry()
        let paneSurfaceID = UUID()
        let ghosttySurfaceID = UUID()
        let injectedPane = Date(timeIntervalSince1970: 1_700_000_200)
        let injectedGhostty = Date(timeIntervalSince1970: 1_700_000_300)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-a"), surfaceID: paneSurfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-a"), surfaceID: paneSurfaceID)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-b"), surfaceID: ghosttySurfaceID)
        registry.handleHookEvent(event("UserPromptSubmit", sessionID: "session-b"), surfaceID: ghosttySurfaceID)

        registry.handlePaneCommandFinished(surfaceID: paneSurfaceID, exitCode: 0, now: injectedPane)
        registry.handleGhosttyCommandFinished(surfaceID: ghosttySurfaceID, exitCode: 0, now: injectedGhostty)

        let paneEntry = registry.entries[paneSurfaceID]
        XCTAssertEqual(paneEntry?.state, .done)
        XCTAssertEqual(paneEntry?.lastEventAt, injectedPane,
                       "handlePaneCommandFinished's settle must stamp lastEventAt with the injected now")

        let ghosttyEntry = registry.entries[ghosttySurfaceID]
        XCTAssertEqual(ghosttyEntry?.state, .done)
        XCTAssertEqual(ghosttyEntry?.lastEventAt, injectedGhostty,
                       "handleGhosttyCommandFinished's settle must stamp lastEventAt with the injected now")
    }

    // MARK: - handleProgressReport: never creates a row for an unregistered surface

    func test_handleProgressReport_unregisteredSurface_neverCreatesARow() {
        let registry = AgentRegistry()
        let surfaceID = UUID()

        registry.handleProgressReport(surfaceID: surfaceID, isActive: true)

        XCTAssertNil(registry.entries[surfaceID])
        XCTAssertTrue(registry.entries.isEmpty)
    }
}

// MARK: - .calyxAgentConversationEnded

/// Records the surface IDs `.calyxAgentConversationEnded` carries for one
/// registry. The selector observer runs on the posting thread, before
/// `post` returns.
@MainActor
private final class ConversationEndedRecorder: NSObject {
    private(set) var surfaceIDs: [UUID] = []
    private let registry: AgentRegistry

    init(registry: AgentRegistry) {
        self.registry = registry
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(conversationEnded(_:)), name: .calyxAgentConversationEnded, object: registry
        )
    }

    @objc private func conversationEnded(_ notification: Notification) {
        guard let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        surfaceIDs.append(surfaceID)
    }
}

/// The registry posts `.calyxAgentConversationEnded` when a pane's row
/// enters `.done`: the agent process of that pane ended.
@MainActor
final class AgentRegistryConversationEndedTests: XCTestCase {

    private func event(_ name: String, sessionID: String = "session-1") -> AgentEvent {
        AgentEvent(hookEventName: name, sessionID: sessionID, cwd: "/Users/dev/project", message: nil)
    }

    func test_sessionEnd_ofALiveRow_postsOnceWithTheSurface() {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit"), surfaceID: surfaceID)
        XCTAssertTrue(recorder.surfaceIDs.isEmpty, "a live row posts nothing")

        registry.handleHookEvent(event("SessionEnd"), surfaceID: surfaceID)

        XCTAssertEqual(recorder.surfaceIDs, [surfaceID])
    }

    func test_sessionEnd_forASurfaceWithNoRow_posts() {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()

        registry.handleHookEvent(event("SessionEnd"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "precondition: SessionEnd creates a done row")
        XCTAssertEqual(recorder.surfaceIDs, [surfaceID])
    }

    /// Claude Code sends `SessionEnd` with `reason: "clear"` on `/clear`
    /// and keeps running. `/clear` starts a new conversation, so the post
    /// (the pane's conversation ended) is intended here too.
    func test_sessionEnd_withReasonClear_posts() throws {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID)
        let payload = Data(#"{"hook_event_name":"SessionEnd","session_id":"session-1","cwd":"/Users/dev/project","reason":"clear"}"#.utf8)
        let clear = try XCTUnwrap(AgentEvent.decode(from: payload))

        registry.handleHookEvent(clear, surfaceID: surfaceID)

        XCTAssertEqual(recorder.surfaceIDs, [surfaceID])
    }

    func test_secondSessionEnd_ofADoneRow_doesNotPostAgain() {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID)
        registry.handleHookEvent(event("SessionEnd"), surfaceID: surfaceID)

        registry.handleHookEvent(event("SessionEnd"), surfaceID: surfaceID)

        XCTAssertEqual(recorder.surfaceIDs, [surfaceID])
    }

    func test_stop_settlesIdle_andDoesNotPost() {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID)
        registry.handleHookEvent(event("UserPromptSubmit"), surfaceID: surfaceID)

        registry.handleHookEvent(event("Stop"), surfaceID: surfaceID)

        XCTAssertEqual(registry.entries[surfaceID]?.state, .idle)
        XCTAssertTrue(recorder.surfaceIDs.isEmpty)
    }

    func test_paneCommandFinished_settlingAnMCPConnectionRow_posts() {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()
        registry.handleMCPConnection(surfaceID: surfaceID, kind: AgentEntry.codexKind)

        XCTAssertTrue(registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 0))

        XCTAssertEqual(recorder.surfaceIDs, [surfaceID])
    }

    func test_paneCommandFinished_suspended_doesNotPost() {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()
        registry.handleHookEvent(event("SessionStart"), surfaceID: surfaceID)

        XCTAssertFalse(registry.handlePaneCommandFinished(surfaceID: surfaceID, exitCode: 0, suspended: true))

        XCTAssertTrue(recorder.surfaceIDs.isEmpty)
    }

    func test_surfaceDestroyed_andReset_doNotPost() {
        let registry = AgentRegistry()
        let recorder = ConversationEndedRecorder(registry: registry)
        let destroyedSurfaceID = UUID()
        let resetSurfaceID = UUID()
        registry.handleHookEvent(event("SessionStart"), surfaceID: destroyedSurfaceID)
        registry.handleHookEvent(event("SessionStart", sessionID: "session-2"), surfaceID: resetSurfaceID)

        registry.handleSurfaceDestroyed(surfaceID: destroyedSurfaceID)
        registry.reset()

        XCTAssertTrue(registry.entries.isEmpty, "precondition: both rows are gone")
        XCTAssertTrue(recorder.surfaceIDs.isEmpty)
    }

    func test_titleHeuristicRowRetirement_doesNotPost() {
        let registry = AgentRegistry()
        registry.markServerStarted()
        let recorder = ConversationEndedRecorder(registry: registry)
        let surfaceID = UUID()
        registry.handleScreenClassification(surfaceID: surfaceID, state: .working)
        XCTAssertEqual(registry.entries[surfaceID]?.source, .titleHeuristic, "precondition: an inferred row")

        for _ in 0..<10 where registry.entries[surfaceID] != nil {
            registry.handleScreenClassification(surfaceID: surfaceID, state: nil)
        }

        XCTAssertNil(registry.entries[surfaceID], "precondition: the miss streak retired the row")
        XCTAssertTrue(recorder.surfaceIDs.isEmpty)
        registry.reset()
    }
}
