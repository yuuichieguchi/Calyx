import AppKit

struct DiffRowText: Equatable, Sendable {
    let markerLength: Int
    let markerColumns: Int
    let units: [UInt16]
    let columns: [Double]

    var totalColumns: Double { columns[columns.count - 1] }
}

struct DiffPaneWrap: Equatable, Sendable {
    let column: Int?
    let projections: [DiffLineProjection?]
    let segmentCounts: [Int]

    static func unwrapped(rowCount: Int) -> DiffPaneWrap {
        DiffPaneWrap(column: nil, projections: Array(repeating: nil, count: rowCount),
                     segmentCounts: Array(repeating: 1, count: rowCount))
    }
}

struct DiffPaneText {
    static let tabSize = 4
    static let columnsForFullWidthChar: Double = 2
    static let wrappingIndent = DiffWrappingIndent.same
    static let commentSymbol: UInt16 = 0xFFFC
    static let commentSymbolColumns = 2

    let attributed: NSAttributedString
    let string: String
    let nsString: NSString
    let rowRanges: [NSRange]
    let rowTexts: [DiffRowText]
    let widestRowColumns: Double
    private let contentUnits: [UInt16]
    private let contentClasses: [UInt8]
    private let contentStarts: [Int]
    private let totalColumns: [Double]
    private let rowMarkerColumns: [Int]

    init(cells: [DiffCell?], attributed: NSAttributedString) {
        self.attributed = attributed
        string = attributed.string
        nsString = attributed.string as NSString
        let units = Array(string.utf16)
        var ranges: [NSRange] = []
        var location = 0
        for (index, unit) in units.enumerated() where unit == 0x0A {
            ranges.append(NSRange(location: location, length: index - location))
            location = index + 1
        }
        ranges.append(NSRange(location: location, length: units.count - location))
        rowRanges = ranges

        var texts: [DiffRowText] = []
        texts.reserveCapacity(ranges.count)
        var flatUnits: [UInt16] = []
        flatUnits.reserveCapacity(units.count)
        var starts: [Int] = []
        starts.reserveCapacity(ranges.count + 1)
        var widest: Double = 0
        for (row, range) in ranges.enumerated() {
            let marker = Self.marker(cell: row < cells.count ? cells[row] : nil, range: range, units: units)
            let content = Array(units[(range.location + marker.length)..<NSMaxRange(range)])
            let text = DiffRowText(markerLength: marker.length, markerColumns: marker.columns, units: content,
                                   columns: Self.columns(of: content))
            widest = max(widest, Double(marker.columns) + text.totalColumns)
            starts.append(flatUnits.count)
            flatUnits.append(contentsOf: content)
            texts.append(text)
        }
        starts.append(flatUnits.count)
        rowTexts = texts
        widestRowColumns = widest
        contentUnits = flatUnits
        contentClasses = DiffLineBreaks.defaultClassifier.classify(flatUnits)
        contentStarts = starts
        totalColumns = texts.map(\.totalColumns)
        rowMarkerColumns = texts.map(\.markerColumns)
    }

    var rowCount: Int { rowRanges.count }

    private static func marker(cell: DiffCell?, range: NSRange, units: [UInt16]) -> (length: Int, columns: Int) {
        guard let cell, range.length > 0 else { return (0, 0) }
        switch cell.kind {
        case .line:
            return (1, 1)
        case .comment:
            guard range.length >= 2, units[range.location] == commentSymbol else { return (0, 0) }
            return (2, commentSymbolColumns + 1)
        case .filler, .collapsedRegion, .banner:
            return (0, 0)
        }
    }

    static func columns(of units: [UInt16]) -> [Double] {
        var columns: [Double] = []
        columns.reserveCapacity(units.count + 1)
        var column: Double = 0
        for unit in units {
            columns.append(column)
            column += DiffLineBreaks.computeCharWidth(Int(unit), column, tabSize, columnsForFullWidthChar, true)
        }
        columns.append(column)
        return columns
    }

    func rewrapped(_ previous: DiffPaneWrap, column: Int?) -> DiffPaneWrap {
        precondition(previous.projections.count == rowCount, "the wrap belongs to this text")
        guard let column else { return .unwrapped(rowCount: rowCount) }
        var projections = previous.projections
        var counts = previous.segmentCounts
        contentUnits.withUnsafeBufferPointer { units in
            contentClasses.withUnsafeBufferPointer { classes in
                contentStarts.withUnsafeBufferPointer { starts in
                    totalColumns.withUnsafeBufferPointer { totals in
                        rowMarkerColumns.withUnsafeBufferPointer { markers in
                            projections.withUnsafeMutableBufferPointer { lines in
                                counts.withUnsafeMutableBufferPointer { segmentCounts in
                                    let input = DiffRowRewrapInput(
                                        units: units, classes: classes, starts: starts, totalColumns: totals,
                                        markerColumns: markers, tabSize: Self.tabSize,
                                        columnsForFullWidthChar: Self.columnsForFullWidthChar,
                                        wrappingIndent: Self.wrappingIndent)
                                    DiffRowRewrap.rewrap(DiffRowRewrap.Job(column: column, input: input, lines: lines,
                                                                           counts: segmentCounts))
                                }
                            }
                        }
                    }
                }
            }
        }
        return DiffPaneWrap(column: column, projections: projections, segmentCounts: counts)
    }
}
