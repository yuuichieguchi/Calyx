// LineRange.swift
// Calyx
//
// Port of src/vs/editor/common/core/ranges/lineRange.ts (subset used by the
// diff computer), microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0.

import Foundation

/// A range of lines (1-based). `endLineNumberExclusive` is exclusive.
struct LineRange: Equatable, Hashable, Sendable {
    let startLineNumber: Int
    let endLineNumberExclusive: Int

    static func fromRangeInclusive(_ range: DiffTextRange) -> LineRange {
        LineRange(startLineNumber: range.startLineNumber, endLineNumberExclusive: range.endLineNumber + 1)
    }

    static func join(_ lineRanges: [LineRange]) -> LineRange {
        precondition(!lineRanges.isEmpty, "lineRanges cannot be empty")
        var startLineNumber = lineRanges[0].startLineNumber
        var endLineNumberExclusive = lineRanges[0].endLineNumberExclusive
        for range in lineRanges.dropFirst() {
            startLineNumber = min(startLineNumber, range.startLineNumber)
            endLineNumberExclusive = max(endLineNumberExclusive, range.endLineNumberExclusive)
        }
        return LineRange(startLineNumber: startLineNumber, endLineNumberExclusive: endLineNumberExclusive)
    }

    init(startLineNumber: Int, endLineNumberExclusive: Int) {
        precondition(
            startLineNumber <= endLineNumberExclusive,
            "startLineNumber \(startLineNumber) cannot be after endLineNumberExclusive \(endLineNumberExclusive)"
        )
        self.startLineNumber = startLineNumber
        self.endLineNumberExclusive = endLineNumberExclusive
    }

    var isEmpty: Bool { startLineNumber == endLineNumberExclusive }

    func delta(_ offset: Int) -> LineRange {
        LineRange(startLineNumber: startLineNumber + offset, endLineNumberExclusive: endLineNumberExclusive + offset)
    }

    var length: Int { endLineNumberExclusive - startLineNumber }

    func contains(_ lineNumber: Int) -> Bool {
        startLineNumber <= lineNumber && lineNumber < endLineNumberExclusive
    }

    func join(_ other: LineRange) -> LineRange {
        LineRange(
            startLineNumber: min(startLineNumber, other.startLineNumber),
            endLineNumberExclusive: max(endLineNumberExclusive, other.endLineNumberExclusive)
        )
    }

    /// nil if the ranges do not intersect or touch; empty if they only touch.
    func intersect(_ other: LineRange) -> LineRange? {
        let s = max(startLineNumber, other.startLineNumber)
        let e = min(endLineNumberExclusive, other.endLineNumberExclusive)
        if s <= e {
            return LineRange(startLineNumber: s, endLineNumberExclusive: e)
        }
        return nil
    }

    func intersectsOrTouches(_ other: LineRange) -> Bool {
        startLineNumber <= other.endLineNumberExclusive && other.startLineNumber <= endLineNumberExclusive
    }

    func toInclusiveRange() -> DiffTextRange? {
        if isEmpty {
            return nil
        }
        return DiffTextRange(
            startLineNumber: startLineNumber, startColumn: 1,
            endLineNumber: endLineNumberExclusive - 1, endColumn: DiffTextPosition.maxSafeInteger
        )
    }

    func toOffsetRange() -> OffsetRange {
        OffsetRange(start: startLineNumber - 1, endExclusive: endLineNumberExclusive - 1)
    }
}
