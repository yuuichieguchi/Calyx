// ApprovalBannerModel.swift
// Calyx
//
// Per-window view-model behind the Cockpit approval banner, choosing
// which single pending ApprovalRequest (if any) this window should show
// and forwarding Allow/Deny/Always Allow to
// ApprovalInboxStore.decide(id:_:) / CockpitSettings.autoApproveEnabled.
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

    init(store: ApprovalInboxStore, ownsSurface: @escaping (UUID) -> Bool, isKeyWindow: @escaping () -> Bool) {
        self.store = store
        self.ownsSurface = ownsSurface
        self.isKeyWindow = isKeyWindow
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

    /// `id` is the request the CALLER actually rendered (threaded in by
    /// `ApprovalBannerView` from its own `request.id`), not re-derived
    /// from `current` -- `current` can advance between a render and a
    /// click (another decide()/expire() landing first), so re-reading it
    /// here could resolve a DIFFERENT request than the one the human
    /// looked at and clicked Allow/Deny on. A no-op if `id` is no longer
    /// pending (`store.decide` itself already no-ops safely for that
    /// case too, but the explicit guard here also protects
    /// `alwaysAllow(id:)`'s side effects below from firing on a stale
    /// click).
    func allow(id: UUID) {
        guard store.pending.contains(where: { $0.id == id }) else { return }
        store.decide(id: id, .allowed)
    }

    func deny(id: UUID) {
        guard store.pending.contains(where: { $0.id == id }) else { return }
        store.decide(id: id, .denied)
    }

    /// Turns on auto-approve for every FUTURE gated action, resolves the
    /// clicked `id` allowed first (the request the human actually looked
    /// at), then drains every OTHER request already queued and visible
    /// to THIS window -- otherwise the user would have to separately
    /// dismiss each banner already on screen right after turning
    /// auto-approve on. Deliberately scoped to this window: a pending
    /// request owned by a DIFFERENT window is left alone here (auto-approve
    /// only gates that request's future re-submits; that other window
    /// drains its own backlog the same way on its own next interaction).
    /// A no-op, including no setting change, if `id` is no longer
    /// pending -- a stale click must never silently turn auto-approve on.
    ///
    /// The whole drain goes through `ApprovalInboxStore.decide(ids:_:)`
    /// (the batched form) rather than one `decide(id:_:)` call per
    /// request, so this posts exactly ONE `.calyxApprovalInboxChanged`
    /// change notification -- and therefore triggers exactly one
    /// `refreshHostingView()` per open window -- no matter how many
    /// requests the backlog contains, instead of one full main-content
    /// rebuild per drained request.
    func alwaysAllow(id: UUID) {
        guard store.pending.contains(where: { $0.id == id }) else { return }
        CockpitSettings.autoApproveEnabled = true

        var idsToAllow = [id]
        idsToAllow.append(contentsOf: store.pending.filter { $0.id != id && isVisible($0) }.map(\.id))
        store.decide(ids: idsToAllow, .allowed)
    }
}
