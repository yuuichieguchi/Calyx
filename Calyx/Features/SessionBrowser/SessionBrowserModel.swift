// SessionBrowserModel.swift
// Calyx
//
// UI-independent logic layer behind the session browser window:
// fetches the daemon's full session ledger
// (`SessionDaemonClient.listAll()`), keeps only its Running sessions
// (an Exited entry has no affordances here -- nothing to attach to,
// nothing to reconnect -- and the daemon ledger's own GC handles its
// eventual removal, so the browser is a view of attachable/killable
// sessions, not the raw ledger), flags orphaned running sessions
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
    /// `true` for a running session with no current `SessionSurfaceMap`
    /// entry -- i.e. the daemon still has its child process alive, but
    /// no ghostty surface in this Calyx process is attached to it
    /// (orphaned by a crash, a `kill -9`'d Calyx process, or a session
    /// started by a different Calyx launch). Every `SessionBrowserRow`
    /// wraps a running session (`SessionBrowserModel.refresh()` never
    /// produces a row for an exited one), so this is the only case
    /// `isOrphan` distinguishes.
    let isOrphan: Bool
    /// `true` when `SessionSurfaceMap` currently has a surface for
    /// this session in this Calyx process — i.e. it's already visibly
    /// attached somewhere, so "Attach" in the browser should reveal
    /// that pane rather than open a second attach connection.
    let isAttachedHere: Bool

    /// User-visible label for the `isOrphan` badge (`SessionBrowserRowView`).
    /// Kept separate from the SwiftUI view so this string is testable
    /// without a snapshot/view-inspection dependency. Internal name
    /// (`isOrphan`) is unchanged this cycle -- only the user-visible
    /// wording moves from "Orphaned" to "Detached".
    static let orphanBadgeLabel = "Detached"
}

@MainActor
@Observable
final class SessionBrowserModel {

    private(set) var rows: [SessionBrowserRow] = []

    private let daemonClient: SessionDaemonClientProtocol
    private let surfaceMap: SessionSurfaceMap
    private let hostCandidateProvider: SSHHostCandidateProvider

    /// Remote host candidates for the "New Remote Session…" picker,
    /// populated by `refreshRemoteHostCandidates()` from the injected
    /// `hostCandidateProvider`, in its own declaration order.
    private(set) var remoteHostCandidates: [String] = []

    /// Invoked by `attachToRemoteHost(_:)` with the `SessionSpawnContext`
    /// a chosen remote host must turn into -- structurally identical to
    /// what `CalyxWindowController.remoteSessionSpawnContext(forHost:)`
    /// produces for the same host, so both entry points feed the same
    /// downstream spawn contract. Actual surface/window creation is a
    /// `CalyxWindowController` concern, kept out of this pure logic
    /// layer -- mirrors `onAttachRequested`'s injectable-closure
    /// pattern.
    var onRemoteSessionRequested: ((SessionSpawnContext) -> Void)?

    /// R12-A item 3 (r12-fix-spec.md): guards against `refresh()`'s 1s
    /// poll timer stacking an unbounded number of concurrent
    /// `listAllBounded()` round-trips behind a slow/hung daemon. A
    /// second `refresh()` issued while one is still in flight is a
    /// no-op instead of starting its own overlapping daemon call; the
    /// poll naturally backs off to the bound's own cadence instead.
    private var isRefreshing = false

    /// Invoked by `attach(_:)` with the row to attach to. Actual
    /// surface/window creation is a `SessionBrowserWindowController` /
    /// `CalyxWindowController` concern, deliberately kept out of this
    /// pure logic layer — tests inject a closure and assert it was
    /// called with the right row instead of driving real AppKit.
    var onAttachRequested: ((SessionBrowserRow) -> Void)?

    init(
        daemonClient: SessionDaemonClientProtocol = SessionDaemonClient.shared,
        surfaceMap: SessionSurfaceMap = .shared,
        hostCandidateProvider: SSHHostCandidateProvider = SSHHostCandidateProvider()
    ) {
        self.daemonClient = daemonClient
        self.surfaceMap = surfaceMap
        self.hostCandidateProvider = hostCandidateProvider
    }

    /// Refreshes `rows` from `daemonClient.listAll()`, for Running
    /// sessions only.
    ///
    /// The daemon ledger never removes `Exited` entries on its own (its
    /// retention GC runs on its own schedule); a `listAll()` result
    /// mixing Running and Exited sessions is the ledger's normal shape,
    /// not an edge case. An Exited session has zero affordances here --
    /// nothing to attach to, nothing to reconnect -- so keeping a row
    /// for one would accumulate as a permanent dead row in the browser
    /// (observed in production: 7 stale `Exited(137)` rows) rather than
    /// disappearing once the ledger eventually GCs it. Filtering here
    /// keeps the browser a view of sessions you can actually attach to
    /// or kill.
    ///
    /// R10-C item 2 (r10-fix-spec.md): routed through `listAllBounded()`
    /// rather than `listAll()` directly, since a hung daemon used to
    /// freeze the whole session browser forever. Shares the same 5s
    /// bound `AppDelegate`'s agent-resume path already applied to itself
    /// (see `SessionDaemonClientProtocol.listAllBounded()`'s own doc
    /// comment).
    ///
    /// R14-A sweep addendum item 1 (r14-fix-spec.md): guards on
    /// `Task.isCancelled` before assigning `rows`, mirroring
    /// `AppDelegate.listAllSessionsBounded`'s identical R12-A item 4
    /// guard. Without this, a closed-window poll cancellation (once
    /// R14-A propagates it into `listAllBounded()`'s own race) could
    /// still resolve early with a result that arrives after the
    /// caller gave up, wiping this SHARED model's rows with a stale
    /// value -- an empty flash on reopen.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let sessions = await daemonClient.listAllBounded()
        guard !Task.isCancelled else { return }
        rows = sessions.filter { $0.state == .running }.map { info in
            let isAttached = surfaceMap.surfaceID(for: info.id) != nil
            return SessionBrowserRow(
                info: info,
                isOrphan: !isAttached,
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

    /// Populates `remoteHostCandidates` from the injected
    /// `hostCandidateProvider`.
    func refreshRemoteHostCandidates() {
        remoteHostCandidates = hostCandidateProvider.hostCandidates()
    }

    /// Requests spawning a new remote session against `host`.
    func attachToRemoteHost(_ host: String) {
        onRemoteSessionRequested?(SessionSpawnContext(host: host, origin: .tab))
    }

    /// Deploys the daemon to `host` via the injected `daemonClient`'s
    /// own `installRemote(host:)`, returning its result -- mirrors
    /// `kill(_:)`'s existing injectable-client pattern.
    func installRemote(host: String) async -> CommandResult? {
        await daemonClient.installRemote(host: host)
    }
}
