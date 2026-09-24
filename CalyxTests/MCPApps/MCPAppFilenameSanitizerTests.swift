//
//  MCPAppFilenameSanitizerTests.swift
//  CalyxTests
//
//  Pure filename sanitization for ui/download-file and materialized
//  non-text ui/message content (contract v2 §11.7, rules pinned verbatim):
//  path separators (`/`, `\`), `:`, and control characters become `_`;
//  leading dots are stripped (no hidden files); surrounding whitespace is
//  trimmed; a 255-byte UTF-8 cap truncates the body while keeping the
//  extension; an empty result becomes "download"; a case-insensitive
//  collision against existingNames gets " (2)", " (3)", ... inserted
//  before the extension, at the first free name.
//

import XCTest
@testable import Calyx

final class MCPAppFilenameSanitizerTests: XCTestCase {

    // MARK: - Path separators, colon, control characters -> "_"

    func test_pathSeparators_areReplacedWithUnderscore() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("a/b\\c", existingNames: []), "a_b_c")
    }

    func test_colon_isReplacedWithUnderscore() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("a:b", existingNames: []), "a_b")
    }

    func test_controlCharacters_areReplacedWithUnderscore() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("report\u{0007}.pdf", existingNames: []), "report_.pdf")
    }

    // MARK: - Leading dots stripped

    func test_leadingDots_areStripped_noHiddenFiles() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("..secret", existingNames: []), "secret")
    }

    func test_singleLeadingDot_isStripped() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize(".bashrc", existingNames: []), "bashrc")
    }

    // MARK: - Surrounding whitespace trimmed

    func test_surroundingWhitespace_isTrimmed() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("  report.pdf  ", existingNames: []), "report.pdf")
    }

    // MARK: - 255-byte UTF-8 cap, extension preserved

    func test_255ByteCap_isEnforced() {
        let longName = String(repeating: "a", count: 400) + ".txt"
        let sanitized = MCPAppFilenameSanitizer.sanitize(longName, existingNames: [])
        XCTAssertLessThanOrEqual(sanitized.utf8.count, 255)
    }

    func test_255ByteCap_preservesExtension() {
        let longName = String(repeating: "a", count: 400) + ".txt"
        let sanitized = MCPAppFilenameSanitizer.sanitize(longName, existingNames: [])
        XCTAssertTrue(sanitized.hasSuffix(".txt"), "truncation must not eat the extension")
    }

    // MARK: - Empty result -> "download"

    func test_emptyAfterSanitization_becomesDownload() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("...", existingNames: []), "download")
    }

    func test_wholeStringWhitespace_becomesDownload() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("   ", existingNames: []), "download")
    }

    // MARK: - Dedup: case-insensitive, " (n)" before the extension

    func test_dedup_noCollision_returnsUnchanged() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("report.pdf", existingNames: []), "report.pdf")
    }

    func test_dedup_collision_appendsParenthesizedCounter() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("report.pdf", existingNames: ["report.pdf"]), "report (2).pdf")
    }

    func test_dedup_multipleCollisions_incrementsToFirstFreeName() {
        let sanitized = MCPAppFilenameSanitizer.sanitize(
            "report.pdf", existingNames: ["report.pdf", "report (2).pdf", "report (3).pdf"]
        )
        XCTAssertEqual(sanitized, "report (4).pdf")
    }

    func test_dedup_isCaseInsensitive() {
        XCTAssertEqual(MCPAppFilenameSanitizer.sanitize("Report.PDF", existingNames: ["report.pdf"]), "Report (2).PDF")
    }
}
