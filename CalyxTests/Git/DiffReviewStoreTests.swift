// DiffReviewStoreTests.swift
// CalyxTests
//
// Tests for DiffReviewStore: comment CRUD, submission formatting,
// displayLine interleaving, and input sanitization.

import Foundation
import Testing
@testable import Calyx

// MARK: - Helpers

/// Build a DiffLine for testing without requiring a real parser.
private func makeDiffLine(
    type: DiffLineType,
    text: String,
    oldLineNumber: Int? = nil,
    newLineNumber: Int? = nil
) -> DiffLine {
    DiffLine(type: type, text: text, oldLineNumber: oldLineNumber, newLineNumber: newLineNumber)
}

// MARK: - Store Logic Tests

@MainActor
@Suite("DiffReviewStore CRUD Tests")
struct DiffReviewStoreCRUDTests {

    @Test func test_addComment_increasesCount() {
        let store = DiffReviewStore()
        #expect(store.comments.isEmpty)

        store.addComment(
            lineIndex: 0,
            lineNumber: 42,
            oldLineNumber: nil,
            lineType: .addition,
            text: "looks good"
        )

        #expect(store.comments.count == 1)
    }

    @Test func test_removeComment_decreasesCount() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: 10,
            oldLineNumber: nil,
            lineType: .addition,
            text: "first"
        )
        store.addComment(
            lineIndex: 1,
            lineNumber: 11,
            oldLineNumber: nil,
            lineType: .addition,
            text: "second"
        )
        #expect(store.comments.count == 2)

        let idToRemove = store.comments[0].id
        store.removeComment(id: idToRemove)

        #expect(store.comments.count == 1)
        #expect(store.comments.first?.text == "second")
    }

    @Test func test_updateComment_changesText() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: 5,
            oldLineNumber: nil,
            lineType: .addition,
            text: "original"
        )
        let commentID = store.comments[0].id

        store.updateComment(id: commentID, text: "updated")

        #expect(store.comments[0].text == "updated")
    }

    @Test func test_clearAll_emptiesComments() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: 1,
            oldLineNumber: nil,
            lineType: .addition,
            text: "a"
        )
        store.addComment(
            lineIndex: 1,
            lineNumber: 2,
            oldLineNumber: nil,
            lineType: .context,
            text: "b"
        )
        #expect(store.comments.count == 2)

        store.clearAll()

        #expect(store.comments.isEmpty)
    }

    @Test func test_hasUnsubmittedComments_trueWhenNotEmpty() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: 1,
            oldLineNumber: nil,
            lineType: .addition,
            text: "note"
        )

        #expect(store.hasUnsubmittedComments == true)
    }

    @Test func test_hasUnsubmittedComments_falseWhenEmpty() {
        let store = DiffReviewStore()

        #expect(store.hasUnsubmittedComments == false)
    }
}

// MARK: - Format Tests

@MainActor
@Suite("DiffReviewStore Format Tests")
struct DiffReviewStoreFormatTests {

    @Test func test_formatForSubmission_singleAdditionComment() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: 42,
            oldLineNumber: nil,
            lineType: .addition,
            text: "nice change"
        )

        let output = store.formatForSubmission(filePath: "Sources/App.swift")

        #expect(output.contains("[Code Review] Sources/App.swift"))
        #expect(output.contains("L42 (+): nice change"))
    }

    @Test func test_formatForSubmission_deletionUsesOldLineNumber() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: nil,
            oldLineNumber: 88,
            lineType: .deletion,
            text: "why remove this?"
        )

        let output = store.formatForSubmission(filePath: "file.swift")

        #expect(output.contains("L88(old) (-): why remove this?"))
    }

    @Test func test_formatForSubmission_multipleComments_orderedByLineIndex() {
        let store = DiffReviewStore()
        // Add in reverse order to verify sorting
        store.addComment(
            lineIndex: 10,
            lineNumber: 55,
            oldLineNumber: nil,
            lineType: .context,
            text: "later comment"
        )
        store.addComment(
            lineIndex: 2,
            lineNumber: 20,
            oldLineNumber: nil,
            lineType: .addition,
            text: "earlier comment"
        )

        let output = store.formatForSubmission(filePath: "test.swift")
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // First non-header line should be the earlier comment (lineIndex 2)
        // Header is "[Code Review] test.swift"
        #expect(lines.count >= 3)
        #expect(lines[0] == "[Code Review] test.swift")
        #expect(lines[1].contains("earlier comment"))
        #expect(lines[2].contains("later comment"))
    }

    @Test func test_formatForSubmission_contextUsesNewLineNumber() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: 55,
            oldLineNumber: 50,
            lineType: .context,
            text: "context note"
        )

        let output = store.formatForSubmission(filePath: "ctx.swift")

        // Context lines use new-side line number: "L55 ( ): ..."
        #expect(output.contains("L55 ( ): context note"))
        // Must NOT use old-side format
        #expect(!output.contains("L50(old)"))
    }
}

// MARK: - Constraint Tests

@MainActor
@Suite("DiffReviewStore Constraint Tests")
struct DiffReviewStoreConstraintTests {

    @Test func test_commentTextNewlineStripped() {
        let store = DiffReviewStore()
        store.addComment(
            lineIndex: 0,
            lineNumber: 1,
            oldLineNumber: nil,
            lineType: .addition,
            text: "line1\nline2\rline3"
        )

        let comment = store.comments[0]
        #expect(!comment.text.contains("\n"))
        #expect(!comment.text.contains("\r"))
        #expect(comment.text == "line1line2line3")
    }
}

// MARK: - DisplayLine Tests

@MainActor
@Suite("DiffReviewStore DisplayLine Tests")
struct DiffReviewStoreDisplayLineTests {

    @Test func test_displayLines_noComments_matchesDiffLines() {
        let store = DiffReviewStore()
        let diffLines = [
            makeDiffLine(type: .context, text: "unchanged", oldLineNumber: 1, newLineNumber: 1),
            makeDiffLine(type: .addition, text: "added", oldLineNumber: nil, newLineNumber: 2),
            makeDiffLine(type: .deletion, text: "removed", oldLineNumber: 2, newLineNumber: nil),
        ]

        let result = store.buildDisplayLines(from: diffLines)

        // Every element should be .diff, matching the input 1:1
        #expect(result.count == 3)
        for (i, displayLine) in result.enumerated() {
            if case .diff(let line) = displayLine {
                #expect(line == diffLines[i])
            } else {
                Issue.record("Expected .diff at index \(i), got .commentBlock")
            }
        }
    }

    @Test func test_displayLines_commentInsertedAfterTargetLine() {
        let store = DiffReviewStore()
        let diffLines = [
            makeDiffLine(type: .context, text: "line A", oldLineNumber: 1, newLineNumber: 1),
            makeDiffLine(type: .addition, text: "line B", oldLineNumber: nil, newLineNumber: 2),
            makeDiffLine(type: .context, text: "line C", oldLineNumber: 2, newLineNumber: 3),
        ]

        // Add a comment on line index 1 (the addition line)
        store.addComment(
            lineIndex: 1,
            lineNumber: 2,
            oldLineNumber: nil,
            lineType: .addition,
            text: "review note"
        )

        let result = store.buildDisplayLines(from: diffLines)

        // Expected: diff[0], diff[1], commentBlock, diff[2]
        #expect(result.count == 4)

        if case .diff(let d0) = result[0] {
            #expect(d0 == diffLines[0])
        } else {
            Issue.record("Expected .diff at index 0")
        }

        if case .diff(let d1) = result[1] {
            #expect(d1 == diffLines[1])
        } else {
            Issue.record("Expected .diff at index 1")
        }

        if case .commentBlock(let comment) = result[2] {
            #expect(comment.text == "review note")
            #expect(comment.lineIndex == 1)
        } else {
            Issue.record("Expected .commentBlock at index 2")
        }

        if case .diff(let d2) = result[3] {
            #expect(d2 == diffLines[2])
        } else {
            Issue.record("Expected .diff at index 3")
        }
    }

    @Test func test_displayLines_multipleComments_correctOrder() {
        let store = DiffReviewStore()
        let diffLines = [
            makeDiffLine(type: .context, text: "line 1", oldLineNumber: 1, newLineNumber: 1),
            makeDiffLine(type: .addition, text: "line 2", oldLineNumber: nil, newLineNumber: 2),
            makeDiffLine(type: .addition, text: "line 3", oldLineNumber: nil, newLineNumber: 3),
            makeDiffLine(type: .context, text: "line 4", oldLineNumber: 2, newLineNumber: 4),
        ]

        // Comment on line index 1 and line index 2 (consecutive additions)
        store.addComment(
            lineIndex: 1,
            lineNumber: 2,
            oldLineNumber: nil,
            lineType: .addition,
            text: "first comment"
        )
        store.addComment(
            lineIndex: 2,
            lineNumber: 3,
            oldLineNumber: nil,
            lineType: .addition,
            text: "second comment"
        )

        let result = store.buildDisplayLines(from: diffLines)

        // Expected: diff[0], diff[1], comment1, diff[2], comment2, diff[3]
        #expect(result.count == 6)

        // Verify comment ordering: first comment after diff[1], second after diff[2]
        if case .commentBlock(let c1) = result[2] {
            #expect(c1.text == "first comment")
        } else {
            Issue.record("Expected .commentBlock (first comment) at index 2")
        }

        if case .commentBlock(let c2) = result[4] {
            #expect(c2.text == "second comment")
        } else {
            Issue.record("Expected .commentBlock (second comment) at index 4")
        }
    }
}

// MARK: - Multi-File Format Tests

@MainActor
@Suite("DiffReviewStore Multi-File Format Tests")
struct DiffReviewStoreMultiFileFormatTests {

    @Test func test_formatAllForSubmission_multipleFiles_sortedByPath() {
        // Two stores with different file paths, verify output sorted by path
        let storeB = DiffReviewStore()
        storeB.addComment(lineIndex: 0, lineNumber: 10, oldLineNumber: nil, lineType: .addition, text: "comment on B")
        let storeA = DiffReviewStore()
        storeA.addComment(lineIndex: 0, lineNumber: 5, oldLineNumber: nil, lineType: .addition, text: "comment on A")

        let entries: [(source: DiffSource, store: DiffReviewStore)] = [
            (.staged(path: "src/B.swift", workDir: "/tmp"), storeB),
            (.staged(path: "src/A.swift", workDir: "/tmp"), storeA),
        ]

        let output = DiffReviewStore.formatAllForSubmission(entries)

        // A.swift should appear before B.swift
        let aRange = output.range(of: "src/A.swift")!
        let bRange = output.range(of: "src/B.swift")!
        #expect(aRange.lowerBound < bRange.lowerBound)
        #expect(output.contains("[Code Review] 2 files"))
    }

    @Test func test_formatAllForSubmission_samePathDifferentSource_distinguished() {
        // Same file path but staged vs unstaged → distinguished by source label
        let storeSt = DiffReviewStore()
        storeSt.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "staged comment")
        let storeUn = DiffReviewStore()
        storeUn.addComment(lineIndex: 0, lineNumber: 2, oldLineNumber: nil, lineType: .addition, text: "unstaged comment")

        let entries: [(source: DiffSource, store: DiffReviewStore)] = [
            (.unstaged(path: "Models/User.swift", workDir: "/tmp"), storeUn),
            (.staged(path: "Models/User.swift", workDir: "/tmp"), storeSt),
        ]

        let output = DiffReviewStore.formatAllForSubmission(entries)

        #expect(output.contains("Models/User.swift (staged)"))
        #expect(output.contains("Models/User.swift (unstaged)"))
        // staged should come before unstaged in sort order
        let stagedRange = output.range(of: "(staged)")!
        let unstagedRange = output.range(of: "(unstaged)")!
        #expect(stagedRange.lowerBound < unstagedRange.lowerBound)
    }

    @Test func test_formatAllForSubmission_skipsEmptyStores() {
        let storeWithComments = DiffReviewStore()
        storeWithComments.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "has comment")
        let emptyStore = DiffReviewStore()

        let entries: [(source: DiffSource, store: DiffReviewStore)] = [
            (.staged(path: "file1.swift", workDir: "/tmp"), storeWithComments),
            (.staged(path: "file2.swift", workDir: "/tmp"), emptyStore),
        ]

        let output = DiffReviewStore.formatAllForSubmission(entries)

        #expect(output.contains("file1.swift"))
        #expect(!output.contains("file2.swift"))
        #expect(output.contains("[Code Review] 1 file"))
    }

    @Test func test_formatAllForSubmission_singleFile() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 42, oldLineNumber: nil, lineType: .addition, text: "single file comment")

        let entries: [(source: DiffSource, store: DiffReviewStore)] = [
            (.commit(hash: "a1b2c3d4e5f6", path: "Views/Main.swift", workDir: "/tmp"), store),
        ]

        let output = DiffReviewStore.formatAllForSubmission(entries)

        #expect(output.contains("[Code Review] 1 file"))
        #expect(output.contains("Views/Main.swift (a1b2c3d)"))
        #expect(output.contains("L42 (+): single file comment"))
    }

    @Test func test_formatAllForSubmission_emptyInput() {
        let output = DiffReviewStore.formatAllForSubmission([])
        #expect(output.isEmpty)
    }

    @Test func test_formatAllForSubmission_commitSourceUsesShortHash() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .context, text: "note")

        let entries: [(source: DiffSource, store: DiffReviewStore)] = [
            (.commit(hash: "abcdef1234567890", path: "file.swift", workDir: "/tmp"), store),
        ]

        let output = DiffReviewStore.formatAllForSubmission(entries)
        #expect(output.contains("(abcdef1)"))
    }

    @Test func test_formatAllForSubmission_untrackedSource() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "untracked note")

        let entries: [(source: DiffSource, store: DiffReviewStore)] = [
            (.untracked(path: "NewFile.swift", workDir: "/tmp"), store),
        ]

        let output = DiffReviewStore.formatAllForSubmission(entries)
        #expect(output.contains("NewFile.swift (untracked)"))
    }

    @Test func test_formatAllForSubmission_commentsWithinFileSortedByLineIndex() {
        let store = DiffReviewStore()
        // Add in reverse order to verify intra-file sorting
        store.addComment(lineIndex: 10, lineNumber: 50, oldLineNumber: nil, lineType: .addition, text: "later")
        store.addComment(lineIndex: 2, lineNumber: 20, oldLineNumber: nil, lineType: .context, text: "earlier")

        let entries: [(source: DiffSource, store: DiffReviewStore)] = [
            (.staged(path: "file.swift", workDir: "/tmp"), store),
        ]

        let output = DiffReviewStore.formatAllForSubmission(entries)
        let earlierRange = output.range(of: "earlier")!
        let laterRange = output.range(of: "later")!
        #expect(earlierRange.lowerBound < laterRange.lowerBound)
    }

    @Test func test_sanitizeForTerminal_removesC1ControlCharacters() {
        let store = DiffReviewStore()
        // CSI (0x9B) can initiate terminal escape sequences
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "before\u{9B}31mafter")
        #expect(store.comments[0].text == "before31mafter")
    }
}

// MARK: - Sanitize Tests

@MainActor
@Suite("DiffReviewStore Sanitize Tests")
struct DiffReviewStoreSanitizeTests {

    @Test func test_sanitizeForTerminal_removesControlCharacters() {
        let store = DiffReviewStore()
        // ESC (0x1B), BEL (0x07), NULL (0x00)
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "hello\u{1B}world\u{07}test\u{00}end")
        #expect(store.comments[0].text == "helloworldtestend")
    }

    @Test func test_sanitizeForTerminal_convertsTabToSpace() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "before\tafter")
        #expect(store.comments[0].text == "before after")
    }

    @Test func test_sanitizeForTerminal_preservesNormalText() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "Normal text with spaces & symbols! @#$%")
        #expect(store.comments[0].text == "Normal text with spaces & symbols! @#$%")
    }

    @Test func test_sanitizeForTerminal_removesNewlines() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "line1\nline2\rline3")
        #expect(store.comments[0].text == "line1line2line3")
    }

    @Test func test_updateComment_sanitizes() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: nil, lineType: .addition, text: "original")
        let id = store.comments[0].id
        store.updateComment(id: id, text: "updated\u{1B}\twith\u{07}control")
        #expect(store.comments[0].text == "updated withcontrol")
    }
}

// MARK: - Range Comment Tests

@MainActor
@Suite("DiffReviewStore Range Comment Tests")
struct DiffReviewStoreRangeCommentTests {

    /// Build diff lines with addition lines at indices 2-5, newLineNumber 10-13.
    private func makeRangeDiffLines() -> [DiffLine] {
        [
            makeDiffLine(type: .meta, text: "diff --git a/f b/f"),
            makeDiffLine(type: .hunkHeader, text: "@@ -1,3 +10,4 @@"),
            makeDiffLine(type: .addition, text: "line10", newLineNumber: 10),
            makeDiffLine(type: .addition, text: "line11", newLineNumber: 11),
            makeDiffLine(type: .addition, text: "line12", newLineNumber: 12),
            makeDiffLine(type: .addition, text: "line13", newLineNumber: 13),
        ]
    }

    @Test func test_addRangeComment_storesRange() {
        let store = DiffReviewStore()
        let diffLines = makeRangeDiffLines()

        store.addRangeComment(
            startLineIndex: 2,
            endLineIndex: 5,
            lines: diffLines,
            text: "range note"
        )

        #expect(store.comments.count == 1)
        let comment = store.comments[0]
        #expect(comment.endLineIndex == 5)
        #expect(comment.displayLineNumber == "L10-L13")
        #expect(comment.text == "range note")
    }

    @Test func test_rangeComment_displayLines_insertedAfterLastLine() {
        let store = DiffReviewStore()
        let diffLines = [
            makeDiffLine(type: .context, text: "line A", oldLineNumber: 1, newLineNumber: 1),
            makeDiffLine(type: .addition, text: "line B", newLineNumber: 2),
            makeDiffLine(type: .addition, text: "line C", newLineNumber: 3),
            makeDiffLine(type: .context, text: "line D", oldLineNumber: 2, newLineNumber: 4),
        ]

        // Range comment spanning lineIndex 1 to 2
        store.addRangeComment(
            startLineIndex: 1,
            endLineIndex: 2,
            lines: diffLines,
            text: "range display test"
        )

        let result = store.buildDisplayLines(from: diffLines)

        // Expected: diff[0], diff[1], diff[2], commentBlock, diff[3]
        // The comment block should appear after the LAST line of the range (index 2), not after index 1
        #expect(result.count == 5)

        if case .diff(let d0) = result[0] {
            #expect(d0 == diffLines[0])
        } else {
            Issue.record("Expected .diff at display index 0")
        }
        if case .diff(let d1) = result[1] {
            #expect(d1 == diffLines[1])
        } else {
            Issue.record("Expected .diff at display index 1")
        }
        if case .diff(let d2) = result[2] {
            #expect(d2 == diffLines[2])
        } else {
            Issue.record("Expected .diff at display index 2")
        }
        if case .commentBlock(let c) = result[3] {
            #expect(c.text == "range display test")
        } else {
            Issue.record("Expected .commentBlock at display index 3")
        }
        if case .diff(let d3) = result[4] {
            #expect(d3 == diffLines[3])
        } else {
            Issue.record("Expected .diff at display index 4")
        }
    }

    @Test func test_rangeComment_formatForSubmission_additionOnly() {
        let store = DiffReviewStore()
        let diffLines = [
            makeDiffLine(type: .addition, text: "a", newLineNumber: 10),
            makeDiffLine(type: .addition, text: "b", newLineNumber: 11),
        ]

        store.addRangeComment(
            startLineIndex: 0,
            endLineIndex: 1,
            lines: diffLines,
            text: "addition range"
        )

        let output = store.formatForSubmission(filePath: "test.swift")
        #expect(output.contains("L10-L11 (+): addition range"))
    }

    @Test func test_rangeComment_formatForSubmission_deletionOnly() {
        let store = DiffReviewStore()
        let diffLines = [
            makeDiffLine(type: .deletion, text: "a", oldLineNumber: 5),
            makeDiffLine(type: .deletion, text: "b", oldLineNumber: 6),
            makeDiffLine(type: .deletion, text: "c", oldLineNumber: 7),
        ]

        store.addRangeComment(
            startLineIndex: 0,
            endLineIndex: 2,
            lines: diffLines,
            text: "deletion range"
        )

        let output = store.formatForSubmission(filePath: "test.swift")
        #expect(output.contains("L5(old)-L7(old) (-): deletion range"))
    }

    @Test func test_rangeComment_formatForSubmission_mixedTypes() {
        let store = DiffReviewStore()
        let diffLines = [
            makeDiffLine(type: .deletion, text: "old", oldLineNumber: 5),
            makeDiffLine(type: .addition, text: "new", newLineNumber: 11),
        ]

        // Range starting with deletion, ending with addition
        store.addRangeComment(
            startLineIndex: 0,
            endLineIndex: 1,
            lines: diffLines,
            text: "mixed range"
        )

        let output = store.formatForSubmission(filePath: "test.swift")
        // Uses start line's type (deletion) for the type indicator
        #expect(output.contains("L5(old)-L11 (-): mixed range"))
    }
}

// MARK: - resolveDisplayRange Tests

@MainActor
@Suite("DiffReviewStore resolveDisplayRange Tests")
struct DiffReviewStoreResolveDisplayRangeTests {

    private func makeTestDisplayLines() -> [DisplayLine] {
        [
            .diff(makeDiffLine(type: .meta, text: "diff --git a/f b/f")),
            .diff(makeDiffLine(type: .hunkHeader, text: "@@ -1,3 +1,4 @@")),
            .diff(makeDiffLine(type: .context, text: "line1", oldLineNumber: 1, newLineNumber: 1)),
            .diff(makeDiffLine(type: .deletion, text: "line2", oldLineNumber: 2)),
            .diff(makeDiffLine(type: .addition, text: "line2a", newLineNumber: 2)),
            .diff(makeDiffLine(type: .addition, text: "line2b", newLineNumber: 3)),
            .diff(makeDiffLine(type: .context, text: "line3", oldLineNumber: 3, newLineNumber: 4)),
            .diff(makeDiffLine(type: .hunkHeader, text: "@@ -10,2 +11,2 @@")),
            .diff(makeDiffLine(type: .context, text: "line10", oldLineNumber: 10, newLineNumber: 11)),
            .diff(makeDiffLine(type: .addition, text: "line11", newLineNumber: 12)),
        ]
    }

    private func makeTestDisplayLinesWithComment() -> [DisplayLine] {
        [
            .diff(makeDiffLine(type: .meta, text: "diff --git a/f b/f")),
            .diff(makeDiffLine(type: .hunkHeader, text: "@@ -1,3 +1,4 @@")),
            .diff(makeDiffLine(type: .context, text: "line1", oldLineNumber: 1, newLineNumber: 1)),
            .diff(makeDiffLine(type: .deletion, text: "line2", oldLineNumber: 2)),
            .diff(makeDiffLine(type: .addition, text: "line2a", newLineNumber: 2)),
            .commentBlock(ReviewComment(
                id: UUID(),
                lineIndex: 4,
                endLineIndex: nil,
                displayLineNumber: "L2",
                lineType: .addition,
                text: "existing"
            )),
            .diff(makeDiffLine(type: .addition, text: "line2b", newLineNumber: 3)),
            .diff(makeDiffLine(type: .context, text: "line3", oldLineNumber: 3, newLineNumber: 4)),
            .diff(makeDiffLine(type: .hunkHeader, text: "@@ -10,2 +11,2 @@")),
            .diff(makeDiffLine(type: .context, text: "line10", oldLineNumber: 10, newLineNumber: 11)),
            .diff(makeDiffLine(type: .addition, text: "line11", newLineNumber: 12)),
        ]
    }

    @Test func test_resolveDisplayRange_normalRange() {
        let displayLines = makeTestDisplayLines()

        let result = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: 2,
            endDisplayIdx: 5,
            displayLines: displayLines
        )

        // display 2-5 are all .diff lines with commentable types (context, deletion, addition, addition)
        // original indices: meta=0, hunkHeader=1, context=2, deletion=3, addition=4, addition=5
        #expect(result != nil)
        #expect(result?.startOriginal == 2)
        #expect(result?.endOriginal == 5)
    }

    @Test func test_resolveDisplayRange_clampsAtHunkHeader() {
        let displayLines = makeTestDisplayLines()

        let result = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: 5,
            endDisplayIdx: 9,
            displayLines: displayLines
        )

        // Range crosses hunkHeader at display index 7 → clamp to continuous commentable block before it
        // display 5 = addition (orig 5), display 6 = context (orig 6), display 7 = hunkHeader → stop
        #expect(result != nil)
        #expect(result?.startOriginal == 5)
        #expect(result?.endOriginal == 6)
    }

    @Test func test_resolveDisplayRange_skipsCommentBlocks() {
        let displayLines = makeTestDisplayLinesWithComment()

        let result = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: 2,
            endDisplayIdx: 6,
            displayLines: displayLines
        )

        // display 2(context,orig 2), 3(deletion,orig 3), 4(addition,orig 4),
        // 5(commentBlock, skip), 6(addition,orig 5)
        // All commentable lines → originals 2-5
        #expect(result != nil)
        #expect(result?.startOriginal == 2)
        #expect(result?.endOriginal == 5)
    }

    @Test func test_resolveDisplayRange_upwardDrag() {
        let displayLines = makeTestDisplayLines()

        // Reversed selection: start > end → should normalize
        let result = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: 5,
            endDisplayIdx: 2,
            displayLines: displayLines
        )

        #expect(result != nil)
        #expect(result?.startOriginal == 2)
        #expect(result?.endOriginal == 5)
    }

    @Test func test_resolveDisplayRange_singleLine() {
        let displayLines = makeTestDisplayLines()

        let result = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: 4,
            endDisplayIdx: 4,
            displayLines: displayLines
        )

        // Single commentable line (addition at display 4, orig 4)
        #expect(result != nil)
        #expect(result?.startOriginal == 4)
        #expect(result?.endOriginal == 4)
    }

    @Test func test_resolveDisplayRange_noCommentableLines() {
        let displayLines = makeTestDisplayLines()

        // display 0 = meta, display 1 = hunkHeader → neither is commentable
        let result = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: 0,
            endDisplayIdx: 1,
            displayLines: displayLines
        )

        #expect(result == nil)
    }
}

// MARK: - Backward Compatibility Tests

@MainActor
@Suite("DiffReviewStore Backward Compatibility Tests")
struct DiffReviewStoreBackwardCompatibilityTests {

    @Test func test_singleLineComment_backwardCompatible() {
        let store = DiffReviewStore()

        // Use existing addComment method
        store.addComment(
            lineIndex: 3,
            lineNumber: 42,
            oldLineNumber: nil,
            lineType: .addition,
            text: "single line note"
        )

        let comment = store.comments[0]

        // endLineIndex should be nil for single-line comments
        #expect(comment.endLineIndex == nil)
        // displayLineNumber should be the traditional format
        #expect(comment.displayLineNumber == "L42")
        #expect(comment.text == "single line note")
    }
}
