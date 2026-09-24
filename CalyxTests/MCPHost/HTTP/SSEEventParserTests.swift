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
//    - `struct SSEEventParser { mutating func feed(_ chunk: Data) -> [SSEEvent] }`
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
//

import XCTest
@testable import Calyx

final class SSEEventParserTests: XCTestCase {

    // MARK: - Basic single-line data

    func test_feed_singleDataLine_dispatchesOnBlankLine() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("data: hello\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello")
        XCTAssertNil(events[0].event)
        XCTAssertNil(events[0].id)
    }

    // MARK: - Multi-line data concatenation

    func test_feed_multipleDataLines_joinsWithNewline() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("data: line1\ndata: line2\ndata: line3\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "line1\nline2\nline3")
    }

    // MARK: - event / id / retry fields

    func test_feed_eventAndIdAndData_allCaptured() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("event: message\nid: 42\ndata: payload\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].id, "42")
        XCTAssertEqual(events[0].data, "payload")
    }

    func test_feed_retryField_parsedAsMilliseconds() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("retry: 3000\ndata: x\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].retryMs, 3000)
    }

    func test_feed_retryField_nonNumeric_isIgnored() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("retry: not-a-number\ndata: x\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events[0].retryMs)
    }

    // MARK: - Comment lines

    func test_feed_commentLine_contributesNothing() {
        var parser = SSEEventParser()
        let events = parser.feed(Data(": this is a comment\ndata: real\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "real")
    }

    func test_feed_commentOnlyBlock_dispatchesNoEvent() {
        var parser = SSEEventParser()
        let events = parser.feed(Data(": keep-alive\n\n".utf8))
        XCTAssertEqual(events.count, 0)
    }

    // MARK: - CRLF and LF

    func test_feed_crlfLineEndings_parsedIdenticallyToLF() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("event: message\r\ndata: hello\r\n\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].data, "hello")
    }

    func test_feed_mixedCRLFAndLF_withinSameStream_bothParsed() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("data: first\r\n\r\ndata: second\n\n".utf8))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].data, "first")
        XCTAssertEqual(events[1].data, "second")
    }

    // MARK: - Partial chunks across feeds

    func test_feed_chunkSplitMidLine_bufferedUntilLineComplete() {
        var parser = SSEEventParser()
        let first = parser.feed(Data("data: hel".utf8))
        XCTAssertEqual(first.count, 0)
        let second = parser.feed(Data("lo\n\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].data, "hello")
    }

    func test_feed_chunkSplitMidFieldName_bufferedUntilFieldComplete() {
        var parser = SSEEventParser()
        let first = parser.feed(Data("da".utf8))
        XCTAssertEqual(first.count, 0)
        let second = parser.feed(Data("ta: value\n\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].data, "value")
    }

    func test_feed_chunkSplitAcrossBlankLineDelimiter_dispatchesOnceDelimiterCompletes() {
        var parser = SSEEventParser()
        let first = parser.feed(Data("data: value\n".utf8))
        XCTAssertEqual(first.count, 0, "a single trailing newline is not yet the blank-line dispatch delimiter")
        let second = parser.feed(Data("\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].data, "value")
    }

    func test_feed_multipleEventsInOneChunk_allDispatched() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("data: one\n\ndata: two\n\ndata: three\n\n".utf8))
        XCTAssertEqual(events.map(\.data), ["one", "two", "three"])
    }

    // MARK: - Empty data events

    func test_feed_dataFieldWithNoValue_dispatchesEventWithEmptyStringData() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("data:\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "")
    }

    func test_feed_eventFieldWithNoData_dispatchesEventWithNilData() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("event: ping\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "ping")
        XCTAssertNil(events[0].data)
    }

    // MARK: - Field value leading-space stripping (SSE spec: strip exactly one leading space)

    func test_feed_fieldValue_stripsExactlyOneLeadingSpace() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("data:  two leading spaces\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, " two leading spaces", "only the first leading space after ':' is stripped")
    }

    func test_feed_fieldWithNoColon_treatedAsFieldNameWithEmptyValue() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("data\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "")
    }

    // MARK: - Bare CR line endings (WHATWG accepts CR, LF, or CRLF)

    func test_feed_bareCRLineEndings_parsedIdenticallyToLF() {
        var parser = SSEEventParser()
        let events = parser.feed(Data("event: message\rdata: hello\r\r".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].event, "message")
        XCTAssertEqual(events[0].data, "hello")
    }

    func test_feed_bareCR_doesNotDoubleDispatch_whenFollowedByLF() {
        // A lone CR immediately followed by LF is one line terminator
        // (CRLF), not two separate blank lines.
        var parser = SSEEventParser()
        let events = parser.feed(Data("data: one\r\ndata: two\r\n\r\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "one\ntwo")
    }

    // MARK: - Leading BOM is stripped once, at stream start only

    func test_feed_leadingBOM_isStrippedFromFirstField() {
        var parser = SSEEventParser()
        let bom = Data([0xEF, 0xBB, 0xBF])
        let events = parser.feed(bom + Data("data: hello\n\n".utf8))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].data, "hello", "the BOM must not become part of the field name or value")
    }

    // MARK: - id persists across dispatches until a new id: line updates it

    func test_feed_id_persistsToNextDispatch_whenNotRepeated() {
        var parser = SSEEventParser()
        let first = parser.feed(Data("id: 1\ndata: a\n\n".utf8))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].id, "1")

        let second = parser.feed(Data("data: b\n\n".utf8))
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, "1", "the last-seen id carries forward to an event that has no id: line of its own")
        XCTAssertEqual(second[0].data, "b")
    }
}
