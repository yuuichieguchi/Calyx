//
//  SSEEventParser.swift
//  Calyx
//
//  Server-Sent Events framing (WHATWG HTML, "Parsing an event stream"),
//  shared by the legacy HTTP+SSE transport and Streamable HTTP's SSE
//  responses. Incremental: `feed` accepts chunks split at any byte.
//
//  `maxEventBytes` bounds the bytes retained for the event in progress:
//  the unterminated line plus the `data`, `event`, and `id` values stored
//  since the last dispatch. Comment lines and unknown fields release their
//  bytes once complete; a blank line releases everything. Crossing the
//  bound throws `ParseError.eventTooLarge`, after which every `feed`
//  throws the same error.
//

import Foundation

/// One dispatched SSE event.
struct SSEEvent: Sendable, Equatable {
    /// The `event:` field of this event, or nil when the event had none.
    let event: String?
    /// The `data:` lines joined with "\n", or nil when the event had none.
    let data: String?
    /// The last event ID seen on the stream at dispatch time.
    let id: String?
    /// The `retry:` field of this event, in milliseconds.
    let retryMs: Int?
}

struct SSEEventParser: Sendable {

    enum ParseError: Error, Equatable {
        /// The event in progress retained more than `limit` bytes.
        case eventTooLarge(limit: Int)
    }

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Bytes of the line not yet terminated.
    private var lineBuffer: [UInt8] = []
    /// True when the last byte fed was CR, so an LF that follows it
    /// (possibly in the next chunk) completes the same terminator.
    private var lastByteWasCarriageReturn = false
    /// True until the first line is complete; a leading BOM is stripped
    /// from that line only.
    private var isAtStreamStart = true

    private var eventType: String?
    private var dataLines: [String]?
    private var retryMs: Int?
    private var lastEventID: String?

    private let maxEventBytes: Int
    /// UTF-8 bytes of the `data`, `event`, and `id` values stored since
    /// the last dispatch.
    private var retainedFieldBytes = 0
    /// UTF-8 bytes of the `id` value stored since the last dispatch, so a
    /// repeated `id:` line replaces rather than adds to its count.
    private var idBytesSinceDispatch = 0
    /// Set once `eventTooLarge` is thrown; every later `feed` rethrows it.
    private var failure: ParseError?

    init(maxEventBytes: Int) {
        self.maxEventBytes = maxEventBytes
    }

    /// Consumes `chunk` and returns the events it completes, in order.
    /// Throws `ParseError.eventTooLarge` when the event in progress
    /// retains more than `maxEventBytes` bytes.
    mutating func feed(_ chunk: Data) throws -> [SSEEvent] {
        if let failure { throw failure }
        var events: [SSEEvent] = []
        for byte in chunk {
            if lastByteWasCarriageReturn {
                lastByteWasCarriageReturn = false
                if byte == Self.lineFeed { continue }
            }
            switch byte {
            case Self.carriageReturn:
                lastByteWasCarriageReturn = true
                if let event = completeLine() { events.append(event) }
            case Self.lineFeed:
                if let event = completeLine() { events.append(event) }
            default:
                lineBuffer.append(byte)
            }
            if lineBuffer.count + retainedFieldBytes > maxEventBytes {
                let error = ParseError.eventTooLarge(limit: maxEventBytes)
                failure = error
                throw error
            }
        }
        return events
    }

    // MARK: - Private

    /// Processes the buffered line. Returns an event when the line is blank
    /// and something was accumulated since the last dispatch.
    private mutating func completeLine() -> SSEEvent? {
        if isAtStreamStart {
            isAtStreamStart = false
            if lineBuffer.starts(with: Self.byteOrderMark) {
                lineBuffer.removeFirst(Self.byteOrderMark.count)
            }
        }
        let line = String(decoding: lineBuffer, as: UTF8.self)
        lineBuffer.removeAll(keepingCapacity: true)

        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        process(field: field, value: String(value))
        return nil
    }

    private mutating func process(field: Substring, value: String) {
        switch field {
        case "event":
            retainedFieldBytes += value.utf8.count - (eventType?.utf8.count ?? 0)
            eventType = value
        case "data":
            retainedFieldBytes += value.utf8.count
            dataLines = (dataLines ?? []) + [value]
        case "id":
            // An id containing NULL is ignored. An empty id clears the
            // last event ID.
            guard !value.contains("\u{0}") else { return }
            retainedFieldBytes += value.utf8.count - idBytesSinceDispatch
            idBytesSinceDispatch = value.utf8.count
            lastEventID = value.isEmpty ? nil : value
        case "retry":
            guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }), let milliseconds = Int(value) else {
                return
            }
            retryMs = milliseconds
        default:
            return
        }
    }

    /// Dispatches the accumulated event, if any, and resets the per-event
    /// fields and the retained byte count. The last event ID is kept.
    private mutating func dispatch() -> SSEEvent? {
        defer {
            eventType = nil
            dataLines = nil
            retryMs = nil
            retainedFieldBytes = 0
            idBytesSinceDispatch = 0
        }
        guard eventType != nil || dataLines != nil || retryMs != nil else { return nil }
        return SSEEvent(
            event: eventType,
            data: dataLines?.joined(separator: "\n"),
            id: lastEventID,
            retryMs: retryMs
        )
    }
}
