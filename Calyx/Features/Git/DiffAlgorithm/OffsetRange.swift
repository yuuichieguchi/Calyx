// OffsetRange.swift
// Calyx
//
// Port of src/vs/editor/common/core/ranges/offsetRange.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).

import Foundation

/// A range of offsets (0-based). `start` is inclusive, `endExclusive` is exclusive.
struct OffsetRange: Equatable, Hashable, Sendable {
    let start: Int
    let endExclusive: Int

    static func ofLength(_ length: Int) -> OffsetRange {
        OffsetRange(start: 0, endExclusive: length)
    }

    static func ofStartAndLength(_ start: Int, _ length: Int) -> OffsetRange {
        OffsetRange(start: start, endExclusive: start + length)
    }

    init(start: Int, endExclusive: Int) {
        // offsetRange.ts throws BugIndicatingError for start > endExclusive.
        precondition(start <= endExclusive, "Invalid range: [\(start), \(endExclusive))")
        self.start = start
        self.endExclusive = endExclusive
    }

    var isEmpty: Bool { start == endExclusive }

    func delta(_ offset: Int) -> OffsetRange {
        OffsetRange(start: start + offset, endExclusive: endExclusive + offset)
    }

    func deltaStart(_ offset: Int) -> OffsetRange {
        OffsetRange(start: start + offset, endExclusive: endExclusive)
    }

    func deltaEnd(_ offset: Int) -> OffsetRange {
        OffsetRange(start: start, endExclusive: endExclusive + offset)
    }

    var length: Int { endExclusive - start }

    func containsRange(_ other: OffsetRange) -> Bool {
        start <= other.start && other.endExclusive <= endExclusive
    }

    func contains(_ offset: Int) -> Bool {
        start <= offset && offset < endExclusive
    }

    /// The smallest range that contains both ranges.
    func join(_ other: OffsetRange) -> OffsetRange {
        OffsetRange(start: min(start, other.start), endExclusive: max(endExclusive, other.endExclusive))
    }

    /// Empty if the ranges touch but do not intersect; nil if they do not even touch.
    func intersect(_ other: OffsetRange) -> OffsetRange? {
        let s = max(start, other.start)
        let e = min(endExclusive, other.endExclusive)
        if s <= e {
            return OffsetRange(start: s, endExclusive: e)
        }
        return nil
    }

    func intersectionLength(_ range: OffsetRange) -> Int {
        let s = max(start, range.start)
        let e = min(endExclusive, range.endExclusive)
        return max(0, e - s)
    }

    /// Always false if one range is empty.
    func intersects(_ other: OffsetRange) -> Bool {
        let s = max(start, other.start)
        let e = min(endExclusive, other.endExclusive)
        return s < e
    }

    func intersectsOrTouches(_ other: OffsetRange) -> Bool {
        let s = max(start, other.start)
        let e = min(endExclusive, other.endExclusive)
        return s <= e
    }
}
