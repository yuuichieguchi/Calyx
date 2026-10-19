// DiffRowBuilderBlockTests.swift
// CalyxTests
//
// DiffRowBuilder.buildLayout (plan addendum 2 §2): the same rows as
// build(...) plus alignment blocks (row-index ranges partitioning the rows).
// Every emitGroup call (alignment group or uncovered-lines group) is one
// block including its interleaved comment rows; outside a group each line
// row and each comment row is its own block; inline rows are singletons.
// Fixtures mirror DiffRowBuilderTests (its helpers are file-private).

import Foundation
import Testing
@testable import Calyx

// MARK: - Helpers

private func ctx(_ text: String, _ old: Int, _ new: Int) -> DiffLine {
    DiffLine(type: .context, text: " " + text, oldLineNumber: old, newLineNumber: new)
}

private func del(_ text: String, _ old: Int) -> DiffLine {
    DiffLine(type: .deletion, text: "-" + text, oldLineNumber: old, newLineNumber: nil)
}

private func add(_ text: String, _ new: Int) -> DiffLine {
    DiffLine(type: .addition, text: "+" + text, oldLineNumber: nil, newLineNumber: new)
}

private func mapping(
    orig: (Int, Int), mod: (Int, Int), inner: [RangeMapping]? = nil
) -> DetailedLineRangeMapping {
    DetailedLineRangeMapping(
        original: LineRange(startLineNumber: orig.0, endLineNumberExclusive: orig.1),
        modified: LineRange(startLineNumber: mod.0, endLineNumberExclusive: mod.1),
        innerChanges: inner
    )
}

private func inner(orig: (Int, Int, Int, Int), mod: (Int, Int, Int, Int)) -> RangeMapping {
    RangeMapping(
        originalRange: DiffTextRange(startLineNumber: orig.0, startColumn: orig.1, endLineNumber: orig.2, endColumn: orig.3),
        modifiedRange: DiffTextRange(startLineNumber: mod.0, startColumn: mod.1, endLineNumber: mod.2, endColumn: mod.3)
    )
}

private struct Fixture {
    let name: String
    let lines: [DiffLine]
    let changes: [DetailedLineRangeMapping]
    let store: @MainActor () -> DiffReviewStore
}

private let replace2to2Lines: [DiffLine] = [
    ctx("a", 1, 1), del("b", 2), del("c", 3), add("B", 2), add("C", 3), ctx("d", 4, 4),
]
private let replace2to2Changes = [mapping(orig: (2, 4), mod: (2, 4))]

/// Same as DiffRowBuilderSideBySideTests.innerLines/innerChanges: two
/// alignment groups, orig [2,4)/mod [2,5) and orig [4,5)/mod [5,6).
private let innerLines: [DiffLine] = [
    ctx("header", 1, 1), del("let alpha = 1", 2), del("b", 3), del("returnValue(x)", 4),
    add("let alphaX = 1", 2), add("b", 3), add("c", 4), add("returnValue2(x)", 5), ctx("footer", 5, 6),
]
private let innerChanges = [mapping(
    orig: (2, 5), mod: (2, 6),
    inner: [
        inner(orig: (2, 5, 2, 8), mod: (2, 5, 2, 9)),
        inner(orig: (4, 1, 4, 10), mod: (5, 1, 5, 12)),
    ]
)]

@MainActor
private func commentStore(lineIndex: Int, new: Int?, old: Int?, type: DiffLineType) -> DiffReviewStore {
    let store = DiffReviewStore()
    store.addComment(lineIndex: lineIndex, lineNumber: new, oldLineNumber: old, lineType: type, text: "c")
    return store
}

@MainActor private var fixtures: [Fixture] { [
    Fixture(name: "empty", lines: [], changes: [], store: { DiffReviewStore() }),
    Fixture(name: "contextOnly", lines: [ctx("a", 1, 1), ctx("b", 2, 2)], changes: [], store: { DiffReviewStore() }),
    Fixture(name: "pureInsert", lines: [ctx("a", 1, 1), add("x", 2), ctx("b", 2, 3)],
            changes: [mapping(orig: (2, 2), mod: (2, 3))], store: { DiffReviewStore() }),
    Fixture(name: "pureDelete", lines: [ctx("a", 1, 1), del("x", 2), ctx("b", 3, 2)],
            changes: [mapping(orig: (2, 3), mod: (2, 2))], store: { DiffReviewStore() }),
    Fixture(name: "replace2to2", lines: replace2to2Lines, changes: replace2to2Changes, store: { DiffReviewStore() }),
    Fixture(name: "replace1to3", lines: [del("a", 1), add("x", 1), add("y", 2), add("z", 3)],
            changes: [mapping(orig: (1, 2), mod: (1, 4))], store: { DiffReviewStore() }),
    Fixture(name: "replace3to1", lines: [del("a", 1), del("b", 2), del("c", 3), add("x", 1)],
            changes: [mapping(orig: (1, 4), mod: (1, 2))], store: { DiffReviewStore() }),
    Fixture(name: "innerChanges", lines: innerLines, changes: innerChanges, store: { DiffReviewStore() }),
    Fixture(name: "emptyInnerRange",
            lines: [ctx("a", 1, 1), ctx("b", 2, 2), del("abcXdef", 3), add("abcdef", 3)],
            changes: [mapping(orig: (3, 4), mod: (3, 4), inner: [inner(orig: (3, 4, 3, 5), mod: (3, 4, 3, 4))])],
            store: { DiffReviewStore() }),
    Fixture(name: "inlinePureInsert", lines: [ctx("a", 1, 1), add("x", 2), add("y", 3)],
            changes: [mapping(orig: (2, 2), mod: (2, 4))], store: { DiffReviewStore() }),
    Fixture(name: "commentOnDeletion", lines: replace2to2Lines, changes: replace2to2Changes,
            store: { commentStore(lineIndex: 1, new: nil, old: 2, type: .deletion) }),
    Fixture(name: "commentOnAddition", lines: replace2to2Lines, changes: replace2to2Changes,
            store: { commentStore(lineIndex: 3, new: 2, old: nil, type: .addition) }),
    Fixture(name: "commentOnContext", lines: replace2to2Lines, changes: replace2to2Changes,
            store: { commentStore(lineIndex: 0, new: 1, old: 1, type: .context) }),
] }

@MainActor
private func layout(_ lines: [DiffLine], _ changes: [DetailedLineRangeMapping], _ layout: DiffLayout,
                    store: DiffReviewStore = DiffReviewStore()) -> DiffRowLayout {
    DiffRowBuilder.buildLayout(displayLines: store.buildDisplayLines(from: lines), changes: changes, layout: layout)
}

/// Blocks must partition 0..<rowCount: non-empty, contiguous, ascending.
private func expectPartition(_ blocks: [Range<Int>], rowCount: Int, _ label: String = "",
                             sourceLocation: SourceLocation = #_sourceLocation) {
    var next = 0
    for b in blocks {
        #expect(b.lowerBound == next, "\(label): block \(b) does not start at \(next)", sourceLocation: sourceLocation)
        #expect(!b.isEmpty, "\(label): empty block \(b)", sourceLocation: sourceLocation)
        next = b.upperBound
    }
    #expect(next == rowCount, "\(label): blocks end at \(next), rows \(rowCount)", sourceLocation: sourceLocation)
}

private func singletons(_ count: Int) -> [Range<Int>] {
    (0..<count).map { $0..<($0 + 1) }
}

// MARK: - Tests

@MainActor
@Suite("DiffRowBuilder.buildLayout blocks")
struct DiffRowBuilderBlockTests {

    @Test func rows_equalBuild_forEveryFixture_bothLayouts() {
        for f in fixtures {
            for l in [DiffLayout.sideBySide, .inline] {
                let store = f.store()
                let display = store.buildDisplayLines(from: f.lines)
                let built = DiffRowBuilder.build(displayLines: display, changes: f.changes, layout: l)
                let result = DiffRowBuilder.buildLayout(displayLines: display, changes: f.changes, layout: l)
                #expect(result.rows == built, "\(f.name) \(l)")
                expectPartition(result.blocks, rowCount: result.rows.count, "\(f.name) \(l)")
            }
        }
    }

    @Test func empty_noBlocks() {
        #expect(layout([], [], .sideBySide) == DiffRowLayout(rows: [], blocks: []))
    }

    @Test func contextOnly_eachRowOwnBlock() {
        let result = layout([ctx("a", 1, 1), ctx("b", 2, 2)], [], .sideBySide)
        #expect(result.rows.count == 2)
        #expect(result.blocks == [0..<1, 1..<2])
    }

    /// rows: 0 ctx | 1 (filler, +x) | 2 ctx
    @Test func pureInsert_changeIsOwnBlock() {
        let result = layout([ctx("a", 1, 1), add("x", 2), ctx("b", 2, 3)], [mapping(orig: (2, 2), mod: (2, 3))], .sideBySide)
        #expect(result.blocks == [0..<1, 1..<2, 2..<3])
    }

    /// rows: 0 ctx | 1-2 group | 3 ctx
    @Test func replace2to2_oneTwoRowBlock() {
        let result = layout(replace2to2Lines, replace2to2Changes, .sideBySide)
        #expect(result.blocks == [0..<1, 1..<3, 3..<4])
    }

    @Test func replace1to3_oneBlockOfThreeRows() {
        let result = layout([del("a", 1), add("x", 1), add("y", 2), add("z", 3)],
                            [mapping(orig: (1, 2), mod: (1, 4))], .sideBySide)
        #expect(result.rows.count == 3)
        #expect(result.blocks == [0..<3])
    }

    /// rows: 0 ctx | 1-3 group 1 (2 orig vs 3 mod) | 4 group 2 (1:1) | 5 ctx
    @Test func twoAlignmentGroups_twoBlocks() {
        let result = layout(innerLines, innerChanges, .sideBySide)
        #expect(result.rows.count == 6)
        #expect(result.blocks == [0..<1, 1..<4, 4..<5, 5..<6])
    }

    /// rows: 0 ctx | 1 (del, add) | 2 (comment, filler) | 3 (del, add) | 4 ctx
    /// The comment row sits inside the change group, so the group block covers it.
    @Test func commentOnDeletion_groupBlockCoversLineAndCommentRow() {
        let store = commentStore(lineIndex: 1, new: nil, old: 2, type: .deletion)
        let result = layout(replace2to2Lines, replace2to2Changes, .sideBySide, store: store)
        #expect(result.rows.count == 5)
        #expect(result.blocks == [0..<1, 1..<4, 4..<5])
    }

    /// rows: 0 ctx | 1 (filler, comment) | 2-3 group | 4 ctx
    @Test func commentOnContext_lineAndCommentAreSeparateSingletons() {
        let store = commentStore(lineIndex: 0, new: 1, old: 1, type: .context)
        let result = layout(replace2to2Lines, replace2to2Changes, .sideBySide, store: store)
        #expect(result.rows.count == 5)
        #expect(result.blocks == [0..<1, 1..<2, 2..<4, 4..<5])
    }

    @Test func inline_allSingletons() {
        for f in fixtures {
            let result = layout(f.lines, f.changes, .inline, store: f.store())
            #expect(result.blocks == singletons(result.rows.count), "\(f.name)")
        }
        let r = layout(replace2to2Lines, replace2to2Changes, .inline)
        #expect(r.rows.count == 6)
        #expect(r.blocks == singletons(6))
    }
}
