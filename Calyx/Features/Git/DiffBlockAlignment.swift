import CoreGraphics
import Foundation

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

    static func padding(blocks: [Range<Int>], leftHeights: [CGFloat], rightHeights: [CGFloat],
                        tolerance: CGFloat = 0.5) -> [Pad] {
        var pads: [Pad] = []
        leftHeights.withUnsafeBufferPointer { leftHeights in
            rightHeights.withUnsafeBufferPointer { rightHeights in
                for block in blocks where !block.isEmpty {
                    precondition(block.lowerBound >= 0 && block.upperBound <= leftHeights.count
                                 && block.upperBound <= rightHeights.count,
                                 "every block lies within both sides' rows")
                    var left: CGFloat = 0
                    var right: CGFloat = 0
                    var row = block.lowerBound
                    while row < block.upperBound {
                        left += leftHeights[row]
                        right += rightHeights[row]
                        row += 1
                    }
                    let diff = left - right
                    guard abs(diff) > tolerance else { continue }
                    pads.append(Pad(row: block.upperBound - 1, side: diff > 0 ? .right : .left, pad: abs(diff)))
                }
            }
        }
        return pads
    }
}
