//
//  ClaudeTitleHeuristicTests.swift
//  CalyxTests
//
//  TDD Red Phase for ClaudeTitleHeuristic.classify(title:): the fallback
//  pane-title → AgentState classifier used before any hook event arrives.
//
//  Coverage:
//  - Spinner-character-prefixed titles → .working
//  - A title that (trimmed, case-insensitively) equals exactly "claude" or
//    "claude code" → .idle
//  - A title merely *containing* "claude" as a substring → nil, not .idle
//    (contract updated post-review: a bare substring match misclassified
//    unrelated panes, e.g. a `vim claude_notes.md` tab, as an idle Claude
//    Code instance)
//  - Unrelated titles → nil (non-applicable)
//

import XCTest
@testable import Calyx

final class ClaudeTitleHeuristicTests: XCTestCase {

    // MARK: - Spinner prefix → working

    func test_classify_spinnerPrefixedTitle_isWorking() {
        let spinnerTitles = [
            "✳ Compacting conversation",
            "✻ Thinking",
            "✽ Editing file.swift",
            "✢ Running tests",
        ]

        for title in spinnerTitles {
            XCTAssertEqual(ClaudeTitleHeuristic.classify(title: title), .working,
                           "Spinner-prefixed title '\(title)' must classify as .working")
        }
    }

    // MARK: - Exact "claude" / "claude code" title → idle

    func test_classify_titleExactlyClaude_isIdle() {
        XCTAssertEqual(ClaudeTitleHeuristic.classify(title: "claude"), .idle)
        XCTAssertEqual(ClaudeTitleHeuristic.classify(title: "Claude Code"), .idle,
                       "Match must be case-insensitive")
        XCTAssertEqual(ClaudeTitleHeuristic.classify(title: "CLAUDE"), .idle,
                       "Match must be case-insensitive")
        XCTAssertEqual(ClaudeTitleHeuristic.classify(title: "  claude  "), .idle,
                       "Match must tolerate surrounding whitespace")
    }

    // MARK: - "claude" substring (not exact) → non-applicable

    func test_classify_titleContainingClaudeAsSubstring_isNil() {
        // Contract updated post-review: a bare substring match previously
        // classified this as .idle, misreporting an unrelated pane (a vim
        // session on a file that happens to mention Claude) as an idle
        // Claude Code instance in the sidebar.
        XCTAssertNil(ClaudeTitleHeuristic.classify(title: "vim claude_notes.md"))
    }

    // MARK: - Unrelated title → non-applicable

    func test_classify_unrelatedTitle_isNil() {
        // Sanity: a title that should classify must not come back nil,
        // proving the negative assertions below aren't just trivially true
        // against a permanently-nil stub.
        XCTAssertEqual(ClaudeTitleHeuristic.classify(title: "claude"), .idle,
                       "Precondition: a recognizable title must classify")

        XCTAssertNil(ClaudeTitleHeuristic.classify(title: "zsh"))
        XCTAssertNil(ClaudeTitleHeuristic.classify(title: "~/projects/Calyx"))
    }
}
