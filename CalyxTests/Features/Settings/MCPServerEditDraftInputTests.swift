//
//  MCPServerEditDraftInputTests.swift
//  CalyxTests
//
//  The add/edit sheet's pure input rules: the Arguments field is split
//  like shell words and written back with the same quoting, and while
//  adding a server the alias follows the name until the user edits it.
//

import XCTest
@testable import Calyx

final class MCPServerArgumentSplitterTests: XCTestCase {

    func test_split_spaceSeparatedWords() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("server.py --port 8080"), ["server.py", "--port", "8080"])
    }

    func test_split_repeatedAndSurroundingWhitespace_isIgnored() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("  a \t  b  "), ["a", "b"])
        XCTAssertEqual(try MCPServerArgumentSplitter.split(""), [])
    }

    func test_split_quotedPathWithSpaces_isOneArgument() throws {
        XCTAssertEqual(
            try MCPServerArgumentSplitter.split(#""/Users/me/My Servers/server.py" --name 'two words'"#),
            ["/Users/me/My Servers/server.py", "--name", "two words"]
        )
    }

    func test_split_escapedQuotes() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split(#"say \"hi\" "a \"b\" c" it\'s"#), ["say", "\"hi\"", "a \"b\" c", "it's"])
    }

    func test_split_newlineSeparatedInput_stillWorks() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("--stdio\n--verbose\n\n/tmp/x"), ["--stdio", "--verbose", "/tmp/x"])
    }

    func test_split_emptyQuotes_areEmptyArguments() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split(#"a '' """#), ["a", "", ""])
    }

    func test_split_unterminatedQuote_throws() {
        XCTAssertThrowsError(try MCPServerArgumentSplitter.split("'open")) { error in
            XCTAssertEqual(error as? MCPServerArgumentSplitter.SplitError, .unterminatedQuote("'"))
        }
        XCTAssertThrowsError(try MCPServerArgumentSplitter.split("\"open")) { error in
            XCTAssertEqual(error as? MCPServerArgumentSplitter.SplitError, .unterminatedQuote("\""))
        }
    }

    func test_split_trailingBackslash_throws() {
        XCTAssertThrowsError(try MCPServerArgumentSplitter.split("a\\")) { error in
            XCTAssertEqual(error as? MCPServerArgumentSplitter.SplitError, .trailingBackslash)
        }
    }

    func test_join_thenSplit_roundTrips() throws {
        let arguments = ["plain", "two words", "it's", #"say "hi""#, #"back\slash"#, "", "line\nbreak"]
        XCTAssertEqual(try MCPServerArgumentSplitter.split(MCPServerArgumentSplitter.join(arguments)), arguments)
    }

    func test_join_leavesPlainArgumentsUnquoted() {
        XCTAssertEqual(MCPServerArgumentSplitter.join(["server.py", "--port", "8080"]), "server.py --port 8080")
        XCTAssertEqual(MCPServerArgumentSplitter.join(["/a b/c"]), "'/a b/c'")
    }

    // MARK: - Special characters followed by a combining scalar

    // A quote, space or backslash followed by a combining mark, ZWJ,
    // variation selector or emoji modifier forms one Character with it,
    // but each is still special to the splitter.

    func test_split_quoteFollowedByACombiningMark_opensAQuote() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("'\u{301}x y'"), ["\u{301}x y"])
    }

    func test_split_spaceFollowedByACombiningMark_separatesArguments() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("a \u{301}"), ["a", "\u{301}"])
    }

    func test_split_backslashFollowedByAVariationSelector_escapesTheSelector() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("a\\\u{FE0F}b"), ["a\u{FE0F}b"])
    }

    func test_split_spaceFollowedByAnEmojiModifier_separatesArguments() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("a \u{1F3FB}"), ["a", "\u{1F3FB}"])
    }

    func test_split_crlf_isTwoSeparators_andABackslashBeforeItJoinsTheLines() throws {
        XCTAssertEqual(try MCPServerArgumentSplitter.split("a\r\nb"), ["a", "b"])
        XCTAssertEqual(try MCPServerArgumentSplitter.split("a\\\r\nb"), ["ab"])
        XCTAssertEqual(try MCPServerArgumentSplitter.split("a\\\nb"), ["ab"])
    }

    func test_join_argumentStartingWithACombiningMark_splitsBack() throws {
        let arguments = ["\u{301}x y"]
        XCTAssertEqual(try MCPServerArgumentSplitter.split(MCPServerArgumentSplitter.join(arguments)), arguments)
    }

    func test_join_argumentThatIsACombiningMark_staysASeparateArgument() throws {
        let arguments = ["a", "\u{301}"]
        XCTAssertEqual(try MCPServerArgumentSplitter.split(MCPServerArgumentSplitter.join(arguments)), arguments)
    }

    func test_join_zwjBeforeAQuote_roundTrips() throws {
        let arguments = ["\u{200D}' z"]
        XCTAssertEqual(try MCPServerArgumentSplitter.split(MCPServerArgumentSplitter.join(arguments)), arguments)
    }

    func test_join_combiningScalarsAfterEverySpecialCharacter_roundTrip() throws {
        let arguments = [
            "'\u{301}", "\"\u{FE0F}", "\\\u{1F3FB}", " \u{200D}", "\t\u{301}", "\n\u{301}", "\r\n\u{301}", "it\u{301}'s",
        ]
        XCTAssertEqual(try MCPServerArgumentSplitter.split(MCPServerArgumentSplitter.join(arguments)), arguments)
    }
}

final class MCPServerAliasFieldStateTests: XCTestCase {

    func test_alias_followsTheDerivedAliasOfTheName() {
        var field = MCPServerAliasFieldState()
        field.nameDidChange("My Weather")
        XCTAssertEqual(field.alias, "myweather")
        field.nameDidChange("My Weather Server")
        XCTAssertEqual(field.alias, "myweathers")
    }

    func test_alias_isEmptyWhenNothingCanBeDerived() {
        var field = MCPServerAliasFieldState()
        field.nameDidChange("Weather")
        field.nameDidChange("!!!")
        XCTAssertEqual(field.alias, "")
    }

    func test_userEdit_stopsFollowingTheName() {
        var field = MCPServerAliasFieldState()
        field.nameDidChange("Weather")
        field.userDidEdit("wx")
        field.nameDidChange("Something Else")
        XCTAssertEqual(field.alias, "wx")
        XCTAssertFalse(field.followsName)
    }

    func test_writingTheSameValue_isNotAnEdit() {
        var field = MCPServerAliasFieldState()
        field.nameDidChange("Weather")
        field.userDidEdit("weather")
        field.nameDidChange("Forecast")
        XCTAssertEqual(field.alias, "forecast")
        XCTAssertTrue(field.followsName)
    }
}
