// SessionBrowserModel.swift
// Calyx
//
// UI-independent logic layer behind the session browser window:
// fetches the daemon's full session ledger
// (`SessionDaemonClient.listAll()`), flags orphaned running sessions
// (a session with no live ghostty surface attached in this Calyx
// process — `SessionSurfaceMap` has no entry for it), and exposes
// attach/kill actions. Kept separate from
// `SessionBrowserWindowController` (AppKit/SwiftUI chrome) so it's
// directly unit-testable — no window, no real daemon process — the
// same way `SessionBrowserModelTests` exercises it.
//
import Foundation

struct SessionBrowserRow: Identifiable, Equatable, Sendable {
    var id: String { info.id }
    let info: SessionInfo
    /// `true` only for a *running* session with no current
    /// `SessionSurfaceMap` entry — i.e. the daemon still has its child
    /// process alive, but no ghostty surface in this Calyx process is
    /// attached to it (orphaned by a crash, a `kill -9`'d Calyx
    /// process, or a session started by a different Calyx launch).
    /// Always `false` for an exited session — there is nothing to
    /// reconnect to.
    let isOrphan: Bool
    /// `true` when `SessionSurfaceMap` currently has a surface for
    /// this session in this Calyx process — i.e. it's already visibly
    /// attached somewhere, so "Attach" in the browser should reveal
    /// that pane rather than open a second attach connection.
    let isAttachedHere: Bool
}

@MainActor
@Observable
final class SessionBrowserModel {

    private(set) var rows: [SessionBrowserRow] = []

    private let daemonClient: SessionDaemonClientProtocol
    private let surfaceMap: SessionSurfaceMap

    /// Invoked by `attach(_:)` with the row to attach to. Actual
    /// surface/window creation is a `SessionBrowserWindowController` /
    /// `CalyxWindowController` concern, deliberately kept out of this
    /// pure logic layer — tests inject a closure and assert it was
    /// called with the right row instead of driving real AppKit.
    var onAttachRequested: ((SessionBrowserRow) -> Void)?

    init(
        daemonClient: SessionDaemonClientProtocol = SessionDaemonClient.shared,
        surfaceMap: SessionSurfaceMap = .shared
    ) {
        self.daemonClient = daemonClient
        self.surfaceMap = surfaceMap
    }

    /// Refreshes `rows` from `daemonClient.listAll()`.
    ///
    /// R10-C item 2 (r10-fix-spec.md): routed through `listAllBounded()`
    /// rather than `listAll()` directly, since a hung daemon used to
    /// freeze the whole session browser forever. Shares the same 5s
    /// bound `AppDelegate`'s agent-resume path already applied to itself
    /// (see `SessionDaemonClientProtocol.listAllBounded()`'s own doc
    /// comment).
    func refresh() async {
        let sessions = await daemonClient.listAllBounded()
        rows = sessions.map { info in
            let isAttached = surfaceMap.surfaceID(for: info.id) != nil
            return SessionBrowserRow(
                info: info,
                isOrphan: info.state == .running && !isAttached,
                isAttachedHere: isAttached
            )
        }
    }

    /// Requests attaching to `row`'s session.
    func attach(_ row: SessionBrowserRow) {
        onAttachRequested?(row)
    }

    /// Kills `row`'s session via the daemon, then refreshes.
    func kill(_ row: SessionBrowserRow) async {
        await daemonClient.kill(id: row.info.id)
        await refresh()
    }
}
