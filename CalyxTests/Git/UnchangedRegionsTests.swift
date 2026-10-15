// UnchangedRegionsTests.swift
// CalyxTests
//
// Tests for UnchangedRegions (port of VS Code UnchangedRegion.fromDiffs,
// diffEditorViewModel.ts), DiffRevealState and UnchangedRegions.apply.

import Foundation
import Testing
@testable import Calyx

// MARK: - Helpers

private func mapping(orig: (Int, Int), mod: (Int, Int)) -> DetailedLineRangeMapping {
    DetailedLineRangeMapping(
        original: LineRange(startLineNumber: orig.0, endLineNumberExclusive: orig.1),
        modified: LineRange(startLineNumber: mod.0, endLineNumberExclusive: mod.1),
        innerChanges: nil
    )
}

private func triples(_ regions: [UnchangedRegion]) -> [[Int]] {
    regions.map { [$0.originalLineNumber, $0.modifiedLineNumber, $0.lineCount] }
}

private func regions(_ changes: [DetailedLineRangeMapping], _ origCount: Int, _ modCount: Int) -> [[Int]] {
    triples(UnchangedRegions.fromDiffs(changes: changes, originalLineCount: origCount, modifiedLineCount: modCount))
}

// MARK: - fromDiffs

@Suite("UnchangedRegions.fromDiffs")
struct UnchangedRegionsFromDiffsTests {

    @Test func middleRun_trimmedByMinContextOnBothEnds() {
        // change1 orig [2,3) -> mod [2,4); middle orig [3,15) / mod [4,16) len 12;
        // change2 orig [15,16) -> mod [16,17); tail len 5 (< 6) not collapsed; head len 1.
        let result = regions([mapping(orig: (2, 3), mod: (2, 4)), mapping(orig: (15, 16), mod: (16, 17))], 20, 21)
        #expect(result == [[6, 7, 6]])
    }

    @Test func runAtFileStart_trimmedOnlyAtBottom() {
        // head orig/mod [1,10) len 9 -> (1,1,6); tail [11,13) len 2 dropped.
        #expect(regions([mapping(orig: (10, 11), mod: (10, 11))], 12, 12) == [[1, 1, 6]])
    }

    @Test func runAtFileEnd_trimmedOnlyAtTop() {
        // head len 1 dropped; tail [3,13) len 10 -> (6,6,7).
        #expect(regions([mapping(orig: (2, 3), mod: (2, 3))], 12, 12) == [[6, 6, 7]])
    }

    @Test func wholeFileUnchanged_notTrimmed() {
        #expect(regions([], 10, 10) == [[1, 1, 10]])
    }

    @Test func wholeFileUnchanged_shorterThanMinContextPlusMinHidden_notCollapsed() {
        #expect(regions([], 5, 5).isEmpty)
    }

    @Test func middleRunShorterThanTwiceContextPlusHidden_notCollapsed() {
        // middle [3,11) len 8 < 9 dropped; tail [12,21) len 9 at end -> (15,15,6).
        let result = regions([mapping(orig: (2, 3), mod: (2, 3)), mapping(orig: (11, 12), mod: (11, 12))], 20, 20)
        #expect(result == [[15, 15, 6]])
    }

    @Test func middleRunExactlyTwiceContextPlusHidden_collapsed() {
        // middle [3,12) len 9 -> (6,6,3); tail [13,15) len 2 dropped.
        let result = regions([mapping(orig: (2, 3), mod: (2, 3)), mapping(orig: (12, 13), mod: (12, 13))], 14, 14)
        #expect(result == [[6, 6, 3]])
    }
}

// MARK: - DiffRevealState

@MainActor
@Suite("DiffRevealState")
struct DiffRevealStateTests {

    private func makeState() -> DiffRevealState {
        let state = DiffRevealState()
        state.updateRegions([UnchangedRegion(originalLineNumber: 6, modifiedLineNumber: 6, lineCount: 50)])
        return state
    }

    @Test func initialCountsAreZero() {
        let state = makeState()
        #expect(state.visibleLineCountTop(regionID: 6) == 0)
        #expect(state.visibleLineCountBottom(regionID: 6) == 0)
    }

    @Test func showMoreAbove_addsCount_clampedToLineCount() {
        let state = makeState()
        state.showMoreAbove(regionID: 6, count: 20)
        #expect(state.visibleLineCountTop(regionID: 6) == 20)
        state.showMoreAbove(regionID: 6, count: 20)
        #expect(state.visibleLineCountTop(regionID: 6) == 40)
        state.showMoreAbove(regionID: 6, count: 20)
        #expect(state.visibleLineCountTop(regionID: 6) == 50)
    }

    @Test func showMoreBelow_clampedSoTopPlusBottomFitsLineCount() {
        let state = makeState()
        state.showMoreAbove(regionID: 6, count: 20)
        state.showMoreAbove(regionID: 6, count: 20)
        state.showMoreBelow(regionID: 6, count: 20)
        #expect(state.visibleLineCountTop(regionID: 6) == 40)
        #expect(state.visibleLineCountBottom(regionID: 6) == 10)
    }

    @Test func showMoreAbove_clampedAgainstExistingBottom() {
        let state = makeState()
        state.showMoreBelow(regionID: 6, count: 20)
        state.showMoreBelow(regionID: 6, count: 20)
        state.showMoreAbove(regionID: 6, count: 20)
        #expect(state.visibleLineCountBottom(regionID: 6) == 40)
        #expect(state.visibleLineCountTop(regionID: 6) == 10)
    }

    @Test func showAll_revealsEntireRegion() {
        let state = makeState()
        state.showMoreAbove(regionID: 6, count: 20)
        state.showAll(regionID: 6)
        #expect(state.visibleLineCountTop(regionID: 6) == 20)
        #expect(state.visibleLineCountBottom(regionID: 6) == 30)
    }

    @Test func collapseAll_resetsCounts() {
        let state = makeState()
        state.showMoreAbove(regionID: 6, count: 20)
        state.showMoreBelow(regionID: 6, count: 20)
        state.collapseAll()
        #expect(state.visibleLineCountTop(regionID: 6) == 0)
        #expect(state.visibleLineCountBottom(regionID: 6) == 0)
    }

    @Test func onChanged_firedOnEveryMutation() {
        let state = makeState()
        var count = 0
        state.onChanged = { count += 1 }
        state.showMoreAbove(regionID: 6, count: 20)
        #expect(count == 1)
        state.showMoreBelow(regionID: 6, count: 20)
        #expect(count == 2)
        state.showAll(regionID: 6)
        #expect(count == 3)
        state.collapseAll()
        #expect(count == 4)
    }
}

// MARK: - apply

@MainActor
@Suite("UnchangedRegions.apply")
struct UnchangedRegionsApplyTests {

    /// 20-line file, line 10 replaced 1:1.
    /// display 0-8 ctx lines 1-9, 9 del old10, 10 add new10, 11-20 ctx lines 11-20.
    /// Side-by-side rows: rows[0..8] ctx, rows[9] (d9,d10), rows[10..19] ctx d11..d20.
    /// Regions: head [1,10) len 9 -> (1,1,6); tail [11,21) len 10 -> (14,14,7).
    private struct Fixture {
        let rows: [DiffLayoutRow]
        let regions: [UnchangedRegion]
    }

    private func makeFixture() -> Fixture {
        var lines: [DiffLine] = []
        for n in 1...9 { lines.append(DiffLine(type: .context, text: " l\(n)", oldLineNumber: n, newLineNumber: n)) }
        lines.append(DiffLine(type: .deletion, text: "-old10", oldLineNumber: 10, newLineNumber: nil))
        lines.append(DiffLine(type: .addition, text: "+new10", oldLineNumber: nil, newLineNumber: 10))
        for n in 11...20 { lines.append(DiffLine(type: .context, text: " l\(n)", oldLineNumber: n, newLineNumber: n)) }
        let changes = [mapping(orig: (10, 11), mod: (10, 11))]
        let displayLines = DiffReviewStore().buildDisplayLines(from: lines)
        let rows = DiffRowBuilder.build(displayLines: displayLines, changes: changes, layout: .sideBySide)
        let regions = UnchangedRegions.fromDiffs(changes: changes, originalLineCount: 20, modifiedLineCount: 20)
        return Fixture(rows: rows, regions: regions)
    }

    private func expectCollapsed(_ row: DiffLayoutRow, regionID: Int, hidden: Int,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let kind = DiffCellKind.collapsedRegion(regionID: regionID, hiddenCount: hidden)
        #expect(row.left?.kind == kind, sourceLocation: sourceLocation)
        #expect(row.right?.kind == kind, sourceLocation: sourceLocation)
    }

    @Test func fixtureSanity() {
        let f = makeFixture()
        #expect(f.rows.count == 20)
        #expect(triples(f.regions) == [[1, 1, 6], [14, 14, 7]])
    }

    @Test func fullyCollapsed_oneCollapsedRowPerRegion() {
        let f = makeFixture()
        let state = DiffRevealState()
        state.updateRegions(f.regions)
        let out = UnchangedRegions.apply(rows: f.rows, regions: f.regions, reveal: state.snapshot,
                                         forcedVisibleDisplayIndices: [])
        #expect(out.count == 9)
        guard out.count == 9 else { return }
        expectCollapsed(out[0], regionID: 1, hidden: 6)
        #expect(Array(out[1...7]) == Array(f.rows[6...12]))
        expectCollapsed(out[8], regionID: 14, hidden: 7)
    }

    @Test func partiallyRevealed_keepsTopAndBottomLines() {
        let f = makeFixture()
        let state = DiffRevealState()
        state.updateRegions(f.regions)
        state.showMoreBelow(regionID: 1, count: 2)   // lines 5,6 visible
        state.showMoreAbove(regionID: 14, count: 2)  // lines 14,15 visible
        let out = UnchangedRegions.apply(rows: f.rows, regions: f.regions, reveal: state.snapshot,
                                         forcedVisibleDisplayIndices: [])
        #expect(out.count == 13)
        guard out.count == 13 else { return }
        expectCollapsed(out[0], regionID: 1, hidden: 4)
        #expect(Array(out[1...11]) == Array(f.rows[4...14]))
        expectCollapsed(out[12], regionID: 14, hidden: 5)
    }

    @Test func showAll_removesCollapsedRowForThatRegion() {
        let f = makeFixture()
        let state = DiffRevealState()
        state.updateRegions(f.regions)
        state.showAll(regionID: 14)
        let out = UnchangedRegions.apply(rows: f.rows, regions: f.regions, reveal: state.snapshot,
                                         forcedVisibleDisplayIndices: [])
        #expect(out.count == 15)
        guard out.count == 15 else { return }
        expectCollapsed(out[0], regionID: 1, hidden: 6)
        #expect(Array(out[1...14]) == Array(f.rows[6...19]))
    }

    @Test func forcedVisibleDisplayIndex_preventsCollapse() {
        let f = makeFixture()
        let state = DiffRevealState()
        state.updateRegions(f.regions)
        // display index 2 = line 3, inside region 1 (lines 1-6).
        let out = UnchangedRegions.apply(rows: f.rows, regions: f.regions, reveal: state.snapshot,
                                         forcedVisibleDisplayIndices: [2])
        #expect(out.count == 14)
        guard out.count == 14 else { return }
        #expect(Array(out[0...12]) == Array(f.rows[0...12]))
        expectCollapsed(out[13], regionID: 14, hidden: 7)
    }

    @Test func noRegions_rowsUnchanged() {
        let f = makeFixture()
        let out = UnchangedRegions.apply(rows: f.rows, regions: [], reveal: DiffRevealState().snapshot,
                                         forcedVisibleDisplayIndices: [])
        #expect(out == f.rows)
    }
}
