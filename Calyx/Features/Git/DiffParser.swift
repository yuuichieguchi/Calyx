// DiffParser.swift
// Calyx
//
// Parses unified diff output into structured DiffLine arrays.

import Foundation

enum DiffParser {
    private static let maxBytes = 1_000_000
    private static let maxLines = 50_000

    static func parse(_ raw: String, path: String) -> FileDiff {
        guard !raw.isEmpty else {
            return FileDiff(path: path, lines: [], isBinary: false, isTruncated: false)
        }

        var input = raw
        var isTruncated = false

        if input.utf8.count > maxBytes {
            let index = input.utf8.index(input.utf8.startIndex, offsetBy: maxBytes)
            input = String(input[..<index])
            isTruncated = true
        }

        let rawLines = input.components(separatedBy: "\n")
        var lines: [DiffLine] = []
        var isBinary = false

        var inHunk = false
        var oldLine = 0
        var newLine = 0

        for rawLine in rawLines {
            if lines.count >= maxLines {
                isTruncated = true
                break
            }

            if rawLine.hasPrefix("diff --git ") {
                inHunk = false
                lines.append(DiffLine(type: .meta, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                continue
            }

            if !inHunk {
                if rawLine.hasPrefix("Binary files ") && rawLine.hasSuffix(" differ") {
                    isBinary = true
                    lines.append(DiffLine(type: .meta, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                    continue
                }
                if rawLine.hasPrefix("GIT binary patch") {
                    isBinary = true
                    lines.append(DiffLine(type: .meta, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                    continue
                }
                if rawLine.hasPrefix("@@") {
                    let parsed = parseHunkHeader(rawLine)
                    oldLine = parsed.oldStart
                    newLine = parsed.newStart
                    inHunk = true
                    lines.append(DiffLine(type: .hunkHeader, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                    continue
                }
                if rawLine.hasPrefix("index ") || rawLine.hasPrefix("--- ") || rawLine.hasPrefix("+++ ") ||
                   rawLine.hasPrefix("new file mode") || rawLine.hasPrefix("deleted file mode") ||
                   rawLine.hasPrefix("rename from ") || rawLine.hasPrefix("rename to ") ||
                   rawLine.hasPrefix("similarity index") || rawLine.hasPrefix("old mode") ||
                   rawLine.hasPrefix("new mode") {
                    lines.append(DiffLine(type: .meta, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                    continue
                }
                lines.append(DiffLine(type: .meta, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                continue
            }

            // Inside hunk
            if rawLine.hasPrefix("@@") {
                let parsed = parseHunkHeader(rawLine)
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                lines.append(DiffLine(type: .hunkHeader, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                continue
            }

            if rawLine.hasPrefix("+") {
                lines.append(DiffLine(type: .addition, text: rawLine, oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
                continue
            }

            if rawLine.hasPrefix("-") {
                lines.append(DiffLine(type: .deletion, text: rawLine, oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
                continue
            }

            if rawLine.hasPrefix(" ") || (rawLine.isEmpty && inHunk) {
                lines.append(DiffLine(type: .context, text: rawLine, oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
                continue
            }

            if rawLine.hasPrefix("\\") {
                lines.append(DiffLine(type: .meta, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
                continue
            }

            lines.append(DiffLine(type: .meta, text: rawLine, oldLineNumber: nil, newLineNumber: nil))
        }

        return FileDiff(path: path, lines: lines, isBinary: isBinary, isTruncated: isTruncated)
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int) {
        let scanner = Scanner(string: line)
        _ = scanner.scanString("@@")
        _ = scanner.scanString("-")

        let oldStart = scanner.scanInt() ?? 1
        if scanner.scanString(",") != nil {
            _ = scanner.scanInt()
        }

        _ = scanner.scanString("+")
        let newStart = scanner.scanInt() ?? 1

        return (oldStart, newStart)
    }
}
