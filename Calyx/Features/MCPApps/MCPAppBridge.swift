//
//  MCPAppBridge.swift
//  Calyx
//
//  The host end of one view's postMessage channel. The bridge script in
//  the named content world has already matched `event.source` and
//  `event.origin`; this handler also requires the message to come from
//  the host page's main frame in that world. Messages are serialized
//  JSON-RPC, at most 16 MiB, parsed with `JSONRPCMessage.parse`.
//

import Foundation
import WebKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "MCPAppBridge")

/// Handles what the view sends.
@MainActor
protocol MCPAppBridgeDelegate: AnyObject {
    /// Returns the result object, or the JSON-RPC error to reply with.
    func bridge(_ bridge: MCPAppBridge, didReceiveRequest method: String, params: [String: AnyCodable]?) async
        -> Result<AnyCodable, JSONRPCError>
    func bridge(_ bridge: MCPAppBridge, didReceiveNotification method: String, params: [String: AnyCodable]?)
}

enum MCPAppBridgeError: Error, Equatable {
    /// The web view is gone or its host page has no view iframe.
    case viewUnavailable
    /// The bridge was closed while the request was waiting for its reply.
    case closed
}

@MainActor
final class MCPAppBridge: NSObject, WKScriptMessageHandlerWithReply {

    /// The world the bridge script and handler live in, invisible to the page.
    nonisolated static let worldName = "calyxMcpAppBridge"

    weak var delegate: (any MCPAppBridgeDelegate)?
    weak var webView: WKWebView?
    let world: WKContentWorld

    private var pendingReplies: [String: CheckedContinuation<JSONRPCMessage, Error>] = [:]
    private var nextRequestNumber = 0
    private var isClosed = false
    /// `ui/notifications/initialized` arrived since the last load.
    private(set) var hasReceivedInitialized = false

    init(world: WKContentWorld = .world(name: MCPAppBridge.worldName)) {
        self.world = world
    }

    // MARK: - View to host

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard message.world == world, message.frameInfo.isMainFrame, let text = message.body as? String else {
            replyHandler(nil, "Rejected")
            return
        }
        guard text.utf8.count <= MCPAppBridgeDispatch.maxMessageBytes else {
            Self.reply(.response(id: nil, result: nil, error: JSONRPCError(
                code: -32600, message: "Message exceeds \(MCPAppBridgeDispatch.maxMessageBytes) bytes.", data: nil
            )), with: replyHandler)
            return
        }

        let parsed: JSONRPCMessage
        do {
            parsed = try JSONRPCMessage.parse(Data(text.utf8))
        } catch {
            Self.reply(.response(id: nil, result: nil, error: JSONRPCError(
                code: -32700, message: "Parse error", data: nil
            )), with: replyHandler)
            return
        }

        switch parsed {
        case .request(let id, let method, let params):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let reply = await self.reply(to: id, method: method, params: params)
                Self.reply(reply, with: replyHandler)
            }
        case .notification(let method, let params):
            if method == "ui/notifications/initialized" { hasReceivedInitialized = true }
            delegate?.bridge(self, didReceiveNotification: method, params: params)
            replyHandler(nil, nil)
        case .response(let id, let result, let error):
            resolveReply(id: id, message: .response(id: id, result: result, error: error))
            replyHandler(nil, nil)
        case .batch:
            Self.reply(.response(id: nil, result: nil, error: JSONRPCError(
                code: -32600, message: "Batches are not supported.", data: nil
            )), with: replyHandler)
        }
    }

    private func reply(to id: JSONRPCId, method: String, params: [String: AnyCodable]?) async -> JSONRPCMessage {
        if let error = MCPAppBridgeDispatch.validate(initialized: hasReceivedInitialized, method: method)
            ?? MCPAppBridgeDispatch.validateParams(method: method, params: params.map { AnyCodable($0) }) {
            return .response(id: id, result: nil, error: error)
        }
        guard let delegate else {
            return .response(id: id, result: nil, error: JSONRPCError(code: -32000, message: "The view is closing.", data: nil))
        }
        switch await delegate.bridge(self, didReceiveRequest: method, params: params) {
        case .success(let result):
            return .response(id: id, result: result, error: nil)
        case .failure(let error):
            return .response(id: id, result: nil, error: error)
        }
    }

    // MARK: - Host to view

    /// Posts a notification, or a request and waits for its reply. A
    /// request's id is replaced by one of the bridge's own. A request ends
    /// with the view's reply, with `CancellationError` when the awaiting
    /// task is cancelled, or with `.closed` when the bridge closes (the
    /// view is torn down or its process ended). It has no timer.
    func send(_ message: JSONRPCMessage) async throws -> JSONRPCMessage? {
        guard !isClosed, let webView else { throw MCPAppBridgeError.viewUnavailable }
        switch message {
        case .request(_, let method, let params):
            nextRequestNumber += 1
            let key = "calyx-host-\(nextRequestNumber)"
            let request = JSONRPCMessage.request(id: .string(key), method: method, params: params)
            let json = try Self.serialize(request)
            let world = world
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingReplies[key] = continuation
                    // The cancellation handler hops to the main actor, so it
                    // runs after this registration even for a task that was
                    // already cancelled.
                    Task { @MainActor [weak self] in
                        do {
                            let posted = try await MCPAppWebViewFactory.postToView(webView, json: json, world: world)
                            if !posted { self?.failReply(key: key, error: MCPAppBridgeError.viewUnavailable) }
                        } catch {
                            self?.failReply(key: key, error: error)
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.failReply(key: key, error: CancellationError())
                }
            }
        default:
            let json = try Self.serialize(message)
            let posted = try await MCPAppWebViewFactory.postToView(webView, json: json, world: world)
            guard posted else { throw MCPAppBridgeError.viewUnavailable }
            return nil
        }
    }

    /// Fails every waiting request. Later sends throw.
    func close() {
        isClosed = true
        let pending = pendingReplies
        pendingReplies.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: MCPAppBridgeError.closed)
        }
    }

    // MARK: - Private

    private func resolveReply(id: JSONRPCId?, message: JSONRPCMessage) {
        guard case .string(let key)? = id, let continuation = pendingReplies.removeValue(forKey: key) else {
            logger.debug("Dropped a view response with no matching host request")
            return
        }
        continuation.resume(returning: message)
    }

    private func failReply(key: String, error: Error) {
        pendingReplies.removeValue(forKey: key)?.resume(throwing: error)
    }

    private static func serialize(_ message: JSONRPCMessage) throws -> String {
        String(decoding: try message.serialize(), as: UTF8.self)
    }

    /// A serialization failure rejects the script's promise with the error.
    private static func reply(_ message: JSONRPCMessage, with replyHandler: @MainActor @Sendable (Any?, String?) -> Void) {
        do {
            replyHandler(try serialize(message), nil)
        } catch {
            logger.error("Could not serialize a reply to the view: \(error, privacy: .public)")
            replyHandler(nil, "\(error)")
        }
    }
}
