//
//  MCPProtocolVersion.swift
//  Calyx
//
//  MCP protocol revisions Calyx negotiates with upstream servers.
//

import Foundation

/// An MCP protocol revision string.
enum MCPProtocolVersion: String, Sendable, CaseIterable, Equatable, Codable {
    case v2026_07_28 = "2026-07-28"
    case v2025_11_25 = "2025-11-25"
    case v2025_06_18 = "2025-06-18"
    case v2025_03_26 = "2025-03-26"
    case v2024_11_05 = "2024-11-05"

    /// True for the stateless revision (`server/discover`, per-request `_meta`);
    /// false for every revision that uses the `initialize` handshake.
    var isModern: Bool { self == .v2026_07_28 }
}
