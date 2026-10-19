import CoreGraphics
import Testing
@testable import Calyx

private func projection(_ breakOffsets: [Int]) -> DiffLineProjection {
    DiffLineProjection(breakOffsets: breakOffsets, breakOffsetsVisibleColumn: breakOffsets.map(Double.init),
                       wrappedTextIndentLength: 0)
}

private func geometry(_ projections: [DiffLineProjection?], pads: [CGFloat]? = nil) -> DiffRowGeometry {
    DiffRowGeometry(segmentCounts: projections.map { $0?.segmentCount ?? 1 },
                    pads: pads ?? Array(repeating: 0, count: projections.count), rowHeight: 10, topInset: 4)
}

@Suite
struct DiffStableViewportTests {

    private let wide: [DiffLineProjection?] = [nil, projection([10, 20, 25]), nil, projection([8, 16])]

    @Test func fixtureGeometry() {
        let g = geometry(wide)
        #expect((0..<4).map(g.rowTop) == [4, 14, 44, 54])
        #expect(g.documentHeight == 74)
    }

    @Test func capture_topAtZeroOrAbove_isNil() {
        #expect(DiffStableViewport.capture(scrollY: 0, geometry: geometry(wide), projections: wide) == nil)
        #expect(DiffStableViewport.capture(scrollY: -5, geometry: geometry(wide), projections: wide) == nil)
    }

    @Test func capture_unwrappedRow() {
        let start = DiffStableViewport.capture(scrollY: 6, geometry: geometry(wide), projections: wide)
        #expect(start == DiffViewportStart(row: 0, offset: 0, delta: 2))
    }

    @Test func capture_wrappedRowViewedMidLine() {
        let start = DiffStableViewport.capture(scrollY: 27, geometry: geometry(wide), projections: wide)
        #expect(start == DiffViewportStart(row: 1, offset: 10, delta: 3))
    }

    @Test func capture_exactlyAtSegmentBoundary() {
        #expect(DiffStableViewport.capture(scrollY: 24, geometry: geometry(wide), projections: wide)
                == DiffViewportStart(row: 1, offset: 10, delta: 0))
        #expect(DiffStableViewport.capture(scrollY: 34, geometry: geometry(wide), projections: wide)
                == DiffViewportStart(row: 1, offset: 20, delta: 0))
    }

    @Test func capture_insideThePadAfterARow_anchorsToTheNextRowLikeVSCode() throws {
        let before = geometry(wide, pads: [0, 6, 0, 0])
        let padTop = before.rowTop(1) + before.contentHeight(1)
        let y = padTop + 2
        let start = try #require(DiffStableViewport.capture(scrollY: y, geometry: before, projections: wide))
        #expect(start == DiffViewportStart(row: 2, offset: 0, delta: y - before.rowTop(2)))
        #expect(start.delta < 0)
        let after = geometry(wide, pads: [0, 18, 0, 0])
        let recovered = DiffStableViewport.recover(start, geometry: after, projections: wide)
        #expect(abs((after.rowTop(2) - recovered) - (before.rowTop(2) - y)) < 0.001,
                "the top stays the same distance above row 2: \(recovered) in \(after.rowTop(2))")
    }

    @Test func captureThenRecover_sameGeometry_isIdentity() throws {
        let g = geometry(wide, pads: [0, 6, 0, 0])
        var y: CGFloat = 0.5
        while y < g.documentHeight {
            let start = try #require(DiffStableViewport.capture(scrollY: y, geometry: g, projections: wide))
            #expect(abs(DiffStableViewport.recover(start, geometry: g, projections: wide) - y) < 0.001, "y \(y) -> \(start)")
            y += 0.5
        }
    }

    @Test func recover_afterNarrowing_offsetAtNewSegmentStart() {
        let narrow: [DiffLineProjection?] = [nil, projection([5, 10, 15, 20, 25]), nil, projection([4, 8, 12, 16])]
        let start = DiffViewportStart(row: 1, offset: 10, delta: 3)
        #expect(DiffStableViewport.recover(start, geometry: geometry(narrow), projections: narrow) == 37)
    }

    @Test func recover_afterNarrowing_offsetInsideNewSegment_thenRecaptureMovesToSegmentStart() throws {
        let narrow: [DiffLineProjection?] = [nil, projection([7, 14, 21, 25]), nil, projection([8, 16])]
        let start = DiffViewportStart(row: 1, offset: 10, delta: 3)
        let y = DiffStableViewport.recover(start, geometry: geometry(narrow), projections: narrow)
        #expect(y == 27)
        let recaptured = try #require(DiffStableViewport.capture(scrollY: y, geometry: geometry(narrow), projections: narrow))
        #expect(recaptured == DiffViewportStart(row: 1, offset: 7, delta: 3))
    }

    @Test func recover_afterWidening_rowNoLongerWraps() {
        let unwrapped: [DiffLineProjection?] = [nil, nil, nil, nil]
        let start = DiffViewportStart(row: 1, offset: 20, delta: 3)
        #expect(DiffStableViewport.recover(start, geometry: geometry(unwrapped), projections: unwrapped) == 17)
    }

    @Test func recover_rowThatStartsWrapping_offsetZeroStaysOnFirstSegment() {
        let wrapped: [DiffLineProjection?] = [projection([3, 6]), projection([10, 20, 25]), nil, projection([8, 16])]
        let start = DiffViewportStart(row: 0, offset: 0, delta: 2)
        #expect(DiffStableViewport.recover(start, geometry: geometry(wrapped), projections: wrapped) == 6)
    }

    @Test func recover_rowsAboveChangeHeight_followTheAnchor() {
        let narrow: [DiffLineProjection?] = [projection([3, 6, 9]), projection([5, 10, 15, 20, 25]), nil, projection([8, 16])]
        let start = DiffViewportStart(row: 3, offset: 8, delta: 4)
        let expected: CGFloat = 4 + 30 + 50 + 10 + 10 + 4
        #expect(DiffStableViewport.recover(start, geometry: geometry(narrow), projections: narrow) == expected)
    }

    @Test func narrowThenWiden_anchorAtLineStartIsStable() throws {
        let narrow: [DiffLineProjection?] = [nil, projection([7, 14, 21, 25]), nil, projection([4, 8, 12, 16])]
        let original = try #require(DiffStableViewport.capture(scrollY: 57, geometry: geometry(wide), projections: wide))
        #expect(original == DiffViewportStart(row: 3, offset: 0, delta: 3))
        let narrowY = DiffStableViewport.recover(original, geometry: geometry(narrow), projections: narrow)
        let expectedNarrowY: CGFloat = 4 + 10 + 40 + 10 + 3
        #expect(narrowY == expectedNarrowY)
        let again = try #require(DiffStableViewport.capture(scrollY: narrowY, geometry: geometry(narrow), projections: narrow))
        #expect(again == original)
        #expect(DiffStableViewport.recover(again, geometry: geometry(wide), projections: wide) == 57)
    }
}
