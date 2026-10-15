// DiffRevealState.swift
// Calyx
//
// Per-diff-tab (not persisted) reveal state for collapsed unchanged
// regions. Port of the visible-line-count half of VS Code's
// `UnchangedRegion` (diffEditorViewModel.ts): showMoreAbove/Below clamp
// so top + bottom never exceeds the region's lineCount, showAll reveals
// the remainder from the bottom, collapseAll resets both counts.

import Foundation

/// A run of unchanged lines that may be collapsed. Its id is
/// `originalLineNumber`.
struct UnchangedRegion: Equatable, Sendable {
    let originalLineNumber: Int
    let modifiedLineNumber: Int
    let lineCount: Int

    var id: Int { originalLineNumber }
}

/// Immutable copy of a `DiffRevealState` for row building.
struct DiffRevealSnapshot: Equatable, Sendable {
    struct Counts: Equatable, Sendable {
        var top: Int
        var bottom: Int
    }

    /// Keyed by region id (`UnchangedRegion.originalLineNumber`).
    let counts: [Int: Counts]
    let isAllRevealed: Bool

    func visibleLineCountTop(regionID: Int) -> Int {
        counts[regionID]?.top ?? 0
    }

    func visibleLineCountBottom(regionID: Int) -> Int {
        counts[regionID]?.bottom ?? 0
    }
}

@MainActor
final class DiffRevealState {

    private var regions: [Int: UnchangedRegion] = [:]
    private var counts: [Int: DiffRevealSnapshot.Counts] = [:]

    /// True after `revealAllRegions()`, false after `collapseAll()`
    /// (independent of whether any regions exist). Regions arriving via `updateRegions` while
    /// true start fully revealed.
    private(set) var isAllRevealed = false

    /// Fired after every user-driven mutation (showMore*/showAll/
    /// collapseAll/revealAllRegions). Not fired by `updateRegions`, which
    /// the view calls while rebuilding rows; firing there would re-enter
    /// the rebuild.
    var onChanged: (() -> Void)?

    init() {}

    var snapshot: DiffRevealSnapshot {
        DiffRevealSnapshot(counts: counts, isAllRevealed: isAllRevealed)
    }

    /// Replaces the region set. Counts of regions whose id survives are
    /// kept (re-clamped to the new lineCount); new regions start collapsed,
    /// or fully revealed when `isAllRevealed`.
    func updateRegions(_ newRegions: [UnchangedRegion]) {
        var nextRegions: [Int: UnchangedRegion] = [:]
        var nextCounts: [Int: DiffRevealSnapshot.Counts] = [:]
        for region in newRegions {
            nextRegions[region.id] = region
            if isAllRevealed {
                nextCounts[region.id] = Self.clamped(top: 0, bottom: region.lineCount, lineCount: region.lineCount)
            } else if let existing = counts[region.id] {
                nextCounts[region.id] = Self.clamped(top: existing.top, bottom: existing.bottom, lineCount: region.lineCount)
            } else {
                nextCounts[region.id] = DiffRevealSnapshot.Counts(top: 0, bottom: 0)
            }
        }
        regions = nextRegions
        counts = nextCounts
    }

    func visibleLineCountTop(regionID: Int) -> Int {
        counts[regionID]?.top ?? 0
    }

    func visibleLineCountBottom(regionID: Int) -> Int {
        counts[regionID]?.bottom ?? 0
    }

    func showMoreAbove(regionID: Int, count: Int) {
        guard let region = regions[regionID], let current = counts[regionID] else { return }
        let maxTop = region.lineCount - current.bottom
        counts[regionID] = DiffRevealSnapshot.Counts(top: min(current.top + count, maxTop), bottom: current.bottom)
        onChanged?()
    }

    func showMoreBelow(regionID: Int, count: Int) {
        guard let region = regions[regionID], let current = counts[regionID] else { return }
        let maxBottom = region.lineCount - current.top
        counts[regionID] = DiffRevealSnapshot.Counts(top: current.top, bottom: min(current.bottom + count, maxBottom))
        onChanged?()
    }

    func showAll(regionID: Int) {
        guard let region = regions[regionID], let current = counts[regionID] else { return }
        counts[regionID] = DiffRevealSnapshot.Counts(top: current.top, bottom: region.lineCount - current.top)
        onChanged?()
    }

    func collapseAll() {
        for id in counts.keys {
            counts[id] = DiffRevealSnapshot.Counts(top: 0, bottom: 0)
        }
        isAllRevealed = false
        onChanged?()
    }

    func revealAllRegions() {
        for (id, region) in regions {
            let top = counts[id]?.top ?? 0
            counts[id] = DiffRevealSnapshot.Counts(top: top, bottom: region.lineCount - top)
        }
        isAllRevealed = true
        onChanged?()
    }

    /// VS Code `UnchangedRegion.setState` clamping.
    private static func clamped(top: Int, bottom: Int, lineCount: Int) -> DiffRevealSnapshot.Counts {
        let t = max(min(top, lineCount), 0)
        let b = max(min(bottom, lineCount - t), 0)
        return DiffRevealSnapshot.Counts(top: t, bottom: b)
    }
}
