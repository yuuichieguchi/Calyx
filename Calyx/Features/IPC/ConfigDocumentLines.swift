// ConfigDocumentLines.swift
// Calyx
//
// Byte-level line scanner shared by MarkerConfigDocumentEditor and
// TOMLTableConfigDocumentEditor. Operates entirely on bytes, never on
// Swift `String`/`Character`, since a CRLF pair collapses into a single
// `Character` and would make EOL-sensitive checks silently wrong against
// CRLF content.

import Foundation

struct LineRecord {
    /// This line's own bytes, excluding its terminator.
    let contentRange: Range<Int>
    /// This line's terminating EOL bytes (`\n` or `\r\n`); empty when the
    /// document ends without a trailing newline.
    let eolRange: Range<Int>
}

struct LineDoc {
    let bytes: [UInt8]
    let lines: [LineRecord]

    init(bytes: [UInt8]) {
        self.bytes = bytes
        var records: [LineRecord] = []
        var lineStart = 0
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\n") {
                let eolStart = (i > lineStart && bytes[i - 1] == UInt8(ascii: "\r")) ? i - 1 : i
                records.append(LineRecord(contentRange: lineStart..<eolStart, eolRange: eolStart..<(i + 1)))
                lineStart = i + 1
            }
            i += 1
        }
        records.append(LineRecord(contentRange: lineStart..<bytes.count, eolRange: bytes.count..<bytes.count))
        self.lines = records
    }

    func lineBytes(_ record: LineRecord) -> [UInt8] {
        Array(bytes[record.contentRange])
    }

    func detectEOL() -> [UInt8] {
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "\n") {
                if i > 0, bytes[i - 1] == UInt8(ascii: "\r") {
                    return [UInt8(ascii: "\r"), UInt8(ascii: "\n")]
                }
                return [UInt8(ascii: "\n")]
            }
            i += 1
        }
        return [UInt8(ascii: "\n")]
    }

    /// `startLine` through `endLine`'s own line terminator, excluding any
    /// separator line before `startLine`. Used to replace an existing
    /// region in place without disturbing whatever precedes it.
    func blockRange(startLine: Int, endLine: Int) -> Range<Int> {
        let start = lines[startLine].contentRange.lowerBound
        let end = lines[endLine].eolRange.upperBound
        return start..<end
    }

    /// `blockRange`, extended to also consume exactly one immediately
    /// preceding empty line, if there is one. Used to fully remove a
    /// region together with the blank-line separator that precedes it.
    func removalRange(startLine: Int, endLine: Int) -> Range<Int> {
        var start = lines[startLine].contentRange.lowerBound
        if startLine > 0, lines[startLine - 1].contentRange.isEmpty {
            start = lines[startLine - 1].contentRange.lowerBound
        }
        let end = lines[endLine].eolRange.upperBound
        return start..<end
    }

    /// Concatenates `range`'s lines' own content bytes plus their own
    /// original EOL bytes, in document order. Used to copy a span of
    /// lines byte-for-byte (indentation, trailing whitespace, comments,
    /// blank lines, and line ending all included) when writing preserved
    /// foreign content back into a document.
    func rawBytes(forLines range: Range<Int>) -> [UInt8] {
        var result: [UInt8] = []
        for i in range {
            result.append(contentsOf: bytes[lines[i].contentRange])
            result.append(contentsOf: bytes[lines[i].eolRange])
        }
        return result
    }

    /// The number of leading ASCII space bytes in `record`'s own content
    /// (not tab-aware -- a caller that must reject tab indentation checks
    /// for a leading tab byte itself before calling this).
    func leadingSpaceCount(_ record: LineRecord) -> Int {
        var n = 0
        for byte in bytes[record.contentRange] {
            if byte == UInt8(ascii: " ") { n += 1 } else { break }
        }
        return n
    }
}
