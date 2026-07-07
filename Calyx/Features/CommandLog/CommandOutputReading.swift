// CommandOutputReading.swift
// Calyx
//
// Seam CommandLogStore reads terminal output through, so tests can supply a
// fake instead of driving the real Ghostty surface -- same shape as
// GhosttyBridge's SelectionReading protocol.

import Foundation

@MainActor
protocol CommandOutputReading: AnyObject {
    /// Cumulative scrollback row count for the surface at the moment of
    /// the call, used to compute a command's row delta between its start
    /// and end events. `nil` when the surface is unknown.
    func scrollbarTotal(surfaceID: UUID) -> UInt64?

    /// The last `count` rows of the surface's screen/scrollback, joined
    /// by newlines. `nil` when the surface is unknown.
    func readScreenTailLines(surfaceID: UUID, count: Int) -> String?
}
