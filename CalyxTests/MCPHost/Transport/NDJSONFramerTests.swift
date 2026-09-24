//
//  NDJSONFramerTests.swift
//  CalyxTests
//
//  Pure, incremental newline-delimited JSON framer used by
//  StdioMCPTransport. This layer only splits bytes on line feeds; it does
//  not parse or validate JSON (that happens one layer up, at
//  JSONRPCMessage.parse). Per the API contract's Transport section 2.1:
//  the delimiter is \n, a single trailing \r is stripped (CRLF
//  tolerance), empty and whitespace-only lines are dropped, and an
//  unterminated buffered line exceeding maxLineBytes throws
//  NDJSONFramerError.lineTooLarge(limit:) and keeps throwing on every
//  subsequent feed (non-recovering). When the same chunk also completed
//  lines, feed returns them and checkPending() throws the error instead.
//

import XCTest
@testable import Calyx

final class NDJSONFramerTests: XCTestCase {

    // MARK: - Splitting on 0x0A

    func test_feed_singleCompleteLine_emitsOneMessage() throws {
        var framer = NDJSONFramer()
        let lines = try framer.feed(Data(#"{"a":1}"#.utf8) + Data([0x0A]))
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, [#"{"a":1}"#])
    }

    func test_feed_multipleLinesInOneChunk_emitsEachAsSeparateMessage() throws {
        var framer = NDJSONFramer()
        let chunk = Data(#"{"a":1}"#.utf8) + Data([0x0A]) + Data(#"{"b":2}"#.utf8) + Data([0x0A])
        let lines = try framer.feed(chunk)
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, [#"{"a":1}"#, #"{"b":2}"#])
    }

    func test_feed_partialLine_emitsNothingUntilNewlineArrives() throws {
        var framer = NDJSONFramer()
        let first = try framer.feed(Data(#"{"a":"#.utf8))
        XCTAssertTrue(first.isEmpty)
        let second = try framer.feed(Data("1}".utf8) + Data([0x0A]))
        XCTAssertEqual(second.map { String(data: $0, encoding: .utf8) }, [#"{"a":1}"#])
    }

    func test_feed_partialLineSplitAcrossThreeChunks_reassemblesOnFinalNewline() throws {
        var framer = NDJSONFramer()
        let first = try framer.feed(Data(#"{"a""#.utf8))
        let second = try framer.feed(Data(":1".utf8))
        XCTAssertTrue(first.isEmpty)
        XCTAssertTrue(second.isEmpty)
        let third = try framer.feed(Data("}".utf8) + Data([0x0A]))
        XCTAssertEqual(third.map { String(data: $0, encoding: .utf8) }, [#"{"a":1}"#])
    }

    // MARK: - CRLF: exactly one trailing \r stripped

    func test_feed_crlfLineEnding_stripsExactlyOneTrailingCR() throws {
        var framer = NDJSONFramer()
        let lines = try framer.feed(Data(#"{"a":1}"#.utf8) + Data([0x0D, 0x0A]))
        XCTAssertEqual(lines, [Data(#"{"a":1}"#.utf8)])
    }

    func test_feed_lfOnly_doesNotStripAnyCharacter() throws {
        var framer = NDJSONFramer()
        let lines = try framer.feed(Data(#"{"a":1}"#.utf8) + Data([0x0A]))
        XCTAssertEqual(lines, [Data(#"{"a":1}"#.utf8)])
    }

    // MARK: - Empty and whitespace-only lines are dropped

    func test_feed_emptyLine_isDropped() throws {
        var framer = NDJSONFramer()
        let chunk = Data([0x0A]) + Data(#"{"a":1}"#.utf8) + Data([0x0A]) + Data([0x0A])
        let lines = try framer.feed(chunk)
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, [#"{"a":1}"#])
    }

    func test_feed_whitespaceOnlyLine_isDropped() throws {
        var framer = NDJSONFramer()
        let chunk = Data("   ".utf8) + Data([0x0A]) + Data("\t".utf8) + Data([0x0A]) + Data(#"{"a":1}"#.utf8) + Data([0x0A])
        let lines = try framer.feed(chunk)
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, [#"{"a":1}"#])
    }

    // MARK: - UTF-8 multibyte character split across chunks

    func test_feed_utf8MultibyteCharacterSplitAcrossChunks_reassemblesCorrectly() throws {
        var framer = NDJSONFramer()
        // "🎉" (U+1F389) is 4 UTF-8 bytes: F0 9F 8E 89. Split the JSON
        // payload so the split point lands inside that multibyte sequence.
        let payload = #"{"emoji":"🎉"}"#
        let payloadBytes = Array(Data(payload.utf8))
        let splitIndex = payloadBytes.firstIndex(of: 0xF0)! + 2 // inside the 4-byte sequence
        let firstChunk = Data(payloadBytes[0..<splitIndex])
        let secondChunk = Data(payloadBytes[splitIndex...]) + Data([0x0A])

        let firstResult = try framer.feed(firstChunk)
        XCTAssertTrue(firstResult.isEmpty)
        let secondResult = try framer.feed(secondChunk)
        XCTAssertEqual(secondResult.count, 1)
        XCTAssertEqual(String(data: secondResult[0], encoding: .utf8), payload)
    }

    // MARK: - No JSON validation at this layer

    func test_feed_nonJSONLine_isEmittedVerbatimAndFramerKeepsWorkingAfterward() throws {
        var framer = NDJSONFramer()
        let firstLines = try framer.feed(Data("not json at all".utf8) + Data([0x0A]))
        XCTAssertEqual(firstLines.map { String(data: $0, encoding: .utf8) }, ["not json at all"])
        let secondLines = try framer.feed(Data(#"{"ok":true}"#.utf8) + Data([0x0A]))
        XCTAssertEqual(secondLines.map { String(data: $0, encoding: .utf8) }, [#"{"ok":true}"#])
    }

    // MARK: - maxLineBytes cap: non-recovering

    func test_feed_unterminatedLineExceedingMaxLineBytes_throwsLineTooLarge() {
        var framer = NDJSONFramer(maxLineBytes: 16)
        let oversized = Data(repeating: 0x61, count: 17) // no trailing \n yet
        XCTAssertThrowsError(try framer.feed(oversized)) { error in
            XCTAssertEqual(error as? NDJSONFramerError, .lineTooLarge(limit: 16))
        }
    }

    func test_feed_lineAtExactlyMaxLineBytes_doesNotThrow() throws {
        var framer = NDJSONFramer(maxLineBytes: 16)
        let exact = Data(repeating: 0x61, count: 16) + Data([0x0A])
        XCTAssertNoThrow(try framer.feed(exact))
    }

    func test_feed_afterLineTooLarge_keepsThrowingOnSubsequentFeeds() {
        // Non-recovering: once the buffered line has overflowed, every
        // later feed(_:) call throws the same error, even on a chunk that
        // would otherwise be a small, well-formed line.
        var framer = NDJSONFramer(maxLineBytes: 16)
        XCTAssertThrowsError(try framer.feed(Data(repeating: 0x61, count: 17)))
        XCTAssertThrowsError(try framer.feed(Data(#"{"a":1}"#.utf8) + Data([0x0A]))) { error in
            XCTAssertEqual(error as? NDJSONFramerError, .lineTooLarge(limit: 16))
        }
    }

    func test_feed_maxLineBytesAccumulatesAcrossChunks_beforeThrowing() {
        // The buffered (unterminated) line grows across feed calls; the
        // cap applies to the accumulated buffer, not each individual
        // chunk.
        var framer = NDJSONFramer(maxLineBytes: 16)
        XCTAssertNoThrow(try framer.feed(Data(repeating: 0x61, count: 10)))
        XCTAssertThrowsError(try framer.feed(Data(repeating: 0x62, count: 10))) { error in
            XCTAssertEqual(error as? NDJSONFramerError, .lineTooLarge(limit: 16))
        }
    }

    // MARK: - Complete lines before an oversized tail are returned

    func test_feed_completeLinesBeforeOversizedTail_returnsLines_thenCheckPendingThrows() throws {
        var framer = NDJSONFramer(maxLineBytes: 16)
        let chunk = Data(#"{"a":1}"#.utf8) + Data([0x0A]) + Data(#"{"b":2}"#.utf8) + Data([0x0A])
            + Data(repeating: 0x61, count: 17)
        let lines = try framer.feed(chunk)
        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, [#"{"a":1}"#, #"{"b":2}"#])

        XCTAssertThrowsError(try framer.checkPending()) { error in
            XCTAssertEqual(error as? NDJSONFramerError, .lineTooLarge(limit: 16))
        }
        XCTAssertThrowsError(try framer.feed(Data(#"{"c":3}"#.utf8) + Data([0x0A]))) { error in
            XCTAssertEqual(error as? NDJSONFramerError, .lineTooLarge(limit: 16))
        }
    }

    func test_checkPending_withinLimit_doesNotThrow() throws {
        var framer = NDJSONFramer(maxLineBytes: 16)
        _ = try framer.feed(Data(#"{"a":1}"#.utf8) + Data([0x0A]) + Data(repeating: 0x61, count: 16))
        XCTAssertNoThrow(try framer.checkPending())
    }

    func test_checkPending_afterFeedThrew_throwsLineTooLarge() {
        var framer = NDJSONFramer(maxLineBytes: 16)
        XCTAssertThrowsError(try framer.feed(Data(repeating: 0x61, count: 17)))
        XCTAssertThrowsError(try framer.checkPending()) { error in
            XCTAssertEqual(error as? NDJSONFramerError, .lineTooLarge(limit: 16))
        }
    }

    // MARK: - encode(_:)

    func test_encode_appendsExactlyOneTrailingNewline() {
        let framer = NDJSONFramer()
        let payload = Data(#"{"a":1}"#.utf8)
        let framed = framer.encode(payload)
        XCTAssertEqual(framed, payload + Data([0x0A]))
    }

    func test_encode_jsonStringContainingEscapedNewline_doesNotIntroduceRawNewlineByte() {
        // A JSON string value containing a literal newline character is
        // encoded by JSONEncoder as the two-byte escape sequence \n
        // (0x5C 0x6E), never as a raw 0x0A. Confirm encode(_:) does not
        // introduce a second raw 0x0A either.
        struct Payload: Codable { let text: String }
        let data = try! JSONEncoder().encode(Payload(text: "line one\nline two"))
        let framer = NDJSONFramer()
        let framed = framer.encode(data)
        XCTAssertEqual(framed.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(framed.last, 0x0A)
    }
}
