//
//  AgentStateResolverSubagentTests.swift
//  CalyxTests
//
//  Pins the child-event branch AgentStateResolver.resolveHookRow places
//  FIRST, ahead of every other clause including SessionStart:
//  AgentEvent.isSubagentEvent (agentID != nil) is the ONLY subagent
//  predicate, and a subagent event must never create, replace, or
//  promote a row -- no event name, SessionStart included, is an
//  exception -- and must never rewrite an existing row's
//  sessionID / cwd / kind.
//
//  Driven directly through AgentStateResolver.resolve(.hook(...)),
//  bypassing AgentRegistry, per the design note that row-state decisions
//  live exclusively in the resolver -- AgentRegistry owns only storage
//  and side effects.
//
//  Coverage:
//  - No current row -> no row created (.keep)
//  - A session-mismatched subagent event does not replace the row, even
//    for a forward-moving event name that would trigger a mismatch
//    replace for an ordinary (non-subagent) event
//  - sessionID / cwd / kind are never rewritten by a subagent event
//  - A subagent PreToolUse on an existing .hooks row updates only state
//    and lastEventAt
//  - A subagent event never promotes a .titleHeuristic or .mcpConnection
//    row to .hooks
//  - A subagent event leaves a .done row alone
//  - SubagentStart / SubagentStop map to no AgentState, so they leave
//    the parent row's state (and the whole row) unchanged
//  - A subagent PermissionRequest still blocks the parent row -- the
//    settled decision that a child's approval prompt blocks the parent
//  - The existing blockedSince PreToolUse race guard still applies to a
//    subagent PreToolUse
//  - A subagent-scoped SessionStart leaves a .working parent row
//    completely untouched, both with its own sessionID set and with it
//    stripped to nil (the Grok adapter's shape), and creates no row when
//    none exists
//  - The parent's own SessionStart still behaves exactly as before: a
//    fresh session replaces the row, and a same-session re-send
//    preserves state and revives a .done row
//  - retiresChildren: an accepted, same-session parent-scoped Stop no
//    longer retires children (it still settles the row to .idle); an
//    accepted SessionEnd / SessionStart still retires them; an accepted
//    session-mismatch row replacement (a forward-moving event handing
//    the surface to a different session) retires them too, whatever the
//    event's name; a subagent-scoped event never retires them; a
//    rejected (session-mismatched) parent-scoped event never retires
//    them; an accepted event PROMOTING an .mcpConnection or
//    .titleHeuristic row (sessionID nil) to .hooks does not retire them
//    either, since that is a row learning its session for the first
//    time, not a different session taking the row over; nor does a
//    replacement whose new session is nil (a value-to-nil loss of
//    session identity)
//

import XCTest
@testable import Calyx

final class AgentStateResolverSubagentTests: XCTestCase {

    // MARK: - Helpers

    private func event(
        _ name: String,
        sessionID: String? = "parent-session",
        cwd: String? = "/Users/dev/project",
        message: String? = nil,
        agentID: String? = "sub-1",
        agentType: String? = "explore",
        toolName: String? = nil
    ) -> AgentEvent {
        AgentEvent(
            hookEventName: name, sessionID: sessionID, cwd: cwd, message: message,
            agentID: agentID, agentType: agentType, toolName: toolName
        )
    }

    private func hooksEntry(
        surfaceID: UUID,
        sessionID: String? = "parent-session",
        cwd: String? = "/Users/dev/project",
        state: AgentState = .idle,
        kind: String = AgentEntry.claudeCodeKind,
        lastEventAt: Date = Date()
    ) -> AgentEntry {
        AgentEntry(
            surfaceID: surfaceID, sessionID: sessionID, source: .hooks, state: state,
            cwd: cwd, kind: kind, lastEventAt: lastEventAt
        )
    }

    private func resolve(
        _ event: AgentEvent,
        current: AgentEntry?,
        kind: String = AgentEntry.claudeCodeKind,
        evidence: AgentEvidence = AgentEvidence(),
        now: Date = Date()
    ) -> AgentResolution {
        AgentStateResolver.resolve(
            .hook(event, kind: kind),
            surfaceID: UUID(),
            current: current,
            evidence: evidence,
            context: ResolverContext(isServerRunning: true, calyxShellIntegrationSeen: false),
            now: now
        )
    }

    private func writtenEntry(_ resolution: AgentResolution) -> AgentEntry? {
        guard case .write(let entry) = resolution.row else { return nil }
        return entry
    }

    // MARK: - No current row

    func test_subagentEvent_noCurrentRow_createsNoRow() {
        let resolution = resolve(event("PreToolUse"), current: nil)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event with no existing row must never create one -- got \(resolution.row)")
        }
    }

    // MARK: - Session mismatch never replaces

    func test_subagentEvent_sessionMismatch_doesNotReplaceTheRow() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, sessionID: "real-parent-session", state: .idle)

        // UserPromptSubmit is forward-moving: for an ORDINARY event with a
        // mismatched session this would replace the row. A subagent event
        // whose sessionID has been stripped (e.g. Grok) or otherwise
        // differs must never reach that path at all.
        let resolution = resolve(
            event("UserPromptSubmit", sessionID: nil), current: existing
        )

        if case .write(let entry) = resolution.row {
            XCTAssertEqual(entry.sessionID, existing.sessionID,
                           "A subagent event must never replace the row with one carrying a different sessionID")
        }
        // .keep is also an acceptable outcome here; the load-bearing fact
        // is that no replacement with a different sessionID occurred.
    }

    // MARK: - sessionID / cwd / kind are never rewritten

    func test_subagentEvent_neverRewritesSessionIDCwdOrKind() {
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project",
            state: .idle, kind: AgentEntry.codexKind
        )

        let resolution = resolve(event("PreToolUse", sessionID: nil, cwd: nil), current: existing)

        let updated = writtenEntry(resolution)
        XCTAssertEqual(updated?.sessionID, existing.sessionID)
        XCTAssertEqual(updated?.cwd, existing.cwd)
        XCTAssertEqual(updated?.kind, existing.kind)
    }

    // MARK: - Updates only state and lastEventAt

    func test_subagentPreToolUse_existingHooksRow_updatesOnlyStateAndLastEventAt() throws {
        let surfaceID = UUID()
        let base = Date()
        let existing = hooksEntry(surfaceID: surfaceID, state: .idle, lastEventAt: base)
        let now = base.addingTimeInterval(5)

        let resolution = resolve(event("PreToolUse"), current: existing, now: now)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .working)
        XCTAssertEqual(updated.lastEventAt, now)
        XCTAssertEqual(updated.sessionID, existing.sessionID)
        XCTAssertEqual(updated.cwd, existing.cwd)
        XCTAssertEqual(updated.kind, existing.kind)
        XCTAssertEqual(updated.source, .hooks)
    }

    // MARK: - Never promotes a non-.hooks row

    func test_subagentEvent_doesNotPromoteTitleHeuristicRowToHooks() {
        let surfaceID = UUID()
        let existing = AgentEntry(
            surfaceID: surfaceID, sessionID: nil, source: .titleHeuristic, state: .idle,
            cwd: nil, kind: AgentEntry.claudeCodeKind, lastEventAt: Date()
        )

        let resolution = resolve(event("PreToolUse"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event must never promote a .titleHeuristic row -- got \(resolution.row)")
        }
    }

    func test_subagentEvent_doesNotPromoteMCPConnectionRowToHooks() {
        let surfaceID = UUID()
        let existing = AgentEntry(
            surfaceID: surfaceID, sessionID: nil, source: .mcpConnection, state: .idle,
            cwd: nil, kind: AgentEntry.codexKind, lastEventAt: Date()
        )

        let resolution = resolve(event("PreToolUse"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event must never promote a .mcpConnection row -- got \(resolution.row)")
        }
    }

    // MARK: - .done row left alone

    func test_subagentEvent_doneRow_isLeftAlone() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .done)

        let resolution = resolve(event("PreToolUse"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("A subagent event must leave a .done row untouched -- got \(resolution.row)")
        }
    }

    // MARK: - SubagentStart / SubagentStop leave the parent row unchanged

    func test_subagentStart_leavesParentRowUnchanged() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .idle)

        let resolution = resolve(event("SubagentStart"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("SubagentStart maps to no AgentState, so the parent row must stay unchanged -- got \(resolution.row)")
        }
    }

    func test_subagentStop_leavesParentRowUnchanged() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("SubagentStop"), current: existing)

        guard case .keep = resolution.row else {
            return XCTFail("SubagentStop maps to no AgentState, so the parent row must stay unchanged -- got \(resolution.row)")
        }
    }

    // MARK: - A child's PermissionRequest still blocks the parent

    func test_subagentPermissionRequest_stillBlocksTheParentRow() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("PermissionRequest"), current: existing)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .blocked,
                       "The settled decision: a child-sourced PermissionRequest still blocks the parent row")
    }

    // MARK: - blockedSince PreToolUse race guard still applies

    func test_subagentPreToolUse_withinRaceWindowOfBlocked_isDropped() {
        let surfaceID = UUID()
        let base = Date()
        let existing = hooksEntry(surfaceID: surfaceID, state: .blocked, lastEventAt: base)
        var evidence = AgentEvidence()
        evidence.blockedSince = base

        let resolution = resolve(
            event("PreToolUse"), current: existing, evidence: evidence, now: base.addingTimeInterval(0.5)
        )

        guard case .keep = resolution.row else {
            return XCTFail("A subagent PreToolUse within the 1.5s race window of blockedSince must be " +
                           "dropped like any other PreToolUse -- got \(resolution.row)")
        }
    }

    func test_subagentPreToolUse_outsideRaceWindowOfBlocked_clearsBlocked() throws {
        let surfaceID = UUID()
        let base = Date()
        let existing = hooksEntry(surfaceID: surfaceID, state: .blocked, lastEventAt: base)
        var evidence = AgentEvidence()
        evidence.blockedSince = base

        let resolution = resolve(
            event("PreToolUse"), current: existing, evidence: evidence, now: base.addingTimeInterval(2.0)
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .working,
                       "Outside the race window, a subagent PreToolUse clears blocked exactly like an " +
                       "ordinary one")
    }

    // MARK: - A child's own turn/session ending must never retire the parent row

    func test_subagentSessionEnd_leavesAWorkingParentRowWorking() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("SessionEnd"), current: existing)

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry.state, .working,
                           "A child's own SessionEnd must never report the parent's session as .done")
        case .remove:
            XCTFail("A subagent-scoped SessionEnd must never remove the parent row")
        }
    }

    func test_subagentSessionEnd_doesNotPoisonTheRowAgainstLaterParentEvents() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let childResolution = resolve(event("SessionEnd"), current: existing)
        let afterChildEvent: AgentEntry
        switch childResolution.row {
        case .keep:
            afterChildEvent = existing
        case .write(let entry):
            afterChildEvent = entry
        case .remove:
            return XCTFail("A subagent-scoped SessionEnd must never remove the parent row")
        }

        // A normal parent PreToolUse must still move the row -- proving it
        // was never poisoned into a sticky .done state, which would
        // otherwise swallow every later parent event via resolveHookRow's
        // same-session .done guard.
        let parentResolution = resolve(
            event("PreToolUse", agentID: nil, agentType: nil), current: afterChildEvent
        )
        let updated = try XCTUnwrap(writtenEntry(parentResolution))
        XCTAssertEqual(updated.state, .working,
                       "A normal parent PreToolUse must still move the row after a child's SessionEnd")
    }

    func test_subagentStop_leavesAWorkingParentRowWorking() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("Stop"), current: existing)

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry.state, .working,
                           "A child's own Stop must never report the parent's turn as .idle")
        case .remove:
            XCTFail("A subagent-scoped Stop must never remove the parent row")
        }
    }

    // MARK: - The parent's own SessionEnd / Stop still settle the row exactly as before

    func test_parentOwnSessionEnd_stillSettlesTheRowToDone() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("SessionEnd", agentID: nil, agentType: nil), current: existing)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .done, "The parent's own SessionEnd must still settle the row to .done")
    }

    func test_parentOwnStop_stillSettlesTheRowToIdle() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("Stop", agentID: nil, agentType: nil), current: existing)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .idle, "The parent's own Stop must still settle the row to .idle")
    }

    // MARK: - A subagent-scoped SessionStart must never replace the parent row

    func test_subagentScopedSessionStart_leavesAWorkingParentRowCompletelyUntouched() {
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project",
            state: .working, kind: AgentEntry.codexKind
        )

        let resolution = resolve(
            event("SessionStart", sessionID: "child-session", agentID: "sub-1"), current: existing
        )

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry, existing,
                           "A subagent-scoped SessionStart must never replace the parent row -- got a write " +
                           "with a different entry")
        case .remove:
            XCTFail("A subagent-scoped SessionStart must never remove the parent row")
        }
    }

    func test_subagentScopedSessionStart_withNilSessionID_leavesAWorkingParentRowCompletelyUntouched() {
        // The Grok adapter's shape: a subagent-scoped SessionStart whose
        // own sessionID has been stripped to nil -- the case that
        // previously reached resolveHookRow's SessionStart replacement
        // path because nil never matches the parent's own sessionID.
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project",
            state: .working
        )

        let resolution = resolve(
            event("SessionStart", sessionID: nil, agentID: "sub-1"), current: existing
        )

        switch resolution.row {
        case .keep:
            break
        case .write(let entry):
            XCTAssertEqual(entry, existing,
                           "A subagent-scoped SessionStart with a nil sessionID must still never replace " +
                           "the parent row")
        case .remove:
            XCTFail("A subagent-scoped SessionStart must never remove the parent row")
        }
    }

    func test_subagentScopedSessionStart_noExistingRow_createsNoRow() {
        let resolution = resolve(
            event("SessionStart", sessionID: nil, agentID: "sub-1"), current: nil
        )

        guard case .keep = resolution.row else {
            return XCTFail("A subagent-scoped SessionStart with no existing row must never create one -- " +
                           "got \(resolution.row)")
        }
    }

    func test_parentOwnSessionStart_freshSession_stillReplacesTheRow() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "old-session", cwd: "/Users/dev/old", state: .done
        )

        let resolution = resolve(
            event("SessionStart", sessionID: "new-session", cwd: "/Users/dev/new", agentID: nil, agentType: nil),
            current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.sessionID, "new-session")
        XCTAssertEqual(updated.cwd, "/Users/dev/new")
        XCTAssertEqual(updated.state, .idle)
    }

    func test_parentOwnSessionStart_sameSession_preservesStateAndRevivesADoneRow() throws {
        let surfaceID = UUID()
        let existingWorking = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project", state: .working
        )

        let workingResolution = resolve(
            event("SessionStart", sessionID: "parent-session", agentID: nil, agentType: nil),
            current: existingWorking
        )
        let workingUpdated = try XCTUnwrap(writtenEntry(workingResolution))
        XCTAssertEqual(workingUpdated.state, .working,
                       "A re-sent SessionStart for the same session preserves the row's state")

        let existingDone = hooksEntry(
            surfaceID: surfaceID, sessionID: "parent-session", cwd: "/Users/dev/project", state: .done
        )
        let doneResolution = resolve(
            event("SessionStart", sessionID: "parent-session", agentID: nil, agentType: nil),
            current: existingDone
        )
        let doneUpdated = try XCTUnwrap(writtenEntry(doneResolution))
        XCTAssertEqual(doneUpdated.state, .idle,
                       "A re-sent SessionStart for the same session revives a .done row to .idle")
    }

    // MARK: - retiresChildren

    /// An accepted parent-scoped `Stop` must still settle the row to
    /// `.idle` exactly as before, but must no longer retire the
    /// surface's children -- a still-running child must be allowed to
    /// linger past its parent's own turn ending, since the CLI itself
    /// keeps reporting it running past that point (the real captured
    /// Claude Code sequence this bug was found from).
    func test_acceptedParentStop_settlesRowToIdle_butNoLongerRetiresChildren() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("Stop", agentID: nil, agentType: nil), current: existing)

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.state, .idle, "An accepted parent Stop must still settle the row to .idle")
        XCTAssertFalse(resolution.retiresChildren,
                       "An accepted parent Stop must no longer retire the surface's children")
    }

    /// An accepted parent-scoped `SessionEnd` must still retire every
    /// child of the surface: the parent's own session ending really
    /// does mean no child of it can still be running.
    func test_acceptedParentSessionEnd_stillRetiresChildren() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        let resolution = resolve(event("SessionEnd", agentID: nil, agentType: nil), current: existing)

        _ = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertTrue(resolution.retiresChildren, "An accepted parent SessionEnd must still retire children")
    }

    /// An accepted parent-scoped `SessionStart` (a fresh session
    /// replacing the row) must still retire every child of the surface:
    /// a new session starting means whatever the previous session's
    /// children were, none of them belong to it.
    func test_acceptedParentSessionStart_stillRetiresChildren() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(
            surfaceID: surfaceID, sessionID: "old-session", cwd: "/Users/dev/old", state: .done
        )

        let resolution = resolve(
            event("SessionStart", sessionID: "new-session", cwd: "/Users/dev/new", agentID: nil, agentType: nil),
            current: existing
        )

        _ = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertTrue(resolution.retiresChildren, "An accepted parent SessionStart must still retire children")
    }

    /// A subagent-scoped event must never retire children, whatever its
    /// name -- including one it maps to `.idle`/`.done` for the parent
    /// row like `Stop`/`SessionEnd`, and including `SessionStart`, which
    /// never even reaches the parent row.
    func test_subagentScopedEvent_neverRetiresChildren() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .working)

        for name in ["Stop", "SessionEnd", "SessionStart", "PreToolUse"] {
            let resolution = resolve(event(name), current: existing)
            XCTAssertFalse(resolution.retiresChildren,
                           "A subagent-scoped \(name) must never retire children")
        }
    }

    /// An accepted session-mismatch row replacement -- a forward-moving
    /// event (never `SessionEnd`/`SessionStart`) whose session differs
    /// from the row that was there before, which `resolveHookRow`
    /// accepts by replacing the row outright -- must retire the OLD
    /// session's children: that CLI process is gone, and no
    /// `SubagentStop` for its children can ever arrive once a different
    /// session now owns the surface.
    func test_acceptedSessionMismatchReplacement_retiresOldSessionsChildren() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, sessionID: "old-session", state: .working)

        let resolution = resolve(
            event("PreToolUse", sessionID: "new-session", agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution),
                                    "Precondition: a forward-moving, session-mismatched event on a " +
                                    "non-.done row must be accepted and replace the row -- otherwise this " +
                                    "test proves nothing about the replacement case")
        XCTAssertEqual(updated.sessionID, "new-session",
                       "Precondition: the row now belongs to the new session")
        XCTAssertTrue(resolution.retiresChildren,
                      "An accepted session-mismatch row replacement must retire the OLD session's " +
                      "children -- that CLI process is gone")
    }

    /// An accepted event that PROMOTES an `.mcpConnection` row (whose
    /// `sessionID` is always `nil`) to `.hooks` must not retire children:
    /// the row is learning a session for the first time, not handing the
    /// surface from one session to another, and `AgentRegistry
    /// .handleHookEvent` lets a child be created under any live row --
    /// `.mcpConnection` included -- so a child created moments earlier
    /// under this row must survive its promotion.
    func test_acceptedPromotionFromMCPConnectionRow_doesNotRetireChildren() throws {
        let surfaceID = UUID()
        let existing = AgentEntry(
            surfaceID: surfaceID, sessionID: nil, source: .mcpConnection, state: .idle,
            cwd: nil, kind: AgentEntry.claudeCodeKind, lastEventAt: Date()
        )

        let resolution = resolve(
            event("PreToolUse", sessionID: "parent-session", agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution),
                                    "Precondition: the promoting event must be accepted and replace the row")
        XCTAssertEqual(updated.source, .hooks, "Precondition: the row was promoted to .hooks")
        XCTAssertEqual(updated.sessionID, "parent-session", "Precondition: the row now carries a session")
        XCTAssertFalse(resolution.retiresChildren,
                       "Promoting an .mcpConnection row to .hooks must not retire children -- the row is " +
                       "learning its session for the first time, not changing hands")
    }

    /// The same promotion, from a `.titleHeuristic` row instead.
    func test_acceptedPromotionFromTitleHeuristicRow_doesNotRetireChildren() throws {
        let surfaceID = UUID()
        let existing = AgentEntry(
            surfaceID: surfaceID, sessionID: nil, source: .titleHeuristic, state: .idle,
            cwd: nil, kind: AgentEntry.claudeCodeKind, lastEventAt: Date()
        )

        let resolution = resolve(
            event("PreToolUse", sessionID: "parent-session", agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution),
                                    "Precondition: the promoting event must be accepted and replace the row")
        XCTAssertEqual(updated.source, .hooks, "Precondition: the row was promoted to .hooks")
        XCTAssertEqual(updated.sessionID, "parent-session", "Precondition: the row now carries a session")
        XCTAssertFalse(resolution.retiresChildren,
                       "Promoting a .titleHeuristic row to .hooks must not retire children -- the row is " +
                       "learning its session for the first time, not changing hands")
    }

    /// An accepted session-mismatch replacement where the NEW event
    /// carries no `session_id` at all (a `.hooks` row losing its session
    /// identity, value-to-`nil`) must not retire children either: that
    /// reports missing identity, not a report that a different session
    /// took the row over.
    func test_acceptedValueToNilSessionReplacement_doesNotRetireChildren() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, sessionID: "old-session", state: .working)

        let resolution = resolve(
            event("PreToolUse", sessionID: nil, agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution),
                                    "Precondition: a forward-moving, session-mismatched event on a " +
                                    "non-.done row must be accepted and replace the row")
        XCTAssertNil(updated.sessionID, "Precondition: the new row carries no session at all")
        XCTAssertFalse(resolution.retiresChildren,
                       "A replacement whose new session is nil must not retire children -- that reports " +
                       "missing session identity, not a different session taking the row over")
    }

    /// A rejected (session-mismatched, non-`.done` row) parent-scoped
    /// event must never retire children -- a rejected event says
    /// nothing happened to the parent's turn or session, so it must say
    /// nothing about the parent's children either.
    func test_rejectedMismatchedSessionParentEvent_neverRetiresChildren() {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, sessionID: "real-session", state: .working)

        for name in ["Stop", "SessionEnd"] {
            let resolution = resolve(
                event(name, sessionID: "other-session", agentID: nil, agentType: nil), current: existing
            )
            guard case .keep = resolution.row else {
                return XCTFail("Precondition: a session-mismatched \(name) on a non-.done row must be " +
                               "rejected (.keep) -- otherwise this test proves nothing about the rejected " +
                               "case, got \(resolution.row)")
            }
            XCTAssertFalse(resolution.retiresChildren,
                           "A rejected (session-mismatched) parent-scoped \(name) must never retire children")
        }
    }

    // MARK: - currentToolName / currentToolSummary (Mission Map)
    //
    // AgentEntry.currentToolName / currentToolSummary: set on a PARENT's
    // own PreToolUse via AgentResolution.withCurrentTool(from:), retained
    // across PostToolUse, and cleared on Stop / SessionEnd /
    // UserPromptSubmit. A subagent (child) PreToolUse must never change
    // the parent row's own currentToolName/currentToolSummary -- only the
    // parent's own event may.

    /// A parent's own PreToolUse must set both fields from the event's
    /// own toolName/toolSummary.
    func test_parentPreToolUse_setsCurrentToolNameAndSummary() throws {
        let surfaceID = UUID()
        let existing = hooksEntry(surfaceID: surfaceID, state: .idle)

        let resolution = resolve(
            AgentEvent(
                hookEventName: "PreToolUse", sessionID: "parent-session", cwd: "/Users/dev/project",
                message: nil, agentID: nil, agentType: nil, toolName: "Write",
                toolSummary: "main.swift"
            ),
            current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.currentToolName, "Write")
        XCTAssertEqual(updated.currentToolSummary, "main.swift")
    }

    /// PostToolUse must retain whatever the preceding PreToolUse set --
    /// it does not carry a fresh toolName of its own into the row.
    func test_parentPostToolUse_retainsCurrentTool() throws {
        let surfaceID = UUID()
        var existing = hooksEntry(surfaceID: surfaceID, state: .working)
        existing.currentToolName = "Write"
        existing.currentToolSummary = "main.swift"

        let resolution = resolve(
            event("PostToolUse", agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertEqual(updated.currentToolName, "Write")
        XCTAssertEqual(updated.currentToolSummary, "main.swift")
    }

    /// Stop must clear both fields -- the turn is over, so there is no
    /// "current tool" any more.
    func test_parentStop_clearsCurrentTool() throws {
        let surfaceID = UUID()
        var existing = hooksEntry(surfaceID: surfaceID, state: .working)
        existing.currentToolName = "Write"
        existing.currentToolSummary = "main.swift"

        let resolution = resolve(
            event("Stop", agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertNil(updated.currentToolName)
        XCTAssertNil(updated.currentToolSummary)
    }

    /// SessionEnd must clear both fields -- same reasoning as Stop.
    func test_parentSessionEnd_clearsCurrentTool() throws {
        let surfaceID = UUID()
        var existing = hooksEntry(surfaceID: surfaceID, state: .working)
        existing.currentToolName = "Write"
        existing.currentToolSummary = "main.swift"

        let resolution = resolve(
            event("SessionEnd", agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertNil(updated.currentToolName)
        XCTAssertNil(updated.currentToolSummary)
    }

    /// UserPromptSubmit must clear both fields -- a fresh prompt means
    /// no tool call is in flight yet.
    func test_parentUserPromptSubmit_clearsCurrentTool() throws {
        let surfaceID = UUID()
        var existing = hooksEntry(surfaceID: surfaceID, state: .working)
        existing.currentToolName = "Write"
        existing.currentToolSummary = "main.swift"

        let resolution = resolve(
            event("UserPromptSubmit", agentID: nil, agentType: nil), current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution))
        XCTAssertNil(updated.currentToolName)
        XCTAssertNil(updated.currentToolSummary)
    }

    /// A subagent's own PreToolUse must not change the parent row's
    /// currentToolName/currentToolSummary at all -- the parent row is
    /// only ever updated (state/lastEventAt) by resolveHookRow's shared
    /// child-scoped branch, which withCurrentTool(from:) must not touch.
    func test_subagentPreToolUse_doesNotChangeParentCurrentTool() throws {
        let surfaceID = UUID()
        var existing = hooksEntry(surfaceID: surfaceID, state: .working)
        existing.currentToolName = "Write"
        existing.currentToolSummary = "main.swift"

        let resolution = resolve(
            event("PreToolUse", agentID: "sub-1", agentType: "explore", toolName: "Bash"),
            current: existing
        )

        let updated = try XCTUnwrap(writtenEntry(resolution),
                                    "Precondition: a subagent PreToolUse on an existing .hooks row still " +
                                    "updates state/lastEventAt")
        XCTAssertEqual(updated.currentToolName, "Write",
                       "A subagent's own tool call must never overwrite the parent's currentToolName")
        XCTAssertEqual(updated.currentToolSummary, "main.swift")
    }
}
