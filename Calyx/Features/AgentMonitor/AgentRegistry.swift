// AgentRegistry.swift
// Calyx
//
// Source of truth for AI agent state in the Agents sidebar. One surface
// (pane) maps to at most one AgentEntry.

import Foundation

@MainActor
@Observable
final class AgentRegistry {

    static let shared = AgentRegistry()

    /// Case-insensitive notification message substrings that indicate a
    /// blocked (permission / input needed) agent. This is a server-side
    /// backstop for the `Notification` hook's `matcher: "permission_prompt"`
    /// filter configured by `ClaudeHooksConfigManager`: when the message is
    /// present but doesn't match, state is left unchanged (a `Notification`
    /// unrelated to permissions/input shouldn't flip the row to blocked).
    /// A `nil` message *does* flip to `.blocked` — see `resultingState`.
    static let blockedNotificationPatterns: [String] = [
        "needs your permission",
        "waiting for your input",
    ]

    /// `.working` entries idle this long without a new hook event are
    /// treated as crashed (see `sweepStaleEntries(now:)`).
    private static let staleWorkingThreshold: TimeInterval = 15 * 60

    /// Consecutive `nil` `handleScreenClassification` results (no known
    /// blocked/working pattern recognized) that retire (remove) a
    /// `.titleHeuristic` row — at the screen poll's 2-second interval,
    /// 5 misses is ~10 seconds. See `heuristicMissStreaks`'s doc comment.
    private static let heuristicMissRetirementThreshold = 5

    /// Hook events that represent forward progress within a session, used
    /// by the session-mismatch reconciliation in `handleHookEvent` — see
    /// its doc comment. `PermissionRequest` (Codex, Phase 2) is
    /// deliberately excluded: unlike `UserPromptSubmit`/`PreToolUse`/
    /// `PostToolUse`, seeing one for an unrecognized session isn't good
    /// evidence of a genuine new session Calyx missed the `SessionStart`
    /// for — it's at least as likely a stale/mismatched permission prompt
    /// from a session that's already ending, and replacing the entry on
    /// that basis would incorrectly flip an active row to `.blocked`.
    private static let forwardMovingEventNames: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse",
    ]

    private(set) var entries: [UUID: AgentEntry] = [:]

    /// Human-readable descriptions of hooks the app failed to install,
    /// surfaced as a persistent warning banner instead of the one-shot
    /// enable-time alert. Set wholesale by `setHooksIssues` (called by
    /// `CalyxWindowController.enableIPC`), cleared by `reset()`.
    private(set) var hooksIssues: [String] = []

    /// Surface → peer ID bindings learned from a `PreToolUse`/
    /// `PostToolUse` hook event carrying `AgentEvent.ipcSelfPeerID` (see
    /// `handleHookEvent` and `bindSurface`). Kept in sync with
    /// `peerToSurface`, its reverse — see that property's doc comment.
    /// Cleared per-surface on `handleSurfaceDestroyed`, and wholesale on
    /// `reset()`.
    private var surfaceToPeer: [UUID: UUID] = [:]

    /// Reverse of `surfaceToPeer`, giving `updateInbox` / `syncInboxCounts`
    /// an O(1), deterministic peer → surface lookup instead of a linear
    /// scan of `surfaceToPeer` for a matching value (which was also
    /// order-dependent if more than one surface had ever mapped to the
    /// same peer). `bindSurface` enforces "1 peer = 1 surface": binding a
    /// peer to a new surface removes its previous surface's binding, so
    /// this dictionary is always a true reverse of `surfaceToPeer`, never
    /// stale in either direction.
    private var peerToSurface: [UUID: UUID] = [:]

    /// Per-surface count of consecutive `nil` `handleScreenClassification`
    /// results for a `.titleHeuristic` entry — sparse (only surfaces with
    /// at least one miss have a key). Reset to absent (0) by a "positive"
    /// signal from any heuristic source (a `.blocked`/`.working` screen
    /// classification, a `.working` title classification, or an
    /// `isActive == true` progress report); incremented only by a `nil`
    /// screen classification. Reaching
    /// `heuristicMissRetirementThreshold` removes the row entirely —
    /// without this, a `.titleHeuristic` row for a pane whose Claude Code
    /// process has long since exited (title reverted, no more on-screen
    /// patterns) would sit at `.idle` in the sidebar forever. Cleared
    /// per-surface on `handleSurfaceDestroyed` and whenever a hook event
    /// is processed for the surface (a `.hooks`-sourced entry doesn't use
    /// this bookkeeping at all), and wholesale on `reset()`.
    private var heuristicMissStreaks: [UUID: Int] = [:]

    /// Whether `CalyxMCPServer` currently has its IPC listener running.
    /// `AgentStatusView` observes this (not `CalyxMCPServer.isRunning`
    /// directly) so the sidebar's disabled/enabled placeholder redraws —
    /// `CalyxMCPServer` is a plain `@MainActor` class, not `@Observable`,
    /// so a SwiftUI view reading its `isRunning` never gets a re-render
    /// signal when it changes.
    private(set) var isServerRunning: Bool = false

    /// Count of currently-mounted `AgentStatusView` instances across every
    /// window (incremented/decremented by its `onAppear`/`onDisappear`).
    /// `CalyxWindowController.pollScreenClassificationIfAgentsSidebarVisible`
    /// reads `isAgentsSidebarVisibleAnywhere` (derived from this) instead
    /// of its own window's local `sidebarMode`/`showSidebar` state, so
    /// that when the Agents sidebar is visible in *any* window, *every*
    /// window's controller polls its own surfaces — closing the gap where
    /// a pane in a background window (Agents sidebar not open there)
    /// never got its screen classified even though the visible sidebar in
    /// another window would display its row. Not reset by `reset()`: this
    /// tracks mounted SwiftUI views, which is independent of the IPC
    /// server's running state and persists across a server stop/start.
    private(set) var agentsSidebarVisibleCount: Int = 0

    /// Whether the Agents sidebar is currently visible in at least one
    /// window. See `agentsSidebarVisibleCount`'s doc comment.
    var isAgentsSidebarVisibleAnywhere: Bool { agentsSidebarVisibleCount > 0 }

    /// Called by `AgentStatusView.onAppear`.
    func incrementAgentsSidebarVisible() {
        agentsSidebarVisibleCount += 1
    }

    /// Called by `AgentStatusView.onDisappear`. Clamped at 0 so a stray
    /// unbalanced call can't underflow the count negative.
    func decrementAgentsSidebarVisible() {
        agentsSidebarVisibleCount = max(0, agentsSidebarVisibleCount - 1)
    }

    /// 60-second periodic sweep started by `markServerStarted()` and
    /// cancelled by `reset()`.
    private var sweepTask: Task<Void, Never>?

    /// Entries sorted for sidebar display: blocked → working → idle → done,
    /// same-state entries ordered by `cwd` basename. Decorate-sort-undecorate:
    /// each entry's sort key (priority + basename) is computed once, up
    /// front, rather than recomputing `basename` on both sides of every
    /// comparison the sort performs.
    var sortedEntries: [AgentEntry] {
        entries.values
            .map { entry in (entry: entry, priority: Self.sortPriority(for: entry.state), basename: Self.basename(entry.cwd)) }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                if lhs.basename != rhs.basename { return lhs.basename < rhs.basename }
                return lhs.entry.surfaceID.uuidString < rhs.entry.surfaceID.uuidString
            }
            .map(\.entry)
    }

    init() {}

    // MARK: - Server Lifecycle

    /// Marks the registry as observing a running IPC server and starts the
    /// periodic staleness sweep. Called by `CalyxMCPServer.finishStart()`.
    func markServerStarted() {
        isServerRunning = true
        sweepTask?.cancel()
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.sweepStaleEntries()
            }
        }
    }

    /// Clears every entry, marks the registry as stopped, and cancels the
    /// staleness sweep. Called by `CalyxMCPServer.stop()` so a disabled IPC
    /// server shows the "disabled" placeholder immediately rather than
    /// leaving stale rows from the previous session.
    func reset() {
        entries.removeAll()
        surfaceToPeer.removeAll()
        peerToSurface.removeAll()
        heuristicMissStreaks.removeAll()
        hooksIssues = []
        isServerRunning = false
        sweepTask?.cancel()
        sweepTask = nil
    }

    // MARK: - Hook Events

    /// Applies a decoded hook event to the registry. See the state
    /// transition table in the AgentMonitor design doc:
    /// - `SessionStart` for a surface with no existing `.hooks` entry, or
    ///   one from a different session, unconditionally upserts (state
    ///   resets to `.idle`). `SessionStart` for the *same* session
    ///   (compact/resume re-sends it without an intervening `SessionEnd`)
    ///   preserves the existing state and only refreshes `cwd` /
    ///   `lastEventAt` — otherwise a mid-session compact would visibly
    ///   flash a `.working`/`.blocked` row back to idle.
    /// - `SubagentStop` (and any event name this registry does not
    ///   recognize) is fully ignored: it never registers a surface and
    ///   never changes an existing entry's state.
    /// - Every other recognized event only applies when the surface is
    ///   unregistered (or still `.titleHeuristic`-sourced, promoting it to
    ///   `.hooks`) or its `sessionID` matches the entry's. A session
    ///   mismatch replaces the entry when the existing one is `.done` (a
    ///   stale session that has already ended) or the incoming event is
    ///   forward-moving (`UserPromptSubmit` / `PreToolUse` / `PostToolUse`
    ///   — a new session already under way that Calyx never saw a
    ///   `SessionStart` for, e.g. because IPC was enabled mid-session).
    ///   Otherwise — a mismatched `Stop` / `SessionEnd` / `Notification` —
    ///   the event is discarded, since those are as likely to be a stale
    ///   session's event arriving out of order (e.g. `/clear`'s old-session
    ///   `SessionEnd` landing after the new session's first event) as a
    ///   genuine new session. A mismatched `PermissionRequest` gets one more
    ///   rescue: it also replaces an `.idle` (not just `.done`) existing
    ///   entry — see `resultingState`'s doc comment for why `PermissionRequest`
    ///   isn't simply added to `forwardMovingEventNames` instead. Codex has
    ///   no `SessionEnd` hook, so a missed `SessionStart` (IPC enabled
    ///   mid-session, or Calyx restarted) can leave a stale-but-idle entry
    ///   on a pane; without this rescue a subsequent approval prompt for the
    ///   real new session is discarded and the sidebar never shows it as
    ///   blocked. `.working` and `.blocked` entries remain protected from a
    ///   mismatched `PermissionRequest`, exactly as before.
    /// - Parameter kind: The agent CLI this event came from (Phase 2:
    ///   Codex / OpenCode alongside the default Claude Code), forwarded by
    ///   `CalyxMCPServer.routeAgentEvent`'s `X-Calyx-Agent-Kind` header.
    ///   Applied only when this call creates or replaces an entry —
    ///   `makeEntry` below — so a same-session continuation event (the
    ///   `SessionStart` re-send branch, and the "same session" update path
    ///   at the bottom of this method) never overwrites an existing
    ///   entry's `kind` with this parameter's default.
    /// - Parameter now: Injectable for tests (defaults to `Date()`).
    ///   Notably used by the same-session update path's PreToolUse race
    ///   guard below, which compares `now` against `existing.lastEventAt`.
    func handleHookEvent(
        _ event: AgentEvent,
        surfaceID: UUID,
        kind: String = AgentEntry.claudeCodeKind,
        now: Date = Date()
    ) {
        // A hook event is real self-reported evidence the pane is a live
        // agent session — any leftover heuristic miss-streak bookkeeping
        // (relevant only to `.titleHeuristic` rows) for this surface is
        // stale from here on, whether this event promotes an existing
        // `.titleHeuristic` row to `.hooks` or the surface was never
        // heuristic-tracked at all (a no-op removal either way).
        heuristicMissStreaks.removeValue(forKey: surfaceID)

        // Learn the surface -> peer binding from a calyx-ipc PreToolUse's
        // or PostToolUse's self-reported peer ID, independent of (and
        // alongside) whatever entry mutation this event triggers below —
        // see `AgentEvent.ipcSelfPeerID`'s doc comment. Every other
        // event's `ipcSelfPeerID` is `nil`, so this is a no-op for them.
        if let ipcSelfPeerID = event.ipcSelfPeerID, let peerUUID = UUID(uuidString: ipcSelfPeerID) {
            bindSurface(surfaceID, toPeer: peerUUID)
        }

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

        if event.hookEventName == "SessionStart" {
            if let existing = entries[surfaceID], existing.source == .hooks, existing.sessionID == event.sessionID {
                var updated = existing
                updated.cwd = event.cwd
                updated.lastEventAt = now
                entries[surfaceID] = updated
            } else {
                entries[surfaceID] = makeEntry(state: .idle)
            }
            return
        }

        guard let newState = Self.resultingState(for: event) else { return }

        guard let existing = entries[surfaceID], existing.source == .hooks else {
            // Unregistered surface, or a `.titleHeuristic` entry not yet
            // promoted: register/promote using this event's session/cwd.
            entries[surfaceID] = makeEntry(state: newState)
            return
        }

        guard existing.sessionID == event.sessionID else {
            let isForwardMoving = Self.forwardMovingEventNames.contains(event.hookEventName)
            let isPermissionRequestIdleRescue =
                event.hookEventName == "PermissionRequest" && existing.state == .idle
            guard existing.state == .done || isForwardMoving || isPermissionRequestIdleRescue else { return }
            entries[surfaceID] = makeEntry(state: newState)
            return
        }

        // Round 4 review: `calyx-agent-hook`'s command entries all run
        // `"async": true`, so the script's POST to the server never blocks
        // Claude Code — two hooks fired moments apart in the real event
        // order (a tool call's own `PreToolUse`, then almost immediately
        // after, a *different* tool call's permission dialog appearing)
        // can land at the server out of that order. A `PreToolUse`
        // arriving within 1.5s of the moment this entry became `.blocked`
        // is treated as exactly that stale async-delivery race rather than
        // genuine forward progress, and is dropped here — otherwise it
        // would flash the row back to `.working` for a beat even though
        // the permission dialog the user actually sees is still up.
        // `PostToolUse` / `Stop` / `UserPromptSubmit` are deliberately not
        // covered by this guard: each of those only fires once the prompt
        // has *actually* been resolved (the tool ran, or the user typed a
        // new message), so they must keep clearing `.blocked` immediately,
        // exactly as before. 1.5s is comfortably longer than realistic
        // same-session hook delivery jitter and comfortably shorter than
        // the time an actual human takes to click through a dialog.
        //
        // Accepted trade-off: this guard cannot distinguish the stale race
        // above from a *genuinely new*, unrelated tool call's `PreToolUse`
        // landing in the same 1.5s window right after a rejection — that
        // legitimate event is dropped too, same as the stale one. The row
        // stays visibly stale for at most 1.5s either way, and the very
        // next `PostToolUse`/`Stop`/`UserPromptSubmit` (none of which this
        // guard touches) corrects it immediately, so this was judged an
        // acceptable cost for closing the more common stale-`.blocked`
        // flash.
        if existing.state == .blocked,
           event.hookEventName == "PreToolUse",
           now.timeIntervalSince(existing.lastEventAt) < 1.5 {
            return
        }

        // `cwd` is not re-derived here: `SessionStart` already established
        // it for the session's lifetime, and a Claude Code session's
        // working directory doesn't change mid-session.
        var updated = existing
        updated.state = newState
        updated.lastEventAt = now
        entries[surfaceID] = updated
    }

    /// The state a recognized hook event resolves to, independent of any
    /// registry/session guard. `nil` means the event carries no actionable
    /// state change: either the event type is not tracked (`SubagentStop`,
    /// unknown names), or it's a `Notification` with a non-nil message that
    /// doesn't match `blockedNotificationPatterns`.
    ///
    /// A `Notification` with a *nil* message resolves to `.blocked` rather
    /// than `nil`: the `matcher: "permission_prompt"` filter configured by
    /// `ClaudeHooksConfigManager` already restricts which `Notification`s
    /// fire this hook at all, so trusting that filter and defaulting to
    /// blocked favors "false blocked" (a harmless extra red dot) over
    /// "false idle" (a permission prompt the user never notices) when the
    /// message field is absent or unparseable. The substring check exists
    /// only to guard against an older Claude Code build that ignores the
    /// matcher and fires `Notification` for unrelated messages too.
    ///
    /// `PermissionRequest` always resolves to `.blocked`, unconditionally —
    /// unlike `Notification` there's no message-substring backstop to
    /// apply, since this event's hook payload carries no equivalent field:
    /// `calyx-agent-hook` exiting 0 with no output already guarantees the
    /// hook never influences the CLI's own approval decision, so firing it
    /// at all is a reliable signal the agent is waiting on the user.
    /// Originally Codex-only (Phase 2); Round 4 also subscribes Claude
    /// Code to it (`ClaudeHooksConfigManager`), alongside
    /// `Notification`("permission_prompt"), because `PermissionRequest`
    /// fires in sync with the permission dialog appearing while
    /// `Notification` can lag it by several seconds. It's deliberately
    /// absent from `forwardMovingEventNames`: see that property's doc
    /// comment.
    private static func resultingState(for event: AgentEvent) -> AgentState? {
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

    // MARK: - Heuristic Signal Arbitration

    /// Single choke point every heuristic signal source
    /// (`handleTitleChange` / `handleScreenClassification` /
    /// `handleProgressReport`) routes an *update to an existing*
    /// `.titleHeuristic` entry through, so the following invariants are
    /// enforced exactly once rather than re-implemented (and risking
    /// drifting out of sync) at each of the three call sites:
    ///
    /// - A `nil`/absent entry, or one that isn't `.titleHeuristic`-sourced
    ///   (a `.hooks` entry is authoritative), is left untouched — this
    ///   method never creates a row; each caller's own creation path
    ///   (when it has one) handles that separately.
    /// - `newState` identical to the entry's current `state` is never
    ///   written: on Calyx's 2-second screen poll, most ticks reclassify
    ///   the same steady state, and writing it back every time would
    ///   needlessly churn `@Observable`'s change tracking (and the
    ///   sidebar's redraw) for no actual change.
    /// - `isAuthoritative` gates whether this signal may move the entry
    ///   *away* from `.blocked`: only `handleScreenClassification`'s own
    ///   non-blocked result (`isAuthoritative: true`) may — a
    ///   `.titleHeuristic` row's `.blocked` state means the pane's
    ///   on-screen text still shows an approval prompt, and a
    ///   lower-confidence signal (a progress report going inactive, or a
    ///   title reverting to idle/spinner) must not second-guess that and
    ///   flip the row away while the prompt is still actually visible.
    @discardableResult
    private func applyHeuristicState(surfaceID: UUID, newState: AgentState, isAuthoritative: Bool) -> Bool {
        guard let existing = entries[surfaceID], existing.source == .titleHeuristic else { return false }
        guard isAuthoritative || existing.state != .blocked else { return true }
        guard existing.state != newState else { return true }

        var updated = existing
        updated.state = newState
        updated.lastEventAt = Date()
        entries[surfaceID] = updated
        return true
    }

    /// Removes `surfaceID`'s heuristic miss-streak count (see
    /// `heuristicMissStreaks`'s doc comment) — called by every "positive"
    /// heuristic signal (a `.blocked`/`.working` screen classification, a
    /// `.working` title classification, or an `isActive == true` progress
    /// report).
    private func resetHeuristicMissStreak(surfaceID: UUID) {
        heuristicMissStreaks.removeValue(forKey: surfaceID)
    }

    // MARK: - Title Heuristic Fallback

    /// Applies the second-layer title-based classifier. Only creates or
    /// updates a `.titleHeuristic` entry — an existing `.hooks`-sourced
    /// entry is authoritative and is left untouched. Routes an update to
    /// an existing `.titleHeuristic` entry through `applyHeuristicState`
    /// as a non-authoritative signal — see that method's doc comment.
    func handleTitleChange(surfaceID: UUID, title: String) {
        guard let classified = ClaudeTitleHeuristic.classify(title: title) else { return }

        if classified == .working {
            resetHeuristicMissStreak(surfaceID: surfaceID)
        }

        if let existing = entries[surfaceID] {
            guard existing.source == .titleHeuristic else { return }
            applyHeuristicState(surfaceID: surfaceID, newState: classified, isAuthoritative: false)
            return
        }

        entries[surfaceID] = AgentEntry(
            surfaceID: surfaceID,
            sessionID: nil,
            source: .titleHeuristic,
            state: classified,
            cwd: nil,
            kind: AgentEntry.claudeCodeKind,
            lastEventAt: Date()
        )
    }

    /// Replaces `hooksIssues` wholesale. Called by
    /// `CalyxWindowController.enableIPC` with one formatted entry per
    /// failed `AgentHooksResult`, or `[]` when every hook installed
    /// cleanly (or IPC was disabled) — `AgentStatusView` renders a
    /// warning banner whenever this is non-empty.
    func setHooksIssues(_ issues: [String]) {
        hooksIssues = issues
    }

    // MARK: - Screen State Classification (Herdr Layer 2)

    /// Applies a `ScreenStateClassifier` result polled from a pane's
    /// on-screen text. `.hooks`-sourced entries are left untouched (hooks
    /// self-report is authoritative). An existing `.titleHeuristic` entry
    /// is updated as an *authoritative* signal (`applyHeuristicState`) —
    /// `.blocked` / `.working` reflected as-is (and resetting the
    /// heuristic miss streak, since this is a "positive" signal), `nil`
    /// falling back to `.idle` and counting as a miss: reaching
    /// `heuristicMissRetirementThreshold` consecutive misses removes the
    /// row entirely (see `heuristicMissStreaks`'s doc comment) rather
    /// than leaving it parked at `.idle` forever. An unregistered surface
    /// only gets a new `.titleHeuristic` entry when `state` is `.blocked`
    /// or `.working`: a `nil` classification never creates a row for a
    /// plain shell pane.
    func handleScreenClassification(surfaceID: UUID, state: AgentState?) {
        guard let existing = entries[surfaceID] else {
            guard let state, state == .blocked || state == .working else { return }
            entries[surfaceID] = AgentEntry(
                surfaceID: surfaceID,
                sessionID: nil,
                source: .titleHeuristic,
                state: state,
                cwd: nil,
                kind: AgentEntry.claudeCodeKind,
                lastEventAt: Date()
            )
            return
        }
        guard existing.source == .titleHeuristic else { return }

        if let state, state == .blocked || state == .working {
            resetHeuristicMissStreak(surfaceID: surfaceID)
            applyHeuristicState(surfaceID: surfaceID, newState: state, isAuthoritative: true)
            return
        }

        let missCount = (heuristicMissStreaks[surfaceID] ?? 0) + 1
        if missCount >= Self.heuristicMissRetirementThreshold {
            entries.removeValue(forKey: surfaceID)
            heuristicMissStreaks.removeValue(forKey: surfaceID)
            return
        }
        heuristicMissStreaks[surfaceID] = missCount
        applyHeuristicState(surfaceID: surfaceID, newState: .idle, isAuthoritative: true)
    }

    /// Applies an OSC 9;4 progress-report signal
    /// (`GHOSTTY_ACTION_PROGRESS_REPORT`) polled/observed for a pane.
    /// `.hooks`-sourced entries are untouched. Only an existing
    /// `.titleHeuristic` entry is affected (a progress report never
    /// creates a row on its own — screen classification's blocked/working
    /// patterns are the more conservative signal for that): it flips to
    /// `.working` when `isActive` is `true` (a "positive" signal — see
    /// `heuristicMissStreaks`) and `.idle` when `false`, routed through
    /// `applyHeuristicState` as a non-authoritative signal.
    func handleProgressReport(surfaceID: UUID, isActive: Bool) {
        if isActive {
            resetHeuristicMissStreak(surfaceID: surfaceID)
        }
        applyHeuristicState(surfaceID: surfaceID, newState: isActive ? .working : .idle, isAuthoritative: false)
    }

    // MARK: - Peer ↔ Surface Binding

    /// Learns that `surfaceID` is bound to `peerID`, enforcing "1 peer =
    /// 1 surface" in both directions:
    /// - If `surfaceID` was already bound to a *different* peer, that
    ///   peer's now-stale reverse (`peerToSurface`) entry is dropped.
    /// - If `peerID` was already bound to a *different* surface, that
    ///   surface's now-stale forward (`surfaceToPeer`) entry is dropped
    ///   too — a peer only ever legitimately self-reports from one pane,
    ///   so a rebind means its owning pane changed (e.g. IPC
    ///   re-registration after a restart), not that it's now shared.
    ///
    /// Not `private` (Round 4): `handleHookEvent` below still calls this
    /// for the `PreToolUse`/`PostToolUse` hook-derived binding it has
    /// always used, but `CalyxMCPServer` also calls it directly now, to
    /// bind a surface the moment its MCP connection's `initialize` (or an
    /// explicit `register_peer` tool call) carries an `X-Calyx-Surface-ID`
    /// header — covering a passive recipient that never calls a
    /// calyx-ipc tool itself and so never fires the hook path at all.
    /// Both call sites share the same "1 peer = 1 surface" invariant this
    /// method enforces.
    func bindSurface(_ surfaceID: UUID, toPeer peerID: UUID) {
        if let oldPeerID = surfaceToPeer[surfaceID], oldPeerID != peerID {
            peerToSurface.removeValue(forKey: oldPeerID)
        }
        if let staleSurfaceID = peerToSurface[peerID], staleSurfaceID != surfaceID {
            surfaceToPeer.removeValue(forKey: staleSurfaceID)
        }
        surfaceToPeer[surfaceID] = peerID
        peerToSurface[peerID] = surfaceID
    }

    /// Removes `surfaceID`'s binding in both directions, if any.
    private func unbindSurface(_ surfaceID: UUID) {
        guard let peerID = surfaceToPeer.removeValue(forKey: surfaceID) else { return }
        peerToSurface.removeValue(forKey: peerID)
    }

    /// Whether `surfaceID` currently has a peer bound to it via
    /// `bindSurface`. Read-only query (Round 4 review): `CalyxMCPServer`'s
    /// `initialize` handler uses this to only auto-bind a surface that
    /// isn't already bound, rather than unconditionally rebinding on every
    /// MCP `initialize` — see that call site's own comment for why an
    /// unconditional bind there is unsafe. `register_peer`'s own binding
    /// remains unconditional and does not consult this.
    func isSurfaceBound(_ surfaceID: UUID) -> Bool {
        surfaceToPeer[surfaceID] != nil
    }

    /// Returns the peer ID currently bound to `surfaceID` via `bindSurface`,
    /// or `nil` if the surface has no binding. Round 6: unlike
    /// `isSurfaceBound` (Bool-only), this hands back the actual peer id so
    /// callers can look up whether that peer is still alive in
    /// `IPCStore`. Two call sites in `CalyxMCPServer` rely on this:
    /// `handleJSONRPC`'s `initialize` case uses it to resolve a
    /// reconnecting surface's ONE true peer identity — reporting the same
    /// `peer_id` back instead of auto-registering a fresh one — and
    /// `handleRegisterPeer` uses it to rename that peer in place instead
    /// of minting a second identity for the same surface.
    func boundPeerID(for surfaceID: UUID) -> UUID? {
        surfaceToPeer[surfaceID]
    }

    // MARK: - Unread Message Badges

    /// Every peer ID currently bound to a surface. `CalyxMCPServer`
    /// reads this once per `tools/call` request to batch-sync unread
    /// badges via `syncInboxCounts` — see that method's doc comment.
    var boundPeerIDs: [UUID] {
        Array(peerToSurface.keys)
    }

    /// Reflects `count` as the `unreadCount` of the surface bound to
    /// `peerID` (learned from a `PreToolUse`/`PostToolUse` hook event
    /// carrying an `AgentEvent.ipcSelfPeerID` — see `bindSurface`). A
    /// no-op when no surface is bound to `peerID` yet.
    func updateInbox(peerID: UUID, count: Int) {
        guard let surfaceID = peerToSurface[peerID], var entry = entries[surfaceID] else { return }
        entry.unreadCount = count
        entries[surfaceID] = entry
    }

    /// Batch counterpart to `updateInbox`: applies `counts` (typically
    /// `IPCStore.inboxCounts(for: boundPeerIDs)`) to every currently-
    /// bound surface in one pass, via `peerToSurface`'s O(1) reverse
    /// lookup. `CalyxMCPServer` calls this once at the end of every
    /// `tools/call` request instead of each individual IPC tool handler
    /// calling `updateInbox` separately — see that call site's doc
    /// comment. A `peerID` in `counts` with no bound surface (already
    /// possible for `updateInbox`, e.g. a stale/purged peer) is simply
    /// skipped.
    func syncInboxCounts(_ counts: [UUID: Int]) {
        for (peerID, count) in counts {
            guard let surfaceID = peerToSurface[peerID], var entry = entries[surfaceID] else { continue }
            entry.unreadCount = count
            entries[surfaceID] = entry
        }
    }

    // MARK: - Staleness Sweep

    /// Downgrades `.working` `.hooks`-sourced entries whose `lastEventAt`
    /// is older than `staleWorkingThreshold` to `.idle`. Guards against a
    /// Claude Code process that exits non-gracefully (crash, `kill -9`,
    /// terminal force-close) and so never sends the `Stop` hook — without
    /// this sweep such a row stays frozen at `.working` forever.
    /// `.blocked` entries are excluded: a permission prompt left
    /// unanswered for a long time is a legitimate wait, not staleness.
    func sweepStaleEntries(now: Date = Date()) {
        for (surfaceID, entry) in entries {
            guard entry.source == .hooks, entry.state == .working else { continue }
            guard now.timeIntervalSince(entry.lastEventAt) > Self.staleWorkingThreshold else { continue }
            var updated = entry
            updated.state = .idle
            entries[surfaceID] = updated
        }
    }

    // MARK: - Surface Lifecycle

    func handleSurfaceDestroyed(surfaceID: UUID) {
        entries.removeValue(forKey: surfaceID)
        unbindSurface(surfaceID)
        heuristicMissStreaks.removeValue(forKey: surfaceID)
    }

    // MARK: - Sorting Helpers

    private static func sortPriority(for state: AgentState) -> Int {
        switch state {
        case .blocked: return 0
        case .working: return 1
        case .idle: return 2
        case .done: return 3
        }
    }

    /// The row-name basename of a pane's `cwd`, or `""` for a `nil`/empty
    /// `cwd`. Not `private`: `AgentStatusView` reuses this directly so the
    /// basename logic exists in exactly one place.
    static func basename(_ cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "" }
        return (cwd as NSString).lastPathComponent
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted by `SurfaceRegistry.destroySurface` when a pane is torn down.
    /// `userInfo["surfaceID"]` carries the destroyed surface's `UUID`.
    static let calyxSurfaceDestroyed = Notification.Name("com.calyx.agentMonitor.surfaceDestroyed")

    /// Posted when an Agents sidebar row is clicked. `userInfo["surfaceID"]`
    /// carries the `UUID` of the surface to focus.
    static let calyxFocusSurface = Notification.Name("com.calyx.agentMonitor.focusSurface")
}
