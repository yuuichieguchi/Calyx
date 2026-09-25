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

    private(set) var entries: [UUID: AgentEntry] = [:]

    /// Rows describing agents Calyx learned about from an external
    /// source (herdr's own event stream) rather than its own hooks or
    /// title/screen heuristics. Deliberately a SEPARATE store from
    /// `entries`, never merged into it: mixing the two would require
    /// auditing every source-arbitration clause in `AgentStateResolver`
    /// (`resolveHookRow`'s source, session, and terminal-state guards,
    /// plus the `heuristicApply` sub-clause the screen, title, and
    /// progress clauses share, which together decide `.hooks` vs.
    /// `.titleHeuristic` precedence) and forking `reset()`'s clearing
    /// semantics, whereas separate storage makes "herdr rows survive
    /// `AgentRegistry.reset()`" true by construction -- `reset()` only
    /// ever clears `entries`, so it leaves this store alone without
    /// needing to know it exists.
    /// Populated/depopulated via `upsertExternalEntry` /
    /// `removeExternalEntry` below; queried via `hasExternalEntries`.
    /// `sortedEntries` merges both stores for sidebar display -- see
    /// that property's doc comment.
    private(set) var externalEntries: [UUID: AgentEntry] = [:]

    /// Child rows (subagents) reported under a pane's own row, keyed by
    /// parent surface. A storage side effect, not a row-state decision --
    /// `handleHookEvent` forwards every event to it after resolving the
    /// parent row itself. See `SubagentRegistry`'s own doc comment.
    let subagentRegistry = SubagentRegistry()

    /// Human-readable descriptions of agent CLI config write failures,
    /// one domain of the persistent warning banner `integrationIssues`
    /// combines. Set wholesale by `setConfigIssues` (called by
    /// `IPCActivationCoordinator`), cleared by `reset()`.
    private(set) var configIssues: [String] = []

    /// Human-readable descriptions of agent hook/plugin/extension
    /// install failures, the other domain `integrationIssues` combines.
    /// Set wholesale by `setHooksIssues` (called by
    /// `IPCActivationCoordinator` and by `AppDelegate`'s launch-time
    /// hooks re-sync), cleared by `reset()`.
    private(set) var hooksIssues: [String] = []

    /// The reason a server-start attempt failed (token generation or
    /// `CalyxMCPServer.start` itself), the domain the sidebar's
    /// `disabledPlaceholder` branch checks to show a failure banner
    /// instead of the ordinary "disabled" text. Set wholesale by
    /// `setServerIssues` (called by `IPCActivationCoordinator`).
    /// Deliberately NOT cleared by `reset()`: `reset()` runs from
    /// `CalyxMCPServer.stop()`, which is never called right after a
    /// start failure, so clearing this domain there would erase the
    /// banner while the failure it describes is still true. The only
    /// way this domain clears is an explicit `setServerIssues([])` from
    /// a subsequent successful `enable()` or a `disable()`.
    private(set) var serverIssues: [String] = []

    /// `configIssues` and `hooksIssues` combined, config first, for the
    /// single warning banner `AgentStatusView` renders. Kept as two
    /// separate stored properties rather than one shared array so
    /// `IPCActivationCoordinator`'s config-write report and
    /// `AppDelegate`'s hooks-only launch-time re-sync can each replace
    /// their own domain wholesale without erasing the other's.
    var integrationIssues: [String] { configIssues + hooksIssues }

    /// Surface → peer ID bindings learned from a `PreToolUse`/
    /// `PostToolUse` hook event carrying `AgentEvent.ipcSelfPeerID`
    /// (`AgentStateResolver.resolveHook` reads it off the event and
    /// reports it as `AgentResolution.learnedPeerID`; `apply` performs
    /// the bind through `bindSurface`). Kept in sync with
    /// `peerToSurface`, its reverse — see that property's doc comment.
    /// Cleared per-surface on `handleSurfaceDestroyed`, and wholesale on
    /// `reset()`.
    private var surfaceToPeer: [UUID: UUID] = [:]

    /// Reverse of `surfaceToPeer`, giving `syncInboxCounts` an O(1),
    /// deterministic peer → surface lookup instead of a linear scan of
    /// `surfaceToPeer` for a matching value (which was also
    /// order-dependent if more than one surface had ever mapped to the
    /// same peer). `bindSurface` enforces "1 peer = 1 surface": binding a
    /// peer to a new surface removes its previous surface's binding, so
    /// this dictionary is always a true reverse of `surfaceToPeer`, never
    /// stale in either direction.
    private var peerToSurface: [UUID: UUID] = [:]

    /// Per-surface accumulated evidence a row itself cannot carry -- see
    /// `AgentEvidence`. Sparse (only a surface some clause has actually
    /// recorded something for has a key): `apply(_:surfaceID:)` drops a
    /// surface's key the moment its evidence goes back to `.isEmpty`.
    /// Reaching `AgentStateResolver.heuristicMissRetirementThreshold`
    /// removes the row entirely — without this, a `.titleHeuristic` row
    /// for a pane whose Claude Code process has long since exited (title
    /// reverted, no more on-screen patterns) would sit at `.idle` in the
    /// sidebar forever. Cleared per-surface on `handleSurfaceDestroyed`,
    /// and wholesale on `reset()`. A hook event or MCP connection also
    /// clears what Calyx merely inferred for the surface, as fresh
    /// self-reported presence supersedes it, while leaving what Calyx's
    /// own shell integration reported alone
    /// (`AgentEvidence.clearingInferredEvidence`).
    private var evidence: [UUID: AgentEvidence] = [:]

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
    ///
    /// Merges both stores -- `entries` (native hooks/titleHeuristic rows)
    /// and `externalEntries` (herdr rows) -- through the same priority/
    /// basename ordering: a row's store of origin never affects its sort
    /// position. No dedup: `externalEntries` is keyed by a herdr-derived
    /// id, never a `SurfaceRegistry` UUID, so it cannot collide with an
    /// `entries` key by construction.
    var sortedEntries: [AgentEntry] {
        (Array(entries.values) + Array(externalEntries.values))
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
        evidence.removeAll()
        configIssues = []
        hooksIssues = []
        isServerRunning = false
        sweepTask?.cancel()
        sweepTask = nil
        subagentRegistry.reset()
        AgentEditedFileLog.shared.reset()
        IPCMessageEventFeed.shared.reset()
    }

    // MARK: - External Entries (Herdr)

    /// Inserts or replaces `entry` in `externalEntries`, keyed by its
    /// `id` (`entry.surfaceID`). Never touches `entries`.
    func upsertExternalEntry(_ entry: AgentEntry) {
        externalEntries[entry.id] = entry
    }

    /// Removes the external entry keyed by `id`, if any. A no-op for an
    /// `id` with no external entry. Never touches `entries`.
    func removeExternalEntry(id: UUID) {
        externalEntries.removeValue(forKey: id)
    }

    /// Whether `externalEntries` currently holds at least one row.
    /// Consulted by `AgentSidebarGate.decide` (`AgentStatusView.swift`)
    /// so the Agents sidebar keeps showing rows even while
    /// `isServerRunning` is `false`.
    var hasExternalEntries: Bool {
        !externalEntries.isEmpty
    }

    // MARK: - MCP Connection Presence

    /// Records explicit agent-presence evidence from a surface-bound MCP
    /// `initialize` request: presence evidence before a pane's first hook
    /// event arrives, and for a pane whose hook entries its CLI has not
    /// been trusted to run.
    ///
    /// A same-kind `.hooks` or `.mcpConnection` entry remains
    /// authoritative, with one exception: `.done`. A pane already
    /// holding a finished row -- a `.hooks` entry settled by a real
    /// `SessionEnd`, or either source settled by
    /// `handlePaneCommandFinished`'s pane-exit signal -- that starts a
    /// fresh agent session whose hook entries have not fired yet (or,
    /// for a kind with no hooks at all, e.g. Hermes, never will) reports
    /// that new session through this `initialize` call alone, so a
    /// `.done` entry falls through to the replace branch below instead
    /// of returning early -- becoming a live `.idle` `.mcpConnection`
    /// entry with `cwd` preserved, rather than stranding the live
    /// session behind the finished one's row. A later real hook event
    /// promotes an `.mcpConnection` entry through `handleHookEvent`'s
    /// existing non-hooks replacement path. Repeated initialize requests
    /// for the same kind and not already `.done` only refresh presence
    /// and preserve the current screen-classified state.
    func handleMCPConnection(surfaceID: UUID, kind: String, now: Date = Date()) {
        apply(
            AgentStateResolver.resolve(
                .mcpConnection(kind: kind),
                surfaceID: surfaceID,
                current: entries[surfaceID],
                evidence: evidence[surfaceID] ?? AgentEvidence(),
                context: context(for: surfaceID),
                now: now
            ),
            surfaceID: surfaceID
        )
    }

    // MARK: - Hook Events

    /// Applies a decoded hook event to the registry via
    /// `AgentStateResolver.resolve(.hook(...))`, whose `resolveHook`
    /// clause owns every precedence rule an event answers to: the
    /// `SessionStart` re-send, the unrecognized event, the terminal
    /// `.done` row, the session mismatch, and -- for a non-subagent
    /// event accepted for the parent row -- whether the surface's
    /// children are retired (`AgentResolution.retiresChildren`, set on a
    /// parent-scoped `SessionEnd`/`SessionStart` or a row replacement
    /// where a different session took the surface over, applied by
    /// `apply` below).
    /// See also the state transition table in the AgentMonitor design
    /// doc.
    ///
    /// - Parameter kind: The agent CLI this event came from (Phase 2:
    ///   Codex / OpenCode alongside the default Claude Code), forwarded by
    ///   `CalyxMCPServer.routeAgentEvent`'s `X-Calyx-Agent-Kind` header.
    ///   Applied only when this call creates or replaces an entry —
    ///   `AgentStateResolver.resolveHook`'s own `makeEntry` — so a
    ///   same-session continuation event (that clause's `SessionStart`
    ///   re-send branch, and its "same session" update path) never
    ///   overwrites an existing entry's `kind` with this parameter's
    ///   default.
    /// - Parameter now: Injectable for tests (defaults to `Date()`).
    ///   Notably used by the same-session update path's PreToolUse race
    ///   guard in `AgentStateResolver.resolveHook`, which compares `now`
    ///   against the moment the row entered `.blocked`
    ///   (`AgentEvidence.blockedSince`).
    func handleHookEvent(
        _ event: AgentEvent,
        surfaceID: UUID,
        kind: String = AgentEntry.claudeCodeKind,
        now: Date = Date()
    ) {
        apply(
            AgentStateResolver.resolve(
                .hook(event, kind: kind),
                surfaceID: surfaceID,
                current: entries[surfaceID],
                evidence: evidence[surfaceID] ?? AgentEvidence(),
                context: context(for: surfaceID),
                now: now
            ),
            surfaceID: surfaceID
        )
        recordEditedFiles(of: event, surfaceID: surfaceID, now: now)
        // A child is only ever tracked under a live row: read the row
        // AFTER apply() above so this decision uses its post-event state,
        // mirroring AgentStateResolver.resolveHookRow's own
        // `existing.state != .done` guard. Without this, a subagent
        // event whose fire-and-forget POST completes after the parent
        // already settled `.done` (or never had a row at all) would
        // create a child nothing can ever remove: the CLI has exited, so
        // no further parent-scoped event will arrive to sweep it.
        //
        // A non-subagent event is never forwarded here at all: its own
        // effect on the surface's children, if any, was already decided
        // by the resolver above (`AgentResolution.retiresChildren`) and
        // carried out by `apply`. `SubagentRegistry` itself only ever
        // creates, updates, or removes a child by its own `agentID`.
        guard event.isSubagentEvent else { return }
        guard let row = entries[surfaceID], row.state != .done else { return }
        subagentRegistry.handleHookEvent(event, parentSurfaceID: surfaceID, now: now)
    }

    /// Records the files `event` is about to write into
    /// `AgentEditedFileLog` for Mission Map's conflict lines. Runs for a
    /// parent and a subagent event alike, and whether or not the
    /// resolver accepted the event for the row: a child editing a file
    /// edits it in the parent's pane all the same, and a file write the
    /// row's state machine ignored still happened.
    ///
    /// A relative path (Codex `apply_patch` names files relative to its
    /// cwd) is resolved here, against the event's own `cwd` or else the
    /// row's -- Grok strips `cwd` from a child's events -- because the
    /// log's consumers see no cwd at all. With neither, the path is kept
    /// as the tool named it.
    private func recordEditedFiles(of event: AgentEvent, surfaceID: UUID, now: Date) {
        guard !event.editedFilePaths.isEmpty, let toolName = event.toolName else { return }
        let baseDirectory = event.cwd ?? entries[surfaceID]?.cwd
        let paths = event.editedFilePaths.map { path -> String in
            guard !(path as NSString).isAbsolutePath, let baseDirectory else { return path }
            return (baseDirectory as NSString).appendingPathComponent(path)
        }
        AgentEditedFileLog.shared.record(surfaceID: surfaceID, paths: paths, toolName: toolName, at: now)
    }

    // MARK: - Pane Command Lifecycle (Shell Integration)

    /// Surfaces Calyx's own shell integration has ever reported on --
    /// recorded by `recordCalyxShellIntegrationReported`, which
    /// `CalyxMCPServer.routeCommandEvent` calls unconditionally for both
    /// a `.start` and an `.end` `CommandEvent` (right after the surface
    /// resolves, regardless of whether `CommandLogStore.ingest` accepts
    /// or rejects it), and which `handlePaneCommandFinished` also calls
    /// unconditionally on every one of its own calls, including one that
    /// settles nothing because the report itself was a suspend
    /// (`suspended: true`) or a stop-signal `exitCode`. Recording on
    /// `.start` too, not just `.end`, matters because ghostty's own OSC
    /// 133 D can otherwise win a race for the same command: ghostty
    /// prepends its resources dir to `XDG_DATA_DIRS` while Calyx appends,
    /// and fish sources vendor integration files in directory order and
    /// dispatches their handlers in registration order, so ghostty's
    /// pane-exit signal can be written before Calyx's own end-of-command
    /// POST even spawns -- recording only on `.end` would leave this set
    /// unpopulated at the exact moment such a race needs it populated.
    ///
    /// `handleGhosttyCommandFinished` defers entirely (returns `false`
    /// without touching the row, recording the deferral on the surface's
    /// evidence instead) once a surface is in this set: only
    /// Calyx's own zsh/fish shell integration can tell a suspend apart
    /// from a real exit for that surface (zsh's `128 + signal`
    /// convention, or fish's own separate lingering-job check), so
    /// ghostty's fallback signal -- which carries no such evidence at all
    /// -- must not risk a false settle for it. That protection is itself
    /// conditional on Command Tracking being on: `AppDelegate
    /// .applyCalyxShellIntegrationIfEnabled` gates the whole shell
    /// integration install and env injection on `CommandTrackingSettings
    /// .trackingEnabled`, so with tracking off no Calyx integration is
    /// ever present in the pane, nothing is ever recorded into this set
    /// for it, and ghostty's fallback signal governs unopposed there --
    /// a fish Ctrl-Z can retire the row early. That residual risk is
    /// accepted rather than narrowed away (narrowing the fallback would
    /// break bash, which has no Calyx integration to fall back from in
    /// the first place): it is bounded to the row's colour, since a
    /// ghostty-sourced settle never expires pending approvals -- only a
    /// Calyx-sourced settle over `/command-event` does
    /// (`CalyxMCPServer.routeCommandEvent`).
    ///
    /// Cleared per-surface on `handleSurfaceDestroyed`. Deliberately
    /// never cleared wholesale, not even by `reset()`: a pane whose shell
    /// already sourced Calyx's integration keeps reporting even after
    /// Command Tracking is switched off, so the memory staying put is
    /// correct -- only a newly destroyed/recreated surface starts over
    /// with no memory and correctly falls back to ghostty again.
    private var calyxShellIntegrationReportedSurfaces: Set<UUID> = []

    /// Records that Calyx's own shell integration is live in
    /// `surfaceID`'s pane, without touching the row's state at all --
    /// the recording half of what `handlePaneCommandFinished` already
    /// does unconditionally on every call of its own. `CalyxMCPServer
    /// .routeCommandEvent` calls this directly, for both a `.start` and
    /// an `.end` `CommandEvent`, right after the surface resolves and
    /// regardless of `CommandLogStore.ingest`'s acceptance: a rejected
    /// duplicate event still proves Calyx's integration is live in that
    /// pane. See `calyxShellIntegrationReportedSurfaces`'s own doc
    /// comment for why recording on `.start` as well as `.end` matters --
    /// that reasoning is unaffected by `phase` below, which governs only
    /// what the resolver does with the report, not whether this set is
    /// updated.
    ///
    /// Also routes the report through the resolver, tagged with `phase`.
    /// Only `.commandEnd` stamps `AgentEvidence.lastCalyxCommandEndAt`
    /// and answers any outstanding ghostty deferral for the surface --
    /// `AgentStateResolver.resolveCalyxShellIntegrationReported` owns
    /// that decision; a `.commandStart` report leaves the surface's
    /// evidence untouched, since a command merely starting answers no
    /// question about whether any job has finished. That evidence has a
    /// lifetime of one command, so it lives in `evidence` rather than in
    /// the permanent set above.
    ///
    /// - Parameter now: Injectable for tests (defaults to `Date()`).
    func recordCalyxShellIntegrationReported(
        surfaceID: UUID, phase: CalyxShellReportPhase, now: Date = Date()
    ) {
        calyxShellIntegrationReportedSurfaces.insert(surfaceID)
        apply(
            AgentStateResolver.resolve(
                .calyxShellIntegrationReported(phase: phase),
                surfaceID: surfaceID,
                current: entries[surfaceID],
                evidence: evidence[surfaceID] ?? AgentEvidence(),
                context: context(for: surfaceID),
                now: now
            ),
            surfaceID: surfaceID
        )
    }

    /// Settles `surfaceID`'s entry to `.done` in response to the pane's
    /// shell integration reporting a `/command-event` with `phase: end`:
    /// zsh's `precmd` / fish's `fish_postexec` firing means the pane's
    /// foreground command finished and the prompt returned. Both shell
    /// integration bodies `ShellIntegrationInstaller` installs are
    /// interactive-only (`[[ -o interactive ]]` for zsh, `status
    /// --is-interactive` for fish), so a non-interactive shell an agent
    /// spawns for its own tool calls never emits this signal -- making it
    /// a trustworthy proxy for "the pane's foreground agent process
    /// exited" even for a CLI kind with no way to self-report its own
    /// exit (OpenCode's plugin event vocabulary has no process-exit
    /// event; Hermes has no hooks at all), and a backstop for a CLI whose
    /// hooks were never trusted to run, or one that exits via
    /// SIGKILL/crash before a hook fires.
    ///
    /// `phase: end` also fires when the foreground job is merely
    /// SUSPENDED (e.g. Ctrl-Z), not exited. This registry recognizes that
    /// case through two routes: the shell reporting `exitCode` as
    /// `128 + <stop signal>` (`isStopSignalExitCode`) -- a convention
    /// zsh's own `$?` satisfies natively -- or the caller passing
    /// `suspended: true`. The latter exists because fish's own `$status`
    /// inside `fish_postexec` does not change on a suspend (it keeps the
    /// PREVIOUS command's real exit code instead), so
    /// `ShellIntegrationInstaller.fishIntegrationBody`'s `_calyx_postexec`
    /// cannot signal a suspend through `exitCode` at all -- it detects a
    /// lingering stopped job via `jobs` and reports that through this
    /// separate flag instead, leaving `exitCode` free to carry fish's
    /// real (if occasionally stale for the suspended command's own
    /// record -- see that method's own doc comment) `$status`. Either
    /// route excludes the event from settling the row -- the job is
    /// still alive, about to be resumed with `fg`. Every other case,
    /// including `exitCode` of `nil` with `suspended` false (no code
    /// reported at all, so there is no positive evidence of a suspend to
    /// exclude), settles it.
    ///
    /// Settles only a `.hooks` or `.mcpConnection` entry not already
    /// `.done`. A `.titleHeuristic` row is left alone -- it retires
    /// itself through its own miss-streak bookkeeping
    /// (`evidence`) instead. An already-`.done` row is left
    /// alone too (no `lastEventAt` churn), an unregistered surface stays
    /// unregistered (this never creates a row), and `externalEntries`
    /// (herdr rows, not keyed by a `SurfaceRegistry` UUID) is never
    /// touched.
    ///
    /// Returns whether this call actually transitioned the row to
    /// `.done` -- `false` for every guard above, `.hooks`-source-mismatch
    /// case, and suspend exclusion (either route) included.
    /// `CalyxMCPServer.routeCommandEvent` consults this to decide whether
    /// to also expire that surface's pending approvals
    /// (`ApprovalInboxStore.expireForSurface`): a suspend, or any other
    /// reason this call didn't settle anything, must not cancel an
    /// approval request the still-alive agent is waiting on.
    ///
    /// Every call -- settling something or not -- unconditionally records
    /// `surfaceID` via `recordCalyxShellIntegrationReported` first: see
    /// `calyxShellIntegrationReportedSurfaces`'s own doc comment for why
    /// `handleGhosttyCommandFinished` depends on the recording happening
    /// even when this call settles nothing. `CalyxMCPServer
    /// .routeCommandEvent` also calls `recordCalyxShellIntegrationReported`
    /// directly, on both a `.start` and an `.end` event, so the memory
    /// does not depend on this method ever being reached.
    @discardableResult
    func handlePaneCommandFinished(
        surfaceID: UUID, exitCode: Int32? = nil, suspended: Bool = false, now: Date = Date()
    ) -> Bool {
        recordCalyxShellIntegrationReported(surfaceID: surfaceID, phase: .commandEnd, now: now)
        let resolution = AgentStateResolver.resolve(
            .paneCommandFinished(exitCode: exitCode, suspended: suspended, origin: .calyxShellIntegration),
            surfaceID: surfaceID,
            current: entries[surfaceID],
            evidence: evidence[surfaceID] ?? AgentEvidence(),
            context: context(for: surfaceID),
            now: now
        )
        apply(resolution, surfaceID: surfaceID)
        return resolution.didSettle
    }

    /// Settles `surfaceID`'s entry to `.done` in response to
    /// `GHOSTTY_ACTION_COMMAND_FINISHED` (ghostty's own OSC 133 C/D
    /// pane-exit signal, forwarded via `.ghosttyCommandFinished`) -- a
    /// fallback for the shells Calyx's own `/command-event` shell
    /// integration does not cover (bash, elvish, nushell;
    /// `ShellIntegrationInstaller` only installs zsh/fish bodies). Routes
    /// through `AgentStateResolver.resolve(.paneCommandFinished(...,
    /// origin: .ghostty))`, sharing `handlePaneCommandFinished`'s own
    /// `.hooks`/`.mcpConnection`-only, not-already-`.done` guards and the
    /// same `isStopSignalExitCode` exclusion for a shell's `128 + signal`
    /// report.
    ///
    /// Unlike `handlePaneCommandFinished`, this has no `suspended`
    /// parameter: ghostty has no equivalent of zsh's `128 + signal`
    /// convention or fish's own separate lingering-job check, so it has
    /// no way to positively detect a suspend beyond the stop-signal exit
    /// code the shared guards already exclude. Because of that gap, the
    /// resolver's own `origin: .ghostty` clause defers entirely --
    /// leaves the row untouched -- once `calyxShellIntegrationReportedSurfaces`
    /// (surfaced to the resolver as `context(for:)`'s
    /// `calyxShellIntegrationSeen`) already contains this surface: once
    /// Calyx's own integration has ever reported on a surface, it alone
    /// is trusted to tell a suspend apart from a real exit for that
    /// surface. The mistake this asymmetry protects against is
    /// one-directional, same as `isStopSignalExitCode`'s own: a false
    /// "still alive" from this method only leaves a row live, whereas a
    /// false settle from a source blind to suspends would wrongly expire
    /// a live agent's pending approvals.
    ///
    /// The deferred signal is remembered rather than discarded
    /// (`AgentEvidence.deferredGhosttyFinishAt`), so `sweepStaleEntries`
    /// can settle the row when Calyx's own `/command-event` never
    /// answers it: the shell integration body swallows a failed POST, and
    /// without the memory a lost `phase: end` would leave the row stuck
    /// forever, since ghostty deferred to a report that never came.
    ///
    /// Returns whether this call actually transitioned the row to
    /// `.done`. Never consulted to expire pending approvals -- that
    /// wiring lives in `CalyxMCPServer.routeCommandEvent`, gated on
    /// `handlePaneCommandFinished`'s own return value, and this method is
    /// not reachable from that call site.
    @discardableResult
    func handleGhosttyCommandFinished(surfaceID: UUID, exitCode: Int32?, now: Date = Date()) -> Bool {
        let resolution = AgentStateResolver.resolve(
            .paneCommandFinished(exitCode: exitCode, suspended: false, origin: .ghostty),
            surfaceID: surfaceID,
            current: entries[surfaceID],
            evidence: evidence[surfaceID] ?? AgentEvidence(),
            context: context(for: surfaceID),
            now: now
        )
        apply(resolution, surfaceID: surfaceID)
        return resolution.didSettle
    }

    // MARK: - Resolver Application

    /// Applies an `AgentStateResolver.resolve` result to storage: the
    /// surface's evidence, any peer binding the signal reported, then
    /// the row itself. `evidence` and `entries` are both stored
    /// properties of this `@Observable` class, so both writes are
    /// guarded on the value actually changing, leaning on `AgentEvidence`
    /// and `AgentEntry` both being `Equatable`: the screen poll resolves
    /// every surface every two seconds and the staleness sweep every
    /// minute, and the great majority of those resolutions change
    /// neither, which an unguarded write would still publish as a
    /// mutation. `evidence` also stays sparse, dropping `surfaceID`'s
    /// key once it goes back to `.isEmpty`.
    ///
    /// Also sweeps `subagentRegistry`'s children of `surfaceID` whenever
    /// this resolution leaves the surface without a live row (the row
    /// was removed, or the row's state became `.done`), or whenever the
    /// resolver itself decided the surface's children are retired
    /// (`AgentResolution.retiresChildren` -- a resolver-accepted
    /// parent-scoped `SessionEnd`/`SessionStart`, or a resolver-accepted
    /// row replacement where a different session took the row over,
    /// decided entirely by `AgentStateResolver.resolveHook`; this method
    /// never re-derives that decision from the event's name or from
    /// comparing sessionIDs itself). An accepted, same-session parent
    /// `Stop` settles the row to `.idle` the same as before but no
    /// longer sweeps children -- a parent row can now legitimately sit
    /// `.idle` while its children are still `.working`, since a CLI can
    /// and does keep a subagent running past its parent's own turn
    /// ending; a `Stop` that instead replaces the row with a different
    /// session's does sweep, since a different session actually took the
    /// row over. Every settle path funnels through here -- a
    /// hook-reported `SessionEnd`,
    /// a pane-exit signal (`handlePaneCommandFinished`), and the
    /// staleness sweep's deferred-ghostty settle (`resolveStaleSweep`)
    /// alike -- so a child can never outlive a parent row that stopped
    /// reporting, regardless of which route settled it. A
    /// `.working`-to-`.idle` staleness downgrade is deliberately
    /// excluded: `.idle` is still a live row, and that downgrade is
    /// Calyx's own inference about a row it hasn't heard from, not a
    /// report that the agent finished.
    ///
    /// A row that enters `.done` here (from a live state or from no row)
    /// also posts `.calyxAgentConversationEnded` for `surfaceID`, after
    /// the row is written. `.done` is written only by a hook-reported
    /// `SessionEnd` and by the pane-exit settles, so the post means the
    /// pane's conversation ended: the agent process exited or the session
    /// was cleared. Claude Code sends `SessionEnd` with `reason: "clear"`
    /// on `/clear` and keeps running; that also posts. A `.remove` posts
    /// nothing: the resolver's only `.remove` retires an inferred
    /// `.titleHeuristic` row. `handleSurfaceDestroyed` and `reset()` do
    /// not pass through here and post nothing either.
    private func apply(_ r: AgentResolution, surfaceID: UUID) {
        let newEvidence = r.evidence.isEmpty ? nil : r.evidence
        if evidence[surfaceID] != newEvidence { evidence[surfaceID] = newEvidence }
        if let peerID = r.learnedPeerID {
            bindSurface(surfaceID, toPeer: peerID)
        }
        switch r.row {
        case .keep:
            break
        case .write(let row):
            let previousState = entries[surfaceID]?.state
            if entries[surfaceID] != row { entries[surfaceID] = row }
            if row.state == .done || r.retiresChildren {
                subagentRegistry.handleSurfaceDestroyed(parentSurfaceID: surfaceID)
            }
            if row.state == .done, previousState != .done {
                NotificationCenter.default.post(
                    name: .calyxAgentConversationEnded, object: self, userInfo: ["surfaceID": surfaceID]
                )
            }
        case .remove:
            if entries[surfaceID] != nil { entries.removeValue(forKey: surfaceID) }
            subagentRegistry.handleSurfaceDestroyed(parentSurfaceID: surfaceID)
        }
    }

    /// Builds the registry-wide facts `AgentStateResolver.resolve` needs
    /// alongside a surface's own row and evidence.
    private func context(for surfaceID: UUID) -> ResolverContext {
        ResolverContext(
            isServerRunning: isServerRunning,
            calyxShellIntegrationSeen: calyxShellIntegrationReportedSurfaces.contains(surfaceID)
        )
    }

    // MARK: - Title Heuristic Fallback

    /// Applies the second-layer title-based classifier via
    /// `AgentStateResolver.resolve(.title(...))`. Only creates or updates
    /// a `.titleHeuristic` entry — an existing `.hooks`-sourced entry is
    /// authoritative and is left untouched, and an `.mcpConnection`
    /// entry's state is owned by screen classification, not a title.
    ///
    /// `ClaudeTitleHeuristic.classify` runs here, outside the resolver,
    /// so `AgentSignal.title` can carry a non-optional `AgentState`:
    /// `.screen` already spends `nil` on "a classification that
    /// recognized nothing", and `ClaudeTitleHeuristic` is a per-CLI type
    /// the shared resolver must stay free of -- see `AgentSignal.title`'s
    /// own doc comment.
    ///
    /// Creating a NEW row additionally requires `isServerRunning` —
    /// mirroring `pollScreenClassificationIfAgentsSidebarVisible`'s own
    /// gate in `CalyxWindowController`, which already refuses to feed
    /// `handleScreenClassification` while the server is stopped, for
    /// exactly the same reason: classifying into the registry while IPC
    /// is off would only produce a row this app can't retire on its own.
    /// This call site (fed unconditionally by every pane's title change,
    /// via `handleSetTitleNotification`) is otherwise the one
    /// heuristic-creation path with no such gate of its own — with herdr
    /// connected, the Agents sidebar stays visible (`AgentSidebarGate`)
    /// even while `isServerRunning` is `false`, so a `.titleHeuristic`
    /// row created here in that combination would have no way to ever
    /// retire: the miss-streak sweep that would clean it up lives inside
    /// `handleScreenClassification`, reachable only from that same
    /// isServerRunning-gated poll. Gating creation the same way makes
    /// creation and retirement symmetric — both require the server to be
    /// running. Updating an EXISTING `.titleHeuristic` entry needs no
    /// separate such guard: no such entry can exist while
    /// `isServerRunning` is `false` in the first place, since
    /// `CalyxMCPServer.stop()` unconditionally clears `entries` via
    /// `reset()` before flipping `isServerRunning` false.
    ///
    /// Option considered and rejected: decoupling the retirement sweep
    /// from `isServerRunning` instead (running it whenever the sidebar is
    /// showing rows). That sweep lives inside `handleScreenClassification`
    /// itself, inseparable from ITS OWN row-creation path — un-gating the
    /// poll that feeds it would let screen classification start creating
    /// rows while IPC is off too, reintroducing this exact asymmetry one
    /// layer over instead of fixing it.
    ///
    /// - Parameter now: Injectable for tests (defaults to `Date()`).
    func handleTitleChange(surfaceID: UUID, title: String, now: Date = Date()) {
        guard let classified = ClaudeTitleHeuristic.classify(title: title) else { return }

        apply(
            AgentStateResolver.resolve(
                .title(classified),
                surfaceID: surfaceID,
                current: entries[surfaceID],
                evidence: evidence[surfaceID] ?? AgentEvidence(),
                context: context(for: surfaceID),
                now: now
            ),
            surfaceID: surfaceID
        )
    }

    /// Replaces `configIssues` wholesale. Called by
    /// `IPCActivationCoordinator` with `config.issueMessages`, or `[]`
    /// when every agent config write succeeded (or IPC was disabled).
    /// `AgentStatusView` renders a warning banner whenever
    /// `integrationIssues` is non-empty.
    func setConfigIssues(_ issues: [String]) {
        configIssues = issues
    }

    /// Replaces `hooksIssues` wholesale. Called by
    /// `IPCActivationCoordinator` with `hooks.issueMessages`, and by
    /// `AppDelegate`'s unattended launch-time hooks re-sync with the
    /// same shape, or `[]` when every hook install succeeded (or IPC was
    /// disabled). `AgentStatusView` renders a warning banner whenever
    /// `integrationIssues` is non-empty.
    func setHooksIssues(_ issues: [String]) {
        hooksIssues = issues
    }

    /// Replaces `serverIssues` wholesale. Called by
    /// `IPCActivationCoordinator` with the same one-line reason
    /// `IPCServerFailure.description` produces for
    /// `.tokenGeneration` / `.start`, or `[]` on a
    /// successful `enable()` or on `disable()`. See `serverIssues`'s own
    /// doc comment for why `reset()` never clears this domain.
    func setServerIssues(_ issues: [String]) {
        serverIssues = issues
    }

    // MARK: - Screen State Classification (Herdr Layer 2)

    /// Applies a `ScreenStateClassifier` result polled from a pane's
    /// on-screen text, via `AgentStateResolver.resolve(.screen(...))`.
    /// `.hooks`-sourced entries are left untouched (hooks self-report is
    /// authoritative). An `.mcpConnection` entry uses the screen result
    /// for state while retaining the row on `nil`: the MCP initialize is
    /// independent evidence that the pane hosts an agent, so an
    /// unrecognized idle screen must not retire it -- and a `.done`
    /// `.mcpConnection` entry is left untouched rather than folded into
    /// that `nil`-retains-the-row handling, since the Agents sidebar
    /// polls screen classification every two seconds and would otherwise
    /// revert a just-settled row almost immediately. An existing
    /// `.titleHeuristic` entry is updated as an *authoritative* signal --
    /// `.blocked`/`.working` reflected as-is (resetting the heuristic
    /// miss streak, since this is a "positive" signal), `nil` falling
    /// back to `.idle` and counting as a miss, with enough consecutive
    /// misses removing the row entirely rather than leaving it parked at
    /// `.idle` forever. An unregistered surface only gets a new
    /// `.titleHeuristic` entry when `state` is `.blocked` or `.working`:
    /// a `nil` classification never creates a row for a plain shell
    /// pane. See `AgentStateResolver.resolveScreen` for the full clause,
    /// including the miss-streak asymmetry against `.title`/`.progress`.
    ///
    /// - Parameter now: Injectable for tests (defaults to `Date()`).
    func handleScreenClassification(surfaceID: UUID, state: AgentState?, now: Date = Date()) {
        apply(
            AgentStateResolver.resolve(
                .screen(state),
                surfaceID: surfaceID,
                current: entries[surfaceID],
                evidence: evidence[surfaceID] ?? AgentEvidence(),
                context: context(for: surfaceID),
                now: now
            ),
            surfaceID: surfaceID
        )
    }

    /// Applies an OSC 9;4 progress-report signal
    /// (`GHOSTTY_ACTION_PROGRESS_REPORT`) polled/observed for a pane, via
    /// `AgentStateResolver.resolve(.progress(...))`. `.hooks`-sourced
    /// entries are untouched, and a progress report never creates a row
    /// on its own — screen classification's blocked/working patterns are
    /// the more conservative signal for that. Only an existing
    /// `.titleHeuristic` entry is affected: it flips to `.working` when
    /// `isActive` is `true` (a "positive" signal — see `evidence`'s doc
    /// comment) and `.idle` when `false`, as a non-authoritative signal
    /// that cannot clear `.blocked`.
    ///
    /// - Parameter now: Injectable for tests (defaults to `Date()`).
    func handleProgressReport(surfaceID: UUID, isActive: Bool, now: Date = Date()) {
        apply(
            AgentStateResolver.resolve(
                .progress(isActive: isActive),
                surfaceID: surfaceID,
                current: entries[surfaceID],
                evidence: evidence[surfaceID] ?? AgentEvidence(),
                context: context(for: surfaceID),
                now: now
            ),
            surfaceID: surfaceID
        )
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
    /// Not `private`: `handleHookEvent` below still calls this
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

    /// Returns the peer ID currently bound to `surfaceID` via `bindSurface`,
    /// or `nil` if the surface has no binding. Hands back the peer id
    /// itself, not a bare "is it bound" flag, so callers can look up
    /// whether that peer is still alive in `IPCStore`. Two call sites in
    /// `CalyxMCPServer` rely on this:
    /// `handleJSONRPC`'s `initialize` case uses it to resolve a
    /// reconnecting surface's ONE true peer identity — reporting the same
    /// `peer_id` back instead of auto-registering a fresh one — and
    /// `handleRegisterPeer` uses it to rename that peer in place instead
    /// of minting a second identity for the same surface.
    func boundPeerID(for surfaceID: UUID) -> UUID? {
        surfaceToPeer[surfaceID]
    }

    /// The surface currently bound to `peerID`, or `nil` if none is --
    /// `boundPeerID(for:)`'s reverse. Mission Map resolves an IPC
    /// message's sender and recipient peers to the panes it draws the
    /// message's line between.
    func surfaceID(boundTo peerID: UUID) -> UUID? {
        peerToSurface[peerID]
    }

    /// A read-only copy of every peer -> surface binding, for building a
    /// whole Mission Map snapshot in one read instead of one lookup per
    /// peer. `peerToSurface` itself stays private so `bindSurface`
    /// remains the only writer of the bijection.
    var peerToSurfaceMap: [UUID: UUID] {
        peerToSurface
    }

    // MARK: - Unread Message Badges

    /// Every peer ID currently bound to a surface. `CalyxMCPServer`
    /// reads this once per `tools/call` request to batch-sync unread
    /// badges via `syncInboxCounts` — see that method's doc comment.
    var boundPeerIDs: [UUID] {
        Array(peerToSurface.keys)
    }

    /// Applies `counts` (typically `IPCStore.inboxCounts(for: boundPeerIDs)`)
    /// to every currently-bound surface in one pass, via
    /// `peerToSurface`'s O(1) reverse lookup: each peer's count becomes
    /// the `unreadCount` of the surface bound to it (a binding learned
    /// from a `PreToolUse`/`PostToolUse` hook event carrying an
    /// `AgentEvent.ipcSelfPeerID` -- see `bindSurface`). `CalyxMCPServer`
    /// calls this once at the end of every `tools/call` request, batching
    /// every IPC tool handler's badge update into a single pass -- see
    /// that call site's doc comment. A `peerID` in `counts` with no bound
    /// surface (e.g. a stale/purged peer) is simply skipped.
    func syncInboxCounts(_ counts: [UUID: Int]) {
        for (peerID, count) in counts {
            guard let surfaceID = peerToSurface[peerID], var entry = entries[surfaceID] else { continue }
            entry.unreadCount = count
            entries[surfaceID] = entry
        }
    }

    // MARK: - Staleness Sweep

    /// Applies the sweep to every native row, per the rules in
    /// `AgentStateResolver.resolveStaleSweep`: a `.working` row idle past
    /// the staleness threshold is downgraded to `.idle`, and a row
    /// holding a ghostty pane-exit signal Calyx's own shell integration
    /// never answered is settled to `.done`. Neither can expire a
    /// surface's pending approvals: that wiring lives in
    /// `CalyxMCPServer.routeCommandEvent`, gated on
    /// `handlePaneCommandFinished`'s return value, and this method
    /// reports nothing to it.
    func sweepStaleEntries(now: Date = Date()) {
        for (surfaceID, entry) in entries {
            apply(
                AgentStateResolver.resolve(
                    .staleSweep,
                    surfaceID: surfaceID,
                    current: entry,
                    evidence: evidence[surfaceID] ?? AgentEvidence(),
                    context: context(for: surfaceID),
                    now: now
                ),
                surfaceID: surfaceID
            )
        }
    }

    // MARK: - Surface Lifecycle

    func handleSurfaceDestroyed(surfaceID: UUID) {
        entries.removeValue(forKey: surfaceID)
        unbindSurface(surfaceID)
        evidence.removeValue(forKey: surfaceID)
        calyxShellIntegrationReportedSurfaces.remove(surfaceID)
        subagentRegistry.handleSurfaceDestroyed(parentSurfaceID: surfaceID)
        AgentEditedFileLog.shared.removeAll(for: surfaceID)
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

    /// Posted by `AgentRegistry` when a pane's row enters `.done`: the
    /// pane's conversation ended, because the agent process exited or the
    /// session was cleared (Claude Code's `/clear` sends `SessionEnd` and
    /// the process keeps running). `object` is the registry;
    /// `userInfo["surfaceID"]` carries the pane's surface `UUID`.
    static let calyxAgentConversationEnded = Notification.Name("com.calyx.agentMonitor.agentConversationEnded")

    /// Posted when an Agents sidebar row is clicked. `userInfo["surfaceID"]`
    /// carries the `UUID` of the surface to focus.
    static let calyxFocusSurface = Notification.Name("com.calyx.agentMonitor.focusSurface")
}
