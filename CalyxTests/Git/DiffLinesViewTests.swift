import AppKit
import Foundation
import Testing
@testable import Calyx

private let wordRowText = "foo_bar it's 3.14 かなカナ漢字ひらがな end"
private let clusterRowText = "a 𝑥y 😀b e\u{301}x 👍🏽 q 👨‍👩‍👧 z 漢字かな\tq end"

private func makeManyRowsRaw(_ count: Int) -> String {
    var out = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1,\(count) +1,\(count) @@\n"
    for n in 1...count { out += " row \(n) of many plain words\n" }
    return out
}

private func makeLongLinesRaw() -> String {
    var out = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1,40 +1,40 @@\n"
    for n in 1...40 {
        let long = String(repeating: "wide words \(n) ", count: 40)
        if n == 20 { out += "-old \(long)\n+new \(long)\n" } else { out += " \(long)\n" }
    }
    return out
}

private final class CursorInvalidationSpyWindow: NSWindow {
    var invalidatedViews: [NSView] = []

    override func invalidateCursorRects(for view: NSView) {
        invalidatedViews.append(view)
        super.invalidateCursorRects(for: view)
    }
}

private func makeLinesRaw() -> String {
    var out = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1,200 +1,200 @@\n"
    for n in 1...200 {
        switch n {
        case 10: out += " alpha needle omega \(n)\n"
        case 30: out += " \(clusterRowText) \(n)\n"
        case 50: out += " \(wordRowText) \(n)\n"
        case 150: out += " second needle here \(n)\n"
        case 100: out += "-old line \(n)\n+new line \(n)\n"
        default: out += " plain line \(n)\n"
        }
    }
    return out
}

extension DiffViewWindowedSuites {

@MainActor
@Suite(.serialized)
struct DiffLinesViewTests {

    private let suiteName = "com.calyx.tests.DiffLinesViewTests"

    private struct Hosted {
        let window: NSWindow
        let view: DiffView
        let pane: DiffPaneView
        let lines: DiffLinesView
        let pasteboard: NSPasteboard

        @MainActor func close() {
            pasteboard.releaseGlobally()
            window.orderOut(nil)
            window.close()
        }
    }

    private func withSettings(wordWrap: Bool = false, _ body: () async throws -> Void) async rethrows {
        DiffLayoutSettings._testUseSuite(named: suiteName)
        defer { DiffLayoutSettings._testTeardownSuite(named: suiteName) }
        DiffLayoutSettings.preference = .inline
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        DiffLayoutSettings.wordWrap = wordWrap
        try await body()
    }

    private func drain() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try await drain()
        }
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { sub -> [T] in
            ((sub as? T).map { [$0] } ?? []) + descendants(of: sub, type)
        }
    }

    private func makeHosted(raw: String = makeLinesRaw(),
                            width: CGFloat = 800,
                            configure: (DiffView, FileDiff) -> Void = { _, _ in },
                            makeWindow: (NSRect) -> NSWindow = { rect in
                                NSWindow(contentRect: rect, styleMask: [.titled, .resizable],
                                         backing: .buffered, defer: false)
                            }) async throws -> Hosted {
        let window = makeWindow(NSRect(x: 100, y: 100, width: width, height: 400))
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = DiffView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFront(nil)
        let diff = DiffParser.parse(raw, path: "l.txt")
        configure(view, diff)
        view.display(diff: diff)
        try await settle(window)
        let pane = view.inlinePaneForTesting
        let lines = pane.linesView
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("calyx.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        lines.pasteboard = pasteboard
        pane.scroll(toY: 0)
        try await settle(window)
        return Hosted(window: window, view: view, pane: pane, lines: lines, pasteboard: pasteboard)
    }

    private func rowRanges(_ string: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var location = 0
        for row in string.components(separatedBy: "\n") {
            let length = row.utf16.count
            ranges.append(NSRange(location: location, length: length))
            location += length + 1
        }
        return ranges
    }

    private func range(of token: String, in string: String) throws -> NSRange {
        let found = (string as NSString).range(of: token)
        try #require(found.location != NSNotFound, "\(token) must be in the pane text")
        return found
    }

    private func row(containing location: Int, _ ranges: [NSRange]) -> Int? {
        ranges.firstIndex { location >= $0.location && location <= NSMaxRange($0) }
    }

    private func characterRect(_ lines: DiffLinesView, _ location: Int) throws -> NSRect {
        let rects = lines.rects(forCharacterRange: NSRange(location: location, length: 1)) ?? []
        return try #require(rects.first?.rectValue)
    }

    private func point(inside location: Int, _ lines: DiffLinesView) throws -> NSPoint {
        let rect = try characterRect(lines, location)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in lines: DiffLinesView,
                            clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try #require(lines.window)
        let location = lines.convert(point, to: nil)
        return try #require(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func click(_ lines: DiffLinesView, at point: NSPoint, clickCount: Int = 1,
                       modifiers: NSEvent.ModifierFlags = [], dragTo end: NSPoint? = nil) async throws {
        let target = end ?? point
        if let end {
            NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: end, in: lines, clickCount: clickCount, modifiers: modifiers), atStart: false)
        }
        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: target, in: lines, clickCount: clickCount, modifiers: modifiers), atStart: false)
        lines.mouseDown(with: try mouseEvent(.leftMouseDown, at: point, in: lines, clickCount: clickCount, modifiers: modifiers))
        try await drain()
    }

    @Test func pane_containsNoTextView() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            #expect(descendants(of: hosted.view, NSTextView.self).isEmpty)
            #expect(descendants(of: hosted.pane, DiffLinesView.self).count == 1)
            #expect(hosted.pane.scrollView.documentView === hosted.lines)
        }
    }

    @Test func textStartsRightOfTheGutter() async throws {
        for wrap in [false, true] {
            try await withSettings(wordWrap: wrap) {
                let hosted = try await makeHosted()
                defer { hosted.close() }
                let clip = hosted.pane.scrollView.contentView
                #expect(clip.contentInsets.left >= hosted.pane.lineNumberView.requiredThickness - 0.5)
                #expect(abs(clip.bounds.minX + clip.contentInsets.left) <= 0.5,
                        "wrap \(wrap): document x 0 sits at the gutter's trailing edge, clip \(clip.bounds)")
                let gutterEdge = hosted.pane.lineNumberView.convert(NSPoint(x: hosted.pane.lineNumberView.bounds.maxX, y: 0),
                                                                    to: hosted.lines).x
                let first = try characterRect(hosted.lines, hosted.lines.rowRanges[0].location)
                #expect(first.minX >= gutterEdge, "the first character \(first) is not under the gutter edge \(gutterEdge)")
            }
        }
    }

    @Test func string_isRowsJoinedByNewline() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let ranges = rowRanges(hosted.lines.string)
            #expect(ranges.count == hosted.lines.geometry.rowCount)
            #expect(ranges.count == 201)
            let needle = try range(of: "alpha needle omega 10", in: hosted.lines.string)
            #expect(row(containing: needle.location, ranges) == 9)
        }
    }

    @Test func rectsForCharacterRange_followGeometryAndColumns() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            let needle = try range(of: "needle", in: lines.string)
            let rects = lines.rects(forCharacterRange: needle) ?? []
            #expect(rects.count == 1)
            let rect = try #require(rects.first?.rectValue)
            #expect(abs(rect.height - DiffMetrics.rowHeight) <= 0.5)
            #expect(abs(rect.width - 6 * DiffMetrics.columnWidth) <= 0.5)
            #expect(abs(rect.minY - lines.geometry.rowTop(9)) <= 0.5)
            let rowStartRect = try characterRect(lines, ranges[9].location)
            let column = needle.location - ranges[9].location
            #expect(abs(rect.minX - rowStartRect.minX - CGFloat(column) * DiffMetrics.columnWidth) <= 0.5)
            var effective = NSRange()
            #expect(lines.contentView(at: needle.location, effectiveCharacterRange: &effective) === lines)
            #expect(NSLocationInRange(needle.location, effective))
        }
    }

    @Test func click_placesInsertionPoint() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let needle = try range(of: "needle", in: lines.string)
            let rect = try characterRect(lines, needle.location + 2)
            try await click(lines, at: NSPoint(x: rect.minX + 1, y: rect.midY))
            #expect(lines.selectedRange() == NSRange(location: needle.location + 2, length: 0))
            #expect(hosted.window.firstResponder === lines)
        }
    }

    @Test func drag_selectsBetweenPoints() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let needle = try range(of: "alpha needle omega", in: lines.string)
            let start = try characterRect(lines, needle.location)
            let end = try characterRect(lines, needle.location + 12)
            try await click(lines, at: NSPoint(x: start.minX + 1, y: start.midY),
                            dragTo: NSPoint(x: end.minX + 1, y: end.midY))
            #expect(lines.selectedRange() == NSRange(location: needle.location, length: 12))
        }
    }

    @Test func dragAcrossRows_selectsAcrossNewline() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            let start = try characterRect(lines, ranges[2].location + 1)
            let end = try characterRect(lines, ranges[4].location + 3)
            try await click(lines, at: NSPoint(x: start.minX + 1, y: start.midY),
                            dragTo: NSPoint(x: end.minX + 1, y: end.midY))
            #expect(lines.selectedRange() == NSRange(location: ranges[2].location + 1,
                                                     length: ranges[4].location + 3 - ranges[2].location - 1))
        }
    }

    @Test func shiftClick_extendsSelection() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            let first = try characterRect(lines, ranges[3].location + 2)
            let second = try characterRect(lines, ranges[6].location + 4)
            try await click(lines, at: NSPoint(x: first.minX + 1, y: first.midY))
            try await click(lines, at: NSPoint(x: second.minX + 1, y: second.midY), modifiers: .shift)
            #expect(lines.selectedRange() == NSRange(location: ranges[3].location + 2,
                                                     length: ranges[6].location + 4 - ranges[3].location - 2))
        }
    }

    @Test func doubleClick_selectsWord() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let needle = try range(of: "needle", in: lines.string)
            try await click(lines, at: try point(inside: needle.location + 3, lines), clickCount: 2)
            #expect(lines.selectedRange() == needle)
        }
    }

    @Test func tripleClick_selectsRowIncludingLineBreak() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            let needle = try range(of: "needle", in: lines.string)
            try await click(lines, at: try point(inside: needle.location + 3, lines), clickCount: 3)
            #expect(lines.selectedRange() == NSRange(location: ranges[9].location, length: ranges[9].length + 1))
        }
    }

    @Test func selectAll_selectsWholeString() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            hosted.lines.selectAll(nil)
            #expect(hosted.lines.selectedRange() == NSRange(location: 0, length: hosted.lines.string.utf16.count))
        }
    }

    @Test func copy_writesSelectedSubstringToInjectedPasteboard() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            let needle = try range(of: "alpha needle", in: lines.string)
            let selection = NSRange(location: needle.location, length: NSMaxRange(ranges[10]) - needle.location)
            lines.setSelectedRange(selection)
            lines.copy(nil)
            let expected = (lines.string as NSString).substring(with: selection)
            #expect(expected.contains("\n"))
            #expect(hosted.pasteboard.string(forType: .string) == expected)
        }
    }

    @Test func textFinderClient_reportsStringAndSelection() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let needle = try range(of: "needle", in: lines.string)
            lines.setSelectedRange(needle)
            let client: NSTextFinderClient = lines
            #expect(client.string == lines.string)
            #expect(client.firstSelectedRange == needle)
            #expect(client.isSelectable == true)
            #expect(client.isEditable == false)
        }
    }

    @Test func textFinderClient_scrollRangeToVisible_movesClipView() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let target = try range(of: "second needle here 150", in: lines.string)
            #expect(row(containing: target.location, rowRanges(lines.string)) == 150)
            hosted.pane.scroll(toY: 0)
            let targetTop = lines.geometry.rowTop(150)
            #expect(!hosted.pane.scrollView.documentVisibleRect.contains(NSPoint(x: 1, y: targetTop + 1)))
            lines.scrollRangeToVisible(target)
            let visible = hosted.pane.scrollView.documentVisibleRect
            #expect(visible.minY <= targetTop && targetTop + DiffMetrics.rowHeight <= visible.maxY,
                    "row 150 at \(targetTop) must be visible in \(visible)")
        }
    }

    @Test func performTextFinderAction_showsFindBar() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            hosted.pane.performTextFinderAction(item)
            try await drain()
            #expect(hosted.pane.scrollView.isFindBarVisible)
        }
    }

    private func performThroughResponderChain(_ action: Selector, from origin: NSResponder) -> Bool {
        var candidate: NSResponder? = origin
        while let responder = candidate {
            if responder.responds(to: action) {
                let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
                guard let validator = responder as? NSUserInterfaceValidations,
                      validator.validateUserInterfaceItem(item) else { return false }
                _ = responder.perform(action, with: item)
                return true
            }
            candidate = responder.nextResponder
        }
        return false
    }

    @Test func findShortcuts_reachDiffFinderFromFindFieldAndLinesView() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let string = lines.string as NSString
            let first = try range(of: "needle", in: lines.string)
            let afterFirst = NSRange(location: NSMaxRange(first), length: string.length - NSMaxRange(first))
            let second = string.range(of: "needle", range: afterFirst)
            try #require(second.location != NSNotFound)
            #expect(hosted.window.makeFirstResponder(lines))
            lines.setSelectedRange(first)
            lines.textFinder.performAction(.setSearchString)
            #expect(performThroughResponderChain(#selector(SurfaceView.performFindAction(_:)), from: lines))
            try await drain()
            #expect(hosted.pane.scrollView.isFindBarVisible)
            let field = try #require(descendants(of: hosted.pane.scrollView, NSSearchField.self).first)

            let focusField: () throws -> NSResponder = {
                #expect(hosted.window.makeFirstResponder(field))
                return try #require(hosted.window.firstResponder)
            }
            let focusLines: () throws -> NSResponder = {
                #expect(hosted.window.makeFirstResponder(lines))
                return try #require(hosted.window.firstResponder)
            }
            for focus in [focusField, focusLines] {
                lines.setSelectedRange(first)
                let origin = try focus()
                #expect(performThroughResponderChain(#selector(SurfaceView.findNext(_:)), from: origin))
                try await drain()
                #expect(lines.selectedRange() == second, "\(origin) findNext")
                #expect(performThroughResponderChain(#selector(SurfaceView.findPrevious(_:)), from: origin))
                try await drain()
                #expect(lines.selectedRange() == first, "\(origin) findPrevious")
                #expect(performThroughResponderChain(#selector(SurfaceView.performFindAction(_:)), from: origin))
                try await drain()
                #expect(hosted.pane.scrollView.isFindBarVisible)
            }
        }
    }

    @Test func accessibility_roleValueAndSelection() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            #expect(lines.isAccessibilityElement())
            #expect(lines.accessibilityRole() == .textArea)
            #expect(lines.accessibilityValue() as? String == lines.string)
            let needle = try range(of: "needle", in: lines.string)
            lines.setSelectedRange(needle)
            #expect(lines.accessibilitySelectedTextRange() == needle)
            #expect(lines.accessibilitySelectedText() == "needle")
            #expect(lines.accessibilityNumberOfCharacters() == lines.string.utf16.count)
        }
    }

    @Test func accessibility_linesAndStrings() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            let needle = try range(of: "needle", in: lines.string)
            #expect(lines.accessibilityLine(for: needle.location) == 9)
            #expect(lines.accessibilityLine(for: ranges[0].location) == 0)
            #expect(lines.accessibilityRange(forLine: 9) == NSRange(location: ranges[9].location, length: ranges[9].length + 1))
            #expect(lines.accessibilityString(for: needle) == "needle")
        }
    }

    @Test func accessibility_visibleCharacterRange_coversViewport() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            hosted.pane.scroll(toY: lines.geometry.rowTop(40) + 1)
            let visibleRows = hosted.pane.visibleRowRange
            #expect(visibleRows.lowerBound == 40)
            let range = lines.accessibilityVisibleCharacterRange()
            #expect(range.location == ranges[40].location)
            let last = visibleRows.upperBound - 1
            #expect(NSMaxRange(range) >= NSMaxRange(ranges[last]))
            #expect(NSMaxRange(range) <= NSMaxRange(ranges[last]) + 1)
            #expect(!NSLocationInRange(ranges[39].location, range))
        }
    }

    @Test func accessibility_frameForRange_isOnScreenRowRect() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let needle = try range(of: "needle", in: lines.string)
            let local = try #require(lines.rects(forCharacterRange: needle)?.first?.rectValue)
            let window = try #require(lines.window)
            let expected = window.convertToScreen(lines.convert(local, to: nil))
            let frame = lines.accessibilityFrame(for: needle)
            #expect(abs(frame.minX - expected.minX) <= 0.5)
            #expect(abs(frame.minY - expected.minY) <= 0.5)
            #expect(abs(frame.width - 6 * DiffMetrics.columnWidth) <= 0.5)
            #expect(abs(frame.height - DiffMetrics.rowHeight) <= 0.5)
        }
    }

    @Test func validateUserInterfaceItem_copyNeedsSelection() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let copy = NSMenuItem(title: "Copy", action: #selector(DiffLinesView.copy(_:)), keyEquivalent: "c")
            lines.setSelectedRange(NSRange(location: 3, length: 0))
            #expect(!lines.validateUserInterfaceItem(copy))
            lines.setSelectedRange(NSRange(location: 3, length: 4))
            #expect(lines.validateUserInterfaceItem(copy))
            let selectAll = NSMenuItem(title: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
            #expect(lines.validateUserInterfaceItem(selectAll))
        }
    }

    private func inkPixels(_ rep: NSBitmapImageRep, in rect: NSRect, origin: NSRect) -> Int {
        let scale = CGFloat(rep.pixelsWide) / origin.width
        let minX = max(Int((rect.minX - origin.minX) * scale), 0)
        let maxX = min(Int((rect.maxX - origin.minX) * scale), rep.pixelsWide)
        let minY = max(Int((rect.minY - origin.minY) * scale), 0)
        let maxY = min(Int((rect.maxY - origin.minY) * scale), rep.pixelsHigh)
        guard minX < maxX, minY < maxY else {
            Issue.record("\(rect) is outside the \(rep.pixelsWide)x\(rep.pixelsHigh) px render of \(origin)")
            return 0
        }
        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { count += 1 }
            }
        }
        return count
    }

    @Test func draw_rendersGlyphsInsideTheirCharacterRects() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            lines.setSelectedRange(NSRange(location: 0, length: 0))
            let visible = lines.visibleRect
            let rep = try #require(lines.bitmapImageRepForCachingDisplay(in: visible))
            lines.cacheDisplay(in: visible, to: rep)
            let needle = try #require(lines.rects(forCharacterRange: try range(of: "needle", in: lines.string))?.first?.rectValue)
            #expect(inkPixels(rep, in: needle, origin: visible) > 20, "the glyphs of \"needle\" are drawn in \(needle)")
            let rowEnd = try #require(lines.rects(forCharacterRange: NSRange(location: NSMaxRange(ranges[9]), length: 0))?
                .first?.rectValue)
            let blank = NSRect(x: rowEnd.maxX + DiffMetrics.columnWidth, y: rowEnd.minY,
                               width: 20 * DiffMetrics.columnWidth, height: rowEnd.height)
            #expect(inkPixels(rep, in: blank, origin: visible) == 0, "nothing is drawn past the end of row 9")
        }
    }

    private struct Reference {
        let window: NSWindow
        let scrollView: NSScrollView
        let textView: NSTextView
        let storage: NSTextStorage

        @MainActor func close() {
            window.orderOut(nil)
            window.close()
        }
    }

    private func makeReference(_ string: String) -> Reference {
        let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 800, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: scrollView.bounds, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainerInset = DiffMetrics.textInset
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.font = DiffMetrics.font
        textView.string = string
        scrollView.documentView = textView
        window.contentView = scrollView
        window.orderFront(nil)
        window.makeFirstResponder(textView)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        textView.frame = NSRect(x: 0, y: 0, width: max(scrollView.contentSize.width, used.width + 2 * DiffMetrics.textInset.width),
                                height: max(scrollView.contentSize.height, used.height + 2 * DiffMetrics.textInset.height))
        window.layoutIfNeeded()
        return Reference(window: window, scrollView: scrollView, textView: textView, storage: storage)
    }

    private func referencePoint(_ reference: Reference, _ location: Int) throws -> NSPoint {
        let textView = reference.textView
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        return NSPoint(x: rect.minX + 0.5, y: rect.midY)
    }

    private func clickReference(_ reference: Reference, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        let location = reference.textView.convert(point, to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: reference.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: false)
        reference.textView.mouseDown(with: try event(.leftMouseDown))
    }

    private func clusterRow(_ lines: DiffLinesView) throws -> (row: Int, range: NSRange) {
        let ranges = rowRanges(lines.string)
        let found = try range(of: clusterRowText, in: lines.string)
        let row = try #require(row(containing: found.location, ranges))
        #expect(row == 29)
        return (row, ranges[row])
    }

    private func isClusterBoundary(_ index: Int, in string: String) -> Bool {
        let text = string as NSString
        guard index > 0, index < text.length else { return true }
        return text.rangeOfComposedCharacterSequence(at: index).location == index
    }

    private func clusterRects(_ lines: DiffLinesView, _ token: String) throws -> (cluster: NSRect, next: NSRect) {
        let found = try range(of: token, in: lines.string)
        let cluster = try #require(lines.rects(forCharacterRange: found)?.first?.rectValue)
        let next = try characterRect(lines, NSMaxRange(found))
        return (cluster, next)
    }

    @Test func graphemes_hitTestingReturnsClusterBoundaries() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let (row, rowRange) = try clusterRow(lines)
            let y = lines.geometry.rowTop(row) + DiffMetrics.rowHeight / 2
            var x: CGFloat = 0
            var seen = Set<Int>()
            while x < 600 {
                let index = lines.characterIndex(at: NSPoint(x: x, y: y))
                #expect(index >= rowRange.location && index <= NSMaxRange(rowRange))
                #expect(isClusterBoundary(index, in: lines.string), "x \(x) hit \(index) inside a cluster")
                seen.insert(index)
                x += 1
            }
            #expect(seen.count > 20)
        }
    }

    @Test func graphemes_followingCharactersSitRightAfterTheCluster() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let cw = DiffMetrics.columnWidth
            let accent = try clusterRects(lines, "e\u{301}")
            #expect(abs(accent.next.minX - accent.cluster.minX - cw) <= 0.5, "e + combining acute is one column: \(accent)")
            for token in ["👍🏽", "👨‍👩‍👧", "😀"] {
                let emoji = try clusterRects(lines, token)
                let advance = emoji.next.minX - emoji.cluster.minX
                #expect(advance > cw && advance < 3 * cw, "\(token) renders as one glyph: advance \(advance)")
                #expect(abs(emoji.cluster.maxX - emoji.next.minX) <= 0.5, "no gap or overlap after \(token)")
            }
            let math = try clusterRects(lines, "𝑥")
            #expect(abs(math.cluster.maxX - math.next.minX) <= 0.5)
            let (row, rowRange) = try clusterRow(lines)
            let tab = try range(of: "\tq end", in: lines.string)
            let tabRect = try characterRect(lines, tab.location)
            let qRect = try characterRect(lines, tab.location + 1)
            let offset = tab.location - rowRange.location - lines.rowTexts[row].markerLength
            let columns = lines.rowTexts[row].columns
            let tabColumns = CGFloat(columns[offset + 1] - columns[offset])
            #expect(abs(qRect.minX - tabRect.minX - tabColumns * cw) <= 0.5,
                    "the tab after CJK expands to \(tabColumns) columns")
            let cjk = try clusterRects(lines, "漢字かな")
            #expect(abs(cjk.cluster.maxX - cjk.next.minX) <= 0.5)
        }
    }

    @Test func graphemes_pixelsDrawnWhereTheRectsAre() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let (row, _) = try clusterRow(lines)
            hosted.pane.scroll(toY: lines.geometry.rowTop(row) - 20)
            lines.setSelectedRange(NSRange(location: 0, length: 0))
            let visible = lines.visibleRect
            let rep = try #require(lines.bitmapImageRepForCachingDisplay(in: visible))
            lines.cacheDisplay(in: visible, to: rep)
            for token in ["e\u{301}", "x", "👍🏽", "q", "👨‍👩‍👧", "z", "漢字かな", "end"] {
                let found = try range(of: token, in: lines.string)
                for rect in lines.rects(forCharacterRange: found)?.map(\.rectValue) ?? [] {
                    #expect(inkPixels(rep, in: rect, origin: visible) > 5, "\(token.debugDescription) drawn in \(rect)")
                }
            }
            let accent = try range(of: "e\u{301}x", in: lines.string)
            let afterX = try characterRect(lines, NSMaxRange(accent))
            #expect(inkPixels(rep, in: afterX.insetBy(dx: 1, dy: 1), origin: visible) == 0, "the space after éx is empty")
        }
    }

    @Test func graphemes_selectionCopyAndDragKeepClusters() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let family = try range(of: "👨‍👩‍👧", in: lines.string)
            lines.setSelectedRange(NSRange(location: family.location + 2, length: 1))
            lines.copy(nil)
            #expect(hosted.pasteboard.string(forType: .string) == "👨‍👩‍👧")
            let accent = try range(of: "e\u{301}", in: lines.string)
            lines.setSelectedRange(NSRange(location: accent.location + 1, length: 0))
            #expect(lines.selectedRange() == NSRange(location: accent.location, length: 0))
            let rect = try #require(lines.rects(forCharacterRange: family)?.first?.rectValue)
            try await click(lines, at: NSPoint(x: rect.minX + 1, y: rect.midY),
                            dragTo: NSPoint(x: rect.minX + rect.width * 0.4, y: rect.midY))
            let selected = lines.selectedRange()
            #expect(isClusterBoundary(selected.location, in: lines.string) && isClusterBoundary(NSMaxRange(selected), in: lines.string))
            #expect(lines.accessibilityString(for: NSRange(location: family.location + 1, length: 1)) == "👨‍👩‍👧")
        }
    }

    @Test func draw_reusesCachedLines() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let visible = lines.visibleRect
            lines.display(visible)
            let built = lines.lineBuildCount
            #expect(built > 0)
            lines.display(visible)
            lines.setSelectedRange(NSRange(location: 3, length: 40))
            lines.display(visible)
            #expect(lines.lineBuildCount == built, "drawing the same rows again builds no new lines")
        }
    }

    private func checkVisualLineModel(string: NSString, lineCount: Int, line: (Int) -> Int, range: (Int) -> NSRange,
                                      label: String) {
        var location = 0
        for index in 0..<lineCount {
            let lineRange = range(index)
            #expect(lineRange.location == location, "\(label) line \(index) starts at \(location): \(lineRange)")
            let end = NSMaxRange(lineRange)
            #expect(line(lineRange.location + 1) == index, "\(label) line(for: \(lineRange.location + 1))")
            #expect(line(end) == index, "\(label) the index after a line's last character belongs to that line")
            location = end
        }
        #expect(location == string.length, "\(label) lines cover the text")
    }

    @Test func accessibility_wrappedSegmentsAreLinesLikeReference() async throws {
        try await withSettings(wordWrap: true) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            hosted.window.setContentSize(NSSize(width: 250, height: 400))
            try await settle(hosted.window)
            let string = lines.string as NSString
            let segments = lines.segmentCounts.reduce(0, +)
            #expect(segments > lines.geometry.rowCount, "some rows wrap")
            checkVisualLineModel(string: string, lineCount: segments, line: lines.accessibilityLine(for:),
                                 range: lines.accessibilityRange(forLine:), label: "lines")
            let wrapped = try #require(lines.segmentCounts.firstIndex { $0 > 1 })
            let first = lines.accessibilityLine(for: lines.rowRanges[wrapped].location + 1)
            let firstRange = lines.accessibilityRange(forLine: first)
            #expect(string.character(at: NSMaxRange(firstRange) - 1) != 0x0A, "a non-final segment has no newline")
            lines.setSelectedRange(NSRange(location: NSMaxRange(firstRange), length: 0))
            #expect(lines.accessibilityInsertionPointLineNumber() == first + 1)
            let reference = makeReference("short\nalpha beta gamma delta epsilon zeta\nend")
            defer { reference.close() }
            let textView = reference.textView
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.setFrameSize(NSSize(width: 120, height: 400))
            textView.textContainer?.containerSize = NSSize(width: 120, height: CGFloat.greatestFiniteMagnitude)
            reference.window.layoutIfNeeded()
            let referenceString = textView.string as NSString
            let referenceLines = textView.accessibilityLine(for: referenceString.length) + 1
            #expect(referenceLines > 3, "the reference wraps")
            checkVisualLineModel(string: referenceString, lineCount: referenceLines, line: textView.accessibilityLine(for:),
                                 range: textView.accessibilityRange(forLine:), label: "NSTextView")
        }
    }

    @Test func shiftClick_matchesReferenceAnchorRule() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let reference = makeReference(lines.string)
            defer { reference.close() }
            let base = rowRanges(lines.string)[5].location
            enum Step { case set(Int, Int), click(Int), shift(Int) }
            let cases: [[Step]] = [
                [.set(100, 20), .shift(50)], [.set(100, 20), .shift(150)], [.set(100, 0), .shift(50)], [.set(100, 0), .shift(150)],
                [.click(100), .shift(120), .shift(50)], [.click(100), .shift(50), .shift(150)],
                [.set(100, 20), .shift(110), .shift(60)], [.set(100, 20), .shift(110), .shift(150)],
                [.set(100, 20), .shift(105)], [.set(100, 20), .shift(115)], [.click(100), .shift(110), .shift(105)],
            ]
            for steps in cases {
                var label = ""
                for step in steps {
                    switch step {
                    case let .set(location, length):
                        let range = NSRange(location: base + location, length: length)
                        reference.textView.setSelectedRange(range)
                        lines.setSelectedRange(range)
                        label += "set \(location),\(length) "
                    case let .click(location):
                        try clickReference(reference, at: try referencePoint(reference, base + location))
                        try await click(lines, at: try leadingPoint(base + location, lines))
                        label += "click \(location) "
                    case let .shift(location):
                        try clickReference(reference, at: try referencePoint(reference, base + location), modifiers: [.shift])
                        try await click(lines, at: try leadingPoint(base + location, lines), modifiers: [.shift])
                        label += "shift \(location) "
                    }
                    #expect(lines.selectedRange() == reference.textView.selectedRange(),
                            "\(label): lines \(lines.selectedRange()) vs NSTextView \(reference.textView.selectedRange())")
                }
            }
        }
    }

    private func leadingPoint(_ location: Int, _ lines: DiffLinesView) throws -> NSPoint {
        let rect = try characterRect(lines, location)
        return NSPoint(x: rect.minX + 0.5, y: rect.midY)
    }

    @Test func dragSelect_keepsAutoscrollingWhileTheMouseIsHeldOutside() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let clip = hosted.pane.scrollView.contentView
            let window = hosted.window
            @MainActor func run(periodicEvents: Int) throws -> CGFloat {
                hosted.pane.scroll(toY: 0)
                let start = try point(inside: rowRanges(lines.string)[2].location + 1, lines)
                let outside = NSPoint(x: start.x, y: clip.bounds.maxY + 40)
                NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: outside, in: lines), atStart: false)
                for _ in 0..<periodicEvents {
                    let periodic = try #require(NSEvent.otherEvent(
                        with: .periodic, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0))
                    NSApp.postEvent(periodic, atStart: false)
                }
                NSApp.postEvent(try mouseEvent(.leftMouseUp, at: outside, in: lines), atStart: false)
                lines.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: lines))
                while let leftover = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { _ = leftover }
                return clip.bounds.minY
            }
            let once = try run(periodicEvents: 0)
            let held = try run(periodicEvents: 5)
            #expect(once > 0, "dragging outside autoscrolls")
            #expect(held > once + 1, "held outside the view the clip keeps moving: \(held) vs \(once)")
        }
    }

    @Test func findIndicator_clipsToEachMatchRect() async throws {
        try await withSettings(wordWrap: true) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            hosted.window.setContentSize(NSSize(width: 250, height: 400))
            try await settle(hosted.window)
            let ranges = rowRanges(lines.string)
            let row = try #require(ranges.indices.first { (lines.projections[$0]?.segmentCount ?? 1) >= 2 })
            let markerLength = lines.rowTexts[row].markerLength
            let breakIndex = ranges[row].location + markerLength + (try #require(lines.projections[row])).breakOffsets[0]
            let match = NSRange(location: breakIndex - 2, length: 4)
            let rects = lines.rects(in: match)
            #expect(rects.count == 2)
            let union = rects.reduce(NSRect.null) { $0.union($1) }
            let scale: CGFloat = 2
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(lines.bounds.width * scale), pixelsHigh: Int(lines.bounds.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = lines.bounds.size
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: lines.bounds.height)
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
            lines.drawCharacters(in: match, forContentView: lines)
            NSGraphicsContext.restoreGraphicsState()
            var inkOutside = 0
            var inkInside = 0
            var y = union.minY + 1
            while y < union.maxY - 1 {
                var x = union.minX + 1
                while x < union.maxX - 1 {
                    let alpha = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0
                    if alpha > 0.1 {
                        if rects.contains(where: { $0.contains(NSPoint(x: x, y: y)) }) { inkInside += 1 } else { inkOutside += 1 }
                    }
                    x += 0.5
                }
                y += 0.5
            }
            #expect(inkInside > 0, "the match is drawn")
            #expect(inkOutside == 0, "nothing is drawn between the match rects: \(inkOutside) samples")
        }
    }

    @Test func pageDown_scrollsThroughTheResponderChain() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let clip = hosted.pane.scrollView.contentView
            hosted.window.makeKeyAndOrderFront(nil)
            #expect(hosted.window.makeFirstResponder(lines))
            let selection = lines.selectedRange()
            let topY = clip.bounds.minY
            let pageDown = String(Character(UnicodeScalar(NSPageDownFunctionKey)!))
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hosted.window.windowNumber, context: nil, characters: pageDown,
                charactersIgnoringModifiers: pageDown, isARepeat: false, keyCode: 121))
            lines.keyDown(with: event)
            try await drain()
            #expect(clip.bounds.minY - topY > clip.bounds.height / 2, "Page Down scrolls the pane: clip y \(clip.bounds.minY)")
            #expect(lines.selectedRange() == selection, "scrolling keeps the selection")
        }
    }

    @Test func lineCache_staysNearTheViewport() async throws {
        try await withSettings {
            let hosted = try await makeHosted(raw: makeManyRowsRaw(20_000))
            defer { hosted.close() }
            let lines = hosted.lines
            let pane = hosted.pane
            let bound = lines.lineCacheBoundForTesting
            let step = pane.scrollView.documentVisibleRect.height
            var y: CGFloat = 0
            while y < lines.frame.height {
                pane.scroll(toY: y)
                hosted.window.displayIfNeeded()
                #expect(lines.lineCacheCountForTesting <= bound, "scrolled to \(y): \(lines.lineCacheCountForTesting) > \(bound)")
                y += step
            }
            lines.selectAll(nil)
            let whole = NSRange(location: 0, length: (lines.string as NSString).length)
            let rects = try #require(lines.rects(forCharacterRange: whole))
            #expect(rects.count >= 20_000)
            _ = lines.characterIndex(at: NSPoint(x: 40, y: 3))
            #expect(lines.lineCacheCountForTesting <= bound, "select-all and far queries: \(lines.lineCacheCountForTesting) > \(bound)")
            pane.scroll(toY: lines.frame.height / 2)
            hosted.window.displayIfNeeded()
            let builds = lines.lineBuildCount
            lines.needsDisplay = true
            hosted.window.displayIfNeeded()
            #expect(lines.lineBuildCount == builds, "redrawing the viewport reuses cached lines")
        }
    }

    @Test func rewrap_clearsProjectionsOfRowsThatFit() async throws {
        try await withSettings(wordWrap: true) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let text = hosted.lines.text
            var wrap = DiffPaneWrap.unwrapped(rowCount: text.rowCount)
            for column in [8, 13, 5, 200, 9, 400] {
                wrap = text.rewrapped(wrap, column: column)
                for row in 0..<wrap.projections.count {
                    let count = wrap.segmentCounts[row]
                    #expect((wrap.projections[row] == nil) == (count == 1), "column \(column) row \(row): \(count) segments")
                    #expect(count == (wrap.projections[row]?.segmentCount ?? 1))
                }
            }
            #expect(wrap.projections.allSatisfy { $0 == nil }, "every row fits at 400 columns")
        }
    }

    private func rightClick(_ lines: DiffLinesView, at point: NSPoint,
                            modifiers: NSEvent.ModifierFlags = []) throws -> NSMenu? {
        lines.menu(for: try mouseEvent(.rightMouseDown, at: point, in: lines, modifiers: modifiers))
    }

    private func rightClickReference(_ reference: Reference, at point: NSPoint) throws -> NSMenu? {
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: reference.textView.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: reference.window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        return reference.textView.menu(for: event)
    }

    private func referenceCharacterRect(_ reference: Reference, _ location: Int) throws -> NSRect {
        let textView = reference.textView
        let layoutManager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }

    private func fractionPoint(_ rect: NSRect, _ fraction: CGFloat) -> NSPoint {
        NSPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
    }

    private func copyItem(_ menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.items.first { $0.action == #selector(DiffLinesView.copy(_:)) })
    }

    private func selectAllItem(_ menu: NSMenu) throws -> NSMenuItem {
        try #require(menu.items.first { $0.action == #selector(NSResponder.selectAll(_:)) })
    }

    private func isActionRow(_ cell: DiffCell?) -> Bool {
        switch cell?.kind {
        case .comment?, .collapsedRegion?: return true
        default: return false
        }
    }

    private func addContextComment(_ view: DiffView, _ diff: FileDiff, newLine: Int) throws {
        let store = view.reviewStore ?? DiffReviewStore()
        view.reviewStore = store
        let index = try #require(diff.lines.firstIndex { $0.type == .context && $0.newLineNumber == newLine })
        store.addComment(lineIndex: index, lineNumber: newLine, oldLineNumber: diff.lines[index].oldLineNumber,
                         lineType: .context, text: "note \(newLine)")
    }

    private func makeActionRowsHosted() async throws -> Hosted {
        DiffLayoutSettings.hideUnchangedRegionsEnabled = true
        var configured: Result<Void, Error> = .success(())
        let hosted = try await makeHosted { view, diff in
            configured = Result { try addContextComment(view, diff, newLine: 106) }
        }
        try configured.get()
        return hosted
    }

    @Test func contextMenu_offersCopyAndSelectAllTargetingTheLinesView() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let needle = try range(of: "needle", in: lines.string)
            let menu = try #require(try rightClick(lines, at: try point(inside: needle.location + 2, lines)))
            #expect(menu.items.count == 2)
            #expect(!menu.items.contains { $0.isSeparatorItem })
            #expect(menu.items.map(\.title) == ["Copy", "Select All"])
            let copy = try copyItem(menu)
            let selectAll = try selectAllItem(menu)
            #expect(menu.items.first === copy)
            #expect(copy.target === lines)
            #expect(selectAll.target === lines)
            #expect(copy.keyEquivalent == "")
            #expect(selectAll.keyEquivalent == "")
            #expect(copy.accessibilityIdentifier() == AccessibilityID.Diff.contextMenuCopy)
            #expect(selectAll.accessibilityIdentifier() == AccessibilityID.Diff.contextMenuSelectAll)
        }
    }

    @Test func contextMenu_rightClickSelectionMatchesReference() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let reference = makeReference(lines.string)
            defer { reference.close() }
            let ranges = rowRanges(lines.string)
            let needle = try range(of: "needle", in: lines.string)
            let omega = try range(of: "omega", in: lines.string)
            let pi = try range(of: "3.14", in: lines.string)
            let its = try range(of: "it's", in: lines.string)
            let fooBar = try range(of: "foo_bar", in: lines.string)
            let kana = try range(of: "かなカナ漢字ひらがな", in: lines.string)
            let elsewhere = NSRange(location: ranges[3].location + 2, length: 0)
            let rowEnd = NSMaxRange(ranges[9]) - 1
            struct Case { let label: String; let selection: NSRange; let index: Int; let fraction: CGFloat; let beyondRowEnd: Bool }
            var cases: [Case] = []
            func add(_ label: String, _ selection: NSRange, _ index: Int, fractions: [CGFloat] = [0.25, 0.75],
                     beyondRowEnd: Bool = false) {
                for fraction in fractions {
                    cases.append(Case(label: label, selection: selection, index: index, fraction: fraction,
                                      beyondRowEnd: beyondRowEnd))
                }
            }
            add("caret elsewhere, word character", elsewhere, needle.location + 2)
            add("word selected, click inside it", needle, needle.location + 3)
            add("word selected, click another word", needle, omega.location + 1)
            add("caret elsewhere, space", elsewhere, needle.location - 1)
            add("caret elsewhere, period of 3.14", elsewhere, pi.location + 1)
            add("caret elsewhere, apostrophe of it's", elsewhere, its.location + 2)
            add("caret elsewhere, underscore of foo_bar", elsewhere, fooBar.location + 3)
            add("word selected, first character", needle, needle.location)
            add("word selected, last character", needle, NSMaxRange(needle) - 1)
            add("caret at the character's left boundary", NSRange(location: needle.location + 2, length: 0), needle.location + 2)
            add("caret elsewhere, right of a row end", elsewhere, rowEnd, fractions: [0.25], beyondRowEnd: true)
            add("caret elsewhere, kana", elsewhere, kana.location + 1)
            add("caret elsewhere, katakana", elsewhere, kana.location + 2)
            add("caret elsewhere, kanji", elsewhere, kana.location + 4)
            add("caret elsewhere, hiragana after kanji", elsewhere, kana.location + 6)
            for entry in cases {
                lines.setSelectedRange(entry.selection)
                reference.textView.setSelectedRange(entry.selection)
                var linesPoint = fractionPoint(try characterRect(lines, entry.index), entry.fraction)
                var referencePoint = fractionPoint(try referenceCharacterRect(reference, entry.index), entry.fraction)
                if entry.beyondRowEnd {
                    linesPoint.x = try characterRect(lines, entry.index).maxX + 100
                    referencePoint.x = try referenceCharacterRect(reference, entry.index).maxX + 100
                }
                _ = try rightClickReference(reference, at: referencePoint)
                _ = try rightClick(lines, at: linesPoint)
                #expect(lines.selectedRange() == reference.textView.selectedRange(),
                        "\(entry.label) at \(entry.fraction): lines \(lines.selectedRange()) vs NSTextView \(reference.textView.selectedRange())")
            }
        }
    }

    @Test func contextMenu_enablementFollowsSelection() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let needle = try range(of: "needle", in: lines.string)
            let caret = NSRange(location: needle.location + 2, length: 0)
            lines.setSelectedRange(caret)
            let kept = try #require(try rightClick(lines, at: fractionPoint(try characterRect(lines, caret.location), 0.25)))
            kept.update()
            #expect(lines.selectedRange() == caret)
            #expect(try !copyItem(kept).isEnabled)
            #expect(try selectAllItem(kept).isEnabled)

            lines.setSelectedRange(NSRange(location: rowRanges(lines.string)[3].location, length: 0))
            let word = try #require(try rightClick(lines, at: try point(inside: needle.location + 2, lines)))
            word.update()
            #expect(try copyItem(word).isEnabled)
            #expect(try selectAllItem(word).isEnabled)
        }
    }

    @Test func contextMenu_copyItemCopiesTheRightClickedWord() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            lines.setSelectedRange(NSRange(location: rowRanges(lines.string)[3].location, length: 0))
            let needle = try range(of: "needle", in: lines.string)
            let menu = try #require(try rightClick(lines, at: try point(inside: needle.location + 2, lines)))
            let index = try #require(menu.items.firstIndex { $0.action == #selector(DiffLinesView.copy(_:)) })
            menu.performActionForItem(at: index)
            #expect(hosted.pasteboard.string(forType: .string) == "needle")
        }
    }

    @Test func contextMenu_rightClickOnATextRowMakesLinesFirstResponder() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            hosted.window.makeFirstResponder(nil)
            #expect(hosted.window.firstResponder !== lines)
            let needle = try range(of: "needle", in: lines.string)
            _ = try rightClick(lines, at: try point(inside: needle.location + 2, lines))
            #expect(hosted.window.firstResponder === lines)
        }
    }

    @Test func contextMenu_onCommentAndCollapsedRowsKeepsSelection() async throws {
        try await withSettings {
            let hosted = try await makeActionRowsHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let kinds = lines.cells.map(\.?.kind)
            let commentRow = try #require(kinds.firstIndex { $0 == .comment })
            let collapsedRow = try #require(kinds.firstIndex {
                if case .collapsedRegion? = $0 { return true }
                return false
            })
            let textRow = try #require(lines.cells.indices.first { !isActionRow(lines.cells[$0]) && lines.rowRanges[$0].length > 3 })
            for (label, row) in [("comment", commentRow), ("collapsed", collapsedRow)] {
                lines.scrollToVisible(NSRect(x: 0, y: lines.geometry.rowTop(row), width: 1,
                                             height: lines.geometry.contentHeight(row)))
                try await settle(hosted.window)
                let selection = NSRange(location: lines.rowRanges[textRow].location, length: 3)
                lines.setSelectedRange(selection)
                hosted.window.makeFirstResponder(nil)
                let responder = hosted.window.firstResponder
                let y = lines.geometry.rowTop(row) + lines.geometry.contentHeight(row) / 2
                let menu = try rightClick(lines, at: NSPoint(x: lines.visibleRect.midX, y: y))
                #expect(menu != nil, "\(label) row \(row) offers the menu")
                #expect(lines.selectedRange() == selection, "\(label) row keeps the selection: \(lines.selectedRange())")
                #expect(hosted.window.firstResponder === responder, "\(label) row keeps the first responder")
            }
        }
    }

    private func checkCursorRegions(_ lines: DiffLinesView, label: String) {
        let rect = lines.visibleRect
        let regions = lines.cursorRegions(in: rect)
        let rows = Array(lines.geometry.rows(intersecting: rect.minY, rect.maxY))
        #expect(!rows.isEmpty, "\(label): rows intersect \(rect)")
        for region in regions {
            #expect(region.rect.minX <= rect.minX + 0.5 && region.rect.maxX >= rect.maxX - 0.5,
                    "\(label): region \(region.rect) spans the x-range of \(rect)")
        }
        for (i, a) in regions.enumerated() {
            for b in regions[(i + 1)...] {
                let overlap = a.rect.intersection(b.rect)
                #expect(overlap.isNull || overlap.height <= 0.5 || overlap.width <= 0.5,
                        "\(label): regions \(a.rect) and \(b.rect) overlap")
            }
        }
        for row in rows {
            let top = max(lines.geometry.rowTop(row), rect.minY)
            let bottom = min(lines.geometry.rowTop(row) + lines.geometry.contentHeight(row) + lines.geometry.pads[row], rect.maxY)
            let probe = NSPoint(x: rect.midX, y: (top + bottom) / 2)
            let hits = regions.filter { $0.rect.contains(probe) }
            #expect(hits.count == 1, "\(label): row \(row) probe \(probe) is in \(hits.count) regions")
            let expected = isActionRow(lines.cells[row]) ? NSCursor.arrow : NSCursor.iBeam
            if let hit = hits.first {
                #expect(hit.cursor === expected, "\(label): row \(row) \(String(describing: lines.cells[row]?.kind)) cursor")
            }
        }
        var runs = 0
        var previous: Bool?
        for row in rows {
            let action = isActionRow(lines.cells[row])
            if action != previous { runs += 1 }
            previous = action
        }
        #expect(regions.count == runs, "\(label): \(regions.count) regions for \(runs) same-kind runs")
    }

    @Test func cursorRegions_iBeamOnTextRowsArrowOnActionRows() async throws {
        try await withSettings {
            let hosted = try await makeActionRowsHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let rect = lines.visibleRect
            let rows = lines.geometry.rows(intersecting: rect.minY, rect.maxY)
            let kinds = lines.cells.map { $0.map { "\($0.kind)" } ?? "nil" }
            #expect(rows.contains { lines.cells[$0]?.kind == .comment }, "a comment row is visible in \(rows) of \(kinds)")
            #expect(rows.contains { if case .collapsedRegion? = lines.cells[$0]?.kind { return true } else { return false } },
                    "a collapsed row is visible")
            #expect(rows.contains { !isActionRow(lines.cells[$0]) }, "a text row is visible")
            checkCursorRegions(lines, label: "top")
        }
    }

    @Test func cursorRegions_followTheViewportAfterScrolling() async throws {
        try await withSettings {
            var configured: Result<Void, Error> = .success(())
            let hosted = try await makeHosted { view, diff in
                configured = Result {
                    try addContextComment(view, diff, newLine: 5)
                    try addContextComment(view, diff, newLine: 160)
                }
            }
            try configured.get()
            defer { hosted.close() }
            let lines = hosted.lines
            checkCursorRegions(lines, label: "top")
            let farRow = try #require(lines.cells.indices.first { lines.cells[$0]?.kind == .comment && $0 > 100 })
            hosted.pane.scroll(toY: lines.geometry.rowTop(farRow) - 60)
            try await settle(hosted.window)
            let rect = lines.visibleRect
            #expect(lines.geometry.rows(intersecting: rect.minY, rect.maxY).contains(farRow), "scrolled to row \(farRow)")
            checkCursorRegions(lines, label: "scrolled")
        }
    }

    private func checkInsetCursorRegions(_ lines: DiffLinesView, label: String) throws {
        let geometry = lines.geometry
        let lastRow = geometry.rowCount - 1
        let firstCursor = isActionRow(lines.cells[0]) ? NSCursor.arrow : NSCursor.iBeam
        let lastCursor = isActionRow(lines.cells[lastRow]) ? NSCursor.arrow : NSCursor.iBeam
        let topRect = NSRect(x: 0, y: 0, width: lines.bounds.width, height: geometry.rowTop(0) - 1)
        try #require(topRect.height > 0, "\(label): top inset exists")
        let top = lines.cursorRegions(in: topRect)
        #expect(top.count == 1, "\(label): \(top.count) regions inside the top inset \(topRect)")
        #expect(top.first?.rect == topRect, "\(label): top region \(String(describing: top.first?.rect)) vs \(topRect)")
        #expect(top.first?.cursor === firstCursor, "\(label): top inset cursor follows row 0 \(String(describing: lines.cells[0]?.kind))")
        let bottomRect = NSRect(x: 0, y: geometry.documentHeight + 1, width: lines.bounds.width,
                                height: lines.bounds.maxY - geometry.documentHeight - 2)
        try #require(bottomRect.height > 0, "\(label): bottom inset exists below \(geometry.documentHeight) in \(lines.bounds)")
        let bottom = lines.cursorRegions(in: bottomRect)
        #expect(bottom.count == 1, "\(label): \(bottom.count) regions inside the bottom inset \(bottomRect)")
        #expect(bottom.first?.rect == bottomRect, "\(label): bottom region \(String(describing: bottom.first?.rect)) vs \(bottomRect)")
        #expect(bottom.first?.cursor === lastCursor,
                "\(label): bottom inset cursor follows row \(lastRow) \(String(describing: lines.cells[lastRow]?.kind))")
    }

    @Test func cursorRegions_coverRectsInsideTheTextInsets() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            try checkInsetCursorRegions(hosted.lines, label: "default")
        }
        try await withSettings {
            let hosted = try await makeActionRowsHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let lastRow = lines.geometry.rowCount - 1
            #expect(isActionRow(lines.cells[0]) || isActionRow(lines.cells[lastRow]),
                    "an edge row is an action row: \(String(describing: lines.cells[0]?.kind)) / \(String(describing: lines.cells[lastRow]?.kind))")
            try checkInsetCursorRegions(lines, label: "action rows")
        }
    }

    @Test func contextMenu_rightClickPastAWrappedSegmentEnd_followsReference() async throws {
        try await withSettings(wordWrap: true) {
            let reference = makeReference("alpha beta gamma delta epsilon zeta eta theta")
            defer { reference.close() }
            let textView = reference.textView
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.setFrameSize(NSSize(width: 120, height: 400))
            textView.textContainer?.containerSize = NSSize(width: 120, height: CGFloat.greatestFiniteMagnitude)
            reference.window.layoutIfNeeded()
            let layoutManager = try #require(textView.layoutManager)
            var fragmentGlyphs = NSRange()
            let usedRect = layoutManager.lineFragmentUsedRect(forGlyphAt: 0, effectiveRange: &fragmentGlyphs)
            let fragmentChars = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            try #require(NSMaxRange(fragmentChars) < reference.storage.length, "the reference wraps")
            let lastChar = NSMaxRange(fragmentChars) - 1
            let origin = textView.textContainerOrigin
            let referenceX = min(usedRect.maxX + origin.x + 4, textView.bounds.maxX - 1)
            try #require(referenceX > usedRect.maxX + origin.x, "click lands right of the fragment end")
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            _ = try rightClickReference(reference, at: NSPoint(x: referenceX, y: usedRect.midY + origin.y))
            let referenceExpected = reference.storage.doubleClick(at: lastChar)
            #expect(textView.selectedRange() == referenceExpected,
                    "NSTextView selected \(textView.selectedRange()); doubleClick(lastChar \(lastChar)) = \(referenceExpected); next fragment starts at \(NSMaxRange(fragmentChars))")

            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            hosted.window.setContentSize(NSSize(width: 250, height: 400))
            try await settle(hosted.window)
            let wrapped = try #require(lines.segmentCounts.firstIndex { $0 > 1 })
            hosted.pane.scroll(toY: max(lines.geometry.rowTop(wrapped) - 40, 0))
            try await settle(hosted.window)
            let first = lines.accessibilityLine(for: lines.rowRanges[wrapped].location + 1)
            let segmentRange = lines.accessibilityRange(forLine: first)
            let segmentLast = NSMaxRange(segmentRange) - 1
            let string = lines.string as NSString
            try #require(string.character(at: segmentLast) != 0x0A, "a non-final segment has no newline")
            let lastRect = try characterRect(lines, segmentLast)
            try #require(lines.visibleRect.intersects(lastRect), "segment \(lastRect) is visible in \(lines.visibleRect)")
            let x = min(lastRect.maxX + 4, lines.bounds.maxX - 1)
            try #require(x > lastRect.maxX, "click lands right of the segment end")
            let elsewhere = wrapped == 0 ? lines.rowRanges[1].location : 0
            lines.setSelectedRange(NSRange(location: elsewhere, length: 0))
            _ = try rightClick(lines, at: NSPoint(x: x, y: lastRect.midY))
            let expected = NSAttributedString(string: lines.string).doubleClick(at: segmentLast)
            #expect(lines.selectedRange() == expected,
                    "lines selected \(lines.selectedRange()); doubleClick(segmentLast \(segmentLast)) = \(expected); next segment starts at \(NSMaxRange(segmentRange))")
        }
    }

    @Test func cursorRects_onlyTheVisibleLayoutRegistersThem() async throws {
        try await withSettings {
            DiffLayoutSettings.preference = .sideBySide
            let hosted = try await makeHosted(width: 1200)
            defer { hosted.close() }
            let view = hosted.view
            #expect(view.inlinePaneForTesting.isHidden && !view.leftPaneForTesting.isHiddenOrHasHiddenAncestor)
            #expect(view.inlinePaneForTesting.linesView.registeredCursorRegions.isEmpty,
                    "the hidden inline pane must not register cursor rects in side-by-side")
            #expect(!view.leftPaneForTesting.linesView.registeredCursorRegions.isEmpty)
            #expect(!view.rightPaneForTesting.linesView.registeredCursorRegions.isEmpty)

            DiffLayoutSettings.preference = .inline
            try await settle(hosted.window)
            #expect(!view.inlinePaneForTesting.isHidden)
            #expect(!view.inlinePaneForTesting.linesView.registeredCursorRegions.isEmpty)
            #expect(view.leftPaneForTesting.linesView.registeredCursorRegions.isEmpty,
                    "the hidden left pane must not register cursor rects in inline")
            #expect(view.rightPaneForTesting.linesView.registeredCursorRegions.isEmpty,
                    "the hidden right pane must not register cursor rects in inline")
        }
    }

    @Test(arguments: [true, false])
    func cursorRects_neverCoverTheGutter(wordWrap: Bool) async throws {
        try await withSettings(wordWrap: wordWrap) {
            let hosted = try await makeHosted(raw: makeLongLinesRaw())
            defer { hosted.close() }
            let pane = hosted.pane
            let lines = hosted.lines
            if !wordWrap {
                let clip = pane.scrollView.contentView
                #expect(lines.frame.width > clip.bounds.width + 600)
                clip.scroll(to: NSPoint(x: 600, y: clip.bounds.origin.y))
                pane.scrollView.reflectScrolledClipView(clip)
                try await settle(hosted.window)
                #expect(clip.bounds.origin.x == 600)
            }
            let gutter = pane.lineNumberView.convert(pane.lineNumberView.bounds, to: nil)
                .insetBy(dx: 0.5, dy: 0.5)
            #expect(gutter.width > 0)
            let regions = lines.registeredCursorRegions
            #expect(!regions.isEmpty)
            let covering = regions.map { lines.convert($0.rect, to: nil) }.filter { $0.intersects(gutter) }
            #expect(covering.isEmpty, "cursor rects \(covering) overlap the gutter \(gutter)")
        }
    }

    @Test func cursorRects_areInvalidatedWhenAPaneIsHiddenOrShown() async throws {
        try await withSettings {
            var spy: CursorInvalidationSpyWindow?
            let hosted = try await makeHosted(width: 1200, makeWindow: { rect in
                let window = CursorInvalidationSpyWindow(contentRect: rect, styleMask: [.titled, .resizable],
                                                         backing: .buffered, defer: false)
                spy = window
                return window
            })
            defer { hosted.close() }
            let window = try #require(spy)
            let view = hosted.view
            let inline = view.inlinePaneForTesting.linesView
            let left = view.leftPaneForTesting.linesView
            let right = view.rightPaneForTesting.linesView
            func recorded(_ target: NSView) -> Bool { window.invalidatedViews.contains { $0 === target } }

            window.invalidatedViews.removeAll()
            DiffLayoutSettings.preference = .sideBySide
            try await settle(window)
            #expect(view.inlinePaneForTesting.isHidden)
            #expect(recorded(inline), "hiding the inline pane must invalidate its cursor rects")
            #expect(recorded(left), "showing the left pane must invalidate its cursor rects")
            #expect(recorded(right), "showing the right pane must invalidate its cursor rects")

            window.invalidatedViews.removeAll()
            DiffLayoutSettings.preference = .inline
            try await settle(window)
            #expect(!view.inlinePaneForTesting.isHidden)
            #expect(recorded(inline), "showing the inline pane must invalidate its cursor rects")
            #expect(recorded(left), "hiding the left pane must invalidate its cursor rects")
            #expect(recorded(right), "hiding the right pane must invalidate its cursor rects")
        }
    }

    private func rawContentLines(_ raw: String, excluding excluded: Character? = nil) -> [String] {
        raw.components(separatedBy: "\n")
            .drop { !$0.hasPrefix("@@") }
            .dropFirst()
            .filter { !$0.isEmpty && $0.first != excluded }
            .map { String($0.dropFirst()) }
    }

    @Test func paneStrings_inlineRowsAreTheFileContentWithoutMarkers() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let rows = hosted.lines.string.components(separatedBy: "\n")
            #expect(rows == rawContentLines(makeLinesRaw()))
            #expect(rows[4] == "plain line 5")
            #expect(rows[99] == "old line 100")
            #expect(rows[100] == "new line 100")
        }
    }

    @Test func paneStrings_sideBySideRowsAreEachSidesContentWithoutMarkers() async throws {
        try await withSettings {
            DiffLayoutSettings.preference = .sideBySide
            let hosted = try await makeHosted(width: 1200)
            defer { hosted.close() }
            let left = hosted.view.leftPaneForTesting.linesView.string.components(separatedBy: "\n")
            let right = hosted.view.rightPaneForTesting.linesView.string.components(separatedBy: "\n")
            #expect(left == rawContentLines(makeLinesRaw(), excluding: "+"))
            #expect(right == rawContentLines(makeLinesRaw(), excluding: "-"))
            #expect(left[4] == "plain line 5" && right[4] == "plain line 5")
            #expect(left[99] == "old line 100")
            #expect(right[99] == "new line 100")
        }
    }

    @Test func selectAllCopy_writesContentWithoutMarkers() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            hosted.lines.selectAll(nil)
            hosted.lines.copy(nil)
            let copied = try #require(hosted.pasteboard.string(forType: .string))
            let rows = copied.components(separatedBy: "\n")
            #expect(rows == rawContentLines(makeLinesRaw()))
            #expect(rows.first == "plain line 1")
            #expect(rows[9] == "alpha needle omega 10")
            #expect(rows[99] == "old line 100")
            #expect(rows[100] == "new line 100")
        }
    }

    @Test func accessibilityValue_hasNoMarkerAtRowStarts() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let value = try #require(hosted.lines.accessibilityValue() as? String)
            let rows = value.components(separatedBy: "\n")
            #expect(rows == rawContentLines(makeLinesRaw()))
            #expect(!rows.contains { $0.hasPrefix("+") || $0.hasPrefix("-") || $0.hasPrefix(" ") })
        }
    }

    @Test func tripleClickAddedLine_copiesItsContentAndLineBreak() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let added = try range(of: "new line 100", in: lines.string)
            try await click(lines, at: try point(inside: added.location + 1, lines), clickCount: 3)
            lines.copy(nil)
            #expect(hosted.pasteboard.string(forType: .string) == "new line 100\n")
        }
    }

    private func backgroundRuns(_ lines: DiffLinesView, in rowRange: NSRange) -> [NSRange] {
        var found: [NSRange] = []
        lines.text.attributed.enumerateAttribute(.backgroundColor, in: rowRange) { value, range, _ in
            if value != nil { found.append(range) }
        }
        return found
    }

    @Test func innerChangeBackground_coversExactlyTheChangedWord() async throws {
        try await withSettings {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let lines = hosted.lines
            let ranges = rowRanges(lines.string)
            let oldRow = try range(of: "old line 100", in: lines.string)
            let newRow = try range(of: "new line 100", in: lines.string)
            #expect(ranges.contains(oldRow), "the deleted row is exactly its content")
            #expect(ranges.contains(newRow), "the added row is exactly its content")
            #expect(backgroundRuns(lines, in: oldRow) == [NSRange(location: oldRow.location, length: 3)])
            #expect(backgroundRuns(lines, in: newRow) == [NSRange(location: newRow.location, length: 3)])
            #expect(backgroundRuns(lines, in: oldRow) == [try range(of: "old", in: lines.string)])
        }
    }

    @Test func wrappedLineRowContinuation_startsAtTheTextInsetPlusIndent() async throws {
        try await withSettings(wordWrap: true) {
            let hosted = try await makeHosted(raw: makeLongLinesRaw())
            defer { hosted.close() }
            let lines = hosted.lines
            hosted.window.setContentSize(NSSize(width: 250, height: 400))
            try await settle(hosted.window)
            let ranges = rowRanges(lines.string)
            let row = try #require(ranges.indices.first { (lines.projections[$0]?.segmentCount ?? 1) >= 2 })
            let projection = try #require(lines.projections[row])
            #expect(lines.rowTexts[row].markerLength == 0)
            #expect(lines.rowTexts[row].markerColumns == 0)
            #expect(projection.wrappedTextIndentLength == 0)
            let breakIndex = ranges[row].location + projection.breakOffsets[0]
            let rect = try characterRect(lines, breakIndex)
            let expected = DiffMetrics.textInset.width + CGFloat(projection.wrappedTextIndentLength) * DiffMetrics.columnWidth
            #expect(abs(rect.minX - expected) <= 0.5, "continuation starts at \(rect.minX), expected \(expected)")
        }
    }

    @Test func wrappedCommentRowContinuation_keepsItsMarkerColumns() async throws {
        try await withSettings(wordWrap: true) {
            let note = String(repeating: "long review note ", count: 20)
            var configured: Result<Void, Error> = .success(())
            let hosted = try await makeHosted(raw: makeLongLinesRaw()) { view, diff in
                configured = Result {
                    let store = view.reviewStore ?? DiffReviewStore()
                    view.reviewStore = store
                    let index = try #require(diff.lines.firstIndex { $0.type == .context && $0.newLineNumber == 5 })
                    store.addComment(lineIndex: index, lineNumber: 5, oldLineNumber: diff.lines[index].oldLineNumber,
                                     lineType: .context, text: note)
                }
            }
            defer { hosted.close() }
            try configured.get()
            let lines = hosted.lines
            hosted.window.setContentSize(NSSize(width: 250, height: 400))
            try await settle(hosted.window)
            let ranges = rowRanges(lines.string)
            let row = try #require(lines.cells.indices.first { lines.cells[$0]?.kind == .comment })
            let projection = try #require(lines.projections[row])
            #expect(projection.segmentCount >= 2)
            #expect(lines.rowTexts[row].markerColumns == 3)
            let breakIndex = ranges[row].location + lines.rowTexts[row].markerLength + projection.breakOffsets[0]
            let rect = try characterRect(lines, breakIndex)
            let expected = DiffMetrics.textInset.width
                + CGFloat(3 + projection.wrappedTextIndentLength) * DiffMetrics.columnWidth
            #expect(abs(rect.minX - expected) <= 0.5, "comment continuation starts at \(rect.minX), expected \(expected)")
        }
    }

    @Test func blankAddedLine_isAZeroLengthRow() async throws {
        try await withSettings {
            let raw = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1,2 +1,3 @@\n a\n+\n b\n"
            let hosted = try await makeHosted(raw: raw)
            defer { hosted.close() }
            #expect(hosted.lines.string == "a\n\nb")
            #expect(rowRanges(hosted.lines.string)[1].length == 0)
            #expect(hosted.lines.rowTexts[1].markerLength == 0)
        }
    }

}
}
