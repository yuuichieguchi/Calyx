// LinesDiffComputer.swift
// Calyx
//
// Port of src/vs/editor/common/diff/linesDiffComputer.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).
// `computeMoves` / `MovedText` are not ported (moved-code detection is off).

import Foundation

/// TS `ILinesDiffComputerOptions` (without `computeMoves`), with the diff
/// editor's defaults (diffEditorOptions.ts).
struct LinesDiffOptions: Equatable, Sendable {
    var ignoreTrimWhitespace: Bool = true
    var maxComputationTimeMs: Int = 5000
    var extendToSubwords: Bool = false
}

struct LinesDiff: Equatable, Sendable {
    let changes: [DetailedLineRangeMapping]

    /// Indicates if the time out was reached. In that case, the diffs might be an
    /// approximation and the user should be asked to rerun the diff with more time.
    let hitTimeout: Bool
}
