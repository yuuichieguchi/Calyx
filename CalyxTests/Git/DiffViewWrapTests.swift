import AppKit
import Foundation
import Testing
@testable import Calyx

private let longText = String(repeating: "xx ", count: 100)

private func header(old: Int, new: Int) -> String {
    "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,\(old) +1,\(new) @@\n"
}

private func makeReplacementRaw(added: [String]) -> String {
    var out = header(old: 60, new: 59 + added.count)
    for n in 1...60 {
        if n == 30 {
            out += "-line 30\n"
            for a in added { out += "+\(a)\n" }
        } else {
            out += " line \(n)\n"
        }
    }
    return out
}

private func makeF1() -> FileDiff { DiffParser.parse(makeReplacementRaw(added: [longText]), path: "w.txt") }
private func makeF2() -> FileDiff { DiffParser.parse(makeReplacementRaw(added: [longText, longText]), path: "w.txt") }
private func makeF4() -> FileDiff { DiffParser.parse(makeReplacementRaw(added: ["short line"]), path: "w.txt") }

private func makeF5() -> FileDiff {
    DiffParser.parse(makeReplacementRaw(added: [String(repeating: " ", count: 40) + longText]), path: "w.txt")
}

private func makeEOFInsertion(lines: Int) -> FileDiff {
    var out = header(old: lines, new: lines + 1)
    for n in 1...lines { out += " line \(n)\n" }
    out += "+\(longText)\n"
    return DiffParser.parse(out, path: "w.txt")
}

private func makeNeedleDiff() -> FileDiff {
    var out = header(old: 40, new: 40)
    for n in 1...40 { out += n == 10 || n == 30 ? " needle \(n)\n" : " line \(n)\n" }
    return DiffParser.parse(out, path: "w.txt")
}

private func makeF3() -> FileDiff {
    var out = header(old: 10, new: 11)
    for n in 1...10 { out += " line \(n)\n" }
    out += "+\(longText)\n"
    return DiffParser.parse(out, path: "w.txt")
}

extension DiffViewWindowedSuites {

@MainActor
@Suite(.serialized)
struct DiffViewWrapTests {

    private let suiteName = "com.calyx.tests.DiffViewWrapTests"
    private let size = NSSize(width: 600, height: 400)

    private func withIsolatedSettings(_ body: () async throws -> Void) async rethrows {
        DiffLayoutSettings._testUseSuite(named: suiteName)
        defer { DiffLayoutSettings._testTeardownSuite(named: suiteName) }
        DiffLayoutSettings.preference = .sideBySide
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        DiffLayoutSettings.wordWrap = true
        try await body()
    }

    private func makeView(_ diff: FileDiff, width: CGFloat = 600) async throws -> DiffView {
        let view = DiffView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        view.display(diff: diff)
        try await settle(view)
        return view
    }

    private func drainMainQueue() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<2 {
            view.layoutSubtreeIfNeeded()
            try await drainMainQueue()
        }
    }

    private func frames(_ pane: DiffPaneView) -> [CGRect] {
        let geometry = pane.linesView.geometry
        return (0..<geometry.rowCount).map {
            CGRect(x: 0, y: geometry.rowTop($0), width: pane.linesView.bounds.width, height: geometry.rowHeight($0))
        }
    }

    private func docHeight(_ pane: DiffPaneView) -> CGFloat {
        pane.linesView.geometry.documentHeight
    }

    private func pads(_ pane: DiffPaneView) -> [Int: CGFloat] {
        var result: [Int: CGFloat] = [:]
        for (row, pad) in pane.linesView.geometry.pads.enumerated() where pad > 0 { result[row] = pad }
        return result
    }

    private func lastRowPad(_ pane: DiffPaneView) -> CGFloat {
        pane.linesView.geometry.pads.last ?? 0
    }

    @Test func fixtureSanity() {
        #expect(makeF1().changes.map(\.modified.startLineNumber) == [30])
        #expect(makeF2().newLineCount == 61)
        #expect(makeF3().newLineCount == 11)
        #expect(longText.count == 300)
    }

    @Test func longLine_wrapsWhenOn() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            let row = try #require(view.row(forModifiedLine: 30))
            #expect(row == 29)
            let right = view.rightPaneForTesting
            let f = frames(right)
            #expect(f[row].height > DiffMetrics.rowHeight, "the 300-char row must wrap at 600 pt")
            #expect(f[row - 1].height == DiffMetrics.rowHeight, "a short row must not wrap")
            #expect(right.linesView.frame.width <= right.scrollView.contentSize.width + 1)
            #expect(right.scrollView.hasHorizontalScroller == false)
            let column = try #require(right.linesView.wrappingColumn)
            #expect(column > 0)
        }
    }

    @Test func panes_rowFramesAligned_singletonBlocks() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            let row = try #require(view.row(forModifiedLine: 30))
            let left = frames(view.leftPaneForTesting)
            let right = frames(view.rightPaneForTesting)
            #expect(left.count == 60)
            #expect(left.count == right.count)
            for i in 0..<min(left.count, right.count) {
                #expect(abs(left[i].minY - right[i].minY) <= 0.5, "row \(i) minY must align")
            }
            let padding = pads(view.leftPaneForTesting)
            #expect(Array(padding.keys) == [row])
            let pad = try #require(padding[row])
            #expect(abs(pad - (right[row].height - DiffMetrics.rowHeight)) <= 0.5)
            #expect(abs(left[row].height - right[row].height) <= 0.5)
            #expect(pads(view.rightPaneForTesting).isEmpty)
        }
    }

    @Test func panes_rowFramesAligned_multiRowBlock() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF2())
            let row = try #require(view.row(forModifiedLine: 30))
            #expect(row == 29)
            #expect(view.blocksForTesting.contains(29..<31))
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            #expect(abs(docHeight(leftPane) - docHeight(rightPane)) <= 0.5)
            let left = frames(leftPane)
            let right = frames(rightPane)
            #expect(left.count == right.count)
            for block in view.blocksForTesting {
                #expect(abs(left[block.lowerBound].minY - right[block.lowerBound].minY) <= 0.5,
                        "block \(block) start must align")
            }
            #expect(Array(pads(leftPane).keys) == [30])
            #expect(pads(rightPane).isEmpty)
        }
    }

    @Test func eofInsertion_padsLastRowInGeometry() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF3())
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            #expect(lastRowPad(leftPane) > 0)
            #expect(lastRowPad(rightPane) == 0)
            #expect(abs(docHeight(leftPane) - docHeight(rightPane)) <= 0.5)
            let geometry = leftPane.linesView.geometry
            let last = geometry.rowCount - 1
            #expect(geometry.documentHeight == geometry.rowTop(last) + geometry.contentHeight(last) + lastRowPad(leftPane),
                    "the final pad is part of the document height")
        }
    }

    @Test func continuationRows_drawNoNumber() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            let row = try #require(view.row(forModifiedLine: 30))
            let frame = frames(view.rightPaneForTesting)[row]
            #expect(frame.height >= 2 * DiffMetrics.rowHeight)
            let fontHeight: CGFloat = 12
            let y = DiffGutterGeometry.labelY(rowFrame: frame, rowHeight: DiffMetrics.rowHeight, fontHeight: fontHeight)
            #expect(abs(y - (frame.minY + (DiffMetrics.rowHeight - fontHeight) / 2)) <= 0.001)
            let tall = CGRect(x: 0, y: 100, width: 50, height: 3 * DiffMetrics.rowHeight)
            let y2 = DiffGutterGeometry.labelY(rowFrame: tall, rowHeight: DiffMetrics.rowHeight, fontHeight: fontHeight)
            #expect(abs(y2 - (100 + (DiffMetrics.rowHeight - fontHeight) / 2)) <= 0.001)
        }
    }

    @Test func toggleOff_restoresArithmeticFrames() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            DiffLayoutSettings.wordWrap = false
            try await settle(view)
            let right = view.rightPaneForTesting
            let f = frames(right)
            #expect(f.count == 60)
            for (i, frame) in f.enumerated() {
                let expectedY = DiffMetrics.textInset.height + CGFloat(i) * DiffMetrics.rowHeight
                #expect(abs(frame.minY - expectedY) <= 0.5, "row \(i) minY")
                #expect(abs(frame.height - DiffMetrics.rowHeight) <= 0.5, "row \(i) height")
            }
            #expect(right.scrollView.hasHorizontalScroller == true)
            #expect(right.wordWrap == false)
            #expect(pads(right).isEmpty)
            #expect(pads(view.leftPaneForTesting).isEmpty)
            #expect(lastRowPad(view.leftPaneForTesting) == 0)
            #expect(right.linesView.wrappingColumn == nil)
        }
    }

    @Test func toggle_preservesScrollAnchorAndCaret() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            view.goToDiff(.next)
            try await settle(view)
            let anchor = view.visibleRowRange.lowerBound
            let caret = view.currentModifiedLine()
            #expect(caret != nil)

            DiffLayoutSettings.wordWrap = false
            try await settle(view)
            DiffLayoutSettings.wordWrap = true
            try await settle(view)

            #expect(abs(view.visibleRowRange.lowerBound - anchor) <= 1)
            #expect(view.currentModifiedLine() == caret)
        }
    }

    @Test func widthChange_realignsOnce() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            let row = try #require(view.row(forModifiedLine: 30))
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            let before = frames(rightPane)[row].height
            let leftPadBefore = pads(leftPane)

            view.setFrameSize(NSSize(width: 400, height: 400))
            try await settle(view)

            #expect(view.currentLayout == .sideBySide)
            #expect(frames(rightPane)[row].height > before)
            #expect(abs(docHeight(leftPane) - docHeight(rightPane)) <= 0.5)
            #expect(pads(leftPane) != leftPadBefore, "the left pad changes")
            #expect(pads(leftPane)[row] != nil)
            #expect(pads(rightPane).isEmpty, "the right side needs no pad")
        }
    }

    @Test func wrapOn_shortLines_noEdits_onRealign() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF4())
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            let range = view.visibleRowRange
            let leftBefore = leftPane.linesView.geometry
            let rightBefore = rightPane.linesView.geometry

            view.setFrameSize(NSSize(width: 400, height: 400))
            try await settle(view)

            #expect(leftPane.linesView.geometry == leftBefore, "no row re-wraps and no pad changes")
            #expect(rightPane.linesView.geometry == rightBefore, "no row re-wraps and no pad changes")
            #expect(view.visibleRowRange == range)
            #expect(pads(leftPane).isEmpty)
            #expect(pads(rightPane).isEmpty)
        }
    }

    @Test func inline_noAlignmentPass() async throws {
        try await withIsolatedSettings {
            DiffLayoutSettings.preference = .inline
            let view = try await makeView(makeF1())
            #expect(view.currentLayout == .inline)
            let row = try #require(view.row(forModifiedLine: 30))
            let inline = view.inlinePaneForTesting
            #expect(pads(inline).isEmpty)
            #expect(lastRowPad(inline) == 0)
            #expect(frames(inline)[row].height > DiffMetrics.rowHeight)
        }
    }

    @Test func banner_isOwnBlock() async throws {
        try await withIsolatedSettings {
            let content = DiffContent(oldLines: ["o1", "o2", "o3", "o4", "o5"],
                                      newLines: ["n1", "n2", "n3", "n4", "n5"],
                                      isBinary: false,
                                      oldMissingTrailingNewline: false, newMissingTrailingNewline: false)
            let diff = FileDiff(path: "w.txt",
                                lines: DiffLineGenerator.uncomparedLines(content: content),
                                isBinary: false, isTruncated: false,
                                oldLineCount: 5, newLineCount: 5, isTooLarge: true)
            let view = try await makeView(diff)
            let rows = frames(view.rightPaneForTesting).count
            #expect(rows == 6, "5 line rows + banner")
            #expect(view.blocksForTesting.last == (rows - 1)..<rows)
            #expect(view.blocksForTesting.count == 6)
        }
    }

    @Test func zeroSizeDisplay_wrapOn_noWrapUntilSized() async throws {
        try await withIsolatedSettings {
            let view = DiffView(frame: .zero)
            view.display(diff: makeF1())
            try await settle(view)
            let right = view.rightPaneForTesting
            #expect(right.linesView.wrappingColumn == nil)

            view.setFrameSize(size)
            try await settle(view)
            let column = try #require(right.linesView.wrappingColumn)
            #expect(column > 0)
        }
    }

    @Test(arguments: [CGFloat(0), 3])
    func wrappingColumn_textAreaWithNoRoom_clampsToOneColumn(textAreaWidth: CGFloat) {
        for style in [NSScroller.Style.legacy, .overlay] {
            for reserves in [false, true] {
                #expect(DiffPaneView.wrappingColumn(textAreaWidth: textAreaWidth, reservesLegacyScroller: reserves,
                                                    scrollerStyle: style) == 1,
                        "width \(textAreaWidth), style \(style.rawValue), reserves \(reserves)")
            }
        }
    }

    @Test(arguments: [CGFloat(300), 240])
    func narrowSideBySide_panesKeepMinimumWidthAndKeepWrapping(width: CGFloat) async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF5(), width: width)
            #expect(view.currentLayout == .sideBySide)
            for pane in [view.leftPaneForTesting, view.rightPaneForTesting] {
                #expect(pane.frame.width >= DiffView.splitViewMinPaneWidth, "pane \(pane.frame)")
                let target = try #require(pane.targetWrappingColumn, "word wrap stays on in a narrow pane \(pane.frame)")
                #expect(target >= 1)
                #expect(pane.linesView.wrappingColumn == target)
            }
            #expect(abs(view.leftPaneForTesting.frame.width - view.rightPaneForTesting.frame.width) <= 1)
        }
    }

    @Test func narrowView_deepIndentZeroed_blocksAlignedInOnePass() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF5(), width: 300)
            #expect(view.currentLayout == .sideBySide)
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            #expect(try #require(rightPane.linesView.wrappingColumn) < 42, "the 40-space indent must leave no room")
            let row = try #require(view.row(forModifiedLine: 30))
            #expect(rightPane.linesView.projections[row]?.wrappedTextIndentLength == 0)
            let left = frames(leftPane)
            let right = frames(rightPane)
            #expect(right[row].height > DiffMetrics.rowHeight)
            #expect(abs(left[row].height - right[row].height) <= 0.5)
            #expect(abs(docHeight(leftPane) - docHeight(rightPane)) <= 0.5)
        }
    }

    @Test func legacyScrollerAtTheToggleThreshold_settlesInOnePass() async throws {
        try await withIsolatedSettings {
            DiffLayoutSettings.preference = .inline
            let view = DiffView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            defer {
                window.orderOut(nil)
                window.close()
            }
            window.contentView = view
            view.autoresizingMask = [.width, .height]
            let pane = view.inlinePaneForTesting
            pane.scrollView.scrollerStyle = .legacy
            let rows = Int((400 - 2 * DiffMetrics.textInset.height) / DiffMetrics.rowHeight) - 2
            var raw = header(old: rows, new: rows)
            for n in 1...rows { raw += n == 3 ? " \(n) " + String(repeating: "word ", count: 24) + "\n" : " line \(n)\n" }
            view.display(diff: DiffParser.parse(raw, path: "w.txt"))
            window.layoutIfNeeded()
            try await settle(view)
            @MainActor func expectedColumn() -> Int {
                let scrollView = pane.scrollView
                let clip = scrollView.contentView
                return DiffPaneView.wrappingColumn(textAreaWidth: clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right,
                                                   reservesLegacyScroller: scrollView.verticalScroller?.isHidden ?? true,
                                                   scrollerStyle: .legacy)
            }
            for width in [520.0, 610.0, 480.0, 700.0] {
                let before = view.geometryPassCountForTesting
                window.setContentSize(NSSize(width: width, height: 400))
                window.layoutIfNeeded()
                let passes = view.geometryPassCountForTesting - before
                #expect(passes <= 1, "width \(width): \(passes) re-wrap passes")
                #expect(pane.linesView.wrappingColumn == expectedColumn(),
                        "width \(width): column \(String(describing: pane.linesView.wrappingColumn)) vs \(expectedColumn())")
                let settled = view.geometryPassCountForTesting
                window.layoutIfNeeded()
                try await settle(view)
                #expect(view.geometryPassCountForTesting == settled, "width \(width): nothing re-wraps after the pass")
                #expect(pane.linesView.wrappingColumn == expectedColumn())
            }
        }
    }

    @Test func legacyScrollerAppearingAfterPad_rewrapsAtNewWidth() async throws {
        try await withIsolatedSettings {
            let lines = Int((400 - 4 * DiffMetrics.rowHeight) / DiffMetrics.rowHeight)
            let view = DiffView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            for pane in [view.leftPaneForTesting, view.rightPaneForTesting] {
                pane.scrollView.scrollerStyle = .legacy
            }
            view.display(diff: makeEOFInsertion(lines: lines))
            try await settle(view)
            let leftPane = view.leftPaneForTesting
            #expect(lastRowPad(leftPane) > 0)
            #expect(leftPane.linesView.frame.height > leftPane.scrollView.contentView.bounds.height)
            #expect(leftPane.scrollView.verticalScroller?.isHidden == false)
            for pane in [leftPane, view.rightPaneForTesting] {
                let clip = pane.scrollView.contentView
                let clipWidth = clip.bounds.width - clip.contentInsets.left - clip.contentInsets.right
                #expect(clip.contentInsets.left >= pane.lineNumberView.requiredThickness - 0.5, "the gutter is outside the text area")
                let expected = DiffPaneView.wrappingColumn(
                    textAreaWidth: clipWidth, reservesLegacyScroller: pane.scrollView.verticalScroller?.isHidden ?? true,
                    scrollerStyle: .legacy)
                let column = try #require(pane.linesView.wrappingColumn)
                #expect(column == expected, "wrapping column \(column) vs \(expected) for clip width \(clipWidth)")
            }
        }
    }

    @Test func findNext_onLinesView_selectsNeedle() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeNeedleDiff())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            defer {
                window.orderOut(nil)
                window.close()
            }
            window.contentView = view
            try await settle(view)
            let linesView = view.rightPaneForTesting.linesView
            #expect(window.makeFirstResponder(linesView))
            let expected = (linesView.string as NSString).range(of: "needle")
            #expect(expected.location != NSNotFound)
            linesView.setSelectedRange(expected)
            let useSelection = NSMenuItem(title: "Use Selection for Find",
                                          action: #selector(DiffPaneView.performFindPanelAction(_:)), keyEquivalent: "")
            useSelection.tag = NSTextFinder.Action.setSearchString.rawValue
            view.rightPaneForTesting.performFindPanelAction(useSelection)
            linesView.setSelectedRange(NSRange(location: 0, length: 0))

            let item = NSMenuItem(title: "Find Next", action: #selector(DiffPaneView.performFindPanelAction(_:)),
                                  keyEquivalent: "")
            item.tag = NSTextFinder.Action.nextMatch.rawValue
            view.rightPaneForTesting.performFindPanelAction(item)
            try await drainMainQueue()

            #expect(linesView.selectedRange() == expected)
        }
    }

    @Test func windowHosted_wrapToggleAndResize_layoutSettles() async throws {
        try await withIsolatedSettings {
            var raw = header(old: 400, new: 401)
            for n in 1...400 {
                if n % 40 == 0 { raw += "-line \(n)\n+\(longText)\n+\(longText)\n" } else { raw += " line \(n)\n" }
            }
            let diff = DiffParser.parse(raw, path: "w.txt")
            var windows: [NSWindow] = []
            defer {
                for window in windows {
                    window.orderOut(nil)
                    window.close()
                }
            }
            for legacy in [false, true] {
                let view = DiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
                let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.animationBehavior = .none
                window.contentView = view
                windows.append(window)
                if legacy {
                    for pane in [view.leftPaneForTesting, view.rightPaneForTesting, view.inlinePaneForTesting] {
                        pane.scrollView.scrollerStyle = .legacy
                    }
                }
                view.display(diff: diff)
                window.layoutIfNeeded()
                try await settle(view)
            }
            for wrap in [false, true, false, true] {
                DiffLayoutSettings.wordWrap = wrap
                for window in windows { window.layoutIfNeeded() }
                try await drainMainQueue()
            }
            for width in [500.0, 900.0, 640.0] {
                for window in windows {
                    window.setContentSize(NSSize(width: width, height: 400))
                    window.layoutIfNeeded()
                }
                try await drainMainQueue()
            }
            for window in windows {
                let view = try #require(window.contentView as? DiffView)
                #expect(abs(docHeight(view.leftPaneForTesting) - docHeight(view.rightPaneForTesting)) <= 0.5)
            }
        }
    }

    private func makeAnchorDiff() -> FileDiff {
        var raw = header(old: 400, new: 400)
        for n in 1...400 {
            if n == 200 {
                raw += "-line 200\n+200 \(longText)\n"
            } else if n % 10 == 0 {
                raw += " \(n) \(longText)\n"
            } else {
                raw += " line \(n)\n"
            }
        }
        return DiffParser.parse(raw, path: "w.txt")
    }

    private func viewportTop(_ pane: DiffPaneView) -> CGFloat {
        pane.scrollView.documentVisibleRect.minY
    }

    @Test(arguments: [(DiffLayoutPreference.sideBySide, true), (.sideBySide, false), (.inline, true), (.inline, false)])
    func widthChange_keepsFirstVisibleLineAndOffset(layout: DiffLayoutPreference, wrap: Bool) async throws {
        try await withIsolatedSettings {
            DiffLayoutSettings.preference = layout
            DiffLayoutSettings.wordWrap = wrap
            let view = DiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            defer {
                window.orderOut(nil)
                window.close()
            }
            window.contentView = view
            view.display(diff: makeAnchorDiff())
            window.layoutIfNeeded()
            try await settle(view)

            let panes = layout == .inline
                ? [view.inlinePaneForTesting] : [view.leftPaneForTesting, view.rightPaneForTesting]
            let addCells = view.rightPaneForTesting.cells
            let row = try #require((layout == .inline ? panes[0].cells : addCells).firstIndex {
                if case .line(.addition)? = $0?.kind { return true }
                return false
            })
            let reference = panes[panes.count - 1]
            let geometry0 = reference.linesView.geometry
            if wrap { #expect(geometry0.contentHeight(row) > DiffMetrics.rowHeight * 1.5, "line 200 wraps at 900 pt") }
            let offsetInRow: CGFloat = wrap ? DiffMetrics.rowHeight + 3 : 7
            for pane in panes {
                pane.scroll(toY: pane.linesView.geometry.rowTop(row) + offsetInRow)
            }
            try await settle(view)
            #expect(reference.firstVisibleRow == row)

            for width in [600.0, 1200.0, 900.0] {
                let start = try #require(reference.viewportStart())
                #expect(start.row == row)
                window.setContentSize(NSSize(width: width, height: 400))
                window.layoutIfNeeded()
                try await settle(view)
                for pane in panes {
                    #expect(pane.firstVisibleRow == row, "width \(width): first visible row")
                    #expect(abs(viewportTop(pane) - viewportTop(reference)) <= 0.5, "width \(width): panes share y")
                }
                let expected = reference.scrollY(for: start)
                #expect(abs(viewportTop(reference) - expected) <= 0.5,
                        "width \(width): top \(viewportTop(reference)) vs \(expected) for \(start)")
            }
        }
    }

    private func makeAnchoredWindow() async throws -> (NSWindow, DiffView) {
        let view = DiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        view.display(diff: makeAnchorDiff())
        window.layoutIfNeeded()
        try await settle(view)
        let row50 = try #require(view.row(forModifiedLine: 50))
        for pane in [view.leftPaneForTesting, view.rightPaneForTesting] { pane.scrollToRow(row50) }
        try await settle(view)
        #expect(view.rightPaneForTesting.firstVisibleRow == row50)
        return (window, view)
    }

    private func startWidthChange(_ window: NSWindow) {
        window.setContentSize(NSSize(width: 600, height: 400))
        window.layoutIfNeeded()
    }

    @Test func widthChange_userScrollBeforeRealign_winsOverAnchor() async throws {
        try await withIsolatedSettings {
            let (window, view) = try await makeAnchoredWindow()
            defer {
                window.orderOut(nil)
                window.close()
            }
            startWidthChange(window)
            let row300 = try #require(view.row(forModifiedLine: 300))
            for pane in [view.leftPaneForTesting, view.rightPaneForTesting] { pane.scrollToRow(row300) }
            try await settle(view)
            #expect(view.rightPaneForTesting.firstVisibleRow == row300, "the user scroll stays")
            #expect(view.leftPaneForTesting.firstVisibleRow == row300)
        }
    }

    @Test func widthChange_goToDiffBeforeRealign_winsOverAnchor() async throws {
        try await withIsolatedSettings {
            let (window, view) = try await makeAnchoredWindow()
            defer {
                window.orderOut(nil)
                window.close()
            }
            startWidthChange(window)
            view.goToDiff(.next)
            try await settle(view)
            #expect(view.currentChangeIndex == 0)
            let row200 = try #require(view.row(forModifiedLine: 200))
            let pane = view.rightPaneForTesting
            let visible = pane.scrollView.documentVisibleRect
            let frame = frames(pane)[row200]
            #expect(frame.minY >= visible.minY && frame.minY < visible.maxY,
                    "the revealed change stays visible: \(frame) in \(visible)")
        }
    }
}

}
