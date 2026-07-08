// CommandOutputReading.swift
// Calyx
//
// Seam CommandLogStore reads terminal output through, so tests can supply a
// fake instead of driving the real Ghostty surface -- same shape as
// GhosttyBridge's SelectionReading protocol.

import Foundation

@MainActor
protocol CommandOutputReading: AnyObject {
    /// Cumulative count of CONTENT rows for the surface at the moment of
    /// the call (scrollback history rows plus the active screen's non-blank
    /// rows), used to compute a command's row delta between its start and
    /// end events. Unlike ghostty's raw scrollbar `total` -- which counts
    /// the fixed grid height and stays CONSTANT until content scrolls off
    /// the top into history, so a short command on a never-scrolled pane
    /// yields a zero delta and no captured output -- this grows by one per
    /// printed line in both the pre-scroll and scrolled regimes. `nil` when
    /// the surface is unknown.
    func contentRowCount(surfaceID: UUID) -> UInt64?

    /// The last `count` rows of the surface's screen/scrollback, joined
    /// by newlines. `nil` when the surface is unknown.
    func readScreenTailLines(surfaceID: UUID, count: Int) -> String?
}
