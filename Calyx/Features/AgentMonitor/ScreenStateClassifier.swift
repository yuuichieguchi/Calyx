// ScreenStateClassifier.swift
// Calyx
//
// Herdr-style "layer 2" classifier: reads a pane's bottom-of-screen text
// (the last N terminal rows) and conservatively recognizes known Claude
// Code / Codex / OpenCode UI patterns — a permission/approval prompt
// (`.blocked`) or an in-progress marker (`.working`). Used as a fallback
// when hooks aren't wired up (or for panes hooks haven't reported on
// yet), polled by CalyxWindowController and fed into
// `AgentRegistry.handleScreenClassification`.

import Foundation

enum ScreenStateClassifier {

    /// The choice-cursor marker Claude Code's approval/permission prompt
    /// renders in front of its default-selected numbered option (e.g.
    /// "❯ 1. Yes"). Round 3's original blocked-pattern set also matched
    /// generic phrases like "do you want" / "would you like" / "esc to
    /// cancel" on their own, which false-positived on unrelated shell
    /// tools that ask their own yes/no questions — apt's
    /// "Do you want to continue? [Y/n]", fzf's "ESC to cancel" footer —
    /// neither of which renders this cursor+numbered-option shape.
    /// Requiring it is Claude-Code-specific and conservative: no
    /// confirmed Codex/OpenCode-equivalent marker exists yet (Round 3
    /// plan's "実機文言の確認" follow-up), so every `kind`, including an
    /// unrecognized one, is classified against this same minimal pattern
    /// for now rather than a per-`kind` guess.
    private static let choiceMarkerPattern = #"❯\s*\d+\."#

    /// Case-insensitive substrings recognized as an in-progress marker.
    /// Claude-specific: Codex/OpenCode render no equivalent status line
    /// Calyx can key off yet, so this isn't a `common`-vs-per-`kind` set
    /// the way `BlockedPatterns` used to be — just the one confirmed
    /// marker.
    private static let workingMarker = "esc to interrupt"

    /// Classifies `bottomText` (the pane's bottom-of-screen viewport
    /// text) for the given agent `kind` ("claude-code" / "codex" /
    /// "opencode"). Returns `.blocked` when the choice-marker pattern is
    /// recognized, `.working` when the in-progress marker is
    /// recognized, or `nil` when neither is found — callers treat `nil`
    /// as "fall back to idle" rather than "no signal at all", per the
    /// Round 3 plan's conservative-by-design rule (a false
    /// `.blocked`/`.working` is worse than a missed one). `.blocked`
    /// takes priority when both kinds of pattern are present (e.g. an
    /// approval prompt that interrupted a still-visible in-progress
    /// status line) — the user needs to answer it before anything
    /// resumes. `kind` is currently unused (every kind shares the same
    /// conservative pattern set — see `choiceMarkerPattern`'s doc
    /// comment) but is kept in the signature for CLI-specific patterns
    /// once confirmed.
    static func classify(bottomText: String, kind: String) -> AgentState? {
        if bottomText.range(of: choiceMarkerPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return .blocked
        }
        if bottomText.range(of: workingMarker, options: .caseInsensitive) != nil {
            return .working
        }
        return nil
    }
}
