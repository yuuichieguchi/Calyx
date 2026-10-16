// DiffBlockAlignment.swift
// Calyx
//
// Row model with alignment blocks, and the per-block height padding that
// keeps both panes of a wrapped side-by-side diff aligned.

import CoreGraphics
import Foundation

/// Rows plus alignment blocks: ascending, contiguous row-index ranges that
/// partition `rows`. Each block's total height must match on both sides.
struct DiffRowLayout: Equatable, Sendable {
    var rows: [DiffLayoutRow]
    var blocks: [Range<Int>]
}

enum DiffBlockAlignment {
    struct Pad: Equatable {
        let row: Int
        let side: DiffSide
        let pad: CGFloat
    }

    /// Per block, compares the summed left and right heights; the shorter
    /// side's last row of the block gets the difference. Differences within
    /// `tolerance` produce no pad.
    static func padding(blocks: [Range<Int>], leftHeights: [CGFloat], rightHeights: [CGFloat],
                        tolerance: CGFloat = 0.5) -> [Pad] {
        var pads: [Pad] = []
        for block in blocks {
            guard let last = block.last else { continue }
            let left = block.reduce(CGFloat(0)) { $0 + leftHeights[$1] }
            let right = block.reduce(CGFloat(0)) { $0 + rightHeights[$1] }
            let diff = left - right
            guard abs(diff) > tolerance else { continue }
            pads.append(Pad(row: last, side: diff > 0 ? .right : .left, pad: abs(diff)))
        }
        return pads
    }
}
