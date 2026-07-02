//
//  ScreenStateClassifierTests.swift
//  CalyxTests
//
//  TDD Red Phase for ScreenStateClassifier: Herdr-style "layer 2"
//  classification of a pane's bottom-of-screen text into .blocked /
//  .working / nil.
//
//  Coverage:
//  - An approval/permission-prompt-shaped multi-line block -> .blocked
//  - An in-progress marker ("esc to interrupt") -> .working
//  - Both patterns present at once -> .blocked takes priority
//  - A plain shell prompt / empty string -> nil (paired with a sanity
//    assertion so this isn't indistinguishable from a permanently-nil
//    classifier)
//

import XCTest
@testable import Calyx

final class ScreenStateClassifierTests: XCTestCase {

    // MARK: - Fixtures

    /// Mimics Claude Code's bottom-of-screen permission/approval prompt:
    /// a boxed tool-use summary followed by a "Do you want to proceed?"
    /// question and a "❯ 1. Yes" default-selected option.
    private static let approvalPromptText = """
    ╭──────────────────────────────────────────╮
    │ Bash command                              │
    │                                            │
    │   npm install                             │
    │                                            │
    │ Do you want to proceed?                   │
    │ ❯ 1. Yes                                  │
    │   2. Yes, and don't ask again this session │
    │   3. No, and tell Claude what to do        │
    ╰──────────────────────────────────────────╯
    """

    /// Mimics Claude Code's bottom-of-screen "in progress" status line.
    private static let workingMarkerText = """
    ✳ Thinking… (12s · ↑ 1.2k tokens · esc to interrupt)
    """

    private static let plainShellPromptText = "~/projects/calyx %"

    /// apt's own yes/no confirmation prompt — no "❯ N." choice-cursor
    /// marker, so it must NOT classify as `.blocked` despite containing
    /// "Do you want to continue?", a phrase the pre-Round-3-fix pattern
    /// set matched generically.
    private static let aptConfirmationPromptText = """
    The following NEW packages will be installed:
      curl
    0 upgraded, 1 newly installed, 0 to remove.
    Do you want to continue? [Y/n]
    """

    /// fzf's footer hint — no "❯ N." choice-cursor marker either, so it
    /// must NOT classify as `.blocked` despite containing "ESC to
    /// cancel", a phrase the pre-Round-3-fix pattern set also matched
    /// generically.
    private static let fzfFooterText = """
    > query
      12/34
    ESC to cancel
    """

    // MARK: - blocked

    func test_classify_approvalPromptPattern_returnsBlocked() {
        XCTAssertEqual(
            ScreenStateClassifier.classify(bottomText: Self.approvalPromptText, kind: "claude-code"),
            .blocked,
            "A recognized permission/approval prompt block must classify as .blocked"
        )
    }

    // MARK: - working

    func test_classify_workingMarker_returnsWorking() {
        XCTAssertEqual(
            ScreenStateClassifier.classify(bottomText: Self.workingMarkerText, kind: "claude-code"),
            .working,
            "A recognized in-progress marker (esc to interrupt) must classify as .working"
        )
    }

    // MARK: - blocked takes priority over working

    func test_classify_bothBlockedAndWorkingMarkersPresent_prefersBlocked() {
        // A viewport can plausibly contain both an in-progress status line
        // scrolled just above a freshly-appeared approval prompt (the
        // prompt interrupted an in-flight tool call). blocked must win —
        // the user needs to answer it before anything resumes.
        let combined = Self.workingMarkerText + "\n" + Self.approvalPromptText

        XCTAssertEqual(
            ScreenStateClassifier.classify(bottomText: combined, kind: "claude-code"),
            .blocked,
            "When both a working marker and an approval prompt are present, .blocked must take priority"
        )
    }

    // MARK: - nil (no recognized pattern)

    func test_classify_plainShellPromptAndEmptyString_returnNil() {
        // Sanity: the classifier must actually recognize a real pattern —
        // otherwise the nil assertions below would be indistinguishable
        // from a classifier that always returns nil regardless of input.
        XCTAssertEqual(
            ScreenStateClassifier.classify(bottomText: Self.approvalPromptText, kind: "claude-code"),
            .blocked,
            "Precondition: a real approval prompt must classify as .blocked"
        )

        XCTAssertNil(
            ScreenStateClassifier.classify(bottomText: Self.plainShellPromptText, kind: "claude-code"),
            "A plain shell prompt with no known pattern must classify as nil"
        )
        XCTAssertNil(
            ScreenStateClassifier.classify(bottomText: "", kind: "claude-code"),
            "Empty bottom text must classify as nil"
        )
    }

    // MARK: - Round 3 fix: generic phrases alone must not match

    func test_classify_aptConfirmationPrompt_returnsNil() {
        // Regression: "do you want to continue" alone (no "❯ N." marker)
        // used to false-positive as .blocked before the Round 3 fix.
        XCTAssertNil(
            ScreenStateClassifier.classify(bottomText: Self.aptConfirmationPromptText, kind: "claude-code"),
            "apt's own yes/no prompt, with no Claude Code choice-cursor marker, must classify as nil"
        )
    }

    func test_classify_fzfFooter_returnsNil() {
        // Regression: "esc to cancel" alone used to false-positive as
        // .blocked before the Round 3 fix.
        XCTAssertNil(
            ScreenStateClassifier.classify(bottomText: Self.fzfFooterText, kind: "claude-code"),
            "fzf's footer hint, with no Claude Code choice-cursor marker, must classify as nil"
        )
    }
}
