import CoreGraphics

struct DiffRowGeometry: Equatable, Sendable {
    private(set) var segmentCounts: [Int]
    private(set) var pads: [CGFloat]
    let rowHeight: CGFloat
    let topInset: CGFloat
    private var tops: [CGFloat]

    init(segmentCounts: [Int], pads: [CGFloat], rowHeight: CGFloat, topInset: CGFloat) {
        precondition(segmentCounts.count == pads.count, "one pad per row")
        self.segmentCounts = segmentCounts
        self.pads = pads
        self.rowHeight = rowHeight
        self.topInset = topInset
        let count = segmentCounts.count
        self.tops = [CGFloat](unsafeUninitializedCapacity: count + 1) { buffer, initialized in
            segmentCounts.withUnsafeBufferPointer { counts in
                pads.withUnsafeBufferPointer { pads in
                    var top = topInset
                    buffer[0] = top
                    var index = 0
                    while index < count {
                        top += CGFloat(counts[index]) * rowHeight + pads[index]
                        index += 1
                        buffer[index] = top
                    }
                }
            }
            initialized = count + 1
        }
    }

    var rowCount: Int { segmentCounts.count }

    var documentHeight: CGFloat { tops[tops.count - 1] }

    func rowTop(_ row: Int) -> CGFloat { tops[row] }

    func rowBottom(_ row: Int) -> CGFloat { tops[row + 1] }

    func rowHeight(_ row: Int) -> CGFloat {
        CGFloat(segmentCounts[row]) * rowHeight + pads[row]
    }

    func contentHeight(_ row: Int) -> CGFloat {
        CGFloat(segmentCounts[row]) * rowHeight
    }

    func segmentTop(row: Int, segment: Int) -> CGFloat {
        tops[row] + CGFloat(segment) * rowHeight
    }

    func row(atY y: CGFloat) -> Int {
        guard rowCount > 0 else { return 0 }
        var lo = 0
        var hi = rowCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if tops[mid] <= y { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func segment(atY y: CGFloat) -> (row: Int, segment: Int) {
        let row = row(atY: y)
        guard rowCount > 0 else { return (row: 0, segment: 0) }
        let index = Int(((y - tops[row]) / rowHeight).rounded(.down))
        return (row: row, segment: min(max(index, 0), segmentCounts[row] - 1))
    }

    func rows(intersecting minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        guard rowCount > 0, maxY > minY, maxY > tops[0], minY < documentHeight else { return 0..<0 }
        let first = row(atY: minY)
        let candidate = row(atY: maxY)
        let last = tops[candidate] >= maxY ? candidate - 1 : candidate
        return first <= last ? first..<(last + 1) : 0..<0
    }
}
