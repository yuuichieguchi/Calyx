// DiffWrapIndent.swift
// Calyx
//
// Hanging indent of wrapped diff lines: port of VS Code
// `computeWrappedTextIndentLength` (monospaceLineBreaksComputer.ts) with
// `wrappingIndent: same`. The diff marker column (index 0) is skipped.

import Foundation

enum DiffWrapIndent {
    static let tabSize = 4
    /// VS Code `columnsForFullWidthChar`.
    private static let columnsForFullWidthChar = 2

    /// Columns continuation lines are indented by: the visible column of the
    /// first non-whitespace content character (marker counted as column 0); 0 when the content has no
    /// non-whitespace character or the indent leaves no room.
    static func columns(lineText: String, tabSize: Int = tabSize, wrappingColumns: Int) -> Int {
        // The marker occupies visible column 0 of the same paragraph and
        // `defaultTabInterval` is measured from the fragment origin, so tab
        // stops are computed from column 1 (right after the marker).
        var column = 1
        var foundNonWhitespace = false
        for (index, scalar) in lineText.unicodeScalars.enumerated() where index > 0 {
            if scalar == " " {
                column += 1
            } else if scalar == "\t" {
                column += tabSize - (column % tabSize)
            } else {
                foundNonWhitespace = true
                break
            }
        }
        guard foundNonWhitespace else { return 0 }
        let indent = column
        if indent + columnsForFullWidthChar > wrappingColumns { return 0 }
        return indent
    }
}
