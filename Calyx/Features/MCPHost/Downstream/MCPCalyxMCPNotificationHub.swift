//
//  MCPCalyxMCPNotificationHub.swift
//  Calyx
//
//  The server-to-client paths of `/calyx-mcp`: legacy GET SSE streams
//  (bound to a session nonce) and modern `subscriptions/listen` streams
//  (bound to the request's pane). Delivers `notifications/tools/list_changed`
//  to every stream when an upstream server's tools change, and only to the
//  streams of one pane when that pane's app tools change. Also tracks the
//  legacy tool calls in flight, for `notifications/cancelled`.
//
//  Every stream sends an SSE comment every `keepAliveInterval` seconds on
//  the injected clock.
//

import Foundation

actor MCPCalyxMCPNotificationHub {

    static let keepAliveInterval: TimeInterval = 15

    private struct Listener {
        /// The pane of a `subscriptions/listen` stream.
        let surfaceID: UUID?
        /// The session of a legacy GET stream. Its pane is looked up in
        /// `paneBySessionNonce` at delivery time.
        let sessionNonce: String?
        /// The `subscriptions/listen` request id, echoed in `_meta`.
        let subscriptionID: JSONRPCId?
        let wantsToolsListChanged: Bool
        let continuation: AsyncStream<Data>.Continuation
        let keepAlive: Task<Void, Never>
    }

    private let clock: any MCPClock
    private var listeners: [UUID: Listener] = [:]
    /// The pane each legacy session was last seen from. In memory only: a
    /// session id stays valid across a restart, its pane binding does not.
    private var paneBySessionNonce: [String: UUID] = [:]
    /// Servers whose `events` are being watched.
    private var watchedServers: Set<MCPServerID> = []
    private var readyServers: Set<MCPServerID> = []
    private var inFlight: [MCPDownstreamCancellationKey: [UUID: @Sendable () -> Void]] = [:]

    init(clock: any MCPClock) {
        self.clock = clock
    }

    // MARK: - Streams

    /// Opens a stream that starts with `initialFrames`.
    func openStream(
        surfaceID: UUID?,
        sessionNonce: String?,
        subscriptionID: JSONRPCId?,
        wantsToolsListChanged: Bool,
        initialFrames: [Data]
    ) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let listenerID = UUID()
        let clock = self.clock
        let keepAlive = Task {
            while !Task.isCancelled {
                await clock.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled else { return }
                continuation.yield(MCPCalyxMCPWire.keepAliveFrame)
            }
        }
        listeners[listenerID] = Listener(
            surfaceID: surfaceID,
            sessionNonce: sessionNonce,
            subscriptionID: subscriptionID,
            wantsToolsListChanged: wantsToolsListChanged,
            continuation: continuation,
            keepAlive: keepAlive
        )
        continuation.onTermination = { [weak self] _ in
            keepAlive.cancel()
            Task { await self?.removeListener(listenerID) }
        }
        for frame in initialFrames {
            continuation.yield(frame)
        }
        return stream
    }

    /// Finishes every GET stream of the session. The session id itself
    /// stays valid.
    func closeSession(nonce: String) {
        for (id, listener) in listeners where listener.sessionNonce == nonce {
            listeners[id] = nil
            listener.keepAlive.cancel()
            listener.continuation.finish()
        }
    }

    func recordPane(_ surfaceID: UUID, forSessionNonce nonce: String) {
        paneBySessionNonce[nonce] = surfaceID
    }

    private func removeListener(_ id: UUID) {
        listeners[id]?.keepAlive.cancel()
        listeners[id] = nil
    }

    // MARK: - list_changed

    /// An upstream server's tools changed: every stream.
    func upstreamToolsChanged() {
        deliverToolsListChanged { _ in true }
    }

    /// A pane's app tools changed: only that pane's streams.
    func paneAppToolsChanged(surfaceID: UUID) {
        deliverToolsListChanged { $0 == surfaceID }
    }

    private func deliverToolsListChanged(to isTarget: (UUID?) -> Bool) {
        for listener in listeners.values where listener.wantsToolsListChanged {
            let pane = listener.surfaceID ?? listener.sessionNonce.flatMap { paneBySessionNonce[$0] }
            guard isTarget(pane) else { continue }
            var params: [String: AnyCodable] = [:]
            if let subscriptionID = listener.subscriptionID {
                params["_meta"] = AnyCodable([
                    MCPCalyxMCPWire.subscriptionIDMetaKey: MCPCalyxMCPWire.idValue(subscriptionID),
                ])
            }
            listener.continuation.yield(MCPCalyxMCPWire.sseFrame(
                MCPCalyxMCPWire.notificationMessage(method: "notifications/tools/list_changed", params: params)
            ))
        }
    }

    // MARK: - Upstream servers

    /// Starts watching the `events` of every server in `serverIDs` not
    /// watched yet. A server without a connection is tried again on the
    /// next call.
    func watchServers(_ serverIDs: [MCPServerID], connections: any MCPConnectionLookup) {
        for serverID in serverIDs where watchedServers.insert(serverID).inserted {
            Task {
                if let connection = await connections.connection(forServerID: serverID) {
                    for await event in await connection.events {
                        self.serverEvent(event, serverID: serverID)
                    }
                }
                self.stopWatching(serverID)
            }
        }
    }

    private func serverEvent(_ event: MCPServerEvent, serverID: MCPServerID) {
        switch event {
        case .toolsChanged:
            upstreamToolsChanged()
        case .stateChanged(let state):
            // The catalog gains the server's tools on `ready` and loses them
            // when it leaves `ready`.
            let isReady: Bool
            if case .ready = state { isReady = true } else { isReady = false }
            let wasReady = readyServers.contains(serverID)
            guard isReady != wasReady else { return }
            if isReady { readyServers.insert(serverID) } else { readyServers.remove(serverID) }
            upstreamToolsChanged()
        }
    }

    private func stopWatching(_ serverID: MCPServerID) {
        watchedServers.remove(serverID)
        if readyServers.remove(serverID) != nil {
            upstreamToolsChanged()
        }
    }

    // MARK: - Legacy calls in flight

    func registerCall(_ key: MCPDownstreamCancellationKey, token: UUID, cancel: @escaping @Sendable () -> Void) {
        inFlight[key, default: [:]][token] = cancel
    }

    func unregisterCall(_ key: MCPDownstreamCancellationKey, token: UUID) {
        inFlight[key]?[token] = nil
        if inFlight[key]?.isEmpty == true {
            inFlight[key] = nil
        }
    }

    /// Cancels the call only when exactly one is in flight under `key`.
    func cancelCall(_ key: MCPDownstreamCancellationKey) {
        guard let calls = inFlight[key], calls.count == 1, let cancel = calls.values.first else { return }
        cancel()
    }
}
