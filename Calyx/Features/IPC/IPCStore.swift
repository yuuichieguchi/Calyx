// IPCStore.swift
// Calyx
//
// Actor-based in-memory IPC store for Claude Code peer communication.
// Manages peer registration, message delivery, broadcast, and TTL expiration.

import Foundation

// MARK: - Models

struct Peer: Sendable, Codable {
    let id: UUID
    let name: String
    let role: String
    var lastSeen: Date
    let registeredAt: Date
}

struct Message: Sendable, Codable {
    let id: UUID
    let from: UUID
    let to: UUID
    let content: String
    var timestamp: Date
}

// MARK: - Errors

enum IPCError: Error, LocalizedError {
    case unregisteredPeer
    case peerNotFound(UUID)
    case contentTooLarge

    var errorDescription: String? {
        switch self {
        case .unregisteredPeer:
            return "You must register_peer first."
        case .peerNotFound(let id):
            return "Peer not found: \(id). Use list_peers to see available peers."
        case .contentTooLarge:
            return "Message content exceeds maximum size (64KB)."
        }
    }
}

// MARK: - IPCStore Actor

actor IPCStore {
    private var peers: [UUID: Peer] = [:]
    private var inbox: [UUID: [Message]] = [:]

    /// Peer TTL: 10 minutes
    private let peerTTL: TimeInterval = 600
    /// Message TTL: 5 minutes
    private let messageTTL: TimeInterval = 300
    /// Max messages per peer inbox
    private let maxMessagesPerPeer: Int = 100
    /// Max content size per message: 64KB
    private let maxContentSize: Int = 65_536

    // MARK: - Peer Management

    /// Registers a new peer with the given name and role.
    /// Returns the created `Peer` with a fresh UUID and timestamps.
    func registerPeer(name: String, role: String) -> Peer {
        let now = Date()
        let peer = Peer(
            id: UUID(),
            name: name,
            role: role,
            lastSeen: now,
            registeredAt: now
        )
        peers[peer.id] = peer
        inbox[peer.id] = []
        return peer
    }

    /// Removes a peer and its inbox.
    func removePeer(id: UUID) {
        peers.removeValue(forKey: id)
        inbox.removeValue(forKey: id)
    }

    /// Returns all peers whose `lastSeen` is within `peerTTL`.
    /// Lazily purges expired peers.
    func listPeers() -> [Peer] {
        let now = Date()
        let expiredIDs = peers.filter { now.timeIntervalSince($0.value.lastSeen) > peerTTL }.map(\.key)
        for id in expiredIDs {
            peers.removeValue(forKey: id)
            inbox.removeValue(forKey: id)
        }
        return Array(peers.values)
    }

    /// Returns the peer if it exists and has not TTL-expired.
    func peerStatus(id: UUID) -> Peer? {
        guard let peer = peers[id] else { return nil }
        let now = Date()
        if now.timeIntervalSince(peer.lastSeen) > peerTTL {
            return nil
        }
        return peer
    }

    // MARK: - Messaging

    /// Sends a message from one peer to another.
    /// Validates that the sender is registered and the recipient exists.
    /// Updates the sender's `lastSeen`. Caps recipient inbox at `maxMessagesPerPeer`.
    func sendMessage(from senderID: UUID, to recipientID: UUID, content: String) throws -> Message {
        guard content.utf8.count <= maxContentSize else {
            throw IPCError.contentTooLarge
        }
        guard peers[senderID] != nil else {
            throw IPCError.unregisteredPeer
        }
        guard peers[recipientID] != nil else {
            throw IPCError.peerNotFound(recipientID)
        }

        let message = Message(
            id: UUID(),
            from: senderID,
            to: recipientID,
            content: content,
            timestamp: Date()
        )

        inbox[recipientID, default: []].append(message)

        // Cap inbox at maxMessagesPerPeer, dropping oldest
        if let count = inbox[recipientID]?.count, count > maxMessagesPerPeer {
            inbox[recipientID]?.removeFirst(count - maxMessagesPerPeer)
        }

        // Update sender's lastSeen
        peers[senderID]?.lastSeen = Date()

        return message
    }

    /// Broadcasts a message from one peer to all other registered peers.
    /// Validates that the sender is registered.
    /// Returns the array of created messages.
    func broadcast(from senderID: UUID, content: String) throws -> [Message] {
        guard content.utf8.count <= maxContentSize else {
            throw IPCError.contentTooLarge
        }
        guard peers[senderID] != nil else {
            throw IPCError.unregisteredPeer
        }

        var messages: [Message] = []
        for recipientID in peers.keys where recipientID != senderID {
            let message = Message(
                id: UUID(),
                from: senderID,
                to: recipientID,
                content: content,
                timestamp: Date()
            )
            inbox[recipientID, default: []].append(message)

            if let count = inbox[recipientID]?.count, count > maxMessagesPerPeer {
                inbox[recipientID]?.removeFirst(count - maxMessagesPerPeer)
            }

            messages.append(message)
        }

        // Update sender's lastSeen
        peers[senderID]?.lastSeen = Date()

        return messages
    }

    /// Returns all non-expired messages in a peer's inbox.
    /// Purges expired messages. Updates peer's `lastSeen`.
    func receiveMessages(for peerID: UUID) -> [Message] {
        let now = Date()

        // Filter out expired messages
        inbox[peerID] = inbox[peerID]?.filter { now.timeIntervalSince($0.timestamp) <= messageTTL }

        // Update peer's lastSeen
        if peers[peerID] != nil {
            peers[peerID]?.lastSeen = now
        }

        return inbox[peerID] ?? []
    }

    /// Removes messages with the given IDs from a peer's inbox.
    func ackMessages(ids: [UUID], for peerID: UUID) {
        let idSet = Set(ids)
        inbox[peerID]?.removeAll { idSet.contains($0.id) }
    }

    // MARK: - Cleanup

    /// Removes ALL peers and ALL inboxes.
    func cleanup() {
        peers.removeAll()
        inbox.removeAll()
    }

    // MARK: - Test Helpers

    /// Directly sets a peer's `lastSeen` for TTL testing.
    func _testSetPeerLastSeen(peerId: UUID, date: Date) {
        peers[peerId]?.lastSeen = date
    }

    /// Directly sets a message's `timestamp` for TTL testing.
    func _testSetMessageTimestamp(messageId: UUID, peerId: UUID, date: Date) {
        guard var messages = inbox[peerId] else { return }
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            messages[index].timestamp = date
            inbox[peerId] = messages
        }
    }
}
