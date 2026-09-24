//
//  MCPServerID.swift
//  Calyx
//
//  Stable identifier of a configured upstream MCP server.
//

import Foundation

/// Encodes and decodes as a bare UUID string.
struct MCPServerID: Sendable, Equatable, Hashable, Codable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
