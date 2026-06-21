//
//  PositionEncodingKind.swift
//  Calyx
//
//  LSP 3.18 PositionEncodingKind. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#positionEncodingKind
//
//  Wire shape is a string with three known values: `"utf-8" | "utf-16" |
//  "utf-32"`. The default (when the server does not negotiate one) is
//  `utf-16`. Unknown string values must fail to decode rather than be
//  silently accepted.
//

import Foundation

/// Position-encoding kinds supported by LSP 3.17+. The raw values use the
/// hyphenated spelling required on the wire.
enum PositionEncodingKind: String, Sendable, Codable, Equatable, Hashable {
    case utf8 = "utf-8"
    case utf16 = "utf-16"
    case utf32 = "utf-32"
}
