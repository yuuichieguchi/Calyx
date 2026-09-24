//
//  MCPDownstreamCancellationKey.swift
//  Calyx
//
//  Identifies an in-flight legacy `/calyx-mcp` request for
//  `notifications/cancelled`. The modern generation cancels the route's
//  Task when the request's connection closes and does not use this key.
//

import Foundation

struct MCPDownstreamCancellationKey: Sendable, Equatable, Hashable {
    /// The legacy session's nonce. Nil for a session-less request.
    let sessionNonce: String?
    let requestID: JSONRPCId

    // `JSONRPCId` is not `Hashable`, so hashing is spelled out here.
    func hash(into hasher: inout Hasher) {
        hasher.combine(sessionNonce)
        switch requestID {
        case .int(let value):
            hasher.combine(0)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(1)
            hasher.combine(value)
        }
    }
}
