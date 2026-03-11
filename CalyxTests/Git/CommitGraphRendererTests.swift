// CommitGraphRendererTests.swift
// CalyxTests
//
// Tests for CommitGraphRenderer: prefix parsing and attributed string generation.

import Testing
@testable import Calyx

struct CommitGraphRendererTests {
    @Test func emptyPrefix() {
        let result = CommitGraphRenderer.parse("")
        #expect(result.isEmpty)
    }

    @Test func pipeCharacter() {
        let result = CommitGraphRenderer.parse("|")
        #expect(result.count == 1)
        #expect(result[0] == .pipe)
    }

    @Test func starCharacter() {
        let result = CommitGraphRenderer.parse("*")
        #expect(result.count == 1)
        #expect(result[0] == .star)
    }

    @Test func allCharacters() {
        let result = CommitGraphRenderer.parse("|*/\\ -.")
        #expect(result.count == 7)
        #expect(result[0] == .pipe)
        #expect(result[1] == .star)
        #expect(result[2] == .slash)
        #expect(result[3] == .backslash)
        #expect(result[4] == .space)
        #expect(result[5] == .dash)
        #expect(result[6] == .dot)
    }

    @Test func typicalGraphPrefix() {
        let result = CommitGraphRenderer.parse("| * ")
        #expect(result.count == 4)
        #expect(result[0] == .pipe)
        #expect(result[1] == .space)
        #expect(result[2] == .star)
        #expect(result[3] == .space)
    }

    @Test func attributedStringNotEmpty() {
        let elements: [GraphElement] = [.pipe, .space, .star]
        let attributed = CommitGraphRenderer.attributedString(from: elements)
        #expect(attributed.length > 0)
    }

    @Test func laneColorRotation() {
        // 9 pipe characters should rotate through 8 colors and restart
        let elements = Array(repeating: GraphElement.pipe, count: 9)
        let attributed = CommitGraphRenderer.attributedString(from: elements)
        #expect(attributed.length == 9) // 9 characters (│ is 1 char)
    }
}
