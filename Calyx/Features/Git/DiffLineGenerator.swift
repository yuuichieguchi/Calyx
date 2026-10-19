// DiffLineGenerator.swift
// Calyx
//
// Builds FileDiff.lines from both file sides and the DefaultLinesDiffComputer
// mappings: unchanged lines become context rows, each mapping emits its
// original lines as deletions followed by its modified lines as additions.

import Foundation

enum DiffLineGenerator {
    /// `changes` must be sorted, non-overlapping, and expressed in `content`'s line numbers.
    static func lines(content: DiffContent, changes: [DetailedLineRangeMapping]) -> [DiffLine] {
        var result: [DiffLine] = []
        result.reserveCapacity(max(content.oldLines.count, content.newLines.count))

        var oldLine = 1
        var newLine = 1

        func emitContext(untilOld oldEnd: Int, untilNew newEnd: Int) {
            assert(oldEnd - oldLine == newEnd - newLine, "unchanged ranges must have equal length")
            while oldLine < oldEnd && newLine < newEnd {
                result.append(contextLine(old: content.oldLines[oldLine - 1], new: content.newLines[newLine - 1],
                                          oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }

        for change in changes {
            emitContext(untilOld: change.original.startLineNumber, untilNew: change.modified.startLineNumber)

            for n in change.original.startLineNumber..<change.original.endLineNumberExclusive {
                result.append(DiffLine(type: .deletion, text: content.oldLines[n - 1],
                                       oldLineNumber: n, newLineNumber: nil))
            }
            for n in change.modified.startLineNumber..<change.modified.endLineNumberExclusive {
                result.append(DiffLine(type: .addition, text: content.newLines[n - 1],
                                       oldLineNumber: nil, newLineNumber: n))
            }
            oldLine = change.original.endLineNumberExclusive
            newLine = change.modified.endLineNumberExclusive
        }

        emitContext(untilOld: content.oldLines.count + 1, untilNew: content.newLines.count + 1)
        return result
    }

    static func uncomparedLines(content: DiffContent) -> [DiffLine] {
        let count = max(content.oldLines.count, content.newLines.count)
        var result: [DiffLine] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let old = index < content.oldLines.count ? content.oldLines[index] : nil
            let new = index < content.newLines.count ? content.newLines[index] : nil
            switch (old, new) {
            case let (old?, new?):
                result.append(contextLine(old: old, new: new, oldLineNumber: index + 1, newLineNumber: index + 1))
            case let (old?, nil):
                result.append(DiffLine(type: .context, text: old, oldLineNumber: index + 1, newLineNumber: nil))
            case let (nil, new?):
                result.append(DiffLine(type: .context, text: new, oldLineNumber: nil, newLineNumber: index + 1))
            case (nil, nil):
                preconditionFailure("index is below the longer side's count")
            }
        }
        return result
    }

    private static func contextLine(old: String, new: String, oldLineNumber: Int, newLineNumber: Int) -> DiffLine {
        let differs = !old.utf16.elementsEqual(new.utf16)
        return DiffLine(type: .context, text: old, oldLineNumber: oldLineNumber,
                        newLineNumber: newLineNumber, newText: differs ? new : nil)
    }
}
