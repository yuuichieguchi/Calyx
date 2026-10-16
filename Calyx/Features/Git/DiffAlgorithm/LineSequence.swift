// LineSequence.swift
// Calyx
//
// Port of src/vs/editor/common/diff/defaultLinesDiffComputer/lineSequence.ts
// (microsoft/vscode c2c46e750ab7afe355bad8bea20a248520adfdb0).

import Foundation

struct LineSequence: DiffSequence {
    private let trimmedHash: [Int]
    private let lines: [String]

    init(trimmedHash: [Int], lines: [String]) {
        self.trimmedHash = trimmedHash
        self.lines = lines
    }

    func getElement(_ offset: Int) -> Int {
        trimmedHash[offset]
    }

    var length: Int {
        trimmedHash.count
    }

    func getBoundaryScore(_ length: Int) -> Int? {
        let indentationBefore = length == 0 ? 0 : getIndentation(lines[length - 1])
        let indentationAfter = length == lines.count ? 0 : getIndentation(lines[length])
        return 1000 - (indentationBefore + indentationAfter)
    }

    func getText(_ range: OffsetRange) -> String {
        lines[range.start..<range.endExclusive].joined(separator: "\n")
    }

    func isStronglyEqual(_ offset1: Int, _ offset2: Int) -> Bool {
        jsStringEquals(lines[offset1], lines[offset2])
    }
}

/// Counts leading spaces / tabs (in UTF-16 code units, which are 1:1 for these).
private func getIndentation(_ str: String) -> Int {
    var i = 0
    for unit in str.utf16 {
        guard Int(unit) == CharCode.space || Int(unit) == CharCode.tab else {
            break
        }
        i += 1
    }
    return i
}
