// RangeMapping.swift
// Calyx
//
// Port of src/vs/editor/common/diff/rangeMapping.ts (subset used by the
// diff computer), microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0.
//
// TS `DetailedLineRangeMapping extends LineRangeMapping`; Swift structs
// cannot inherit, so the shared statics/methods are available on both.
// String lengths are UTF-16 code unit counts (JS `string.length`).

import Foundation

/// Maps a line range in the original text model to a line range in the modified text model.
struct LineRangeMapping: Equatable, Sendable {
    static func inverse(_ mapping: [LineRangeMapping], originalLineCount: Int, modifiedLineCount: Int) -> [LineRangeMapping] {
        lineRangeMappingInverse(mapping.map { ($0.original, $0.modified) },
                                originalLineCount: originalLineCount, modifiedLineCount: modifiedLineCount)
    }

    static func clip(_ mapping: [LineRangeMapping], originalRange: LineRange, modifiedRange: LineRange) -> [LineRangeMapping] {
        var result: [LineRangeMapping] = []
        for m in mapping {
            let original = m.original.intersect(originalRange)
            let modified = m.modified.intersect(modifiedRange)
            if let original, !original.isEmpty, let modified, !modified.isEmpty {
                result.append(LineRangeMapping(original: original, modified: modified))
            }
        }
        return result
    }

    /// The line range in the original text model.
    let original: LineRange
    /// The line range in the modified text model.
    let modified: LineRange

    init(original: LineRange, modified: LineRange) {
        self.original = original
        self.modified = modified
    }

    func flip() -> LineRangeMapping {
        LineRangeMapping(original: modified, modified: original)
    }

    func join(_ other: LineRangeMapping) -> LineRangeMapping {
        LineRangeMapping(original: original.join(other.original), modified: modified.join(other.modified))
    }

    var changedLineCount: Int {
        max(original.length, modified.length)
    }

    /// Assumes this mapping describes a valid diff (see rangeMapping.ts).
    func toRangeMapping() -> RangeMapping {
        if let origInclusiveRange = original.toInclusiveRange(), let modInclusiveRange = modified.toInclusiveRange() {
            return RangeMapping(originalRange: origInclusiveRange, modifiedRange: modInclusiveRange)
        } else if original.startLineNumber == 1 || modified.startLineNumber == 1 {
            // If one line range starts at 1, the other one must start at 1 as well.
            precondition(modified.startLineNumber == 1 && original.startLineNumber == 1, "not a valid diff")
            return RangeMapping(
                originalRange: DiffTextRange(startLineNumber: original.startLineNumber, startColumn: 1,
                                         endLineNumber: original.endLineNumberExclusive, endColumn: 1),
                modifiedRange: DiffTextRange(startLineNumber: modified.startLineNumber, startColumn: 1,
                                         endLineNumber: modified.endLineNumberExclusive, endColumn: 1)
            )
        } else {
            let maxCol = DiffTextPosition.maxSafeInteger
            return RangeMapping(
                originalRange: DiffTextRange(startLineNumber: original.startLineNumber - 1, startColumn: maxCol,
                                         endLineNumber: original.endLineNumberExclusive - 1, endColumn: maxCol),
                modifiedRange: DiffTextRange(startLineNumber: modified.startLineNumber - 1, startColumn: maxCol,
                                         endLineNumber: modified.endLineNumberExclusive - 1, endColumn: maxCol)
            )
        }
    }

    /// Assumes this mapping describes a valid diff (see rangeMapping.ts).
    func toRangeMapping2(_ originalLines: [String], _ modifiedLines: [String]) -> RangeMapping {
        if isValidLineNumber(original.endLineNumberExclusive, originalLines)
            && isValidLineNumber(modified.endLineNumberExclusive, modifiedLines) {
            return RangeMapping(
                originalRange: DiffTextRange(startLineNumber: original.startLineNumber, startColumn: 1,
                                         endLineNumber: original.endLineNumberExclusive, endColumn: 1),
                modifiedRange: DiffTextRange(startLineNumber: modified.startLineNumber, startColumn: 1,
                                         endLineNumber: modified.endLineNumberExclusive, endColumn: 1)
            )
        }

        let maxCol = DiffTextPosition.maxSafeInteger

        if !original.isEmpty && !modified.isEmpty {
            return RangeMapping(
                originalRange: DiffTextRange.fromPositions(
                    DiffTextPosition(lineNumber: original.startLineNumber, column: 1),
                    normalizePosition(DiffTextPosition(lineNumber: original.endLineNumberExclusive - 1, column: maxCol), originalLines)
                ),
                modifiedRange: DiffTextRange.fromPositions(
                    DiffTextPosition(lineNumber: modified.startLineNumber, column: 1),
                    normalizePosition(DiffTextPosition(lineNumber: modified.endLineNumberExclusive - 1, column: maxCol), modifiedLines)
                )
            )
        }

        if original.startLineNumber > 1 && modified.startLineNumber > 1 {
            return RangeMapping(
                originalRange: DiffTextRange.fromPositions(
                    normalizePosition(DiffTextPosition(lineNumber: original.startLineNumber - 1, column: maxCol), originalLines),
                    normalizePosition(DiffTextPosition(lineNumber: original.endLineNumberExclusive - 1, column: maxCol), originalLines)
                ),
                modifiedRange: DiffTextRange.fromPositions(
                    normalizePosition(DiffTextPosition(lineNumber: modified.startLineNumber - 1, column: maxCol), modifiedLines),
                    normalizePosition(DiffTextPosition(lineNumber: modified.endLineNumberExclusive - 1, column: maxCol), modifiedLines)
                )
            )
        }

        // One range is empty, one range touches the last line and one range starts at line 1.
        // rangeMapping.ts throws BugIndicatingError here.
        preconditionFailure("toRangeMapping2: invalid diff")
    }
}

private func lineRangeMappingInverse(
    _ mapping: [(original: LineRange, modified: LineRange)],
    originalLineCount: Int,
    modifiedLineCount: Int
) -> [LineRangeMapping] {
    var result: [LineRangeMapping] = []
    var lastOriginalEndLineNumber = 1
    var lastModifiedEndLineNumber = 1

    for m in mapping {
        let r = LineRangeMapping(
            original: LineRange(startLineNumber: lastOriginalEndLineNumber, endLineNumberExclusive: m.original.startLineNumber),
            modified: LineRange(startLineNumber: lastModifiedEndLineNumber, endLineNumberExclusive: m.modified.startLineNumber)
        )
        if !r.modified.isEmpty {
            result.append(r)
        }
        lastOriginalEndLineNumber = m.original.endLineNumberExclusive
        lastModifiedEndLineNumber = m.modified.endLineNumberExclusive
    }
    let r = LineRangeMapping(
        original: LineRange(startLineNumber: lastOriginalEndLineNumber, endLineNumberExclusive: originalLineCount + 1),
        modified: LineRange(startLineNumber: lastModifiedEndLineNumber, endLineNumberExclusive: modifiedLineCount + 1)
    )
    if !r.modified.isEmpty {
        result.append(r)
    }
    return result
}

private func normalizePosition(_ position: DiffTextPosition, _ content: [String]) -> DiffTextPosition {
    if position.lineNumber < 1 {
        return DiffTextPosition(lineNumber: 1, column: 1)
    }
    if position.lineNumber > content.count {
        return DiffTextPosition(lineNumber: content.count, column: content[content.count - 1].utf16.count + 1)
    }
    let line = content[position.lineNumber - 1]
    if position.column > line.utf16.count + 1 {
        return DiffTextPosition(lineNumber: position.lineNumber, column: line.utf16.count + 1)
    }
    return position
}

private func isValidLineNumber(_ lineNumber: Int, _ lines: [String]) -> Bool {
    lineNumber >= 1 && lineNumber <= lines.count
}

/// Maps a line range in the original text model to a line range in the modified text model.
/// Also contains inner range mappings.
struct DetailedLineRangeMapping: Equatable, Sendable {
    /// LineRangeMapping.inverse, inherited by DetailedLineRangeMapping in TS.
    static func inverse(_ mapping: [DetailedLineRangeMapping], originalLineCount: Int, modifiedLineCount: Int) -> [LineRangeMapping] {
        lineRangeMappingInverse(mapping.map { ($0.original, $0.modified) },
                                originalLineCount: originalLineCount, modifiedLineCount: modifiedLineCount)
    }

    static func fromRangeMappings(_ rangeMappings: [RangeMapping]) -> DetailedLineRangeMapping {
        let originalRange = LineRange.join(rangeMappings.map { LineRange.fromRangeInclusive($0.originalRange) })
        let modifiedRange = LineRange.join(rangeMappings.map { LineRange.fromRangeInclusive($0.modifiedRange) })
        return DetailedLineRangeMapping(original: originalRange, modified: modifiedRange, innerChanges: rangeMappings)
    }

    let original: LineRange
    let modified: LineRange

    /// nil if inner changes have not been computed; otherwise the character-level diff
    /// in this line range. Must not be an empty array.
    let innerChanges: [RangeMapping]?

    init(original: LineRange, modified: LineRange, innerChanges: [RangeMapping]?) {
        self.original = original
        self.modified = modified
        self.innerChanges = innerChanges
    }

    var lineRangeMapping: LineRangeMapping {
        LineRangeMapping(original: original, modified: modified)
    }

    var changedLineCount: Int {
        max(original.length, modified.length)
    }

    func flip() -> DetailedLineRangeMapping {
        DetailedLineRangeMapping(original: modified, modified: original, innerChanges: innerChanges?.map { $0.flip() })
    }

    func toRangeMapping() -> RangeMapping {
        lineRangeMapping.toRangeMapping()
    }

    func withInnerChangesFromLineRanges() -> DetailedLineRangeMapping {
        DetailedLineRangeMapping(original: original, modified: modified, innerChanges: [toRangeMapping()])
    }
}

/// Maps a range in the original text model to a range in the modified text model.
struct RangeMapping: Equatable, Sendable {
    static func join(_ rangeMappings: [RangeMapping]) -> RangeMapping {
        precondition(!rangeMappings.isEmpty, "Cannot join an empty list of range mappings")
        var result = rangeMappings[0]
        for mapping in rangeMappings.dropFirst() {
            result = result.join(mapping)
        }
        return result
    }

    let originalRange: DiffTextRange
    let modifiedRange: DiffTextRange

    init(originalRange: DiffTextRange, modifiedRange: DiffTextRange) {
        self.originalRange = originalRange
        self.modifiedRange = modifiedRange
    }

    func flip() -> RangeMapping {
        RangeMapping(originalRange: modifiedRange, modifiedRange: originalRange)
    }

    func join(_ other: RangeMapping) -> RangeMapping {
        RangeMapping(
            originalRange: originalRange.plusRange(other.originalRange),
            modifiedRange: modifiedRange.plusRange(other.modifiedRange)
        )
    }
}

/// Port of base/common/arrays.ts `groupAdjacentBy`.
func groupAdjacentBy<T>(_ items: [T], _ shouldBeGrouped: (T, T) -> Bool) -> [[T]] {
    var groups: [[T]] = []
    var currentGroup: [T]?
    var last: T?
    for item in items {
        if let l = last, shouldBeGrouped(l, item) {
            currentGroup?.append(item)
        } else {
            if let group = currentGroup {
                groups.append(group)
            }
            currentGroup = [item]
        }
        last = item
    }
    if let group = currentGroup {
        groups.append(group)
    }
    return groups
}

/// `originalLines` / `modifiedLines` stand in for TS `ArrayText` (only line lengths are read).
func lineRangeMappingFromRangeMappings(
    _ alignments: [RangeMapping],
    _ originalLines: [String],
    _ modifiedLines: [String],
    dontAssertStartLine: Bool = false
) -> [DetailedLineRangeMapping] {
    var changes: [DetailedLineRangeMapping] = []
    let groups = groupAdjacentBy(
        alignments.map { getLineRangeMapping($0, originalLines, modifiedLines) }
    ) { a1, a2 in
        a1.original.intersectsOrTouches(a2.original) || a1.modified.intersectsOrTouches(a2.modified)
    }
    for g in groups {
        let first = g[0]
        let last = g[g.count - 1]
        changes.append(DetailedLineRangeMapping(
            original: first.original.join(last.original),
            modified: first.modified.join(last.modified),
            innerChanges: g.map { $0.innerChanges![0] } // getLineRangeMapping always sets exactly one inner change.
        ))
    }

    assert({
        if !dontAssertStartLine, let firstChange = changes.first, let lastChange = changes.last {
            if firstChange.modified.startLineNumber != firstChange.original.startLineNumber {
                return false
            }
            // TextLength.lineCount is (line count - 1) for ArrayText.
            let modifiedLineCount = modifiedLines.count - 1
            let originalLineCount = originalLines.count - 1
            if modifiedLineCount - lastChange.modified.endLineNumberExclusive
                != originalLineCount - lastChange.original.endLineNumberExclusive {
                return false
            }
        }
        for i in changes.indices.dropFirst() {
            let m1 = changes[i - 1]
            let m2 = changes[i]
            let ok = m2.original.startLineNumber - m1.original.endLineNumberExclusive
                == m2.modified.startLineNumber - m1.modified.endLineNumberExclusive
                && m1.original.endLineNumberExclusive < m2.original.startLineNumber
                && m1.modified.endLineNumberExclusive < m2.modified.startLineNumber
            if !ok {
                return false
            }
        }
        return true
    }())

    return changes
}

func getLineRangeMapping(_ rangeMapping: RangeMapping, _ originalLines: [String], _ modifiedLines: [String]) -> DetailedLineRangeMapping {
    let lineStartDelta0 = 0
    var lineEndDelta = 0

    // original: ]xxx \n <- this line is not modified
    // modified: ]xx  \n
    if rangeMapping.modifiedRange.endColumn == 1 && rangeMapping.originalRange.endColumn == 1
        && rangeMapping.originalRange.startLineNumber + lineStartDelta0 <= rangeMapping.originalRange.endLineNumber
        && rangeMapping.modifiedRange.startLineNumber + lineStartDelta0 <= rangeMapping.modifiedRange.endLineNumber {
        // We can only do this if the range is not empty yet
        lineEndDelta = -1
    }

    var lineStartDelta = lineStartDelta0
    // original: xxx[ \n <- this line is not modified
    // modified: xxx[ \n
    if rangeMapping.modifiedRange.startColumn - 1 >= modifiedLines[rangeMapping.modifiedRange.startLineNumber - 1].utf16.count
        && rangeMapping.originalRange.startColumn - 1 >= originalLines[rangeMapping.originalRange.startLineNumber - 1].utf16.count
        && rangeMapping.originalRange.startLineNumber <= rangeMapping.originalRange.endLineNumber + lineEndDelta
        && rangeMapping.modifiedRange.startLineNumber <= rangeMapping.modifiedRange.endLineNumber + lineEndDelta {
        // We can only do this if the range is not empty yet
        lineStartDelta = 1
    }

    let originalLineRange = LineRange(
        startLineNumber: rangeMapping.originalRange.startLineNumber + lineStartDelta,
        endLineNumberExclusive: rangeMapping.originalRange.endLineNumber + 1 + lineEndDelta
    )
    let modifiedLineRange = LineRange(
        startLineNumber: rangeMapping.modifiedRange.startLineNumber + lineStartDelta,
        endLineNumberExclusive: rangeMapping.modifiedRange.endLineNumber + 1 + lineEndDelta
    )

    return DetailedLineRangeMapping(original: originalLineRange, modified: modifiedLineRange, innerChanges: [rangeMapping])
}
