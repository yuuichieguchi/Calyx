import Foundation

struct DiffRowRewrapInput {
    let units: UnsafeBufferPointer<UInt16>
    let classes: UnsafeBufferPointer<UInt8>
    let starts: UnsafeBufferPointer<Int>
    let totalColumns: UnsafeBufferPointer<Double>
    let markerColumns: UnsafeBufferPointer<Int>
    let tabSize: Int
    let columnsForFullWidthChar: Double
    let wrappingIndent: DiffWrappingIndent
}

enum DiffRowRewrap {
    private static let rowsPerChunk = 64

    struct Job: @unchecked Sendable {
        let column: Int
        let input: DiffRowRewrapInput
        let lines: UnsafeMutableBufferPointer<DiffLineProjection?>
        let counts: UnsafeMutableBufferPointer<Int>
    }

    static func rewrap(_ job: Job) {
        let rowCount = job.input.totalColumns.count
        precondition(job.lines.count == rowCount && job.counts.count == rowCount, "one projection per row")
        let chunkCount = (rowCount + rowsPerChunk - 1) / rowsPerChunk
        DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
            let lower = chunk * rowsPerChunk
            rewrapRows(lower..<min(lower + rowsPerChunk, rowCount), column: job.column,
                       input: job.input, lines: job.lines, counts: job.counts)
        }
    }

    private static func rewrapRows(_ rows: Range<Int>, column: Int, input: DiffRowRewrapInput,
                                   lines: UnsafeMutableBufferPointer<DiffLineProjection?>,
                                   counts: UnsafeMutableBufferPointer<Int>) {
        guard let unitBase = input.units.baseAddress, let classBase = input.classes.baseAddress else { return }
        var pooledOffsets: [Int] = []
        var pooledVisibleColumns: [Double] = []
        var row = rows.lowerBound
        while row < rows.upperBound {
            defer { row += 1 }
            let rowColumn = max(column + 1 - input.markerColumns[row], 1)
            if input.totalColumns[row] <= Double(rowColumn) {
                if lines[row] != nil {
                    lines[row] = nil
                    counts[row] = 1
                }
                continue
            }
            let start = input.starts[row]
            let count = input.starts[row + 1] - start
            counts[row] = breakLine(UnsafeBufferPointer(start: unitBase + start, count: count),
                                    UnsafeBufferPointer(start: classBase + start, count: count),
                                    column: rowColumn, input: input, projection: &lines[row],
                                    pooledOffsets: &pooledOffsets, pooledVisibleColumns: &pooledVisibleColumns)
        }
    }

    private static func breakLine(_ text: UnsafeBufferPointer<UInt16>, _ classes: UnsafeBufferPointer<UInt8>,
                                  column: Int, input: DiffRowRewrapInput, projection: inout DiffLineProjection?,
                                  pooledOffsets: inout [Int], pooledVisibleColumns: inout [Double]) -> Int {
        guard var previous = projection else {
            projection = DiffLineBreaks.createLineBreaks(
                text, classes, tabSize: input.tabSize, firstLineBreakColumn: column,
                columnsForFullWidthChar: input.columnsForFullWidthChar, wrappingIndent: input.wrappingIndent,
                wordBreak: .normal, useTwoCellFullwidthCharacters: true)
            return projection?.segmentCount ?? 1
        }
        projection = nil
        let indent = DiffLineBreaks.createLineBreaksFromPreviousLineBreaks(
            previous, text, classes, tabSize: input.tabSize, firstLineBreakColumn: column,
            columnsForFullWidthChar: input.columnsForFullWidthChar, wrappingIndent: input.wrappingIndent,
            wordBreak: .normal, useTwoCellFullwidthCharacters: true,
            breakingOffsets: &pooledOffsets, breakingOffsetsVisibleColumn: &pooledVisibleColumns)
        guard let indent else { return 1 }
        let segmentCount = pooledOffsets.count
        projection = DiffLineProjection(breakOffsets: pooledOffsets,
                                        breakOffsetsVisibleColumn: pooledVisibleColumns,
                                        wrappedTextIndentLength: indent)
        swap(&pooledOffsets, &previous.breakOffsets)
        swap(&pooledVisibleColumns, &previous.breakOffsetsVisibleColumn)
        return segmentCount
    }
}
