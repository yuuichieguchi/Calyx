// DiffAlgorithmTests.swift
// CalyxTests
//
// Tests for the Swift port of VS Code's diff computer
// (src/vs/editor/common/diff/defaultLinesDiffComputer/*, rangeMapping.ts,
// core/ranges/offsetRange.ts) pinned at microsoft/vscode
// c2c46e750ab7afe355bad8bea20a248520adfdb0.
//
// Expected values are hand-traced from the TypeScript sources; the TS
// function responsible for a non-obvious value is cited next to it.

import Foundation
import Testing
@testable import Calyx

// MARK: - Helpers

/// Minimal integer sequence for exercising the raw algorithms.
private struct IntSequence: DiffSequence {
    let items: [Int]
    var length: Int { items.count }
    func getElement(_ offset: Int) -> Int { items[offset] }
    func getBoundaryScore(_ length: Int) -> Int? { nil }
    func isStronglyEqual(_ offset1: Int, _ offset2: Int) -> Bool { items[offset1] == items[offset2] }
}

/// Deterministic stand-in for an expired `DateTimeout`.
private struct NeverValidTimeout: DiffTimeout {
    func isValid() -> Bool { false }
}

private func sd(_ s1: Int, _ e1: Int, _ s2: Int, _ e2: Int) -> SequenceDiff {
    SequenceDiff(
        seq1Range: OffsetRange(start: s1, endExclusive: e1),
        seq2Range: OffsetRange(start: s2, endExclusive: e2)
    )
}

/// [seq1.start, seq1.endExclusive, seq2.start, seq2.endExclusive] per diff.
private func flat(_ diffs: [SequenceDiff]) -> [[Int]] {
    diffs.map { [$0.seq1Range.start, $0.seq1Range.endExclusive, $0.seq2Range.start, $0.seq2Range.endExclusive] }
}

private func tr(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int) -> DiffTextRange {
    DiffTextRange(startLineNumber: sl, startColumn: sc, endLineNumber: el, endColumn: ec)
}

private func flat(_ r: DiffTextRange) -> [Int] {
    [r.startLineNumber, r.startColumn, r.endLineNumber, r.endColumn]
}

/// [orig.start, orig.endExclusive, mod.start, mod.endExclusive]
private func lines(_ m: DetailedLineRangeMapping) -> [Int] {
    [m.original.startLineNumber, m.original.endLineNumberExclusive,
     m.modified.startLineNumber, m.modified.endLineNumberExclusive]
}

/// Each inner change as [orig(sl,sc,el,ec), mod(sl,sc,el,ec)] flattened to 8 ints.
private func inner(_ m: DetailedLineRangeMapping) -> [[Int]]? {
    m.innerChanges?.map { flat($0.originalRange) + flat($0.modifiedRange) }
}

private func charSeq(_ text: String, considerWhitespaceChanges: Bool = true) -> LinesSliceCharSequence {
    LinesSliceCharSequence(
        lines: [text],
        range: tr(1, 1, 1, text.count + 1),
        considerWhitespaceChanges: considerWhitespaceChanges
    )
}

// MARK: - Ranges

struct DiffAlgorithmRangeTests {

    @Test func offsetRange_lengthAndIsEmpty() {
        let r = OffsetRange(start: 2, endExclusive: 7)
        #expect(r.length == 5)
        #expect(r.isEmpty == false)
        #expect(OffsetRange(start: 4, endExclusive: 4).isEmpty)
        #expect(OffsetRange(start: 4, endExclusive: 4).length == 0)
    }

    @Test func offsetRange_join_isSmallestCoveringRange() {
        let j = OffsetRange(start: 5, endExclusive: 8).join(OffsetRange(start: 1, endExclusive: 3))
        #expect(j.start == 1)
        #expect(j.endExclusive == 8)
    }

    @Test func offsetRange_intersect_overlapping() {
        let i = OffsetRange(start: 0, endExclusive: 5).intersect(OffsetRange(start: 3, endExclusive: 8))
        #expect(i?.start == 3)
        #expect(i?.endExclusive == 5)
    }

    @Test func offsetRange_intersect_touchingIsEmptyRange() {
        // offsetRange.ts intersect: `start <= end` -> range, so touching ranges give an empty range.
        let i = OffsetRange(start: 0, endExclusive: 3).intersect(OffsetRange(start: 3, endExclusive: 5))
        #expect(i?.start == 3)
        #expect(i?.endExclusive == 3)
    }

    @Test func offsetRange_intersect_disjointIsNil() {
        #expect(OffsetRange(start: 0, endExclusive: 2).intersect(OffsetRange(start: 5, endExclusive: 6)) == nil)
    }

    @Test func lineRange_lengthAndIsEmpty() {
        let r = LineRange(startLineNumber: 2, endLineNumberExclusive: 5)
        #expect(r.length == 3)
        #expect(r.isEmpty == false)
        #expect(LineRange(startLineNumber: 3, endLineNumberExclusive: 3).isEmpty)
    }

    @Test func textRange_isEmpty() {
        #expect(tr(2, 4, 2, 4).isEmpty)
        #expect(tr(2, 4, 2, 5).isEmpty == false)
        #expect(tr(2, 4, 3, 4).isEmpty == false)
    }

    @Test func sequenceDiff_invert_middleDiff() {
        // diffAlgorithm.ts SequenceDiff.invert: last pair ends at
        // (doc1Length, (a.seq2.end - a.seq1.end) + doc1Length) = (4, 1 + 4).
        let inverted = SequenceDiff.invert([sd(1, 2, 1, 3)], length: 4)
        #expect(flat(inverted) == [[0, 1, 0, 1], [2, 4, 3, 5]])
    }

    @Test func sequenceDiff_invert_diffAtStartKeepsEmptyLeadingRange() {
        let inverted = SequenceDiff.invert([sd(0, 1, 0, 1)], length: 2)
        #expect(flat(inverted) == [[0, 0, 0, 0], [1, 2, 1, 2]])
    }

    @Test func sequenceDiff_invert_emptyIsWholeRange() {
        // forEachAdjacent calls the callback once with (undefined, undefined).
        #expect(flat(SequenceDiff.invert([], length: 3)) == [[0, 3, 0, 3]])
    }

    @Test func lineRangeMapping_inverse_emitsUnchangedRanges() {
        let m = DetailedLineRangeMapping(
            original: LineRange(startLineNumber: 2, endLineNumberExclusive: 3),
            modified: LineRange(startLineNumber: 2, endLineNumberExclusive: 4),
            innerChanges: nil
        )
        let inv = DetailedLineRangeMapping.inverse([m], originalLineCount: 4, modifiedLineCount: 5)
        let flatInv = inv.map { [$0.original.startLineNumber, $0.original.endLineNumberExclusive,
                                 $0.modified.startLineNumber, $0.modified.endLineNumberExclusive] }
        #expect(flatInv == [[1, 2, 1, 2], [3, 5, 4, 6]])
    }

    @Test func lineRangeMapping_inverse_skipsEmptyLeadingRange() {
        // rangeMapping.ts LineRangeMapping.inverse filters on `modified.isEmpty`.
        let m = DetailedLineRangeMapping(
            original: LineRange(startLineNumber: 1, endLineNumberExclusive: 2),
            modified: LineRange(startLineNumber: 1, endLineNumberExclusive: 2),
            innerChanges: nil
        )
        let inv = DetailedLineRangeMapping.inverse([m], originalLineCount: 2, modifiedLineCount: 2)
        let flatInv = inv.map { [$0.original.startLineNumber, $0.original.endLineNumberExclusive,
                                 $0.modified.startLineNumber, $0.modified.endLineNumberExclusive] }
        #expect(flatInv == [[2, 3, 2, 3]])
    }

    @Test func dateTimeout_longTimeoutIsValid() {
        #expect(DateTimeout(timeoutMs: 60_000).isValid())
        #expect(InfiniteTimeout().isValid())
    }
}

// MARK: - Myers / Dynamic programming

struct DiffAlgorithmCoreTests {

    @Test func myers_identical_noDiffs() {
        let r = MyersDiffAlgorithm().compute(IntSequence(items: [1, 2, 3]), IntSequence(items: [1, 2, 3]), timeout: InfiniteTimeout())
        #expect(r.diffs.isEmpty)
        #expect(r.hitTimeout == false)
    }

    @Test func myers_insert() {
        let r = MyersDiffAlgorithm().compute(IntSequence(items: [1, 2]), IntSequence(items: [1, 9, 2]), timeout: InfiniteTimeout())
        #expect(flat(r.diffs) == [[1, 1, 1, 2]])
    }

    @Test func myers_delete() {
        let r = MyersDiffAlgorithm().compute(IntSequence(items: [1, 9, 2]), IntSequence(items: [1, 2]), timeout: InfiniteTimeout())
        #expect(flat(r.diffs) == [[1, 2, 1, 1]])
    }

    @Test func myers_replace_isOneDiff() {
        let r = MyersDiffAlgorithm().compute(IntSequence(items: [1, 2, 3]), IntSequence(items: [1, 7, 3]), timeout: InfiniteTimeout())
        #expect(flat(r.diffs) == [[1, 2, 1, 2]])
    }

    @Test func myers_emptyInputs_areTrivial() {
        // DiffAlgorithmResult.trivial: one diff covering both sequences, even when both are empty.
        let a = MyersDiffAlgorithm().compute(IntSequence(items: []), IntSequence(items: [1, 2]), timeout: InfiniteTimeout())
        #expect(flat(a.diffs) == [[0, 0, 0, 2]])
        let b = MyersDiffAlgorithm().compute(IntSequence(items: []), IntSequence(items: []), timeout: InfiniteTimeout())
        #expect(flat(b.diffs) == [[0, 0, 0, 0]])
    }

    @Test func myers_timeout_returnsTrivialTimedOut() {
        let r = MyersDiffAlgorithm().compute(IntSequence(items: [1, 2, 3]), IntSequence(items: [4, 5]), timeout: NeverValidTimeout())
        #expect(r.hitTimeout)
        #expect(flat(r.diffs) == [[0, 3, 0, 2]])
    }

    @Test func dp_identical_noDiffs() {
        let r = DynamicProgrammingDiffing().compute(IntSequence(items: [1, 2, 3]), IntSequence(items: [1, 2, 3]), timeout: InfiniteTimeout())
        #expect(r.diffs.isEmpty)
        #expect(r.hitTimeout == false)
    }

    @Test func dp_insert() {
        let r = DynamicProgrammingDiffing().compute(IntSequence(items: [1, 2]), IntSequence(items: [1, 9, 2]), timeout: InfiniteTimeout())
        #expect(flat(r.diffs) == [[1, 1, 1, 2]])
    }

    @Test func dp_delete() {
        let r = DynamicProgrammingDiffing().compute(IntSequence(items: [1, 9, 2]), IntSequence(items: [1, 2]), timeout: InfiniteTimeout())
        #expect(flat(r.diffs) == [[1, 2, 1, 1]])
    }

    @Test func dp_replace_isOneDiff() {
        let r = DynamicProgrammingDiffing().compute(IntSequence(items: [1, 2, 3]), IntSequence(items: [1, 7, 3]), timeout: InfiniteTimeout())
        #expect(flat(r.diffs) == [[1, 2, 1, 2]])
    }

    @Test func dp_emptyInputs_areTrivial() {
        let a = DynamicProgrammingDiffing().compute(IntSequence(items: [1, 2]), IntSequence(items: []), timeout: InfiniteTimeout())
        #expect(flat(a.diffs) == [[0, 2, 0, 0]])
        let b = DynamicProgrammingDiffing().compute(IntSequence(items: []), IntSequence(items: []), timeout: InfiniteTimeout())
        #expect(flat(b.diffs) == [[0, 0, 0, 0]])
    }

    @Test func dp_timeout_returnsTrivialTimedOut() {
        let r = DynamicProgrammingDiffing().compute(IntSequence(items: [1, 2, 3]), IntSequence(items: [4, 5]), timeout: NeverValidTimeout())
        #expect(r.hitTimeout)
        #expect(flat(r.diffs) == [[0, 3, 0, 2]])
    }
}

// MARK: - Sequences

struct DiffAlgorithmSequenceTests {

    /// Fixture from VS Code's defaultLinesDiffComputer.test.ts, suite 'LinesSliceCharSequence'.
    private let sequence = LinesSliceCharSequence(
        lines: [
            "line1: foo",
            "line2: fizzbuzz",
            "line3: barr",
            "line4: hello world",
            "line5: bazz",
        ],
        range: DiffTextRange(startLineNumber: 2, startColumn: 1, endLineNumber: 5, endColumn: 1),
        considerWhitespaceChanges: true
    )

    @Test func linesSlice_length() {
        // 16 ("line2: fizzbuzz\n") + 12 ("line3: barr\n") + 19 ("line4: hello world\n") + 0
        #expect(sequence.length == 47)
    }

    @Test func linesSlice_extendToFullLines_vscodeFixture() {
        #expect(sequence.getText(sequence.extendToFullLines(OffsetRange(start: 20, endExclusive: 25))) == "line3: barr\n")
        #expect(sequence.getText(sequence.extendToFullLines(OffsetRange(start: 20, endExclusive: 45))) == "line3: barr\nline4: hello world\n")
    }

    @Test func linesSlice_translateRange_vscodeFixtureOffsets() {
        // translateOffset fixture: 0 -> (2,1), 15 -> (2,16), 16 -> (3,1), 46 -> (4,19).
        #expect(flat(sequence.translateRange(OffsetRange(start: 0, endExclusive: 1))).prefix(2) == [2, 1])
        #expect(flat(sequence.translateRange(OffsetRange(start: 15, endExclusive: 16))).prefix(2) == [2, 16])
        #expect(flat(sequence.translateRange(OffsetRange(start: 16, endExclusive: 17))).prefix(2) == [3, 1])
        #expect(flat(sequence.translateRange(OffsetRange(start: 46, endExclusive: 47))).prefix(2) == [4, 19])
    }

    @Test func linesSlice_translateRange_withinLine() {
        #expect(flat(sequence.translateRange(OffsetRange(start: 16, endExclusive: 20))) == [3, 1, 3, 5])
    }

    @Test func linesSlice_countLinesIn() {
        #expect(sequence.countLinesIn(OffsetRange(start: 0, endExclusive: 16)) == 1)
        #expect(sequence.countLinesIn(OffsetRange(start: 0, endExclusive: 5)) == 0)
    }

    @Test func linesSlice_ignoringWhitespace_translatesBackToOriginalColumns() {
        // linesSliceCharSequence.ts translateOffset adds trimmedWsLengthsByLineIdx.
        let s = charSeq("  ab  ", considerWhitespaceChanges: false)
        #expect(s.length == 2)
        #expect(s.getText(OffsetRange(start: 0, endExclusive: 2)) == "ab")
        #expect(flat(s.translateRange(OffsetRange(start: 0, endExclusive: 2))) == [1, 3, 1, 5])
    }

    @Test func linesSlice_findWordContaining() {
        let s = charSeq("foo bar")
        let w = s.findWordContaining(5)
        #expect(w?.start == 4)
        #expect(w?.endExclusive == 7)
        #expect(s.findWordContaining(3) == nil)
    }

    @Test func linesSlice_boundaryScore() {
        // getBoundaryScore: lower -> ',' : 10 (category change) + 0 + 30 (Separator) = 40
        #expect(charSeq("a,b").getBoundaryScore(1) == 40)
        // End(-1) -> lower: 10 + 10 (End) + 0 = 20
        #expect(charSeq("a,b").getBoundaryScore(0) == 20)
    }

    @Test func lineSequence_elementsBoundaryAndStrongEquality() {
        let s = LineSequence(trimmedHash: [0, 1, 0], lines: ["a", "    b", " a"])
        #expect(s.length == 3)
        #expect(s.getElement(2) == 0)
        // 1000 - (indent("a") + indent("    b")) = 996
        #expect(s.getBoundaryScore(1) == 996)
        #expect(s.isStronglyEqual(0, 2) == false)
        #expect(s.isStronglyEqual(0, 0))
    }
}

// MARK: - Heuristics

struct DiffAlgorithmHeuristicTests {

    @Test func optimizeSequenceDiffs_shiftsInsertionToWordBoundary() {
        // s1 "Ib", s2 "Ia, Ib"; raw insertion of "a, I" at s1 offset 1.
        // shiftDiffToBetterPosition: deltaBefore = 1, deltaAfter = 0.
        //   delta -1: b1(0)=20 + b2(0)=20 + b2(4)=13 (' ' -> 'I') = 53
        //   delta  0: b1(1)=10 + b2(1)=10 + b2(5)=10           = 30
        // -> insertion of "Ia, " at offset 0.
        let s1 = charSeq("Ib")
        let s2 = charSeq("Ia, Ib")
        let result = HeuristicSequenceOptimizations.optimizeSequenceDiffs(s1, s2, [sd(1, 1, 1, 5)])
        #expect(flat(result) == [[0, 0, 0, 4]])
    }

    @Test func optimizeSequenceDiffs_keepsAlreadyOptimalReplacement() {
        let s1 = charSeq("ab")
        let s2 = charSeq("xb")
        let result = HeuristicSequenceOptimizations.optimizeSequenceDiffs(s1, s2, [sd(0, 1, 0, 1)])
        #expect(flat(result) == [[0, 1, 0, 1]])
    }

    @Test func removeShortMatches_joinsGapOfTwo() {
        let s = IntSequence(items: Array(repeating: 0, count: 10))
        let result = HeuristicSequenceOptimizations.removeShortMatches(s, s, [sd(0, 1, 0, 1), sd(3, 4, 3, 4)])
        #expect(flat(result) == [[0, 4, 0, 4]])
    }

    @Test func removeShortMatches_keepsGapOfThree() {
        let s = IntSequence(items: Array(repeating: 0, count: 10))
        let result = HeuristicSequenceOptimizations.removeShortMatches(s, s, [sd(0, 1, 0, 1), sd(4, 5, 4, 5)])
        #expect(flat(result) == [[0, 1, 0, 1], [4, 5, 4, 5]])
    }

    @Test func removeShortMatches_joinsWhenOnlyOneSideGapIsShort() {
        // Condition is `gap1 <= 2 || gap2 <= 2`.
        let s = IntSequence(items: Array(repeating: 0, count: 10))
        let result = HeuristicSequenceOptimizations.removeShortMatches(s, s, [sd(0, 1, 0, 1), sd(4, 5, 2, 3)])
        #expect(flat(result) == [[0, 5, 0, 3]])
    }

    @Test func extendToWord_shortWordMostlyChanged_extends() {
        // "ab" -> "cb": word [0,2) both sides, equal chars 1 + 1 = 2 < (2 + 2) * 2/3 -> extend.
        let s1 = charSeq("ab")
        let s2 = charSeq("cb")
        let result = HeuristicSequenceOptimizations.extendDiffsToEntireWordIfAppropriate(
            s1, s2, [sd(0, 1, 0, 1)], findParent: { seq, idx in seq.findWordContaining(idx) })
        #expect(flat(result) == [[0, 2, 0, 2]])
    }

    @Test func extendToWord_halfChanged_extends() {
        // "foobar" -> "fooxyz": equal 3 + 3 = 6 < (6 + 6) * 2/3 = 8 -> extend.
        let s1 = charSeq("foobar")
        let s2 = charSeq("fooxyz")
        let result = HeuristicSequenceOptimizations.extendDiffsToEntireWordIfAppropriate(
            s1, s2, [sd(3, 6, 3, 6)], findParent: { seq, idx in seq.findWordContaining(idx) })
        #expect(flat(result) == [[0, 6, 0, 6]])
    }

    @Test func extendToWord_foo1ToFoo2_doesNotExtend() {
        // equal 3 + 3 = 6, not < (4 + 4) * 2/3 = 5.33 -> unchanged.
        let s1 = charSeq("foo1")
        let s2 = charSeq("foo2")
        let result = HeuristicSequenceOptimizations.extendDiffsToEntireWordIfAppropriate(
            s1, s2, [sd(3, 4, 3, 4)], findParent: { seq, idx in seq.findWordContaining(idx) })
        #expect(flat(result) == [[3, 4, 3, 4]])
    }

    @Test func extendToWord_longWordOneCharChange_doesNotExtend() {
        let s1 = charSeq("configuration1")
        let s2 = charSeq("configuration2")
        let result = HeuristicSequenceOptimizations.extendDiffsToEntireWordIfAppropriate(
            s1, s2, [sd(13, 14, 13, 14)], findParent: { seq, idx in seq.findWordContaining(idx) })
        #expect(flat(result) == [[13, 14, 13, 14]])
    }

    @Test func removeVeryShortMatchingTextBetweenLongDiffs_joinsAroundShortText() {
        // Both diffs are 130 chars on one line -> every measure capped at 130.
        // Sum = 2 * (2 * 130^1.5)^1.5 ~ 3.2e5 > (130^1.5)^1.5 * 1.3 ~ 7.4e4 -> join.
        // Joined diff covers whole line, so the prefix/suffix pass adds nothing.
        let t1 = String(repeating: "a", count: 130) + "=" + String(repeating: "b", count: 130)
        let t2 = String(repeating: "c", count: 130) + "=" + String(repeating: "d", count: 130)
        let result = HeuristicSequenceOptimizations.removeVeryShortMatchingTextBetweenLongDiffs(
            charSeq(t1), charSeq(t2), [sd(0, 130, 0, 130), sd(131, 261, 131, 261)])
        #expect(flat(result) == [[0, 261, 0, 261]])
    }

    @Test func removeVeryShortMatchingTextBetweenLongDiffs_keepsShortDiffsApart() {
        // 1-char diffs: sum ~ 5.7, far below the threshold.
        let result = HeuristicSequenceOptimizations.removeVeryShortMatchingTextBetweenLongDiffs(
            charSeq("ab=cd"), charSeq("xb=yd"), [sd(0, 1, 0, 1), sd(3, 4, 3, 4)])
        #expect(flat(result) == [[0, 1, 0, 1], [3, 4, 3, 4]])
    }

    @Test func removeVeryShortMatchingLinesBetweenDiffs_joinsWhenNeighbourIsLong() {
        // Unchanged text "x" (<= 4 non-ws chars) and after-diff length 1 + 5 = 6 > 5 -> join.
        let s1 = LineSequence(trimmedHash: [0, 1, 2], lines: ["a", "x", "b"])
        let s2 = LineSequence(trimmedHash: [3, 4, 5, 1, 6, 7, 8, 9, 10],
                              lines: ["p", "q", "r", "x", "s", "t", "u", "v", "w"])
        let result = HeuristicSequenceOptimizations.removeVeryShortMatchingLinesBetweenDiffs(
            s1, s2, [sd(0, 1, 0, 3), sd(2, 3, 4, 9)])
        #expect(flat(result) == [[0, 3, 0, 9]])
    }

    @Test func removeVeryShortMatchingLinesBetweenDiffs_keepsWhenBothShort() {
        // before 1 + 3 = 4, after 1 + 3 = 4, neither > 5 -> no join.
        let s1 = LineSequence(trimmedHash: [0, 1, 2], lines: ["a", "x", "b"])
        let s2 = LineSequence(trimmedHash: [3, 4, 5, 1, 6, 7, 8],
                              lines: ["p", "q", "r", "x", "s", "t", "u"])
        let result = HeuristicSequenceOptimizations.removeVeryShortMatchingLinesBetweenDiffs(
            s1, s2, [sd(0, 1, 0, 3), sd(2, 3, 4, 7)])
        #expect(flat(result) == [[0, 1, 0, 3], [2, 3, 4, 7]])
    }
}

// MARK: - DefaultLinesDiffComputer end-to-end

struct DefaultLinesDiffComputerTests {

    private func compute(_ original: [String], _ modified: [String],
                         ignoreTrimWhitespace: Bool = true,
                         maxComputationTimeMs: Int = 5000) -> LinesDiff {
        var options = LinesDiffOptions()
        options.ignoreTrimWhitespace = ignoreTrimWhitespace
        options.maxComputationTimeMs = maxComputationTimeMs
        return DefaultLinesDiffComputer().computeDiff(originalLines: original, modifiedLines: modified, options: options)
    }

    @Test func options_defaults() {
        let o = LinesDiffOptions()
        #expect(o.ignoreTrimWhitespace == true)
        #expect(o.maxComputationTimeMs == 5000)
        #expect(o.extendToSubwords == false)
    }

    @Test func identical_noChanges() {
        let r = compute(["a", "b", "c"], ["a", "b", "c"])
        #expect(r.changes.isEmpty)
        #expect(r.hitTimeout == false)
    }

    @Test func singleEmptyLineBothSides_noChanges() {
        #expect(compute([""], [""]).changes.isEmpty)
    }

    @Test func emptyOriginal_specialCasedWholeMapping() {
        // defaultLinesDiffComputer.ts computeDiff: originalLines == [""] short-circuit.
        let r = compute([""], ["a", "b"])
        #expect(r.changes.count == 1)
        #expect(lines(r.changes[0]) == [1, 2, 1, 3])
        #expect(inner(r.changes[0]) == [[1, 1, 1, 1, 1, 1, 2, 2]])
    }

    @Test func modifyOneLine_oneMappingWithOneInnerChange() {
        // refineDiff slices "b\n" vs "x\n" -> char diff [0,1) -> Range(2,1,2,2) on both sides.
        let r = compute(["a", "b", "c"], ["a", "x", "c"])
        #expect(r.changes.count == 1)
        #expect(lines(r.changes[0]) == [2, 3, 2, 3])
        #expect(inner(r.changes[0]) == [[2, 1, 2, 2, 2, 1, 2, 2]])
        #expect(r.hitTimeout == false)
    }

    @Test func insertLine_emptyOriginalRange() {
        // getLineRangeMapping: both end columns are 1 -> lineEndDelta = -1.
        let r = compute(["a", "c"], ["a", "b", "c"])
        #expect(r.changes.count == 1)
        #expect(lines(r.changes[0]) == [2, 2, 2, 3])
        #expect(inner(r.changes[0]) == [[2, 1, 2, 1, 2, 1, 3, 1]])
    }

    @Test func deleteLine_emptyModifiedRange() {
        let r = compute(["a", "b", "c"], ["a", "c"])
        #expect(r.changes.count == 1)
        #expect(lines(r.changes[0]) == [2, 3, 2, 2])
        #expect(inner(r.changes[0]) == [[2, 1, 3, 1, 2, 1, 2, 1]])
    }

    @Test func whitespaceOnlyChange_ignoreTrimWhitespace_noChanges() {
        // Line hashes use l.trim(), and scanForWhitespaceChanges returns early when
        // !considerWhitespaceChanges, so nothing is reported.
        let r = compute(["a", "  b", "c"], ["a", "b", "c"], ignoreTrimWhitespace: true)
        #expect(r.changes.isEmpty)
    }

    @Test func whitespaceOnlyChange_considered_innerChange() {
        // scanForWhitespaceChanges -> refineDiff of "  b\n" vs "b\n" -> diff [0,2) <-> [0,0).
        let r = compute(["a", "  b", "c"], ["a", "b", "c"], ignoreTrimWhitespace: false)
        #expect(r.changes.count == 1)
        #expect(lines(r.changes[0]) == [2, 3, 2, 3])
        #expect(inner(r.changes[0]) == [[2, 1, 2, 3, 2, 1, 2, 1]])
    }

    @Test func multiLineBlock_innerRangeSpansLines() {
        // Char diffs "b\nc\n" vs "x\ny\n": [0,1) and [2,3), joined by removeShortMatches (gap 1)
        // into [0,3) -> Range(2,1,3,2).
        let r = compute(["a", "b", "c", "d"], ["a", "x", "y", "d"])
        #expect(r.changes.count == 1)
        #expect(lines(r.changes[0]) == [2, 4, 2, 4])
        #expect(inner(r.changes[0]) == [[2, 1, 3, 2, 2, 1, 3, 2]])
    }

    @Test func twoSeparatedChanges_twoMappings() {
        let r = compute(["a", "b", "c", "d", "e"], ["a", "x", "c", "d", "y"])
        #expect(r.changes.map(lines) == [[2, 3, 2, 3], [5, 6, 5, 6]])
    }

    @Test func zeroTimeout_meansInfinite_noHitTimeout() {
        // computeDiff: maxComputationTimeMs === 0 ? InfiniteTimeout.instance : new DateTimeout(...)
        let r = compute(["a", "b", "c"], ["a", "x", "c"], maxComputationTimeMs: 0)
        #expect(r.hitTimeout == false)
        #expect(r.changes.map(lines) == [[2, 3, 2, 3]])
    }
}
