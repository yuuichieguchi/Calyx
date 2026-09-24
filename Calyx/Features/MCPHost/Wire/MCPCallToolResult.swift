//
//  MCPCallToolResult.swift
//  Calyx
//
//  Result of an upstream `tools/call`, kept as raw JSON.
//

import Foundation

/// The upstream `tools/call` result object, held verbatim.
///
/// `content`, `structuredContent`, `isError`, `resultType`, `_meta`, and any
/// key the schema does not name are all preserved as received. A missing
/// `resultType` (servers older than 2026-07-28) stays missing; readers treat
/// it as `"complete"`.
struct MCPCallToolResult: Sendable, Equatable {
    let raw: [String: AnyCodable]
}
