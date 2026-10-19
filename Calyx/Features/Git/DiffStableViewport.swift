// Port of VS Code viewModelImpl.ts `_captureStableViewport` / `StableViewport` (MIT License,
// Copyright (c) Microsoft Corporation), pinned at c2c46e750ab7afe355bad8bea20a248520adfdb0.

import CoreGraphics

struct DiffViewportStart: Equatable, Sendable, CustomStringConvertible {
    let row: Int
    let offset: Int
    let delta: CGFloat

    var description: String { "row \(row) offset \(offset) delta \(delta)" }
}

enum DiffStableViewport {
    static func capture(scrollY: CGFloat, geometry: DiffRowGeometry,
                        projections: [DiffLineProjection?]) -> DiffViewportStart? {
        guard scrollY > 0, geometry.rowCount > 0 else { return nil }
        let containing = geometry.row(atY: scrollY)
        if containing + 1 < geometry.rowCount,
           scrollY >= geometry.rowTop(containing) + geometry.contentHeight(containing) {
            return DiffViewportStart(row: containing + 1, offset: 0, delta: scrollY - geometry.rowTop(containing + 1))
        }
        let (row, segment) = geometry.segment(atY: scrollY)
        guard segment > 0 else {
            return DiffViewportStart(row: row, offset: 0, delta: scrollY - geometry.segmentTop(row: row, segment: 0))
        }
        guard let projection = projections[row] else {
            preconditionFailure("row \(row) has \(segment + 1) segments but no projection")
        }
        let offset = projection.breakOffsets[segment - 1]
        return DiffViewportStart(row: row, offset: offset,
                                 delta: scrollY - geometry.segmentTop(row: row, segment: segment))
    }

    static func segment(containing offset: Int, in projection: DiffLineProjection?) -> Int {
        guard let projection else { return 0 }
        var segment = 0
        for index in 0..<(projection.breakOffsets.count - 1) where projection.breakOffsets[index] <= offset {
            segment = index + 1
        }
        return segment
    }

    static func recover(_ start: DiffViewportStart, geometry: DiffRowGeometry,
                        projections: [DiffLineProjection?]) -> CGFloat {
        guard geometry.rowCount > 0 else { return start.delta }
        let row = min(max(start.row, 0), geometry.rowCount - 1)
        let segment = segment(containing: start.offset, in: projections[row])
        return geometry.segmentTop(row: row, segment: segment) + start.delta
    }
}
