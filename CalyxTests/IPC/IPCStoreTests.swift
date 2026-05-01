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

        // Note: stale peer has no in-flight message → unread-message pin rule does
        // not apply. Pure lastSeen TTL expiration is the only relevant signal here.
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

    // ==================== 12. Old Timestamp Message Still Returned (rewrite of message TTL test) ====================

    func test_oldTimestampMessage_isStillReturned_whenRecipientAlive() async throws {
        // After Change 3, message retention is governed by recipient peer
        // liveness, not by individual message timestamps. A 6-minute-old message
        // must still be delivered as long as the recipient peer is alive.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let oldMsg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "still here"
        )
        let freshMsg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "fresh"
        )

        // Artificially age oldMsg's timestamp to 6 minutes ago
        let sixMinutesAgo = Date().addingTimeInterval(-6 * 60)
        await store._testSetMessageTimestamp(
            messageId: oldMsg.id, peerId: peerB.id, date: sixMinutesAgo
        )

        // Act
        let inbox = await store.receiveMessages(for: peerB.id)

        // Assert — both messages must be returned (no time-based drop)
        XCTAssertEqual(inbox.count, 2,
                       "Both messages should be returned regardless of message timestamp; recipient peer liveness is the only retention rule")
        let messageIDs = Set(inbox.map(\.id))
        XCTAssertTrue(messageIDs.contains(oldMsg.id),
                      "Old-timestamp message should still be delivered")
        XCTAssertTrue(messageIDs.contains(freshMsg.id),
                      "Fresh message should still be delivered")
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

    // ============================================================
    // MARK: - Issue #31: New TTL auto-extension contract
    // ============================================================

    // ==================== Change 1: Bidirectional Bump ====================

    // Test 1
    func test_sendMessage_bumpsRecipientLastSeen() async throws {
        // Contract: sendMessage(from: A, to: B) must bump BOTH A and B's lastSeen.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: oneSecondAgo)

        // Act — A sends to B; under the new contract, B's lastSeen must bump too.
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "ping"
        )

        // Assert
        let updatedB = await store.peerStatus(id: peerB.id)
        XCTAssertNotNil(updatedB, "Recipient should still exist")
        XCTAssertTrue(updatedB!.lastSeen > oneSecondAgo,
                      "Recipient's lastSeen should bump on sendMessage")
    }

    // Test 2
    func test_broadcast_bumpsAllRecipientsLastSeen() async throws {
        // Contract: broadcast(from: A) must bump A and ALL alive recipients' lastSeen.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: oneSecondAgo)
        await store._testSetPeerLastSeen(peerId: peerC.id, date: oneSecondAgo)

        // Act
        _ = try await store.broadcast(from: peerA.id, content: "announcement")

        // Assert
        let updatedB = await store.peerStatus(id: peerB.id)
        let updatedC = await store.peerStatus(id: peerC.id)
        XCTAssertNotNil(updatedB)
        XCTAssertNotNil(updatedC)
        XCTAssertTrue(updatedB!.lastSeen > oneSecondAgo,
                      "Recipient B's lastSeen should bump on broadcast")
        XCTAssertTrue(updatedC!.lastSeen > oneSecondAgo,
                      "Recipient C's lastSeen should bump on broadcast")
    }

    // Test 3
    func test_receiveMessages_bumpsAllSendersLastSeen() async throws {
        // Contract: receiveMessages(for: B) bumps B and ALL distinct senders'
        // lastSeen for messages returned in this call.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        // A and C both send to B
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "from A"
        )
        _ = try await store.sendMessage(
            from: peerC.id, to: peerB.id, content: "from C"
        )

        // Now age both A and C's lastSeen to 1 second ago
        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: oneSecondAgo)
        await store._testSetPeerLastSeen(peerId: peerC.id, date: oneSecondAgo)

        // Act — B reads its inbox
        _ = await store.receiveMessages(for: peerB.id)

        // Assert — both senders should be bumped
        let updatedA = await store.peerStatus(id: peerA.id)
        let updatedC = await store.peerStatus(id: peerC.id)
        XCTAssertNotNil(updatedA)
        XCTAssertNotNil(updatedC)
        XCTAssertTrue(updatedA!.lastSeen > oneSecondAgo,
                      "Sender A's lastSeen should bump when B receives A's message")
        XCTAssertTrue(updatedC!.lastSeen > oneSecondAgo,
                      "Sender C's lastSeen should bump when B receives C's message")
    }

    // Test 4
    func test_ackMessages_bumpsRecipientLastSeen() async throws {
        // Contract: ackMessages(for: B) bumps B's lastSeen because ack is an
        // explicit liveness signal.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "ack me"
        )

        let oneSecondAgo = Date().addingTimeInterval(-1)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: oneSecondAgo)

        // Act
        await store.ackMessages(ids: [msg.id], for: peerB.id)

        // Assert
        let updatedB = await store.peerStatus(id: peerB.id)
        XCTAssertNotNil(updatedB)
        XCTAssertTrue(updatedB!.lastSeen > oneSecondAgo,
                      "Recipient's lastSeen should bump on ackMessages")
    }

    // ==================== Change 2: Unread Message Pinning ====================

    // Test 5
    func test_unreadMessage_pinsRecipientAlive_inListPeers() async throws {
        // Contract: An in-flight (unread) message pins its recipient alive even
        // when the recipient's lastSeen exceeds peerTTL.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // A → B (creates unread message in B's inbox)
        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "you have mail"
        )

        // Age only B's lastSeen to 11 min ago (do NOT touch A; this test asserts
        // about B's pinning specifically).
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerB.id),
                      "Recipient B must be pinned alive while it has an unread message")
    }

    // Test 6
    func test_unreadMessage_pinsSenderAlive_inListPeers() async throws {
        // Contract: An in-flight message also pins its sender alive (so the
        // sender is still around to receive a reply).
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerA.id),
                      "Sender A must be pinned alive while its message is unread")
    }

    // Test 7
    func test_unreadMessage_pinsRecipientAlive_inPeerStatus() async throws {
        // Contract: Pin must also be visible via peerStatus, not only listPeers.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let status = await store.peerStatus(id: peerB.id)

        // Assert
        XCTAssertNotNil(status,
                        "peerStatus must return non-nil while the peer is pinned by an unread message")
        XCTAssertEqual(status?.id, peerB.id)
    }

    // Test 8
    func test_pinLifts_afterAck_recipientThenPurged() async throws {
        // Contract: Once the unread message is ack'd, the pin is lifted.
        // After the pin is lifted, the recipient's stale lastSeen makes it
        // purgeable on the next listPeers call.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        // B acks the message → pin lifts
        await store.ackMessages(ids: [msg.id], for: peerB.id)

        // Now age B's lastSeen to 11 min ago (note: ack also bumps B, so we
        // override that here)
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerB.id),
                       "Recipient B should be purged after pin lifts and TTL elapses")
    }

    // Test 9
    func test_pinLifts_afterAck_senderThenPurged() async throws {
        // Contract (mirror of test 8): once the unread message is gone, the
        // sender is no longer pinned and its stale lastSeen makes it purgeable.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let msg = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "hi"
        )

        // B acks → no in-flight messages remain
        await store.ackMessages(ids: [msg.id], for: peerB.id)

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "Sender A should be purged after pin lifts and TTL elapses")
    }

    // Test 10
    func test_broadcast_pinsSenderWhileAnyRecipientUnread() async throws {
        // Contract: A broadcaster is pinned alive as long as any recipient
        // still has an unread copy of the broadcast.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        _ = try await store.broadcast(from: peerA.id, content: "broadcast")

        // Age A's lastSeen to 11 min ago. Neither B nor C has acked.
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerA.id),
                      "Broadcaster A should be pinned alive while any recipient still has the unread broadcast")
    }

    // Test 11
    func test_broadcast_partialAck_keepsSenderPinned() async throws {
        // Contract: Pin holds while at least ONE recipient still has the
        // broadcast unread.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        let messages = try await store.broadcast(from: peerA.id, content: "broadcast")

        // B acks its copy; C has not.
        guard let msgForB = messages.first(where: { $0.to == peerB.id }) else {
            XCTFail("Expected broadcast message for B")
            return
        }
        await store.ackMessages(ids: [msgForB.id], for: peerB.id)

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertTrue(peerIDs.contains(peerA.id),
                      "A should remain pinned while C still has the broadcast unread")
    }

    // Test 12
    func test_broadcast_fullAck_unpinsSender() async throws {
        // Contract: Once ALL recipients have acked, the pin lifts and A's stale
        // lastSeen makes it purgeable.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")
        let peerC = await store.registerPeer(name: "C", role: "plugin")

        let messages = try await store.broadcast(from: peerA.id, content: "broadcast")

        // B and C both ack
        for msg in messages {
            await store.ackMessages(ids: [msg.id], for: msg.to)
        }

        // Age A's lastSeen to 11 min ago
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act
        let peers = await store.listPeers()

        // Assert
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "A should be purged once all recipients have acked")
    }

    // ==================== Change 3: No Time-Based Drop ====================

    // Test 14 (test 13 is the rewritten existing #12 above)
    func test_messageRetention_governedByPeerLiveness_purgedWithRecipient() async throws {
        // Contract: Removing a recipient must also remove their inbox.
        // receiveMessages on a removed peer returns [].
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        _ = try await store.sendMessage(
            from: peerA.id, to: peerB.id, content: "doomed"
        )

        // Act — remove B
        await store.removePeer(id: peerB.id)

        // Assert — B's inbox is empty (peer + inbox were torn down together)
        let inbox = await store.receiveMessages(for: peerB.id)
        XCTAssertTrue(inbox.isEmpty,
                      "Removed recipient's inbox must be empty; message retention is governed by recipient liveness")
    }

    // ==================== Change 0: Revive Prevention ====================

    // Test 15
    func test_expiredPeer_noUnread_cannotSendMessage() async throws {
        // Contract: An expired peer with no in-flight message must NOT be able
        // to revive itself by calling sendMessage. The call must throw
        // unregisteredPeer, and the peer must be purged.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Age A to 11 min ago. No unread messages exist.
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act & Assert — sendMessage must throw unregisteredPeer
        do {
            _ = try await store.sendMessage(
                from: peerA.id, to: peerB.id, content: "should not go"
            )
            XCTFail("Expected IPCError.unregisteredPeer because A is expired with no pin")
        } catch let error as IPCError {
            if case .unregisteredPeer = error {
                // Expected
            } else {
                XCTFail("Expected .unregisteredPeer, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        // A must be purged from the store
        let peers = await store.listPeers()
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "Expired sender must be purged after the rejected sendMessage call")
    }

    // Test 16
    func test_expiredPeer_noUnread_cannotReceiveMessages() async {
        // Contract: An expired peer with no in-flight message must NOT be able
        // to revive itself via receiveMessages. The call must return [] AND the
        // peer must be purged (not bumped).
        // Arrange
        let store = makeStore()
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act
        let result = await store.receiveMessages(for: peerB.id)

        // Assert
        XCTAssertTrue(result.isEmpty,
                      "Expired peer with no unread should receive []")
        let peers = await store.listPeers()
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerB.id),
                       "Expired peer must be purged on receiveMessages, not silently bumped")
    }

    // Test 17
    func test_expiredPeer_noUnread_cannotAckMessages() async {
        // Contract: An expired peer with no in-flight message must NOT be able
        // to revive via ackMessages. ack is no-op and the peer is purged.
        // Arrange
        let store = makeStore()
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act — call ack with arbitrary ID
        await store.ackMessages(ids: [UUID()], for: peerB.id)

        // Assert
        let peers = await store.listPeers()
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerB.id),
                       "Expired peer must be purged on ackMessages, not silently bumped")
    }

    // Test 18
    func test_expiredRecipient_noUnread_sendThrowsPeerNotFound() async throws {
        // Contract: An alive sender targeting an expired recipient (with no pin)
        // must get peerNotFound. The lazy purge in aliveOrPurge removes the
        // expired recipient before the dictionary check.
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")
        let peerB = await store.registerPeer(name: "B", role: "terminal")

        // Only B is stale
        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerB.id, date: elevenMinutesAgo)

        // Act & Assert
        do {
            _ = try await store.sendMessage(
                from: peerA.id, to: peerB.id, content: "should fail"
            )
            XCTFail("Expected IPCError.peerNotFound because B is expired with no pin")
        } catch let error as IPCError {
            if case .peerNotFound(let id) = error {
                XCTAssertEqual(id, peerB.id,
                               "peerNotFound should carry the expired recipient's UUID")
            } else {
                XCTFail("Expected .peerNotFound, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // ==================== Change 4: peerStatus Purge Unification ====================

    // Test 19
    func test_peerStatus_expiredPeer_purgesPeerAndInbox() async throws {
        // Contract: peerStatus on an expired peer with no pin must return nil
        // AND tear down the peer + inbox (consistent with listPeers' purge).
        // Arrange
        let store = makeStore()
        let peerA = await store.registerPeer(name: "A", role: "terminal")

        let elevenMinutesAgo = Date().addingTimeInterval(-11 * 60)
        await store._testSetPeerLastSeen(peerId: peerA.id, date: elevenMinutesAgo)

        // Act — call peerStatus, which under the new contract should also purge
        let status = await store.peerStatus(id: peerA.id)

        // Assert: returns nil
        XCTAssertNil(status,
                     "peerStatus should return nil for an expired peer with no pin")

        // Assert: A is gone from listPeers (purge happened, not just nil)
        let peers = await store.listPeers()
        let peerIDs = Set(peers.map(\.id))
        XCTAssertFalse(peerIDs.contains(peerA.id),
                       "peerStatus should purge the expired peer, so subsequent listPeers does not see it")

        // Assert: A's inbox is gone — receiveMessages returns []
        let inbox = await store.receiveMessages(for: peerA.id)
        XCTAssertTrue(inbox.isEmpty,
                      "peerStatus should also tear down the inbox of an expired peer")
    }
}
