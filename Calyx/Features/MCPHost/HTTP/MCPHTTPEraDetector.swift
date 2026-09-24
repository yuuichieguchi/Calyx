//
//  MCPHTTPEraDetector.swift
//  Calyx
//
//  Maps the outcome of one Streamable HTTP era probe to a verdict, per
//  the backwards-compatibility section of the 2026-07-28 Streamable HTTP
//  transport. Sends and receives nothing.
//

import Foundation

enum MCPHTTPProbe: Sendable, Equatable {
    case discover
    case initialize
}

enum MCPHTTPProbeVerdict: Sendable, Equatable {
    /// `server/discover` answered 200, or 400 with a recognized modern
    /// JSON-RPC error (-32020, -32021, -32022).
    case modern
    /// `initialize` answered 200.
    case legacyStreamableHTTP
    /// `server/discover` answered 400, 404 or 405 without a recognized
    /// modern error: probe `initialize` next.
    case fallBack
    /// `initialize` answered 400, 404 or 405: use the 2024-11-05 HTTP+SSE
    /// transport.
    case legacySSERequired
    /// Either probe answered 401.
    case authorizationRequired
    /// Any other status.
    case failed
}

enum MCPHTTPEraDetector {

    private static let endpointMissingStatuses: Set<Int> = [400, 404, 405]

    static func classify(probe: MCPHTTPProbe, status: Int, bodyIsRecognizedModernError: Bool) -> MCPHTTPProbeVerdict {
        if status == 401 { return .authorizationRequired }
        switch probe {
        case .discover:
            if status == 200 { return .modern }
            if status == 400 && bodyIsRecognizedModernError { return .modern }
            return endpointMissingStatuses.contains(status) ? .fallBack : .failed
        case .initialize:
            if status == 200 { return .legacyStreamableHTTP }
            return endpointMissingStatuses.contains(status) ? .legacySSERequired : .failed
        }
    }
}
