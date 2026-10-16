// UnchangedRegions.swift
// Calyx
//
// Port of VS Code `UnchangedRegion.fromDiffs` (diffEditorViewModel.ts)
// plus `apply`, which collapses the hidden middle of each region in a
// built row list into one `.collapsedRegion` row.

import Foundation

enum UnchangedRegions {

    static func fromDiffs(changes: [DetailedLineRangeMapping], originalLineCount: Int, modifiedLineCount: Int,
                          minHiddenLineCount: Int = 3, minContext: Int = 3) -> [UnchangedRegion] {
        let inversed = DetailedLineRangeMapping.inverse(
            changes, originalLineCount: originalLineCount, modifiedLineCount: modifiedLineCount)
        var result: [UnchangedRegion] = []
        for mapping in inversed {
            var origStart = mapping.original.startLineNumber
            var modStart = mapping.modified.startLineNumber
            var length = mapping.original.length

            let atStart = origStart == 1 && modStart == 1
            let atEnd = origStart + length == originalLineCount + 1 && modStart + length == modifiedLineCount + 1

            if (atStart || atEnd) && length >= minContext + minHiddenLineCount {
                if atStart && !atEnd {
                    length -= minContext
                }
                if atEnd && !atStart {
                    origStart += minContext
                    modStart += minContext
                    length -= minContext
                }
                result.append(UnchangedRegion(originalLineNumber: origStart, modifiedLineNumber: modStart, lineCount: length))
            } else if length >= minContext * 2 + minHiddenLineCount {
                origStart += minContext
                modStart += minContext
                length -= minContext * 2
                result.append(UnchangedRegion(originalLineNumber: origStart, modifiedLineNumber: modStart, lineCount: length))
            }
        }
        return result
    }

    /// Replaces the hidden middle of each region (after `visibleLineCountTop`,
    /// before `visibleLineCountBottom`) with one row whose both cells are
    /// `.collapsedRegion`. Original line numbers are recovered by counting
    /// left-side context/deletion line cells from 1, so `rows` must cover
    /// the whole original file (as built from `DiffLineGenerator` output).
    /// A region with any cell whose displayIndex is in
    /// `forcedVisibleDisplayIndices` (between its first and last row) stays expanded.
    static func apply(rows: [DiffLayoutRow], regions: [UnchangedRegion], reveal: DiffRevealSnapshot,
                      forcedVisibleDisplayIndices: Set<Int>) -> [DiffLayoutRow] {
        guard !regions.isEmpty else { return rows }
        let replacements = replacements(rows: rows, regions: regions, reveal: reveal,
                                        forcedVisibleDisplayIndices: forcedVisibleDisplayIndices)
        return splice(rows: rows, replacements: replacements)
    }

    /// Same rows as `apply(rows:...)`, with the alignment blocks remapped:
    /// blocks before a collapsed range shift by the cumulative shrink, and
    /// the rows of a collapsed range become one singleton block.
    static func apply(layout: DiffRowLayout, regions: [UnchangedRegion], reveal: DiffRevealSnapshot,
                      forcedVisibleDisplayIndices: Set<Int>) -> DiffRowLayout {
        guard !regions.isEmpty else { return layout }
        let replacements = replacements(rows: layout.rows, regions: regions, reveal: reveal,
                                        forcedVisibleDisplayIndices: forcedVisibleDisplayIndices)
        let rows = splice(rows: layout.rows, replacements: replacements)

        // Old row index -> new row index, and whether the old row was replaced.
        var newIndex = [Int](repeating: 0, count: layout.rows.count)
        var replaced = [Bool](repeating: false, count: layout.rows.count)
        var shrink = 0
        var next = 0
        for replacement in replacements {
            for old in next..<replacement.range.lowerBound { newIndex[old] = old - shrink }
            let collapsed = replacement.range.lowerBound - shrink
            for old in replacement.range {
                newIndex[old] = collapsed
                replaced[old] = true
            }
            shrink += replacement.range.count - 1
            next = replacement.range.upperBound + 1
        }
        for old in next..<layout.rows.count { newIndex[old] = old - shrink }

        var blocks: [Range<Int>] = []
        var covered = 0
        for block in layout.blocks {
            let kept = block.filter { !replaced[$0] }
            if kept.isEmpty {
                // Fully inside a collapsed range: one block for the collapsed row.
                guard let first = block.first else { continue }
                let collapsed = newIndex[first]
                if collapsed >= covered {
                    blocks.append(collapsed..<(collapsed + 1))
                    covered = collapsed + 1
                }
                continue
            }
            assert(kept.count == block.count, "alignment block \(block) straddles a collapsed region")
            // Release builds clip a straddling block to its kept rows; any
            // collapsed row skipped by the clip becomes its own block.
            let lo = newIndex[kept[0]]
            let hi = newIndex[kept[kept.count - 1]] + 1
            while covered < lo {
                blocks.append(covered..<(covered + 1))
                covered += 1
            }
            blocks.append(max(lo, covered)..<hi)
            covered = hi
        }
        while covered < rows.count {
            blocks.append(covered..<(covered + 1))
            covered += 1
        }
        return DiffRowLayout(rows: rows, blocks: blocks)
    }

    private static func replacements(
        rows: [DiffLayoutRow], regions: [UnchangedRegion], reveal: DiffRevealSnapshot,
        forcedVisibleDisplayIndices: Set<Int>
    ) -> [(range: ClosedRange<Int>, row: DiffLayoutRow)] {

        // Original line number -> row index of its left context cell.
        var contextRowByOriginalLine: [Int: Int] = [:]
        var originalLine = 0
        for (index, row) in rows.enumerated() {
            guard let kind = row.left?.kind else { continue }
            switch kind {
            case .line(.context):
                originalLine += 1
                contextRowByOriginalLine[originalLine] = index
            case .line(.deletion):
                originalLine += 1
            default:
                break
            }
        }

        // Row ranges to replace, with their collapsed row.
        var replacements: [(range: ClosedRange<Int>, row: DiffLayoutRow)] = []
        for region in regions {
            let regionLines = region.originalLineNumber..<(region.originalLineNumber + region.lineCount)
            let regionRows = regionLines.compactMap { contextRowByOriginalLine[$0] }
            guard let firstRegionRow = regionRows.first, let lastRegionRow = regionRows.last else { continue }
            let isForced = rows[firstRegionRow...lastRegionRow].contains { row in
                [row.left, row.right].contains { cell in
                    cell?.displayIndex.map(forcedVisibleDisplayIndices.contains) == true
                }
            }
            if isForced { continue }

            let top = reveal.visibleLineCountTop(regionID: region.id)
            let bottom = reveal.visibleLineCountBottom(regionID: region.id)
            let hiddenCount = region.lineCount - top - bottom
            guard hiddenCount > 0 else { continue }
            let hiddenStart = region.originalLineNumber + top
            let hiddenRows = (hiddenStart..<(hiddenStart + hiddenCount)).compactMap { contextRowByOriginalLine[$0] }
            guard let firstHidden = hiddenRows.first, let lastHidden = hiddenRows.last else { continue }
            let cell = DiffCell(displayIndex: nil, lineIndex: nil,
                                kind: .collapsedRegion(regionID: region.id, hiddenCount: hiddenCount),
                                innerRanges: [], isWholeLineChange: false)
            replacements.append((firstHidden...lastHidden, DiffLayoutRow(left: cell, right: cell)))
        }

        replacements.sort { $0.range.lowerBound < $1.range.lowerBound }
        return replacements
    }

    private static func splice(rows: [DiffLayoutRow],
                               replacements: [(range: ClosedRange<Int>, row: DiffLayoutRow)]) -> [DiffLayoutRow] {
        var out: [DiffLayoutRow] = []
        out.reserveCapacity(rows.count)
        var next = 0
        for replacement in replacements {
            out.append(contentsOf: rows[next..<replacement.range.lowerBound])
            out.append(replacement.row)
            next = replacement.range.upperBound + 1
        }
        out.append(contentsOf: rows[next...])
        return out
    }
}
