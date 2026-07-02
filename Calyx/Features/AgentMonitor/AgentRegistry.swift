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

    /// The only agent `kind` `AgentRegistry` produces entries for in v1.
    /// Phase 2 adds `"codex"` / `"opencode"` alongside their own event
    /// sources.
    private static let claudeCodeKind = "claude-code"

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

    /// Hook events that represent forward progress within a session, used
    /// by the session-mismatch reconciliation in `handleHookEvent` — see
    /// its doc comment.
    private static let forwardMovingEventNames: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse",
    ]

    private(set) var entries: [UUID: AgentEntry] = [:]

    /// Whether `CalyxMCPServer` currently has its IPC listener running.
    /// `AgentStatusView` observes this (not `CalyxMCPServer.isRunning`
    /// directly) so the sidebar's disabled/enabled placeholder redraws —
    /// `CalyxMCPServer` is a plain `@MainActor` class, not `@Observable`,
    /// so a SwiftUI view reading its `isRunning` never gets a re-render
    /// signal when it changes.
    private(set) var isServerRunning: Bool = false

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
    ///   genuine new session.
    func handleHookEvent(_ event: AgentEvent, surfaceID: UUID) {
        let now = Date()

        func makeEntry(state: AgentState) -> AgentEntry {
            AgentEntry(
                surfaceID: surfaceID,
                sessionID: event.sessionID,
                source: .hooks,
                state: state,
                cwd: event.cwd,
                kind: Self.claudeCodeKind,
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
            guard existing.state == .done || isForwardMoving else { return }
            entries[surfaceID] = makeEntry(state: newState)
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
    private static func resultingState(for event: AgentEvent) -> AgentState? {
        switch event.hookEventName {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse":
            return .working
        case "Stop":
            return .idle
        case "SessionEnd":
            return .done
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

    // MARK: - Title Heuristic Fallback

    /// Applies the second-layer title-based classifier. Only creates or
    /// updates a `.titleHeuristic` entry — an existing `.hooks`-sourced
    /// entry is authoritative and is left untouched.
    func handleTitleChange(surfaceID: UUID, title: String) {
        guard let classified = ClaudeTitleHeuristic.classify(title: title) else { return }

        let existing = entries[surfaceID]
        guard existing == nil || existing?.source == .titleHeuristic else { return }

        entries[surfaceID] = AgentEntry(
            surfaceID: surfaceID,
            sessionID: existing?.sessionID,
            source: .titleHeuristic,
            state: classified,
            cwd: existing?.cwd,
            kind: Self.claudeCodeKind,
            lastEventAt: Date()
        )
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
