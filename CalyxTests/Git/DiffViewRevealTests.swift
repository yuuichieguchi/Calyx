// DiffViewRevealTests.swift
// CalyxTests
//
// DiffView reveals the first change on first display (centred), navigates
// changes with goToDiff (wrapping), and keeps the scroll position when the
// same path is displayed again. The reveal is always deferred to layout()
// and then the main queue, so tests drain the main queue after layout.
//
// Fixture: 400-line original; modified replaces lines 200-201 (2 -> 2) and
// inserts one line at modified 350 (401 lines). Side-by-side rows: no filler
// before modified 200, so modified line N (N <= 349) is row N-1 and the
// inserted modified 350 is row 349 (its left cell is a filler).

import AppKit
import Foundation
import Testing
@testable import Calyx

private func makeRaw() -> String {
    var out = "diff --git a/big.txt b/big.txt\n--- a/big.txt\n+++ b/big.txt\n@@ -1,400 +1,401 @@\n"
    var n = 1
    while n <= 400 {
        if n == 200 {
            out += "-line 200\n-line 201\n+changed alpha\n+changed beta\n"
            n += 2
            continue
        }
        if n == 350 {
            out += "+inserted line\n"
        }
        out += " line \(n)\n"
        n += 1
    }
    return out
}

@MainActor
@Suite(.serialized)
struct DiffViewRevealTests {

    private let suiteName = "com.calyx.tests.DiffViewRevealTests"

    private func withIsolatedSettings(_ body: () async throws -> Void) async rethrows {
        DiffLayoutSettings._testUseSuite(named: suiteName)
        defer { DiffLayoutSettings._testTeardownSuite(named: suiteName) }
        DiffLayoutSettings.preference = .sideBySide
        DiffLayoutSettings.hideUnchangedRegionsEnabled = false
        try await body()
    }

    private func makeView(_ diff: FileDiff) async throws -> DiffView {
        let view = DiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.display(diff: diff)
        try await settle(view)
        return view
    }

    /// Suspends the main-actor test so the main queue runs the blocks
    /// scheduled by layout() (layout switch, reveal). A nested run loop
    /// cannot: the test itself runs inside a main-queue block.
    private func drainMainQueue() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    /// Layout pass + main-queue drain, twice: a layout switch applied on the
    /// main queue requests another layout pass before the reveal runs.
    private func settle(_ view: NSView) async throws {
        for _ in 0..<2 {
            view.layoutSubtreeIfNeeded()
            try await drainMainQueue()
        }
    }

    private func descendants<T: NSView>(of view: NSView, _ type: T.Type) -> [T] {
        view.subviews.flatMap { sub -> [T] in
            ((sub as? T).map { [$0] } ?? []) + descendants(of: sub, type)
        }
    }

    private func makeWindow(holding view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func expectCentred(_ row: Int, in range: Range<Int>, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(range.contains(row), "row \(row) must be visible in \(range)", sourceLocation: sourceLocation)
        let centre = Double(range.lowerBound + range.upperBound - 1) / 2
        #expect(abs(centre - Double(row)) <= 2, "row \(row) must be roughly centred in \(range)", sourceLocation: sourceLocation)
    }

    @Test func fixtureSanity_parsedChanges() {
        let diff = DiffParser.parse(makeRaw(), path: "big.txt")
        #expect(diff.newLineCount == 401)
        #expect(diff.changes.map(\.modified.startLineNumber) == [200, 350])
    }

    @Test func rowForModifiedLine_mapsSideBySideRows() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(DiffParser.parse(makeRaw(), path: "big.txt"))
            #expect(view.row(forModifiedLine: 1) == 0)
            #expect(view.row(forModifiedLine: 200) == 199)
            #expect(view.row(forModifiedLine: 350) == 349)
        }
    }

    @Test func firstDisplay_revealsFirstChangeCentred() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(DiffParser.parse(makeRaw(), path: "big.txt"))
            let row200 = try #require(view.row(forModifiedLine: 200))
            let row350 = try #require(view.row(forModifiedLine: 350))
            let range = view.visibleRowRange
            #expect(!range.isEmpty)
            #expect(range.count < 150, "the 400-pt view must show only part of the file")
            expectCentred(row200, in: range)
            #expect(!range.contains(row350))
            #expect(view.currentChangeIndex == 0)
        }
    }

    @Test func goToDiff_nextWrapsAndPrevious() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(DiffParser.parse(makeRaw(), path: "big.txt"))
            let row200 = try #require(view.row(forModifiedLine: 200))
            let row350 = try #require(view.row(forModifiedLine: 350))

            view.goToDiff(.next)
            view.layoutSubtreeIfNeeded()
            #expect(view.visibleRowRange.contains(row350))
            #expect(!view.visibleRowRange.contains(row200))
            #expect(view.currentChangeIndex == 1)

            view.goToDiff(.next)
            view.layoutSubtreeIfNeeded()
            #expect(view.visibleRowRange.contains(row200))
            #expect(!view.visibleRowRange.contains(row350))
            #expect(view.currentChangeIndex == 0)

            view.goToDiff(.previous)
            view.layoutSubtreeIfNeeded()
            #expect(view.visibleRowRange.contains(row350))
            #expect(view.currentChangeIndex == 1)
        }
    }

    @Test func redisplaySamePath_keepsVisibleRange() async throws {
        try await withIsolatedSettings {
            let diff = DiffParser.parse(makeRaw(), path: "big.txt")
            let view = try await makeView(diff)
            view.goToDiff(.next)
            view.layoutSubtreeIfNeeded()
            let before = view.visibleRowRange
            view.display(diff: diff)
            view.layoutSubtreeIfNeeded()
            #expect(view.visibleRowRange == before)
        }
    }

    // MARK: Zero-size reveal (finding 1)

    @Test func zeroSizeDisplay_revealsAfterSizing() async throws {
        try await withIsolatedSettings {
            let view = DiffView(frame: .zero)
            view.display(diff: DiffParser.parse(makeRaw(), path: "big.txt"))
            try await settle(view)
            #expect(view.visibleRowRange.lowerBound == 0)
            #expect(view.currentChangeIndex == nil)

            view.setFrameSize(NSSize(width: 800, height: 400))
            try await settle(view)
            let row200 = try #require(view.row(forModifiedLine: 200))
            expectCentred(row200, in: view.visibleRowRange)
            #expect(view.currentChangeIndex == 0)
        }
    }

    @Test func zeroSizeDisplay_revealRunsOnlyOnce() async throws {
        try await withIsolatedSettings {
            let view = DiffView(frame: .zero)
            view.display(diff: DiffParser.parse(makeRaw(), path: "big.txt"))
            view.setFrameSize(NSSize(width: 800, height: 400))
            try await settle(view)
            #expect(view.currentChangeIndex == 0)

            // Programmatic scroll to the top (not a navigation).
            for scrollView in descendants(of: view, NSScrollView.self) {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            let scrolled = view.visibleRowRange
            #expect(scrolled.lowerBound == 0)

            view.setFrameSize(NSSize(width: 820, height: 420))
            try await settle(view)
            #expect(view.visibleRowRange.lowerBound == 0, "the reveal must not run again")
        }
    }

    @Test func pendingLayoutSwitch_revealWaitsForFinalLayout() async throws {
        try await withIsolatedSettings {
            DiffLayoutSettings.preference = .automatic
            let view = DiffView(frame: NSRect(x: 0, y: 0, width: 1200, height: 400))
            view.display(diff: DiffParser.parse(makeRaw(), path: "big.txt"))
            #expect(view.currentLayout == .sideBySide)
            view.setFrameSize(NSSize(width: 800, height: 400))
            view.layoutSubtreeIfNeeded()
            // The switch to inline is pending: no reveal in the old layout.
            #expect(view.currentLayout == .sideBySide)
            #expect(view.currentChangeIndex == nil)
            #expect(view.visibleRowRange.lowerBound == 0)

            try await settle(view)
            #expect(view.currentLayout == .inline)
            #expect(view.currentChangeIndex == 0)
            let row200 = try #require(view.row(forModifiedLine: 200))
            expectCentred(row200, in: view.visibleRowRange)
        }
    }

    // MARK: User navigation cancels a waiting reveal (finding 2)

    @Test func goToDiff_beforeDeferredReveal_wins() async throws {
        try await withIsolatedSettings {
            let view = DiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
            view.display(diff: DiffParser.parse(makeRaw(), path: "big.txt"))
            view.layoutSubtreeIfNeeded() // reveal scheduled, not yet run
            #expect(view.currentChangeIndex == nil)
            view.goToDiff(.previous) // from the top: wraps to the last change
            try await settle(view)
            let row350 = try #require(view.row(forModifiedLine: 350))
            #expect(view.currentChangeIndex == 1)
            #expect(view.visibleRowRange.contains(row350))
        }
    }

    @Test func rulerReveal_beforeDeferredReveal_wins() async throws {
        try await withIsolatedSettings {
            let view = DiffView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
            view.display(diff: DiffParser.parse(makeRaw(), path: "big.txt"))
            view.layoutSubtreeIfNeeded()
            let ruler = try #require(descendants(of: view, DiffOverviewRulerView.self).first)
            let onRevealRow = try #require(ruler.onRevealRow)
            onRevealRow(380)
            try await settle(view)
            #expect(view.currentChangeIndex == nil)
            #expect(view.visibleRowRange.contains(380))
        }
    }

    // MARK: Ruler toggle does not rebuild (finding 4)

    @Test func rulerToggle_keepsTextCaretAndScroll() async throws {
        try await withIsolatedSettings {
            DiffLayoutSettings.renderOverviewRuler = true
            let view = try await makeView(DiffParser.parse(makeRaw(), path: "big.txt"))
            view.goToDiff(.next)
            try await settle(view)
            let range = view.visibleRowRange
            let caretLine = view.currentModifiedLine()
            #expect(caretLine == 350)

            var edits = 0
            let storages = descendants(of: view, NSTextView.self).compactMap(\.textStorage)
            let tokens = storages.map { storage in
                NotificationCenter.default.addObserver(
                    forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
                ) { _ in edits += 1 }
            }
            defer { tokens.forEach(NotificationCenter.default.removeObserver) }

            DiffLayoutSettings.renderOverviewRuler = false
            try await settle(view)
            let ruler = try #require(descendants(of: view, DiffOverviewRulerView.self).first)
            #expect(ruler.isHidden)
            #expect(edits == 0, "toggling the ruler must not rebuild the text")
            #expect(view.visibleRowRange == range)
            #expect(view.currentModifiedLine() == caretLine)
            DiffLayoutSettings.renderOverviewRuler = true
        }
    }

    // MARK: Cursor line clamp (finding 5)

    @Test func cursorOnPureDeletionAtEOF_clampsToLastLine() async throws {
        try await withIsolatedSettings {
            DiffLayoutSettings.preference = .inline
            var raw = "diff --git a/eof.txt b/eof.txt\n--- a/eof.txt\n+++ b/eof.txt\n@@ -1,12 +1,10 @@\n"
            for n in 1...10 { raw += " line \(n)\n" }
            raw += "-line 11\n-line 12\n"
            let diff = DiffParser.parse(raw, path: "eof.txt")
            #expect(diff.newLineCount == 10)
            #expect(diff.changes.map(\.modified.startLineNumber) == [11])

            let view = try await makeView(diff)
            let window = makeWindow(holding: view)
            defer { window.close() }
            let textView = try #require(descendants(of: view, DiffTextView.self).first)
            #expect(window.makeFirstResponder(textView))
            let deletedRow = 10 // inline rows: lines 1-10, then deleted 11, 12
            let location = try #require(textView.textStart(ofRow: deletedRow))
            textView.setSelectedRange(NSRange(location: location, length: 0))
            #expect(view.currentModifiedLine() == 10)
        }
    }

    // MARK: Left selection counts through the right caret (finding 6)

    @Test func leftPaneSelection_mirrorsToRightCaret() async throws {
        try await withIsolatedSettings {
            let view = try await makeView(DiffParser.parse(makeRaw(), path: "big.txt"))
            let window = makeWindow(holding: view)
            defer { window.close() }
            try await settle(view)
            let textViews = descendants(of: view, DiffTextView.self)
            #expect(textViews.count == 2)
            // The split view's first subview is the original (left) pane.
            let left = try #require(textViews.first)
            #expect(window.makeFirstResponder(left))
            let row300 = try #require(view.row(forModifiedLine: 300))
            let location = try #require(left.textStart(ofRow: row300))
            left.setSelectedRange(NSRange(location: location, length: 0))
            #expect(view.currentModifiedLine() == 300)
            view.goToDiff(.next)
            #expect(view.currentChangeIndex == 1)
        }
    }
}
