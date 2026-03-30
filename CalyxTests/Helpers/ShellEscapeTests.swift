// ShellEscapeTests.swift
// CalyxTests
//
// TDD red-phase tests for ShellEscape.
//
// ShellEscape is a utility enum that escapes shell-sensitive characters
// by prefixing each with a backslash (matching Ghostty's Shell.swift
// escape set, rev 332b2aefc).
//
// Coverage:
// - Plain path passes through unchanged
// - Space escaping
// - Parentheses escaping
// - Single quote escaping
// - Backslash escaping (must not double-escape)
// - Tab character escaping
// - Multiple special characters in sequence
// - Empty string
// - Non-ASCII (Japanese) filenames pass through unchanged
// - URL with query string and ampersand
// - Full Ghostty escape-set parity

import Testing
@testable import Calyx

// MARK: - Pass-Through Tests

@Suite("ShellEscape - plain strings pass through unchanged")
struct ShellEscapePassThroughTests {

    @Test("Plain path with no special characters passes through unchanged")
    func plainPathUnchanged() {
        let result = ShellEscape.escape("/usr/local/bin")
        #expect(
            result == "/usr/local/bin",
            "Plain path should pass through unchanged but got \(result)"
        )
    }

    @Test("Empty string returns empty string")
    func emptyStringReturnsEmpty() {
        let result = ShellEscape.escape("")
        #expect(
            result == "",
            "Empty string should return empty but got \(result)"
        )
    }

    @Test("Non-ASCII characters (Japanese filename) pass through unchanged")
    func nonASCIIPassesThrough() {
        let result = ShellEscape.escape("/Users/名前/ドキュメント/報告書.txt")
        #expect(
            result == "/Users/名前/ドキュメント/報告書.txt",
            "Japanese filename should pass through unchanged but got \(result)"
        )
    }
}

// MARK: - Individual Character Escaping Tests

@Suite("ShellEscape - individual special characters")
struct ShellEscapeIndividualTests {

    @Test("Path with spaces gets spaces escaped")
    func spacesAreEscaped() {
        let result = ShellEscape.escape("/Users/name/My Documents")
        #expect(
            result == "/Users/name/My\\ Documents",
            "Spaces should be escaped but got \(result)"
        )
    }

    @Test("Path with parentheses gets parentheses escaped")
    func parenthesesAreEscaped() {
        let result = ShellEscape.escape("file (copy).txt")
        #expect(
            result == "file\\ \\(copy\\).txt",
            "Parentheses and space should be escaped but got \(result)"
        )
    }

    @Test("Single quotes are escaped")
    func singleQuotesAreEscaped() {
        let result = ShellEscape.escape("it's")
        #expect(
            result == "it\\'s",
            "Single quote should be escaped but got \(result)"
        )
    }

    @Test("Backslash is escaped correctly and not double-escaped")
    func backslashEscapedCorrectly() {
        let result = ShellEscape.escape("a\\b")
        #expect(
            result == "a\\\\b",
            "Backslash should be escaped to double-backslash but got \(result)"
        )
    }

    @Test("Tab character is escaped")
    func tabCharacterIsEscaped() {
        let result = ShellEscape.escape("a\tb")
        #expect(
            result == "a\\\tb",
            "Tab should be preceded by a backslash but got \(result)"
        )
    }
}

// MARK: - Complex Input Tests

@Suite("ShellEscape - complex inputs")
struct ShellEscapeComplexTests {

    @Test("Multiple special characters in sequence are all escaped")
    func multipleSpecialCharsInSequence() {
        // Input contains: space, open-paren, close-paren, single-quote
        let result = ShellEscape.escape("a (b)'c")
        #expect(
            result == "a\\ \\(b\\)\\'c",
            "All special characters should be individually escaped but got \(result)"
        )
    }

    @Test("URL with query string and ampersand gets ? and & escaped")
    func urlQueryStringEscaped() {
        let result = ShellEscape.escape("https://example.com?q=1&b=2")
        #expect(
            result == "https://example.com\\?q=1\\&b=2",
            "Question mark and ampersand should be escaped but got \(result)"
        )
    }

    @Test("Ghostty parity: all escape-set characters are individually escaped")
    func ghosttyParityAllChars() {
        // The full escape set (in order):
        //   \  space  (  )  [  ]  {  }  <  >  "  '  `  !  #  $  &  ;  |  *  ?  \t
        // Each character in the input should be prefixed with a backslash.
        let specials: [Character] = [
            "\\", " ", "(", ")", "[", "]", "{", "}", "<", ">",
            "\"", "'", "`", "!", "#", "$", "&", ";", "|", "*",
            "?", "\t",
        ]
        let input = String(specials)
        let expected = specials.map { "\\\($0)" }.joined()

        let result = ShellEscape.escape(input)
        #expect(
            result == expected,
            "Every character in the Ghostty escape set should be escaped but got \(result)"
        )
    }
}
