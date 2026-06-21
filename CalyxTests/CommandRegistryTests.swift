//
//  CommandRegistryTests.swift
//  CalyxTests
//
//  Tests for CommandRegistry: registration, fuzzy search, frequency
//  ranking, edge cases, and ordering stability.
//
//  Coverage:
//  - Register command → allCommands contains it
//  - Search empty string → returns all commands
//  - Search "new" → matches "New Tab", "New Group"
//  - Search "xyz" → empty result
//  - recordUsage → ranking changes
//  - Case insensitive search
//  - Empty registry search → empty array
//  - Ranking stability on tie (registration order preserved)
//

import XCTest
@testable import Calyx

@MainActor
final class CommandRegistryTests: XCTestCase {

    // MARK: - Helpers

    private func makeRegistry() -> CommandRegistry {
        CommandRegistry()
    }

    private func makeCommand(
        id: String = "test.cmd",
        title: String = "Test Command",
        shortcut: String? = nil,
        category: String = "General"
    ) -> PaletteCommand {
        PaletteCommand(id: id, title: title, shortcut: shortcut, category: category) {}
    }

    // ==================== 1. Register → allCommands Contains It ====================

    func test_should_contain_command_after_registration() {
        // Arrange
        let registry = makeRegistry()
        let command = makeCommand(id: "new.tab", title: "New Tab")

        // Act
        registry.register(command)

        // Assert
        XCTAssertEqual(registry.allCommands.count, 1,
                       "Registry should have exactly 1 command after registration")
        XCTAssertEqual(registry.allCommands.first?.id, "new.tab",
                       "Registered command should be accessible via allCommands")
        XCTAssertEqual(registry.allCommands.first?.title, "New Tab",
                       "Command title should match what was registered")
    }

    // ==================== 2. Search Empty String → Returns All ====================

    func test_should_return_all_commands_when_search_query_is_empty() {
        // Arrange
        let registry = makeRegistry()
        registry.register(makeCommand(id: "cmd1", title: "New Tab"))
        registry.register(makeCommand(id: "cmd2", title: "Close Window"))
        registry.register(makeCommand(id: "cmd3", title: "Split Pane"))

        // Act
        let results = registry.search(query: "")

        // Assert
        XCTAssertEqual(results.count, 3,
                       "Empty query should return all registered commands (FuzzyMatcher returns 1 for empty)")
    }

    // ==================== 3. Search "new" → Matches "New Tab", "New Group" ====================

    func test_should_return_matching_commands_when_search_query_is_new() {
        // Arrange
        let registry = makeRegistry()
        registry.register(makeCommand(id: "new.tab", title: "New Tab"))
        registry.register(makeCommand(id: "new.group", title: "New Group"))
        registry.register(makeCommand(id: "close.win", title: "Close Window"))
        registry.register(makeCommand(id: "split.pane", title: "Split Pane"))

        // Act
        let results = registry.search(query: "new")

        // Assert
        XCTAssertEqual(results.count, 2,
                       "Query 'new' should match exactly 'New Tab' and 'New Group'")
        let resultIDs = Set(results.map(\.id))
        XCTAssertTrue(resultIDs.contains("new.tab"),
                      "Results should include 'New Tab'")
        XCTAssertTrue(resultIDs.contains("new.group"),
                      "Results should include 'New Group'")
    }

    // ==================== 4. Search "xyz" → Empty Result ====================

    func test_should_return_empty_when_no_commands_match() {
        // Arrange
        let registry = makeRegistry()
        registry.register(makeCommand(id: "new.tab", title: "New Tab"))
        registry.register(makeCommand(id: "close.win", title: "Close Window"))

        // Act
        let results = registry.search(query: "xyz")

        // Assert
        XCTAssertTrue(results.isEmpty,
                      "Query 'xyz' should not match any commands")
    }

    // ==================== 5. recordUsage → Ranking Changes ====================

    func test_should_boost_ranking_after_recording_usage() {
        // Arrange
        let registry = makeRegistry()
        let cmdNewTab = makeCommand(id: "new.tab", title: "New Tab")
        let cmdNewWindow = makeCommand(id: "new.window", title: "New Window")
        registry.register(cmdNewTab)
        registry.register(cmdNewWindow)

        // Pre-condition: get initial ranking for query "new"
        let initialResults = registry.search(query: "new")
        XCTAssertEqual(initialResults.count, 2)
        let initialFirstID = initialResults[0].id

        // Act — boost the command that was NOT ranked first
        let idToBoost = initialFirstID == "new.tab" ? "new.window" : "new.tab"
        for _ in 0..<10 {
            registry.recordUsage(idToBoost)
        }

        // Assert — boosted command should now rank first
        let boostedResults = registry.search(query: "new")
        XCTAssertEqual(boostedResults.first?.id, idToBoost,
                       "Frequently used command should rank higher after recordUsage")
    }

    // ==================== 6. Case Insensitive Search ====================

    func test_should_match_case_insensitively() {
        // Arrange
        let registry = makeRegistry()
        registry.register(makeCommand(id: "new.tab", title: "New Tab"))

        // Act
        let upperResults = registry.search(query: "NEW")
        let lowerResults = registry.search(query: "new")
        let mixedResults = registry.search(query: "nEw")

        // Assert
        XCTAssertEqual(upperResults.count, 1,
                       "'NEW' should match 'New Tab' case-insensitively")
        XCTAssertEqual(lowerResults.count, 1,
                       "'new' should match 'New Tab' case-insensitively")
        XCTAssertEqual(mixedResults.count, 1,
                       "'nEw' should match 'New Tab' case-insensitively")
    }

    // ==================== 7. Empty Registry Search → Empty Array ====================

    func test_should_return_empty_array_when_registry_is_empty() {
        // Arrange
        let registry = makeRegistry()

        // Act
        let results = registry.search(query: "anything")
        let emptyQueryResults = registry.search(query: "")

        // Assert
        XCTAssertTrue(results.isEmpty,
                      "Search on empty registry should return empty array")
        XCTAssertTrue(emptyQueryResults.isEmpty,
                      "Empty query on empty registry should return empty array")
    }

    // ==================== 8. Ranking Stability on Tie ====================

    func test_should_preserve_registration_order_when_scores_tie() {
        // Arrange — two commands with identical titles → same FuzzyMatcher score
        let registry = makeRegistry()
        let cmd1 = makeCommand(id: "first", title: "Duplicate Command")
        let cmd2 = makeCommand(id: "second", title: "Duplicate Command")
        registry.register(cmd1)
        registry.register(cmd2)

        // Act
        let results = registry.search(query: "dup")

        // Assert — with equal scores, sorted { $0.1 > $1.1 } preserves
        // relative order from the input array (Swift's sort is stable),
        // so registration order should be maintained.
        XCTAssertEqual(results.count, 2,
                       "Both commands should match query 'dup'")
        XCTAssertEqual(results[0].id, "first",
                       "First registered command should appear first when scores tie")
        XCTAssertEqual(results[1].id, "second",
                       "Second registered command should appear second when scores tie")
    }
}
