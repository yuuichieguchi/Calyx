//
//  HerdrSocketPaneSending.swift
//  Calyx
//
//  Types text into a herdr pane: `pane.send_text` with the text (no
//  newline), then `pane.send_keys` with one or two Return keys in a single
//  call.
//

import Foundation

struct HerdrSocketPaneSending: MCPHerdrPaneInputSending {
    /// Not confirmed against herdr's schema, which lists no key names.
    static let returnKeyName = "Return"

    private let send: @Sendable (_ method: String, _ params: [String: AnyCodable]) async throws -> Void

    /// `send` performs one socket API call.
    init(send: @escaping @Sendable (_ method: String, _ params: [String: AnyCodable]) async throws -> Void) {
        self.send = send
    }

    /// One one-shot herdr connection per call to the socket at `socketPath`.
    static func live(socketPath: String) -> HerdrSocketPaneSending {
        HerdrSocketPaneSending { method, params in
            let request = HerdrOneShotRequest(transport: BSDHerdrTransport())
            let _: AnyCodable = try await request.send(method: method, params: params, socketPath: socketPath)
        }
    }

    func sendText(paneID: String, text: String, pressReturnTwice: Bool) async throws {
        try await send("pane.send_text", [
            "pane_id": AnyCodable(paneID),
            "text": AnyCodable(text),
        ])
        let keys = Array(repeating: AnyCodable(Self.returnKeyName), count: pressReturnTwice ? 2 : 1)
        try await send("pane.send_keys", [
            "pane_id": AnyCodable(paneID),
            "keys": AnyCodable(keys),
        ])
    }
}
