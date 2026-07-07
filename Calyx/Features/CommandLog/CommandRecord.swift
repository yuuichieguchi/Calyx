// CommandRecord.swift
// Calyx
//
// Data model for a single tracked shell command execution: the record
// CommandLogStore builds from a start/end CommandEvent pair, plus its
// captured terminal output.

import Foundation

// MARK: - CommandOutput

struct CommandOutput: Codable, Sendable, Equatable {
    let text: String
    let truncated: Bool
    let totalRows: Int
}

// MARK: - CommandRecord

struct CommandRecord: Codable, Sendable, Identifiable {
    enum State: String, Codable, Sendable, Equatable {
        case running, finished, orphaned
    }

    let id: UUID
    let cmdID: String
    /// `var`, not `let`: CommandLogStore.remapSurface(old:new:) rewrites
    /// this in place when a persistent-session pane's surfaceID changes
    /// out from under an in-flight record.
    var surfaceID: UUID
    let command: String
    let cwd: String
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var durationNanos: UInt64?
    var output: CommandOutput?
    var state: State
    var scrollbarTotalAtStart: UInt64?
}
