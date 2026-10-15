// MyersDiffAlgorithm.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/myersDiffAlgorithm.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).

import Foundation

/// An O(ND) diff algorithm that has a quadratic space worst-case complexity.
struct MyersDiffAlgorithm {
    func compute(_ seq1: some DiffSequence, _ seq2: some DiffSequence, timeout: some DiffTimeout = InfiniteTimeout.instance) -> DiffAlgorithmResult {
        // These are common special cases. The early return improves performance dramatically.
        if seq1.length == 0 || seq2.length == 0 {
            return DiffAlgorithmResult.trivial(seq1, seq2)
        }

        let seqX = seq1 // Text on the x axis
        let seqY = seq2 // Text on the y axis
        let seqXLength = seqX.length
        let seqYLength = seqY.length

        func getXAfterSnake(_ x0: Int, _ y0: Int) -> Int {
            var x = x0
            var y = y0
            while x < seqXLength && y < seqYLength && seqX.getElement(x) == seqY.getElement(y) {
                x += 1
                y += 1
            }
            return x
        }

        var d = 0
        // V[k]: X value of longest d-line that ends in diagonal k.
        var V = FastIntArrayNegativeIndices()
        V.set(0, getXAfterSnake(0, 0))

        var paths = FastArrayNegativeIndices<SnakePath>()
        paths.set(0, V.get(0) == 0 ? nil : SnakePath(prev: nil, x: 0, y: 0, length: V.get(0)))

        var k = 0

        loop: while true {
            d += 1
            if !timeout.isValid() {
                return DiffAlgorithmResult.trivialTimedOut(seqX, seqY)
            }
            // The paper has `for (k = -d; k <= d; k += 2)`, but we can ignore diagonals that cannot influence the result.
            let lowerBound = -min(d, seqYLength + (d % 2))
            let upperBound = min(d, seqXLength + (d % 2))
            // `for (k = lowerBound; k <= upperBound; k += 2)`; k must keep its value on `break loop`.
            k = lowerBound - 2
            while k + 2 <= upperBound {
                k += 2
                // We can use the X values of (d-1)-lines to compute X value of the longest d-lines.
                let maxXofDLineTop = k == upperBound ? -1 : V.get(k + 1) // vertical non-diagonal (add a symbol in seqX)
                let maxXofDLineLeft = k == lowerBound ? -1 : V.get(k - 1) + 1 // horizontal non-diagonal (delete a symbol in seqX)
                let x = min(max(maxXofDLineTop, maxXofDLineLeft), seqXLength)
                let y = x - k
                if x > seqXLength || y > seqYLength {
                    // This diagonal is irrelevant for the result.
                    continue
                }
                let newMaxX = getXAfterSnake(x, y)
                V.set(k, newMaxX)
                let lastPath = x == maxXofDLineTop ? paths.get(k + 1) : paths.get(k - 1)
                paths.set(k, newMaxX != x ? SnakePath(prev: lastPath, x: x, y: y, length: newMaxX - x) : lastPath)

                if V.get(k) == seqXLength && V.get(k) - k == seqYLength {
                    break loop
                }
            }
        }

        var path = paths.get(k)
        var result: [SequenceDiff] = []
        var lastAligningPosS1 = seqXLength
        var lastAligningPosS2 = seqYLength

        while true {
            let endX = path.map { $0.x + $0.length } ?? 0
            let endY = path.map { $0.y + $0.length } ?? 0

            if endX != lastAligningPosS1 || endY != lastAligningPosS2 {
                result.append(SequenceDiff(
                    seq1Range: OffsetRange(start: endX, endExclusive: lastAligningPosS1),
                    seq2Range: OffsetRange(start: endY, endExclusive: lastAligningPosS2)
                ))
            }
            guard let current = path else {
                break
            }
            lastAligningPosS1 = current.x
            lastAligningPosS2 = current.y

            path = current.prev
        }

        result.reverse()
        return DiffAlgorithmResult(diffs: result, hitTimeout: false)
    }
}

private final class SnakePath {
    let prev: SnakePath?
    let x: Int
    let y: Int
    let length: Int

    init(prev: SnakePath?, x: Int, y: Int, length: Int) {
        self.prev = prev
        self.x = x
        self.y = y
        self.length = length
    }
}

/// TS `FastInt32Array`: supports negative indices. Slots that were never set
/// read as 0, like the zero-initialised Int32Array backing store in TS.
private struct FastIntArrayNegativeIndices {
    private var positiveArr = [Int](repeating: 0, count: 10)
    private var negativeArr = [Int](repeating: 0, count: 10)

    func get(_ idx: Int) -> Int {
        if idx < 0 {
            let i = -idx - 1
            return i < negativeArr.count ? negativeArr[i] : 0
        }
        return idx < positiveArr.count ? positiveArr[idx] : 0
    }

    mutating func set(_ idx: Int, _ value: Int) {
        if idx < 0 {
            let i = -idx - 1
            if i >= negativeArr.count {
                negativeArr.append(contentsOf: [Int](repeating: 0, count: Swift.max(negativeArr.count, i + 1 - negativeArr.count)))
            }
            negativeArr[i] = value
        } else {
            if idx >= positiveArr.count {
                positiveArr.append(contentsOf: [Int](repeating: 0, count: Swift.max(positiveArr.count, idx + 1 - positiveArr.count)))
            }
            positiveArr[idx] = value
        }
    }
}

/// TS `FastArrayNegativeIndices<SnakePath | null>`: unset slots read as nil.
private struct FastArrayNegativeIndices<T> {
    private var positiveArr: [T?] = []
    private var negativeArr: [T?] = []

    func get(_ idx: Int) -> T? {
        if idx < 0 {
            let i = -idx - 1
            return i < negativeArr.count ? negativeArr[i] : nil
        }
        return idx < positiveArr.count ? positiveArr[idx] : nil
    }

    mutating func set(_ idx: Int, _ value: T?) {
        if idx < 0 {
            let i = -idx - 1
            if i >= negativeArr.count {
                negativeArr.append(contentsOf: [T?](repeating: nil, count: i + 1 - negativeArr.count))
            }
            negativeArr[i] = value
        } else {
            if idx >= positiveArr.count {
                positiveArr.append(contentsOf: [T?](repeating: nil, count: idx + 1 - positiveArr.count))
            }
            positiveArr[idx] = value
        }
    }
}
