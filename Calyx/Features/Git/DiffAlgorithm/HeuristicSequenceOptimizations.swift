// HeuristicSequenceOptimizations.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/heuristicSequenceOptimizations.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).
// String lengths are JS lengths (UTF-16 code units).

import Foundation

enum HeuristicSequenceOptimizations {

    static func optimizeSequenceDiffs(_ sequence1: some DiffSequence, _ sequence2: some DiffSequence, _ sequenceDiffs: [SequenceDiff]) -> [SequenceDiff] {
        var result = sequenceDiffs
        result = joinSequenceDiffsByShifting(sequence1, sequence2, result)
        // Sometimes, calling this function twice improves the result.
        result = joinSequenceDiffsByShifting(sequence1, sequence2, result)
        result = shiftSequenceDiffs(sequence1, sequence2, result)
        return result
    }

    /// Fixes issues like this:
    /// ```
    /// import { Baz, Bar } from "foo";
    /// ```
    /// <->
    /// ```
    /// import { Baz, Bar, Foo } from "foo";
    /// ```
    /// Computed diff: [ {Add "," after Bar}, {Add "Foo " after space} }
    /// Improved diff: [{Add ", Foo" after Bar}]
    static func joinSequenceDiffsByShifting(_ sequence1: some DiffSequence, _ sequence2: some DiffSequence, _ sequenceDiffs: [SequenceDiff]) -> [SequenceDiff] {
        if sequenceDiffs.isEmpty {
            return sequenceDiffs
        }

        var result: [SequenceDiff] = []
        result.append(sequenceDiffs[0])

        // First move them all to the left as much as possible and join them if possible
        for i in 1..<sequenceDiffs.count {
            let prevResult = result[result.count - 1]
            var cur = sequenceDiffs[i]

            if cur.seq1Range.isEmpty || cur.seq2Range.isEmpty {
                let length = cur.seq1Range.start - prevResult.seq1Range.endExclusive
                var d = 1
                while d <= length {
                    if sequence1.getElement(cur.seq1Range.start - d) != sequence1.getElement(cur.seq1Range.endExclusive - d)
                        || sequence2.getElement(cur.seq2Range.start - d) != sequence2.getElement(cur.seq2Range.endExclusive - d) {
                        break
                    }
                    d += 1
                }
                d -= 1

                if d == length {
                    // Merge previous and current diff
                    result[result.count - 1] = SequenceDiff(
                        seq1Range: OffsetRange(start: prevResult.seq1Range.start, endExclusive: cur.seq1Range.endExclusive - length),
                        seq2Range: OffsetRange(start: prevResult.seq2Range.start, endExclusive: cur.seq2Range.endExclusive - length)
                    )
                    continue
                }

                cur = cur.delta(-d)
            }

            result.append(cur)
        }

        var result2: [SequenceDiff] = []
        // Then move them all to the right and join them again if possible
        var i = 0
        while i < result.count - 1 {
            defer { i += 1 }
            let nextResult = result[i + 1]
            var cur = result[i]

            if cur.seq1Range.isEmpty || cur.seq2Range.isEmpty {
                let length = nextResult.seq1Range.start - cur.seq1Range.endExclusive
                var d = 0
                while d < length {
                    if !sequence1.isStronglyEqual(cur.seq1Range.start + d, cur.seq1Range.endExclusive + d)
                        || !sequence2.isStronglyEqual(cur.seq2Range.start + d, cur.seq2Range.endExclusive + d) {
                        break
                    }
                    d += 1
                }

                if d == length {
                    // Merge previous and current diff, write to result!
                    result[i + 1] = SequenceDiff(
                        seq1Range: OffsetRange(start: cur.seq1Range.start + length, endExclusive: nextResult.seq1Range.endExclusive),
                        seq2Range: OffsetRange(start: cur.seq2Range.start + length, endExclusive: nextResult.seq2Range.endExclusive)
                    )
                    continue
                }

                if d > 0 {
                    cur = cur.delta(d)
                }
            }

            result2.append(cur)
        }

        if !result.isEmpty {
            result2.append(result[result.count - 1])
        }

        return result2
    }

    // align character level diffs at whitespace characters
    // import { IBar } from "foo";
    // import { I[Arr, I]Bar } from "foo";
    // ->
    // import { [IArr, ]IBar } from "foo";

    /// TS checks whether both sequences implement the optional `getBoundaryScore`;
    /// here a sequence without boundary scores returns nil from `getBoundaryScore`.
    static func shiftSequenceDiffs(_ sequence1: some DiffSequence, _ sequence2: some DiffSequence, _ sequenceDiffs: [SequenceDiff]) -> [SequenceDiff] {
        if sequence1.getBoundaryScore(0) == nil || sequence2.getBoundaryScore(0) == nil {
            return sequenceDiffs
        }

        var sequenceDiffs = sequenceDiffs
        for i in sequenceDiffs.indices {
            let prevDiff: SequenceDiff? = i > 0 ? sequenceDiffs[i - 1] : nil
            let diff = sequenceDiffs[i]
            let nextDiff: SequenceDiff? = i + 1 < sequenceDiffs.count ? sequenceDiffs[i + 1] : nil

            let seq1ValidRange = OffsetRange(
                start: prevDiff.map { $0.seq1Range.endExclusive + 1 } ?? 0,
                endExclusive: nextDiff.map { $0.seq1Range.start - 1 } ?? sequence1.length
            )
            let seq2ValidRange = OffsetRange(
                start: prevDiff.map { $0.seq2Range.endExclusive + 1 } ?? 0,
                endExclusive: nextDiff.map { $0.seq2Range.start - 1 } ?? sequence2.length
            )

            if diff.seq1Range.isEmpty {
                sequenceDiffs[i] = shiftDiffToBetterPosition(diff, sequence1, sequence2, seq1ValidRange, seq2ValidRange)
            } else if diff.seq2Range.isEmpty {
                sequenceDiffs[i] = shiftDiffToBetterPosition(diff.swap(), sequence2, sequence1, seq2ValidRange, seq1ValidRange).swap()
            }
        }

        return sequenceDiffs
    }

    static func shiftDiffToBetterPosition(
        _ diff: SequenceDiff,
        _ sequence1: some DiffSequence,
        _ sequence2: some DiffSequence,
        _ seq1ValidRange: OffsetRange,
        _ seq2ValidRange: OffsetRange
    ) -> SequenceDiff {
        let maxShiftLimit = 100 // To prevent performance issues

        // don't touch previous or next!
        var deltaBefore = 1
        while diff.seq1Range.start - deltaBefore >= seq1ValidRange.start
            && diff.seq2Range.start - deltaBefore >= seq2ValidRange.start
            && sequence2.isStronglyEqual(diff.seq2Range.start - deltaBefore, diff.seq2Range.endExclusive - deltaBefore)
            && deltaBefore < maxShiftLimit {
            deltaBefore += 1
        }
        deltaBefore -= 1

        var deltaAfter = 0
        while diff.seq1Range.start + deltaAfter < seq1ValidRange.endExclusive
            && diff.seq2Range.endExclusive + deltaAfter < seq2ValidRange.endExclusive
            && sequence2.isStronglyEqual(diff.seq2Range.start + deltaAfter, diff.seq2Range.endExclusive + deltaAfter)
            && deltaAfter < maxShiftLimit {
            deltaAfter += 1
        }

        if deltaBefore == 0 && deltaAfter == 0 {
            return diff
        }

        var bestDelta = 0
        var bestScore = -1
        // find best scored delta
        for delta in -deltaBefore...deltaAfter {
            let seq2OffsetStart = diff.seq2Range.start + delta
            let seq2OffsetEndExclusive = diff.seq2Range.endExclusive + delta
            let seq1Offset = diff.seq1Range.start + delta

            // Non-nil: shiftSequenceDiffs only calls this for sequences with boundary scores.
            let score = sequence1.getBoundaryScore(seq1Offset)!
                + sequence2.getBoundaryScore(seq2OffsetStart)!
                + sequence2.getBoundaryScore(seq2OffsetEndExclusive)!
            if score > bestScore {
                bestScore = score
                bestDelta = delta
            }
        }

        return diff.delta(bestDelta)
    }

    static func removeShortMatches(_ sequence1: some DiffSequence, _ sequence2: some DiffSequence, _ sequenceDiffs: [SequenceDiff]) -> [SequenceDiff] {
        var result: [SequenceDiff] = []
        for s in sequenceDiffs {
            guard let last = result.last else {
                result.append(s)
                continue
            }

            if s.seq1Range.start - last.seq1Range.endExclusive <= 2 || s.seq2Range.start - last.seq2Range.endExclusive <= 2 {
                result[result.count - 1] = SequenceDiff(seq1Range: last.seq1Range.join(s.seq1Range), seq2Range: last.seq2Range.join(s.seq2Range))
            } else {
                result.append(s)
            }
        }

        return result
    }

    static func extendDiffsToEntireWordIfAppropriate(
        _ sequence1: LinesSliceCharSequence,
        _ sequence2: LinesSliceCharSequence,
        _ sequenceDiffs: [SequenceDiff],
        findParent: (LinesSliceCharSequence, Int) -> OffsetRange?,
        force: Bool = false
    ) -> [SequenceDiff] {
        // Used as a queue: `equalMappings[equalMappingsHead...]` are the remaining items (TS shift()).
        let equalMappings = SequenceDiff.invert(sequenceDiffs, length: sequence1.length)
        var equalMappingsHead = 0

        var additional: [SequenceDiff] = []

        var lastPoint = OffsetPair(offset1: 0, offset2: 0)

        func scanWord(_ pair: OffsetPair, _ equalMapping: SequenceDiff) {
            if pair.offset1 < lastPoint.offset1 || pair.offset2 < lastPoint.offset2 {
                return
            }

            guard let w1 = findParent(sequence1, pair.offset1), let w2 = findParent(sequence2, pair.offset2) else {
                return
            }
            var w = SequenceDiff(seq1Range: w1, seq2Range: w2)
            // Non-nil: both words contain the pair, which lies in (or touches) equalMapping.
            let equalPart = w.intersect(equalMapping)!

            var equalChars1 = equalPart.seq1Range.length
            var equalChars2 = equalPart.seq2Range.length

            // The words do not touch previous equals mappings, as we would have processed them already.
            // But they might touch the next ones.

            while equalMappingsHead < equalMappings.count {
                let next = equalMappings[equalMappingsHead]
                let intersects = next.seq1Range.intersects(w.seq1Range) || next.seq2Range.intersects(w.seq2Range)
                if !intersects {
                    break
                }

                // Because there is an intersection, we know that the words are not empty.
                let v1 = findParent(sequence1, next.seq1Range.start)!
                let v2 = findParent(sequence2, next.seq2Range.start)!
                let v = SequenceDiff(seq1Range: v1, seq2Range: v2)
                let equalPart = v.intersect(next)!

                equalChars1 += equalPart.seq1Range.length
                equalChars2 += equalPart.seq2Range.length

                w = w.join(v)

                if w.seq1Range.endExclusive >= next.seq1Range.endExclusive {
                    // The word extends beyond the next equal mapping.
                    equalMappingsHead += 1
                } else {
                    break
                }
            }

            let wordLengths = w.seq1Range.length + w.seq2Range.length
            if (force && equalChars1 + equalChars2 < wordLengths)
                || Double(equalChars1 + equalChars2) < Double(wordLengths) * 2 / 3 {
                additional.append(w)
            }

            lastPoint = w.getEndExclusives()
        }

        while equalMappingsHead < equalMappings.count {
            let next = equalMappings[equalMappingsHead]
            equalMappingsHead += 1
            if next.seq1Range.isEmpty {
                continue
            }
            scanWord(next.getStarts(), next)
            // The equal parts are not empty, so -1 gives us a character that is equal in both parts.
            scanWord(next.getEndExclusives().delta(-1), next)
        }

        let merged = mergeSequenceDiffs(sequenceDiffs, additional)
        return merged
    }

    static func mergeSequenceDiffs(_ sequenceDiffs1: [SequenceDiff], _ sequenceDiffs2: [SequenceDiff]) -> [SequenceDiff] {
        var result: [SequenceDiff] = []
        var i1 = 0
        var i2 = 0

        while i1 < sequenceDiffs1.count || i2 < sequenceDiffs2.count {
            let sd1: SequenceDiff? = i1 < sequenceDiffs1.count ? sequenceDiffs1[i1] : nil
            let sd2: SequenceDiff? = i2 < sequenceDiffs2.count ? sequenceDiffs2[i2] : nil

            let next: SequenceDiff
            if let sd1, sd2 == nil || sd1.seq1Range.start < sd2!.seq1Range.start {
                next = sd1
                i1 += 1
            } else {
                // Non-nil: the loop condition guarantees one side has items and sd1 was not taken.
                next = sd2!
                i2 += 1
            }

            if let last = result.last, last.seq1Range.endExclusive >= next.seq1Range.start {
                result[result.count - 1] = last.join(next)
            } else {
                result.append(next)
            }
        }

        return result
    }

    static func removeVeryShortMatchingLinesBetweenDiffs(_ sequence1: LineSequence, _ sequence2: LineSequence, _ sequenceDiffs: [SequenceDiff]) -> [SequenceDiff] {
        var diffs = sequenceDiffs
        if diffs.isEmpty {
            return diffs
        }

        var counter = 0
        var shouldRepeat: Bool
        repeat {
            shouldRepeat = false

            var result: [SequenceDiff] = [diffs[0]]

            for i in 1..<diffs.count {
                let cur = diffs[i]
                let lastResult = result[result.count - 1]

                func shouldJoinDiffs(_ before: SequenceDiff, _ after: SequenceDiff) -> Bool {
                    let unchangedRange = OffsetRange(start: lastResult.seq1Range.endExclusive, endExclusive: cur.seq1Range.start)

                    let unchangedText = sequence1.getText(unchangedRange)
                    // unchangedText.replace(/\s/g, '').length
                    let unchangedTextWithoutWsLength = unchangedText.utf16.reduce(0) { $0 + (jsIsWhitespace($1) ? 0 : 1) }
                    if unchangedTextWithoutWsLength <= 4
                        && (before.seq1Range.length + before.seq2Range.length > 5 || after.seq1Range.length + after.seq2Range.length > 5) {
                        return true
                    }

                    return false
                }

                let shouldJoin = shouldJoinDiffs(lastResult, cur)
                if shouldJoin {
                    shouldRepeat = true
                    result[result.count - 1] = result[result.count - 1].join(cur)
                } else {
                    result.append(cur)
                }
            }

            diffs = result
            counter += 1
        } while counter - 1 < 10 && shouldRepeat

        return diffs
    }

    static func removeVeryShortMatchingTextBetweenLongDiffs(_ sequence1: LinesSliceCharSequence, _ sequence2: LinesSliceCharSequence, _ sequenceDiffs: [SequenceDiff]) -> [SequenceDiff] {
        var diffs = sequenceDiffs
        if diffs.isEmpty {
            return diffs
        }

        var counter = 0
        var shouldRepeat: Bool
        repeat {
            shouldRepeat = false

            var result: [SequenceDiff] = [diffs[0]]

            for i in 1..<diffs.count {
                let cur = diffs[i]
                let lastResult = result[result.count - 1]

                func shouldJoinDiffs(_ before: SequenceDiff, _ after: SequenceDiff) -> Bool {
                    let unchangedRange = OffsetRange(start: lastResult.seq1Range.endExclusive, endExclusive: cur.seq1Range.start)

                    let unchangedLineCount = sequence1.countLinesIn(unchangedRange)
                    if unchangedLineCount > 5 || unchangedRange.length > 500 {
                        return false
                    }

                    let unchangedText = jsTrim(Array(sequence1.getText(unchangedRange).utf16)[...])
                    // unchangedText.split(/\r\n|\r|\n/).length > 1 <=> it contains \r or \n.
                    if unchangedText.count > 20 || unchangedText.contains(where: { $0 == 0x0A || $0 == 0x0D }) {
                        return false
                    }

                    let beforeLineCount1 = sequence1.countLinesIn(before.seq1Range)
                    let beforeSeq1Length = before.seq1Range.length
                    let beforeLineCount2 = sequence2.countLinesIn(before.seq2Range)
                    let beforeSeq2Length = before.seq2Range.length

                    let afterLineCount1 = sequence1.countLinesIn(after.seq1Range)
                    let afterSeq1Length = after.seq1Range.length
                    let afterLineCount2 = sequence2.countLinesIn(after.seq2Range)
                    let afterSeq2Length = after.seq2Range.length

                    let maxValue = 2 * 40 + 50
                    func cap(_ v: Int) -> Double {
                        Double(min(v, maxValue))
                    }

                    let beforeScore = pow(pow(cap(beforeLineCount1 * 40 + beforeSeq1Length), 1.5) + pow(cap(beforeLineCount2 * 40 + beforeSeq2Length), 1.5), 1.5)
                    let afterScore = pow(pow(cap(afterLineCount1 * 40 + afterSeq1Length), 1.5) + pow(cap(afterLineCount2 * 40 + afterSeq2Length), 1.5), 1.5)
                    if beforeScore + afterScore > pow(pow(Double(maxValue), 1.5), 1.5) * 1.3 {
                        return true
                    }
                    return false
                }

                let shouldJoin = shouldJoinDiffs(lastResult, cur)
                if shouldJoin {
                    shouldRepeat = true
                    result[result.count - 1] = result[result.count - 1].join(cur)
                } else {
                    result.append(cur)
                }
            }

            diffs = result
            counter += 1
        } while counter - 1 < 10 && shouldRepeat

        var newDiffs: [SequenceDiff] = []

        // Remove short suffixes/prefixes
        forEachWithNeighbors(diffs) { prev, cur, next in
            var newDiff = cur

            func shouldMarkAsChanged(_ text: String) -> Bool {
                let units = Array(text.utf16)
                return !units.isEmpty && jsTrim(units[...]).count <= 3 && cur.seq1Range.length + cur.seq2Range.length > 100
            }

            let fullRange1 = sequence1.extendToFullLines(cur.seq1Range)
            let prefix = sequence1.getText(OffsetRange(start: fullRange1.start, endExclusive: cur.seq1Range.start))
            if shouldMarkAsChanged(prefix) {
                newDiff = newDiff.deltaStart(-prefix.utf16.count)
            }
            let suffix = sequence1.getText(OffsetRange(start: cur.seq1Range.endExclusive, endExclusive: fullRange1.endExclusive))
            if shouldMarkAsChanged(suffix) {
                newDiff = newDiff.deltaEnd(suffix.utf16.count)
            }

            let availableSpace = SequenceDiff.fromOffsetPairs(
                prev?.getEndExclusives() ?? OffsetPair.zero,
                next?.getStarts() ?? OffsetPair.max
            )
            // Non-nil: newDiff overlaps cur, which lies within availableSpace.
            let result = newDiff.intersect(availableSpace)!
            if let last = newDiffs.last, result.getStarts().equals(last.getEndExclusives()) {
                newDiffs[newDiffs.count - 1] = last.join(result)
            } else {
                newDiffs.append(result)
            }
        }

        return newDiffs
    }

    /// Port of base/common/arrays.ts `forEachWithNeighbors`.
    static func forEachWithNeighbors<T>(_ arr: [T], _ f: (T?, T, T?) -> Void) {
        for i in arr.indices {
            f(i == 0 ? nil : arr[i - 1], arr[i], i + 1 == arr.count ? nil : arr[i + 1])
        }
    }
}
