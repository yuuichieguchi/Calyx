// GhosttyCommandOutputReader.swift
// Calyx
//
// Production CommandOutputReading: reads a surface's scrollback total and
// tail lines from the live Ghostty surface via SurfaceLocator + FFI.

import Foundation
import GhosttyKit

@MainActor
final class GhosttyCommandOutputReader: CommandOutputReading {

    func scrollbarTotal(surfaceID: UUID) -> UInt64? {
        SurfaceLocator.shared.controller(for: surfaceID)?.scrollbar?.total
    }

    /// Reads a full-SCREEN `ghostty_selection_s` (tag `GHOSTTY_POINT_SCREEN`,
    /// spanning `TOP_LEFT` to `BOTTOM_RIGHT`). Routes the actual FFI call
    /// through a throwaway `GhosttySurfaceSelectionReader`'s
    /// `readAndDecodeText` (SelectionEditHandler.swift) instead of
    /// duplicating that read/decode/free lifecycle here, then slices the
    /// result through `tailLines(_:count:)`.
    func readScreenTailLines(surfaceID: UUID, count: Int) -> String? {
        guard let surface = SurfaceLocator.shared.controller(for: surfaceID)?.surface else {
            return nil
        }

        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )

        let selectionReader = GhosttySurfaceSelectionReader(surface: surface)
        guard let text = selectionReader.readAndDecodeText({
            GhosttyFFI.surfaceReadText(surface, selection: selection, text: &$0)
        })?.text else {
            return nil
        }
        return Self.tailLines(text, count: count)
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
