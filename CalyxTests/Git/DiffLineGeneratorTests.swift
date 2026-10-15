// DiffLineGeneratorTests.swift
// CalyxTests
//
// Tests for DiffLineGenerator: building FileDiff.lines from both file sides
// plus the DefaultLinesDiffComputer mappings, and composing with
// DiffReviewStore so the submission text format is unchanged.

import Foundation
import Testing
@testable import Calyx

private func content(_ old: [String], _ new: [String]) -> DiffContent {
    DiffContent(
        oldLines: old,
        newLines: new,
        isBinary: false,
        oldMissingTrailingNewline: false,
        newMissingTrailingNewline: false
    )
}

private func mapping(_ os: Int, _ oe: Int, _ ms: Int, _ me: Int) -> DetailedLineRangeMapping {
    DetailedLineRangeMapping(
        original: LineRange(startLineNumber: os, endLineNumberExclusive: oe),
        modified: LineRange(startLineNumber: ms, endLineNumberExclusive: me),
        innerChanges: nil
    )
}

struct DiffLineGeneratorTests {

    @Test func noChanges_allContextWithBothNumbers() {
        let result = DiffLineGenerator.lines(content: content(["a", "b"], ["a", "b"]), changes: [])
        #expect(result == [
            DiffLine(type: .context, text: " a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(type: .context, text: " b", oldLineNumber: 2, newLineNumber: 2),
        ])
    }

    @Test func replacement_deletionsThenAdditions() {
        let result = DiffLineGenerator.lines(
            content: content(["a", "b", "c"], ["a", "x", "y", "c"]),
            changes: [mapping(2, 3, 2, 4)]
        )
        #expect(result == [
            DiffLine(type: .context, text: " a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(type: .deletion, text: "-b", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(type: .addition, text: "+x", oldLineNumber: nil, newLineNumber: 2),
            DiffLine(type: .addition, text: "+y", oldLineNumber: nil, newLineNumber: 3),
            DiffLine(type: .context, text: " c", oldLineNumber: 3, newLineNumber: 4),
        ])
    }

    @Test func pureInsertion() {
        let result = DiffLineGenerator.lines(
            content: content(["a", "c"], ["a", "b", "c"]),
            changes: [mapping(2, 2, 2, 3)]
        )
        #expect(result == [
            DiffLine(type: .context, text: " a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(type: .addition, text: "+b", oldLineNumber: nil, newLineNumber: 2),
            DiffLine(type: .context, text: " c", oldLineNumber: 2, newLineNumber: 3),
        ])
    }

    @Test func pureDeletion() {
        let result = DiffLineGenerator.lines(
            content: content(["a", "b", "c"], ["a", "c"]),
            changes: [mapping(2, 3, 2, 2)]
        )
        #expect(result == [
            DiffLine(type: .context, text: " a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(type: .deletion, text: "-b", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(type: .context, text: " c", oldLineNumber: 3, newLineNumber: 2),
        ])
    }

    @Test func multipleMappings_andTrailingInsertion() {
        let result = DiffLineGenerator.lines(
            content: content(["a", "b", "c"], ["z", "a", "c", "d"]),
            changes: [mapping(1, 1, 1, 2), mapping(2, 3, 3, 3), mapping(4, 4, 4, 5)]
        )
        #expect(result == [
            DiffLine(type: .addition, text: "+z", oldLineNumber: nil, newLineNumber: 1),
            DiffLine(type: .context, text: " a", oldLineNumber: 1, newLineNumber: 2),
            DiffLine(type: .deletion, text: "-b", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(type: .context, text: " c", oldLineNumber: 3, newLineNumber: 3),
            DiffLine(type: .addition, text: "+d", oldLineNumber: nil, newLineNumber: 4),
        ])
    }

    @Test func untrackedFile_allAdditions() {
        let result = DiffLineGenerator.lines(
            content: content([], ["a", "b"]),
            changes: [mapping(1, 1, 1, 3)]
        )
        #expect(result == [
            DiffLine(type: .addition, text: "+a", oldLineNumber: nil, newLineNumber: 1),
            DiffLine(type: .addition, text: "+b", oldLineNumber: nil, newLineNumber: 2),
        ])
    }

    @Test func neverEmitsHunkHeaderOrMeta() {
        let result = DiffLineGenerator.lines(
            content: content(["a", "b", "c", "d"], ["a", "x", "c", "y"]),
            changes: [mapping(2, 3, 2, 3), mapping(4, 5, 4, 5)]
        )
        #expect(result.count == 6)
        #expect(!result.contains { $0.type == .hunkHeader || $0.type == .meta })
    }
}

@MainActor
@Suite("DiffLineGenerator + DiffReviewStore")
struct DiffLineGeneratorReviewTests {

    @Test func commentOnAdditionLine_submissionTextUnchanged() throws {
        let result = DiffLineGenerator.lines(
            content: content(["a", "b", "c"], ["a", "x", "c"]),
            changes: [mapping(2, 3, 2, 3)]
        )
        let index = try #require(result.firstIndex { $0.type == .addition })
        #expect(index == 2)
        let line = result[index]

        let store = DiffReviewStore()
        store.addComment(
            lineIndex: index,
            lineNumber: line.newLineNumber,
            oldLineNumber: line.oldLineNumber,
            lineType: line.type,
            text: "rename this"
        )
        #expect(store.formatForSubmission(filePath: "Sources/App.swift")
                == "[Code Review] Sources/App.swift\n\nL2 (+): rename this")
    }

    @Test func commentOnDeletionLine_usesOldNumber() throws {
        let result = DiffLineGenerator.lines(
            content: content(["a", "b", "c"], ["a", "x", "c"]),
            changes: [mapping(2, 3, 2, 3)]
        )
        let index = try #require(result.firstIndex { $0.type == .deletion })
        #expect(index == 1)
        let line = result[index]

        let store = DiffReviewStore()
        store.addComment(
            lineIndex: index,
            lineNumber: line.newLineNumber,
            oldLineNumber: line.oldLineNumber,
            lineType: line.type,
            text: "why"
        )
        #expect(store.formatForSubmission(filePath: "f.swift") == "[Code Review] f.swift\n\nL2(old) (-): why")
    }
}
