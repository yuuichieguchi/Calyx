// DiffTextRange.swift
// Calyx
//
// Port of src/vs/editor/common/core/position.ts and core/range.ts (subset
// used by the diff computer), microsoft/vscode
// c2c46e750ab7afe355bad8bea20a248520adfdb0. Named DiffTextPosition / DiffTextRange
// to avoid clashing with Swift's Range. Columns are 1-based UTF-16 code
// unit offsets, matching JavaScript string semantics.

import Foundation

struct DiffTextPosition: Equatable, Hashable, Sendable {
    /// JavaScript's Number.MAX_SAFE_INTEGER.
    static let maxSafeInteger = 9_007_199_254_740_991

    let lineNumber: Int
    let column: Int

    init(lineNumber: Int, column: Int) {
        self.lineNumber = lineNumber
        self.column = column
    }

    /// True if this position is strictly before `other`.
    func isBefore(_ other: DiffTextPosition) -> Bool {
        DiffTextPosition.isBefore(self, other)
    }

    static func isBefore(_ a: DiffTextPosition, _ b: DiffTextPosition) -> Bool {
        if a.lineNumber < b.lineNumber {
            return true
        }
        if b.lineNumber < a.lineNumber {
            return false
        }
        return a.column < b.column
    }

    func isBeforeOrEqual(_ other: DiffTextPosition) -> Bool {
        if lineNumber < other.lineNumber {
            return true
        }
        if other.lineNumber < lineNumber {
            return false
        }
        return column <= other.column
    }
}

struct DiffTextRange: Equatable, Hashable, Sendable {
    let startLineNumber: Int
    let startColumn: Int
    let endLineNumber: Int
    let endColumn: Int

    /// Like range.ts, swaps start and end if start is after end.
    init(startLineNumber: Int, startColumn: Int, endLineNumber: Int, endColumn: Int) {
        if startLineNumber > endLineNumber || (startLineNumber == endLineNumber && startColumn > endColumn) {
            self.startLineNumber = endLineNumber
            self.startColumn = endColumn
            self.endLineNumber = startLineNumber
            self.endColumn = startColumn
        } else {
            self.startLineNumber = startLineNumber
            self.startColumn = startColumn
            self.endLineNumber = endLineNumber
            self.endColumn = endColumn
        }
    }

    static func fromPositions(_ start: DiffTextPosition, _ end: DiffTextPosition? = nil) -> DiffTextRange {
        let e = end ?? start
        return DiffTextRange(startLineNumber: start.lineNumber, startColumn: start.column,
                         endLineNumber: e.lineNumber, endColumn: e.column)
    }

    var isEmpty: Bool {
        startLineNumber == endLineNumber && startColumn == endColumn
    }

    func getStartPosition() -> DiffTextPosition {
        DiffTextPosition(lineNumber: startLineNumber, column: startColumn)
    }

    func getEndPosition() -> DiffTextPosition {
        DiffTextPosition(lineNumber: endLineNumber, column: endColumn)
    }

    /// The smallest range containing both ranges.
    func plusRange(_ range: DiffTextRange) -> DiffTextRange {
        DiffTextRange.plusRange(self, range)
    }

    static func plusRange(_ a: DiffTextRange, _ b: DiffTextRange) -> DiffTextRange {
        let startLineNumber: Int
        let startColumn: Int
        let endLineNumber: Int
        let endColumn: Int

        if b.startLineNumber < a.startLineNumber {
            startLineNumber = b.startLineNumber
            startColumn = b.startColumn
        } else if b.startLineNumber == a.startLineNumber {
            startLineNumber = b.startLineNumber
            startColumn = min(b.startColumn, a.startColumn)
        } else {
            startLineNumber = a.startLineNumber
            startColumn = a.startColumn
        }

        if b.endLineNumber > a.endLineNumber {
            endLineNumber = b.endLineNumber
            endColumn = b.endColumn
        } else if b.endLineNumber == a.endLineNumber {
            endLineNumber = b.endLineNumber
            endColumn = max(b.endColumn, a.endColumn)
        } else {
            endLineNumber = a.endLineNumber
            endColumn = a.endColumn
        }

        return DiffTextRange(startLineNumber: startLineNumber, startColumn: startColumn,
                         endLineNumber: endLineNumber, endColumn: endColumn)
    }
}
