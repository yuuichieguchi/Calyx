// GhosttyCommandOutputReader.swift
// Calyx
//
// Production CommandOutputReading: reads a surface's scrollback total and
// tail lines from the live Ghostty surface via SurfaceLocator + FFI.

import Foundation
import GhosttyKit

@MainActor
final class GhosttyCommandOutputReader: CommandOutputReading {

    /// Content rows so far = scrollback history rows + active-screen content
    /// rows. ghostty's scrollbar `total` counts `PageList.total_rows`, which
    /// equals the fixed grid height until content scrolls off the top into
    /// history (`total == len` pre-scroll, `total == len + history` once
    /// scrolling); subtracting `len` (`PageList.rows`, always the viewport
    /// height) leaves the grid-height-INVARIANT history term (0 until history
    /// actually grows). The active term is the line count of the ACTIVE-region
    /// dump, which ghostty's formatter emits with trailing blank rows dropped
    /// ("Trailing blank lines are always trimmed", formatter.zig), so it counts
    /// exactly the non-blank rows on screen -- the piece that grows as a short
    /// command echoes lines BEFORE the screen has filled and started scrolling.
    /// Their sum grows by one per printed line in BOTH regimes, so the store's
    /// end-minus-start delta reflects real output rows even on a fresh pane.
    func contentRowCount(surfaceID: UUID) -> UInt64? {
        guard let scrollbar = SurfaceLocator.shared.controller(for: surfaceID)?.scrollbar else {
            return nil
        }
        let scrollbackRows = Self.scrollbackRows(total: scrollbar.total, len: scrollbar.len)
        let activeRows = readSelectionText(surfaceID: surfaceID, tag: GHOSTTY_POINT_ACTIVE)
            .map(Self.lineCount) ?? 0
        return scrollbackRows + UInt64(activeRows)
    }

    /// Reads a full-SCREEN `ghostty_selection_s` (tag `GHOSTTY_POINT_SCREEN`,
    /// spanning `TOP_LEFT` to `BOTTOM_RIGHT`), then slices the result through
    /// `tailLines(_:count:)`. The SCREEN dump's own line count matches
    /// `contentRowCount` exactly -- both go through the same formatter that
    /// drops trailing blank rows -- so taking the last `count` (== the store's
    /// end-start delta) lines lands on the command's real output rows, never
    /// on trailing blanks.
    func readScreenTailLines(surfaceID: UUID, count: Int) -> String? {
        guard let text = readSelectionText(surfaceID: surfaceID, tag: GHOSTTY_POINT_SCREEN) else {
            return nil
        }
        return Self.tailLines(text, count: count)
    }

    /// Reads a `TOP_LEFT`..`BOTTOM_RIGHT` selection for `tag` and decodes it
    /// to a `String`. Routes the actual FFI call through a throwaway
    /// `GhosttySurfaceSelectionReader`'s `readAndDecodeText`
    /// (SelectionEditHandler.swift) instead of duplicating that
    /// read/decode/free lifecycle. `nil` when the surface is unknown or the
    /// selection decodes empty (`readAndDecodeText` maps an empty read to nil).
    private func readSelectionText(surfaceID: UUID, tag: ghostty_point_tag_e) -> String? {
        guard let surface = SurfaceLocator.shared.controller(for: surfaceID)?.surface else {
            return nil
        }

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: tag,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: tag,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        let selectionReader = GhosttySurfaceSelectionReader(surface: surface)
        return selectionReader.readAndDecodeText({
            GhosttyFFI.surfaceReadText(surface, selection: selection, text: &$0)
        })?.text
    }

    /// Scrollback history rows = the part of the scrollbar `total` above the
    /// viewport length `len`. Guards `total < len` (which ghostty shouldn't
    /// produce -- `total` includes the visible rows -- but a stale/degenerate
    /// scrollbar update must not underflow this unsigned subtraction) to 0.
    /// Pure and FFI-free so the guard is unit-testable on its own.
    nonisolated static func scrollbackRows(total: UInt64, len: UInt64) -> UInt64 {
        total >= len ? total - len : 0
    }

    /// Number of newline-separated rows in a dump: `components(separatedBy:)`'s
    /// count for non-empty text, and 0 for empty text (`components` would
    /// otherwise report 1 for `""`). Pure and FFI-free so it's unit-testable.
    nonisolated static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }

    /// Keeps the last `count` newline-separated segments of `text`,
    /// rejoined by `"\n"` -- pure and FFI-free so it's unit-testable on
    /// its own (`readScreenTailLines` is not: the FFI read it wraps
    /// can't run in a unit-test host). Contract: split `text` on `"\n"`
    /// with `components(separatedBy:)` (so a trailing newline yields a
    /// trailing empty component, preserved through the slice/rejoin
    /// rather than dropped), take the `suffix(count)` of the resulting
    /// array (fewer components than `count` returns all of them
    /// unchanged, and a negative `count` is clamped to 0 rather than
    /// trapping `suffix`'s "non-negative" precondition), and
    /// `joined(separator: "\n")`.
    ///
    /// `nonisolated`: touches no actor-isolated state, so it's callable
    /// synchronously from a non-MainActor test (or any other) context.
    nonisolated static func tailLines(_ text: String, count: Int) -> String {
        text.components(separatedBy: "\n").suffix(max(0, count)).joined(separator: "\n")
    }
}
