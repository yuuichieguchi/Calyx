//
//  SSEEventParserTests.swift
//  CalyxTests
//
//  Pure Server-Sent Events framing per the WHATWG SSE spec, as used by
//  both the legacy HTTP+SSE transport and the request-scoped SSE
//  responses of Streamable HTTP.
//
//  Contract asserted here:
//    - `SSEEvent { event: String?, data: String?, id: String?, retryMs: Int? }`
//    - `struct SSEEventParser { init(maxEventBytes: Int); mutating func feed(_ chunk: Data) throws -> [SSEEvent] }`
//    - `enum ParseError: Error, Equatable { case eventTooLarge(limit: Int) }`
//    - Multiple `data:` lines in one event are joined with "\n".
//    - A line starting with `:` is a comment and contributes nothing.
//    - A blank line dispatches the event assembled since the last dispatch;
//      `id` persists across dispatches (per spec, the parser's last-seen
//      id is remembered) until a new `id:` line updates it, but is only
//      attached to an event when the event actually carries a `data`
//      field or `event`/`retry` field (i.e. something was accumulated).
//    - Feeds may split anywhere, including mid-line and mid-chunk;
//      partial lines are buffered across `feed` calls.
//    - Both CRLF and bare LF line endings are accepted.
//    - `maxEventBytes` bounds the bytes retained for the in-progress event:
//      the unterminated `lineBuffer` plus buffered `data`/`event`/`id`
//      value bytes. Completed comment lines and unknown fields release
//      their bytes. Accounting resets on dispatch (blank line). Once
//      `feed` throws `eventTooLarge`, every subsequent `feed` throws the
//      same error.
//

import XCTest
@testable import Calyx

final class SSEEventParserTests: XCTestCase {

    // MARK: - Basic single-line data

    func test_feed_singleDataLine_dispatchesOnBlankLine() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data: hello\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello")
        XCTAssertNil(events[0].event)
        XCTAssertNil(events[0].id)
    }

    // MARK: - Multi-line data concatenation

    func test_feed_multipleDataLines_joinsWithNewline() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data: line1\ndata: line2\ndata: line3\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2\nline3")
    }

    // MARK: - event / id / retry fields

    func test_feed_eventAndIdAndData_allCaptured() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("event: message\nid: 42\ndata: payload\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].id, "42")
        XCTAssertEqual(events[0].data, "payload")
    }

    func test_feed_retryField_parsedAsMilliseconds() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("retry: 3000\ndata: x\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].retryMs, 3000)
    }

    func test_feed_retryField_nonNumeric_isIgnored() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("retry: not-a-number\ndata: x\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].retryMs)
    }

    // MARK: - Comment lines

    func test_feed_commentLine_contributesNothing() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data(": this is a comment\ndata: real\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "real")
    }

    func test_feed_commentOnlyBlock_dispatchesNoEvent() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data(": keep-alive\n\n".utf8))
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - CRLF and LF

    func test_feed_crlfLineEndings_parsedIdenticallyToLF() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("event: message\r\ndata: hello\r\n\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].data, "hello")
    }

    func test_feed_mixedCRLFAndLF_withinSameStream_bothParsed() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data: first\r\n\r\ndata: second\n\n".utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, "first")
        XCTAssertEqual(events[1].data, "second")
    }

    // MARK: - Partial chunks across feeds

    func test_feed_chunkSplitMidLine_bufferedUntilLineComplete() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let first = try parser.feed(Data("data: hel".utf8))
        XCTAssertEqual(first.count, 0)
        let second = try parser.feed(Data("lo\n\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].data, "hello")
    }

    func test_feed_chunkSplitMidFieldName_bufferedUntilFieldComplete() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let first = try parser.feed(Data("da".utf8))
        XCTAssertEqual(first.count, 0)
        let second = try parser.feed(Data("ta: value\n\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].data, "value")
    }

    func test_feed_chunkSplitAcrossBlankLineDelimiter_dispatchesOnceDelimiterCompletes() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let first = try parser.feed(Data("data: value\n".utf8))
        XCTAssertEqual(first.count, 0, "a single trailing newline is not yet the blank-line dispatch delimiter")
        let second = try parser.feed(Data("\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].data, "value")
    }

    func test_feed_multipleEventsInOneChunk_allDispatched() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data: one\n\ndata: two\n\ndata: three\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["one", "two", "three"])
    }

    // MARK: - Empty data events

    func test_feed_dataFieldWithNoValue_dispatchesEventWithEmptyStringData() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data:\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "")
    }

    func test_feed_eventFieldWithNoData_dispatchesEventWithNilData() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("event: ping\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "ping")
        XCTAssertNil(events[0].data)
    }

    // MARK: - Field value leading-space stripping (SSE spec: strip exactly one leading space)

    func test_feed_fieldValue_stripsExactlyOneLeadingSpace() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data:  two leading spaces\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, " two leading spaces", "only the first leading space after ':' is stripped")
    }

    func test_feed_fieldWithNoColon_treatedAsFieldNameWithEmptyValue() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "")
    }

    // MARK: - Bare CR line endings (WHATWG accepts CR, LF, or CRLF)

    func test_feed_bareCRLineEndings_parsedIdenticallyToLF() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("event: message\rdata: hello\r\r".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].data, "hello")
    }

    func test_feed_bareCR_doesNotDoubleDispatch_whenFollowedByLF() throws {
        // A lone CR immediately followed by LF is one line terminator
        // (CRLF), not two separate blank lines.
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let events = try parser.feed(Data("data: one\r\ndata: two\r\n\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "one\ntwo")
    }

    // MARK: - Leading BOM is stripped once, at stream start only

    func test_feed_leadingBOM_isStrippedFromFirstField() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let bom = Data([0xEF, 0xBB, 0xBF])
        let events = try parser.feed(bom + Data("data: hello\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello", "the BOM must not become part of the field name or value")
    }

    // MARK: - id persists across dispatches until a new id: line updates it

    func test_feed_id_persistsToNextDispatch_whenNotRepeated() throws {
        var parser = SSEEventParser(maxEventBytes: 1 << 20)
        let first = try parser.feed(Data("id: 1\ndata: a\n\n".utf8))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].id, "1")

        let second = try parser.feed(Data("data: b\n\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, "1", "the last-seen id carries forward to an event that has no id: line of its own")
        XCTAssertEqual(second[0].data, "b")
    }

    // MARK: - maxEventBytes bounds the in-progress event

    func test_feed_unterminatedLineExceedingLimit_throwsEventTooLarge() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        let overLong = Data(repeating: 0x78, count: 65) // 65 non-newline bytes, no terminator yet
        XCTAssertThrowsError(try parser.feed(overLong)) { error in
            XCTAssertEqual(error as? SSEEventParser.ParseError, .eventTooLarge(limit: 64))
        }
    }

    func test_feed_bufferedDataLinesExceedingLimit_throwsEventTooLarge() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        // 7 completed "data:" lines, each with a 10-byte value (70 bytes
        // total), never terminated by a blank line, so nothing is
        // dispatched (and nothing released) before the limit is crossed.
        let line = "data: aaaaaaaaaa\n"
        let chunk = Data(String(repeating: line, count: 7).utf8)
        XCTAssertThrowsError(try parser.feed(chunk)) { error in
            XCTAssertEqual(error as? SSEEventParser.ParseError, .eventTooLarge(limit: 64))
        }
    }

    func test_feed_manySmallEvents_totalExceedingLimit_succeeds() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        // 10 events of a 10-byte data value each (100 bytes total across
        // the whole feed), but each is dispatched by its own blank line,
        // so the retained total for any single in-progress event never
        // exceeds 10 bytes.
        let event = "data: xxxxxxxxxx\n\n"
        let chunk = Data(String(repeating: event, count: 10).utf8)
        let events = try parser.feed(chunk)
        XCTAssertEqual(events.count, 10)
        XCTAssertEqual(events.map(\.data), Array(repeating: "xxxxxxxxxx", count: 10))
    }

    func test_feed_commentLinesWithoutBlankLine_doNotAccumulate() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        // 20 comment lines of 12 bytes each (240 bytes total), no blank
        // line; comment lines contribute nothing to the retained total.
        let line = ": keepalive\n"
        let chunk = Data(String(repeating: line, count: 20).utf8)
        let events = try parser.feed(chunk)
        XCTAssertEqual(events, [], "comment-only input never dispatches an event")
    }

    func test_feed_unknownFieldLines_doNotAccumulate() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        // 20 unknown-field lines of 9 bytes each (180 bytes total), no
        // blank line; unrecognized fields contribute nothing retained.
        let line = "foo: bar\n"
        let chunk = Data(String(repeating: line, count: 20).utf8)
        let events = try parser.feed(chunk)
        XCTAssertEqual(events, [], "unknown fields never dispatch an event and must not accumulate toward the limit")
    }

    func test_feed_afterEventTooLarge_keepsThrowing() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        let overLong = Data(repeating: 0x78, count: 65)
        XCTAssertThrowsError(try parser.feed(overLong)) { error in
            XCTAssertEqual(error as? SSEEventParser.ParseError, .eventTooLarge(limit: 64))
        }
        XCTAssertThrowsError(try parser.feed(Data("\n\n".utf8))) { error in
            XCTAssertEqual(error as? SSEEventParser.ParseError, .eventTooLarge(limit: 64),
                "once thrown, every subsequent feed must throw the same error")
        }
    }

    func test_feed_dataLineAtExactlyLimit_succeeds() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        // "data: " (6 bytes) + 58 'x' bytes makes the unterminated
        // lineBuffer peak at exactly 64 bytes just before the "\n"
        // completes the line; the value retained afterward (58 bytes) is
        // released from lineBuffer into the data line's own byte count.
        let value = String(repeating: "x", count: 58)
        let events = try parser.feed(Data("data: \(value)\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, value, "retained bytes exactly at the limit must not throw")
    }

    func test_feed_unterminatedLineAtExactlyLimit_doesNotThrow() throws {
        var parser = SSEEventParser(maxEventBytes: 64)
        let exactly64 = Data(repeating: 0x78, count: 64)
        XCTAssertNoThrow(try parser.feed(exactly64), "an unterminated line exactly at the limit must not throw")
    }
}
