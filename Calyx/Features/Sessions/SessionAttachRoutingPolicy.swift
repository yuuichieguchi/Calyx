// SessionAttachRoutingPolicy.swift
// Calyx
//
// Single decision the session browser's "Attach" action must follow, in
// one place, instead of two independently-reasoned flows silently
// diverging: an already-visible session is focused, not attached a
// second time; a not-yet-visible session joins the already-available
// main window as a new tab; a fresh window is the last resort, only when
// no main window exists at all. Extracted as a pure, three-way decision
// (mirrors SessionCloseKillPolicy's identical "single pure predicate
// instead of each call site separately reasoning about it" precedent)
// after a review found the session browser's own "Attach" button always
// opened a second window regardless of whether a main window was already
// available -- an inconsistency with the sibling remote-session flow
// (AppDelegate.spawnRemoteSessionTab), which already added a new tab to
// an available window instead of a second one for a brand-new remote
// session.

enum SessionAttachRoutingPolicy {
    enum Decision: Equatable {
        /// The session already has a live surface somewhere in this
        /// process -- reveal it instead of attaching a second time.
        case focusExistingSurface
        /// No live surface for this session anywhere in this process,
        /// and a main window is available: the session becomes a new
        /// tab in it.
        case attachAsTab
        /// No live surface, and no main window at all: a fresh window
        /// is the only option.
        case attachAsNewWindow
    }

    /// The three-way decision: an already-attached session always wins
    /// (focus, regardless of window availability); otherwise a window to
    /// add a tab to is preferred over opening a fresh one; a fresh window
    /// is the last resort, only when neither of the above applies. See
    /// `SessionAttachRoutingPolicyTests`'s truth table for every
    /// combination.
    static func decide(isAttachedHere: Bool, hasAvailableWindow: Bool) -> Decision {
        if isAttachedHere {
            return .focusExistingSurface
        }
        return hasAvailableWindow ? .attachAsTab : .attachAsNewWindow
    }
}
