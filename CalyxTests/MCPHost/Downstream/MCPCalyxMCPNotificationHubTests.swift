//
//  MCPCalyxMCPNotificationHubTests.swift
//  CalyxTests
//
//  `MCPCalyxMCPNotificationHub` watches each server's connection events.
//  When the watched connection's events end because the supervisor
//  replaced the connection (a transport change), the hub watches the
//  server's current connection instead.
//

import XCTest
@testable import Calyx

/// A connection lookup whose table the test changes.
private actor MutableConnectionLookup: MCPConnectionLookup {
    private var connections: [MCPServerID: any MCPUpstreamConnecting] = [:]

    func set(_ connection: (any MCPUpstreamConnecting)?, for serverID: MCPServerID) {
        connections[serverID] = connection
    }

    func connection(forServerID serverID: MCPServerID) async -> (any MCPUpstreamConnecting)? {
        connections[serverID]
    }
}

/// Collects the frames of one hub stream.
private actor FrameCollector {
    private(set) var frames: [Data] = []
    func append(_ frame: Data) { frames.append(frame) }
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

final class MCPCalyxMCPNotificationHubTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 2, _ description: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { throw WaitTimedOut(description: description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func isToolsListChanged(_ frame: Data) -> Bool {
        String(decoding: frame, as: UTF8.self).contains("notifications/tools/list_changed")
    }

    func test_afterTheWatchedConnectionIsReplaced_theNewConnectionsEventsAreDelivered() async throws {
        let hub = MCPCalyxMCPNotificationHub(clock: ManualMCPClock())
        let serverID = MCPServerID()
        let first = FakeUpstreamConnection(serverID: serverID)
        let second = FakeUpstreamConnection(serverID: serverID)
        let lookup = MutableConnectionLookup()
        await lookup.set(first, for: serverID)

        let stream = await hub.openStream(
            surfaceID: nil, sessionNonce: nil, subscriptionID: nil, wantsToolsListChanged: true, initialFrames: []
        )
        let collector = FrameCollector()
        let reader = Task {
            for await frame in stream {
                await collector.append(frame)
            }
        }
        defer { reader.cancel() }

        await hub.watchServers([serverID], connections: lookup)
        await first.setTools([])
        try await waitUntil("the first connection's tools change is delivered") {
            await collector.frames.filter(Self.isToolsListChanged).count == 1
        }

        // The supervisor replaces the connection: the lookup returns the
        // new one, then the old one's events end.
        await lookup.set(second, for: serverID)
        await first.finishEvents()
        await second.setTools([])

        try await waitUntil("the replacement connection's tools change is delivered") {
            await collector.frames.filter(Self.isToolsListChanged).count == 2
        }
    }
}
