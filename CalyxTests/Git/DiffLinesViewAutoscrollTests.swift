import AppKit
import XCTest
@testable import Calyx

@MainActor
final class DiffLinesViewAutoscrollTests: XCTestCase {
    private let suiteName = "com.calyx.tests.DiffLinesViewAutoscrollTests"
    private var window: NSWindow?

    override func setUp() async throws {
        try await super.setUp()
        DiffLayoutSettings._testUseSuite(named: suiteName)
        DiffLayoutSettings.preference = .inline
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        DiffLayoutSettings.wordWrap = true
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window?.close()
        window = nil
        DiffLayoutSettings._testTeardownSuite(named: suiteName)
        try await super.tearDown()
    }

    private static func rawDiff(rows: Int, changedRow: Int) -> String {
        var out = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1,\(rows) +1,\(rows) @@\n"
        for n in 1...rows {
            out += n == changedRow ? "-old row \(n)\n+new row \(n)\n" : " row \(n) of many plain words\n"
        }
        return out
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private func hostDiffView(contentHeight: CGFloat,
                              raw: String = rawDiff(rows: 400, changedRow: 300)) -> DiffView {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: contentHeight),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = DiffView(frame: NSRect(x: 0, y: 0, width: 800, height: contentHeight))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFront(nil)
        self.window = window
        view.display(diff: DiffParser.parse(raw, path: "l.txt"))
        settle(window)
        return view
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in lines: DiffLinesView) throws -> NSEvent {
        let window = try XCTUnwrap(lines.window)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: lines.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func dragSelect(_ lines: DiffLinesView, from start: NSPoint, to end: NSPoint) throws {
        NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: end, in: lines), atStart: false)
        NSApp.postEvent(try mouseEvent(.leftMouseUp, at: end, in: lines), atStart: false)
        lines.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: lines))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func assertDragInsideVisibleBodyKeepsOrigin(_ pane: DiffPaneView,
                                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let clip = pane.scrollView.contentView
        let lines = pane.linesView
        let visible = lines.visibleRect
        let before = clip.bounds.origin
        try dragSelect(lines, from: NSPoint(x: 120, y: visible.midY - 20), to: NSPoint(x: 260, y: visible.midY + 20))
        XCTAssertGreaterThan(lines.selectedRange().length, 0, "the drag must select text", file: file, line: line)
        XCTAssertEqual(clip.bounds.origin, before,
                       "a drag that stays inside the visible body must not scroll (backing scale \(lines.window?.backingScaleFactor ?? 0))",
                       file: file, line: line)
    }

    func test_dragInsideVisibleBody_afterNextChangeCentresTheChangeInAnOddHeightViewport_keepsScrollOrigin() throws {
        let view = hostDiffView(contentHeight: 400)
        let window = try XCTUnwrap(view.window)
        window.setContentSize(NSSize(width: 800, height: 401))
        settle(window)
        view.goToDiff(.next)
        settle(window)
        let pane = view.inlinePaneForTesting
        XCTAssertTrue(pane.visibleRowRange.contains(299), "Next Change must reveal the change on row 300")
        try assertDragInsideVisibleBodyKeepsOrigin(pane)
    }

    func test_dragInsideVisibleBody_atHalfBackingPixelScrollOrigin_keepsScrollOrigin() throws {
        let view = hostDiffView(contentHeight: 400)
        let pane = view.inlinePaneForTesting
        let scale = try XCTUnwrap(pane.window).backingScaleFactor
        pane.scroll(toY: 2000 + 0.5 / scale)
        settle(try XCTUnwrap(pane.window))
        XCTAssertEqual(pane.scrollView.contentView.bounds.origin.y, 2000 + 0.5 / scale)
        try assertDragInsideVisibleBodyKeepsOrigin(pane)
    }

    private static func longLinesRawDiff(rows: Int) -> String {
        var out = "diff --git a/l.txt b/l.txt\n--- a/l.txt\n+++ b/l.txt\n@@ -1,\(rows) +1,\(rows) @@\n"
        for n in 1...rows { out += " \(String(repeating: "wide words \(n) ", count: 40))\n" }
        return out
    }

    private func holdDrag(_ lines: DiffLinesView, from start: NSPoint, to held: NSPoint,
                          checkingHeldPoint check: (NSPoint) -> Void) throws {
        let clip = try XCTUnwrap(lines.enclosingScrollView?.contentView)
        check(clip.convert(lines.convert(held, to: nil), from: nil))
        let releaseLocation = lines.convert(held, to: nil)
        let windowNumber = try XCTUnwrap(lines.window).windowNumber
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard let release = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: releaseLocation, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0) else { return }
                NSApp.postEvent(release, atStart: false)
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        NSApp.postEvent(try mouseEvent(.leftMouseDragged, at: held, in: lines), atStart: false)
        lines.mouseDown(with: try mouseEvent(.leftMouseDown, at: start, in: lines))
        timer.invalidate()
        while let leftover = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { _ = leftover }
    }

    func test_dragIntoTheGutter_whileScrolledRightWithoutWordWrap_scrollsLeft() throws {
        DiffLayoutSettings.wordWrap = false
        let view = hostDiffView(contentHeight: 400, raw: Self.longLinesRawDiff(rows: 40))
        let window = try XCTUnwrap(view.window)
        let pane = view.inlinePaneForTesting
        let clip = pane.scrollView.contentView
        let lines = pane.linesView
        XCTAssertGreaterThan(clip.contentInsets.left, 0, "the line-number ruler must inset the clip")
        clip.scroll(to: NSPoint(x: 1500, y: clip.bounds.origin.y))
        pane.scrollView.reflectScrolledClipView(clip)
        settle(window)
        let before = clip.bounds.origin
        XCTAssertGreaterThan(before.x, 1000, "the clip must be scrolled right")
        let insetLeft = clip.contentInsets.left
        let gutterInClip = NSPoint(x: clip.bounds.minX + insetLeft / 2, y: clip.bounds.midY)
        let start = lines.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), from: clip)
        let held = lines.convert(gutterInClip, from: clip)
        try holdDrag(lines, from: start, to: held) { inClip in
            XCTAssertTrue(clip.bounds.contains(inClip), "held point \(inClip) must be inside clip bounds \(clip.bounds)")
            XCTAssertLessThan(inClip.x, clip.bounds.minX + insetLeft,
                              "held point \(inClip) must be inside the left inset \(insetLeft)")
        }
        XCTAssertLessThan(clip.bounds.origin.x, before.x,
                          "holding the drag over the gutter must scroll left: \(clip.bounds.origin.x) vs \(before.x)")
    }

    func test_dragOverTheFindBar_scrollsUp() throws {
        let view = hostDiffView(contentHeight: 400)
        let pane = view.inlinePaneForTesting
        let window = try XCTUnwrap(pane.window)
        let clip = pane.scrollView.contentView
        let lines = pane.linesView
        lines.textFinder.performAction(.showFindInterface)
        settle(window)
        XCTAssertTrue(pane.scrollView.isFindBarVisible)
        let insetTop = clip.contentInsets.top
        XCTAssertGreaterThan(insetTop, 0, "the find bar must inset the clip")
        pane.scroll(toY: 3000)
        settle(window)
        let before = clip.bounds.origin
        XCTAssertGreaterThan(before.y, 1000, "the clip must be scrolled into the middle")
        let findBarInClip = NSPoint(x: clip.bounds.midX, y: clip.bounds.minY + insetTop / 2)
        let start = lines.convert(NSPoint(x: 200, y: clip.bounds.midY), from: clip)
        let held = lines.convert(findBarInClip, from: clip)
        try holdDrag(lines, from: start, to: held) { inClip in
            XCTAssertTrue(clip.bounds.contains(inClip), "held point \(inClip) must be inside clip bounds \(clip.bounds)")
            XCTAssertLessThan(inClip.y, clip.bounds.minY + insetTop,
                              "held point \(inClip) must be inside the top inset \(insetTop)")
        }
        XCTAssertLessThan(clip.bounds.origin.y, before.y,
                          "holding the drag over the find bar must scroll up: \(clip.bounds.origin.y) vs \(before.y)")
    }

    func test_dragHeldInsideVisibleBody_atHalfBackingPixelScrollOrigin_keepsScrollOrigin() throws {
        let view = hostDiffView(contentHeight: 400)
        let pane = view.inlinePaneForTesting
        let window = try XCTUnwrap(pane.window)
        let scale = window.backingScaleFactor
        pane.scroll(toY: 2000 + 0.5 / scale)
        settle(window)
        let clip = pane.scrollView.contentView
        XCTAssertEqual(clip.bounds.origin.y, 2000 + 0.5 / scale)
        let lines = pane.linesView
        let visible = lines.visibleRect
        let before = clip.bounds.origin
        try holdDrag(lines, from: NSPoint(x: 120, y: visible.midY - 20), to: NSPoint(x: 260, y: visible.midY + 20)) { inClip in
            XCTAssertTrue(clip.bounds.contains(inClip))
        }
        XCTAssertGreaterThan(lines.selectedRange().length, 0, "the drag must select text")
        XCTAssertEqual(clip.bounds.origin, before, "a drag held inside the visible body must not scroll (backing scale \(scale))")
    }
}
