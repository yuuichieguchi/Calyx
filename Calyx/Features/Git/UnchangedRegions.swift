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
