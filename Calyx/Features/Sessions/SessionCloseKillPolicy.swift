// SessionCloseKillPolicy.swift
// Calyx
//
// Decides whether tearing down a persistent-session surface should also
// kill the underlying calyx-session. Extracted as an explicit, pure
// decision after a review found the kill call was reachable from two
// unsafe reentrant paths:
//
//   - `SurfaceRegistry.destroySurface(_:)` synchronously re-enters
//     ghostty's `close_surface` callback (`handleCloseSurfaceNotification`
//     -> `closeSurfaceAndCleanUp`), which used to call
//     `killSessionIfPersistent` unconditionally, before checking
//     `closingTabIDs` — so:
//       (a) `performReconnect` (which destroys the OLD surface to make
//           room for the reconnected one) killed the very session it
//           was reconnecting to, and
//       (b) `windowWillClose` (quit / last-window-close teardown, which
//           destroys every surface in the window) killed every
//           persistent session, even though it pre-populates
//           `closingTabIDs` specifically to try to prevent exactly this.
//
// The fix direction is to gate the kill decision on explicit state (is
// this teardown part of app termination? part of a reconnect surface
// swap?) through this single pure function, rather than each call site
// separately reasoning about reentrancy.

enum SessionCloseKillPolicy {

    /// - `hasSession == false`: nothing to kill (an ordinary pane, or
    ///   a surface already unregistered from `SessionSurfaceMap`).
    /// - `isTerminating == true`: quit / last-window-close teardown —
    ///   detach, don't kill, so the session survives to be reattached
    ///   on next launch.
    /// - `isReconnectSwap == true`: the destroy is `performReconnect`
    ///   replacing the surface, not a real close — killing here would
    ///   self-destruct the very session being reconnected to.
    /// - Otherwise (a genuine explicit close: `closeTab`,
    ///   `closeActiveGroup`, `closeAllTabsInGroup`, or a
    ///   ghostty-driven `close_surface` for a pane the user didn't
    ///   ask to keep alive): kill.
    static func shouldKill(hasSession: Bool, isTerminating: Bool, isReconnectSwap: Bool) -> Bool {
        hasSession && !isTerminating && !isReconnectSwap
    }

    /// F9 (V10, WARNING, r4-fix-spec.md): the detach-instead-of-kill
    /// paths' (`session.detach`, `.giveUp`) counterpart to `shouldKill`
    /// above, using the same gate, since detach and kill are mutually
    /// exclusive alternatives for tearing down a persistent-session
    /// surface (see each call site for which one runs): nothing to
    /// detach with no session; quit/last-window-close teardown must
    /// leave `tab.sessionRefs` untouched so the snapshot save sees it;
    /// and a reconnect surface swap must never touch the session it's
    /// reconnecting to. Detach's own call site
    /// (`detachSessionIfPersistent`) previously checked only
    /// `!isTerminating` inline, never consulting `reconnectingSurfaceIDs`
    /// the way `killSessionIfPersistent` does. That is currently inert
    /// (no reachable path calls detach mid-reconnect-swap; see
    /// r4-verdicts.md V10), but structurally required so detach isn't
    /// relying on incidental caller ordering the way kill used to before
    /// this policy existed.
    static func shouldDetach(hasSession: Bool, isTerminating: Bool, isReconnectSwap: Bool) -> Bool {
        hasSession && !isTerminating && !isReconnectSwap
    }
}
