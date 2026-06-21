import XCTest
@testable import Calyx

final class FuzzyMatcherTests: XCTestCase {

    // MARK: - Basic Matching

    func test_exact_match_scores_higher_than_prefix() {
        let exact = FuzzyMatcher.score(query: "copy", candidate: "copy")
        let prefix = FuzzyMatcher.score(query: "copy", candidate: "copy to clipboard")

        XCTAssertGreaterThan(exact, 0, "Exact match should have positive score")
        XCTAssertGreaterThan(prefix, 0, "Prefix match should have positive score")
        XCTAssertGreaterThan(exact, prefix, "Exact match should score higher than prefix")
    }

    func test_prefix_scores_higher_than_substring() {
        let prefix = FuzzyMatcher.score(query: "new", candidate: "new tab")
        let substring = FuzzyMatcher.score(query: "new", candidate: "create new tab")

        XCTAssertGreaterThan(prefix, 0)
        XCTAssertGreaterThan(substring, 0)
        XCTAssertGreaterThan(prefix, substring, "Prefix match should score higher than substring")
    }

    func test_substring_scores_higher_than_scattered() {
        let substring = FuzzyMatcher.score(query: "tab", candidate: "new tab")
        let scattered = FuzzyMatcher.score(query: "tab", candidate: "extract label")

        XCTAssertGreaterThan(substring, 0)
        XCTAssertGreaterThan(scattered, 0)
        XCTAssertGreaterThan(substring, scattered, "Substring should score higher than scattered")
    }

    // MARK: - Empty Query

    func test_empty_query_matches_all() {
        let score = FuzzyMatcher.score(query: "", candidate: "anything")
        XCTAssertGreaterThan(score, 0, "Empty query should match all candidates")
    }

    // MARK: - Case Insensitivity

    func test_case_insensitive_matching() {
        let lower = FuzzyMatcher.score(query: "copy", candidate: "Copy to Clipboard")
        let upper = FuzzyMatcher.score(query: "COPY", candidate: "Copy to Clipboard")

        XCTAssertGreaterThan(lower, 0, "Lowercase query should match mixed-case candidate")
        XCTAssertGreaterThan(upper, 0, "Uppercase query should match mixed-case candidate")
        XCTAssertEqual(lower, upper, "Case should not affect score")
    }

    // MARK: - No Match

    func test_no_match_returns_zero() {
        let score = FuzzyMatcher.score(query: "xyz", candidate: "copy to clipboard")
        XCTAssertEqual(score, 0, "Non-matching query should return 0")
    }

    func test_query_longer_than_candidate_returns_zero() {
        let score = FuzzyMatcher.score(query: "very long query", candidate: "short")
        XCTAssertEqual(score, 0, "Query longer than candidate chars should return 0")
    }

    // MARK: - Frequency Boost (via CommandRegistry)

    @MainActor
    func test_frequency_boost_affects_ranking() {
        let registry = CommandRegistry()

        let cmd1 = PaletteCommand(id: "cmd1", title: "New Tab") {}
        let cmd2 = PaletteCommand(id: "cmd2", title: "New Window") {}

        registry.register(cmd1)
        registry.register(cmd2)

        // Boost cmd2
        registry.recordUsage("cmd2")
        registry.recordUsage("cmd2")
        registry.recordUsage("cmd2")

        let results = registry.search(query: "new")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, "cmd2", "Frequently used command should rank higher")
    }

    // MARK: - Word Start Bonus

    func test_word_start_gets_bonus() {
        let wordStart = FuzzyMatcher.score(query: "s", candidate: "new split")
        let midWord = FuzzyMatcher.score(query: "s", candidate: "restore")

        XCTAssertGreaterThan(wordStart, 0)
        XCTAssertGreaterThan(midWord, 0)
        XCTAssertGreaterThan(wordStart, midWord, "Word-start match should score higher")
    }

    // MARK: - Consecutive Bonus

    func test_consecutive_matches_score_higher() {
        let consecutive = FuzzyMatcher.score(query: "ab", candidate: "abc def")
        let separated = FuzzyMatcher.score(query: "ad", candidate: "abc def")

        XCTAssertGreaterThan(consecutive, 0)
        XCTAssertGreaterThan(separated, 0)
        XCTAssertGreaterThan(consecutive, separated, "Consecutive matches should score higher")
    }
}
