// DiffWrapIndentTests.swift
// CalyxTests
//
// DiffWrapIndent (plan addendum 2 §6): port of VS Code
// computeWrappedTextIndentLength with wrappingIndent 'same', tabSize 4.
// The marker occupies visible column 0 of the same paragraph and NSParagraph
// tab stops (defaultTabInterval) are measured from the fragment origin, so
// counting starts at column 1 after the marker and a tab advances to the next
// multiple of tabSize of that visible column. Result = visible column of the
// first content character; 0 for empty/whitespace-only content; 0 when
// indent + 2 > wrappingColumns.

import Foundation
import Testing
@testable import Calyx

@Suite("DiffWrapIndent.columns")
struct DiffWrapIndentTests {

    @Test func tabSize_isFour() {
        #expect(DiffWrapIndent.tabSize == 4)
    }

    @Test func noLeadingWhitespace_isOne() {
        #expect(DiffWrapIndent.columns(lineText: " foo", wrappingColumns: .max) == 1)
    }

    @Test func fourSpaces_afterAdditionMarker_isFive() {
        #expect(DiffWrapIndent.columns(lineText: "+    foo", wrappingColumns: .max) == 5)
    }

    /// "-\tfoo": marker at column 0, the tab advances 1 -> 4, `foo` at 4.
    @Test func oneTab_afterDeletionMarker_isFour() {
        #expect(DiffWrapIndent.columns(lineText: "-\tfoo", wrappingColumns: .max) == 4)
    }

    /// "  \t foo": marker 0, space -> 2, tab -> 4, space -> 5.
    @Test func mixedSpacesAndTab_tabExpandsToNextMultipleOfFour() {
        #expect(DiffWrapIndent.columns(lineText: "  \t foo", wrappingColumns: .max) == 5)
    }

    /// " \t\tfoo": marker 0, tabs 1 -> 4 -> 8.
    @Test func twoTabs_isEight() {
        #expect(DiffWrapIndent.columns(lineText: " \t\tfoo", wrappingColumns: .max) == 8)
    }

    /// The marker itself is never counted, even when it is a tab.
    @Test func markerColumn_isSkipped() {
        #expect(DiffWrapIndent.columns(lineText: "\tfoo", wrappingColumns: .max) == 1)
    }

    @Test func explicitTabSize_isUsed() {
        // marker 0, tab 1 -> 8.
        #expect(DiffWrapIndent.columns(lineText: "+\tfoo", tabSize: 8, wrappingColumns: .max) == 8)
    }

    @Test func whitespaceOnlyOrEmpty_isZero() {
        #expect(DiffWrapIndent.columns(lineText: "    ", wrappingColumns: .max) == 0)
        #expect(DiffWrapIndent.columns(lineText: "+\t ", wrappingColumns: .max) == 0)
        #expect(DiffWrapIndent.columns(lineText: "+", wrappingColumns: .max) == 0)
        #expect(DiffWrapIndent.columns(lineText: "", wrappingColumns: .max) == 0)
    }

    /// VS Code: indent + columnsForFullWidthChar (2) > wrappingColumns -> 0.
    @Test func noRoom_zeroesIndent() {
        #expect(DiffWrapIndent.columns(lineText: "+    foo", wrappingColumns: 6) == 0)
        #expect(DiffWrapIndent.columns(lineText: "+    foo", wrappingColumns: 7) == 5)
        #expect(DiffWrapIndent.columns(lineText: "+    foo", wrappingColumns: Int.max) == 5)
        // Tab indent 4: no room below 6 columns.
        #expect(DiffWrapIndent.columns(lineText: "-\tfoo", wrappingColumns: 5) == 0)
        #expect(DiffWrapIndent.columns(lineText: "-\tfoo", wrappingColumns: 6) == 4)
    }
}
