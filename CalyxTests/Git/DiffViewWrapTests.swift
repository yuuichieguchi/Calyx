// DiffViewWrapTests.swift
// CalyxTests
//
// Word wrap in the diff view (plan Addendum 2, §3/§4/§7/§8): measured row
// frames, side-by-side block alignment via paddings, virtual tail padding,
// wrap toggle, width-change realign, inline / banner / zero-size cases.
//
// Fixtures (side-by-side, no filler before the change, so modified line N
// sits at row N-1 until the change):
// F1: 60 lines, line 30 replaced 1->1 by a 300-char modified line.
// F2: 60 lines, line 30 replaced 1->2 by two 300-char lines (block of 2 rows:
//     del/add, filler/add).
// F3: 10 lines + one 300-char line inserted at end of file.
// F4: 60 short lines, line 30 replaced 1->1 by a short line.

import AppKit
import Foundation
import Testing
@testable import Calyx

/// 300 characters: 100 x "xx " (breakable by .byWordWrapping).
private let longText = String(repeating: "xx ", count: 100)

private func header(old: Int, new: Int) -> String {
    "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,\(old) +1,\(new) @@\n"
}

/// F1 (`added == [longText]`), F2 (`[longText, longText]`), F4 (short).
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

/// F5: line 30 replaced 1->1 by a deeply indented long line (indent leaves
/// no room in a narrow pane, so it is zeroed by the no-room rule).
private func makeF5() -> FileDiff {
    DiffParser.parse(makeReplacementRaw(added: [String(repeating: " ", count: 40) + longText]), path: "w.txt")
}

/// `lines` context lines + one 300-char line inserted at end of file.
private func makeEOFInsertion(lines: Int) -> FileDiff {
    var out = header(old: lines, new: lines + 1)
    for n in 1...lines { out += " line \(n)\n" }
    out += "+\(longText)\n"
    return DiffParser.parse(out, path: "w.txt")
}

/// 40 lines; rows 10 and 30 contain "needle".
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
        pane.textView.ensureRowFrames()
    }

    private func docHeight(_ pane: DiffPaneView) -> CGFloat {
        frames(pane).last?.maxY ?? 0
    }

    /// Counts NSTextStorage.didProcessEditingNotification per storage.
    private final class EditCounter {
        var left = 0
        var right = 0
        private var tokens: [NSObjectProtocol] = []
        init(left: NSTextStorage, right: NSTextStorage) {
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: left, queue: nil
            ) { [unowned self] _ in self.left += 1 })
            tokens.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: right, queue: nil
            ) { [unowned self] _ in self.right += 1 })
        }
        func stop() { tokens.forEach(NotificationCenter.default.removeObserver); tokens = [] }
    }

    // MARK: Fixture sanity

    @Test func fixtureSanity() {
        #expect(makeF1().changes.map(\.modified.startLineNumber) == [30])
        #expect(makeF2().newLineCount == 61)
        #expect(makeF3().newLineCount == 11)
        #expect(longText.count == 300)
    }

    // MARK: Wrapping

    @Test func longLine_wrapsWhenOn() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            let row = try #require(view.row(forModifiedLine: 30))
            #expect(row == 29)
            let right = view.rightPaneForTesting
            let f = frames(right)
            #expect(f[row].height > DiffMetrics.rowHeight, "the 300-char row must wrap at 600 pt")
            #expect(f[row - 1].height == DiffMetrics.rowHeight, "a short row must not wrap")
            #expect(right.textView.frame.width <= right.scrollView.contentSize.width + 1)
            #expect(right.scrollView.hasHorizontalScroller == false)
            let width = try #require(right.textView.textContainer).containerSize.width
            #expect(width < .greatestFiniteMagnitude)
            #expect(width > 0)
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
            let padding = view.leftPaneForTesting.textView.appliedPadding
            #expect(Array(padding.keys) == [row])
            let pad = try #require(padding[row])
            #expect(abs(pad - (right[row].height - DiffMetrics.rowHeight)) <= 0.5)
            #expect(abs(left[row].height - right[row].height) <= 0.5)
            #expect(view.rightPaneForTesting.textView.appliedPadding.isEmpty)
        }
    }

    @Test func panes_rowFramesAligned_multiRowBlock() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF2())
            let row = try #require(view.row(forModifiedLine: 30))
            #expect(row == 29)
            // 1 -> 2 replacement: rows 29 (del/add) and 30 (filler/add) form one block.
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
            // The shorter (left) side pads the block's last row only.
            #expect(Array(leftPane.textView.appliedPadding.keys) == [30])
            #expect(rightPane.textView.appliedPadding.isEmpty)
        }
    }

    @Test func eofInsertion_padsVirtually() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF3())
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            #expect(leftPane.textView.tailPadding > 0)
            #expect(rightPane.textView.tailPadding == 0)
            #expect(abs(docHeight(leftPane) - docHeight(rightPane)) <= 0.5)
            let storage = try #require(leftPane.textView.textStorage)
            #expect(storage.length > 0)
            let style = storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) as? NSParagraphStyle
            #expect((style?.paragraphSpacing ?? 0) == 0, "the final pad is virtual, not an attribute")
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
            // Independent of the frame height: one label in the first fragment.
            let tall = CGRect(x: 0, y: 100, width: 50, height: 3 * DiffMetrics.rowHeight)
            let y2 = DiffGutterGeometry.labelY(rowFrame: tall, rowHeight: DiffMetrics.rowHeight, fontHeight: fontHeight)
            #expect(abs(y2 - (100 + (DiffMetrics.rowHeight - fontHeight) / 2)) <= 0.001)
        }
    }

    // MARK: Toggle

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
            #expect(right.textView.appliedPadding.isEmpty)
            #expect(view.leftPaneForTesting.textView.appliedPadding.isEmpty)
            #expect(view.leftPaneForTesting.textView.tailPadding == 0)
            #expect(try #require(right.textView.textContainer).containerSize.width == .greatestFiniteMagnitude)
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

    // MARK: Width change

    @Test func widthChange_realignsOnce() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF1())
            let row = try #require(view.row(forModifiedLine: 30))
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            let before = frames(rightPane)[row].height
            let counter = EditCounter(left: try #require(leftPane.textView.textStorage),
                                      right: try #require(rightPane.textView.textStorage))
            defer { counter.stop() }

            view.setFrameSize(NSSize(width: 400, height: 400))
            try await settle(view)

            #expect(view.currentLayout == .sideBySide)
            #expect(frames(rightPane)[row].height > before)
            #expect(abs(docHeight(leftPane) - docHeight(rightPane)) <= 0.5)
            #expect(counter.left >= 1, "the left pad changes: at least one edit batch")
            #expect(counter.right == 0, "the right side needs no pad: no edit")
        }
    }

    @Test func wrapOn_shortLines_noEdits_onRealign() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF4())
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            let range = view.visibleRowRange
            let counter = EditCounter(left: try #require(leftPane.textView.textStorage),
                                      right: try #require(rightPane.textView.textStorage))
            defer { counter.stop() }

            view.setFrameSize(NSSize(width: 400, height: 400))
            try await settle(view)

            #expect(counter.left == 0)
            #expect(counter.right == 0)
            #expect(view.visibleRowRange == range)
            #expect(leftPane.textView.appliedPadding.isEmpty)
            #expect(rightPane.textView.appliedPadding.isEmpty)
        }
    }

    // MARK: Inline / banner / zero size

    @Test func inline_noAlignmentPass() async throws {
        try await withIsolatedSettings {
            DiffLayoutSettings.preference = .inline
            let view = try await makeView(makeF1())
            #expect(view.currentLayout == .inline)
            let row = try #require(view.row(forModifiedLine: 30))
            let inline = view.inlinePaneForTesting
            #expect(inline.textView.appliedPadding.isEmpty)
            #expect(inline.textView.tailPadding == 0)
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
            #expect(try #require(right.textView.textContainer).containerSize.width == .greatestFiniteMagnitude)

            view.setFrameSize(size)
            try await settle(view)
            let width = try #require(right.textView.textContainer).containerSize.width
            #expect(width < .greatestFiniteMagnitude)
            #expect(width > 0)
        }
    }

    // MARK: Indent zeroing before measuring

    /// Indent zeroing changes wrap counts, so it must run before the heights
    /// the pads are computed from: one realign yields aligned blocks.
    @Test func narrowView_deepIndentZeroed_blocksAlignedInOnePass() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeF5(), width: 300)
            #expect(view.currentLayout == .sideBySide)
            let leftPane = view.leftPaneForTesting
            let rightPane = view.rightPaneForTesting
            #expect(rightPane.wrappingColumns < 42, "the 40-space indent must leave no room")
            let row = try #require(view.row(forModifiedLine: 30))
            let left = frames(leftPane)
            let right = frames(rightPane)
            #expect(right[row].height > DiffMetrics.rowHeight)
            #expect(abs(left[row].height - right[row].height) <= 0.5)
            #expect(abs(docHeight(leftPane) - docHeight(rightPane)) <= 0.5)
        }
    }

    // MARK: Legacy scroller

    /// A legacy (space-taking) vertical scroller that appears only once the
    /// left pane's tail pad makes it taller than the clip must re-wrap the
    /// pane at the narrower width.
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
            #expect(leftPane.textView.tailPadding > 0)
            #expect(leftPane.textView.frame.height > leftPane.scrollView.contentView.bounds.height)
            #expect(leftPane.scrollView.verticalScroller?.isHidden == false)
            for pane in [leftPane, view.rightPaneForTesting] {
                let ruler = pane.scrollView.verticalRulerView?.requiredThickness ?? 0
                let viewport = pane.scrollView.contentSize.width - ruler
                let expected = max(viewport - 2 * DiffMetrics.textInset.width, 8 * DiffMetrics.columnWidth)
                let width = try #require(pane.textView.textContainer).containerSize.width
                #expect(abs(width - expected) <= 0.5, "container \(width) vs wrap width \(expected)")
            }
        }
    }

    // MARK: Find bar

    /// The find bar works on the explicit TextKit 1 network.
    @Test func findNext_onOwnedTextKit1Stack_selectsNeedle() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(makeNeedleDiff())
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer {
                window.orderOut(nil)
                window.close()
            }
            window.contentView = view
            try await settle(view)
            let textView = view.rightPaneForTesting.textView
            let storage = try #require(textView.textStorage)
            let layoutManager = try #require(textView.layoutManager)
            #expect(storage.layoutManagers.contains { $0 === layoutManager })
            #expect(layoutManager.textContainers.contains { $0 === textView.container })
            #expect(textView.textLayoutManager == nil, "TextKit 1")
            #expect(window.makeFirstResponder(textView))
            textView.setSelectedRange(NSRange(location: 0, length: 0))

            let pasteboard = NSPasteboard(name: .find)
            pasteboard.clearContents()
            pasteboard.setString("needle", forType: .string)
            let item = NSMenuItem(title: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)),
                                  keyEquivalent: "")
            item.tag = NSTextFinder.Action.nextMatch.rawValue
            textView.performFindPanelAction(item)
            try await drainMainQueue()

            let expected = (storage.string as NSString).range(of: "needle")
            #expect(expected.location != NSNotFound)
            #expect(textView.selectedRange() == expected)
        }
    }

    /// Regression: a clip-view frame change arrives inside
    /// `NSScrollView.tile()` (mid layout pass). Re-marking layout from it
    /// looped the window's layout pass (NSGenericException "more Update
    /// Constraints in Window passes than there are views"). Window-hosted
    /// views across wrap toggles and resizes must settle. (In isolation this
    /// does not trip the loop; the original reproducer was DiffViewRevealTests
    /// + DiffViewWrapTests in one launch.)
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

    // MARK: Width change keeps the viewport (VS Code viewport-start line + delta)

    /// 400 lines with long (wrapping) lines every 10 lines; line 200
    /// replaced by a long line.
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
            // The modified line 200 (its addition row; in side-by-side the
            // row shared by the deletion and the addition).
            let addCells = view.rightPaneForTesting.cells
            let row = try #require((layout == .inline ? panes[0].cells : addCells).firstIndex {
                if case .line(.addition)? = $0?.kind { return true }
                return false
            })
            // The modified side anchors the viewport; panes share one y.
            let reference = panes[panes.count - 1]
            let natural0 = reference.textView.naturalHeights()[row]
            if wrap { #expect(natural0 > DiffMetrics.rowHeight * 1.5, "line 200 wraps at 900 pt") }
            // Viewport top inside line 200: half way down when wrapped, 7 pt otherwise.
            let fraction: CGFloat = wrap ? 0.5 : 7 / natural0
            for pane in panes {
                pane.scroll(toY: pane.textView.ensureRowFrames()[row].minY + fraction * natural0)
            }
            try await settle(view)
            #expect(reference.firstVisibleRow == row)

            for width in [600.0, 1200.0, 900.0] {
                window.setContentSize(NSSize(width: width, height: 400))
                window.layoutIfNeeded()
                try await settle(view)
                for pane in panes {
                    #expect(pane.firstVisibleRow == row, "width \(width): first visible row")
                    #expect(abs(viewportTop(pane) - viewportTop(reference)) <= 0.5, "width \(width): panes share y")
                }
                let frame = reference.textView.ensureRowFrames()[row]
                let natural = reference.textView.naturalHeights()[row]
                let offset = viewportTop(reference) - frame.minY
                #expect(abs(offset - fraction * natural) <= 1,
                        "width \(width): offset \(offset) vs \(fraction * natural) (natural \(natural))")
            }
        }
    }

    // MARK: A scroll during a pending width change supersedes the anchor

    /// Window-hosted side-by-side wrapped view of `makeAnchorDiff()` at
    /// 900 pt, its viewport top at the modified line 50.
    private func makeAnchoredWindow() async throws -> (NSWindow, DiffView) {
        let view = DiffView(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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

    /// Starts a width change: the panes re-wrap (anchor captured and
    /// restored) and the realign stays queued on the main queue.
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
            let frame = pane.textView.ensureRowFrames()[row200]
            #expect(frame.minY >= visible.minY && frame.minY < visible.maxY,
                    "the revealed change stays visible: \(frame) in \(visible)")
        }
    }
}

} // extension DiffViewWindowedSuites
