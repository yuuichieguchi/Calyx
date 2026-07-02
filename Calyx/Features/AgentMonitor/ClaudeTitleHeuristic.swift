// ClaudeTitleHeuristic.swift
// Calyx
//
// Fallback classifier for AI agent state derived from a pane's title, used
// only until the first hooks-sourced event replaces it.

import Foundation

enum ClaudeTitleHeuristic {
    /// The literal spinner glyphs Claude Code cycles through in its
    /// terminal title while generating. Deliberately a small enumerated
    /// set rather than the full Unicode Dingbats block (U+2700–U+27BF):
    /// that block also contains scissors, checkmarks, and other symbols
    /// unrelated to Claude Code's spinner that a user's own shell prompt
    /// or tmux status line could legitimately prefix a title with,
    /// producing phantom "working" rows.
    private static let spinnerGlyphs: Set<Character> = ["✳", "✻", "✽", "✢", "·"]

    /// Classifies a pane title into an `AgentState`, or `nil` if the title
    /// carries no agent signal. Checked in order: a leading spinner glyph
    /// wins over an idle-title match, since a title can carry both while
    /// generating (e.g. "✳ claude — compacting").
    ///
    /// The idle check requires the *entire* (trimmed, case-folded) title
    /// to be exactly "claude" or "claude code" — not a substring match.
    /// A substring match would misclassify any unrelated pane whose title
    /// happens to mention Claude, e.g. a `vim claude_notes.md` tab, as an
    /// idle Claude Code instance.
    static func classify(title: String) -> AgentState? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, spinnerGlyphs.contains(first) {
            return .working
        }
        let normalized = trimmed.lowercased()
        if normalized == "claude" || normalized == "claude code" {
            return .idle
        }
        return nil
    }
}
