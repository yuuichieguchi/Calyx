// SessionTabTitle.swift
// Calyx
//
// Derives a session-attach placeholder Tab's initial title from its cwd,
// so a reattached session's tab shows a meaningful title immediately
// instead of the generic "Terminal" default until the shell's next
// prompt emits an OSC title. Shared by AppDelegate.attachWindow and
// .attachSessionAsNewTab (both attach call sites).
//
// Abbreviation mirrors zsh's `%~` prompt style (and
// NSString.abbreviatingWithTildeInPath): home is only substituted with
// "~" when it is a real path-component prefix of cwd, never a naive
// string prefix, so a sibling directory that merely shares home's
// spelling (e.g. "/Users/eguchiyuuichi2") is never mistaken for a
// subdirectory of home ("/Users/eguchiyuuichi").

import Foundation

enum SessionTabTitle {
    static func fromCwd(_ cwd: String?, home: String) -> String {
        guard let cwd, !cwd.isEmpty else { return "Terminal" }
        if cwd == home { return "~" }
        if cwd.hasPrefix(home + "/") {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }
}
