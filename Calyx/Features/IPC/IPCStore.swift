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
    /// Max messages per peer inbox
    private let maxMessagesPerPeer: Int = 100
    /// Max content size per message: 64KB
    private let maxContentSize: Int = 65_536

    // MARK: - Liveness

    /// A peer is alive if its `lastSeen` is within `peerTTL` OR it is pinned by
    /// being the sender or recipient of any in-flight (not yet received)
    /// message.
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

    /// Updates an existing peer's `name`/`role` in place and bumps its
    /// `lastSeen`, preserving `id` and `registeredAt` — a rename, not a
    /// re-registration. `nil` for either parameter keeps that field's
    /// current value unchanged (Round 6 review: `CalyxMCPServer.handleRegisterPeer`
    /// passes `nil` for an omitted or empty `register_peer` argument so a
    /// caller that only supplies a new `name` doesn't blank out the
    /// existing `role`, or vice versa). Returns the updated `Peer`, or
    /// `nil` if `id` has no registered (alive) peer. Round 6: backs
    /// `handleRegisterPeer`'s rename semantics — a surface with an
    /// already-bound, still-alive peer gets that peer renamed instead of
    /// a second identity being minted, closing the "two peers per pane"
    /// defect.
    func updatePeer(id: UUID, name: String?, role: String?) -> Peer? {
        guard let existing = aliveOrPurge(id) else { return nil }
        let updated = Peer(
            id: existing.id,
            name: name ?? existing.name,
            role: role ?? existing.role,
            lastSeen: Date(),
            registeredAt: existing.registeredAt
        )
        peers[updated.id] = updated
        return updated
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

    /// Returns all messages currently in the peer's inbox, deleting them
    /// from the inbox in the same call (delete-on-read, at-most-once
    /// delivery) — a message a `receiveMessages` call returns will never
    /// be returned again. Bumps the recipient's `lastSeen` and the
    /// `lastSeen` of every distinct sender of returned messages. If the
    /// peer is not alive, returns [] and purges.
    ///
    /// Round 7: replaces the earlier at-least-once contract (a message
    /// stayed in the inbox, merely marked delivered, until a separate
    /// `ackMessages` call removed it). In practice `ackMessages` was
    /// rarely called — MCP instructions never told a client it needed
    /// to — so inboxes only grew, and an agent could stumble onto a
    /// stale message from a call it had already processed. A pull-based
    /// inbox reads more naturally as "read it, it's gone" than as a
    /// two-step read-then-acknowledge protocol, so delete-on-read is now
    /// the only contract; there is no ack step to skip. This deletion is
    /// final except for the one narrow case `requeue` undoes (see its
    /// doc comment for exactly which failure that is, and which ones it
    /// deliberately does not cover) — under the at-most-once contract, a
    /// caller-side failure to actually deliver the returned messages is
    /// accepted, permanent loss, not something this store recovers from.
    func receiveMessages(for peerID: UUID) -> [Message] {
        guard aliveOrPurge(peerID) != nil else { return [] }

        let now = Date()
        let messages = inbox[peerID] ?? []
        inbox[peerID] = []
        peers[peerID]?.lastSeen = now

        // Bump every distinct sender (no-op if a sender has since been purged).
        var seenSenders: Set<UUID> = []
        for msg in messages {
            if seenSenders.insert(msg.from).inserted {
                peers[msg.from]?.lastSeen = now
            }
        }

        return messages
    }

    /// Restores `messages` to the FRONT of `peerID`'s inbox, ahead of
    /// anything already present, preserving their original relative
    /// order. Exists solely to undo a `receiveMessages` call's deletion
    /// when a later step fails after the fact — `CalyxMCPServer.
    /// handleReceiveMessages` calls this if it can't serialize the
    /// result, so a serialization failure doesn't silently lose messages
    /// `receiveMessages` already committed to removing from the store.
    /// `messages` are placed ahead of whatever is already in the inbox
    /// (e.g. a message that arrived during the gap between the failed
    /// `receiveMessages` call and this one) so the next `receiveMessages`
    /// call returns them first, in the order they were originally sent —
    /// same drop-oldest-first capping as `appendCapped` if the combined
    /// total exceeds `maxMessagesPerPeer`. If the peer is no longer
    /// alive, this is a no-op: there is no inbox left to requeue into,
    /// and a peer that expired in that same gap should not be revived by
    /// a requeue. A no-op for an empty `messages` too, since there is
    /// nothing to restore.
    ///
    /// Scope: this only covers the synchronous `JSONSerialization`
    /// failure inside `handleReceiveMessages` that calls it directly. It
    /// does NOT cover, and cannot recover from, a failure at either of
    /// the two later points on that same response path — the JSON-RPC
    /// envelope's own re-encode in `toolSuccess`, or a network-layer
    /// failure writing the HTTP response — both of which lose the
    /// already-deleted messages permanently. That's the accepted
    /// boundary of the at-most-once contract this round establishes, not
    /// a gap `requeue` is meant to close.
    ///
    /// Unlike `sendMessage`, `broadcast`, and `receiveMessages`, this
    /// does not bump `peerID`'s `lastSeen` — it's a server-internal
    /// recovery step undoing this store's own prior deletion, not a
    /// client-initiated liveness signal.
    func requeue(_ messages: [Message], for peerID: UUID) {
        guard aliveOrPurge(peerID) != nil else { return }
        guard !messages.isEmpty else { return }

        var combined = messages + (inbox[peerID] ?? [])
        if combined.count > maxMessagesPerPeer {
            combined.removeFirst(combined.count - maxMessagesPerPeer)
        }
        inbox[peerID] = combined
    }

    /// Number of messages currently waiting in `peerID`'s inbox — what
    /// `AgentRegistry`'s unread-message badge reflects. Since
    /// `receiveMessages` deletes every message it returns, this is
    /// simply the inbox's current size; there is no separate
    /// delivered/undelivered distinction to track. Without the side
    /// effects `receiveMessages` has (bumping `lastSeen` on the
    /// recipient and every distinct sender) — and without
    /// `aliveOrPurge`'s purge-on-expiry either, since this is a pure
    /// read used to refresh the badge after a send/broadcast/receive,
    /// not a liveness-gated API. An unknown `peerID` simply has no
    /// inbox entry, reading as `0`.
    func inboxCount(for peerID: UUID) -> Int {
        (inbox[peerID] ?? []).count
    }

    /// Batch form of `inboxCount(for:)`: the current inbox count for
    /// every `peerID` in `peerIDs`, in one call. Used by
    /// `CalyxMCPServer` to refresh every bound peer's badge once per
    /// `tools/call` request instead of one `inboxCount` round trip per
    /// affected peer — see the call site's doc comment. Same read-only,
    /// no-side-effect, non-liveness-gated contract as
    /// `inboxCount(for:)`; an unknown `peerID` in `peerIDs` simply reads
    /// as `0`.
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
