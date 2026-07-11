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
// instance per window.
//
// Queue navigation (prev/next cursor): a stored `selectedRequestID`
// lets a window step through every request visible to it via
// `selectNext()`/`selectPrevious()`, instead of only ever showing the
// oldest one -- see `current`'s own doc comment for the full contract,
// and `advanceCursor(pastDisplayed:)` for how deciding the DISPLAYED
// request keeps the cursor moving forward through the backlog. See
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

    /// This window's own navigation cursor -- see `current`'s own doc
    /// comment for the full selected-if-still-visible/inert-once-stale
    /// contract.
    private var selectedRequestID: UUID?

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

    /// Every pending request visible to this window (same ownership/
    /// key-window filter as `isVisible`), in `store.pending`'s own
    /// oldest-first order (see `ApprovalInboxStore.submit`'s own doc
    /// comment) -- the queue `current`/`positionInfo`/`selectNext()`/
    /// `selectPrevious()`/`advanceCursor(pastDisplayed:)` all navigate.
    private var visibleRequests: [ApprovalRequest] {
        store.pending.filter { isVisible($0) }
    }

    /// The request this window currently displays: `selectedRequestID`
    /// while it is still pending AND visible to this window, else the
    /// oldest visible request (mirrors this property's original,
    /// pre-navigation behavior, and what a freshly-resolved selection
    /// falls back to). `selectedRequestID` is deliberately never cleared
    /// just because its request leaves `visibleRequests` -- it goes
    /// permanently INERT instead, rather than being reset to nil. That's
    /// safe because `ApprovalRequest.id` is a UUID: no future request
    /// can ever be assigned that same id, so a stale cursor can never
    /// accidentally resurrect and re-select some unrelated LATER
    /// request -- it just keeps missing every lookup here (falling back
    /// to the oldest visible request) until some action explicitly
    /// reassigns it (`selectNext()`/`selectPrevious()`/
    /// `advanceCursor(pastDisplayed:)`), or clears it outright
    /// (`allowAllPending()`).
    var current: ApprovalRequest? {
        let visible = visibleRequests
        if let selectedRequestID, let selected = visible.first(where: { $0.id == selectedRequestID }) {
            return selected
        }
        return visible.first
    }

    /// This window's 1-based (index, count) position of `current` within
    /// `visibleRequests` -- nil exactly when `current` is nil. Backs the
    /// banner's "N / M" position label (`ApprovalBannerView.
    /// queueNavigator(positionInfo:)`), shown only while more than one
    /// request is queued for this window. Locates the displayed request
    /// within its own already-computed `visible` local directly (mirrors
    /// `current`'s own selected-if-present-else-first selection logic)
    /// rather than calling `current` itself, which would re-filter
    /// `store.pending` a second time for the same answer.
    var positionInfo: (index: Int, count: Int)? {
        let visible = visibleRequests
        guard !visible.isEmpty else { return nil }
        let index = selectedRequestID.flatMap { selectedID in
            visible.firstIndex(where: { $0.id == selectedID })
        } ?? 0
        return (index: index + 1, count: visible.count)
    }

    /// Whether `current` has a predecessor in `visibleRequests` to step
    /// back to -- false at the oldest (first) visible request, and
    /// whenever nothing is visible at all.
    var canSelectPrevious: Bool {
        guard let positionInfo else { return false }
        return positionInfo.index > 1
    }

    /// Whether `current` has a successor in `visibleRequests` to step
    /// forward to -- false at the newest (last) visible request, and
    /// whenever nothing is visible at all.
    var canSelectNext: Bool {
        guard let positionInfo else { return false }
        return positionInfo.index < positionInfo.count
    }

    /// Mirrors `current`'s own ownership filter: the count of every
    /// pending request this window owns/can see. `ApprovalBannerView`
    /// no longer reads this directly -- the queue navigator now gates
    /// on `positionInfo.count` instead (see that property's own doc
    /// comment), which is derived from the SAME `visibleRequests` this
    /// counts. Kept as its own model-level contract because
    /// CalyxTests/ApprovalInbox/ApprovalBannerModelTests.swift asserts
    /// it directly (`test_pendingCountForWindow_countsOnlyOwnedRequests`).
    var pendingCountForWindow: Int {
        visibleRequests.count
    }

    /// Store-wide pending count, with NO window/ownership visibility
    /// filter at all -- used by the cross-actions menu's "Allow All
    /// Pending (N)" label (see `ApprovalBannerView`), distinct from
    /// `pendingCountForWindow` above, which counts only requests this
    /// window owns/can see.
    var totalPendingCount: Int {
        store.pending.count
    }

    /// Neither this nor `selectPrevious()` below calls
    /// `refreshHostingView()` or posts `.calyxApprovalInboxChanged`: both
    /// are invoked from an in-hierarchy SwiftUI `Button` inside
    /// `ApprovalBannerView`, itself hosted from `MainContentView.body`'s
    /// own `safeAreaInset` closure, which reads `approvalBannerModel.
    /// current` directly (MainContentView.swift's `body`). Mutating
    /// `selectedRequestID` (a tracked, stored `@Observable` property)
    /// therefore invalidates that already-rendered `body` the same way
    /// `RecoveryBarModel.dismiss()` does for `recoveryBarModel.
    /// showRecoveryBar` right alongside it (RecoveryBarModel.swift's
    /// `dismiss()` mutates `isDismissed` with no explicit refresh either)
    /// -- the explicit-refresh doctrine (`ApprovalInboxStore.swift`'s own
    /// `.calyxApprovalInboxChanged` doc comment) exists for mutations
    /// made from OUTSIDE the currently rendered view hierarchy (e.g. a
    /// store change landing from a background MCP call), not for a click
    /// handler already running inside it.
    ///
    /// Steps `current` forward to its successor in `visibleRequests`.
    /// Clamped: a no-op once already at the newest (last) visible
    /// request, or when nothing is visible at all. Navigates from
    /// `current` (not the raw, possibly-inert `selectedRequestID`), so a
    /// stale cursor resolves relative to wherever `current` has already
    /// fallen back to, not from wherever it was last pointing.
    func selectNext() {
        guard canSelectNext, let current, let index = visibleRequests.firstIndex(where: { $0.id == current.id }) else { return }
        selectedRequestID = visibleRequests[index + 1].id
    }

    /// Steps `current` back to its predecessor in `visibleRequests`.
    /// Clamped: a no-op once already at the oldest (first) visible
    /// request, or when nothing is visible at all. Same from-`current`
    /// navigation rationale, and same no-explicit-refresh-needed
    /// rationale (see `selectNext()`'s own doc comment above), as
    /// `selectNext()`.
    func selectPrevious() {
        guard canSelectPrevious, let current, let index = visibleRequests.firstIndex(where: { $0.id == current.id }) else { return }
        selectedRequestID = visibleRequests[index - 1].id
    }

    /// Called immediately before the `store.decide`/`store.decide(ids:)`
    /// that actually resolves `id`, in every action below (`allow`/
    /// `deny`/`alwaysAllow`/`alwaysAllowAcrossPanes`) -- for `allow`/
    /// `deny` that's still their very first line (neither has an
    /// intervening bail-out guard); for `alwaysAllow`'s `.agentHook`
    /// branch and `alwaysAllowAcrossPanes`, this call is placed AFTER
    /// their own early-return guards (a missing `targetSurfaceID`, or a
    /// `.mcpTool`-sourced click for `alwaysAllowAcrossPanes`) -- a path
    /// that bails out without deciding anything must never advance the
    /// cursor either. `store.pending` hasn't been mutated yet at the
    /// point this actually runs, so `visibleRequests` here still
    /// includes `id`, letting this compute its successor/predecessor
    /// within the PRE-removal queue, same as `selectNext()`/
    /// `selectPrevious()` do. A no-op unless `id` is the request this
    /// window is actually DISPLAYING right now (`current?.id`) -- a
    /// stale `id` (already decided by some other path, see `allow(id:)`'s
    /// own stale-id contract below) can never equal `current?.id` in the
    /// first place (a non-pending request is never in `visibleRequests`),
    /// so this guard also doubles as that same stale-id no-op, keeping
    /// the cursor exactly where `current` has already independently
    /// fallen back to.
    ///
    /// `drainedIDs` (default empty, used only by the batch-drain callers
    /// below) closes a gap the plain immediate-neighbor pick left open:
    /// `alwaysAllow`'s drains (the `.mcpTool` branch's all-visible-
    /// `.mcpTool` sweep; the `.agentHook` branch's same-(surface, kind,
    /// toolName) sweep) and `alwaysAllowAcrossPanes`'s same-(kind,
    /// toolName) store-wide sweep can decide MORE than just `id` in the
    /// very same call -- including the immediate successor this method
    /// would otherwise pick as the new cursor. Once that neighbor is
    /// itself swept, `current`'s `selectedRequestID` lookup misses and
    /// falls all the way back to the OLDEST visible request, snapping the
    /// banner backward instead of stepping to the nearest request that
    /// actually survives the drain. Scans forward from `index + 1` for
    /// the first element NOT in `drainedIDs`; if every forward element is
    /// drained, scans backward from `index - 1` for the nearest element
    /// NOT in `drainedIDs`; nil if nothing survives either direction.
    /// With `drainedIDs` empty (`allow(id:)`/`deny(id:)`'s case), every
    /// forward/backward element trivially survives the exclusion check,
    /// so this reduces exactly to the plain immediate-neighbor behavior.
    private func advanceCursor(pastDisplayed id: UUID, excluding drainedIDs: Set<UUID> = []) {
        guard current?.id == id else { return }
        let visible = visibleRequests
        guard let index = visible.firstIndex(where: { $0.id == id }) else { return }
        if let forwardSurvivor = visible[(index + 1)...].first(where: { !drainedIDs.contains($0.id) }) {
            selectedRequestID = forwardSurvivor.id
        } else if let backwardSurvivor = visible[..<index].last(where: { !drainedIDs.contains($0.id) }) {
            selectedRequestID = backwardSurvivor.id
        } else {
            selectedRequestID = nil
        }
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
        advanceCursor(pastDisplayed: id)
        store.decide(id: id, .allowed)
    }

    func deny(id: UUID) {
        advanceCursor(pastDisplayed: id)
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
            var idsToAllow = [id]
            idsToAllow.append(contentsOf: store.pending.filter { candidate in
                guard candidate.id != id, isVisible(candidate) else { return false }
                guard case .mcpTool = candidate.source else { return false }
                return true
            }.map(\.id))
            advanceCursor(pastDisplayed: id, excluding: Set(idsToAllow))
            CockpitSettings.autoApproveEnabled = true
            store.decide(ids: idsToAllow, .allowed)

        case .agentHook(let toolName, let kind, _):
            guard let targetSurfaceID = request.targetSurfaceID else { return }
            let idsToAllow = store.pending
                .filter { $0.targetSurfaceID == targetSurfaceID && matchesAgentHook($0.source, kind: kind, toolName: toolName) }
                .map(\.id)
            advanceCursor(pastDisplayed: id, excluding: Set(idsToAllow))
            memory.rememberPane(surfaceID: targetSurfaceID, kind: kind, toolName: toolName)
            store.decide(ids: idsToAllow, .allowed)
        }
    }

    /// Decides EVERY pending request in the store `.allowed`, store-wide,
    /// with NO window/ownership visibility filter and no source filter
    /// at all. Leaves no Always-Allow memory behind and never touches
    /// any setting -- called by the cross-actions menu's "Allow All
    /// Pending" item (see `ApprovalBannerView`). Clears the navigation
    /// cursor outright (rather than advancing it, unlike `allow(id:)`/
    /// `deny(id:)`/`alwaysAllow(id:)`/`alwaysAllowAcrossPanes(id:)`
    /// above): nothing is left pending store-wide to point at.
    func allowAllPending() {
        selectedRequestID = nil
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

        let idsToAllow = store.pending
            .filter { matchesAgentHook($0.source, kind: kind, toolName: toolName) }
            .map(\.id)
        advanceCursor(pastDisplayed: id, excluding: Set(idsToAllow))
        memory.rememberCross(kind: kind, toolName: toolName)
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
