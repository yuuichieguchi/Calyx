// AgentStateResolver.swift
// Calyx
//
// Pure state-transition function for AgentRegistry: given a signal and
// everything the registry currently knows about one surface, decides the
// row write (or removal) and the surface's post-signal evidence that
// signal produces. AgentRegistry owns all storage and every side effect
// (peer bindings, inbox counts, external entries); this file owns none --
// `AgentStateResolver.resolve` reads its inputs, returns an
// `AgentResolution`, and touches nothing else.

import Darwin
import Foundation

// MARK: - Signal

/// One fact `AgentRegistry` learned about a surface, in the vocabulary
/// `AgentStateResolver.resolve` consumes. Each case names its own
/// evidence source (a hook POST, an MCP `initialize`, a pane-exit signal,
/// a shell-integration report, a screen poll, a title change, an OSC 9;4
/// progress report, or the periodic staleness sweep) so `resolve` can
/// apply that source's own precedence rules against the surface's
/// current row.
enum AgentSignal: Sendable {
    case hook(AgentEvent, kind: String)
    case mcpConnection(kind: String)
    case paneCommandFinished(exitCode: Int32?, suspended: Bool, origin: PaneCommandOrigin)
    /// Calyx's own shell integration reported something for the surface.
    /// Carries no row effect of its own: it exists so the resolver, not
    /// the registry, owns when an outstanding ghostty deferral is
    /// answered. Only `.commandEnd` answers it -- see
    /// `CalyxShellReportPhase` and `resolveCalyxShellIntegrationReported`.
    case calyxShellIntegrationReported(phase: CalyxShellReportPhase)
    case screen(AgentState?)
    /// Pre-classified: `AgentRegistry.handleTitleChange` constructs this
    /// only when `ClaudeTitleHeuristic.classify` returns non-nil, so a
    /// pane title carrying no agent signal never reaches the resolver.
    /// Non-optional for two reasons. `.screen` above is already
    /// `AgentState?`, where `nil` means "a classification that
    /// recognized nothing", which counts toward retirement; an optional
    /// `.title` would give `nil` two incompatible meanings in adjacent
    /// cases of one enum. And `ClaudeTitleHeuristic` is a per-CLI type,
    /// so classifying at the call site keeps the shared resolver free of
    /// any single agent's parsing.
    case title(AgentState)
    case progress(isActive: Bool)
    case staleSweep
}

/// Which pane-exit channel reported a `.paneCommandFinished` signal --
/// Calyx's own zsh/fish shell integration, or ghostty's OSC 133 fallback.
/// Only `.ghostty` consults `ResolverContext.calyxShellIntegrationSeen`
/// to defer to the more trustworthy Calyx-sourced signal once it has
/// ever reported on the surface.
enum PaneCommandOrigin: Sendable, Equatable {
    case calyxShellIntegration, ghostty
}

/// The phase of a `CommandEvent` Calyx's own shell integration reported,
/// in the resolver's own vocabulary -- kept separate from
/// `CommandEvent.Phase` (`Features/CommandLog/CommandEvent.swift`) so
/// this resolver stays free of the CommandLog feature; `CalyxMCPServer
/// .routeCommandEvent` converts at the boundary. A deferral answers a
/// question only a command's own END can answer -- "did the pane's
/// foreground job actually finish?" -- so only `.commandEnd` carries
/// that answer to `resolveCalyxShellIntegrationReported`.
enum CalyxShellReportPhase: Sendable, Equatable {
    case commandStart, commandEnd
}

// MARK: - Evidence & Context

/// Per-surface accumulated evidence a row itself cannot carry: the
/// count of consecutive `nil` screen classifications a
/// `.titleHeuristic` row has seen since its last positive heuristic
/// signal (a `.blocked`/`.working` screen classification, a `.working`
/// title classification, or an `isActive == true` progress report),
/// when the row entered `.blocked`, and the two timestamps that decide
/// whether a ghostty pane-exit signal deferred to Calyx's own shell
/// integration is still waiting for an answer.
struct AgentEvidence: Sendable, Equatable {
    var screenMissStreak: Int = 0

    /// When the row entered `.blocked` -- `nil` whenever the row is not
    /// `.blocked`. `resolveHookRow`'s `PreToolUse` race guard measures
    /// its window from here rather than from the row's `lastEventAt`,
    /// which is the time of the last ACCEPTED write: a repeated blocking
    /// `Notification` re-stamps that timestamp without the row ever
    /// leaving `.blocked`, sliding the window forward and swallowing a
    /// `PreToolUse` that is genuinely outside it.
    ///
    /// No clause sets this. `resolve` derives it once at its tail, from
    /// the row's state before and after the signal, so whatever a clause
    /// returns for this field is overwritten unconditionally. That is
    /// what makes the anchor impossible to lose: a clause cannot forget
    /// to carry it, and cannot wipe it by rebuilding its evidence.
    var blockedSince: Date? = nil

    /// When ghostty's own pane-exit signal was deferred to Calyx's
    /// shell integration and Calyx has not answered it yet. Nil once
    /// Calyx reports anything for the surface, and nil whenever no
    /// deferral is outstanding. The staleness sweep settles a row whose
    /// deferred signal has gone unanswered: ghostty and Calyx describe
    /// the same command completing and arrive milliseconds apart, so an
    /// unanswered deferral means Calyx's report was lost, and without
    /// this the row could never settle by either route.
    var deferredGhosttyFinishAt: Date? = nil

    /// When Calyx's own shell integration last reported a command's END
    /// for the surface. Read only to decide whether a ghostty deferral
    /// arriving right now is worth recording: a suspend that Calyx just
    /// reported is answered already, and recording a deferral for it
    /// would let the sweep settle a job that is merely stopped. A
    /// `.commandStart` report never stamps this -- see
    /// `resolveCalyxShellIntegrationReported`.
    var lastCalyxCommandEndAt: Date? = nil

    var isEmpty: Bool {
        screenMissStreak == 0 && blockedSince == nil
            && deferredGhosttyFinishAt == nil && lastCalyxCommandEndAt == nil
    }

    /// The evidence after a positive heuristic signal: a
    /// `.blocked`/`.working` screen classification, a `.working` title
    /// classification, or an active progress report. Each is direct
    /// evidence the pane holds a live agent, so the run of screen
    /// classifications that recognized nothing stops counting toward
    /// retirement.
    func clearingScreenMissStreak() -> AgentEvidence {
        var copy = self
        copy.screenMissStreak = 0
        return copy
    }

    /// The evidence after a screen classification that recognized
    /// nothing. Five consecutive misses retire a `.titleHeuristic` row,
    /// which is the only way such a row goes away on its own.
    func incrementingScreenMissStreak() -> AgentEvidence {
        var copy = self
        copy.screenMissStreak += 1
        return copy
    }

    /// The evidence after an agent reports its own presence, through a
    /// hook event or an MCP connection. Both supersede what Calyx
    /// inferred by watching the pane: any heuristic miss streak is
    /// stale, and so is a ghostty pane-exit signal still waiting for an
    /// answer. What Calyx's own shell integration last reported is
    /// untouched, because neither kind of event says anything about it.
    func clearingInferredEvidence() -> AgentEvidence {
        var copy = self
        copy.screenMissStreak = 0
        copy.deferredGhosttyFinishAt = nil
        return copy
    }
}

/// Registry-wide facts a clause needs that are not per-surface evidence.
struct ResolverContext: Sendable {
    /// Whether `CalyxMCPServer`'s IPC listener is currently running --
    /// gates the `.title` clause's row-creation branch the same way
    /// `CalyxWindowController.pollScreenClassificationIfAgentsSidebarVisible`
    /// already gates screen classification: a row created while the
    /// server is stopped would have no way to ever retire, since the
    /// retirement sweep lives inside screen classification's own
    /// server-gated poll.
    var isServerRunning: Bool
    /// Whether Calyx's own shell integration has ever reported on THIS
    /// surface (`AgentRegistry.calyxShellIntegrationReportedSurfaces`).
    /// Consulted only by a `.paneCommandFinished` signal whose origin is
    /// `.ghostty`.
    var calyxShellIntegrationSeen: Bool
}

// MARK: - Resolution

/// The effect one `AgentStateResolver.resolve` call has on a surface: the
/// row write (if any) and the surface's evidence after the signal.
struct AgentResolution: Sendable {
    /// Three cases rather than `AgentEntry?`: a `nil` would conflate
    /// "leave an absent row absent" with "remove the row", and the
    /// latter would fire an `@Observable` mutation on every ignored
    /// screen classification for an ordinary shell pane.
    enum RowAction: Sendable {
        case keep, write(AgentEntry), remove
    }

    let row: RowAction
    /// The evidence AFTER this signal, always populated even on `.keep`
    /// -- a hook event, an MCP connection, a `.working` title, and an
    /// active progress report all reset the miss streak without
    /// otherwise touching the row.
    let evidence: AgentEvidence
    /// Whether this call actually settled the row to `.done`. Always
    /// `false` outside `.paneCommandFinished`, including every one of
    /// its own guards -- `CalyxMCPServer.routeCommandEvent` gates
    /// `ApprovalInboxStore.expireForSurface` on it.
    let didSettle: Bool
    /// A peer ID this signal reported for the surface, if any -- a
    /// calyx-ipc tool call's own self-reported peer. `nil` for every
    /// other signal and every other event. The registry performs the
    /// binding rather than the resolver: a binding is a registry-wide
    /// bijection whose maintenance evicts a DIFFERENT surface from the
    /// map, which a per-surface resolution cannot express. Deciding it
    /// is still the resolver's job, so an event is interpreted in
    /// exactly one place.
    let learnedPeerID: UUID?
    /// Whether this signal must retire every child `SubagentRegistry`
    /// tracks under this surface. `resolveHook` sets it, on an accepted
    /// (`RowAction.write`) non-subagent `.hook`, whenever either of two
    /// CLI-reported facts holds: the event's name is one of
    /// `Self.parentSessionBoundaryEventNames`, or the written row and the
    /// row it replaced each name a session and those sessions differ --
    /// a different session took the row over, which is itself a fact the
    /// CLI reported, not a guess. A row merely learning a session for the
    /// first time (an `.mcpConnection`/`.titleHeuristic` row, whose
    /// `sessionID` is always `nil`, promoted to `.hooks`) does not count
    /// on its own: `nil` on one side means no session to compare
    /// against, not a handoff. `false` for every signal but `.hook`, and `false` for a `.hook`
    /// this resolver rejected for the parent row (`RowAction.keep`) -- a
    /// rejected event says nothing happened to the parent's session, so
    /// it must say nothing about the parent's children either. An
    /// accepted parent `Stop` that leaves the row's own session
    /// unchanged is `false` too: the parent's own turn ending says
    /// nothing about whether any of its children are still running.
    let retiresChildren: Bool

    /// Private so the factories below are the only way to build a
    /// resolution. Two combinations of these fields are destructive and
    /// must stay unrepresentable: a settle that writes no row would
    /// expire a live agent's pending approvals while leaving its row
    /// untouched, and a peer binding attached to a signal that never
    /// reports one would evict a different surface's binding.
    private init(
        row: RowAction, evidence: AgentEvidence, didSettle: Bool, learnedPeerID: UUID?,
        retiresChildren: Bool = false
    ) {
        self.row = row
        self.evidence = evidence
        self.didSettle = didSettle
        self.learnedPeerID = learnedPeerID
        self.retiresChildren = retiresChildren
    }

    /// The signal changed no row. Its evidence may still have changed.
    static func keep(evidence: AgentEvidence) -> AgentResolution {
        AgentResolution(row: .keep, evidence: evidence, didSettle: false, learnedPeerID: nil)
    }

    static func write(_ entry: AgentEntry, evidence: AgentEvidence) -> AgentResolution {
        AgentResolution(row: .write(entry), evidence: evidence, didSettle: false, learnedPeerID: nil)
    }

    static func remove(evidence: AgentEvidence) -> AgentResolution {
        AgentResolution(row: .remove, evidence: evidence, didSettle: false, learnedPeerID: nil)
    }

    /// The only producer of `didSettle == true`. It takes the settled
    /// row, so a settle that writes nothing cannot be expressed.
    static func settled(_ entry: AgentEntry, evidence: AgentEvidence) -> AgentResolution {
        AgentResolution(row: .write(entry), evidence: evidence, didSettle: true, learnedPeerID: nil)
    }

    /// Wraps a row action a shared sub-clause already decided.
    static func applying(_ row: RowAction, evidence: AgentEvidence) -> AgentResolution {
        AgentResolution(row: row, evidence: evidence, didSettle: false, learnedPeerID: nil)
    }

    /// Attaches the peer a hook event reported. Only `resolveHook` calls
    /// this, so no other signal can reach `bindSurface`.
    func withLearnedPeerID(_ peerID: UUID?) -> AgentResolution {
        AgentResolution(
            row: row, evidence: evidence, didSettle: didSettle, learnedPeerID: peerID,
            retiresChildren: retiresChildren
        )
    }

    /// The event names after which the parent turn has no tool call in
    /// flight: the turn ended, the session ended, or a fresh prompt
    /// started a turn that has not called anything yet.
    private static let currentToolClearingEventNames: Set<String> = [
        "Stop", "SessionEnd", "UserPromptSubmit",
    ]

    /// Maintains the written row's `currentToolName`/`currentToolSummary`
    /// from a parent-scoped hook event: a `PreToolUse` sets both from the
    /// event, `Stop` / `SessionEnd` / `UserPromptSubmit` clear both, and
    /// every other event (`PostToolUse` included) leaves whatever the row
    /// already carries. Only `resolveHook` calls this.
    ///
    /// A subagent event returns `self` unchanged: the child's own tool is
    /// `SubagentRegistry`'s to show, and writing it onto the parent row
    /// would make the parent card describe a call the parent never made.
    /// A `.keep` or `.remove` also returns `self`: the event was not
    /// accepted for the row, so it says nothing about the row's tool.
    func withCurrentTool(from event: AgentEvent) -> AgentResolution {
        guard !event.isSubagentEvent, case .write(var entry) = row else { return self }
        if event.hookEventName == "PreToolUse" {
            entry.currentToolName = event.toolName
            entry.currentToolSummary = event.toolSummary
        } else if Self.currentToolClearingEventNames.contains(event.hookEventName) {
            entry.currentToolName = nil
            entry.currentToolSummary = nil
        } else {
            return self
        }
        return AgentResolution(
            row: .write(entry), evidence: evidence, didSettle: didSettle, learnedPeerID: learnedPeerID,
            retiresChildren: retiresChildren
        )
    }

    /// Marks this resolution as retiring every child of the surface it
    /// resolves. Only `resolveHook` calls this, on its way out, once it
    /// already knows the event was both parent-scoped and accepted for
    /// the parent row.
    func retiringChildren() -> AgentResolution {
        AgentResolution(
            row: row, evidence: evidence, didSettle: didSettle, learnedPeerID: learnedPeerID,
            retiresChildren: true
        )
    }

    /// Re-derives when the row entered `.blocked`. `resolve` calls this
    /// once on the way out, so no clause has to remember to maintain it
    /// and none can wipe it by returning fresh evidence.
    func trackingBlockedSince(
        previousState: AgentState?,
        incomingBlockedSince: Date?,
        now: Date
    ) -> AgentResolution {
        let finalState: AgentState?
        switch row {
        case .keep: finalState = previousState
        case .write(let entry): finalState = entry.state
        case .remove: finalState = nil
        }
        var updated = evidence
        if finalState == .blocked {
            updated.blockedSince = previousState == .blocked ? incomingBlockedSince : now
        } else {
            updated.blockedSince = nil
        }
        return AgentResolution(
            row: row, evidence: updated, didSettle: didSettle, learnedPeerID: learnedPeerID,
            retiresChildren: retiresChildren
        )
    }
}

// MARK: - Resolver

enum AgentStateResolver {

    // MARK: Shared Constants

    /// Case-insensitive notification message substrings that indicate a
    /// blocked (permission / input needed) agent. A server-side backstop
    /// for the `Notification` hook's `matcher: "permission_prompt"`
    /// filter `ClaudeHooksConfigManager` configures: when the message is
    /// present but doesn't match, `resultingState` leaves state
    /// unchanged (a `Notification` unrelated to permissions/input
    /// shouldn't flip a row to blocked). A `nil` message *does* resolve
    /// to `.blocked` -- see `resultingState`.
    private static let blockedNotificationPatterns: [String] = [
        "needs your permission",
        "waiting for your input",
    ]

    /// `.working` entries idle this long without a new hook event are
    /// treated as crashed by `AgentRegistry.sweepStaleEntries`.
    private static let staleWorkingThreshold: TimeInterval = 15 * 60

    /// Consecutive `nil` screen-classification results (no known
    /// blocked/working pattern recognized) that retire a
    /// `.titleHeuristic` row -- see `resolveScreen`. At the screen
    /// poll's 2-second interval, 5 misses is ~10 seconds. See
    /// `AgentRegistry.evidence`'s doc comment.
    private static let heuristicMissRetirementThreshold = 5

    /// Hook events that represent forward progress within a session,
    /// used by `AgentRegistry.handleHookEvent`'s session-mismatch
    /// reconciliation. `PermissionRequest` (Codex, Phase 2) is
    /// deliberately excluded: unlike `UserPromptSubmit`/`PreToolUse`/
    /// `PostToolUse`, seeing one for an unrecognized session isn't good
    /// evidence of a genuine new session Calyx missed the `SessionStart`
    /// for -- it's at least as likely a stale/mismatched permission
    /// prompt from a session that's already ending, and replacing the
    /// entry on that basis would incorrectly flip an active row to
    /// `.blocked`.
    private static let forwardMovingEventNames: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse",
    ]

    /// Hook event names that, on the PARENT's own event (never a
    /// subagent event) and only once `resolveHookRow` has actually
    /// ACCEPTED that event for the parent row, mean no child of the
    /// surface can still be running: the parent's session ended
    /// (`SessionEnd`) or a new session started (`SessionStart`). This is
    /// one of two facts `resolveHook` treats as children-retiring; the
    /// other, decided independently of any event name, is a different
    /// session taking the row over -- see `AgentResolution
    /// .retiresChildren`'s own doc comment for what that requires (both
    /// the written row and the row it replaced must actually name a
    /// session, so a row merely learning its first session, such as an
    /// `.mcpConnection` row promoted to `.hooks`, does not qualify on its
    /// own). `Stop` is
    /// deliberately excluded from this set: a captured real Claude Code
    /// run shows the parent's own `Stop` firing, several times across a
    /// turn, while both of its subagents were still mid-flight -- a CLI
    /// can and does keep a subagent running past the parent's own turn
    /// ending, so treating `Stop` as a children-retiring event deleted
    /// rows the CLI still reported live. An accepted `Stop` still retires
    /// children when it lands via the session-mismatch replacement path
    /// (a `.done` row's session differs from the event's), since that is
    /// the other, name-independent fact. `resolveHook` is the only
    /// reader of this set -- see its own `retiringChildren` call. This is
    /// also what makes a CLI that omits `agent_id` on its own
    /// `SubagentStop` degrade rather than leak permanently, though the
    /// degradation window is now longer than a turn: the lingering child
    /// survives an accepted, same-session parent `Stop` and only goes
    /// away on an ACCEPTED `SessionEnd`/`SessionStart`, a session-mismatch
    /// row replacement, the pane exiting, or the parent row settling
    /// `.done`. That trade is still the right one: deleting a child the
    /// CLI still reports running is the worse violation of the two. A
    /// `SessionEnd`/`SessionStart` this resolver rejects (a session
    /// mismatch on a non-`.done` row) never reaches either check.
    private static let parentSessionBoundaryEventNames: Set<String> = [
        "SessionEnd", "SessionStart",
    ]

    /// Window within which a same-session `PreToolUse` following a
    /// transition to `.blocked` is treated as a stale async-delivery
    /// race rather than genuine forward progress, and is dropped rather
    /// than clearing `.blocked` -- see `AgentRegistry.handleHookEvent`'s
    /// own guard for the full rationale (why 1.5s, and the accepted
    /// trade-off).
    private static let preToolUseRaceWindow: TimeInterval = 1.5

    /// POSIX signals that can only stop (suspend) a process, never
    /// terminate it -- unlike every other signal, delivering one of
    /// these leaves the process alive, waiting to be resumed. See
    /// `isStopSignalExitCode`.
    private static let stopSignals: Set<Int32> = [SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU]

    /// How recently Calyx's own shell integration must have reported a
    /// command's END (`AgentEvidence.lastCalyxCommandEndAt`) for a
    /// ghostty deferral arriving now to count as already answered, and
    /// so not be recorded at all. The two signals for one command arrive
    /// within milliseconds of each other in either order, and it is the
    /// order where Calyx reports FIRST that needs this: without it a
    /// suspend Calyx already answered would record a deferral nothing
    /// can ever clear, and `resolveStaleSweep` would retire a job that is
    /// merely stopped.
    private static let calyxReportGraceWindow: TimeInterval = 2

    /// How long a deferred ghostty pane-exit signal may go unanswered by
    /// Calyx's own shell integration before `resolveStaleSweep` settles
    /// the row on it. Well past the milliseconds the two signals for one
    /// command are actually separated by, so only a Calyx report that
    /// was genuinely lost reaches it. The sweep runs once a minute, so a
    /// lost report costs a stale row for at most this plus that interval.
    private static let deferredGhosttySettleDelay: TimeInterval = 30

    // MARK: Entry Point

    static func resolve(
        _ signal: AgentSignal,
        surfaceID: UUID,
        current: AgentEntry?,
        evidence: AgentEvidence,
        context: ResolverContext,
        now: Date
    ) -> AgentResolution {
        let resolution: AgentResolution
        switch signal {
        case .hook(let event, let kind):
            resolution = resolveHook(
                event, kind: kind, surfaceID: surfaceID, current: current,
                evidence: evidence, blockedSince: evidence.blockedSince, now: now
            )
        case .staleSweep:
            resolution = resolveStaleSweep(current: current, evidence: evidence, now: now)
        case .mcpConnection(let kind):
            resolution = resolveMCPConnection(
                kind: kind, surfaceID: surfaceID, current: current, evidence: evidence, now: now
            )
        case .paneCommandFinished(let exitCode, let suspended, let origin):
            resolution = resolvePaneCommandFinished(
                exitCode: exitCode, suspended: suspended, origin: origin,
                current: current, evidence: evidence, context: context, now: now
            )
        case .calyxShellIntegrationReported(let phase):
            resolution = resolveCalyxShellIntegrationReported(phase: phase, evidence: evidence, now: now)
        case .screen(let state):
            resolution = resolveScreen(
                state, surfaceID: surfaceID, current: current, evidence: evidence, now: now
            )
        case .title(let classified):
            resolution = resolveTitle(
                classified, surfaceID: surfaceID, current: current,
                evidence: evidence, context: context, now: now
            )
        case .progress(let isActive):
            resolution = resolveProgress(isActive, current: current, evidence: evidence, now: now)
        }
        return resolution.trackingBlockedSince(
            previousState: current?.state,
            incomingBlockedSince: evidence.blockedSince,
            now: now
        )
    }

    /// Two independent reasons to correct a self-reported row
    /// (`AgentSource.isSelfReported`) nothing else is going to correct.
    /// An inferred row is never swept at all: it retires itself through
    /// its own miss-streak bookkeeping instead.
    ///
    /// First, a ghostty pane-exit signal `resolvePaneCommandFinished`
    /// deferred to Calyx's own shell integration and Calyx never
    /// answered (`AgentEvidence.deferredGhosttyFinishAt` older than
    /// `deferredGhosttySettleDelay`) settles the row to `.done` and
    /// clears the deferral. The two signals for one command arrive
    /// within milliseconds of each other, so a deferral still
    /// outstanding this long means Calyx's own report was lost -- the
    /// shell integration body swallows a failed POST -- and nothing else
    /// will ever settle this row: Calyx never reports the end, and
    /// ghostty already deferred to the report that never came. This
    /// reason runs ahead of the staleness check below because it applies
    /// to a row in ANY live state, `.blocked` very much included: the
    /// user-visible symptom is a finished agent's row stuck red.
    ///
    /// Second, a `.working` row whose last event is older than
    /// `staleWorkingThreshold` is downgraded to `.idle`, guarding
    /// against an agent process that exits non-gracefully (crash,
    /// `kill -9`, terminal force-close) and so never sends its own
    /// terminal hook: without this the row would stay frozen at
    /// `.working` forever. `.blocked` rows are excluded from THIS
    /// reason: a permission prompt left unanswered for a long time is a
    /// legitimate wait, not staleness.
    ///
    /// Neither write stamps `lastEventAt`, alone in the registry. The
    /// row's timestamp still means "when this agent last reported", and
    /// the sweep is Calyx's own inference rather than a report from the
    /// agent, so advancing it would both lie to the sidebar's
    /// relative-time label and reset the very window that triggered the
    /// correction.
    ///
    /// Neither write settles in the `AgentResolution.settled` sense
    /// either: both go out through `.write`, so `didSettle` stays
    /// `false`. That is load-bearing for the first reason, whose
    /// evidence is ghostty's signal, and a ghostty-sourced settle never
    /// expires a surface's pending approvals -- only a Calyx-sourced one
    /// over `/command-event` does (`CalyxMCPServer.routeCommandEvent`).
    private static func resolveStaleSweep(
        current: AgentEntry?,
        evidence: AgentEvidence,
        now: Date
    ) -> AgentResolution {
        guard let existing = current else {
            return .keep(evidence: evidence)
        }
        guard existing.source.isSelfReported else {
            return .keep(evidence: evidence)
        }

        if existing.state != .done,
           let deferredAt = evidence.deferredGhosttyFinishAt,
           now.timeIntervalSince(deferredAt) > deferredGhosttySettleDelay {
            var updated = existing
            updated.state = .done
            var answered = evidence
            answered.deferredGhosttyFinishAt = nil
            return .write(updated, evidence: answered)
        }

        guard existing.state == .working else {
            return .keep(evidence: evidence)
        }
        guard now.timeIntervalSince(existing.lastEventAt) > staleWorkingThreshold else {
            return .keep(evidence: evidence)
        }

        var updated = existing
        updated.state = .idle
        return .write(updated, evidence: evidence)
    }

    // MARK: Calyx Shell Integration Report Signal

    /// Records that Calyx's own shell integration reported the END of a
    /// command for the surface, and answers any outstanding ghostty
    /// deferral in the same step. Touches no row: even a command's own
    /// end report says nothing about whether the pane's foreground JOB
    /// exited (a suspend also reaches `phase: end`), which is what
    /// `.paneCommandFinished` decides.
    ///
    /// A `.commandStart` report answers nothing -- a command merely
    /// STARTING says nothing about whether any earlier command, or this
    /// one, has finished -- so it leaves `evidence` completely
    /// untouched: neither stamping `lastCalyxCommandEndAt` nor clearing
    /// `deferredGhosttyFinishAt`. A deferral can only be answered by the
    /// fact it is a question about: did the foreground job end.
    private static func resolveCalyxShellIntegrationReported(
        phase: CalyxShellReportPhase,
        evidence: AgentEvidence,
        now: Date
    ) -> AgentResolution {
        guard phase == .commandEnd else {
            return .keep(evidence: evidence)
        }
        var updated = evidence
        updated.lastCalyxCommandEndAt = now
        updated.deferredGhosttyFinishAt = nil
        return .keep(evidence: updated)
    }

    /// Records explicit agent-presence evidence from a surface-bound MCP
    /// `initialize` request: presence before a pane's first hook event
    /// arrives, and for a pane whose CLI has no hooks at all.
    ///
    /// An `initialize` is presence evidence in its own right, so it
    /// clears any heuristic miss streak the surface accumulated,
    /// unconditionally and regardless of what happens to the row.
    ///
    /// A same-kind `.hooks` or `.mcpConnection` row stays authoritative,
    /// with one exception: `.done`. Both guards below phrase that as
    /// part of a "stay put" condition rather than as a refusal, so a
    /// `.done` row FALLS THROUGH both into the replace below. That
    /// fall-through is deliberate and load-bearing: a pane holding a
    /// finished row that starts a fresh agent session reports the new
    /// session through this call alone, so it must become a live `.idle`
    /// row rather than stranding the live session behind the finished
    /// one's.
    ///
    /// `kind` participates in precedence here and nowhere else in the
    /// registry: a `.hooks` row of a DIFFERENT kind falls through to the
    /// replace even while live and `.working`, because the initialize is
    /// evidence a different CLI now owns the pane.
    ///
    /// The replace carries `cwd` and `unreadCount` over from the row it
    /// replaces (the only replace in the registry that preserves the
    /// unread badge) and drops `sessionID`, which belonged to the hooks
    /// session that is no longer the row's source. A `.titleHeuristic`
    /// row's state carries over too, since a heuristic reading of a live
    /// pane is better evidence than assuming `.idle`.
    private static func resolveMCPConnection(
        kind: String,
        surfaceID: UUID,
        current: AgentEntry?,
        evidence: AgentEvidence,
        now: Date
    ) -> AgentResolution {
        let clearedEvidence = evidence.clearingInferredEvidence()

        guard let existing = current else {
            let entry = AgentEntry(
                surfaceID: surfaceID,
                sessionID: nil,
                source: .mcpConnection,
                state: .idle,
                cwd: nil,
                kind: kind,
                lastEventAt: now,
                unreadCount: 0
            )
            return .write(entry, evidence: clearedEvidence)
        }

        if existing.source == .hooks, existing.kind == kind, existing.state != .done {
            return .keep(evidence: clearedEvidence)
        }

        // Same source and kind, still live: refresh presence and change
        // nothing else, so a screen-classified `.working` row does not
        // flash back to `.idle` on every re-initialize. The registry's
        // one deliberate `lastEventAt`-only write.
        if existing.source == .mcpConnection, existing.kind == kind, existing.state != .done {
            var updated = existing
            updated.lastEventAt = now
            return .write(updated, evidence: clearedEvidence)
        }

        let initialState = existing.source == .titleHeuristic ? existing.state : .idle
        let entry = AgentEntry(
            surfaceID: surfaceID,
            sessionID: nil,
            source: .mcpConnection,
            state: initialState,
            cwd: existing.cwd,
            kind: kind,
            lastEventAt: now,
            unreadCount: existing.unreadCount
        )
        return .write(entry, evidence: clearedEvidence)
    }

    /// Resolves a hook event's row effect, then carries two facts
    /// independent of the row itself on the result. The peer ID the
    /// event reported (if any) rides along on every resolution this
    /// event produces, including the ones that leave the row untouched.
    /// And, once the row effect is known, whether this event retires
    /// every child `SubagentRegistry` tracks under the surface:
    /// `retiringChildren()` applies only when the event is NOT
    /// subagent-scoped and `resolveHookRow` actually accepted it for the
    /// parent row (`RowAction.write`) -- a rejected event (a session
    /// mismatch on a non-`.done` row) never reaches a live child's
    /// lifetime, exactly as it never reaches the parent row -- and, on
    /// top of that, one of two CLI-reported facts holds: the event's
    /// name is one of `parentSessionBoundaryEventNames`, or the row this
    /// call just wrote names a session that differs from the session the
    /// row it replaced named -- i.e. a different session took the row
    /// over. Both sides must actually name a session for that second
    /// condition to hold: a row being promoted from `.mcpConnection`/
    /// `.titleHeuristic` (which carry no `sessionID` of their own) to
    /// `.hooks` is `nil` learning a session for the first time, not a
    /// session handoff, so it does not retire children on its own --
    /// only the accompanying session-boundary event name can. An
    /// accepted parent `Stop` that leaves the row's own session unchanged
    /// settles the parent row same as before but triggers neither
    /// condition, so it never reaches this check at all; a `Stop` that
    /// instead lands via a session-mismatch replacement does, since a
    /// different session really did take the row over. The child's
    /// lifetime is decided HERE, in the same place that decided the
    /// parent's, rather than re-derived from the event's name a second
    /// time somewhere else.
    private static func resolveHook(
        _ event: AgentEvent,
        kind: String,
        surfaceID: UUID,
        current: AgentEntry?,
        evidence: AgentEvidence,
        blockedSince: Date?,
        now: Date
    ) -> AgentResolution {
        let resolution = resolveHookRow(
            event, kind: kind, surfaceID: surfaceID, current: current,
            evidence: evidence, blockedSince: blockedSince, now: now
        )
        .withLearnedPeerID(event.ipcSelfPeerID.flatMap(UUID.init(uuidString:)))
        .withCurrentTool(from: event)

        guard !event.isSubagentEvent, case .write(let entry) = resolution.row else {
            return resolution
        }
        let previousSessionID = current?.sessionID
        let tookOverFromADifferentSession =
            entry.sessionID != nil && previousSessionID != nil && entry.sessionID != previousSessionID
        guard parentSessionBoundaryEventNames.contains(event.hookEventName)
            || tookOverFromADifferentSession
        else {
            return resolution
        }
        return resolution.retiringChildren()
    }

    /// Applies a CLI hook event, the strongest evidence the registry
    /// has: a live agent reporting its own lifecycle. A hook event
    /// clears any heuristic miss streak for the surface unconditionally,
    /// whether it promotes an existing `.titleHeuristic` row, replaces a
    /// row, or changes nothing at all.
    ///
    /// A subagent event (`AgentEvent.isSubagentEvent`, `agentID != nil`)
    /// must never create, replace, or promote a row of its own -- a
    /// child shares its parent's row, it never gets one. This branch
    /// runs FIRST, before every other clause including `SessionStart`,
    /// because no event name is an exception to that rule: a child
    /// starting its own session says nothing about the parent's, so a
    /// subagent-scoped `SessionStart` must never reach the block below
    /// that treats `SessionStart` as answering to no precedence at all.
    /// Running first also means a child PreToolUse (which maps to
    /// `.working`) structurally cannot reach either the `makeEntry`
    /// creation branch (no current row) or the forward-moving
    /// replacement branch (session mismatch): both would otherwise be
    /// reachable for a child event whose sessionID a CLI adapter may
    /// have stripped or never carried in the first place. Only an
    /// existing, matching-source, non-terminal `.hooks` row's `state`
    /// and `lastEventAt` are ever written; sessionID/cwd/kind are left
    /// exactly as they were.
    ///
    /// A child may report onto the parent row only what its OWN
    /// activity or wait says about the pane: `.working` (it is doing
    /// something) or `.blocked` (it is waiting on the user). It can
    /// never report the parent's own turn ending or the parent's own
    /// session ending, since only the parent's own event can say
    /// either is true -- a child finishing tells us nothing about
    /// whether the parent's turn, or session, is over. Concretely,
    /// this excludes `resultingState(for:)`'s `.idle` (`Stop`) and
    /// `.done` (`SessionEnd`) results from ever reaching the parent
    /// row when the event is subagent-scoped: a Grok child's own
    /// `SessionEnd` teardown, or an OpenCode child's own `Stop`
    /// (mapped from `session.idle`), must never settle or idle a
    /// still-working parent. The same reasoning excludes `SessionStart`
    /// itself, which maps to no `resultingState(for:)` result at all:
    /// a child beginning a fresh session of its own must never replace,
    /// revive, or otherwise touch the parent row.
    ///
    /// `SessionStart` is resolved before the event is mapped to a state,
    /// for two reasons. It maps to no state of its own, so mapping first
    /// would swallow it entirely. And it is the one event that answers
    /// to no precedence at all: no source guard, no session guard, no
    /// terminal-state guard. A pane reporting a new session is a live
    /// pane, whatever its row said a moment ago. A re-sent
    /// `SessionStart` for the SAME session instead preserves the row's
    /// state (so `/compact` or `/resume` does not flash a working row
    /// back to idle), except that it revives a finished one: the session
    /// is running again.
    ///
    /// An unrecognized event resolves to no state and stops here, before
    /// any terminal-state guard is reached. A `Notification` whose
    /// message matches no known blocking pattern is exactly that case.
    ///
    /// A `.done` row is terminal against every remaining event, in two
    /// separate places: for a row this event does not own
    /// (`.mcpConnection` settled by a pane-exit signal, which a stray
    /// resolved event must not silently undo), and for this event's own
    /// session. The one exception is a session mismatch, where `.done`
    /// is what ENABLES the replacement: a finished session's row should
    /// give way to a different session's evidence.
    ///
    /// A mismatched session is otherwise only allowed to replace the row
    /// on forward progress, or to rescue an idle row from a
    /// `PermissionRequest`. A `.working` or `.blocked` row is left alone
    /// there, since a mismatched permission prompt is at least as likely
    /// to be a straggler from a session already ending as it is evidence
    /// of a session Calyx missed the start of.
    private static func resolveHookRow(
        _ event: AgentEvent,
        kind: String,
        surfaceID: UUID,
        current: AgentEntry?,
        evidence: AgentEvidence,
        blockedSince: Date?,
        now: Date
    ) -> AgentResolution {
        let clearedEvidence = evidence.clearingInferredEvidence()

        func makeEntry(state: AgentState) -> AgentEntry {
            AgentEntry(
                surfaceID: surfaceID,
                sessionID: event.sessionID,
                source: .hooks,
                state: state,
                cwd: event.cwd,
                kind: kind,
                lastEventAt: now
            )
        }

        if event.isSubagentEvent {
            guard let existing = current, existing.source == .hooks, existing.state != .done else {
                return .keep(evidence: clearedEvidence)
            }
            guard let newState = resultingState(for: event), newState == .working || newState == .blocked else {
                return .keep(evidence: clearedEvidence)
            }
            if existing.state == .blocked,
               event.hookEventName == "PreToolUse",
               let blockedSince,
               now.timeIntervalSince(blockedSince) < preToolUseRaceWindow {
                return .keep(evidence: clearedEvidence)
            }
            var updated = existing
            updated.state = newState
            updated.lastEventAt = now
            return .write(updated, evidence: clearedEvidence)
        }

        if event.hookEventName == "SessionStart" {
            if let existing = current, existing.source == .hooks, existing.sessionID == event.sessionID {
                var updated = existing
                updated.cwd = event.cwd
                updated.lastEventAt = now
                if existing.state == .done {
                    updated.state = .idle
                }
                return .write(updated, evidence: clearedEvidence)
            }
            return .write(makeEntry(state: .idle), evidence: clearedEvidence)
        }

        guard let newState = resultingState(for: event) else {
            return .keep(evidence: clearedEvidence)
        }

        guard let existing = current, existing.source == .hooks else {
            guard current?.state != .done else {
                return .keep(evidence: clearedEvidence)
            }
            return .write(makeEntry(state: newState), evidence: clearedEvidence)
        }

        guard existing.sessionID == event.sessionID else {
            let isForwardMoving = forwardMovingEventNames.contains(event.hookEventName)
            let isPermissionRequestIdleRescue =
                event.hookEventName == "PermissionRequest" && existing.state == .idle
            guard existing.state == .done || isForwardMoving || isPermissionRequestIdleRescue else {
                return .keep(evidence: clearedEvidence)
            }
            return .write(makeEntry(state: newState), evidence: clearedEvidence)
        }

        guard existing.state != .done else {
            return .keep(evidence: clearedEvidence)
        }

        // A hook script's POST never blocks the CLI, so two hooks fired
        // moments apart in the real event order (a tool call's own
        // `PreToolUse`, then a DIFFERENT tool call's permission dialog
        // appearing) can land here out of that order. A `PreToolUse`
        // arriving within this window of the moment the row ENTERED
        // `.blocked` is treated as that stale delivery race rather than
        // genuine forward progress, so the row does not flash back to
        // `.working` while the dialog the user actually sees is still
        // up. The anchor is `blockedSince`, never the row's
        // `lastEventAt`: a repeated blocking `Notification` re-stamps
        // that timestamp without the row ever leaving `.blocked`, which
        // would slide the window forward for as long as the prompt keeps
        // being reported.
        // `PostToolUse`, `Stop` and `UserPromptSubmit` are deliberately
        // not covered: each fires only once the prompt was actually
        // resolved, so they must keep clearing `.blocked` immediately.
        //
        // Accepted trade-off: a genuinely new, unrelated tool call's
        // `PreToolUse` landing in the same window right after a
        // rejection is dropped too. The row stays visibly stale for at
        // most that window either way, and the next event none of this
        // guard covers corrects it.
        if existing.state == .blocked,
           event.hookEventName == "PreToolUse",
           let blockedSince,
           now.timeIntervalSince(blockedSince) < preToolUseRaceWindow {
            return .keep(evidence: clearedEvidence)
        }

        // `cwd` is deliberately not re-derived: `SessionStart`
        // established it for the session's lifetime, and a session's
        // working directory does not change mid-session.
        var updated = existing
        updated.state = newState
        updated.lastEventAt = now
        return .write(updated, evidence: clearedEvidence)
    }

    // MARK: Pane Command Finished Signal

    /// Settles a self-reported row (`AgentSource.isSelfReported`) not
    /// already `.done` to `.done` on a pane-exit signal, excluding a
    /// `suspended` report or a stop-signal `exitCode`
    /// (`isStopSignalExitCode`) -- either is positive evidence the
    /// pane's foreground job is merely stopped, not exited. An
    /// unregistered surface and an inferred row are both left untouched.
    /// The `.done` guard is not an escape hatch reachable by anything
    /// else -- it exists purely to avoid `lastEventAt` churn on a row
    /// that already settled.
    ///
    /// `origin == .ghostty` defers entirely -- `.keep`, `didSettle:
    /// false` -- once `context.calyxShellIntegrationSeen` is `true`:
    /// ghostty's own OSC 133 fallback has no way to positively detect a
    /// suspend the way Calyx's own zsh/fish shell integration can
    /// (zsh's `128 + signal` convention, or fish's own separate
    /// lingering-job check), so once that integration has ever reported
    /// on a surface, it alone is trusted to tell a suspend apart from a
    /// real exit for it. This guard runs before even checking whether a
    /// row exists -- the memory it consults is independent of `current`
    /// entirely. `origin == .calyxShellIntegration` never consults it: a
    /// `suspended` report or a stop-signal `exitCode` from that origin
    /// is evidence the signal already carries directly, needing no
    /// deferral to itself.
    ///
    /// A deferral is not a discard, though. It is recorded on the
    /// surface's evidence (`AgentEvidence.deferredGhosttyFinishAt`) so
    /// `resolveStaleSweep` can settle the row if Calyx never answers it
    /// -- see that clause and the field's own doc comment. The one case
    /// that records nothing is a deferral arriving within
    /// `calyxReportGraceWindow` of Calyx's own last command-END report
    /// (`AgentEvidence.lastCalyxCommandEndAt`): Calyx has already spoken
    /// for this command, and on a fish Ctrl-Z it can speak FIRST, so
    /// recording here would leave a deferral behind that the report
    /// meant to clear it already went past. A `.commandStart` report
    /// never stamps that field, so it can never win this grace window on
    /// its own -- only a genuine end report can.
    ///
    /// Every path with `origin == .calyxShellIntegration` clears the
    /// deferral instead, settling or not: this signal is the answer a
    /// deferral was waiting for either way.
    ///
    /// `didSettle` is `false` for every guard, including the two that
    /// return before ever inspecting `current` -- `CalyxMCPServer
    /// .routeCommandEvent` gates `ApprovalInboxStore.expireForSurface`
    /// on it, and a suspend (or any other reason nothing settled) must
    /// never expire an approval request a still-alive agent is waiting
    /// on.
    private static func resolvePaneCommandFinished(
        exitCode: Int32?,
        suspended: Bool,
        origin: PaneCommandOrigin,
        current: AgentEntry?,
        evidence: AgentEvidence,
        context: ResolverContext,
        now: Date
    ) -> AgentResolution {
        if origin == .ghostty, context.calyxShellIntegrationSeen {
            var updated = evidence
            let calyxJustReported = evidence.lastCalyxCommandEndAt.map {
                now.timeIntervalSince($0) < calyxReportGraceWindow
            } ?? false
            if !calyxJustReported {
                updated.deferredGhosttyFinishAt = now
            }
            return .keep(evidence: updated)
        }

        // Calyx has now answered for this surface, on every path below:
        // this signal IS the report a deferral was waiting for, whether
        // or not it settles anything.
        var answered = evidence
        answered.deferredGhosttyFinishAt = nil

        guard let existing = current else {
            return .keep(evidence: answered)
        }
        guard existing.source.isSelfReported else {
            return .keep(evidence: answered)
        }
        guard existing.state != .done else {
            return .keep(evidence: answered)
        }
        guard !suspended, !isStopSignalExitCode(exitCode) else {
            return .keep(evidence: answered)
        }

        var updated = existing
        updated.state = .done
        updated.lastEventAt = now
        return .settled(updated, evidence: answered)
    }

    // MARK: Screen Classification Signal

    /// Routes a `ScreenStateClassifier` result polled from a pane's
    /// on-screen text.
    ///
    /// An unregistered surface only gets a new `.titleHeuristic` row
    /// when `state` is `.blocked` or `.working` -- a `nil`
    /// classification never creates a row for a plain shell pane. The
    /// new row's evidence is the caller's UNCHANGED `evidence`: unlike
    /// every other clause that resets the miss streak on a positive
    /// signal, creation itself is not treated as one.
    ///
    /// An `.mcpConnection` row reflects the screen result directly
    /// (`nil` falling back to `.idle`), but a `.done` row is left
    /// alone: the Agents sidebar polls screen classification every two
    /// seconds, so without that guard a row `.paneCommandFinished` just
    /// settled would revert off `.done` almost immediately. Neither
    /// branch here ever removes the row -- the MCP `initialize` that
    /// created it is independent presence evidence a screen miss must
    /// not undo -- and neither touches `evidence` at all; the miss
    /// streak belongs exclusively to `.titleHeuristic` bookkeeping, per
    /// the asymmetry noted below.
    ///
    /// A `.hooks` row is left untouched entirely (hooks self-report is
    /// authoritative over a screen poll).
    ///
    /// An existing `.titleHeuristic` row is the only case treated as an
    /// *authoritative* heuristic signal (`heuristicApply(isAuthoritative:
    /// true)`, able to clear `.blocked`): `.blocked`/`.working` reset
    /// the miss streak to 0 and apply as-is; anything else (`nil`, or in
    /// principle `.idle`/`.done`, which `ScreenStateClassifier.classify`
    /// never actually returns) counts as a miss. At
    /// `heuristicMissRetirementThreshold` consecutive misses the row is
    /// removed -- the resolver's only `.remove` -- with the streak
    /// zeroed in that SAME resolution, so a fresh registration on the
    /// same surface never inherits it. Below threshold, the incremented
    /// streak is recorded and `.idle` is applied.
    ///
    /// Asymmetry against `.title`/`.progress`: those reset the miss
    /// streak for ANY existing row (or none at all) on their own
    /// positive signal. This clause resets it ONLY inside the
    /// `.titleHeuristic` branch above -- a `.working` screen result
    /// reflected onto an `.mcpConnection` row leaves the streak
    /// untouched, and a miss there does not increment it either, since
    /// that bookkeeping only ever governs a `.titleHeuristic` row's own
    /// retirement.
    private static func resolveScreen(
        _ state: AgentState?,
        surfaceID: UUID,
        current: AgentEntry?,
        evidence: AgentEvidence,
        now: Date
    ) -> AgentResolution {
        guard let existing = current else {
            guard let state, state == .blocked || state == .working else {
                return .keep(evidence: evidence)
            }
            let entry = makeHeuristicEntry(surfaceID: surfaceID, state: state, now: now)
            return .write(entry, evidence: evidence)
        }

        if existing.source == .mcpConnection {
            guard existing.state != .done else {
                return .keep(evidence: evidence)
            }
            let newState = state ?? .idle
            guard existing.state != newState else {
                return .keep(evidence: evidence)
            }
            var updated = existing
            updated.state = newState
            updated.lastEventAt = now
            return .write(updated, evidence: evidence)
        }

        guard existing.source == .titleHeuristic else {
            return .keep(evidence: evidence)
        }

        if let state, state == .blocked || state == .working {
            return .applying(
                heuristicApply(existing: existing, newState: state, isAuthoritative: true, now: now),
                evidence: evidence.clearingScreenMissStreak()
            )
        }

        let missed = evidence.incrementingScreenMissStreak()
        if missed.screenMissStreak >= heuristicMissRetirementThreshold {
            return .remove(evidence: evidence.clearingScreenMissStreak())
        }
        return .applying(
            heuristicApply(existing: existing, newState: .idle, isAuthoritative: true, now: now),
            evidence: missed
        )
    }

    // MARK: Title Heuristic Signal

    /// A `.working` classification is a "positive" heuristic signal and
    /// resets the miss streak unconditionally, before any row or source
    /// check -- including for a row this signal will otherwise leave
    /// untouched entirely (a `.hooks` or `.mcpConnection` row).
    ///
    /// An existing row routes through `heuristicApply`, which leaves
    /// anything other than a `.titleHeuristic` row untouched: a `.hooks`
    /// entry is authoritative, and an `.mcpConnection` entry's state is
    /// owned by screen classification, not a title.
    ///
    /// An unregistered surface only gets a new row while
    /// `context.isServerRunning` -- see `ResolverContext
    /// .isServerRunning`'s own doc comment. Updating an EXISTING
    /// `.titleHeuristic` entry needs no separate such guard: no such
    /// entry can exist while the server is stopped in the first place,
    /// since `CalyxMCPServer.stop()` unconditionally clears every native
    /// row before flipping `isServerRunning` false.
    private static func resolveTitle(
        _ classified: AgentState,
        surfaceID: UUID,
        current: AgentEntry?,
        evidence: AgentEvidence,
        context: ResolverContext,
        now: Date
    ) -> AgentResolution {
        let updatedEvidence = classified == .working ? evidence.clearingScreenMissStreak() : evidence

        if let existing = current {
            return .applying(
                heuristicApply(existing: existing, newState: classified, isAuthoritative: false, now: now),
                evidence: updatedEvidence
            )
        }

        guard context.isServerRunning else {
            return .keep(evidence: updatedEvidence)
        }

        let entry = makeHeuristicEntry(surfaceID: surfaceID, state: classified, now: now)
        return .write(entry, evidence: updatedEvidence)
    }

    // MARK: Progress Report Signal

    /// `isActive == true` is a "positive" heuristic signal and resets the
    /// miss streak unconditionally, for any surface -- row or not, and
    /// regardless of its source. The row itself is only ever affected
    /// through an existing `.titleHeuristic` entry, routed through
    /// `heuristicApply` as a non-authoritative signal: a progress report
    /// never creates a row on its own, since screen classification's
    /// blocked/working patterns are the more conservative signal for
    /// that.
    private static func resolveProgress(
        _ isActive: Bool,
        current: AgentEntry?,
        evidence: AgentEvidence,
        now: Date
    ) -> AgentResolution {
        let updatedEvidence = isActive ? evidence.clearingScreenMissStreak() : evidence

        guard let existing = current else {
            return .keep(evidence: updatedEvidence)
        }

        return .applying(
            heuristicApply(
                existing: existing, newState: isActive ? .working : .idle, isAuthoritative: false, now: now
            ),
            evidence: updatedEvidence
        )
    }

    // MARK: Shared Heuristic Sub-Clause

    /// A row for a pane Calyx is watching rather than one an agent is
    /// reporting on: no session, no cwd, no unread badge, because none
    /// of that is knowable from a pane title or a screen classification.
    /// `kind` is the one agent-specific value in this resolver, and it
    /// is a guess: an inferred row cannot know which CLI it is watching,
    /// so it names the most common one until a hook event or an MCP
    /// connection replaces the row with the real one.
    private static func makeHeuristicEntry(
        surfaceID: UUID,
        state: AgentState,
        now: Date
    ) -> AgentEntry {
        AgentEntry(
            surfaceID: surfaceID,
            sessionID: nil,
            source: .titleHeuristic,
            state: state,
            cwd: nil,
            kind: AgentEntry.claudeCodeKind,
            lastEventAt: now,
            unreadCount: 0
        )
    }

    /// Routes a proposed state for an existing row through the
    /// invariants every heuristic signal shares, and returns only the
    /// row action: this decides nothing about the surface's evidence,
    /// which each signal computes on its own terms before calling here.
    ///
    /// - A row that isn't `.titleHeuristic`-sourced is left untouched.
    ///   A `.hooks` entry is authoritative, and an `.mcpConnection`
    ///   entry's state is owned by screen classification. This is the
    ///   only place that rule lives.
    /// - `isAuthoritative` gates whether this signal may move the row
    ///   AWAY from `.blocked`. Only screen classification's own
    ///   non-blocked result qualifies: a `.titleHeuristic` row's
    ///   `.blocked` state means the pane's on-screen text still shows an
    ///   approval prompt, and a lower-confidence signal (a progress
    ///   report going inactive, or a title reverting to idle) must not
    ///   flip the row away while the prompt is still visible.
    /// - A `newState` identical to the row's current state is never
    ///   written. On the 2-second screen poll most ticks reclassify the
    ///   same steady state, and writing it back would churn
    ///   `@Observable` for no actual change.
    private static func heuristicApply(
        existing: AgentEntry,
        newState: AgentState,
        isAuthoritative: Bool,
        now: Date
    ) -> AgentResolution.RowAction {
        guard existing.source == .titleHeuristic else { return .keep }
        guard isAuthoritative || existing.state != .blocked else { return .keep }
        guard existing.state != newState else { return .keep }

        var updated = existing
        updated.state = newState
        updated.lastEventAt = now
        return .write(updated)
    }

    // MARK: Hook Event Helpers

    /// The state a recognized hook event resolves to, independent of any
    /// registry/session guard. `nil` means the event carries no
    /// actionable state change: either the event type is not tracked
    /// (`SubagentStop`, unknown names), or it's a `Notification` with a
    /// non-nil message that doesn't match `blockedNotificationPatterns`.
    ///
    /// A `Notification` with a *nil* message resolves to `.blocked`
    /// rather than `nil`: the `matcher: "permission_prompt"` filter
    /// configured by `ClaudeHooksConfigManager` already restricts which
    /// `Notification`s fire this hook at all, so trusting that filter and
    /// defaulting to blocked favors "false blocked" (a harmless extra red
    /// dot) over "false idle" (a permission prompt the user never
    /// notices) when the message field is absent or unparseable. The
    /// substring check exists only to guard against an older Claude Code
    /// build that ignores the matcher and fires `Notification` for
    /// unrelated messages too.
    ///
    /// `PermissionRequest` always resolves to `.blocked`, unconditionally
    /// -- unlike `Notification` there's no message-substring backstop to
    /// apply, since this event's hook payload carries no equivalent
    /// field: `calyx-agent-hook` exiting 0 with no output already
    /// guarantees the hook never influences the CLI's own approval
    /// decision, so firing it at all is a reliable signal the agent is
    /// waiting on the user. Claude Code subscribes to it
    /// (`ClaudeHooksConfigManager`) alongside
    /// `Notification`("permission_prompt") because `PermissionRequest`
    /// fires in sync with the permission dialog appearing while
    /// `Notification` can lag it by several seconds. It's deliberately
    /// absent from `forwardMovingEventNames`: see that property's doc
    /// comment.
    static func resultingState(for event: AgentEvent) -> AgentState? {
        switch event.hookEventName {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "Stop":
            return .idle
        case "SessionEnd":
            return .done
        case "PermissionRequest":
            return .blocked
        case "Notification":
            guard let message = event.message else { return .blocked }
            let isBlocked = blockedNotificationPatterns.contains {
                message.range(of: $0, options: .caseInsensitive) != nil
            }
            return isBlocked ? .blocked : nil
        default:
            return nil
        }
    }

    // MARK: Pane Command Helpers

    /// Whether `exitCode` is a shell's `128 + signal` report for one of
    /// `stopSignals` -- i.e. positive evidence the pane's foreground job
    /// was merely suspended, not exited. `exitCode > 128` is checked
    /// before subtracting so an adversarial `exitCode` near `Int32.min`
    /// can never underflow the subtraction and trap; it also doubles as
    /// the only arithmetically possible range for a `128 + signal` report
    /// to begin with. `nil` (no exit code reported) is never treated as a
    /// stop signal: this check can only recognize a SPECIFIC known value,
    /// never infer one it wasn't given -- see
    /// `AgentRegistry.handlePaneCommandFinished`'s doc comment for why a
    /// `nil` code settles rather than being treated conservatively.
    private static func isStopSignalExitCode(_ exitCode: Int32?) -> Bool {
        guard let exitCode, exitCode > 128 else { return false }
        return stopSignals.contains(exitCode - 128)
    }
}
