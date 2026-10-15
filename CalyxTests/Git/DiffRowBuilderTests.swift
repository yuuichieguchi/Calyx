// DiffRowBuilderTests.swift
// CalyxTests
//
// Tests for DiffRowBuilder: side-by-side alignment (port of VS Code's
// computeRangeAlignment with innerHunkAlignment = true), inline order,
// comment rows, inner ranges and whole-line-change flags.

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

private func inner(
    orig: (Int, Int, Int, Int), mod: (Int, Int, Int, Int)
) -> RangeMapping {
    RangeMapping(
        originalRange: DiffTextRange(startLineNumber: orig.0, startColumn: orig.1, endLineNumber: orig.2, endColumn: orig.3),
        modifiedRange: DiffTextRange(startLineNumber: mod.0, startColumn: mod.1, endLineNumber: mod.2, endColumn: mod.3)
    )
}

/// Expected cell description.
private enum Spec {
    case line(display: Int, line: Int, DiffLineType, inner: [NSRange] = [], whole: Bool = false)
    case filler
    case comment(display: Int)
    case absent
}

/// `showsModified`: the cell is in the right pane or the inline view, where
/// context cells show the modified text.
private func check(_ cell: DiffCell?, _ spec: Spec, row: Int, side: String, showsModified: Bool,
                   sourceLocation: SourceLocation = #_sourceLocation) {
    switch spec {
    case .absent:
        #expect(cell == nil, "row \(row) \(side): expected no cell", sourceLocation: sourceLocation)
    case .filler:
        #expect(cell?.kind == .filler, "row \(row) \(side): expected filler, got \(String(describing: cell))", sourceLocation: sourceLocation)
    case .comment(let d):
        #expect(cell?.kind == .comment, "row \(row) \(side): expected comment, got \(String(describing: cell))", sourceLocation: sourceLocation)
        #expect(cell?.displayIndex == d, "row \(row) \(side): comment displayIndex", sourceLocation: sourceLocation)
    case let .line(d, l, type, innerRanges, whole):
        let expected = DiffCell(displayIndex: d, lineIndex: l, kind: .line(type),
                                innerRanges: innerRanges, isWholeLineChange: whole,
                                textSide: type == .context && showsModified ? .right : .left)
        #expect(cell == expected, "row \(row) \(side): expected \(expected), got \(String(describing: cell))", sourceLocation: sourceLocation)
    }
}

private func expectRows(_ rows: [DiffLayoutRow], _ specs: [(Spec, Spec)],
                        sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(rows.count == specs.count, "row count \(rows.count) != \(specs.count): \(rows)", sourceLocation: sourceLocation)
    let isInline = specs.allSatisfy { if case .absent = $0.1 { true } else { false } }
    for (i, pair) in zip(rows, specs).enumerated() {
        check(pair.0.left, pair.1.0, row: i, side: "left", showsModified: isInline, sourceLocation: sourceLocation)
        check(pair.0.right, pair.1.1, row: i, side: "right", showsModified: true, sourceLocation: sourceLocation)
    }
}

@MainActor
private func build(_ lines: [DiffLine], _ changes: [DetailedLineRangeMapping],
                   _ layout: DiffLayout, store: DiffReviewStore = DiffReviewStore()) -> [DiffLayoutRow] {
    let displayLines = store.buildDisplayLines(from: lines)
    return DiffRowBuilder.build(displayLines: displayLines, changes: changes, layout: layout)
}

/// orig: 1 ctx, 2-3 deleted, 4 ctx  /  mod: 1 ctx, 2-3 added, 4 ctx
private let replace2to2Lines: [DiffLine] = [
    ctx("a", 1, 1), del("b", 2), del("c", 3), add("B", 2), add("C", 3), ctx("d", 4, 4),
]
private let replace2to2Changes = [mapping(orig: (2, 4), mod: (2, 4))]

// MARK: - Side-by-side

@MainActor
@Suite("DiffRowBuilder side-by-side")
struct DiffRowBuilderSideBySideTests {

    @Test func emptyDiff_producesNoRows() {
        #expect(build([], [], .sideBySide).isEmpty)
        #expect(build([], [], .inline).isEmpty)
    }

    @Test func contextOnly_sameLineOnBothSides_rightShowsModifiedText() {
        let rows = build([ctx("a", 1, 1), ctx("b", 2, 2)], [], .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.line(display: 1, line: 1, .context), .line(display: 1, line: 1, .context)),
        ])
    }

    @Test func pureInsert_leftFiller_wholeLine() {
        let lines = [ctx("a", 1, 1), add("x", 2), ctx("b", 2, 3)]
        let rows = build(lines, [mapping(orig: (2, 2), mod: (2, 3))], .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.filler, .line(display: 1, line: 1, .addition, whole: true)),
            (.line(display: 2, line: 2, .context), .line(display: 2, line: 2, .context)),
        ])
    }

    @Test func pureDelete_rightFiller_wholeLine() {
        let lines = [ctx("a", 1, 1), del("x", 2), ctx("b", 3, 2)]
        let rows = build(lines, [mapping(orig: (2, 3), mod: (2, 2))], .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.line(display: 1, line: 1, .deletion, whole: true), .filler),
            (.line(display: 2, line: 2, .context), .line(display: 2, line: 2, .context)),
        ])
    }

    @Test func replace2to2_rowAligned_noFiller_notWholeLine() {
        let rows = build(replace2to2Lines, replace2to2Changes, .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.line(display: 1, line: 1, .deletion), .line(display: 3, line: 3, .addition)),
            (.line(display: 2, line: 2, .deletion), .line(display: 4, line: 4, .addition)),
            (.line(display: 5, line: 5, .context), .line(display: 5, line: 5, .context)),
        ])
    }

    @Test func replace1to3_twoRightOnlyRowsHaveLeftFiller() {
        let lines = [del("a", 1), add("x", 1), add("y", 2), add("z", 3)]
        let rows = build(lines, [mapping(orig: (1, 2), mod: (1, 4))], .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .deletion), .line(display: 1, line: 1, .addition)),
            (.filler, .line(display: 2, line: 2, .addition)),
            (.filler, .line(display: 3, line: 3, .addition)),
        ])
    }

    @Test func replace3to1_twoLeftOnlyRowsHaveRightFiller() {
        let lines = [del("a", 1), del("b", 2), del("c", 3), add("x", 1)]
        let rows = build(lines, [mapping(orig: (1, 4), mod: (1, 2))], .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .deletion), .line(display: 3, line: 3, .addition)),
            (.line(display: 1, line: 1, .deletion), .filler),
            (.line(display: 2, line: 2, .deletion), .filler),
        ])
    }

    /// Mapping orig [2,5) -> mod [2,6) with inner changes
    ///   i1: orig 2:5-2:8  <-> mod 2:5-2:9
    ///   i2: orig 4:1-4:10 <-> mod 5:1-5:12
    /// Hand trace of computeRangeAlignment (innerHunkAlignment = true), last = (2,2), first = true:
    ///   i1 start cols > 1 -> emit(2,2): first=false, both ranges empty -> nothing.
    ///   i1 end col 8 < maxColumn(orig line 2) -> emit(2,2): equals last, not forced -> skipped.
    ///   i2 start col 1 -> no start alignment.
    ///   i2 end col 10 < maxColumn(orig line 4 = 15) -> emit(4,5): orig [2,4) / mod [2,5).
    ///   forced emit(5,6): orig [4,5) / mod [5,6).
    /// Group 1: 2 orig vs 3 mod lines -> one left filler; group 2: 1:1.
    static let innerLines: [DiffLine] = [
        ctx("header", 1, 1),          // d0
        del("let alpha = 1", 2),      // d1
        del("b", 3),                  // d2
        del("returnValue(x)", 4),     // d3
        add("let alphaX = 1", 2),     // d4
        add("b", 3),                  // d5
        add("c", 4),                  // d6
        add("returnValue2(x)", 5),    // d7
        ctx("footer", 5, 6),          // d8
    ]
    static let innerChanges = [mapping(
        orig: (2, 5), mod: (2, 6),
        inner: [
            inner(orig: (2, 5, 2, 8), mod: (2, 5, 2, 9)),
            inner(orig: (4, 1, 4, 10), mod: (5, 1, 5, 12)),
        ]
    )]

    @Test func innerChanges_driveAlignment() {
        let rows = build(Self.innerLines, Self.innerChanges, .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.line(display: 1, line: 1, .deletion, inner: [NSRange(location: 5, length: 3)]),
             .line(display: 4, line: 4, .addition, inner: [NSRange(location: 5, length: 4)])),
            (.line(display: 2, line: 2, .deletion), .line(display: 5, line: 5, .addition)),
            (.filler, .line(display: 6, line: 6, .addition)),
            (.line(display: 3, line: 3, .deletion, inner: [NSRange(location: 1, length: 9)]),
             .line(display: 7, line: 7, .addition, inner: [NSRange(location: 1, length: 11)])),
            (.line(display: 8, line: 8, .context), .line(display: 8, line: 8, .context)),
        ])
    }

    @Test func emptyInnerRange_preservedAsZeroLength() {
        // orig line 3 "abcXdef", mod line 3 "abcdef": X deleted.
        // orig 3:4-3:5 <-> mod 3:4-3:4 (insertion point on the modified side).
        let lines = [ctx("a", 1, 1), ctx("b", 2, 2), del("abcXdef", 3), add("abcdef", 3)]
        let changes = [mapping(orig: (3, 4), mod: (3, 4),
                               inner: [inner(orig: (3, 4, 3, 5), mod: (3, 4, 3, 4))])]
        let rows = build(lines, changes, .sideBySide)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.line(display: 1, line: 1, .context), .line(display: 1, line: 1, .context)),
            (.line(display: 2, line: 2, .deletion, inner: [NSRange(location: 4, length: 1)]),
             .line(display: 3, line: 3, .addition, inner: [NSRange(location: 4, length: 0)])),
        ])
    }
}

// MARK: - Inline

@MainActor
@Suite("DiffRowBuilder inline")
struct DiffRowBuilderInlineTests {

    @Test func inline_oneCellPerRow_deletionsBeforeAdditions() {
        let rows = build(replace2to2Lines, replace2to2Changes, .inline)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .absent),
            (.line(display: 1, line: 1, .deletion), .absent),
            (.line(display: 2, line: 2, .deletion), .absent),
            (.line(display: 3, line: 3, .addition), .absent),
            (.line(display: 4, line: 4, .addition), .absent),
            (.line(display: 5, line: 5, .context), .absent),
        ])
    }

    @Test func inline_innerRangesAndNoFiller() {
        let rows = build(DiffRowBuilderSideBySideTests.innerLines,
                         DiffRowBuilderSideBySideTests.innerChanges, .inline)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .absent),
            (.line(display: 1, line: 1, .deletion, inner: [NSRange(location: 5, length: 3)]), .absent),
            (.line(display: 2, line: 2, .deletion), .absent),
            (.line(display: 3, line: 3, .deletion, inner: [NSRange(location: 1, length: 9)]), .absent),
            (.line(display: 4, line: 4, .addition, inner: [NSRange(location: 5, length: 4)]), .absent),
            (.line(display: 5, line: 5, .addition), .absent),
            (.line(display: 6, line: 6, .addition), .absent),
            (.line(display: 7, line: 7, .addition, inner: [NSRange(location: 1, length: 11)]), .absent),
            (.line(display: 8, line: 8, .context), .absent),
        ])
    }

    @Test func inline_pureInsert_isWholeLineChange() {
        let lines = [ctx("a", 1, 1), add("x", 2), add("y", 3)]
        let rows = build(lines, [mapping(orig: (2, 2), mod: (2, 4))], .inline)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .absent),
            (.line(display: 1, line: 1, .addition, whole: true), .absent),
            (.line(display: 2, line: 2, .addition, whole: true), .absent),
        ])
    }
}

// MARK: - Comment rows

@MainActor
@Suite("DiffRowBuilder comment rows")
struct DiffRowBuilderCommentTests {

    @Test func commentOnDeletion_leftCommentRightFiller() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 1, lineNumber: nil, oldLineNumber: 2, lineType: .deletion, text: "why")
        // display: 0 ctx, 1 del(l1), 2 comment, 3 del(l2), 4 add(l3), 5 add(l4), 6 ctx(l5)
        let rows = build(replace2to2Lines, replace2to2Changes, .sideBySide, store: store)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.line(display: 1, line: 1, .deletion), .line(display: 4, line: 3, .addition)),
            (.comment(display: 2), .filler),
            (.line(display: 3, line: 2, .deletion), .line(display: 5, line: 4, .addition)),
            (.line(display: 6, line: 5, .context), .line(display: 6, line: 5, .context)),
        ])
    }

    @Test func commentOnAddition_rightCommentLeftFiller() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 3, lineNumber: 2, oldLineNumber: nil, lineType: .addition, text: "ok")
        // display: 0 ctx, 1 del(l1), 2 del(l2), 3 add(l3), 4 comment, 5 add(l4), 6 ctx(l5)
        let rows = build(replace2to2Lines, replace2to2Changes, .sideBySide, store: store)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.line(display: 1, line: 1, .deletion), .line(display: 3, line: 3, .addition)),
            (.filler, .comment(display: 4)),
            (.line(display: 2, line: 2, .deletion), .line(display: 5, line: 4, .addition)),
            (.line(display: 6, line: 5, .context), .line(display: 6, line: 5, .context)),
        ])
    }

    @Test func commentOnContext_rendersOnRight() {
        let store = DiffReviewStore()
        store.addComment(lineIndex: 0, lineNumber: 1, oldLineNumber: 1, lineType: .context, text: "ctx")
        // display: 0 ctx, 1 comment, 2 del(l1), 3 del(l2), 4 add(l3), 5 add(l4), 6 ctx(l5)
        let rows = build(replace2to2Lines, replace2to2Changes, .sideBySide, store: store)
        expectRows(rows, [
            (.line(display: 0, line: 0, .context), .line(display: 0, line: 0, .context)),
            (.filler, .comment(display: 1)),
            (.line(display: 2, line: 1, .deletion), .line(display: 4, line: 3, .addition)),
            (.line(display: 3, line: 2, .deletion), .line(display: 5, line: 4, .addition)),
            (.line(display: 6, line: 5, .context), .line(display: 6, line: 5, .context)),
        ])
    }
}
