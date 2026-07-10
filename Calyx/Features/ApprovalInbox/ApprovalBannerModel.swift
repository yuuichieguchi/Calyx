// ApprovalBannerModel.swift
// Calyx
//
// Per-window view-model behind the Cockpit approval banner, choosing
// which single pending ApprovalRequest (if any) this window should show
// and forwarding Allow/Deny/Always Allow/Allow All Pending to
// ApprovalInboxStore.decide(id:_:) / CockpitSettings.autoApproveEnabled /
// AgentHookApprovalMemory (Stage E -- see alwaysAllow(id:)'s own doc
// comment for the .mcpTool vs .agentHook source split).
// Mirrors RecoveryBarModel's shape: UI-independent, injected closures
// instead of reaching for CalyxWindowController/NSWindow directly, one
// instance per window. See
// CalyxTests/ApprovalInbox/ApprovalBannerModelTests.swift for the
// specced contract.

import Foundation

@MainActor
@Observable
final class ApprovalBannerModel {

    private let store: ApprovalInboxStore
    private let ownsSurface: (UUID) -> Bool
    private let isKeyWindow: () -> Bool
    private let memory: AgentHookApprovalMemory

    init(
        store: ApprovalInboxStore,
        ownsSurface: @escaping (UUID) -> Bool,
        isKeyWindow: @escaping () -> Bool,
        memory: AgentHookApprovalMemory = .shared
    ) {
        self.store = store
        self.ownsSurface = ownsSurface
        self.isKeyWindow = isKeyWindow
        self.memory = memory
    }

    /// Whether this window should surface `request` at all. A
    /// surface-targeted request (e.g. a `pane_run` call) is visible only
    /// to the window that owns that surface; a window-agnostic request
    /// (nil `targetSurfaceID`, e.g. a palette-level tool call) is
    /// visible only while this window is key, so every open window
    /// doesn't surface the same banner at once.
    private func isVisible(_ request: ApprovalRequest) -> Bool {
        if let targetSurfaceID = request.targetSurfaceID {
            return ownsSurface(targetSurfaceID)
        }
        return isKeyWindow()
    }

    /// `store.pending` is already oldest-first (see
    /// ApprovalInboxStore.submit's own doc comment), so the first
    /// visible match here is the oldest one this window owns.
    var current: ApprovalRequest? {
        store.pending.first { isVisible($0) }
    }

    /// Mirrors `current`'s own ownership filter, for a "+N more"
    /// affordance in the banner while more than one request is queued
    /// for this window.
    var pendingCountForWindow: Int {
        store.pending.filter { isVisible($0) }.count
    }

    /// Store-wide pending count, with NO window/ownership visibility
    /// filter at all -- used by the cross-actions menu's "Allow All
    /// Pending (N)" label (see `ApprovalBannerView`), distinct from
    /// `pendingCountForWindow` above, which counts only requests this
    /// window owns/can see.
    var totalPendingCount: Int {
        store.pending.count
    }

    /// `id` is the request the CALLER actually rendered (threaded in by
    /// `ApprovalBannerView` from its own `request.id`), not re-derived
    /// from `current` -- `current` can advance between a render and a
    /// click (another decide()/expire() landing first), so re-reading it
    /// here could resolve a DIFFERENT request than the one the human
    /// looked at and clicked Allow/Deny on. A stale `id` (no longer
    /// pending) is a safe no-op -- `store.decide` itself already no-ops
    /// for that case, so no separate guard is needed here (unlike
    /// `alwaysAllow(id:)` below, which guards its own extra side effects).
    func allow(id: UUID) {
        store.decide(id: id, .allowed)
    }

    func deny(id: UUID) {
        store.decide(id: id, .denied)
    }

    /// Branches on the clicked request's own `source` (Stage E).
    ///
    /// For an `.mcpTool`-sourced request: turns on auto-approve for every
    /// FUTURE gated action, resolves the clicked `id` allowed first (the
    /// request the human actually looked at), then drains every OTHER
    /// `.mcpTool`-sourced request already queued and visible to THIS
    /// window -- otherwise the user would have to separately dismiss each
    /// banner already on screen right after turning auto-approve on.
    /// Deliberately scoped to this window: a pending request owned by a
    /// DIFFERENT window is left alone here (auto-approve only gates that
    /// request's future re-submits; that other window drains its own
    /// backlog the same way on its own next interaction). Also
    /// deliberately scoped by SOURCE (R2 fix-pin): a queued
    /// `.agentHook`-sourced request -- even one targeting the SAME
    /// surface -- is never swept into this drain, since flipping global
    /// auto-approve says nothing about that request's own, separate
    /// Always-Allow memory; only that request's own always-allow action
    /// (the `.agentHook` branch below) may ever decide it.
    ///
    /// For an `.agentHook`-sourced request (Stage E, new): NEVER touches
    /// `CockpitSettings.autoApproveEnabled` at all. Instead records PANE
    /// Always-Allow memory (the clicked request's own `targetSurfaceID`,
    /// `kind`, `toolName`) via the injected `memory`, then drains only
    /// the pending requests matching that EXACT tuple (store-wide is
    /// fine -- the same `targetSurfaceID` already implies the same
    /// window). An agent-hook request always carries a target surface
    /// (the endpoint that submits it 400s otherwise), but this
    /// guard-lets and bails gracefully rather than assuming so.
    ///
    /// Either way, a no-op (no setting change, no memory recorded, no
    /// drain) if `id` is no longer pending -- a stale click must never
    /// silently turn auto-approve on or record memory.
    ///
    /// The whole drain goes through `ApprovalInboxStore.decide(ids:_:)`
    /// (the batched form) rather than one `decide(id:_:)` call per
    /// request, so this posts exactly ONE `.calyxApprovalInboxChanged`
    /// change notification -- and therefore triggers exactly one
    /// `refreshHostingView()` per open window -- no matter how many
    /// requests the backlog contains, instead of one full main-content
    /// rebuild per drained request.
    func alwaysAllow(id: UUID) {
        guard let request = store.pending.first(where: { $0.id == id }) else { return }

        switch request.source {
        case .mcpTool:
            CockpitSettings.autoApproveEnabled = true
            var idsToAllow = [id]
            idsToAllow.append(contentsOf: store.pending.filter { candidate in
                guard candidate.id != id, isVisible(candidate) else { return false }
                guard case .mcpTool = candidate.source else { return false }
                return true
            }.map(\.id))
            store.decide(ids: idsToAllow, .allowed)

        case .agentHook(let toolName, let kind, _):
            guard let targetSurfaceID = request.targetSurfaceID else { return }
            memory.rememberPane(surfaceID: targetSurfaceID, kind: kind, toolName: toolName)
            let idsToAllow = store.pending
                .filter { $0.targetSurfaceID == targetSurfaceID && matchesAgentHook($0.source, kind: kind, toolName: toolName) }
                .map(\.id)
            store.decide(ids: idsToAllow, .allowed)
        }
    }

    /// Decides EVERY pending request in the store `.allowed`, store-wide,
    /// with NO window/ownership visibility filter and no source filter
    /// at all. Leaves no Always-Allow memory behind and never touches
    /// any setting -- called by the cross-actions menu's "Allow All
    /// Pending" item (see `ApprovalBannerView`).
    func allowAllPending() {
        store.decide(ids: store.pending.map(\.id), .allowed)
    }

    /// Only meaningful for an `.agentHook`-sourced request: records
    /// CROSS Always-Allow memory (`kind`, `toolName` only -- no
    /// `surfaceID`) via the injected `memory`, then drains every pending
    /// request store-wide sharing that (`kind`, `toolName`), regardless
    /// of window/pane ownership. A no-op (no memory recorded, nothing
    /// drained, no setting touched) if `id` is no longer pending or its
    /// source is `.mcpTool` -- this action only makes sense for an
    /// agent-hook tool call, which has its own `toolName`/`kind` to key
    /// off of.
    func alwaysAllowAcrossPanes(id: UUID) {
        guard let request = store.pending.first(where: { $0.id == id }) else { return }
        guard case .agentHook(let toolName, let kind, _) = request.source else { return }

        memory.rememberCross(kind: kind, toolName: toolName)
        let idsToAllow = store.pending
            .filter { matchesAgentHook($0.source, kind: kind, toolName: toolName) }
            .map(\.id)
        store.decide(ids: idsToAllow, .allowed)
    }

    /// Whether `source` is an `.agentHook` request sharing the exact
    /// (`kind`, `toolName`) pair -- the batch-drain match key both the
    /// pane-scoped half of `alwaysAllow(id:)` and
    /// `alwaysAllowAcrossPanes(id:)` use, deliberately ignoring
    /// `summary` (a per-call, human-readable description, not part of
    /// the tool identity these actions key off of).
    private func matchesAgentHook(_ source: ApprovalRequest.Source, kind: String, toolName: String) -> Bool {
        guard case .agentHook(let sourceToolName, let sourceKind, _) = source else { return false }
        return sourceToolName == toolName && sourceKind == kind
    }
}
