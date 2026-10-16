// DiffGutterDrawingTests.swift
// CalyxTests
//
// Regression: the line-number gutter (`DiffLineNumberView`) painted rows
// above the diff view, over the tab bar / toolbar. With
// `clipsToBounds == false` (macOS 14+) and no clipping ancestor (inline
// layout: no NSSplitView), AppKit sizes the ruler's backing to its
// `visibleRect`, which reaches the window top, and passes a dirty rect
// taller than the ruler's bounds. The gutter drew every row intersecting
// that rect; later scroll-time redraws only cover the bounds, so the rows
// painted above stayed burned in.
//
// The pixel checks render the live layer tree (`CALayer.render(in:)`),
// which shows stale backing contents; `cacheDisplay` redraws the views and
// is checked as well.

import AppKit
import QuartzCore
import Testing
@testable import Calyx

private let longText = String(repeating: "xx ", count: 100)

/// 400 lines; long (wrapping) lines every 40 lines, line 300 modified.
private let layoutWrapCases: [(DiffLayoutPreference, Bool)] = [
    (.inline, true), (.inline, false), (.sideBySide, true), (.sideBySide, false),
]

private func makeLongDiff(changedLine: Int = 300) -> FileDiff {
    var raw = "diff --git a/w.txt b/w.txt\n--- a/w.txt\n+++ b/w.txt\n@@ -1,400 +1,400 @@\n"
    for n in 1...400 {
        if n == changedLine {
            raw += "-old \(n)\n+new \(n)\n"
        } else if n % 40 == 0 {
            raw += " \(n) \(longText)\n"
        } else {
            raw += " line \(n)\n"
        }
    }
    return DiffParser.parse(raw, path: "w.txt")
}

extension DiffViewWindowedSuites {

@MainActor
@Suite(.serialized)
struct DiffGutterDrawingTests {

    private let suiteName = "com.calyx.tests.DiffGutterDrawingTests"
    /// Height of the empty band above the diff view (stands in for the
    /// tab bar / toolbar).
    private let bandHeight: CGFloat = 100

    private struct Hosted {
        let window: NSWindow
        let container: NSView
        let host: DiffGlassHostView
        /// The container's live layer render before the diff view exists.
        let baseline: NSBitmapImageRep

        func close() {
            window.orderOut(nil)
            window.close()
        }
    }

    private func withSettings(layout: DiffLayoutPreference, wrap: Bool,
                              _ body: () async throws -> Void) async rethrows {
        DiffLayoutSettings._testUseSuite(named: suiteName)
        defer { DiffLayoutSettings._testTeardownSuite(named: suiteName) }
        DiffLayoutSettings.preference = layout
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        DiffLayoutSettings.wordWrap = wrap
        try await body()
    }

    /// The app's open path: the host (and its DiffView) is created at
    /// `.zero`, the diff is displayed before the view is sized, then the
    /// view is laid out below an empty band, layer-backed, on screen.
    private func makeHosted(_ diff: FileDiff = makeLongDiff()) async throws -> Hosted {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400 + bandHeight),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400 + bandHeight))
        container.wantsLayer = true
        window.contentView = container
        window.orderFront(nil)
        try await settle(window)
        let baseline = try renderLayer(container)
        let host = DiffGlassHostView(reduceTransparency: false, glassOpacity: 1)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.diffView.display(diff: diff)
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.heightAnchor.constraint(equalToConstant: 400),
        ])
        try await settle(window, passes: 8)
        return Hosted(window: window, container: container, host: host, baseline: baseline)
    }

    private func settle(_ window: NSWindow, passes: Int = 4) async throws {
        for _ in 0..<passes {
            window.layoutIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private func panes(_ view: DiffView, layout: DiffLayoutPreference) -> [DiffPaneView] {
        layout == .inline ? [view.inlinePaneForTesting] : [view.leftPaneForTesting, view.rightPaneForTesting]
    }

    /// Pixels in the band above the diff view that differ from the
    /// baseline rendered before the diff view existed, from the live layer
    /// contents (stale pixels included).
    private func layerBandPixels(_ hosted: Hosted) throws -> Int {
        let rep = try renderLayer(hosted.container)
        let scale = CGFloat(rep.pixelsHigh) / hosted.container.bounds.height
        let bandRows = Int(bandHeight * scale)
        #expect(rep.pixelsWide == hosted.baseline.pixelsWide && rep.pixelsHigh == hosted.baseline.pixelsHigh)
        var count = 0
        for y in 0..<bandRows {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y),
                      let base = hosted.baseline.colorAt(x: x, y: y) else { continue }
                let differs = abs(color.redComponent - base.redComponent) > 0.01
                    || abs(color.greenComponent - base.greenComponent) > 0.01
                    || abs(color.blueComponent - base.blueComponent) > 0.01
                    || abs(color.alphaComponent - base.alphaComponent) > 0.01
                if differs { count += 1 }
            }
        }
        return count
    }

    /// The container's live layer contents.
    private func renderLayer(_ container: NSView) throws -> NSBitmapImageRep {
        let root = try #require(container.layer)
        let width = Int(root.bounds.width)
        let height = Int(root.bounds.height)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        root.render(in: context)
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }

    /// Non-transparent pixels in the band above the diff view, redrawn.
    private func cachedBandPixels(_ container: NSView) throws -> Int {
        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        return bandPixels(rep, pointHeight: container.bounds.height)
    }

    /// Row 0 of a bitmap rep is the top edge.
    private func bandPixels(_ rep: NSBitmapImageRep, pointHeight: CGFloat) -> Int {
        let scale = CGFloat(rep.pixelsHigh) / pointHeight
        let bandRows = Int(bandHeight * scale)
        var count = 0
        for y in 0..<bandRows {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.01 { count += 1 }
            }
        }
        return count
    }

    /// Row frames in the ruler's coordinates (same conversion as drawing).
    private func rulerFrames(_ pane: DiffPaneView) -> [CGRect] {
        let ruler = pane.lineNumberView
        return pane.textView.ensureRowFrames().map {
            let y = ruler.convert(NSPoint(x: 0, y: $0.minY), from: pane.textView).y
            return CGRect(x: 0, y: y, width: ruler.bounds.width, height: $0.height)
        }
    }

    // MARK: Pure geometry

    @Test func rowsToDraw_clipsDirtyRectToBounds() {
        let frames = (0..<10).map { CGRect(x: 0, y: CGFloat($0) * 20 - 100, width: 40, height: 20) }
        let bounds = CGRect(x: 0, y: 0, width: 40, height: 60)
        // A dirty rect reaching 100 pt above and to the right of the bounds.
        let rows = DiffGutterGeometry.rowsToDraw(rowFrames: frames, in: CGRect(x: 0, y: -100, width: 600, height: 300),
                                                 bounds: bounds)
        #expect(rows == 5..<8)
        // Straddling rows (partially visible) are included.
        let partial = DiffGutterGeometry.rowsToDraw(rowFrames: frames.map { $0.offsetBy(dx: 0, dy: -10) },
                                                    in: bounds, bounds: bounds)
        #expect(partial == 5..<9)
        #expect(DiffGutterGeometry.rowsToDraw(rowFrames: frames, in: CGRect(x: 0, y: -100, width: 40, height: 50),
                                              bounds: bounds).isEmpty)
    }

    // MARK: Window-hosted

    @Test(arguments: layoutWrapCases)
    func scrolledToRow300_gutterDrawsOnlyRowsInsideBounds(layout: DiffLayoutPreference, wrap: Bool) async throws {
        try await withSettings(layout: layout, wrap: wrap) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            for pane in panes(hosted.host.diffView, layout: layout) {
                pane.scrollToRow(300)
            }
            try await settle(hosted.window)
            for pane in panes(hosted.host.diffView, layout: layout) {
                let ruler = pane.lineNumberView
                let frames = rulerFrames(pane)
                // The real dirty rect can reach past the bounds (visibleRect), and an
                // explicitly oversized one 200 pt above and below.
                for rect in [ruler.visibleRect, ruler.bounds.insetBy(dx: 0, dy: -200)] {
                    let rows = ruler.rowsToDraw(in: rect)
                    #expect(!rows.isEmpty)
                    #expect(rows.contains(300), "row 300 is at the top: \(rows)")
                    for row in rows {
                        #expect(frames[row].maxY > 0 && frames[row].minY < ruler.bounds.height,
                                "row \(row) frame \(frames[row]) outside ruler bounds \(ruler.bounds)")
                    }
                }
                #expect(abs(frames[300].minY) <= 0.5, "row 300 at the gutter top: \(frames[300])")
                let anchor = pane.rowRect(300)
                #expect(anchor.minY >= -0.5 && anchor.maxY <= ruler.bounds.height + 0.5,
                        "rowRect \(anchor) within \(ruler.bounds)")
            }
        }
    }

    @Test(arguments: layoutWrapCases)
    func initialOpenThenScroll_gutterNeverPaintsAboveDiffView(layout: DiffLayoutPreference, wrap: Bool) async throws {
        try await withSettings(layout: layout, wrap: wrap) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            // Opened and revealed (first change, row ~300).
            let opened = try layerBandPixels(hosted)
            #expect(opened == 0, "after open: \(opened) px")
            // Scroll so a row straddles the top edge, then to row 300.
            for offset: CGFloat in [7, 0] {
                for pane in panes(hosted.host.diffView, layout: layout) {
                    let frames = pane.textView.ensureRowFrames()
                    pane.scroll(toY: frames[300].minY + offset)
                }
                try await settle(hosted.window)
                let live = try layerBandPixels(hosted)
                let cached = try cachedBandPixels(hosted.container)
                #expect(live == 0, "after scroll (offset \(offset)): \(live) px")
                #expect(cached == 0, "cacheDisplay (offset \(offset)): \(cached) px")
            }
        }
    }

    // MARK: Overview ruler

    /// Non-transparent pixels the ruler's layer tree renders outside its
    /// bounds (rendered with a 50 pt margin on every side; sublayers AppKit
    /// places outside the bounds are not clipped by the render).
    private func rulerPixelsOutsideBounds(_ ruler: NSView) throws -> Int {
        let layer = try #require(ruler.layer)
        let margin: CGFloat = 50
        let scale: CGFloat = 2
        let width = Int((layer.bounds.width + 2 * margin) * scale)
        let height = Int((layer.bounds.height + 2 * margin) * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: margin, y: margin)
        layer.render(in: context)
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let inside = (x: Int(margin * scale)..<Int((margin + layer.bounds.width) * scale),
                      y: Int(margin * scale)..<Int((margin + layer.bounds.height) * scale))
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where !(inside.x.contains(x) && inside.y.contains(y)) {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.01 { count += 1 }
            }
        }
        return count
    }

    /// The overview ruler draws nothing outside its frame: the viewport
    /// slider spans the text insets (document y -inset at the top, past the
    /// last row at the end) and a minimum-height mark sits at the last row.
    @Test(arguments: [(DiffLayoutPreference.inline, true), (.sideBySide, false)], [300, 400])
    func overviewRuler_neverDrawsOutsideItsFrame(layoutWrap: (DiffLayoutPreference, Bool),
                                                  changedLine: Int) async throws {
        try await withSettings(layout: layoutWrap.0, wrap: layoutWrap.1) {
            let hosted = try await makeHosted(makeLongDiff(changedLine: changedLine))
            defer { hosted.close() }
            let ruler = try #require(hosted.host.diffView.subviews.first { $0 is DiffOverviewRulerView })
            let opened = try rulerPixelsOutsideBounds(ruler)
            #expect(opened == 0, "after open: \(opened) px")
            // Top, middle, end (`scroll(toY:)` clamps to the document).
            for y: CGFloat in [0, 2000, 1_000_000] {
                for pane in panes(hosted.host.diffView, layout: layoutWrap.0) {
                    pane.scroll(toY: y)
                }
                try await settle(hosted.window)
                let outside = try rulerPixelsOutsideBounds(ruler)
                #expect(outside == 0, "after scroll to \(y): \(outside) px")
            }
        }
    }
}

} // extension DiffViewWindowedSuites
