import CoreGraphics
import Testing
@testable import Calyx

@Suite
struct DiffRowGeometryTests {

    private let mixed = DiffRowGeometry(segmentCounts: [1, 3, 2, 1], pads: [0, 0, 5, 0], rowHeight: 10, topInset: 4)

    @Test func rowCountAndDocumentHeight() {
        #expect(mixed.rowCount == 4)
        #expect(mixed.documentHeight == 79)
    }

    @Test func rowTops_arePrefixSums() {
        #expect((0..<4).map(mixed.rowTop) == [4, 14, 44, 69])
    }

    @Test func rowHeights_includePadContentExcludesIt() {
        #expect((0..<4).map(mixed.rowHeight) == [10, 30, 25, 10])
        #expect((0..<4).map(mixed.contentHeight) == [10, 30, 20, 10])
    }

    @Test func rowAtY_boundariesAndClamping() {
        #expect(mixed.row(atY: -100) == 0)
        #expect(mixed.row(atY: 0) == 0)
        #expect(mixed.row(atY: 4) == 0)
        #expect(mixed.row(atY: 13.9) == 0)
        #expect(mixed.row(atY: 14) == 1)
        #expect(mixed.row(atY: 43.99) == 1)
        #expect(mixed.row(atY: 44) == 2)
        #expect(mixed.row(atY: 66) == 2, "a pad belongs to its row")
        #expect(mixed.row(atY: 69) == 3)
        #expect(mixed.row(atY: 78.9) == 3)
        #expect(mixed.row(atY: 79) == 3)
        #expect(mixed.row(atY: 10_000) == 3)
    }

    @Test func segmentTop() {
        #expect(mixed.segmentTop(row: 0, segment: 0) == 4)
        #expect(mixed.segmentTop(row: 1, segment: 0) == 14)
        #expect(mixed.segmentTop(row: 1, segment: 1) == 24)
        #expect(mixed.segmentTop(row: 1, segment: 2) == 34)
        #expect(mixed.segmentTop(row: 2, segment: 1) == 54)
        #expect(mixed.segmentTop(row: 3, segment: 0) == 69)
    }

    @Test func segmentAtY() {
        #expect(mixed.segment(atY: -3) == (row: 0, segment: 0))
        #expect(mixed.segment(atY: 9) == (row: 0, segment: 0))
        #expect(mixed.segment(atY: 23.9) == (row: 1, segment: 0))
        #expect(mixed.segment(atY: 24) == (row: 1, segment: 1))
        #expect(mixed.segment(atY: 34) == (row: 1, segment: 2))
        #expect(mixed.segment(atY: 43.9) == (row: 1, segment: 2))
        #expect(mixed.segment(atY: 54) == (row: 2, segment: 1))
        #expect(mixed.segment(atY: 66) == (row: 2, segment: 1), "the pad below a row's last segment belongs to that segment")
        #expect(mixed.segment(atY: 70) == (row: 3, segment: 0))
        #expect(mixed.segment(atY: 500) == (row: 3, segment: 0))
    }

    @Test func wrapOff_matchesFixedRowHeight() {
        let rowHeight: CGFloat = 14.5
        let geometry = DiffRowGeometry(segmentCounts: Array(repeating: 1, count: 1000),
                                       pads: Array(repeating: 0, count: 1000), rowHeight: rowHeight, topInset: 4)
        #expect(geometry.rowCount == 1000)
        #expect(geometry.documentHeight == 4 + 1000 * rowHeight)
        for i in [0, 1, 2, 499, 998, 999] {
            #expect(geometry.rowTop(i) == 4 + CGFloat(i) * rowHeight)
            #expect(geometry.rowHeight(i) == rowHeight)
            #expect(geometry.row(atY: 4 + CGFloat(i) * rowHeight + 1) == i)
        }
    }

    @Test func largeDocument_prefixSumsMatchNaiveSum() {
        let counts = (0..<3000).map { $0 % 10 == 0 ? 3 : 1 }
        let pads: [CGFloat] = (0..<3000).map { $0 % 97 == 0 ? 7 : 0 }
        let geometry = DiffRowGeometry(segmentCounts: counts, pads: pads, rowHeight: 10, topInset: 4)
        var top: CGFloat = 4
        for i in 0..<3000 {
            #expect(geometry.rowTop(i) == top)
            top += CGFloat(counts[i]) * 10 + pads[i]
        }
        #expect(geometry.documentHeight == top)
        #expect(geometry.row(atY: geometry.rowTop(2345) + 0.5) == 2345)
    }

    @Test func equatable() {
        #expect(mixed == DiffRowGeometry(segmentCounts: [1, 3, 2, 1], pads: [0, 0, 5, 0], rowHeight: 10, topInset: 4))
        #expect(mixed != DiffRowGeometry(segmentCounts: [1, 3, 2, 1], pads: [0, 0, 6, 0], rowHeight: 10, topInset: 4))
    }
}
