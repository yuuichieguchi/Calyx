// DiffOverviewRuler.swift
// Calyx
//
// Pure model of the diff overview ruler (VS Code overviewRulerFeature.ts):
// change zones as row-index ranges and the viewport slider rectangle.
// Row-based, so collapsed regions and filler alignment are reflected the
// way VS Code maps line ranges to view positions.

import CoreGraphics
import Foundation

struct DiffOverviewZones: Equatable, Sendable {
    /// Runs of rows whose original (left / inline) cell is a deletion.
    let original: [Range<Int>]
    /// Runs of rows whose modified (right, or inline) cell is an addition.
    let modified: [Range<Int>]
}

enum DiffOverviewRuler {
    /// VS Code `ONE_OVERVIEW_WIDTH`.
    static let columnWidth: CGFloat = 15
    /// VS Code `ENTIRE_DIFF_OVERVIEW_WIDTH`.
    static let width: CGFloat = 30
    static let minimumMarkHeight: CGFloat = 2

    static func zones(rows: [DiffLayoutRow]) -> DiffOverviewZones {
        DiffOverviewZones(
            original: runs(rows) { $0.left?.kind == .line(.deletion) },
            modified: runs(rows) { row in
                // Inline rows have no right cell; the single cell carries the type.
                (row.right ?? row.left)?.kind == .line(.addition)
            }
        )
    }

    /// Slider rect in top-left-origin ruler coordinates: row 0 at y = 0,
    /// row `rowCount` at y = `height`.
    static func viewport(firstVisibleRow: Int, visibleRows: Int, rowCount: Int, height: CGFloat) -> CGRect {
        guard rowCount > 0 else { return .zero }
        let scale = height / CGFloat(rowCount)
        return CGRect(x: 0, y: CGFloat(firstVisibleRow) * scale,
                      width: width, height: CGFloat(visibleRows) * scale)
    }

    /// Pixel variant for variable row heights (word wrap): slider rect in
    /// top-left-origin ruler coordinates, document y 0 at y = 0 and
    /// `documentHeight` at y = `height`.
    static func viewport(visibleRect: CGRect, documentHeight: CGFloat, height: CGFloat) -> CGRect {
        guard documentHeight > 0 else { return .zero }
        let scale = height / documentHeight
        return CGRect(x: 0, y: visibleRect.minY * scale,
                      width: width, height: visibleRect.height * scale)
    }

    /// Index of the row containing document y: the last row whose top
    /// offset is <= y, clamped to 0...rowOffsets.count - 1.
    static func rowIndex(atDocumentY y: CGFloat, rowOffsets: [CGFloat]) -> Int {
        guard !rowOffsets.isEmpty else { return 0 }
        var lo = 0
        var hi = rowOffsets.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowOffsets[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    private static func runs(_ rows: [DiffLayoutRow], _ matches: (DiffLayoutRow) -> Bool) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        for (index, row) in rows.enumerated() {
            if matches(row) {
                if start == nil { start = index }
            } else if let s = start {
                result.append(s..<index)
                start = nil
            }
        }
        if let s = start { result.append(s..<rows.count) }
        return result
    }
}
