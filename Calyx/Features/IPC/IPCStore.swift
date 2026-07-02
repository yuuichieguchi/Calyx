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
    /// Whether this message has been returned by a `receiveMessages` call
    /// for its recipient. Set by `receiveMessages`, never cleared. Unlike
    /// removal (only `ackMessages` does that), delivery alone doesn't
    /// drop the message from the inbox — it only stops the message from
    /// counting toward `inboxCount`'s undelivered total, so a peer's
    /// unread badge clears as soon as it actually retrieves its inbox
    /// rather than requiring a separate explicit ack.
    var delivered: Bool = false
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
    /// Max messages per peer inbox
    private let maxMessagesPerPeer: Int = 100
    /// Max content size per message: 64KB
    private let maxContentSize: Int = 65_536

    // MARK: - Liveness

    /// A peer is alive if its `lastSeen` is within `peerTTL` OR it is pinned by
    /// being the sender or recipient of any in-flight (un-acked) message.
    private func isAlive(_ peer: Peer) -> Bool {
        let now = Date()
        if now.timeIntervalSince(peer.lastSeen) <= peerTTL { return true }
        // Pin: this peer is sender or recipient of any in-flight message
        for (_, msgs) in inbox {
            if msgs.contains(where: { $0.from == peer.id || $0.to == peer.id }) {
                return true
            }
        }
        return false
    }

    /// Returns the peer if alive; otherwise tears down peer and inbox and
    /// returns nil. Every public API gates on this to prevent revival of
    /// expired peers.
    private func aliveOrPurge(_ id: UUID) -> Peer? {
        guard let peer = peers[id] else { return nil }
        if isAlive(peer) { return peer }
        peers.removeValue(forKey: id)
        inbox.removeValue(forKey: id)
        return nil
    }

    /// Appends `message` to `recipientID`'s inbox, dropping the oldest entries
    /// when the inbox would exceed `maxMessagesPerPeer`.
    private func appendCapped(_ message: Message, to recipientID: UUID) {
        inbox[recipientID, default: []].append(message)
        if let count = inbox[recipientID]?.count, count > maxMessagesPerPeer {
            inbox[recipientID]?.removeFirst(count - maxMessagesPerPeer)
        }
    }

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

    /// Returns all peers that are alive. A peer is alive when its `lastSeen`
    /// is within `peerTTL` OR it is pinned by an in-flight message (sender or
    /// recipient). Lazily purges any peer that is no longer alive.
    func listPeers() -> [Peer] {
        let allIDs = Array(peers.keys)
        var result: [Peer] = []
        result.reserveCapacity(allIDs.count)
        for id in allIDs {
            if let peer = aliveOrPurge(id) {
                result.append(peer)
            }
        }
        return result
    }

    /// Returns the peer if alive; otherwise nil. Tears down peer and inbox
    /// when expired (consistent with listPeers' lazy purge).
    func peerStatus(id: UUID) -> Peer? {
        return aliveOrPurge(id)
    }

    // MARK: - Messaging

    /// Sends a message from one peer to another.
    /// Both sender and recipient must be alive (within `peerTTL` or pinned by
    /// an in-flight message). Bumps BOTH sender's and recipient's `lastSeen`
    /// after successful delivery. Caps recipient inbox at `maxMessagesPerPeer`.
    func sendMessage(from senderID: UUID, to recipientID: UUID, content: String) throws -> Message {
        guard content.utf8.count <= maxContentSize else {
            throw IPCError.contentTooLarge
        }
        guard aliveOrPurge(senderID) != nil else {
            throw IPCError.unregisteredPeer
        }
        guard aliveOrPurge(recipientID) != nil else {
            throw IPCError.peerNotFound(recipientID)
        }

        let now = Date()
        let message = Message(
            id: UUID(),
            from: senderID,
            to: recipientID,
            content: content,
            timestamp: now
        )
        appendCapped(message, to: recipientID)

        // Bidirectional bump: both sender and recipient remain alive.
        peers[senderID]?.lastSeen = now
        peers[recipientID]?.lastSeen = now

        return message
    }

    /// Broadcasts a message from one peer to all other alive peers.
    /// Sender must be alive. Recipients are filtered by liveness (expired
    /// peers are purged in the process). Bumps `lastSeen` on the sender and
    /// every successful recipient.
    /// Returns the array of created messages.
    func broadcast(from senderID: UUID, content: String) throws -> [Message] {
        guard content.utf8.count <= maxContentSize else {
            throw IPCError.contentTooLarge
        }
        guard aliveOrPurge(senderID) != nil else {
            throw IPCError.unregisteredPeer
        }

        let now = Date()
        let candidateIDs = Array(peers.keys).filter { $0 != senderID }
        var messages: [Message] = []

        for recipientID in candidateIDs {
            guard aliveOrPurge(recipientID) != nil else { continue }

            let message = Message(
                id: UUID(),
                from: senderID,
                to: recipientID,
                content: content,
                timestamp: now
            )
            appendCapped(message, to: recipientID)
            // Bidirectional bump: each alive recipient.
            peers[recipientID]?.lastSeen = now
            messages.append(message)
        }

        peers[senderID]?.lastSeen = now
        return messages
    }

    /// Returns all messages currently in the peer's inbox. Message retention is
    /// governed solely by recipient peer liveness (no time-based drop). Bumps
    /// the recipient's `lastSeen` and the `lastSeen` of every distinct sender
    /// of returned messages. If the peer is not alive, returns [] and purges.
    func receiveMessages(for peerID: UUID) -> [Message] {
        guard aliveOrPurge(peerID) != nil else { return [] }

        let now = Date()
        var messages = inbox[peerID] ?? []
        peers[peerID]?.lastSeen = now

        // Bump every distinct sender (no-op if a sender has since been purged).
        var seenSenders: Set<UUID> = []
        for msg in messages {
            if seenSenders.insert(msg.from).inserted {
                peers[msg.from]?.lastSeen = now
            }
        }

        // Mark every message this call returns as delivered — in the
        // stored inbox, not just the returned copies — so `inboxCount`'s
        // undelivered total (and therefore the unread badge) reflects
        // that this peer has now retrieved them. Delivery doesn't remove
        // anything from the inbox; only `ackMessages` does that.
        for index in messages.indices {
            messages[index].delivered = true
        }
        inbox[peerID] = messages

        return messages
    }

    /// Removes messages with the given IDs from a peer's inbox. Acks are an
    /// explicit liveness signal: bumps the peer's `lastSeen`. If the peer is
    /// not alive, this is a no-op and the peer is purged.
    func ackMessages(ids: [UUID], for peerID: UUID) {
        guard aliveOrPurge(peerID) != nil else { return }

        let idSet = Set(ids)
        inbox[peerID]?.removeAll { idSet.contains($0.id) }

        peers[peerID]?.lastSeen = Date()
    }

    /// Number of currently UNDELIVERED messages waiting in `peerID`'s
    /// inbox (sent but not yet returned by a `receiveMessages` call) —
    /// what `AgentRegistry`'s unread-message badge reflects. A delivered
    /// message stays in the inbox (only `ackMessages` removes it) but no
    /// longer counts here, so retrieving a peer's inbox immediately
    /// clears its badge rather than requiring a separate explicit ack.
    /// Without the side effects `receiveMessages` has (bumping
    /// `lastSeen` on the recipient and every distinct sender) — and
    /// without `aliveOrPurge`'s purge-on-expiry either, since this is a
    /// pure read used to refresh the badge after a
    /// send/broadcast/receive/ack, not a liveness-gated API. An unknown
    /// `peerID` simply has no inbox entry, reading as `0`.
    func inboxCount(for peerID: UUID) -> Int {
        (inbox[peerID] ?? []).filter { !$0.delivered }.count
    }

    /// Batch form of `inboxCount(for:)`: the undelivered count for every
    /// `peerID` in `peerIDs`, in one call. Used by `CalyxMCPServer` to
    /// refresh every bound peer's badge once per `tools/call` request
    /// instead of one `inboxCount` round trip per affected peer — see
    /// the call site's doc comment. Same read-only, no-side-effect,
    /// non-liveness-gated contract as `inboxCount(for:)`; an unknown
    /// `peerID` in `peerIDs` simply reads as `0`.
    func inboxCounts(for peerIDs: [UUID]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        result.reserveCapacity(peerIDs.count)
        for peerID in peerIDs {
            result[peerID] = inboxCount(for: peerID)
        }
        return result
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
