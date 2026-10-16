// DiffReviewFixesTests.swift
// CalyxTests
//
// Modified-side text of unchanged lines, uncompared (too-large) files,
// display-only text sanitisation/truncation in DiffView, and the
// cancellation-aware diff timeout.

import AppKit
import Foundation
import Testing
@testable import Calyx

private func content(_ old: [String], _ new: [String]) -> DiffContent {
    DiffContent(oldLines: old, newLines: new, isBinary: false,
                oldMissingTrailingNewline: false, newMissingTrailingNewline: false)
}

/// Text a cell displays, via DiffView's display path.
@MainActor
private func displayed(_ cell: DiffCell?, _ displayLines: [DisplayLine]) -> String? {
    guard let cell, let d = cell.displayIndex, case .diff(let line) = displayLines[d] else { return nil }
    return DiffView.displayedText(line, side: cell.textSide).text
}

@MainActor
struct DiffModifiedTextTests {

    @Test func whitespaceOnlyChange_contextLineCarriesNewText() {
        let options = LinesDiffOptions(ignoreTrimWhitespace: true)
        let c = content(["a", "  b", "c"], ["a", "b  ", "c"])
        let result = DefaultLinesDiffComputer().computeDiff(originalLines: c.oldLines, modifiedLines: c.newLines,
                                                            options: options)
        #expect(result.changes.isEmpty)
        let lines = DiffLineGenerator.lines(content: c, changes: result.changes)
        #expect(lines == [
            DiffLine(type: .context, text: " a", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(type: .context, text: "   b", oldLineNumber: 2, newLineNumber: 2, newText: " b  "),
            DiffLine(type: .context, text: " c", oldLineNumber: 3, newLineNumber: 3),
        ])
    }

    @Test func whitespaceOnlyChange_rightCellShowsNewText_leftShowsOld() {
        let lines = DiffLineGenerator.lines(content: content(["  b"], ["b  "]), changes: [])
        let displayLines = lines.map { DisplayLine.diff($0) }

        let sbs = DiffRowBuilder.build(displayLines: displayLines, changes: [], layout: .sideBySide)
        #expect(sbs.count == 1)
        #expect(displayed(sbs[0].left, displayLines) == "   b")
        #expect(displayed(sbs[0].right, displayLines) == " b  ")

        let inline = DiffRowBuilder.build(displayLines: displayLines, changes: [], layout: .inline)
        #expect(inline.count == 1)
        #expect(displayed(inline[0].left, displayLines) == " b  ")
    }

    @Test func parser_whitespaceOnlyChange_rightCellShowsNewText() {
        let raw = """
        diff --git a/f b/f
        --- a/f
        +++ b/f
        @@ -1,2 +1,2 @@
         x
        -  y
        +y\t
        """
        let diff = DiffParser.parse(raw, path: "f", options: LinesDiffOptions(ignoreTrimWhitespace: true))
        #expect(diff.changes.isEmpty)
        let displayLines = diff.lines.map { DisplayLine.diff($0) }
        let rows = DiffRowBuilder.build(displayLines: displayLines, changes: diff.changes, layout: .sideBySide)
        #expect(displayed(rows[1].left, displayLines) == "   y")
        #expect(displayed(rows[1].right, displayLines) == " y\t")
    }
}

@MainActor
struct DiffUncomparedLinesTests {

    @Test func unequalLineCounts_noAssertion_bothSidesComplete() {
        let c = content(["o1", "o2"], ["n1", "n2", "n3", "n4"])
        let lines = DiffLineGenerator.uncomparedLines(content: c)
        #expect(lines == [
            DiffLine(type: .context, text: " o1", oldLineNumber: 1, newLineNumber: 1, newText: " n1"),
            DiffLine(type: .context, text: " o2", oldLineNumber: 2, newLineNumber: 2, newText: " n2"),
            DiffLine(type: .context, text: " n3", oldLineNumber: nil, newLineNumber: 3),
            DiffLine(type: .context, text: " n4", oldLineNumber: nil, newLineNumber: 4),
        ])
        let displayLines = lines.map { DisplayLine.diff($0) }

        let sbs = DiffRowBuilder.build(displayLines: displayLines, changes: [], layout: .sideBySide)
        #expect(sbs.map { displayed($0.left, displayLines) } == [" o1", " o2", nil, nil])
        #expect(sbs[2].left?.kind == .filler && sbs[3].left?.kind == .filler)
        #expect(sbs.map { displayed($0.right, displayLines) } == [" n1", " n2", " n3", " n4"])
        #expect(sbs.allSatisfy { [$0.left, $0.right].allSatisfy { $0?.kind == .filler || $0?.kind == .line(.context) } })

        let inline = DiffRowBuilder.build(displayLines: displayLines, changes: [], layout: .inline)
        #expect(inline.map { displayed($0.left, displayLines) } == [" n1", " n2", " n3", " n4"])
    }

    @Test func longerOriginal_rightPaddedWithFillers_inlineShowsNewOnly() {
        let lines = DiffLineGenerator.uncomparedLines(content: content(["o1", "o2", "o3"], ["n1"]))
        let displayLines = lines.map { DisplayLine.diff($0) }
        let sbs = DiffRowBuilder.build(displayLines: displayLines, changes: [], layout: .sideBySide)
        #expect(sbs.map { displayed($0.left, displayLines) } == [" o1", " o2", " o3"])
        #expect(sbs.map { $0.right?.kind } == [.line(.context), .filler, .filler])
        let inline = DiffRowBuilder.build(displayLines: displayLines, changes: [], layout: .inline)
        #expect(inline.map { displayed($0.left, displayLines) } == [" n1"])
    }
}

@MainActor
struct DiffViewDisplayTextTests {

    private func lineCell(_ index: Int) -> DiffCell {
        DiffCell(displayIndex: index, lineIndex: index, kind: .line(.context), innerRanges: [], isWholeLineChange: false)
    }

    @Test func breakCharacters_neverAddParagraphs() {
        let texts = [" a\rb", " a\u{2028}b", " a\u{2029}b", " a\u{0085}b", " plain"]
        let displayLines = texts.enumerated().map {
            DisplayLine.diff(DiffLine(type: .context, text: $0.element, oldLineNumber: $0.offset + 1, newLineNumber: $0.offset + 1))
        }
        let cells: [DiffCell?] = texts.indices.map { lineCell($0) }
        let string = DiffView.attributedString(cells: cells, displayLines: displayLines, bannerMessage: nil).string
        let units = Array(string.utf16)
        #expect(units.filter { $0 == 0x0A }.count == cells.count - 1)
        for separator: UInt16 in [0x0D, 0x2028, 0x2029, 0x85] {
            #expect(!units.contains(separator))
        }
        #expect(string.components(separatedBy: "\n") == [" a\u{240D}b", " a\u{21B5}b", " a\u{00B6}b", " a\u{2424}b", " plain"])
    }

    @Test func truncation_byUTF16_innerRangesClampedBeforeSuffix() {
        // 9_999 BMP + one emoji (2 units) straddling the limit + more text.
        let body = String(repeating: "x", count: DiffView.maxDisplayedLineLength - 2) + "\u{1F600}" + "tail"
        let text = "+" + body
        #expect(text.utf16.count > DiffView.maxDisplayedLineLength)
        let line = DiffLine(type: .addition, text: text, oldLineNumber: nil, newLineNumber: 1)

        let shown = DiffView.displayedText(line, side: .left)
        // Cut before the surrogate pair: never splits it.
        #expect(shown.contentLength == DiffView.maxDisplayedLineLength - 1)
        #expect(shown.text == String(text.utf16.prefix(DiffView.maxDisplayedLineLength - 1))! + DiffView.truncationSuffix)

        let cell = DiffCell(displayIndex: 0, lineIndex: 0, kind: .line(.addition),
                            innerRanges: [NSRange(location: 9_990, length: 50),
                                          NSRange(location: 10_005, length: 0),
                                          NSRange(location: 5, length: 0)],
                            isWholeLineChange: false)
        let clamped = DiffView.clampedToDisplayedText(cell, displayLines: [.diff(line)])
        #expect(clamped.innerRanges == [NSRange(location: 9_990, length: 9),
                                        NSRange(location: 5, length: 0)])

        let attributed = DiffView.attributedString(cells: [clamped], displayLines: [.diff(line)], bannerMessage: nil)
        let suffixStart = attributed.length - DiffView.truncationSuffix.utf16.count
        var effective = NSRange()
        let background = attributed.attribute(.backgroundColor, at: suffixStart, effectiveRange: &effective)
        #expect(background == nil)
        #expect(attributed.attribute(.backgroundColor, at: 9_990, effectiveRange: nil) != nil)
    }
}

struct CancellationAwareTimeoutTests {

    @Test func cancelledTask_isInvalid() async {
        let task = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return CancellationAwareTimeout(base: InfiniteTimeout.instance).isValid()
        }
        task.cancel()
        #expect(await task.value == false)
    }

    @Test func runningTask_followsBase() async {
        let valid = await Task { CancellationAwareTimeout(base: InfiniteTimeout.instance).isValid() }.value
        #expect(valid)
        struct Expired: DiffTimeout { func isValid() -> Bool { false } }
        let expired = await Task { CancellationAwareTimeout(base: Expired()).isValid() }.value
        #expect(!expired)
    }

    @Test func cancelledTask_stopsDiffComputationEarly() async {
        let old = (0..<2_000).map { "line \($0 * 7 % 13)" }
        let new = (0..<2_000).map { "line \($0 * 5 % 11)" }
        let task = Task { () -> LinesDiff in
            while !Task.isCancelled { await Task.yield() }
            return DefaultLinesDiffComputer().computeDiff(
                originalLines: old, modifiedLines: new, options: LinesDiffOptions(maxComputationTimeMs: 0),
                wrapTimeout: { CancellationAwareTimeout(base: $0) })
        }
        task.cancel()
        #expect(await task.value.hitTimeout)
    }
}
