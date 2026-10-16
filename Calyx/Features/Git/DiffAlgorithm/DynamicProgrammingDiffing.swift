// DynamicProgrammingDiffing.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/dynamicProgrammingDiffing.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).

import Foundation

/// A O(MN) diffing algorithm that supports a score function.
struct DynamicProgrammingDiffing {
    func compute(_ sequence1: some DiffSequence, _ sequence2: some DiffSequence, timeout: some DiffTimeout = InfiniteTimeout.instance) -> DiffAlgorithmResult {
        compute(sequence1, sequence2, timeout: timeout, equalityScore: nil)
    }

    func compute(
        _ sequence1: some DiffSequence,
        _ sequence2: some DiffSequence,
        timeout: some DiffTimeout,
        equalityScore: ((Int, Int) -> Double)?
    ) -> DiffAlgorithmResult {
        if sequence1.length == 0 || sequence2.length == 0 {
            return DiffAlgorithmResult.trivial(sequence1, sequence2)
        }

        let len1 = sequence1.length
        let len2 = sequence2.length

        // lcsLengths.get(i, j): Length of the longest common subsequence of
        // sequence1.substring(0, i + 1) and sequence2.substring(0, j + 1).
        // Double because equalityScore yields fractional scores.
        var lcsLengths = Array2D<Double>(width: len1, height: len2, initialValue: 0)
        var directions = Array2D<Int>(width: len1, height: len2, initialValue: 0)
        var lengths = Array2D<Int>(width: len1, height: len2, initialValue: 0)

        // ==== Initializing lcsLengths ====
        for s1 in 0..<len1 {
            for s2 in 0..<len2 {
                if !timeout.isValid() {
                    return DiffAlgorithmResult.trivialTimedOut(sequence1, sequence2)
                }

                let horizontalLen: Double = s1 == 0 ? 0 : lcsLengths.get(s1 - 1, s2)
                let verticalLen: Double = s2 == 0 ? 0 : lcsLengths.get(s1, s2 - 1)

                var extendedSeqScore: Double
                if sequence1.getElement(s1) == sequence2.getElement(s2) {
                    if s1 == 0 || s2 == 0 {
                        extendedSeqScore = 0
                    } else {
                        extendedSeqScore = lcsLengths.get(s1 - 1, s2 - 1)
                    }
                    if s1 > 0 && s2 > 0 && directions.get(s1 - 1, s2 - 1) == 3 {
                        // Prefer consecutive diagonals
                        extendedSeqScore += Double(lengths.get(s1 - 1, s2 - 1))
                    }
                    extendedSeqScore += equalityScore.map { $0(s1, s2) } ?? 1
                } else {
                    extendedSeqScore = -1
                }

                let newValue = max(horizontalLen, verticalLen, extendedSeqScore)

                if newValue == extendedSeqScore {
                    // Prefer diagonals
                    let prevLen = s1 > 0 && s2 > 0 ? lengths.get(s1 - 1, s2 - 1) : 0
                    lengths.set(s1, s2, prevLen + 1)
                    directions.set(s1, s2, 3)
                } else if newValue == horizontalLen {
                    lengths.set(s1, s2, 0)
                    directions.set(s1, s2, 1)
                } else if newValue == verticalLen {
                    lengths.set(s1, s2, 0)
                    directions.set(s1, s2, 2)
                }

                lcsLengths.set(s1, s2, newValue)
            }
        }

        // ==== Backtracking ====
        var result: [SequenceDiff] = []
        var lastAligningPosS1 = len1
        var lastAligningPosS2 = len2

        func reportDecreasingAligningPositions(_ s1: Int, _ s2: Int) {
            if s1 + 1 != lastAligningPosS1 || s2 + 1 != lastAligningPosS2 {
                result.append(SequenceDiff(
                    seq1Range: OffsetRange(start: s1 + 1, endExclusive: lastAligningPosS1),
                    seq2Range: OffsetRange(start: s2 + 1, endExclusive: lastAligningPosS2)
                ))
            }
            lastAligningPosS1 = s1
            lastAligningPosS2 = s2
        }

        var s1 = len1 - 1
        var s2 = len2 - 1
        while s1 >= 0 && s2 >= 0 {
            if directions.get(s1, s2) == 3 {
                reportDecreasingAligningPositions(s1, s2)
                s1 -= 1
                s2 -= 1
            } else {
                if directions.get(s1, s2) == 1 {
                    s1 -= 1
                } else {
                    s2 -= 1
                }
            }
        }
        reportDecreasingAligningPositions(-1, -1)
        result.reverse()
        return DiffAlgorithmResult(diffs: result, hitTimeout: false)
    }
}
