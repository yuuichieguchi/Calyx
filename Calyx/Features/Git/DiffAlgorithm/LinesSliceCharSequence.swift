// LinesSliceCharSequence.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/linesSliceCharSequence.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).
// Elements are UTF-16 code units, matching JS `charCodeAt`.

import Foundation

struct LinesSliceCharSequence: DiffSequence {
    let lines: [String]
    private let range: DiffTextRange
    let considerWhitespaceChanges: Bool

    private var elements: [Int] = []
    private var firstElementOffsetByLineIdx: [Int] = []
    private var lineStartOffsets: [Int] = []
    private var trimmedWsLengthsByLineIdx: [Int] = []

    init(lines: [String], range: DiffTextRange, considerWhitespaceChanges: Bool) {
        self.lines = lines
        self.range = range
        self.considerWhitespaceChanges = considerWhitespaceChanges

        firstElementOffsetByLineIdx.append(0)
        var lineNumber = range.startLineNumber
        while lineNumber <= range.endLineNumber {
            let fullLine = Array(lines[lineNumber - 1].utf16)
            var line = fullLine[...]
            var lineStartOffset = 0
            if lineNumber == range.startLineNumber && range.startColumn > 1 {
                lineStartOffset = range.startColumn - 1
                // JS substring clamps to the string length.
                line = fullLine[min(lineStartOffset, fullLine.count)...]
            }
            lineStartOffsets.append(lineStartOffset)

            var trimmedWsLength = 0
            if !considerWhitespaceChanges {
                let trimmedStartLine = jsTrimStart(line)
                trimmedWsLength = line.count - trimmedStartLine.count
                line = jsTrimEnd(trimmedStartLine)
            }
            trimmedWsLengthsByLineIdx.append(trimmedWsLength)

            let lineLength = lineNumber == range.endLineNumber
                ? min(range.endColumn - 1 - lineStartOffset - trimmedWsLength, line.count)
                : line.count
            var i = 0
            var index = line.startIndex
            while i < lineLength {
                elements.append(Int(line[index]))
                i += 1
                index += 1
            }

            if lineNumber < range.endLineNumber {
                elements.append(CharCode.lineFeed)
                firstElementOffsetByLineIdx.append(elements.count)
            }
            lineNumber += 1
        }
    }

    var text: String {
        getText(OffsetRange(start: 0, endExclusive: length))
    }

    func getText(_ range: OffsetRange) -> String {
        let units = elements[range.start..<range.endExclusive].map { UInt16(truncatingIfNeeded: $0) }
        return String(decoding: units, as: UTF16.self)
    }

    func getElement(_ offset: Int) -> Int {
        elements[offset]
    }

    var length: Int {
        elements.count
    }

    func getBoundaryScore(_ length: Int) -> Int? {
        //   a   b   c   ,           d   e   f
        // 11  0   0   12  15  6   13  0   0   11

        let prevCategory = getCategory(length > 0 ? elements[length - 1] : -1)
        let nextCategory = getCategory(length < elements.count ? elements[length] : -1)

        if prevCategory == .lineBreakCR && nextCategory == .lineBreakLF {
            // don't break between \r and \n
            return 0
        }
        if prevCategory == .lineBreakLF {
            // prefer the linebreak before the change
            return 150
        }

        var score = 0
        if prevCategory != nextCategory {
            score += 10
            if prevCategory == .wordLower && nextCategory == .wordUpper {
                score += 1
            }
        }

        score += getCategoryBoundaryScore(prevCategory)
        score += getCategoryBoundaryScore(nextCategory)

        return score
    }

    enum OffsetPreference {
        case left
        case right
    }

    func translateOffset(_ offset: Int, _ preference: OffsetPreference = .right) -> DiffTextPosition {
        // find smallest i, so that lineBreakOffsets[i] <= offset using binary search
        let i = findLastIdxMonotonous(firstElementOffsetByLineIdx) { $0 <= offset }
        let lineOffset = offset - firstElementOffsetByLineIdx[i]
        return DiffTextPosition(
            lineNumber: range.startLineNumber + i,
            column: 1 + lineStartOffsets[i] + lineOffset
                + ((lineOffset == 0 && preference == .left) ? 0 : trimmedWsLengthsByLineIdx[i])
        )
    }

    func translateRange(_ range: OffsetRange) -> DiffTextRange {
        let pos1 = translateOffset(range.start, .right)
        let pos2 = translateOffset(range.endExclusive, .left)
        if pos2.isBefore(pos1) {
            return DiffTextRange.fromPositions(pos2, pos2)
        }
        return DiffTextRange.fromPositions(pos1, pos2)
    }

    /// Finds the word that contains the character at the given offset.
    func findWordContaining(_ offset: Int) -> OffsetRange? {
        if offset < 0 || offset >= elements.count {
            return nil
        }

        if !isWordChar(elements[offset]) {
            return nil
        }

        // find start
        var start = offset
        while start > 0 && isWordChar(elements[start - 1]) {
            start -= 1
        }

        // find end
        var end = offset
        while end < elements.count && isWordChar(elements[end]) {
            end += 1
        }

        return OffsetRange(start: start, endExclusive: end)
    }

    /// fooBar has the two sub-words foo and bar.
    func findSubWordContaining(_ offset: Int) -> OffsetRange? {
        if offset < 0 || offset >= elements.count {
            return nil
        }

        if !isWordChar(elements[offset]) {
            return nil
        }

        // find start
        var start = offset
        while start > 0 && isWordChar(elements[start - 1]) && !isUpperCase(elements[start]) {
            start -= 1
        }

        // find end
        var end = offset
        while end < elements.count && isWordChar(elements[end]) && !isUpperCase(elements[end]) {
            end += 1
        }

        return OffsetRange(start: start, endExclusive: end)
    }

    func countLinesIn(_ range: OffsetRange) -> Int {
        translateOffset(range.endExclusive).lineNumber - translateOffset(range.start).lineNumber
    }

    func isStronglyEqual(_ offset1: Int, _ offset2: Int) -> Bool {
        elements[offset1] == elements[offset2]
    }

    func extendToFullLines(_ range: OffsetRange) -> OffsetRange {
        let start = findLastMonotonous(firstElementOffsetByLineIdx) { $0 <= range.start } ?? 0
        let end = findFirstMonotonous(firstElementOffsetByLineIdx) { range.endExclusive <= $0 } ?? elements.count
        return OffsetRange(start: start, endExclusive: end)
    }
}

private func isWordChar(_ charCode: Int) -> Bool {
    (charCode >= CharCode.lowerA && charCode <= CharCode.lowerZ)
        || (charCode >= CharCode.upperA && charCode <= CharCode.upperZ)
        || (charCode >= CharCode.digit0 && charCode <= CharCode.digit9)
}

private func isUpperCase(_ charCode: Int) -> Bool {
    charCode >= CharCode.upperA && charCode <= CharCode.upperZ
}

private enum CharBoundaryCategory {
    case wordLower
    case wordUpper
    case wordNumber
    case end
    case other
    case separator
    case space
    case lineBreakCR
    case lineBreakLF
}

private func getCategoryBoundaryScore(_ category: CharBoundaryCategory) -> Int {
    switch category {
    case .wordLower: return 0
    case .wordUpper: return 0
    case .wordNumber: return 0
    case .end: return 10
    case .other: return 2
    case .separator: return 30
    case .space: return 3
    case .lineBreakCR: return 10
    case .lineBreakLF: return 10
    }
}

private func getCategory(_ charCode: Int) -> CharBoundaryCategory {
    if charCode == CharCode.lineFeed {
        return .lineBreakLF
    } else if charCode == CharCode.carriageReturn {
        return .lineBreakCR
    } else if isSpace(charCode) {
        return .space
    } else if charCode >= CharCode.lowerA && charCode <= CharCode.lowerZ {
        return .wordLower
    } else if charCode >= CharCode.upperA && charCode <= CharCode.upperZ {
        return .wordUpper
    } else if charCode >= CharCode.digit0 && charCode <= CharCode.digit9 {
        return .wordNumber
    } else if charCode == -1 {
        return .end
    } else if charCode == CharCode.comma || charCode == CharCode.semicolon {
        return .separator
    } else {
        return .other
    }
}

// MARK: - base/common/arraysFind.ts

/// Index of the last item where `predicate` is true (predicate must be monotonous:
/// true...true false...false); -1 if none.
func findLastIdxMonotonous<T>(_ array: [T], _ predicate: (T) -> Bool) -> Int {
    var i = 0
    var j = array.count
    while i < j {
        let k = (i + j) / 2
        if predicate(array[k]) {
            i = k + 1
        } else {
            j = k
        }
    }
    return i - 1
}

func findLastMonotonous<T>(_ array: [T], _ predicate: (T) -> Bool) -> T? {
    let idx = findLastIdxMonotonous(array, predicate)
    return idx == -1 ? nil : array[idx]
}

/// Index of the first item where `predicate` is true (false...false true...true); array.count if none.
func findFirstIdxMonotonousOrArrLen<T>(_ array: [T], _ predicate: (T) -> Bool) -> Int {
    var i = 0
    var j = array.count
    while i < j {
        let k = (i + j) / 2
        if predicate(array[k]) {
            j = k
        } else {
            i = k + 1
        }
    }
    return i
}

func findFirstMonotonous<T>(_ array: [T], _ predicate: (T) -> Bool) -> T? {
    let idx = findFirstIdxMonotonousOrArrLen(array, predicate)
    return idx == array.count ? nil : array[idx]
}
