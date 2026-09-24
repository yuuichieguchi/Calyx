//
//  MCPAppFilenameSanitizer.swift
//  Calyx
//
//  File names for `ui/download-file` and for non-text `ui/message`
//  content written to disk.
//

import Foundation

enum MCPAppFilenameSanitizer {
    static let maxBytes = 255
    static let emptyName = "download"

    /// Path separators, `:` and control characters become `_`; leading dots
    /// and surrounding whitespace go; the body is cut to keep the UTF-8
    /// name within 255 bytes with its extension; an empty result is
    /// "download"; a case-insensitive collision with `existingNames` gets
    /// " (2)", " (3)", ... before the extension.
    static func sanitize(_ name: String, existingNames: [String]) -> String {
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.map { scalar -> Unicode.Scalar in
            if scalar == "/" || scalar == "\\" || scalar == ":" || scalar.properties.generalCategory == .control {
                return "_"
            }
            return scalar
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = emptyName }

        let (body, ext) = splitExtension(cleaned)
        let taken = Set(existingNames.map { $0.lowercased() })
        var candidate = fitted(body: body, suffix: "", ext: ext)
        var counter = 2
        while taken.contains(candidate.lowercased()) {
            candidate = fitted(body: body, suffix: " (\(counter))", ext: ext)
            counter += 1
        }
        return candidate
    }

    /// `ext` includes its leading dot. A name whose only dot is its first
    /// character has no extension.
    private static func splitExtension(_ name: String) -> (body: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    private static func fitted(body: String, suffix: String, ext: String) -> String {
        var trimmedBody = body
        while (trimmedBody + suffix + ext).utf8.count > maxBytes, !trimmedBody.isEmpty {
            trimmedBody.removeLast()
        }
        return trimmedBody + suffix + ext
    }
}
