// SurfacePropertyStore.swift
// Calyx
//
// App-wide per-surface title/cwd tracker, fed by the same
// .ghosttySetTitle/.ghosttySetPwd notifications CalyxWindowController
// already observes for its own per-tab title/pwd tracking
// (GhosttyAction.swift's handleSetTitle/handlePwd), but keyed per-SURFACE
// rather than per-tab-focused-pane -- Cockpit's pane_list needs every
// pane's own title/cwd, not just the tab's currently-focused one. Pruned
// via .calyxSurfaceDestroyed (SurfaceRegistry.destroySurface's own
// notification). init() must never construct another singleton in a
// stored property -- a prior circular-init crash makes that a hard rule
// for this codebase.
//
// Surface-id resolution: unlike CalyxWindowController's own handlers
// (which resolve via `surfaceView.surfaceController?.id`, valid only for
// a view already wired to a live ghostty surface), this store has no
// per-window SurfaceRegistry of its own to fall back on, so it resolves
// through SurfaceLocator.shared.id(forView:) -- the same global
// surfaceID<->view directory SurfaceRegistry.createSurface (and its
// _testInsert test seam) populate. An unresolvable view (never
// registered anywhere) is silently ignored: see
// CalyxTests/Cockpit/SurfacePropertyStoreTests.swift for the specced
// contract.
//
// Subclasses NSObject solely so NotificationCenter's @objc
// selector-based addObserver can target it, matching every other
// notification observer in this codebase (e.g.
// CalyxWindowController's own handleSetTitleNotification).

import Foundation

@MainActor
final class SurfacePropertyStore: NSObject {

    static let shared = SurfacePropertyStore()

    private struct Entry {
        var title: String?
        var cwd: String?
    }

    private var entries: [UUID: Entry] = [:]
    private var isObserving = false

    override init() {
        super.init()
    }

    func title(for id: UUID) -> String? {
        entries[id]?.title
    }

    func cwd(for id: UUID) -> String? {
        entries[id]?.cwd
    }

    /// Idempotent: a second call is a no-op, so
    /// AppDelegate.applicationDidFinishLaunching can call this
    /// unconditionally without worrying about double-registering
    /// observers on repeated launches within the same process.
    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSetTitle(_:)), name: .ghosttySetTitle, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSetPwd(_:)), name: .ghosttySetPwd, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSurfaceDestroyed(_:)), name: .calyxSurfaceDestroyed, object: nil
        )
    }

    @objc private func handleSetTitle(_ notification: Notification) {
        guard let view = notification.object as? SurfaceView,
              let id = SurfaceLocator.shared.id(forView: view),
              let title = notification.userInfo?["title"] as? String else { return }
        entries[id, default: Entry()].title = title
    }

    @objc private func handleSetPwd(_ notification: Notification) {
        guard let view = notification.object as? SurfaceView,
              let id = SurfaceLocator.shared.id(forView: view),
              let pwd = notification.userInfo?["pwd"] as? String else { return }
        entries[id, default: Entry()].cwd = pwd
    }

    @objc private func handleSurfaceDestroyed(_ notification: Notification) {
        guard let id = notification.userInfo?["surfaceID"] as? UUID else { return }
        entries.removeValue(forKey: id)
    }

    #if DEBUG
    func _testReset() {
        entries.removeAll()
    }

    /// Test-only: undoes `startObserving()`, so a test's own
    /// `SurfacePropertyStore()` instance doesn't keep receiving
    /// `.ghosttySetTitle`/`.ghosttySetPwd`/`.calyxSurfaceDestroyed` for
    /// the rest of the test process after that test ends. Real
    /// `SurfacePropertyStore.shared` never calls this (app-lifetime
    /// singleton). DO NOT use from production code.
    func _stopObserving() {
        guard isObserving else { return }
        NotificationCenter.default.removeObserver(self)
        isObserving = false
    }
    #endif
}
