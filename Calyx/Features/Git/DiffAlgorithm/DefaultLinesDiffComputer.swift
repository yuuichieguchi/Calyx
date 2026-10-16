// DefaultLinesDiffComputer.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0), without computeMoves.
// String lengths and columns are UTF-16 code units, matching JS.

import Foundation

struct DefaultLinesDiffComputer {
    private let dynamicProgrammingDiffing = DynamicProgrammingDiffing()
    private let myersDiffingAlgorithm = MyersDiffAlgorithm()

    /// `[]` is treated as `[""]`: a VS Code text model always has at least one line.
    /// `wrapTimeout` wraps the timeout built from `options.maxComputationTimeMs`
    /// (e.g. to also stop on task cancellation).
    func computeDiff(originalLines originalInput: [String], modifiedLines modifiedInput: [String], options: LinesDiffOptions,
                     wrapTimeout: (any DiffTimeout) -> any DiffTimeout = { $0 }) -> LinesDiff {
        let originalLines = originalInput.isEmpty ? [""] : originalInput
        let modifiedLines = modifiedInput.isEmpty ? [""] : modifiedInput

        if originalLines.count <= 1 && originalLines.count == modifiedLines.count
            && zip(originalLines, modifiedLines).allSatisfy({ jsStringEquals($0, $1) }) {
            return LinesDiff(changes: [], hitTimeout: false)
        }

        if (originalLines.count == 1 && originalLines[0].isEmpty) || (modifiedLines.count == 1 && modifiedLines[0].isEmpty) {
            return LinesDiff(changes: [
                DetailedLineRangeMapping(
                    original: LineRange(startLineNumber: 1, endLineNumberExclusive: originalLines.count + 1),
                    modified: LineRange(startLineNumber: 1, endLineNumberExclusive: modifiedLines.count + 1),
                    innerChanges: [
                        RangeMapping(
                            originalRange: DiffTextRange(startLineNumber: 1, startColumn: 1, endLineNumber: originalLines.count,
                                                     endColumn: originalLines[originalLines.count - 1].utf16.count + 1),
                            modifiedRange: DiffTextRange(startLineNumber: 1, startColumn: 1, endLineNumber: modifiedLines.count,
                                                     endColumn: modifiedLines[modifiedLines.count - 1].utf16.count + 1)
                        ),
                    ]
                ),
            ], hitTimeout: false)
        }

        let timeout: any DiffTimeout = wrapTimeout(options.maxComputationTimeMs == 0
            ? InfiniteTimeout.instance
            : DateTimeout(timeoutMs: options.maxComputationTimeMs))
        let considerWhitespaceChanges = !options.ignoreTrimWhitespace

        // Keyed by UTF-16 code units: JS Map compares strings by code units, whereas
        // Swift String equality uses canonical equivalence.
        var perfectHashes: [[UInt16]: Int] = [:]
        func getOrCreateHash(_ text: [UInt16]) -> Int {
            if let hash = perfectHashes[text] {
                return hash
            }
            let hash = perfectHashes.count
            perfectHashes[text] = hash
            return hash
        }

        let originalLinesHashes = originalLines.map { getOrCreateHash(Array(jsTrim(Array($0.utf16)[...]))) }
        let modifiedLinesHashes = modifiedLines.map { getOrCreateHash(Array(jsTrim(Array($0.utf16)[...]))) }

        let sequence1 = LineSequence(trimmedHash: originalLinesHashes, lines: originalLines)
        let sequence2 = LineSequence(trimmedHash: modifiedLinesHashes, lines: modifiedLines)

        let lineAlignmentResult: DiffAlgorithmResult
        if sequence1.length + sequence2.length < 1700 {
            // Use the improved algorithm for small files
            lineAlignmentResult = dynamicProgrammingDiffing.compute(
                sequence1,
                sequence2,
                timeout: timeout,
                equalityScore: { offset1, offset2 in
                    jsStringEquals(originalLines[offset1], modifiedLines[offset2])
                        ? (modifiedLines[offset2].isEmpty
                            ? 0.1
                            : 1 + log(1 + Double(modifiedLines[offset2].utf16.count)))
                        : 0.99
                }
            )
        } else {
            lineAlignmentResult = myersDiffingAlgorithm.compute(sequence1, sequence2, timeout: timeout)
        }

        var lineAlignments = lineAlignmentResult.diffs
        var hitTimeout = lineAlignmentResult.hitTimeout
        lineAlignments = HeuristicSequenceOptimizations.optimizeSequenceDiffs(sequence1, sequence2, lineAlignments)
        lineAlignments = HeuristicSequenceOptimizations.removeVeryShortMatchingLinesBetweenDiffs(sequence1, sequence2, lineAlignments)

        var alignments: [RangeMapping] = []

        var seq1LastStart = 0
        var seq2LastStart = 0

        func scanForWhitespaceChanges(_ equalLinesCount: Int) {
            if !considerWhitespaceChanges {
                return
            }

            for i in 0..<equalLinesCount {
                let seq1Offset = seq1LastStart + i
                let seq2Offset = seq2LastStart + i
                if !jsStringEquals(originalLines[seq1Offset], modifiedLines[seq2Offset]) {
                    // This is because of whitespace changes, diff these lines
                    let characterDiffs = refineDiff(originalLines, modifiedLines, SequenceDiff(
                        seq1Range: OffsetRange(start: seq1Offset, endExclusive: seq1Offset + 1),
                        seq2Range: OffsetRange(start: seq2Offset, endExclusive: seq2Offset + 1)
                    ), timeout, considerWhitespaceChanges, options)
                    alignments.append(contentsOf: characterDiffs.mappings)
                    if characterDiffs.hitTimeout {
                        hitTimeout = true
                    }
                }
            }
        }

        for diff in lineAlignments {
            assert(diff.seq1Range.start - seq1LastStart == diff.seq2Range.start - seq2LastStart)

            let equalLinesCount = diff.seq1Range.start - seq1LastStart

            scanForWhitespaceChanges(equalLinesCount)

            seq1LastStart = diff.seq1Range.endExclusive
            seq2LastStart = diff.seq2Range.endExclusive

            let characterDiffs = refineDiff(originalLines, modifiedLines, diff, timeout, considerWhitespaceChanges, options)
            if characterDiffs.hitTimeout {
                hitTimeout = true
            }
            alignments.append(contentsOf: characterDiffs.mappings)
        }

        scanForWhitespaceChanges(originalLines.count - seq1LastStart)

        let changes = lineRangeMappingFromRangeMappings(alignments, originalLines, modifiedLines)

        // Make sure all ranges are valid
        assert({
            func validatePosition(_ pos: DiffTextPosition, _ lines: [String]) -> Bool {
                if pos.lineNumber < 1 || pos.lineNumber > lines.count { return false }
                let line = lines[pos.lineNumber - 1]
                if pos.column < 1 || pos.column > line.utf16.count + 1 { return false }
                return true
            }

            func validateRange(_ range: LineRange, _ lines: [String]) -> Bool {
                if range.startLineNumber < 1 || range.startLineNumber > lines.count + 1 { return false }
                if range.endLineNumberExclusive < 1 || range.endLineNumberExclusive > lines.count + 1 { return false }
                return true
            }

            for c in changes {
                guard let innerChanges = c.innerChanges else { return false }
                for ic in innerChanges {
                    let valid = validatePosition(ic.modifiedRange.getStartPosition(), modifiedLines)
                        && validatePosition(ic.modifiedRange.getEndPosition(), modifiedLines)
                        && validatePosition(ic.originalRange.getStartPosition(), originalLines)
                        && validatePosition(ic.originalRange.getEndPosition(), originalLines)
                    if !valid {
                        return false
                    }
                }
                if !validateRange(c.modified, modifiedLines) || !validateRange(c.original, originalLines) {
                    return false
                }
            }
            return true
        }())

        return LinesDiff(changes: changes, hitTimeout: hitTimeout)
    }

    private func refineDiff(
        _ originalLines: [String],
        _ modifiedLines: [String],
        _ diff: SequenceDiff,
        _ timeout: any DiffTimeout,
        _ considerWhitespaceChanges: Bool,
        _ options: LinesDiffOptions
    ) -> (mappings: [RangeMapping], hitTimeout: Bool) {
        let lineRangeMapping = toLineRangeMapping(diff)
        let rangeMapping = lineRangeMapping.toRangeMapping2(originalLines, modifiedLines)

        let slice1 = LinesSliceCharSequence(lines: originalLines, range: rangeMapping.originalRange, considerWhitespaceChanges: considerWhitespaceChanges)
        let slice2 = LinesSliceCharSequence(lines: modifiedLines, range: rangeMapping.modifiedRange, considerWhitespaceChanges: considerWhitespaceChanges)

        let diffResult = slice1.length + slice2.length < 500
            ? dynamicProgrammingDiffing.compute(slice1, slice2, timeout: timeout)
            : myersDiffingAlgorithm.compute(slice1, slice2, timeout: timeout)

        var diffs = diffResult.diffs
        diffs = HeuristicSequenceOptimizations.optimizeSequenceDiffs(slice1, slice2, diffs)
        diffs = HeuristicSequenceOptimizations.extendDiffsToEntireWordIfAppropriate(
            slice1, slice2, diffs, findParent: { seq, idx in seq.findWordContaining(idx) })

        if options.extendToSubwords {
            diffs = HeuristicSequenceOptimizations.extendDiffsToEntireWordIfAppropriate(
                slice1, slice2, diffs, findParent: { seq, idx in seq.findSubWordContaining(idx) }, force: true)
        }

        diffs = HeuristicSequenceOptimizations.removeShortMatches(slice1, slice2, diffs)
        diffs = HeuristicSequenceOptimizations.removeVeryShortMatchingTextBetweenLongDiffs(slice1, slice2, diffs)

        let result = diffs.map { d in
            RangeMapping(
                originalRange: slice1.translateRange(d.seq1Range),
                modifiedRange: slice2.translateRange(d.seq2Range)
            )
        }

        return (mappings: result, hitTimeout: diffResult.hitTimeout)
    }
}

private func toLineRangeMapping(_ sequenceDiff: SequenceDiff) -> LineRangeMapping {
    LineRangeMapping(
        original: LineRange(startLineNumber: sequenceDiff.seq1Range.start + 1, endLineNumberExclusive: sequenceDiff.seq1Range.endExclusive + 1),
        modified: LineRange(startLineNumber: sequenceDiff.seq2Range.start + 1, endLineNumberExclusive: sequenceDiff.seq2Range.endExclusive + 1)
    )
}
