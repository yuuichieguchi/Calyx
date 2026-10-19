// Port of VS Code monospaceLineBreaksComputer.ts (MIT License, Copyright (c) Microsoft Corporation),
// pinned at c2c46e750ab7afe355bad8bea20a248520adfdb0, without injected text and escaped line feeds.

import Foundation

struct DiffLineProjection: Equatable, Sendable {
    var breakOffsets: [Int]
    var breakOffsetsVisibleColumn: [Double]
    var wrappedTextIndentLength: Int

    var segmentCount: Int { breakOffsets.count }
}

enum DiffWrappingIndent: Sendable {
    case none
    case same
    case indent
    case deepIndent
}

enum DiffWordBreak: Sendable {
    case normal
    case keepAll
}

struct WrappingCharacterClassifier: Sendable {
    enum CharacterClass: UInt8, Sendable {
        case none = 0
        case breakBefore = 1
        case breakAfter = 2
        case breakIdeographic = 3
    }

    private var asciiMap: [CharacterClass]
    private var map: [Int: CharacterClass]

    init(breakBefore: String, breakAfter: String) {
        asciiMap = Array(repeating: .none, count: 256)
        map = [:]
        for unit in breakBefore.utf16 { set(Int(unit), .breakBefore) }
        for unit in breakAfter.utf16 { set(Int(unit), .breakAfter) }
    }

    private mutating func set(_ charCode: Int, _ value: CharacterClass) {
        if charCode >= 0 && charCode < 256 {
            asciiMap[charCode] = value
        } else {
            map[charCode] = value
        }
    }

    func get(_ charCode: Int) -> CharacterClass {
        if charCode >= 0 && charCode < 256 {
            return asciiMap[charCode]
        }
        if (charCode >= 0x3040 && charCode <= 0x30FF)
            || (charCode >= 0x3400 && charCode <= 0x4DBF)
            || (charCode >= 0x4E00 && charCode <= 0x9FFF) {
            return .breakIdeographic
        }
        return map[charCode] ?? .none
    }

    func classify(_ units: [UInt16]) -> [UInt8] {
        asciiMap.withUnsafeBufferPointer { ascii in
            units.map { unit in
                let charCode = Int(unit)
                return charCode < 256 ? ascii[charCode].rawValue : get(charCode).rawValue
            }
        }
    }
}

enum DiffLineBreaks {
    static let defaultBreakBeforeCharacters = "([{‘“〈《「『【〔（［｛｢£¥＄￡￥+＋"
    static let defaultBreakAfterCharacters = " \t})]?|/&.,;¢°′″‰℃、。｡､￠，．：；？！％・･ゝゞヽヾーァィゥェォッャュョヮヵヶぁぃぅぇぉっゃゅょゎゕゖㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ々〻ｧｨｩｪｫｬｭｮｯｰ”〉》」』】〕）］｝｣"

    static let defaultClassifier = WrappingCharacterClassifier(
        breakBefore: defaultBreakBeforeCharacters, breakAfter: defaultBreakAfterCharacters)

    static let noneClass = WrappingCharacterClassifier.CharacterClass.none.rawValue
    static let breakBeforeClass = WrappingCharacterClassifier.CharacterClass.breakBefore.rawValue
    static let breakAfterClass = WrappingCharacterClassifier.CharacterClass.breakAfter.rawValue
    static let breakIdeographicClass = WrappingCharacterClassifier.CharacterClass.breakIdeographic.rawValue

    static let tab = 9
    static let space = 32
    static let outOfRange = Int.max

    static func compute(
        _ text: String, tabSize: Int, wrappingColumn: Int, columnsForFullWidthChar: Double,
        wrappingIndent: DiffWrappingIndent, wordBreak: DiffWordBreak, useTwoCellFullwidthCharacters: Bool = false,
        breakBeforeCharacters: String = defaultBreakBeforeCharacters,
        breakAfterCharacters: String = defaultBreakAfterCharacters
    ) -> DiffLineProjection? {
        let units = Array(text.utf16)
        let classes = classifier(breakBeforeCharacters, breakAfterCharacters).classify(units)
        return units.withUnsafeBufferPointer { buffer in
            classes.withUnsafeBufferPointer { classes in
                createLineBreaks(buffer, classes, tabSize: tabSize, firstLineBreakColumn: wrappingColumn,
                                 columnsForFullWidthChar: columnsForFullWidthChar, wrappingIndent: wrappingIndent,
                                 wordBreak: wordBreak, useTwoCellFullwidthCharacters: useTwoCellFullwidthCharacters)
            }
        }
    }

    static func compute(
        _ text: String, previous: DiffLineProjection, tabSize: Int, wrappingColumn: Int,
        columnsForFullWidthChar: Double, wrappingIndent: DiffWrappingIndent, wordBreak: DiffWordBreak,
        useTwoCellFullwidthCharacters: Bool = false,
        breakBeforeCharacters: String = defaultBreakBeforeCharacters,
        breakAfterCharacters: String = defaultBreakAfterCharacters
    ) -> DiffLineProjection? {
        let units = Array(text.utf16)
        let classes = classifier(breakBeforeCharacters, breakAfterCharacters).classify(units)
        return units.withUnsafeBufferPointer { buffer in
            classes.withUnsafeBufferPointer { classes in
                createLineBreaksFromPreviousLineBreaks(
                    previous, buffer, classes, tabSize: tabSize, firstLineBreakColumn: wrappingColumn,
                    columnsForFullWidthChar: columnsForFullWidthChar, wrappingIndent: wrappingIndent,
                    wordBreak: wordBreak, useTwoCellFullwidthCharacters: useTwoCellFullwidthCharacters)
            }
        }
    }

    private static func classifier(_ before: String, _ after: String) -> WrappingCharacterClassifier {
        if before == defaultBreakBeforeCharacters && after == defaultBreakAfterCharacters {
            return defaultClassifier
        }
        return WrappingCharacterClassifier(breakBefore: before, breakAfter: after)
    }

    @inline(__always)
    static func isHighSurrogate(_ charCode: Int) -> Bool {
        charCode >= 0xD800 && charCode <= 0xDBFF
    }

    @inline(__always)
    static func isLowSurrogate(_ charCode: Int) -> Bool {
        charCode >= 0xDC00 && charCode <= 0xDFFF
    }

    @inline(__always)
    static func isFullWidthCharacter(_ charCode: Int) -> Bool {
        (charCode >= 0x2E80 && charCode <= 0xD7AF)
            || (charCode >= 0xF900 && charCode <= 0xFAFF)
            || (charCode >= 0xFF01 && charCode <= 0xFF5E)
    }

    @inline(__always)
    static func fullWidthCharacterColumns(_ columnsForFullWidthChar: Double, _ useTwoCellFullwidthCharacters: Bool) -> Double {
        useTwoCellFullwidthCharacters ? 2 : columnsForFullWidthChar
    }

    @inline(__always)
    static func tabCharacterWidth(_ visibleColumn: Double, _ tabSize: Int) -> Double {
        let size = Double(tabSize)
        return size - visibleColumn.truncatingRemainder(dividingBy: size)
    }

    @inline(__always)
    static func computeCharWidth(_ charCode: Int, _ visibleColumn: Double, _ tabSize: Int,
                                 _ columnsForFullWidthChar: Double, _ useTwoCellFullwidthCharacters: Bool) -> Double {
        if charCode == tab {
            return tabCharacterWidth(visibleColumn, tabSize)
        }
        if isFullWidthCharacter(charCode) {
            return fullWidthCharacterColumns(columnsForFullWidthChar, useTwoCellFullwidthCharacters)
        }
        if charCode < 32 {
            return columnsForFullWidthChar
        }
        return 1
    }

    @inline(__always)
    static func canBreak(_ prevCharCode: Int, _ prevCharCodeClass: UInt8,
                         _ charCode: Int, _ charCodeClass: UInt8, _ isKeepAll: Bool) -> Bool {
        charCode != space
            && (
                (prevCharCodeClass == breakAfterClass && charCodeClass != breakAfterClass)
                || (prevCharCodeClass != breakBeforeClass && charCodeClass == breakBeforeClass)
                || (!isKeepAll && prevCharCodeClass == breakIdeographicClass && charCodeClass != breakAfterClass)
                || (!isKeepAll && charCodeClass == breakIdeographicClass && prevCharCodeClass != breakBeforeClass)
            )
    }

    static func computeWrappedTextIndentLength(_ lineText: UnsafeBufferPointer<UInt16>, tabSize: Int,
                                               firstLineBreakColumn: Int, columnsForFullWidthChar: Double,
                                               wrappingIndent: DiffWrappingIndent) -> Int {
        var wrappedTextIndentLength = 0
        if case .none = wrappingIndent { return 0 }
        var firstNonWhitespaceIndex = 0
        while firstNonWhitespaceIndex < lineText.count,
              Int(lineText[firstNonWhitespaceIndex]) == space || Int(lineText[firstNonWhitespaceIndex]) == tab {
            firstNonWhitespaceIndex += 1
        }
        guard firstNonWhitespaceIndex < lineText.count else { return 0 }
        var i = 0
        while i < firstNonWhitespaceIndex {
            let charWidth = Int(lineText[i]) == tab
                ? Int(tabCharacterWidth(Double(wrappedTextIndentLength), tabSize)) : 1
            wrappedTextIndentLength += charWidth
            i += 1
        }
        let numberOfAdditionalTabs: Int
        switch wrappingIndent {
        case .deepIndent: numberOfAdditionalTabs = 2
        case .indent: numberOfAdditionalTabs = 1
        case .same, .none: numberOfAdditionalTabs = 0
        }
        var tabIndex = 0
        while tabIndex < numberOfAdditionalTabs {
            wrappedTextIndentLength += Int(tabCharacterWidth(Double(wrappedTextIndentLength), tabSize))
            tabIndex += 1
        }
        if Double(wrappedTextIndentLength) + columnsForFullWidthChar > Double(firstLineBreakColumn) {
            wrappedTextIndentLength = 0
        }
        return wrappedTextIndentLength
    }

    static func createLineBreaks(
        _ lineText: UnsafeBufferPointer<UInt16>, _ classes: UnsafeBufferPointer<UInt8>, tabSize: Int,
        firstLineBreakColumn: Int, columnsForFullWidthChar: Double, wrappingIndent: DiffWrappingIndent,
        wordBreak: DiffWordBreak, useTwoCellFullwidthCharacters: Bool
    ) -> DiffLineProjection? {
        if firstLineBreakColumn == -1 { return nil }
        let len = lineText.count
        if len <= 1 { return nil }

        let isKeepAll: Bool
        if case .keepAll = wordBreak { isKeepAll = true } else { isKeepAll = false }
        let wrappedTextIndentLength = computeWrappedTextIndentLength(
            lineText, tabSize: tabSize, firstLineBreakColumn: firstLineBreakColumn,
            columnsForFullWidthChar: fullWidthCharacterColumns(columnsForFullWidthChar, useTwoCellFullwidthCharacters),
            wrappingIndent: wrappingIndent)
        let wrappedLineBreakWidth = Double(firstLineBreakColumn - wrappedTextIndentLength)

        var breakingOffsets: [Int] = []
        var breakingOffsetsVisibleColumn: [Double] = []
        var breakOffset = 0
        var breakOffsetVisibleColumn: Double = 0
        var breakingWidth = Double(firstLineBreakColumn)

        var prevCharCode = Int(lineText[0])
        var visibleColumn = computeCharWidth(prevCharCode, 0, tabSize, columnsForFullWidthChar, useTwoCellFullwidthCharacters)
        var startOffset = 1
        if isHighSurrogate(prevCharCode) {
            visibleColumn += 1
            prevCharCode = Int(lineText[1])
            startOffset += 1
        }
        var prevCharCodeClass = classes[startOffset - 1]

        var i = startOffset
        while i < len {
            let charStartOffset = i
            let charCode = Int(lineText[i])
            let charCodeClass: UInt8
            let charWidth: Double
            if isHighSurrogate(charCode) {
                i += 1
                charCodeClass = noneClass
                charWidth = 2
            } else {
                charCodeClass = classes[i]
                charWidth = computeCharWidth(charCode, visibleColumn, tabSize, columnsForFullWidthChar, useTwoCellFullwidthCharacters)
            }

            if canBreak(prevCharCode, prevCharCodeClass, charCode, charCodeClass, isKeepAll) {
                breakOffset = charStartOffset
                breakOffsetVisibleColumn = visibleColumn
            }

            visibleColumn += charWidth

            if visibleColumn > breakingWidth {
                if breakOffset == 0 || visibleColumn - breakOffsetVisibleColumn > wrappedLineBreakWidth {
                    breakOffset = charStartOffset
                    breakOffsetVisibleColumn = visibleColumn - charWidth
                }
                let currentLineStartOffset = breakingOffsets.last ?? 0
                if breakOffset > currentLineStartOffset {
                    breakingOffsets.append(breakOffset)
                    breakingOffsetsVisibleColumn.append(breakOffsetVisibleColumn)
                    breakingWidth = breakOffsetVisibleColumn + wrappedLineBreakWidth
                    breakOffset = 0
                }
            }

            prevCharCode = charCode
            prevCharCodeClass = charCodeClass
            i += 1
        }

        if breakingOffsets.isEmpty { return nil }
        breakingOffsets.append(len)
        breakingOffsetsVisibleColumn.append(visibleColumn)
        return DiffLineProjection(breakOffsets: breakingOffsets, breakOffsetsVisibleColumn: breakingOffsetsVisibleColumn,
                                  wrappedTextIndentLength: wrappedTextIndentLength)
    }

    static func createLineBreaksFromPreviousLineBreaks(
        _ previousBreakingData: DiffLineProjection,
        _ lineText: UnsafeBufferPointer<UInt16>, _ classes: UnsafeBufferPointer<UInt8>, tabSize: Int,
        firstLineBreakColumn: Int, columnsForFullWidthChar: Double, wrappingIndent: DiffWrappingIndent,
        wordBreak: DiffWordBreak, useTwoCellFullwidthCharacters: Bool
    ) -> DiffLineProjection? {
        var breakingOffsets: [Int] = []
        var breakingOffsetsVisibleColumn: [Double] = []
        guard let indent = createLineBreaksFromPreviousLineBreaks(
            previousBreakingData, lineText, classes, tabSize: tabSize, firstLineBreakColumn: firstLineBreakColumn,
            columnsForFullWidthChar: columnsForFullWidthChar, wrappingIndent: wrappingIndent, wordBreak: wordBreak,
            useTwoCellFullwidthCharacters: useTwoCellFullwidthCharacters,
            breakingOffsets: &breakingOffsets, breakingOffsetsVisibleColumn: &breakingOffsetsVisibleColumn) else {
            return nil
        }
        return DiffLineProjection(breakOffsets: breakingOffsets, breakOffsetsVisibleColumn: breakingOffsetsVisibleColumn,
                                  wrappedTextIndentLength: indent)
    }

    static func createLineBreaksFromPreviousLineBreaks(
        _ previousBreakingData: DiffLineProjection,
        _ lineText: UnsafeBufferPointer<UInt16>, _ classes: UnsafeBufferPointer<UInt8>, tabSize: Int,
        firstLineBreakColumn: Int, columnsForFullWidthChar: Double, wrappingIndent: DiffWrappingIndent,
        wordBreak: DiffWordBreak, useTwoCellFullwidthCharacters: Bool,
        breakingOffsets: inout [Int], breakingOffsetsVisibleColumn: inout [Double]
    ) -> Int? {
        if firstLineBreakColumn == -1 { return nil }
        let len = lineText.count
        if len <= 1 { return nil }

        let isKeepAll: Bool
        if case .keepAll = wordBreak { isKeepAll = true } else { isKeepAll = false }
        return previousBreakingData.breakOffsets.withUnsafeBufferPointer { prevOffsets in
            previousBreakingData.breakOffsetsVisibleColumn.withUnsafeBufferPointer { prevVisibleColumns in
                createLineBreaksFromPreviousLineBreaks(
                    prevOffsets, prevVisibleColumns, lineText, classes, tabSize: tabSize,
                    firstLineBreakColumn: firstLineBreakColumn, columnsForFullWidthChar: columnsForFullWidthChar,
                    wrappingIndent: wrappingIndent, isKeepAll: isKeepAll,
                    useTwoCellFullwidthCharacters: useTwoCellFullwidthCharacters,
                    breakingOffsets: &breakingOffsets, breakingOffsetsVisibleColumn: &breakingOffsetsVisibleColumn)
            }
        }
    }

    private static func createLineBreaksFromPreviousLineBreaks(
        _ prevBreakingOffsets: UnsafeBufferPointer<Int>,
        _ prevBreakingOffsetsVisibleColumn: UnsafeBufferPointer<Double>,
        _ lineText: UnsafeBufferPointer<UInt16>, _ classes: UnsafeBufferPointer<UInt8>, tabSize: Int, firstLineBreakColumn: Int,
        columnsForFullWidthChar: Double, wrappingIndent: DiffWrappingIndent, isKeepAll: Bool,
        useTwoCellFullwidthCharacters: Bool,
        breakingOffsets: inout [Int], breakingOffsetsVisibleColumn: inout [Double]
    ) -> Int? {
        let len = lineText.count
        let fullWidthColumns = fullWidthCharacterColumns(columnsForFullWidthChar, useTwoCellFullwidthCharacters)
        var breakingOffsetsCount = 0

        let wrappedTextIndentLength = computeWrappedTextIndentLength(
            lineText, tabSize: tabSize, firstLineBreakColumn: firstLineBreakColumn,
            columnsForFullWidthChar: fullWidthColumns, wrappingIndent: wrappingIndent)
        let wrappedLineBreakColumn = Double(firstLineBreakColumn - wrappedTextIndentLength)

        var lastBreakingOffset = 0
        var lastBreakingOffsetVisibleColumn: Double = 0

        var breakingColumn = Double(firstLineBreakColumn)
        let prevLen = prevBreakingOffsets.count
        var prevIndex = 0

        if prevIndex >= 0 {
            var bestDistance = (prevBreakingOffsetsVisibleColumn[prevIndex] - breakingColumn).magnitude
            while prevIndex + 1 < prevLen {
                let distance = (prevBreakingOffsetsVisibleColumn[prevIndex + 1] - breakingColumn).magnitude
                if distance >= bestDistance { break }
                bestDistance = distance
                prevIndex += 1
            }
        }

        while prevIndex < prevLen {
            var prevBreakOffset = prevIndex < 0 ? 0 : prevBreakingOffsets[prevIndex]
            var prevBreakOffsetVisibleColumn = prevIndex < 0 ? 0 : prevBreakingOffsetsVisibleColumn[prevIndex]
            if lastBreakingOffset > prevBreakOffset {
                prevBreakOffset = lastBreakingOffset
                prevBreakOffsetVisibleColumn = lastBreakingOffsetVisibleColumn
            }

            var breakOffset = 0
            var breakOffsetVisibleColumn: Double = 0
            var forcedBreakOffset = 0
            var forcedBreakOffsetVisibleColumn: Double = 0

            if prevBreakOffsetVisibleColumn <= breakingColumn {
                var visibleColumn = prevBreakOffsetVisibleColumn
                var prevCharCode = prevBreakOffset == 0 ? 0 : ((prevBreakOffset - 1) < len ? Int(lineText[prevBreakOffset - 1]) : outOfRange)
                var prevCharCodeClass: UInt8 = prevBreakOffset == 0
                    ? noneClass : (prevBreakOffset - 1 < len ? classes[prevBreakOffset - 1] : noneClass)
                var entireLineFits = true
                var i = prevBreakOffset
                while i < len {
                    let charStartOffset = i
                    let charCode = ((i) < len ? Int(lineText[i]) : outOfRange)
                    let charCodeClass: UInt8
                    let charWidth: Double
                    if isHighSurrogate(charCode) {
                        i += 1
                        charCodeClass = noneClass
                        charWidth = 2
                    } else {
                        charCodeClass = classes[i]
                        charWidth = computeCharWidth(charCode, visibleColumn, tabSize, columnsForFullWidthChar, useTwoCellFullwidthCharacters)
                    }

                    if charStartOffset > lastBreakingOffset
                        && canBreak(prevCharCode, prevCharCodeClass, charCode, charCodeClass, isKeepAll) {
                        breakOffset = charStartOffset
                        breakOffsetVisibleColumn = visibleColumn
                    }

                    visibleColumn += charWidth

                    if visibleColumn > breakingColumn {
                        if charStartOffset > lastBreakingOffset {
                            forcedBreakOffset = charStartOffset
                            forcedBreakOffsetVisibleColumn = visibleColumn - charWidth
                        } else {
                            forcedBreakOffset = i + 1
                            forcedBreakOffsetVisibleColumn = visibleColumn
                        }
                        if visibleColumn - breakOffsetVisibleColumn > wrappedLineBreakColumn {
                            breakOffset = 0
                        }
                        entireLineFits = false
                        break
                    }

                    prevCharCode = charCode
                    prevCharCodeClass = charCodeClass
                    i += 1
                }

                if entireLineFits {
                    if breakingOffsetsCount > 0 {
                        store(prevBreakingOffsets[prevBreakingOffsets.count - 1],
                              prevBreakingOffsetsVisibleColumn[prevBreakingOffsets.count - 1], at: breakingOffsetsCount,
                              &breakingOffsets, &breakingOffsetsVisibleColumn)
                        breakingOffsetsCount += 1
                    }
                    break
                }
            }

            if breakOffset == 0 {
                var visibleColumn = prevBreakOffsetVisibleColumn
                var charCode = ((prevBreakOffset) < len ? Int(lineText[prevBreakOffset]) : outOfRange)
                var charCodeClass = prevBreakOffset < len ? classes[prevBreakOffset] : noneClass
                var hitATabCharacter = false
                var i = prevBreakOffset - 1
                while i >= lastBreakingOffset {
                    let charStartOffset = i + 1
                    let prevCharCode = ((i) < len ? Int(lineText[i]) : outOfRange)

                    if prevCharCode == tab {
                        hitATabCharacter = true
                        break
                    }

                    let prevCharCodeClass: UInt8
                    let prevCharWidth: Double
                    if isLowSurrogate(prevCharCode) {
                        i -= 1
                        prevCharCodeClass = noneClass
                        prevCharWidth = 2
                    } else {
                        prevCharCodeClass = classes[i]
                        prevCharWidth = isFullWidthCharacter(prevCharCode) ? fullWidthColumns : 1
                    }

                    if visibleColumn <= breakingColumn {
                        if forcedBreakOffset == 0 {
                            forcedBreakOffset = charStartOffset
                            forcedBreakOffsetVisibleColumn = visibleColumn
                        }
                        if visibleColumn <= breakingColumn - wrappedLineBreakColumn {
                            break
                        }
                        if canBreak(prevCharCode, prevCharCodeClass, charCode, charCodeClass, isKeepAll) {
                            breakOffset = charStartOffset
                            breakOffsetVisibleColumn = visibleColumn
                            break
                        }
                    }

                    visibleColumn -= prevCharWidth
                    charCode = prevCharCode
                    charCodeClass = prevCharCodeClass
                    i -= 1
                }

                if breakOffset != 0 {
                    let remainingWidthOfNextLine = wrappedLineBreakColumn - (forcedBreakOffsetVisibleColumn - breakOffsetVisibleColumn)
                    if remainingWidthOfNextLine <= Double(tabSize) {
                        let charCodeAtForcedBreakOffset = ((forcedBreakOffset) < len ? Int(lineText[forcedBreakOffset]) : outOfRange)
                        let charWidth: Double
                        if isHighSurrogate(charCodeAtForcedBreakOffset) {
                            charWidth = 2
                        } else {
                            charWidth = computeCharWidth(charCodeAtForcedBreakOffset, forcedBreakOffsetVisibleColumn, tabSize,
                                                         columnsForFullWidthChar, useTwoCellFullwidthCharacters)
                        }
                        if remainingWidthOfNextLine - charWidth < 0 {
                            breakOffset = 0
                        }
                    }
                }

                if hitATabCharacter {
                    prevIndex -= 1
                    continue
                }
            }

            if breakOffset == 0 {
                breakOffset = forcedBreakOffset
                breakOffsetVisibleColumn = forcedBreakOffsetVisibleColumn
            }

            if breakOffset <= lastBreakingOffset {
                let charCode = ((lastBreakingOffset) < len ? Int(lineText[lastBreakingOffset]) : outOfRange)
                if isHighSurrogate(charCode) {
                    breakOffset = lastBreakingOffset + 2
                    breakOffsetVisibleColumn = lastBreakingOffsetVisibleColumn + 2
                } else {
                    breakOffset = lastBreakingOffset + 1
                    breakOffsetVisibleColumn = lastBreakingOffsetVisibleColumn
                        + computeCharWidth(charCode, lastBreakingOffsetVisibleColumn, tabSize,
                                           columnsForFullWidthChar, useTwoCellFullwidthCharacters)
                }
            }

            lastBreakingOffset = breakOffset
            store(breakOffset, breakOffsetVisibleColumn, at: breakingOffsetsCount,
                  &breakingOffsets, &breakingOffsetsVisibleColumn)
            breakingOffsetsCount += 1
            lastBreakingOffsetVisibleColumn = breakOffsetVisibleColumn
            breakingColumn = breakOffsetVisibleColumn + wrappedLineBreakColumn

            while prevIndex < 0 || (prevIndex < prevLen && prevBreakingOffsetsVisibleColumn[prevIndex] < breakOffsetVisibleColumn) {
                prevIndex += 1
            }

            if prevIndex < prevLen {
                var bestDistance = (prevBreakingOffsetsVisibleColumn[prevIndex] - breakingColumn).magnitude
                while prevIndex + 1 < prevLen {
                    let distance = (prevBreakingOffsetsVisibleColumn[prevIndex + 1] - breakingColumn).magnitude
                    if distance >= bestDistance { break }
                    bestDistance = distance
                    prevIndex += 1
                }
            }
        }

        if breakingOffsets.count > breakingOffsetsCount {
            breakingOffsets.removeLast(breakingOffsets.count - breakingOffsetsCount)
            breakingOffsetsVisibleColumn.removeLast(breakingOffsetsVisibleColumn.count - breakingOffsetsCount)
        }
        if breakingOffsetsCount == 0 { return nil }
        return wrappedTextIndentLength
    }

    @inline(__always)
    private static func store(_ offset: Int, _ visibleColumn: Double, at index: Int,
                              _ offsets: inout [Int], _ visibleColumns: inout [Double]) {
        if index < offsets.count {
            offsets[index] = offset
            visibleColumns[index] = visibleColumn
        } else {
            offsets.append(offset)
            visibleColumns.append(visibleColumn)
        }
    }
}
