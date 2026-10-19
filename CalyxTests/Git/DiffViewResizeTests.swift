import AppKit
import Foundation
import Testing
@testable import Calyx

private let longContextWords = "alpha beta gamma delta epsilon zeta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega"

private func longLine(_ n: Int) -> String {
    "\(n) " + longContextWords + " " + longContextWords
}

private func shortLine(_ n: Int) -> String {
    let base = "line \(n) the quick brown fox jumps over the lazy dog and keeps running far away"
    return String(base.prefix(78))
}

private let changedModifiedLines = [300, 1800, 2600]

private func makeResizeDiff() -> FileDiff {
    var raw = "diff --git a/r.txt b/r.txt\n--- a/r.txt\n+++ b/r.txt\n@@ -1,3000 +1,3000 @@\n"
    for n in 1...3000 {
        let text = n % 10 == 0 ? longLine(n) : shortLine(n)
        if changedModifiedLines.contains(n) {
            raw += "-\(text)\n+changed \(text)\n"
        } else {
            raw += " \(text)\n"
        }
    }
    return DiffParser.parse(raw, path: "r.txt")
}

private final class ResizeTestWindow: NSWindow {
    var isLiveResizing = false
    override var inLiveResize: Bool { isLiveResizing }
}

private struct VisibleStart: Equatable, CustomStringConvertible {
    let row: Int
    let offset: Int
    let delta: CGFloat
    var description: String { "row \(row) offset \(offset) delta \(String(format: "%.2f", delta))" }
}

extension DiffViewWindowedSuites {

@MainActor
@Suite(.serialized)
struct DiffViewResizeTests {

    private let suiteName = "com.calyx.tests.DiffViewResizeTests"
    private let startWidth: CGFloat = 1035
    private let height: CGFloat = 900
    private let topDelta: CGFloat = 5

    private func topContextLine(_ view: DiffView) -> Int {
        view.currentLayout == .sideBySide ? 280 : 270
    }

    private func widthSteps() -> [CGFloat] {
        Array(stride(from: startWidth - 15, through: 572, by: -15)) + [572]
            + Array(stride(from: 587, through: 769, by: 15)) + [769]
    }

    private func withSettings(_ preference: DiffLayoutPreference, _ body: () async throws -> Void) async rethrows {
        DiffLayoutSettings._testUseSuite(named: suiteName)
        defer { DiffLayoutSettings._testTeardownSuite(named: suiteName) }
        DiffLayoutSettings.preference = preference
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        DiffLayoutSettings.wordWrap = true
        DiffLayoutSettings.renderOverviewRuler = true
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

    private func makeHosted() async throws -> (ResizeTestWindow, DiffView) {
        let window = ResizeTestWindow(contentRect: NSRect(x: 60, y: 60, width: startWidth, height: height),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        let view = DiffView(frame: NSRect(x: 0, y: 0, width: startWidth, height: height))
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.orderFront(nil)
        view.display(diff: makeResizeDiff())
        try await settle(window)
        return (window, view)
    }

    private func modifiedPane(_ view: DiffView) -> DiffPaneView {
        view.currentLayout == .sideBySide ? view.rightPaneForTesting : view.inlinePaneForTesting
    }

    private func visibleStart(_ pane: DiffPaneView) throws -> VisibleStart {
        let lines = pane.linesView
        let top = pane.scrollView.documentVisibleRect.minY
        let (row, segment) = lines.geometry.segment(atY: top)
        let offset = segment == 0 ? 0 : try #require(lines.projections[row]).breakOffsets[segment - 1]
        let start = VisibleStart(row: row, offset: offset, delta: top - lines.geometry.segmentTop(row: row, segment: segment))
        if let reported = pane.viewportStart() {
            #expect(reported.row == start.row && reported.offset == start.offset && abs(reported.delta - start.delta) <= 0.5,
                    "viewportStart() \(reported) must describe the visible top \(start)")
        } else {
            Issue.record("viewportStart() is nil while scrolled to \(top)")
        }
        return start
    }

    private func rowTops(_ pane: DiffPaneView) -> [CGFloat] {
        let geometry = pane.linesView.geometry
        return (0..<geometry.rowCount).map(geometry.rowTop)
    }

    private func caretRow(_ view: DiffView) -> Int? {
        modifiedPane(view).selectionStartRow
    }

    private func positionAnchor(_ view: DiffView) async throws {
        let window = try #require(view.window)
        let pane = modifiedPane(view)
        let row = try #require(view.row(forModifiedLine: topContextLine(view)))
        pane.scroll(toY: rowTops(pane)[row] + topDelta)
        try await settle(window)
    }

    private func setWidth(_ window: NSWindow, _ width: CGFloat) {
        var frame = window.frame
        frame.size.width = width
        window.setFrame(frame, display: false)
        window.layoutIfNeeded()
    }

    private func forEachView(_ view: NSView, _ body: (NSView) -> Void) {
        body(view)
        for sub in view.subviews { forEachView(sub, body) }
    }

    private func expectAligned(_ view: DiffView, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        guard view.currentLayout == .sideBySide else { return }
        let left = rowTops(view.leftPaneForTesting)
        let right = rowTops(view.rightPaneForTesting)
        guard left.count == right.count else {
            Issue.record("\(label): row counts differ \(left.count) vs \(right.count)", sourceLocation: sourceLocation)
            return
        }
        let misaligned = view.blocksForTesting.map(\.lowerBound).filter { abs(left[$0] - right[$0]) > 0.5 }
        #expect(misaligned.isEmpty, "\(label): \(misaligned.count) block starts misaligned, first \(misaligned.first.map { "row \($0) left \(left[$0]) right \(right[$0])" } ?? "")", sourceLocation: sourceLocation)
    }

    private func expectSameStart(_ expected: VisibleStart, _ view: DiffView, _ label: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) throws {
        let pane = modifiedPane(view)
        let actual = try visibleStart(pane)
        let centre = pane.rowIndexAtViewportCentre
        let detail = "\(label): expected \(expected), got \(actual); caret row \(caretRow(view).map(String.init) ?? "nil"), viewport centre row \(centre.map(String.init) ?? "nil")"
        #expect(actual.row == expected.row && actual.offset == expected.offset, "\(detail)", sourceLocation: sourceLocation)
        #expect(abs(actual.delta - expected.delta) <= 0.5, "\(detail)", sourceLocation: sourceLocation)
    }

    private func prepare(_ preference: DiffLayoutPreference) async throws -> (ResizeTestWindow, DiffView, VisibleStart) {
        let (window, view) = try await makeHosted()
        #expect(view.currentChangeIndex == 0, "reveal-first-change must have run")
        let changeRow = try #require(view.row(forModifiedLine: changedModifiedLines[0]))
        #expect(caretRow(view) == changeRow, "the caret sits on the first change, as placed by the reveal")
        try await positionAnchor(view)
        let pane = modifiedPane(view)
        let start = try visibleStart(pane)
        let topRow = try #require(view.row(forModifiedLine: topContextLine(view)))
        #expect(start.row == topRow && start.offset == 0 && abs(start.delta - topDelta) <= 0.5, "setup start \(start)")
        let visible = pane.scrollView.documentVisibleRect
        let caretTop = rowTops(pane)[changeRow]
        #expect(caretTop > visible.midY && caretTop + DiffMetrics.rowHeight < visible.maxY,
                "the caret must be visible in the lower half of the viewport (caret y \(caretTop), viewport \(visible.minY)...\(visible.maxY))")
        #expect(pane.scrollView.documentView === pane.linesView)
        let topRowHeight = pane.linesView.geometry.rowHeight(topRow)
        #expect(topRowHeight > DiffMetrics.rowHeight * 1.5, "the top row must be wrapped")
        return (window, view, start)
    }

    private func runPlainSteps(_ preference: DiffLayoutPreference) async throws {
        try await withSettings(preference) {
            let (window, view, expected) = try await prepare(preference)
            defer { window.orderOut(nil); window.close() }
            for width in widthSteps() {
                setWidth(window, width)
                try expectSameStart(expected, view, "width \(width)")
                expectAligned(view, "width \(width)")
            }
            try await settle(window)
            try expectSameStart(expected, view, "after the steps settled")
            expectAligned(view, "after the steps settled")
        }
    }

    private func runLiveResize(_ preference: DiffLayoutPreference) async throws {
        try await withSettings(preference) {
            let (window, view, expected) = try await prepare(preference)
            defer { window.orderOut(nil); window.close() }
            let content = try #require(window.contentView)
            window.isLiveResizing = true
            forEachView(content) { $0.viewWillStartLiveResize() }
            for width in widthSteps() {
                setWidth(window, width)
                window.displayIfNeeded()
                try expectSameStart(expected, view, "live width \(width)")
                expectAligned(view, "live width \(width)")
            }
            window.isLiveResizing = false
            forEachView(content) { $0.viewDidEndLiveResize() }
            try expectSameStart(expected, view, "right after viewDidEndLiveResize")
            expectAligned(view, "right after viewDidEndLiveResize")
            try await settle(window)
            try expectSameStart(expected, view, "after viewDidEndLiveResize settled")
            expectAligned(view, "after viewDidEndLiveResize settled")
        }
    }

    private func runTiming(_ preference: DiffLayoutPreference) async throws {
        try await withSettings(preference) {
            let (window, _, _) = try await prepare(preference)
            defer { window.orderOut(nil); window.close() }
            let clock = ContinuousClock()
            var samples: [Double] = []
            for (index, width) in widthSteps().enumerated() {
                let elapsed = clock.measure { setWidth(window, width) }
                if index >= 5 {
                    samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                }
            }
            #expect(samples.count >= 20)
            let median = samples.sorted()[samples.count / 2]
            print("RESIZE-MEDIAN \(preference) \(String(format: "%.2f", median)) ms")
            #expect(median < 8, "median width change \(String(format: "%.1f", median)) ms (samples \(samples.map { String(format: "%.0f", $0) }.joined(separator: ",")))")
        }
    }

    @Test func fixtureSanity() {
        let diff = makeResizeDiff()
        #expect(diff.newLineCount == 3000)
        #expect(diff.changes.map(\.modified.startLineNumber) == changedModifiedLines)
        #expect(longLine(280).count > 200)
        #expect(widthSteps().count >= 40)
    }

    @Test func restore_scrollsBackToCapturedViewportStart() async throws {
        try await withSettings(.inline) {
            let (window, view, expected) = try await prepare(.inline)
            defer { window.orderOut(nil); window.close() }
            let pane = modifiedPane(view)
            let captured = try #require(pane.viewportStart())
            #expect(captured.row == expected.row && captured.offset == expected.offset)
            #expect(abs(captured.delta - expected.delta) <= 0.5)
            pane.scroll(toY: 0)
            #expect(pane.viewportStart() == nil, "scrollY 0 has no viewport start (VS Code)")
            pane.scroll(toY: pane.scrollY(for: captured))
            try expectSameStart(expected, view, "after restore")
        }
    }

    @Test func inline_plainResize_keepsFirstVisibleWrappedLine() async throws {
        try await runPlainSteps(.inline)
    }

    @Test func sideBySide_plainResize_keepsFirstVisibleWrappedLineAndAlignment() async throws {
        try await runPlainSteps(.sideBySide)
    }

    @Test func inline_liveResize_keepsFirstVisibleWrappedLine() async throws {
        try await runLiveResize(.inline)
    }

    @Test func sideBySide_liveResize_keepsFirstVisibleWrappedLineAndAlignment() async throws {
        try await runLiveResize(.sideBySide)
    }

    @Test func inline_widthChange_medianUnder8ms() async throws {
        try await runTiming(.inline)
    }

    @Test func sideBySide_widthChange_medianUnder8ms() async throws {
        try await runTiming(.sideBySide)
    }
    private func crossBreakpoint(from startPreference: DiffLayout, to width: CGFloat) async throws {
        try await withSettings(.automatic) {
            let (window, view) = try await makeHosted()
            defer { window.orderOut(nil); window.close() }
            if startPreference == .inline {
                var frame = window.frame
                frame.size.width = 800
                window.setFrame(frame, display: false)
                try await settle(window)
            }
            #expect(view.currentLayout == startPreference)
            try await positionAnchor(view)
            let before = try visibleStart(modifiedPane(view))
            view.setFrameSize(NSSize(width: width, height: view.frame.height))
            view.layoutSubtreeIfNeeded()
            let expected: DiffLayout = startPreference == .inline ? .sideBySide : .inline
            #expect(view.currentLayout == expected, "the new layout is installed in the same pass")
            #expect(modifiedPane(view).window != nil)
            try expectSameStart(before, view, "after crossing 900 pt to \(width)")
        }
    }

    private func constraintIDs(_ view: DiffView) -> Set<ObjectIdentifier> {
        var views: [NSView] = [view]
        var ids = Set<ObjectIdentifier>()
        while let next = views.popLast() {
            if next is NSScrollView { continue }
            ids.formUnion(next.constraints.filter { String(describing: type(of: $0)) != "NSAutoresizingMaskLayoutConstraint" }
                .map(ObjectIdentifier.init))
            views.append(contentsOf: next.subviews)
        }
        return ids
    }

    private func activePanes(_ view: DiffView) -> [DiffPaneView] {
        view.currentLayout == .sideBySide ? [view.leftPaneForTesting, view.rightPaneForTesting] : [view.inlinePaneForTesting]
    }

    private func switchOnce(from startWidth: CGFloat, to width: CGFloat) async throws {
        try await withSettings(.automatic) {
            let (window, view) = try await makeHosted()
            defer { window.orderOut(nil); window.close() }
            setWidth(window, startWidth)
            try await settle(window)
            try await positionAnchor(view)
            let before = try visibleStart(modifiedPane(view))
            let startLayout = view.currentLayout
            let constraintsBefore = constraintIDs(view)
            let panes = [view.inlinePaneForTesting, view.leftPaneForTesting, view.rightPaneForTesting]
            let rewrapsBefore = panes.map(\.linesView.rewrapCountForTesting)
            setWidth(window, width)
            #expect(view.currentLayout != startLayout, "\(startWidth) to \(width) switches the layout")
            for (pane, count) in zip(panes, rewrapsBefore) {
                let isActive = activePanes(view).contains { $0 === pane }
                #expect(pane.linesView.rewrapCountForTesting - count == (isActive ? 1 : 0),
                        "\(pane.side) pane rewraps \(pane.linesView.rewrapCountForTesting - count) times")
            }
            #expect(constraintsBefore.isEmpty, "the content is frame-positioned before the switch")
            #expect(constraintIDs(view) == constraintsBefore, "no constraint is added or removed by the switch")
            for sub in view.subviews {
                #expect(sub.translatesAutoresizingMaskIntoConstraints, "\(type(of: sub)) is frame-positioned")
            }
            try expectSameStart(before, view, "after \(startWidth) to \(width)")
            try await settle(window)
            for (pane, count) in zip(panes, rewrapsBefore) {
                let isActive = activePanes(view).contains { $0 === pane }
                #expect(pane.linesView.rewrapCountForTesting - count == (isActive ? 1 : 0), "no second rewrap after settling")
            }
            try expectSameStart(before, view, "after \(startWidth) to \(width) settled")
        }
    }

    @Test func automaticSwitch_1200to800_rewrapsOncePerPaneWithoutConstraintChanges() async throws {
        try await switchOnce(from: 1200, to: 800)
    }

    @Test func automaticSwitch_800to1200_rewrapsOncePerPaneWithoutConstraintChanges() async throws {
        try await switchOnce(from: 800, to: 1200)
    }

    @Test func automaticSwitch_sideBySideToInline_inTheResizeFrame() async throws {
        try await crossBreakpoint(from: .sideBySide, to: 800)
    }

    @Test func automaticSwitch_inlineToSideBySide_inTheResizeFrame() async throws {
        try await crossBreakpoint(from: .inline, to: 1035)
    }

    @Test func automaticSwitch_oscillatingCrossings_medianUnder8msMaxUnder16msOnePassEach() async throws {
        try await withSettings(.automatic) {
            let (window, view, _) = try await prepare(.automatic)
            defer { window.orderOut(nil); window.close() }
            #expect(view.currentLayout == .sideBySide)
            let clock = ContinuousClock()
            let downSweep = Array(stride(from: startWidth - 15, through: 780, by: -15))
            let upSweep = Array(stride(from: downSweep[downSweep.count - 1] + 15, through: startWidth, by: 15))
            let start = try visibleStart(modifiedPane(view))
            var samples: [Double] = []
            for cycle in 0..<10 {
                for (direction, sweep) in [("down", downSweep), ("up", upSweep)] {
                    var ordinaryFramesSinceCrossing = 0
                    var crossings = 0
                    for width in sweep {
                        let label = "cycle \(cycle) \(direction) to \(width)"
                        let layoutBefore = view.currentLayout
                        let passesBefore = view.geometryPassCountForTesting
                        let elapsed = clock.measure { setWidth(window, width) }
                        if view.currentLayout != layoutBefore {
                            crossings += 1
                            #expect(ordinaryFramesSinceCrossing >= 5, "\(label): \(ordinaryFramesSinceCrossing) ordinary frames before the crossing")
                            #expect(view.geometryPassCountForTesting - passesBefore == 1,
                                    "\(label) ran \(view.geometryPassCountForTesting - passesBefore) geometry passes")
                            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
                            ordinaryFramesSinceCrossing = 0
                        } else {
                            ordinaryFramesSinceCrossing += 1
                        }
                        try expectSameStart(start, view, label)
                    }
                    #expect(crossings == 1, "cycle \(cycle) \(direction) crossed \(crossings) times")
                    #expect(view.currentLayout == (direction == "down" ? .inline : .sideBySide))
                    let passesAfterSweep = view.geometryPassCountForTesting
                    try await settle(window)
                    #expect(view.geometryPassCountForTesting == passesAfterSweep,
                            "cycle \(cycle) \(direction) needed \(view.geometryPassCountForTesting - passesAfterSweep) more passes after the sweep")
                    try expectSameStart(start, view, "cycle \(cycle) \(direction) settled")
                }
            }
            #expect(samples.count == 20)
            let sorted = samples.sorted()
            let median = sorted[sorted.count / 2]
            let maximum = sorted[sorted.count - 1]
            let list = samples.map { String(format: "%.0f", $0) }.joined(separator: ",")
            print("CROSSING-MEDIAN \(String(format: "%.2f", median)) ms max \(String(format: "%.2f", maximum)) ms")
            #expect(median < 8, "median crossing frame \(String(format: "%.1f", median)) ms (samples \(list))")
            #expect(maximum < 16, "max crossing frame \(String(format: "%.1f", maximum)) ms (samples \(list))")
        }
    }


    private final class ResponderLog {
        var responders: [NSResponder?] = []
    }

    private func hostedFocusView(startingIn layout: DiffLayout) async throws -> (ResizeTestWindow, DiffView) {
        let (window, view) = try await makeHosted()
        if layout == .inline {
            setWidth(window, 880)
            try await settle(window)
        }
        #expect(view.currentLayout == layout)
        return (window, view)
    }

    private func focusCaret(_ window: NSWindow, _ pane: DiffPaneView, _ view: DiffView, modifiedLine: Int) throws {
        #expect(window.makeFirstResponder(pane.linesView))
        let row = try #require(view.row(forModifiedLine: modifiedLine))
        pane.placeInsertionPoint(atRow: row)
        #expect(view.currentModifiedLine() == modifiedLine)
    }

    private func crossLoggingResponders(_ window: NSWindow, to width: CGFloat) -> [NSResponder?] {
        let log = ResponderLog()
        let observation = window.observe(\.firstResponder, options: [.new]) { observed, _ in
            log.responders.append(observed.firstResponder)
        }
        setWidth(window, width)
        observation.invalidate()
        return log.responders
    }

    @Test func layoutSwitch_inlineFocus_movesToCaretPaneOnTheSameLine() async throws {
        try await withSettings(.automatic) {
            let (window, view) = try await hostedFocusView(startingIn: .inline)
            defer { window.orderOut(nil); window.close() }
            try focusCaret(window, view.inlinePaneForTesting, view, modifiedLine: changedModifiedLines[1])
            let responders = crossLoggingResponders(window, to: 1035)
            #expect(view.currentLayout == .sideBySide)
            let target = view.rightPaneForTesting.linesView
            #expect(window.firstResponder === target, "first responder \(String(describing: window.firstResponder))")
            #expect(view.currentModifiedLine() == changedModifiedLines[1])
            let strays = responders.compactMap { $0 }.filter { !($0 is NSWindow) && $0 !== target }
            #expect(strays.isEmpty, "responders in between: \(strays)")
        }
    }

    @Test(arguments: [DiffSide.left, .right])
    func layoutSwitch_sideBySideFocus_movesToInlinePaneOnTheSameLine(side: DiffSide) async throws {
        try await withSettings(.automatic) {
            let (window, view) = try await hostedFocusView(startingIn: .sideBySide)
            defer { window.orderOut(nil); window.close() }
            let pane = side == .left ? view.leftPaneForTesting : view.rightPaneForTesting
            try focusCaret(window, pane, view, modifiedLine: changedModifiedLines[1])
            let responders = crossLoggingResponders(window, to: 880)
            #expect(view.currentLayout == .inline)
            let target = view.inlinePaneForTesting.linesView
            #expect(window.firstResponder === target, "first responder \(String(describing: window.firstResponder))")
            #expect(view.currentModifiedLine() == changedModifiedLines[1])
            let strays = responders.compactMap { $0 }.filter { !($0 is NSWindow) && $0 !== target }
            #expect(strays.isEmpty, "responders in between: \(strays)")
        }
    }

    @Test(arguments: [DiffLayout.inline, .sideBySide])
    func layoutSwitch_focusOutsideTheDiff_staysWhereItIs(start: DiffLayout) async throws {
        try await withSettings(.automatic) {
            let (window, view) = try await hostedFocusView(startingIn: start)
            defer { window.orderOut(nil); window.close() }
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
            view.addSubview(field)
            #expect(window.makeFirstResponder(field))
            let focused = window.firstResponder
            let responders = crossLoggingResponders(window, to: start == .inline ? 1035 : 880)
            #expect(view.currentLayout != start)
            #expect(window.firstResponder === focused, "first responder \(String(describing: window.firstResponder))")
            let strays = responders.compactMap { $0 }.filter { !($0 is NSWindow) && $0 !== focused }
            #expect(strays.isEmpty, "responders in between: \(strays)")
        }
    }
}

}
