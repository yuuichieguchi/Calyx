//
//  MCPExportedName.swift
//  Calyx
//
//  The tool name Calyx re-exports for an upstream tool: `<alias>-<tool>`.
//

import CryptoKit
import Foundation

enum MCPExportedName {

    /// 64, the model function-name limit, minus 16, the longest CLI prefix.
    static let maxLength = 48

    private static let shortHashLength = 6
    private static let longHashLength = 12

    /// `<alias>-<tool>` when the tool name uses only `[A-Za-z0-9_-]` and
    /// the result fits in `maxLength`; `isTaken` is not called then.
    /// Otherwise each other character becomes `_`, and `-` plus the first
    /// 6 lowercase hex digits of the SHA-256 of the UTF-8 upstream name is
    /// appended, the tool part truncated so the whole stays within
    /// `maxLength`. When `isTaken` reports that name, the suffix grows to
    /// 12 hex digits. The 12-digit name is returned whatever `isTaken`
    /// reports for it; the caller rejects a name that is still taken.
    static func name(alias: String, upstreamToolName: String, isTaken: (String) -> Bool) -> String {
        if let verbatim = verbatimName(alias: alias, upstreamToolName: upstreamToolName) {
            return verbatim
        }
        let sanitized = String(upstreamToolName.map { isAllowed($0) ? $0 : "_" })
        let hex = SHA256.hash(data: Data(upstreamToolName.utf8)).map { String(format: "%02x", $0) }.joined()

        let short = hashedName(alias: alias, sanitized: sanitized, suffix: "-" + hex.prefix(shortHashLength))
        guard isTaken(short) else { return short }
        let long = hashedName(alias: alias, sanitized: sanitized, suffix: "-" + hex.prefix(longHashLength))
        _ = isTaken(long)
        return long
    }

    /// The `<alias>-<tool>` name when it needs no replacement and no
    /// truncation, else nil.
    static func verbatimName(alias: String, upstreamToolName: String) -> String? {
        let candidate = alias + "-" + upstreamToolName
        guard upstreamToolName.allSatisfy(isAllowed), candidate.count <= maxLength else { return nil }
        return candidate
    }

    private static func hashedName(alias: String, sanitized: String, suffix: String) -> String {
        let bodyLength = maxLength - alias.count - 1 - suffix.count
        return alias + "-" + sanitized.prefix(bodyLength) + suffix
    }

    private static func isAllowed(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-":
            return true
        default:
            return false
        }
    }
}
