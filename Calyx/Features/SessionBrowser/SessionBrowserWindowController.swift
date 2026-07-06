// SessionBrowserWindowController.swift
// Calyx
//
// Independent window (same shape as `SettingsWindowController`) that
// shows the session browser — every calyx-session the daemon knows
// about, across all Calyx windows and launches, not just this
// process's currently-live panes. No dedicated test file: the logic
// worth testing lives in `SessionBrowserModel`, not this AppKit shell.

import AppKit
import SwiftUI

@MainActor
final class SessionBrowserWindowController: NSWindowController {

    static let shared = SessionBrowserWindowController()

    let model = SessionBrowserModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sessions"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentView = NSHostingView(rootView: SessionBrowserView(model: model))

        // "Attach" on a row already visible somewhere in this process
        // (`isAttachedHere`) reveals that pane via the same
        // `.calyxFocusSurface` notification every window controller
        // already observes (`AgentStatusView`'s identical pattern) — a
        // second attach connection to an already-live session makes no
        // sense. Otherwise (an orphaned, running session with no local
        // surface) opens a brand-new window that reattaches to it.
        model.onAttachRequested = { [weak self] row in
            self?.attach(row)
        }

        // P5 (remote sessions): mirrors the onAttachRequested wiring
        // immediately above -- reaches a window controller the same
        // way attach(_:) does (via AppDelegate), for a chosen remote
        // host's SessionSpawnContext instead of an existing session
        // row.
        model.onRemoteSessionRequested = { [weak self] context in
            self?.attachRemote(context)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func attach(_ row: SessionBrowserRow) {
        if row.isAttachedHere, let surfaceID = SessionSurfaceMap.shared.surfaceID(for: row.id) {
            NotificationCenter.default.post(
                name: .calyxFocusSurface, object: nil, userInfo: ["surfaceID": surfaceID]
            )
            return
        }
        (NSApp.delegate as? AppDelegate)?.attachSessionAsTab(sessionID: row.id, cwd: row.info.cwd)
    }

    private func attachRemote(_ context: SessionSpawnContext) {
        (NSApp.delegate as? AppDelegate)?.spawnRemoteSessionTab(host: context.host)
    }

    func showBrowser() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        model.refreshRemoteHostCandidates()
        Task { await model.refresh() }
    }
}
