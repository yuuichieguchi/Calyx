// DiffOverviewRulerTests.swift
// CalyxTests
//
// DiffOverviewRuler (addendum 2026-10-16): change zones as row-index ranges
// (left .deletion runs -> original, right/inline .addition runs -> modified)
// and the viewport rectangle in ruler coordinates.

import Foundation
import CoreGraphics
import Testing
@testable import Calyx

private func ctx(_ text: String, _ old: Int, _ new: Int) -> DiffLine {
    DiffLine(type: .context, text: " " + text, oldLineNumber: old, newLineNumber: new)
}

private func del(_ text: String, _ old: Int) -> DiffLine {
    DiffLine(type: .deletion, text: "-" + text, oldLineNumber: old, newLineNumber: nil)
}

private func add(_ text: String, _ new: Int) -> DiffLine {
    DiffLine(type: .addition, text: "+" + text, oldLineNumber: nil, newLineNumber: new)
}

private func mapping(orig: (Int, Int), mod: (Int, Int)) -> DetailedLineRangeMapping {
    DetailedLineRangeMapping(
        original: LineRange(startLineNumber: orig.0, endLineNumberExclusive: orig.1),
        modified: LineRange(startLineNumber: mod.0, endLineNumberExclusive: mod.1),
        innerChanges: nil
    )
}

@MainActor
private func build(_ lines: [DiffLine], _ changes: [DetailedLineRangeMapping], _ layout: DiffLayout) -> [DiffLayoutRow] {
    let displayLines = DiffReviewStore().buildDisplayLines(from: lines)
    return DiffRowBuilder.build(displayLines: displayLines, changes: changes, layout: layout)
}

@MainActor
@Suite("DiffOverviewRuler.zones")
struct DiffOverviewRulerZonesTests {

    @Test func emptyRows_emptyZones() {
        #expect(DiffOverviewRuler.zones(rows: []) == DiffOverviewZones(original: [], modified: []))
    }

    @Test func contextOnly_noZones() {
        let rows = build([ctx("a", 1, 1), ctx("b", 2, 2)], [], .sideBySide)
        #expect(DiffOverviewRuler.zones(rows: rows) == DiffOverviewZones(original: [], modified: []))
    }

    /// rows: 0 ctx | 1 (filler, +x) | 2 ctx
    @Test func pureInsert_modifiedOnly() {
        let rows = build([ctx("a", 1, 1), add("x", 2), ctx("b", 2, 3)],
                         [mapping(orig: (2, 2), mod: (2, 3))], .sideBySide)
        #expect(rows.count == 3)
        #expect(DiffOverviewRuler.zones(rows: rows) == DiffOverviewZones(original: [], modified: [1..<2]))
    }

    /// rows: 0 ctx | 1 (-x, filler) | 2 ctx
    @Test func pureDelete_originalOnly() {
        let rows = build([ctx("a", 1, 1), del("x", 2), ctx("b", 3, 2)],
                         [mapping(orig: (2, 3), mod: (2, 2))], .sideBySide)
        #expect(rows.count == 3)
        #expect(DiffOverviewRuler.zones(rows: rows) == DiffOverviewZones(original: [1..<2], modified: []))
    }

    /// rows: 0 ctx | 1 (-b,+B) | 2 (-c,+C) | 3 (filler,+D) | 4 ctx
    @Test func replace2to3_sideBySide() {
        let lines = [ctx("a", 1, 1), del("b", 2), del("c", 3), add("B", 2), add("C", 3), add("D", 4), ctx("d", 4, 5)]
        let rows = build(lines, [mapping(orig: (2, 4), mod: (2, 5))], .sideBySide)
        #expect(rows.count == 5)
        #expect(DiffOverviewRuler.zones(rows: rows) == DiffOverviewZones(original: [1..<3], modified: [1..<4]))
    }

    /// Inline rows: 0 ctx | 1 -b | 2 -c | 3 +B | 4 +C | 5 +D | 6 ctx
    @Test func replace2to3_inline() {
        let lines = [ctx("a", 1, 1), del("b", 2), del("c", 3), add("B", 2), add("C", 3), add("D", 4), ctx("d", 4, 5)]
        let rows = build(lines, [mapping(orig: (2, 4), mod: (2, 5))], .inline)
        #expect(rows.count == 7)
        #expect(DiffOverviewRuler.zones(rows: rows) == DiffOverviewZones(original: [1..<3], modified: [3..<6]))
    }

    /// rows: 0 ctx a | 1 (-b,+B) | 2 ctx c | 3 ctx d | 4 (filler,+e) | 5 ctx f
    @Test func twoMappings_separateRuns() {
        let lines = [ctx("a", 1, 1), del("b", 2), add("B", 2), ctx("c", 3, 3), ctx("d", 4, 4), add("e", 5), ctx("f", 5, 6)]
        let rows = build(lines, [mapping(orig: (2, 3), mod: (2, 3)), mapping(orig: (5, 5), mod: (5, 6))], .sideBySide)
        #expect(rows.count == 6)
        #expect(DiffOverviewRuler.zones(rows: rows) == DiffOverviewZones(original: [1..<2], modified: [1..<2, 4..<5]))
    }

    /// 20-line file, line 10 replaced 1:1 (same fixture as UnchangedRegionsApplyTests).
    /// Uncollapsed: change at row 9. Collapsed: out[0] = region 1, out[1...7] = rows[6...12],
    /// so the change row moves to index 4.
    @Test func collapsedUnchangedRegions_zonesShiftUp() {
        var lines: [DiffLine] = []
        for n in 1...9 { lines.append(ctx("l\(n)", n, n)) }
        lines.append(del("old10", 10))
        lines.append(add("new10", 10))
        for n in 11...20 { lines.append(ctx("l\(n)", n, n)) }
        let changes = [mapping(orig: (10, 11), mod: (10, 11))]
        let rows = build(lines, changes, .sideBySide)
        #expect(DiffOverviewRuler.zones(rows: rows) == DiffOverviewZones(original: [9..<10], modified: [9..<10]))

        let regions = UnchangedRegions.fromDiffs(changes: changes, originalLineCount: 20, modifiedLineCount: 20)
        let state = DiffRevealState()
        state.updateRegions(regions)
        let collapsed = UnchangedRegions.apply(rows: rows, regions: regions, reveal: state.snapshot,
                                               forcedVisibleDisplayIndices: [])
        #expect(collapsed.count == 9)
        #expect(DiffOverviewRuler.zones(rows: collapsed) == DiffOverviewZones(original: [4..<5], modified: [4..<5]))
    }
}

@Suite("DiffOverviewRuler.viewport")
struct DiffOverviewRulerViewportTests {

    /// Coordinate convention: top-left origin (flipped view); y grows downward,
    /// row 0 maps to y = 0 and row `rowCount` maps to y = `height`.
    /// 100 rows in 200 pt -> 2 pt/row: first visible row 25 -> y 50; 10 rows -> 20 pt.
    @Test func viewport_proportionalTopLeftOrigin() {
        let rect = DiffOverviewRuler.viewport(firstVisibleRow: 25, visibleRows: 10, rowCount: 100, height: 200)
        #expect(rect.minY == 50)
        #expect(rect.height == 20)
    }

    @Test func viewport_atTop_startsAtZero() {
        let rect = DiffOverviewRuler.viewport(firstVisibleRow: 0, visibleRows: 10, rowCount: 100, height: 200)
        #expect(rect.minY == 0)
        #expect(rect.height == 20)
    }
}
