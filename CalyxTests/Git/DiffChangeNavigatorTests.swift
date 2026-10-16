// DiffChangeNavigatorTests.swift
// CalyxTests
//
// DiffChangeNavigator.target: port of VS Code DiffEditorWidget.goToDiff
// (diffEditorWidget.ts). Changes at modified starts 10, 50, 90 in a
// 100-line file.

import Foundation
import Testing
@testable import Calyx

private func change(modStart: Int) -> DetailedLineRangeMapping {
    DetailedLineRangeMapping(
        original: LineRange(startLineNumber: modStart, endLineNumberExclusive: modStart + 1),
        modified: LineRange(startLineNumber: modStart, endLineNumberExclusive: modStart + 1),
        innerChanges: nil
    )
}

@Suite("DiffChangeNavigator")
struct DiffChangeNavigatorTests {

    private let changes = [change(modStart: 10), change(modStart: 50), change(modStart: 90)]

    private func next(_ line: Int) -> Int? {
        DiffChangeNavigator.target(changes: changes, currentModifiedLine: line, modifiedLineCount: 100, direction: .next)
    }

    private func previous(_ line: Int) -> Int? {
        DiffChangeNavigator.target(changes: changes, currentModifiedLine: line, modifiedLineCount: 100, direction: .previous)
    }

    @Test func empty_returnsNil() {
        #expect(DiffChangeNavigator.target(changes: [], currentModifiedLine: 1, modifiedLineCount: 100, direction: .next) == nil)
        #expect(DiffChangeNavigator.target(changes: [], currentModifiedLine: 1, modifiedLineCount: 100, direction: .previous) == nil)
    }

    @Test func next_firstStartStrictlyAfterCurrent() {
        #expect(next(1) == 0)
        #expect(next(10) == 1)
        #expect(next(50) == 2)
    }

    @Test func next_wrapsToFirst() {
        #expect(next(90) == 0)
    }

    @Test func next_onLastLine_goesToFirst() {
        #expect(next(100) == 0)
    }

    @Test func previous_lastStartStrictlyBeforeCurrent() {
        #expect(previous(100) == 2)
        #expect(previous(50) == 0)
    }

    @Test func previous_wrapsToLast() {
        #expect(previous(10) == 2)
        #expect(previous(1) == 2)
    }

    /// A cursor clamped to the last line (pure deletion at EOF): Previous
    /// takes only changes starting strictly before it.
    @Test func previous_onLastLine_excludesChangeStartingOnLastLine() {
        let changes = [change(modStart: 10), change(modStart: 100)]
        #expect(DiffChangeNavigator.target(changes: changes, currentModifiedLine: 100,
                                           modifiedLineCount: 100, direction: .previous) == 0)
        #expect(DiffChangeNavigator.target(changes: changes, currentModifiedLine: 100,
                                           modifiedLineCount: 100, direction: .next) == 0)
    }
}
