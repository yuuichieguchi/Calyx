
import AppKit
import QuartzCore
import Testing
@testable import Calyx

private let longText = String(repeating: "xx ", count: 100)

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
    private let bandHeight: CGFloat = 100

    private struct Hosted {
        let window: NSWindow
        let container: NSView
        let host: DiffGlassHostView
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

    private func makeHosted(_ diff: FileDiff = makeLongDiff()) async throws -> Hosted {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400 + bandHeight),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
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

    private func cachedBandPixels(_ container: NSView) throws -> Int {
        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        return bandPixels(rep, pointHeight: container.bounds.height)
    }

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

    private func rulerFrames(_ pane: DiffPaneView) -> [CGRect] {
        let ruler = pane.lineNumberView
        let geometry = pane.linesView.geometry
        return (0..<geometry.rowCount).map {
            let y = ruler.convert(NSPoint(x: 0, y: geometry.rowTop($0)), from: pane.linesView).y
            return CGRect(x: 0, y: y, width: ruler.bounds.width, height: geometry.rowHeight($0))
        }
    }

    @Test func rowsToDraw_clipsDirtyRectToBounds() {
        let geometry = DiffRowGeometry(segmentCounts: Array(repeating: 1, count: 10),
                                       pads: Array(repeating: 0, count: 10), rowHeight: 20, topInset: 0)
        let bounds = CGRect(x: 0, y: 0, width: 40, height: 60)
        let rows = DiffGutterGeometry.rowsToDraw(geometry: geometry, offsetY: -100,
                                                 in: CGRect(x: 0, y: -100, width: 600, height: 300), bounds: bounds)
        #expect(rows == 5..<8)
        let partial = DiffGutterGeometry.rowsToDraw(geometry: geometry, offsetY: -110, in: bounds, bounds: bounds)
        #expect(partial == 5..<9)
        #expect(DiffGutterGeometry.rowsToDraw(geometry: geometry, offsetY: -100,
                                              in: CGRect(x: 0, y: -100, width: 40, height: 50), bounds: bounds).isEmpty)
    }

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
            let opened = try layerBandPixels(hosted)
            #expect(opened == 0, "after open: \(opened) px")
            for offset: CGFloat in [7, 0] {
                for pane in panes(hosted.host.diffView, layout: layout) {
                    pane.scroll(toY: pane.linesView.geometry.rowTop(300) + offset)
                }
                try await settle(hosted.window)
                let live = try layerBandPixels(hosted)
                let cached = try cachedBandPixels(hosted.container)
                #expect(live == 0, "after scroll (offset \(offset)): \(live) px")
                #expect(cached == 0, "cacheDisplay (offset \(offset)): \(cached) px")
            }
        }
    }

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

    private enum GutterMarker: CustomStringConvertible {
        case commentDot
        case hoverButton
        var description: String { self == .commentDot ? "comment dot" : "hover button" }
    }

    private struct PixelBox {
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
        var isEmpty: Bool { minX > maxX }
        mutating func include(x: Int, y: Int) {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        func contains(x: Int, y: Int) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }
    }

    private func inkPixels(_ ruler: NSView) throws -> (points: [(x: Int, y: Int)], scale: CGFloat) {
        ruler.needsDisplay = true
        let rep = try #require(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
        ruler.cacheDisplay(in: ruler.bounds, to: rep)
        var points: [(x: Int, y: Int)] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 { points.append((x, y)) }
            }
        }
        return (points, CGFloat(rep.pixelsWide) / ruler.bounds.width)
    }

    private func setHover(_ ruler: DiffLineNumberView, row: Int?, frames: [CGRect]) throws {
        let window = try #require(ruler.window)
        let y = row.map { frames[$0].midY } ?? -1_000_000
        let location = ruler.convert(NSPoint(x: 5, y: y), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    eventNumber: 0, clickCount: 0, pressure: 0))
        ruler.mouseMoved(with: event)
    }

    @Test(arguments: [DiffLayoutPreference.inline, .sideBySide], [GutterMarker.commentDot, .hoverButton])
    private func gutterMarker_keepsTwoPointsClearOfLineNumbers(layout: DiffLayoutPreference,
                                                               marker: GutterMarker) async throws {
        try await withSettings(layout: layout, wrap: false) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let pane = panes(hosted.host.diffView, layout: layout)[layout == .inline ? 0 : 1]
            let ruler = pane.lineNumberView
            let original = ruler.rows
            let frames = rulerFrames(pane)
            let lineRows = original.indices.filter {
                if case .line = original[$0].kind, original[$0].lineIndex != nil { return frames[$0].minY >= 0 && frames[$0].maxY <= ruler.bounds.height }
                return false
            }
            let targets = Array(lineRows.prefix(4))
            try #require(targets.count == 4)
            for (row, number) in zip(targets, [123, 1234, 12345, 123_456]) {
                let base = original[row]
                func rows(numbered: Bool) -> [GutterRow] {
                    original.indices.map { index in
                        let source = original[index]
                        let shown = index == row && numbered
                        return GutterRow(oldNumber: shown ? number : nil, newNumber: shown ? number : nil,
                                         kind: source.kind, displayIndex: source.displayIndex,
                                         lineIndex: source.lineIndex, indicator: nil)
                    }
                }
                ruler.rows = rows(numbered: true)
                ruler.commentedLineIndices = []
                try setHover(ruler, row: nil, frames: frames)
                let numbers = try inkPixels(ruler)
                ruler.rows = rows(numbered: false)
                switch marker {
                case .commentDot: ruler.commentedLineIndices = [try #require(base.lineIndex)]
                case .hoverButton: try setHover(ruler, row: row, frames: frames)
                }
                let markers = try inkPixels(ruler)
                ruler.commentedLineIndices = []
                try setHover(ruler, row: nil, frames: frames)
                var markerBox = PixelBox()
                for point in markers.points { markerBox.include(x: point.x, y: point.y) }
                var numberBox = PixelBox()
                for point in numbers.points { numberBox.include(x: point.x, y: point.y) }
                let label = "\(layout) \(marker), \(String(number).count)-digit number \(number)"
                try #require(!markerBox.isEmpty, "\(label): the marker must render")
                try #require(!numberBox.isEmpty, "\(label): the number must render")
                let scale = markers.scale
                let gap = CGFloat(numberBox.minX - markerBox.maxX - 1) / scale
                #expect(gap >= 2, "\(label): marker right edge \(CGFloat(markerBox.maxX + 1) / scale) pt, number left edge \(CGFloat(numberBox.minX) / scale) pt, gap \(gap) pt")
                let inside = numbers.points.filter { markerBox.contains(x: $0.x, y: $0.y) }.count
                #expect(inside == 0, "\(label): \(inside) number pixels fall inside the marker rect")
            }
            ruler.rows = original
        }
    }

    private func contextRow(old: Int?, new: Int?) -> GutterRow {
        GutterRow(oldNumber: old, newNumber: new, kind: .line(.context), displayIndex: 0, lineIndex: 0, indicator: nil)
    }

    @Test func sideBySideGutterWidth_followsEachPanesOwnSide() async throws {
        try await withSettings(layout: .sideBySide, wrap: false) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let view = hosted.host.diffView
            let cases: [(label: String, pane: DiffPaneView, wide: GutterRow)] = [
                ("left pane", view.leftPaneForTesting, contextRow(old: 100_000, new: 1)),
                ("right pane", view.rightPaneForTesting, contextRow(old: 1, new: 100_000)),
            ]
            for (label, pane, wide) in cases {
                let ruler = pane.lineNumberView
                let original = ruler.rows
                defer { ruler.rows = original }
                ruler.rows = [contextRow(old: 1, new: 1)]
                let narrowThickness = ruler.gutterLayout.thickness
                ruler.rows = [wide]
                let wideThickness = ruler.gutterLayout.thickness
                #expect(wideThickness > narrowThickness,
                        "\(label): 6-digit own-side number \(wide) gives \(wideThickness) pt, 1-digit gives \(narrowThickness) pt")
            }
        }
    }

    @Test func sideBySideGutter_drawsEachPanesOwnSideNumber() async throws {
        try await withSettings(layout: .sideBySide, wrap: false) {
            let hosted = try await makeHosted()
            defer { hosted.close() }
            let view = hosted.host.diffView
            let cases: [(label: String, pane: DiffPaneView, ownSideOnly: (old: Int?, new: Int?))] = [
                ("left pane", view.leftPaneForTesting, (17, nil)),
                ("right pane", view.rightPaneForTesting, (nil, 9)),
            ]
            for (label, pane, ownSideOnly) in cases {
                let ruler = pane.lineNumberView
                let original = ruler.rows
                defer { ruler.rows = original }
                let frames = rulerFrames(pane)
                let row = try #require(original.indices.first {
                    if case .line = original[$0].kind, original[$0].lineIndex != nil { return frames[$0].minY >= 0 && frames[$0].maxY <= ruler.bounds.height }
                    return false
                })
                func rows(old: Int?, new: Int?) -> [GutterRow] {
                    original.indices.map { index in
                        let source = original[index]
                        let shown = index == row
                        return GutterRow(oldNumber: shown ? old : nil, newNumber: shown ? new : nil,
                                         kind: source.kind, displayIndex: source.displayIndex,
                                         lineIndex: source.lineIndex, indicator: nil)
                    }
                }
                ruler.commentedLineIndices = []
                try setHover(ruler, row: nil, frames: frames)
                ruler.rows = rows(old: 17, new: 9)
                let both = try inkPixels(ruler)
                ruler.rows = rows(old: ownSideOnly.old, new: ownSideOnly.new)
                let own = try inkPixels(ruler)
                try #require(!own.points.isEmpty, "\(label): the own-side number must render")
                let bothSet = Set(both.points.map { "\($0.x),\($0.y)" })
                let ownSet = Set(own.points.map { "\($0.x),\($0.y)" })
                #expect(bothSet == ownSet,
                        "\(label): old 17/new 9 renders \(bothSet.count) px, own side \(ownSideOnly) renders \(ownSet.count) px, \(bothSet.symmetricDifference(ownSet).count) differ")
            }
        }
    }

    @Test(arguments: [(DiffLayoutPreference.inline, true), (.sideBySide, false)], [300, 400])
    func overviewRuler_neverDrawsOutsideItsFrame(layoutWrap: (DiffLayoutPreference, Bool),
                                                  changedLine: Int) async throws {
        try await withSettings(layout: layoutWrap.0, wrap: layoutWrap.1) {
            let hosted = try await makeHosted(makeLongDiff(changedLine: changedLine))
            defer { hosted.close() }
            let ruler = try #require(hosted.host.diffView.subviews.first { $0 is DiffOverviewRulerView })
            let opened = try rulerPixelsOutsideBounds(ruler)
            #expect(opened == 0, "after open: \(opened) px")
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

}
