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
}
