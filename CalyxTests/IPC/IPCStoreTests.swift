//
//  IPCStoreTests.swift
//  CalyxTests
//
//  Tests for IPCStore actor: peer registration, message delivery,
//  broadcast, ack/receive, TTL expiration, and cleanup.
//
//  Coverage:
//  - Peer registration (name, role, timestamps)
//  - Peer listing (including TTL expiration filtering)
//  - Peer removal (peer + inbox)
//  - Message send/receive (happy path, unregistered sender, unknown recipient)
//  - Broadcast to all other peers
//  - Message ack (partial removal)
//  - Message limit (101 → keeps newest 100)
//  - Peer TTL (11 min → excluded from list)
//  - Message TTL (6 min → excluded from receive)
//  - Cleanup (full reset)
//  - peerStatus lookup
//  - lastSeen updates on send/receive
//

import XCTest
@testable import Calyx

final class IPCStoreTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() -> IPCStore {
        IPCStore()
    }

    // ==================== 1. Register Peer ====================

    func test_registerPeer_returnsValidPeer() async {
        // Arrange
        let store = makeStore()

        // Act
        let peer = await store.registerPeer(name: "terminal-1", role: "terminal")

        // Assert
        XCTAssertFalse(peer.id.uuidString.isEmpty,
                       "Peer should have a non-empty UUID")
        XCTAssertEqual(peer.name, "terminal-1",
                       "Peer name should match the registered name")
        XCTAssertEqual(peer.role, "terminal",
                       "Peer role should match the registered role")
        XCTAssertNotNil(peer.lastSeen,
                        "Peer lastSeen should be set")
        XCTAssertNotNil(peer.registeredAt,
                        "Peer registeredAt should be set")
        // lastSeen and registeredAt should be very close to now
        let now = Date()
        XCTAssertTrue(now.timeIntervalSince(peer.lastSeen) < 2.0,
                      "lastSeen should be within 2 seconds of now")
        XCTAssertTrue(now.timeIntervalSince(peer.registeredAt) < 2.0,
                      "registeredAt should be within 2 seconds of now")
    }

    // ==================== 2. List Peers ====================

    func test_listPeers_returnsRegisteredPeers() async {
        // Arrange
        let store = makeStore()
        let peer1 = await store.registerPeer(name: "terminal-1", role: "terminal")
        let peer2 = await store.registerPeer(name: "sidebar", role: "plugin")

        // Act
        let peers = await store.listPeers()

        // Assert
        XCTAssertEqual(peers.count, 2,
                       "listPeers should return both registered peers")
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peer1.id),
                      "Should contain peer1")
        XCTAssertTrue(peerIDs.contains(peer2.id),
                      "Should contain peer2")
    }

    // ==================== 3. Remove Peer ====================

    func test_removePeer_removesPeerAndInbox() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Send a message so peerA has inbox content
        _ = try await store.sendMessage(from: peerB.id, to: peerA.id, content: "hello")

        // Act
        await store.removePeer(id: peerA.id)

        // Assert
        let peers = await store.listPeers()
        XCTAssertEqual(peers.count, 1,
                       "Only peerB should remain after removing peerA")
        XCTAssertEqual(peers.first?.id, peerB.id)

        // peerA's inbox should also be gone
        let messages = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(messages.isEmpty,
                      "Removed peer's inbox should be empty")
    }

    // ==================== 4. Send Message ====================

    func test_sendMessage_deliversToRecipient() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Act
        let message = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hello from A"
        )

        // Assert
        XCTAssertEqual(message.from, peerA.id)
        XCTAssertEqual(message.to, peerB.id)
        XCTAssertEqual(message.content, "hello from A")
        XCTAssertFalse(message.id.uuidString.isEmpty,
                       "Message should have a valid UUID")

        // Recipient should have the message in their inbox
        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inbox.count, 1,
                       "Recipient should have exactly 1 message")
        XCTAssertEqual(inbox.first?.content, "hello from A")
    }

    // ==================== 5. Send Message — Unregistered Sender ====================

    func test_sendMessage_unregisteredSender_throws() async {
        // Arrange
        let store = makeStore()
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let fakeID = UUID()

        // Act & Assert
        do {
            _ = try await store.sendMessage(
                from: fakeID, to: peerB.id, content: "should fail"
            )
            XCTFail("Expected IPCError.unregisteredPeer to be thrown")
        } catch let error as IPCError {
            if case .unregisteredPeer = error {
                // Expected
            } else {
                XCTFail("Expected .unregisteredPeer, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // ==================== 6. Send Message — Unknown Recipient ====================

    func test_sendMessage_unknownRecipient_throws() async {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let unknownID = UUID()

        // Act & Assert
        do {
            _ = try await store.sendMessage(
                from: peerA.id, to: unknownID, content: "no one home"
            )
            XCTFail("Expected IPCError.peerNotFound to be thrown")
        } catch let error as IPCError {
            if case .peerNotFound(let id) = error {
                XCTAssertEqual(id, unknownID,
                               "peerNotFound should carry the unknown peer's UUID")
            } else {
                XCTFail("Expected .peerNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // ==================== 7. Broadcast ====================

    func test_broadcast_sendsToAllOtherPeers() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        // Act
        let messages = try await store.broadcast(from: peerA.id, content: "announcement")

        // Assert — messages delivered to B and C, not A
        XCTAssertEqual(messages.count, 2,
                       "Broadcast should create messages for all peers except sender")

        let recipientIDs = Set(messages.map(\.to))
        XCTAssertTrue(recipientIDs.contains(peerB.id),
                      "Broadcast should deliver to peerB")
        XCTAssertTrue(recipientIDs.contains(peerC.id),
                      "Broadcast should deliver to peerC")
        XCTAssertFalse(recipientIDs.contains(peerA.id),
                       "Broadcast should NOT deliver to sender")

        // Verify inboxes
        let inboxB = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inboxB.count, 1)
        XCTAssertEqual(inboxB.first?.content, "announcement")

        let inboxC = await store.receiveMessages(for: peerC.id)
        XCTAssertEqual(inboxC.count, 1)
        XCTAssertEqual(inboxC.first?.content, "announcement")

        // Sender's inbox should be empty
        let inboxA = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(inboxA.isEmpty,
                      "Sender should not receive their own broadcast")
    }

    // ==================== 8. Receive Messages ====================

    func test_receiveMessages_returnsUnackedMessages() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg1 = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "first"
        )
        let msg2 = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "second"
        )

        // Act
        let inbox = await store.receiveMessages(for: peerB.id)

        // Assert
        XCTAssertEqual(inbox.count, 2,
                       "Should return both unacked messages")
        let messageIDs = Set(inbox.map(\.id))
        XCTAssertTrue(messageIDs.contains(msg1.id),
                      "Should contain first message")
        XCTAssertTrue(messageIDs.contains(msg2.id),
                      "Should contain second message")
    }

    // ==================== 9. Ack Messages ====================

    func test_ackMessages_removesAckedMessages() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg1 = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "keep me"
        )
        let msg2 = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "ack me"
        )

        // Act — ack only msg2
        await store.ackMessages(ids: [msg2.id], for: peerB.id)

        // Assert
        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inbox.count, 1,
                       "Only the un-acked message should remain")
        XCTAssertEqual(inbox.first?.id, msg1.id,
                       "The remaining message should be msg1")
        XCTAssertEqual(inbox.first?.content, "keep me")
    }

    // ==================== 10. Message Limit ====================

    func test_messageLimit_dropsOldest() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Act — send 101 messages; limit is 100
        for i in 0..<101 {
            _ = try await store.sendMessage(
                from: peerA.id, to: peerB.id, content: "msg-\(i)"
            )
        }

        // Assert
        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertEqual(inbox.count, 100,
                       "Inbox should cap at 100 messages, dropping the oldest")

        // The oldest message (msg-0) should have been dropped
        let contents = inbox.map(\.content)
        XCTAssertFalse(contents.contains("msg-0"),
                       "Oldest message (msg-0) should be dropped")
        XCTAssertTrue(contents.contains("msg-100"),
                      "Newest message (msg-100) should be present")
        XCTAssertTrue(contents.contains("msg-1"),
                      "Second oldest message (msg-1) should still be present")
    }

    // ==================== 11. Peer TTL ====================

    func test_peerTTL_expiresOldPeers() async {
        // Arrange
        let store = makeStore()
        let freshPeer = await store.registerPeer(name: "fresh", role: "terminal")
        let stalePeer = await store.registerPeer(name: "stale", role: "terminal")

        // Artificially set stalePeer's lastSeen to 11 minutes ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: stalePeer.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        XCTAssertEqual(peers.count, 1,
                       "Only non-expired peers should be returned")
        XCTAssertEqual(peers.first?.id, freshPeer.id,
                       "The fresh peer should remain")
    }

    // ==================== 12. Message TTL ====================

    func test_messageTTL_expiresOldMessages() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let oldMsg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "expired"
        )
        let freshMsg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "fresh"
        )

        // Artificially set oldMsg's timestamp to 6 minutes ago
        let sixMinutesAgo = Date().addingTimeInterval(-6 * 60)
        await store._testSetMessageTimestamp(
            messageId: oldMsg.id, peerId: peerB.id, date: sixMinutesAgo
        )

        // Act
        let inbox = await store.receiveMessages(for: peerB.id)

        // Assert
        XCTAssertEqual(inbox.count, 1,
                       "Only non-expired messages should be returned")
        XCTAssertEqual(inbox.first?.id, freshMsg.id,
                       "The fresh message should remain")
    }

    // ==================== 13. Cleanup ====================

    func test_cleanup_removesAllData() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "will be cleaned"
        )

        // Pre-condition
        let peersBefore = await store.listPeers()
        XCTAssertEqual(peersBefore.count, 2)

        // Act
        await store.cleanup()

        // Assert
        let peersAfter = await store.listPeers()
        XCTAssertTrue(peersAfter.isEmpty,
                      "All peers should be removed after cleanup")

        let inboxA = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(inboxA.isEmpty,
                      "All messages should be removed after cleanup")

        let inboxB = await store.receiveMessages(for: peerB.id)
        XCTAssertTrue(inboxB.isEmpty,
                      "All messages should be removed after cleanup")
    }

    // ==================== 14. Peer Status ====================

    func test_peerStatus_returnsCorrectPeer() async {
        // Arrange
        let store = makeStore()
        let peer = await store.registerPeer(name: "terminal-1", role: "terminal")

        // Act
        let status = await store.peerStatus(id: peer.id)

        // Assert
        XCTAssertNotNil(status, "peerStatus should return the registered peer")
        XCTAssertEqual(status?.id, peer.id)
        XCTAssertEqual(status?.name, "terminal-1")
        XCTAssertEqual(status?.role, "terminal")
    }

    // ==================== 15. Peer Status — Unknown ====================

    func test_peerStatus_unknownPeer_returnsNil() async {
        // Arrange
        let store = makeStore()

        // Act
        let status = await store.peerStatus(id: UUID())

        // Assert
        XCTAssertNil(status,
                     "peerStatus should return nil for an unknown UUID")
    }

    // ==================== 16. Send Updates lastSeen ====================

    func test_sendMessage_updatesLastSeen() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Record the initial lastSeen
        let initialLastSeen = peerA.lastSeen

        // Set lastSeen to 1 second ago to ensure a measurable difference
        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: oneSecondAgo)

        // Act — send a message from peerA (should update A's lastSeen)
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "ping"
        )

        // Assert
        let updatedPeer = await store.peerStatus(id: peerA.id)
        XCTAssertNotNil(updatedPeer)
        XCTAssertTrue(updatedPeer!.lastSeen > oneSecondAgo,
                      "lastSeen should be updated after sending a message")
    }

    // ==================== 17. Receive Updates lastSeen ====================

    func test_receiveMessages_updatesLastSeen() async throws {
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hello"
        )

        // Set peerB's lastSeen to 1 second ago to ensure a measurable difference
        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: oneSecondAgo)

        // Act — receive messages for peerB (should update B's lastSeen)
        _ = await store.receiveMessages(for: peerB.id)

        // Assert
        let updatedPeer = await store.peerStatus(id: peerB.id)
        XCTAssertNotNil(updatedPeer)
        XCTAssertTrue(updatedPeer!.lastSeen > oneSecondAgo,
                      "lastSeen should be updated after receiving messages")
    }
}
