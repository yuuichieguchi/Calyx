//
//  MCPServerAlias.swift
//  Calyx
//
//  Short, immutable name of a configured MCP server. It prefixes the
//  server's re-exported tool names and UI resource URIs.
//

import CryptoKit
import Foundation

/// `^[a-z][a-z0-9]{0,9}$`.
struct MCPServerAlias: Sendable, Equatable, Hashable, Codable, RawRepresentable {
    let rawValue: String

    static let maxLength = 10

    init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard Self.isValid(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid MCP server alias")
        }
        self.rawValue = raw
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isValid(_ raw: String) -> Bool {
        let scalars = Array(raw.unicodeScalars)
        guard let first = scalars.first, scalars.count <= maxLength, isLowercaseASCIILetter(first) else {
            return false
        }
        return scalars.allSatisfy { isLowercaseASCIILetter($0) || isASCIIDigit($0) }
    }

    fileprivate static func isLowercaseASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar)
    }

    fileprivate static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }
}

enum MCPServerAliasDeriver {

    /// Lowercases, removes everything except ASCII letters and digits,
    /// strips leading digits, and truncates to `MCPServerAlias.maxLength`.
    /// `nil` when nothing remains.
    static func derive(fromDisplayName name: String) -> String? {
        let kept = name.lowercased().unicodeScalars.filter {
            MCPServerAlias.isLowercaseASCIILetter($0) || MCPServerAlias.isASCIIDigit($0)
        }
        let body = kept.drop { MCPServerAlias.isASCIIDigit($0) }.prefix(MCPServerAlias.maxLength)
        guard !body.isEmpty else { return nil }
        var result = ""
        result.unicodeScalars.append(contentsOf: body)
        return result
    }

    /// `srv` followed by the first 7 hex digits of the SHA-256 of the
    /// server id's UUID string.
    static func fallback(forServerID id: MCPServerID) -> String {
        let digest = SHA256.hash(data: Data(id.rawValue.uuidString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "srv" + hex.prefix(MCPServerAlias.maxLength - 3)
    }
}
