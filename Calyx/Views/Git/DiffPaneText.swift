import AppKit

struct DiffRowText: Equatable, Sendable {
    let markerLength: Int
    let markerColumns: Int
    let units: [UInt16]
    let columns: [Double]

    var totalColumns: Double { columns[columns.count - 1] }
}

struct DiffPaneRow: Sendable {
    let length: Int
    let markerLength: Int
    let markerColumns: Int
    let content: [UInt16]
    let columns: [Double]
    let classes: [UInt8]

    static let empty = DiffPaneRow(rowUnits: [], markerLength: 0, markerColumns: 0)

    init(rowUnits: [UInt16], markerLength: Int, markerColumns: Int) {
        self.init(rowUnits: rowUnits[...], markerLength: markerLength, markerColumns: markerColumns)
    }

    init(rowUnits: ArraySlice<UInt16>, markerLength: Int, markerColumns: Int) {
        length = rowUnits.count
        self.markerLength = markerLength
        self.markerColumns = markerColumns
        content = Array(rowUnits[(rowUnits.startIndex + markerLength)...])
        columns = DiffPaneText.columns(of: content)
        classes = DiffLineBreaks.defaultClassifier.classify(content)
    }
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
        let units = Array(attributed.string.utf16)
        var rows: [DiffPaneRow] = []
        var location = 0
        func appendRow(endingAt end: Int) {
            let range = NSRange(location: location, length: end - location)
            let marker = Self.marker(cell: rows.count < cells.count ? cells[rows.count] : nil, range: range, units: units)
            rows.append(DiffPaneRow(rowUnits: units[range.location..<end], markerLength: marker.length,
                                    markerColumns: marker.columns))
            location = end + 1
        }
        for (index, unit) in units.enumerated() where unit == 0x0A {
            appendRow(endingAt: index)
        }
        appendRow(endingAt: units.count)
        self.init(attributed: attributed, rows: rows)
    }

    init(attributed: NSAttributedString, rows: [DiffPaneRow]) {
        precondition(!rows.isEmpty, "a pane text has at least one row")
        self.attributed = attributed
        string = attributed.string
        nsString = attributed.string as NSString
        var ranges: [NSRange] = []
        ranges.reserveCapacity(rows.count)
        var texts: [DiffRowText] = []
        texts.reserveCapacity(rows.count)
        var flatUnits: [UInt16] = []
        var flatClasses: [UInt8] = []
        var starts: [Int] = []
        starts.reserveCapacity(rows.count + 1)
        var widest: Double = 0
        var location = 0
        for row in rows {
            ranges.append(NSRange(location: location, length: row.length))
            location += row.length + 1
            let text = DiffRowText(markerLength: row.markerLength, markerColumns: row.markerColumns,
                                   units: row.content, columns: row.columns)
            widest = max(widest, Double(row.markerColumns) + text.totalColumns)
            starts.append(flatUnits.count)
            flatUnits.append(contentsOf: row.content)
            flatClasses.append(contentsOf: row.classes)
            texts.append(text)
        }
        starts.append(flatUnits.count)
        precondition(location - 1 == nsString.length, "the rows cover the attributed string")
        rowRanges = ranges
        rowTexts = texts
        widestRowColumns = widest
        contentUnits = flatUnits
        contentClasses = flatClasses
        contentStarts = starts
        totalColumns = texts.map(\.totalColumns)
        rowMarkerColumns = texts.map(\.markerColumns)
    }

    var rowCount: Int { rowRanges.count }

    static func marker(cell: DiffCell?, range: NSRange, units: [UInt16]) -> (length: Int, columns: Int) {
        guard let cell, range.length > 0 else { return (0, 0) }
        switch cell.kind {
        case .comment:
            guard range.length >= 2, units[range.location] == commentSymbol else { return (0, 0) }
            return (2, commentSymbolColumns + 1)
        case .line, .filler, .collapsedRegion, .banner:
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
