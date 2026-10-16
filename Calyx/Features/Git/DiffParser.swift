// DiffParser.swift
// Calyx
//
// Turns full-context unified diff output into a FileDiff: reconstructs both
// file sides (DiffContent), computes the diff with the VS Code port
// (DefaultLinesDiffComputer) and generates the rows (DiffLineGenerator).

import Foundation

enum DiffParser {
    static func parse(_ raw: String, path: String, options: LinesDiffOptions = LinesDiffOptions(),
                      wrapTimeout: (any DiffTimeout) -> any DiffTimeout = { $0 }) -> FileDiff {
        let content = DiffContent.extract(from: raw)
        if content.isBinary {
            return FileDiff(path: path, lines: [], isBinary: true, isTruncated: false)
        }

        let result = DefaultLinesDiffComputer().computeDiff(
            originalLines: content.oldLines,
            modifiedLines: content.newLines,
            options: options,
            wrapTimeout: wrapTimeout
        )
        let changes = changesInFileLineNumbers(result.changes, content: content)

        return FileDiff(
            path: path,
            lines: DiffLineGenerator.lines(content: content, changes: changes),
            isBinary: false,
            isTruncated: false,
            changes: changes,
            oldLineCount: content.oldLines.count,
            newLineCount: content.newLines.count,
            hitTimeout: result.hitTimeout
        )
    }

    /// Maps the computer's result back to `content`'s line numbering. The computer
    /// models an empty side as one empty line (`[""]`), so an empty file and a file
    /// holding a single blank line compare equal there; that case is restored here
    /// as one mapping covering both sides, shaped like the computer's own
    /// empty-side special case.
    private static func changesInFileLineNumbers(_ changes: [DetailedLineRangeMapping], content: DiffContent) -> [DetailedLineRangeMapping] {
        if changes.isEmpty && content.oldLines.isEmpty != content.newLines.isEmpty {
            let origin = DiffTextRange(startLineNumber: 1, startColumn: 1, endLineNumber: 1, endColumn: 1)
            return [DetailedLineRangeMapping(
                original: LineRange(startLineNumber: 1, endLineNumberExclusive: content.oldLines.count + 1),
                modified: LineRange(startLineNumber: 1, endLineNumberExclusive: content.newLines.count + 1),
                innerChanges: [RangeMapping(originalRange: origin, modifiedRange: origin)]
            )]
        }
        return changes.map { collapseMissingSide($0, content: content) }
    }

    /// The computer models an empty side as one empty line (`[""]`, as VS Code
    /// text models do), so a mapping against it covers line 1. In the file's
    /// own numbering that side has no lines: collapse its range to `[1, 1)`.
    private static func collapseMissingSide(_ mapping: DetailedLineRangeMapping, content: DiffContent) -> DetailedLineRangeMapping {
        let emptyRange = LineRange(startLineNumber: 1, endLineNumberExclusive: 1)
        let original = content.oldLines.isEmpty ? emptyRange : mapping.original
        let modified = content.newLines.isEmpty ? emptyRange : mapping.modified
        if original == mapping.original && modified == mapping.modified {
            return mapping
        }
        return DetailedLineRangeMapping(original: original, modified: modified, innerChanges: mapping.innerChanges)
    }
}
