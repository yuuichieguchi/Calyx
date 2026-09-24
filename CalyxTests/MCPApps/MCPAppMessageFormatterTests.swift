//
//  MCPAppMessageFormatterTests.swift
//  CalyxTests
//
//  MCPAppMessageFormatter is pure (contract v2 §11.12). Text content has
//  no length cap and is always pasted inline verbatim (the 32 KiB
//  threshold from an earlier draft is explicitly withdrawn, §11.12 /
//  §11.20 / §15). Only non-text content (images) is written to a file,
//  with the file's path substituted into pastedText.
//

import XCTest
@testable import Calyx

final class MCPAppMessageFormatterTests: XCTestCase {

    // MARK: - Control character sanitization

    func test_c0Controls_exceptNewlineAndTab_areDropped() {
        let formatted = MCPAppMessageFormatter.sanitizeControlCharacters("a\u{0001}b\u{0007}c")
        XCTAssertEqual(formatted, "abc")
    }

    func test_newlineAndTab_arePreserved() {
        let formatted = MCPAppMessageFormatter.sanitizeControlCharacters("a\nb\tc")
        XCTAssertEqual(formatted, "a\nb\tc")
    }

    func test_escAndDEL_areDropped() {
        let formatted = MCPAppMessageFormatter.sanitizeControlCharacters("a\u{001B}b\u{007F}c")
        XCTAssertEqual(formatted, "abc")
    }

    func test_c1Controls_areDropped() {
        let formatted = MCPAppMessageFormatter.sanitizeControlCharacters("a\u{0090}b")
        XCTAssertEqual(formatted, "ab")
    }

    func test_crAndCRLF_becomeLF() {
        XCTAssertEqual(MCPAppMessageFormatter.sanitizeControlCharacters("a\rb"), "a\nb")
        XCTAssertEqual(MCPAppMessageFormatter.sanitizeControlCharacters("a\r\nb"), "a\nb")
    }

    // MARK: - Text is always pasted inline, with no length cap

    func test_shortText_isPastedInline_noFileWritten() throws {
        let result = try MCPAppMessageFormatter.format(content: [.text("hello world")])
        XCTAssertEqual(result.pastedText, "hello world")
        XCTAssertEqual(result.writtenFilePaths, [])
    }

    func test_textOver1MiB_isStillPastedInline_noFileWritten() throws {
        // The 32 KiB threshold from an earlier draft is withdrawn (§11.12,
        // §15 Decisions carried from the plan): text has no length cap,
        // regardless of size.
        let bigText = String(repeating: "x", count: 1024 * 1024 + 1)
        let result = try MCPAppMessageFormatter.format(content: [.text(bigText)])

        XCTAssertEqual(result.pastedText, bigText)
        XCTAssertEqual(result.writtenFilePaths, [])
    }

    // MARK: - Non-text content is materialized to a file

    func test_imageContent_isWrittenToFile_notPastedAsText() throws {
        let result = try MCPAppMessageFormatter.format(content: [.image(base64: "aGVsbG8=", mimeType: "image/png")])

        XCTAssertEqual(result.writtenFilePaths.count, 1)
    }

    func test_mixedTextAndImage_textPastedInline_imagePathAlsoPresent() throws {
        let result = try MCPAppMessageFormatter.format(content: [.text("caption"), .image(base64: "aGVsbG8=", mimeType: "image/png")])

        XCTAssertTrue(result.pastedText.contains("caption"))
        XCTAssertEqual(result.writtenFilePaths.count, 1)
    }

    func test_multipleImages_eachWrittenToItsOwnFile() throws {
        let result = try MCPAppMessageFormatter.format(content: [
            .image(base64: "aGVsbG8=", mimeType: "image/png"),
            .image(base64: "d29ybGQ=", mimeType: "image/png"),
        ])

        XCTAssertEqual(result.writtenFilePaths.count, 2)
    }

    // MARK: - A failed image write throws instead of stopping the process

    func test_imageWriteFailure_throws() throws {
        // A regular file where the image directory's parent should be, so
        // the directory cannot be created.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("calyx-mcp-apps-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        XCTAssertThrowsError(try MCPAppMessageFormatter.format(
            content: [.image(base64: "aGVsbG8=", mimeType: "image/png")],
            imageDirectory: blocker.appendingPathComponent("images")
        ))
    }
}
