// IPCMessageEventFeed.swift
// Calyx
//
// The most recent IPC messages, as Mission Map's pulse lines. IPCStore
// deletes a message on read, so by the time the map is opened (or
// redrawn) the store can no longer say who talked to whom; this feed
// keeps a short, read-independent trail of it instead.

import Foundation

/// One IPC message as Mission Map draws it. `from`/`to` are raw peer
/// IDs, resolved to panes only at draw time: a peer's pane binding can
/// be learned after the message was sent, and a pane can close while
/// its line is still fading.
struct IPCMessageEvent: Identifiable, Sendable, Equatable {
    let id: UUID
    let from: UUID
    /// The recipient peer. Meaningless for a broadcast, which the
    /// snapshot builder fans out to every other bound peer instead.
    let to: UUID
    let content: String
    let sentAt: Date
    let isBroadcast: Bool
}

/// Ring buffer of the latest `capacity` IPC messages, oldest first.
/// `CalyxMCPServer` records into it after a send or broadcast succeeds.
@MainActor
@Observable
final class IPCMessageEventFeed {
    static let shared = IPCMessageEventFeed()

    /// Count-bounded, not age-bounded: this feed never prunes by how old
    /// an event is, only by how many have arrived since. 512 comfortably
    /// covers `MissionMapView.ipcEdgeLifetime` (2 minutes) worth of
    /// traffic for the send rates Mission Map actually sees -- IPC
    /// messages between a handful of agent panes, not a firehose -- so
    /// every line still on screen is still in here. A workload sending
    /// messages fast enough to blow through 512 within that window (over
    /// 4 messages per second sustained for the full 2 minutes) would
    /// see its oldest, still-live lines evicted early; nothing here
    /// currently guards against that.
    static let capacity = 512

    private(set) var events: [IPCMessageEvent] = []

    func record(_ event: IPCMessageEvent) {
        events.append(event)
        let overflow = events.count - Self.capacity
        if overflow > 0 {
            events.removeFirst(overflow)
        }
    }

    func reset() {
        events.removeAll()
    }
}
