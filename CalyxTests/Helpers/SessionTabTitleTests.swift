// SessionTabTitleTests.swift
// CalyxTests
//
// TDD Red phase for a user-reported defect: attaching a Detached session
// from the session browser (AppDelegate.attachSessionAsNewTab, the
// tab-based Attach path, and attachWindow's new-window path) creates a
// placeholder Tab titled "Terminal" that stays that way until the
// reattached shell's next prompt emits an OSC title -- unlike a
// restore-at-launch tab, which carries its title forward from
// TabSnapshot. The session's cwd is already known at attach time
// (SessionBrowserRow.info.cwd), so the placeholder's initial title
// should be derived from it instead of left generic.
//
// SessionTabTitle is a NEW pure helper (does not exist anywhere in the
// codebase yet) proposed as the single place both attach call sites
// (AppDelegate.attachWindow and .attachSessionAsNewTab) derive a
// placeholder title from a cwd -- a held-out compile-RED file per this
// codebase's established convention (see SettingsPaneTests's header):
// the whole CalyxTests target fails to build until the Green phase adds
// SessionTabTitle. That compile failure IS this file's RED evidence.
// (AppDelegateAttachPlaceholderTitleTests.swift covers the two call
// sites' actual wiring separately, without needing this type to exist,
// so that file's RED evidence is a genuine assertion failure instead.)
//
// ABBREVIATION STYLE: mirrors zsh's `%~` prompt abbreviation (also
// NSString.abbreviatingWithTildeInPath's behavior) -- the home directory
// is replaced with "~" only when it is a real path-component prefix of
// cwd, never a naive string prefix. "/Users/eguchiyuuichi2/projects"
// must NOT abbreviate against home "/Users/eguchiyuuichi" just because
// the string "/Users/eguchiyuuichi" is a textual prefix of it; the two
// are unrelated directories that merely share a spelling prefix.
//
// Coverage:
// - cwd exactly equal to home -> "~"
// - cwd nested under home -> "~/<relative path>"
// - cwd outside home entirely -> stays absolute, unchanged
// - cwd that shares a naive string prefix with home but is NOT actually
//   inside it (path-component boundary safety) -> stays absolute
// - nil cwd -> "Terminal" fallback
// - empty-string cwd -> "Terminal" fallback (explicit in the fix
//   contract: "nil/empty" both fall back)

import Testing
@testable import Calyx

@Suite("SessionTabTitle.fromCwd - home-relative tilde abbreviation")
struct SessionTabTitleFromCwdTests {

    private let home = "/Users/eguchiyuuichi"

    @Test("cwd exactly equal to home abbreviates to a bare tilde")
    func exactHomeAbbreviatesToTilde() {
        let result = SessionTabTitle.fromCwd(home, home: home)
        #expect(result == "~", "cwd == home must abbreviate to \"~\" but got \(result)")
    }

    @Test("cwd nested under home abbreviates to tilde + relative path")
    func nestedPathAbbreviatesRelativeToHome() {
        let result = SessionTabTitle.fromCwd("\(home)/projects/Calyx", home: home)
        #expect(
            result == "~/projects/Calyx",
            "A path nested under home must abbreviate to \"~/projects/Calyx\" but got \(result)"
        )
    }

    @Test("cwd entirely outside home stays an absolute path")
    func nonHomePathStaysAbsolute() {
        let result = SessionTabTitle.fromCwd("/var/root/somewhere", home: home)
        #expect(
            result == "/var/root/somewhere",
            "A path unrelated to home must not be abbreviated but got \(result)"
        )
    }

    @Test("cwd sharing home's string prefix but not its path component stays absolute")
    func siblingDirectorySharingTextualPrefixStaysAbsolute() {
        // "/Users/eguchiyuuichi2" is a SIBLING directory, not a
        // subdirectory of "/Users/eguchiyuuichi" -- a naive
        // hasPrefix(home) check would wrongly abbreviate this to
        // "~2/projects".
        let siblingCwd = "\(home)2/projects"
        let result = SessionTabTitle.fromCwd(siblingCwd, home: home)
        #expect(
            result == siblingCwd,
            "A sibling directory that merely shares home's string prefix must stay absolute, not be wrongly abbreviated, but got \(result)"
        )
    }

    @Test("nil cwd falls back to the \"Terminal\" placeholder title")
    func nilCwdFallsBackToTerminal() {
        let result = SessionTabTitle.fromCwd(nil, home: home)
        #expect(result == "Terminal", "A nil cwd must fall back to \"Terminal\" but got \(result)")
    }

    @Test("empty-string cwd falls back to the \"Terminal\" placeholder title")
    func emptyCwdFallsBackToTerminal() {
        let result = SessionTabTitle.fromCwd("", home: home)
        #expect(result == "Terminal", "An empty cwd must fall back to \"Terminal\" but got \(result)")
    }
}
