//
//  IPCStoreStatusEntriesTests.swift
//  CalyxTests
//
//  TDD Red Phase — tests for IPCStore.statusEntries(now:).
//
//  The method does not exist yet; this file will produce a compile error
//  (Red phase) until it is implemented.
//
//  Contract for statusEntries(now: Date = Date()) -> [(peer: Peer, inboxCount: Int)]:
//    - Applies the same liveness filter as listPeers()
//    - Returns each alive peer paired with the current size of its inbox
//

import XCTest
@testable import Calyx

final class IPCStoreStatusEntriesTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> IPCStore {
        IPCStore()
    }

    // ==================== Happy path: zero inbox ====================

    func test_statusEntries_returnsRegisteredPeersWithZeroInbox() async {
        // Given: two freshly registered peers with no messages
        let store = makeStore()
        let peer1 = await store.registerPeer(name: "agent-1", role: "terminal")
        let peer2 = await store.registerPeer(name: "agent-2", role: "plugin")

        // When
        let entries = await store.statusEntries()

        // Then: both peers are present, each with inboxCount == 0
        XCTAssertEqual(entries.count, 2,
                       "Both registered peers should appear in statusEntries")

        let inboxCounts = Dictionary(uniqueKeysWithValues: entries.map { ($0.peer.id, $0.inboxCount) })
        XCTAssertEqual(inboxCounts[peer1.id], 0,
                       "peer1 should have inboxCount == 0 (no messages sent)")
        XCTAssertEqual(inboxCounts[peer2.id], 0,
                       "peer2 should have inboxCount == 0 (no messages sent)")
    }

    // ==================== Inbox count reflects actual messages ====================

    func test_statusEntries_reflectsInboxCount() async throws {
        // Given: three peers; peer1 sends 2 messages to peer2 and 1 to peer3
        let store = makeStore()
        let peer1 = await store.registerPeer(name: "sender", role: "terminal")
        let peer2 = await store.registerPeer(name: "receiver-a", role: "terminal")
        let peer3 = await store.registerPeer(name: "receiver-b", role: "plugin")

        _ = try await store.sendMessage(from: peer1.id, to: peer2.id, content: "msg-1")
        _ = try await store.sendMessage(from: peer1.id, to: peer2.id, content: "msg-2")
        _ = try await store.sendMessage(from: peer1.id, to: peer3.id, content: "msg-3")

        // When
        let entries = await store.statusEntries()

        // Then: inbox counts match the number of messages delivered
        XCTAssertEqual(entries.count, 3,
                       "All three peers should be present in statusEntries")

        let inboxCounts = Dictionary(uniqueKeysWithValues: entries.map { ($0.peer.id, $0.inboxCount) })
        XCTAssertEqual(inboxCounts[peer1.id], 0,
                       "sender peer1 has no incoming messages, inboxCount should be 0")
        XCTAssertEqual(inboxCounts[peer2.id], 2,
                       "peer2 received 2 messages, inboxCount should be 2")
        XCTAssertEqual(inboxCounts[peer3.id], 1,
                       "peer3 received 1 message, inboxCount should be 1")
    }

    // ==================== Expired peers are excluded ====================

    func test_statusEntries_excludesExpiredPeers() async {
        // Given: two peers; one has its lastSeen set to 11 minutes ago (TTL expired)
        let store = makeStore()
        let freshPeer = await store.registerPeer(name: "fresh-agent", role: "terminal")
        let stalePeer = await store.registerPeer(name: "stale-agent", role: "terminal")

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: stalePeer.id, date: elevenMinutesAgo)

        // When
        let entries = await store.statusEntries()

        // Then: only the fresh peer is included (same TTL behaviour as listPeers)
        XCTAssertEqual(entries.count, 1,
                       "Expired peer should be excluded from statusEntries")

        let peerIDs = entries.map { $0.peer.id }
        XCTAssertTrue(peerIDs.contains(freshPeer.id),
                      "Fresh peer should appear in statusEntries")
        XCTAssertFalse(peerIDs.contains(stalePeer.id),
                       "Stale peer (lastSeen 11 min ago) should NOT appear in statusEntries")
    }
}
