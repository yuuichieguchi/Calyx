//
//  MCPAppGeneration.swift
//  Calyx
//
//  Which views a new UI tool call retires. Only finished views of the
//  same pane go; in-flight views stay. No count limit and no timer.
//

import Foundation

enum MCPAppGeneration {
    enum PaneKey: Sendable, Equatable, Hashable { case pane(UUID), paneless }
    enum Status: Sendable, Equatable { case completed, cancelled, inFlight }
    struct ViewSnapshot: Sendable, Equatable {
        let id: UUID
        let paneKey: PaneKey
        let status: Status
    }

    static func viewsToRetire(existing: [ViewSnapshot], newCallPaneKey: PaneKey) -> Set<UUID> {
        Set(existing.filter { $0.paneKey == newCallPaneKey && $0.status != .inFlight }.map(\.id))
    }
}
