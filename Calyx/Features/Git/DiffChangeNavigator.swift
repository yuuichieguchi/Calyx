// DiffChangeNavigator.swift
// Calyx
//
// Port of the target selection in VS Code DiffEditorWidget.goToDiff
// (diffEditorWidget.ts): next = first mapping whose modified start is
// after the cursor line (wrapping to the first, and the first when the
// cursor is on the last line); previous = last mapping whose modified
// start is before the cursor line (wrapping to the last).

import Foundation

enum DiffChangeNavigator {
    enum Direction: Sendable {
        case next
        case previous
    }

    /// Index into `changes`, nil when there are no changes.
    static func target(changes: [DetailedLineRangeMapping], currentModifiedLine: Int,
                       modifiedLineCount: Int, direction: Direction) -> Int? {
        guard !changes.isEmpty else { return nil }
        switch direction {
        case .next:
            if modifiedLineCount == currentModifiedLine { return 0 }
            return changes.firstIndex { $0.modified.startLineNumber > currentModifiedLine } ?? 0
        case .previous:
            return changes.lastIndex { $0.modified.startLineNumber < currentModifiedLine } ?? changes.count - 1
        }
    }
}
