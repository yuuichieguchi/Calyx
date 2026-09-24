//
//  NDJSONFramer.swift
//  Calyx
//
//  Incremental newline-delimited framer for the MCP stdio transport.
//  Messages are delimited by `\n` and contain no embedded newlines. This
//  layer splits bytes only; JSON parsing belongs to
//  `JSONRPCMessage.parse`.
//

import Foundation

enum NDJSONFramerError: Error, Equatable {
    case lineTooLarge(limit: Int)
}

struct NDJSONFramer: Sendable {
    /// Same as the HTTP body cap.
    static let maxLineBytes = 64 * 1024 * 1024

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let space: UInt8 = 0x20
    private static let tab: UInt8 = 0x09

    private let maxLineBytes: Int
    /// Bytes of the current unterminated line.
    private var buffer = Data()
    /// Once set, every `feed` and `checkPending` throws it.
    private var failure: NDJSONFramerError?

    init(maxLineBytes: Int = NDJSONFramer.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends `chunk` and returns every line it completed, in order.
    /// A single trailing `\r` is stripped from each line; empty and
    /// whitespace-only lines are dropped. The unterminated tail stays
    /// buffered.
    ///
    /// When the buffered tail exceeds `maxLineBytes`, the framer records
    /// `lineTooLarge` and discards the tail. This call throws it only if
    /// `chunk` completed no line; otherwise it returns those lines and
    /// `checkPending` throws it. Every later `feed` throws it.
    mutating func feed(_ chunk: Data) throws -> [Data] {
        if let failure {
            throw failure
        }

        var lines: [Data] = []
        var lineStart = chunk.startIndex
        while let newline = chunk[lineStart...].firstIndex(of: Self.lineFeed) {
            let segment = chunk[lineStart..<newline]
            if buffer.isEmpty {
                appendLine(Data(segment), to: &lines)
            } else {
                buffer.append(segment)
                appendLine(buffer, to: &lines)
                buffer = Data()
            }
            lineStart = chunk.index(after: newline)
        }
        buffer.append(chunk[lineStart...])

        if buffer.count > maxLineBytes {
            let error = NDJSONFramerError.lineTooLarge(limit: maxLineBytes)
            failure = error
            buffer = Data()
            if lines.isEmpty {
                throw error
            }
        }
        return lines
    }

    /// Throws the error `feed` recorded, if any. Call it after handling
    /// the lines `feed` returned.
    func checkPending() throws {
        if let failure {
            throw failure
        }
    }

    /// Returns `payload` followed by one `\n`.
    func encode(_ payload: Data) -> Data {
        var framed = payload
        framed.append(Self.lineFeed)
        return framed
    }

    // MARK: - Private

    private func appendLine(_ raw: Data, to lines: inout [Data]) {
        var line = raw
        if line.last == Self.carriageReturn {
            line.removeLast()
        }
        let isBlank = line.allSatisfy { byte in
            byte == Self.space || byte == Self.tab || byte == Self.carriageReturn
        }
        if !isBlank {
            lines.append(line)
        }
    }
}
