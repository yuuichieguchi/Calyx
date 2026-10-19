// UnchangedRegionsBlockTests.swift
// CalyxTests
//
// UnchangedRegions.apply(layout:...) (plan addendum 2 §2): same rows as
// apply(rows:...), blocks remapped — blocks before a collapsed range shift
// by the cumulative shrink, a collapsed range becomes one singleton block.
// The 1:1 fixture mirrors UnchangedRegionsApplyTests.

import Foundation
import Testing
@testable import Calyx

private func mapping(orig: (Int, Int), mod: (Int, Int)) -> DetailedLineRangeMapping {
    DetailedLineRangeMapping(
        original: LineRange(startLineNumber: orig.0, endLineNumberExclusive: orig.1),
        modified: LineRange(startLineNumber: mod.0, endLineNumberExclusive: mod.1),
        innerChanges: nil
    )
}

private func singletons(_ count: Int) -> [Range<Int>] {
    (0..<count).map { $0..<($0 + 1) }
}

private struct Fixture {
    let layout: DiffRowLayout
    let regions: [UnchangedRegion]
}

/// 20-line file, line 10 replaced 1:1 (20 rows, all singleton blocks).
/// Regions: (1,1,6) and (14,14,7).
@MainActor
private func makeOneToOne() -> Fixture {
    var lines: [DiffLine] = []
    for n in 1...9 { lines.append(DiffLine(type: .context, text: "l\(n)", oldLineNumber: n, newLineNumber: n)) }
    lines.append(DiffLine(type: .deletion, text: "old10", oldLineNumber: 10, newLineNumber: nil))
    lines.append(DiffLine(type: .addition, text: "new10", oldLineNumber: nil, newLineNumber: 10))
    for n in 11...20 { lines.append(DiffLine(type: .context, text: "l\(n)", oldLineNumber: n, newLineNumber: n)) }
    let changes = [mapping(orig: (10, 11), mod: (10, 11))]
    let displayLines = DiffReviewStore().buildDisplayLines(from: lines)
    let layout = DiffRowBuilder.buildLayout(displayLines: displayLines, changes: changes, layout: .sideBySide)
    let regions = UnchangedRegions.fromDiffs(changes: changes, originalLineCount: 20, modifiedLineCount: 20)
    return Fixture(layout: layout, regions: regions)
}

/// orig 20 lines, mod 22: line 10 replaced by new lines 10-12 (1 -> 3).
/// Rows: 0-8 ctx (lines 1-9) | 9-11 change block | 12-21 ctx (orig 11-20 / mod 13-22).
/// Regions: head (1,1,6) hides rows 0-5; tail orig [11,21) len 10 at end -> (14,16,7).
@MainActor
private func makeOneToThree() -> Fixture {
    var lines: [DiffLine] = []
    for n in 1...9 { lines.append(DiffLine(type: .context, text: "l\(n)", oldLineNumber: n, newLineNumber: n)) }
    lines.append(DiffLine(type: .deletion, text: "old10", oldLineNumber: 10, newLineNumber: nil))
    for n in 10...12 { lines.append(DiffLine(type: .addition, text: "new\(n)", oldLineNumber: nil, newLineNumber: n)) }
    for n in 11...20 { lines.append(DiffLine(type: .context, text: "l\(n)", oldLineNumber: n, newLineNumber: n + 2)) }
    let changes = [mapping(orig: (10, 11), mod: (10, 13))]
    let displayLines = DiffReviewStore().buildDisplayLines(from: lines)
    let layout = DiffRowBuilder.buildLayout(displayLines: displayLines, changes: changes, layout: .sideBySide)
    let regions = UnchangedRegions.fromDiffs(changes: changes, originalLineCount: 20, modifiedLineCount: 22)
    return Fixture(layout: layout, regions: regions)
}

@MainActor
@Suite("UnchangedRegions.apply(layout:)")
struct UnchangedRegionsBlockTests {

    private func snapshot(_ regions: [UnchangedRegion], _ configure: (DiffRevealState) -> Void = { _ in }) -> DiffRevealSnapshot {
        let state = DiffRevealState()
        state.updateRegions(regions)
        configure(state)
        return state.snapshot
    }

    private func expectRowsMatch(_ f: Fixture, reveal: DiffRevealSnapshot, regions: [UnchangedRegion]? = nil,
                                 forced: Set<Int> = [], sourceLocation: SourceLocation = #_sourceLocation) -> DiffRowLayout {
        let regs = regions ?? f.regions
        let viaRows = UnchangedRegions.apply(rows: f.layout.rows, regions: regs, reveal: reveal,
                                             forcedVisibleDisplayIndices: forced)
        let viaLayout = UnchangedRegions.apply(layout: f.layout, regions: regs, reveal: reveal,
                                               forcedVisibleDisplayIndices: forced)
        #expect(viaLayout.rows == viaRows, sourceLocation: sourceLocation)
        return viaLayout
    }

    @Test func fixtureSanity() {
        let f = makeOneToOne()
        #expect(f.layout.rows.count == 20)
        #expect(f.layout.blocks == singletons(20))
        let g = makeOneToThree()
        #expect(g.layout.rows.count == 22)
        #expect(g.layout.blocks == singletons(9) + [9..<12] + (12..<22).map { $0..<($0 + 1) })
        #expect(g.regions.map { [$0.originalLineNumber, $0.modifiedLineNumber, $0.lineCount] } == [[1, 1, 6], [14, 16, 7]])
    }

    @Test func fullyCollapsed_nineSingletonBlocks() {
        let f = makeOneToOne()
        let out = expectRowsMatch(f, reveal: snapshot(f.regions))
        #expect(out.rows.count == 9)
        #expect(out.blocks == singletons(9))
    }

    @Test func partiallyRevealed_thirteenSingletonBlocks() {
        let f = makeOneToOne()
        let out = expectRowsMatch(f, reveal: snapshot(f.regions) {
            $0.showMoreBelow(regionID: 1, count: 2)
            $0.showMoreAbove(regionID: 14, count: 2)
        })
        #expect(out.rows.count == 13)
        #expect(out.blocks == singletons(13))
    }

    @Test func showAllOneRegion_rowsMatch_singletons() {
        let f = makeOneToOne()
        let out = expectRowsMatch(f, reveal: snapshot(f.regions) { $0.showAll(regionID: 14) })
        #expect(out.rows.count == 15)
        #expect(out.blocks == singletons(15))
    }

    @Test func forcedVisible_rowsMatch_singletons() {
        let f = makeOneToOne()
        let out = expectRowsMatch(f, reveal: snapshot(f.regions), forced: [2])
        #expect(out.rows.count == 14)
        #expect(out.blocks == singletons(14))
    }

    @Test func noRegions_layoutUnchanged() {
        let f = makeOneToOne()
        let out = expectRowsMatch(f, reveal: DiffRevealState().snapshot, regions: [])
        #expect(out == f.layout)
    }

    /// Head region hides rows 0-5 behind one collapsed row (shrink 5): the
    /// change block 9..<12 moves to 4..<7. Tail hides orig 14-20 (rows 15-21)
    /// behind one row: 1 + 3 + 3 + 3 + 1 = 11 rows.
    @Test func multiRowBlock_shiftsByCollapsedCount_keepsLength() {
        let g = makeOneToThree()
        let out = expectRowsMatch(g, reveal: snapshot(g.regions))
        #expect(out.rows.count == 11)
        #expect(out.blocks == singletons(4) + [4..<7] + [7..<8, 8..<9, 9..<10, 10..<11])
    }

    @Test func multiRowBlock_onlyTailCollapsed_blockUnmoved() {
        let g = makeOneToThree()
        let out = expectRowsMatch(g, reveal: snapshot(g.regions) { $0.showAll(regionID: 1) })
        // rows 0-14 kept, tail collapsed into one row: 16 rows.
        #expect(out.rows.count == 16)
        #expect(out.blocks == singletons(9) + [9..<12] + [12..<13, 13..<14, 14..<15, 15..<16])
    }
}
