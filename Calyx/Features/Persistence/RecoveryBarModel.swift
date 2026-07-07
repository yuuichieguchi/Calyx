// RecoveryBarModel.swift
// Calyx
//
// UI-independent view-model behind the Chrome-style in-app
// "your previous session was preserved" recovery bar (see
// RecoveryBarModelTests.swift for the full design-decision writeup).
// One instance per CalyxWindowController, fed by (not fetching)
// AppDelegate.hasPreservedSessionSnapshot -- this model has zero
// dependency on AppDelegate/SessionPersistenceActor/GhosttyAppController,
// mirroring SessionBrowserModel's own "UI-independent logic layer"
// precedent.
//
// Lives here (Persistence), not Features/Sessions: this is a
// persistence-recovery concern (the preserved snapshot file), not a
// Sessions/calyx-session-daemon one.

import Foundation

@MainActor
@Observable
final class RecoveryBarModel {
    private(set) var hasPreservedSessionSnapshot: Bool
    private(set) var isDismissed: Bool = false
    var onRestore: (() -> Void)?

    init(hasPreservedSessionSnapshot: Bool = false, onRestore: (() -> Void)? = nil) {
        self.hasPreservedSessionSnapshot = hasPreservedSessionSnapshot
        self.onRestore = onRestore
    }

    var showRecoveryBar: Bool {
        hasPreservedSessionSnapshot && !isDismissed
    }

    /// Pushed by AppDelegate after `initializeHasPreservedSessionSnapshotFlag()`'s
    /// async Task resolves, and after a recovery attempt changes the
    /// flag -- fixes the launch-time race where this window's own
    /// construction ran before the real value was known (see this
    /// type's own file header).
    func updateHasPreservedSessionSnapshot(_ value: Bool) {
        hasPreservedSessionSnapshot = value
    }

    /// Hides the bar for this window only, for the rest of this app run.
    /// Deliberately does NOT clear `hasPreservedSessionSnapshot` -- the
    /// command palette's "Recover Previous Session" must remain
    /// available as the non-time-critical fallback.
    func dismiss() {
        isDismissed = true
    }

    /// Invokes the injected recovery closure. Has no opinion on whether
    /// the closure's real work succeeds -- clearing
    /// `hasPreservedSessionSnapshot` is exclusively
    /// `updateHasPreservedSessionSnapshot(_:)`'s job, driven by the
    /// caller once the real async recovery actually finishes.
    func restore() {
        onRestore?()
    }
}
