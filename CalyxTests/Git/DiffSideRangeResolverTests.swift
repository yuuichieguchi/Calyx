// DiffSideRangeResolverTests.swift
// CalyxTests
//
// Tests for DiffSideRangeResolver: mapping a dragged row range on one side
// of the layout to a displayIndex range, composed with
// DiffReviewStore.resolveDisplayRange.

import Foundation
import Testing
@testable import Calyx

// MARK: - Helpers

private func lineCell(_ index: Int, _ type: DiffLineType) -> DiffCell {
    DiffCell(displayIndex: index, lineIndex: index, kind: .line(type), innerRanges: [], isWholeLineChange: false)
}

private func cell(_ kind: DiffCellKind, display: Int? = nil) -> DiffCell {
    DiffCell(displayIndex: display, lineIndex: nil, kind: kind, innerRanges: [], isWholeLineChange: false)
}

private let filler = cell(.filler)

/// display/line: 0 ctx, 1 del, 2 add, 3 add, 4 add, 5 ctx  (replace 1 -> 3)
private let replaceDiffLines: [DiffLine] = [
    DiffLine(type: .context, text: "a", oldLineNumber: 1, newLineNumber: 1),
    DiffLine(type: .deletion, text: "b", oldLineNumber: 2, newLineNumber: nil),
    DiffLine(type: .addition, text: "x", oldLineNumber: nil, newLineNumber: 2),
    DiffLine(type: .addition, text: "y", oldLineNumber: nil, newLineNumber: 3),
    DiffLine(type: .addition, text: "z", oldLineNumber: nil, newLineNumber: 4),
    DiffLine(type: .context, text: "c", oldLineNumber: 3, newLineNumber: 5),
]

private let replaceRows: [DiffLayoutRow] = [
    DiffLayoutRow(left: lineCell(0, .context), right: lineCell(0, .context)),
    DiffLayoutRow(left: lineCell(1, .deletion), right: lineCell(2, .addition)),
    DiffLayoutRow(left: filler, right: lineCell(3, .addition)),
    DiffLayoutRow(left: filler, right: lineCell(4, .addition)),
    DiffLayoutRow(left: lineCell(5, .context), right: lineCell(5, .context)),
]

private func pair(_ r: (start: Int, end: Int)?) -> [Int]? {
    r.map { [$0.start, $0.end] }
}

@Suite("DiffSideRangeResolver")
struct DiffSideRangeResolverTests {

    @Test func rightSide_fullRange() {
        #expect(pair(DiffSideRangeResolver.displayRange(rows: replaceRows, side: .right, startRow: 0, endRow: 4)) == [0, 5])
    }

    @Test func leftSide_skipsFillerInside() {
        #expect(pair(DiffSideRangeResolver.displayRange(rows: replaceRows, side: .left, startRow: 1, endRow: 4)) == [1, 5])
    }

    @Test func leftSide_dragEndingOnFiller_snapsBackToLastRealCell() {
        #expect(pair(DiffSideRangeResolver.displayRange(rows: replaceRows, side: .left, startRow: 0, endRow: 3)) == [0, 1])
    }

    @Test func leftSide_entirelyFiller_isNil() {
        #expect(DiffSideRangeResolver.displayRange(rows: replaceRows, side: .left, startRow: 2, endRow: 3) == nil)
    }

    @Test func singleRow_sameIndex() {
        #expect(pair(DiffSideRangeResolver.displayRange(rows: replaceRows, side: .right, startRow: 3, endRow: 3)) == [4, 4])
        #expect(pair(DiffSideRangeResolver.displayRange(rows: replaceRows, side: .left, startRow: 1, endRow: 1)) == [1, 1])
    }

    @Test func skipsCommentCollapsedAndBannerCells() {
        let rows: [DiffLayoutRow] = [
            DiffLayoutRow(left: lineCell(0, .context), right: lineCell(0, .context)),
            DiffLayoutRow(left: filler, right: cell(.comment, display: 1)),
            DiffLayoutRow(left: cell(.collapsedRegion(regionID: 3, hiddenCount: 4)),
                          right: cell(.collapsedRegion(regionID: 3, hiddenCount: 4))),
            DiffLayoutRow(left: cell(.banner), right: cell(.banner)),
            DiffLayoutRow(left: lineCell(2, .context), right: lineCell(2, .context)),
        ]
        #expect(DiffSideRangeResolver.displayRange(rows: rows, side: .right, startRow: 1, endRow: 3) == nil)
        #expect(pair(DiffSideRangeResolver.displayRange(rows: rows, side: .right, startRow: 0, endRow: 3)) == [0, 0])
        #expect(pair(DiffSideRangeResolver.displayRange(rows: rows, side: .right, startRow: 1, endRow: 4)) == [2, 2])
        #expect(pair(DiffSideRangeResolver.displayRange(rows: rows, side: .left, startRow: 0, endRow: 4)) == [0, 2])
    }

    @Test @MainActor func composedWithResolveDisplayRange_includesOtherSideDeletions() {
        let displayLines = DiffReviewStore().buildDisplayLines(from: replaceDiffLines)
        // Right side rows 0...1: context line 0 and addition at display 2.
        let range = DiffSideRangeResolver.displayRange(rows: replaceRows, side: .right, startRow: 0, endRow: 1)
        #expect(pair(range) == [0, 2])
        guard let range else { return }
        let flat = DiffReviewStore.resolveDisplayRange(
            startDisplayIdx: range.start, endDisplayIdx: range.end, displayLines: displayLines)
        // Flat lineIndex range 0...2 contains the left-side deletion at lineIndex 1.
        #expect(flat?.startOriginal == 0)
        #expect(flat?.endOriginal == 2)
    }
}
