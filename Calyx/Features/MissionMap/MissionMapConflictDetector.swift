// MissionMapConflictDetector.swift
// Calyx
//
// Finds pairs of panes whose agents recently wrote the same file --
// Mission Map's red conflict lines.

import Foundation

/// Two different surfaces both wrote `file` within the window.
/// `surfaceA` sorts before `surfaceB` by `uuidString`, so one pair always
/// reads the same way whichever surface wrote first.
struct MissionMapConflict: Sendable, Equatable, Hashable {
    let surfaceA: UUID
    let surfaceB: UUID
    /// The standardized full path.
    let file: String
}

enum MissionMapConflictDetector {

    /// Five minutes: long enough that two agents working the same file
    /// in turn still show as overlapping, short enough that yesterday's
    /// edit does not keep a line up.
    static let recentWindow: TimeInterval = 300

    /// One conflict per `(surfaceA, surfaceB, file)` among `records`
    /// written within `window` of `now`, however many times either
    /// surface wrote the file. Paths are compared after
    /// `NSString.standardizingPath`, so `/repo/./a` and `/repo/sub/../a`
    /// are the same file. Relative paths were already resolved against
    /// the agent's cwd when recorded (`AgentRegistry.handleHookEvent`).
    /// Sorted by file, then surface pair, so the result is deterministic.
    static func conflicts(
        in records: [AgentEditedFile], now: Date, window: TimeInterval = recentWindow
    ) -> [MissionMapConflict] {
        var surfacesByFile: [String: Set<UUID>] = [:]
        for record in records where now.timeIntervalSince(record.at) <= window {
            let file = (record.path as NSString).standardizingPath
            surfacesByFile[file, default: []].insert(record.surfaceID)
        }

        var conflicts: [MissionMapConflict] = []
        for (file, surfaces) in surfacesByFile where surfaces.count > 1 {
            let ordered = surfaces.sorted { $0.uuidString < $1.uuidString }
            for i in ordered.indices {
                for j in ordered.indices where j > i {
                    conflicts.append(MissionMapConflict(surfaceA: ordered[i], surfaceB: ordered[j], file: file))
                }
            }
        }
        return conflicts.sorted {
            ($0.file, $0.surfaceA.uuidString, $0.surfaceB.uuidString)
                < ($1.file, $1.surfaceA.uuidString, $1.surfaceB.uuidString)
        }
    }
}
