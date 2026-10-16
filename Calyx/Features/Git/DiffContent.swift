// DiffContent.swift
// Calyx
//
// Reconstructs both sides of a file from a full-context (`-U2147483647`)
// unified diff: old = context + deletions, new = context + additions.

import Foundation

enum DiffComputationLimits {
    /// VS Code's diff editor `maxFileSize` (50 MB): above this no diff is computed.
    static let maxFileSizeBytes = 50 * 1024 * 1024
}

struct DiffContent: Equatable, Sendable {
    let oldLines: [String]
    let newLines: [String]
    let isBinary: Bool
    let oldMissingTrailingNewline: Bool
    let newMissingTrailingNewline: Bool

    static func exceedsMaxFileSize(byteCount: Int) -> Bool {
        byteCount > DiffComputationLimits.maxFileSizeBytes
    }

    private enum LastSide {
        case none
        case old
        case new
        case both
    }

    /// Returns a hunk line's text without its one-character marker and without
    /// one trailing "\r", so CRLF files yield lines without EOL characters, as
    /// VS Code's `splitLines` does. Any other "\r" (embedded, or a second
    /// trailing one) is kept verbatim: git defines the line structure by "\n",
    /// so a diff line cannot be split further. U+2028/U+2029 are untouched.
    private static func contentText(_ rawLine: String) -> String {
        var scalars = Substring(rawLine).unicodeScalars.dropFirst()
        if scalars.last == "\r" {
            scalars = scalars.dropLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Parses the hunk body of a unified diff. Header lines (`diff --git`, `index`,
    /// `---`, `+++`, mode / rename lines) are skipped; binary diffs set `isBinary`.
    /// Expects a single hunk; additional hunks are appended in order.
    static func extract(from raw: String) -> DiffContent {
        // git terminates every output line with "\n"; drop that terminator so the
        // split does not yield a phantom empty line.
        // Compare unicode scalars: in Swift, "\r\n" is one Character, so
        // `String.hasSuffix("\n")` is false for CRLF output.
        let body = raw.unicodeScalars.last == "\n"
            ? String(String.UnicodeScalarView(raw.unicodeScalars.dropLast()))
            : raw
        guard !body.isEmpty else {
            return DiffContent(oldLines: [], newLines: [], isBinary: false,
                               oldMissingTrailingNewline: false, newMissingTrailingNewline: false)
        }

        var oldLines: [String] = []
        var newLines: [String] = []
        var isBinary = false
        var oldMissingTrailingNewline = false
        var newMissingTrailingNewline = false

        var inHunk = false
        var lastSide = LastSide.none

        for rawLine in body.components(separatedBy: "\n") {
            if rawLine.hasPrefix("diff --git ") {
                inHunk = false
                lastSide = .none
                continue
            }

            if !inHunk {
                if rawLine.hasPrefix("Binary files ") && rawLine.hasSuffix(" differ") {
                    isBinary = true
                    continue
                }
                if rawLine.hasPrefix("GIT binary patch") {
                    isBinary = true
                    continue
                }
                if rawLine.hasPrefix("@@") {
                    inHunk = true
                    lastSide = .none
                }
                // Every other line outside a hunk is a header line.
                continue
            }

            if rawLine.hasPrefix("@@") {
                lastSide = .none
                continue
            }

            if rawLine.hasPrefix("+") {
                newLines.append(contentText(rawLine))
                lastSide = .new
                continue
            }

            if rawLine.hasPrefix("-") {
                oldLines.append(contentText(rawLine))
                lastSide = .old
                continue
            }

            if rawLine.hasPrefix(" ") || rawLine.isEmpty {
                let text = contentText(rawLine)
                oldLines.append(text)
                newLines.append(text)
                lastSide = .both
                continue
            }

            if rawLine.hasPrefix("\\") {
                // "\ No newline at end of file" applies to the line just above it.
                switch lastSide {
                case .old:
                    oldMissingTrailingNewline = true
                case .new:
                    newMissingTrailingNewline = true
                case .both:
                    oldMissingTrailingNewline = true
                    newMissingTrailingNewline = true
                case .none:
                    break
                }
                continue
            }
        }

        return DiffContent(
            oldLines: oldLines,
            newLines: newLines,
            isBinary: isBinary,
            oldMissingTrailingNewline: oldMissingTrailingNewline,
            newMissingTrailingNewline: newMissingTrailingNewline
        )
    }
}
