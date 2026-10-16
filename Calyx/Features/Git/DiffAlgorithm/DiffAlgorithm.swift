// DiffAlgorithm.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/diffAlgorithm.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).

import Foundation

/// TS `ISequence`. TS declares `getBoundaryScore` as an optional method; here a
/// sequence without boundary scores returns nil for every length.
protocol DiffSequence {
    func getElement(_ offset: Int) -> Int
    var length: Int { get }

    /// The higher the score, the better that offset can be used to split the sequence.
    /// Is used to optimize insertions. Must not be negative. nil = not supported.
    func getBoundaryScore(_ length: Int) -> Int?

    /// For line sequences, getElement returns a number representing trimmed lines.
    /// This however checks equality for the original lines.
    func isStronglyEqual(_ offset1: Int, _ offset2: Int) -> Bool
}

/// TS `ITimeout`.
protocol DiffTimeout {
    func isValid() -> Bool
}

struct InfiniteTimeout: DiffTimeout {
    static let instance = InfiniteTimeout()

    func isValid() -> Bool { true }
}

/// Reference type: like the TS class, it latches to invalid once the time is up.
final class DateTimeout: DiffTimeout {
    private let startTime = Date()
    private let timeoutMs: Int
    private var valid = true

    init(timeoutMs: Int) {
        // diffAlgorithm.ts throws BugIndicatingError('timeout must be positive').
        precondition(timeoutMs > 0, "timeout must be positive")
        self.timeoutMs = timeoutMs
    }

    func isValid() -> Bool {
        let elapsedMs = Date().timeIntervalSince(startTime) * 1000
        let isStillValid = elapsedMs < Double(timeoutMs)
        if !isStillValid && valid {
            valid = false // timeout reached
        }
        return valid
    }
}

struct DiffAlgorithmResult {
    static func trivial(_ seq1: some DiffSequence, _ seq2: some DiffSequence) -> DiffAlgorithmResult {
        DiffAlgorithmResult(
            diffs: [SequenceDiff(seq1Range: .ofLength(seq1.length), seq2Range: .ofLength(seq2.length))],
            hitTimeout: false
        )
    }

    static func trivialTimedOut(_ seq1: some DiffSequence, _ seq2: some DiffSequence) -> DiffAlgorithmResult {
        DiffAlgorithmResult(
            diffs: [SequenceDiff(seq1Range: .ofLength(seq1.length), seq2Range: .ofLength(seq2.length))],
            hitTimeout: true
        )
    }

    let diffs: [SequenceDiff]
    /// Indicates if the time out was reached. In that case, the diffs might be an approximation.
    let hitTimeout: Bool
}

struct SequenceDiff: Equatable, Sendable {
    static func invert(_ sequenceDiffs: [SequenceDiff], length doc1Length: Int) -> [SequenceDiff] {
        var result: [SequenceDiff] = []
        forEachAdjacent(sequenceDiffs) { a, b in
            result.append(SequenceDiff.fromOffsetPairs(
                a?.getEndExclusives() ?? OffsetPair.zero,
                b?.getStarts() ?? OffsetPair(
                    offset1: doc1Length,
                    offset2: (a.map { $0.seq2Range.endExclusive - $0.seq1Range.endExclusive } ?? 0) + doc1Length
                )
            ))
        }
        return result
    }

    static func fromOffsetPairs(_ start: OffsetPair, _ endExclusive: OffsetPair) -> SequenceDiff {
        SequenceDiff(
            seq1Range: OffsetRange(start: start.offset1, endExclusive: endExclusive.offset1),
            seq2Range: OffsetRange(start: start.offset2, endExclusive: endExclusive.offset2)
        )
    }

    static func assertSorted(_ sequenceDiffs: [SequenceDiff]) {
        var last: SequenceDiff?
        for cur in sequenceDiffs {
            if let last {
                precondition(
                    last.seq1Range.endExclusive <= cur.seq1Range.start && last.seq2Range.endExclusive <= cur.seq2Range.start,
                    "Sequence diffs must be sorted"
                )
            }
            last = cur
        }
    }

    let seq1Range: OffsetRange
    let seq2Range: OffsetRange

    init(seq1Range: OffsetRange, seq2Range: OffsetRange) {
        self.seq1Range = seq1Range
        self.seq2Range = seq2Range
    }

    func swap() -> SequenceDiff {
        SequenceDiff(seq1Range: seq2Range, seq2Range: seq1Range)
    }

    func join(_ other: SequenceDiff) -> SequenceDiff {
        SequenceDiff(seq1Range: seq1Range.join(other.seq1Range), seq2Range: seq2Range.join(other.seq2Range))
    }

    func delta(_ offset: Int) -> SequenceDiff {
        if offset == 0 {
            return self
        }
        return SequenceDiff(seq1Range: seq1Range.delta(offset), seq2Range: seq2Range.delta(offset))
    }

    func deltaStart(_ offset: Int) -> SequenceDiff {
        if offset == 0 {
            return self
        }
        return SequenceDiff(seq1Range: seq1Range.deltaStart(offset), seq2Range: seq2Range.deltaStart(offset))
    }

    func deltaEnd(_ offset: Int) -> SequenceDiff {
        if offset == 0 {
            return self
        }
        return SequenceDiff(seq1Range: seq1Range.deltaEnd(offset), seq2Range: seq2Range.deltaEnd(offset))
    }

    func intersectsOrTouches(_ other: SequenceDiff) -> Bool {
        seq1Range.intersectsOrTouches(other.seq1Range) || seq2Range.intersectsOrTouches(other.seq2Range)
    }

    func intersect(_ other: SequenceDiff) -> SequenceDiff? {
        guard let i1 = seq1Range.intersect(other.seq1Range), let i2 = seq2Range.intersect(other.seq2Range) else {
            return nil
        }
        return SequenceDiff(seq1Range: i1, seq2Range: i2)
    }

    func getStarts() -> OffsetPair {
        OffsetPair(offset1: seq1Range.start, offset2: seq2Range.start)
    }

    func getEndExclusives() -> OffsetPair {
        OffsetPair(offset1: seq1Range.endExclusive, offset2: seq2Range.endExclusive)
    }
}

struct OffsetPair: Equatable, Sendable {
    static let zero = OffsetPair(offset1: 0, offset2: 0)
    static let max = OffsetPair(offset1: DiffTextPosition.maxSafeInteger, offset2: DiffTextPosition.maxSafeInteger)

    let offset1: Int
    let offset2: Int

    func delta(_ offset: Int) -> OffsetPair {
        if offset == 0 {
            return self
        }
        return OffsetPair(offset1: offset1 + offset, offset2: offset2 + offset)
    }

    func equals(_ other: OffsetPair) -> Bool {
        self == other
    }
}

/// Port of base/common/arrays.ts `forEachAdjacent`.
func forEachAdjacent<T>(_ arr: [T], _ f: (T?, T?) -> Void) {
    for i in 0...arr.count {
        f(i == 0 ? nil : arr[i - 1], i == arr.count ? nil : arr[i])
    }
}
