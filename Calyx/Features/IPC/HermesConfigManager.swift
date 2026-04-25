// HermesConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.hermes/config.yaml for the Calyx IPC MCP server.
//
// Hermes uses YAML. Rather than introduce a YAML parser dependency, this
// manager performs surgical string/regex edits around a delimited managed
// block (BEGIN/END markers). Two insertion modes:
//
//   - Case A: file has no top-level `mcp_servers:` key — the managed block
//     is appended at EOF and contains its own `mcp_servers:` parent.
//   - Case B: file already has a top-level `mcp_servers:` key — only the
//     `calyx-ipc:` child entry is inserted under it, with comment markers
//     and the entry indented to the learned child indent.

import Foundation

// MARK: - HermesConfigError

enum HermesConfigError: Error, LocalizedError {
    case symlinkDetected
    case invalidEncoding
    case unsupportedYamlStructure(String)
    case malformedManagedBlock(String)
    case invalidScalarValue
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .symlinkDetected:
            return "The Hermes config path is a symlink, which is not allowed for security reasons"
        case .invalidEncoding:
            return "The Hermes config file is not valid UTF-8"
        case .unsupportedYamlStructure(let reason):
            return "Unsupported YAML structure in Hermes config: \(reason)"
        case .malformedManagedBlock(let reason):
            return "Malformed Calyx-managed block in Hermes config: \(reason)"
        case .invalidScalarValue:
            return "Cannot write value: contains characters that are not safe for a YAML double-quoted scalar"
        case .writeFailed(let reason):
            return "Failed to write Hermes config file: \(reason)"
        }
    }
}

// MARK: - HermesConfigManager

struct HermesConfigManager: Sendable {

    // MARK: - Constants

    private static let beginLine = "# BEGIN CALYX IPC (managed by Calyx, do not edit)"
    private static let endLine = "# END CALYX IPC"

    /// Matches a Calyx BEGIN marker line. The line must consist of (optional
    /// indent) + `#` + (optional whitespace) + `BEGIN CALYX IPC` + word boundary
    /// + arbitrary trailing text. Anchored to line start to avoid false-positive
    /// matches on user prose that mentions the literal mid-line.
    private static let beginLineRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*#\s*BEGIN CALYX IPC\b[^\n]*$"#
    )

    /// Matches a Calyx END marker line.
    private static let endLineRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*#\s*END CALYX IPC\s*$"#
    )

    /// Matches a `calyx-ipc:` key line at any indent (used to validate the
    /// inside of a BEGIN/END span before treating it as a real managed block).
    private static let calyxIPCKeyRegex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*calyx-ipc:\s*$"#
    )

    /// Matches a top-level `mcp_servers:` key line (no indent, value empty
    /// after the colon — i.e. introduces a block-style mapping).
    private static let topLevelMcpServersRegex = try! NSRegularExpression(
        pattern: #"(?m)^mcp_servers:\s*$"#
    )

    /// Matches a top-level `mcp_servers:` key with an inline value on the
    /// same line (e.g. `mcp_servers: {}` or `mcp_servers: [a]`). Treated as
    /// an unsupported structure because we cannot safely splice into it.
    private static let inlineMcpServersRegex = try! NSRegularExpression(
        pattern: #"(?m)^mcp_servers:\s*[\{\[].*$"#
    )

    // MARK: - Public API

    /// Enables Calyx IPC by upserting the managed block in the Hermes config.
    /// Self-heals over previously-malformed managed blocks (orphan BEGIN/END,
    /// or BEGIN/END pairs missing the `calyx-ipc:` body) by stripping anything
    /// that looks like a managed block before writing fresh content.
    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw HermesConfigError.symlinkDetected
        }

        let existing: String
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw HermesConfigError.invalidEncoding
            }
            existing = decoded.replacingOccurrences(of: "\r\n", with: "\n")
        } else {
            existing = ""
        }

        let cleaned = stripAllManagedRegions(from: existing)

        let url = "http://localhost:\(port)/mcp"
        let authorization = "Bearer \(token)"
        let urlScalar = try yamlDoubleQuotedScalar(url)
        let authScalar = try yamlDoubleQuotedScalar(authorization)

        // Detect inline mcp_servers AFTER stripping managed regions so a
        // managed-block-internal `mcp_servers: {}` does not trigger.
        if firstMatch(of: inlineMcpServersRegex, in: cleaned) != nil {
            throw HermesConfigError.unsupportedYamlStructure("inline mcp_servers map not supported")
        }

        let result: String
        if let mcpServersRange = firstMatch(of: topLevelMcpServersRegex, in: cleaned) {
            result = try insertCaseB(
                into: cleaned,
                mcpServersLineRange: mcpServersRange,
                urlScalar: urlScalar,
                authScalar: authScalar
            )
        } else {
            result = appendCaseA(to: cleaned, urlScalar: urlScalar, authScalar: authScalar)
        }

        guard let data = result.data(using: .utf8) else {
            throw HermesConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: data, to: path, lockPath: path + ".lock")
    }

    /// Disables Calyx IPC by removing the managed block(s) from the config.
    /// Throws `.malformedManagedBlock` on orphan BEGIN, orphan END, or
    /// BEGIN/END pairs lacking the `calyx-ipc:` body, since silent removal
    /// would risk discarding user intent.
    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        guard FileManager.default.fileExists(atPath: path) else { return }

        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw HermesConfigError.symlinkDetected
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let decoded = String(data: data, encoding: .utf8) else {
            throw HermesConfigError.invalidEncoding
        }
        let normalized = decoded.replacingOccurrences(of: "\r\n", with: "\n")

        try validateNoMalformedBlocks(in: normalized)

        let cleaned = stripValidManagedBlocks(from: normalized)
        guard cleaned != normalized else { return }

        guard let outData = cleaned.data(using: .utf8) else {
            throw HermesConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: outData, to: path, lockPath: path + ".lock")
    }

    /// Returns true iff at least one well-formed managed block exists
    /// (BEGIN line, then `calyx-ipc:` line, then END line — in that order,
    /// with no nested BEGIN/END between them).
    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        let path = configPath ?? defaultConfigPath

        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = String(data: data, encoding: .utf8) else {
            return false
        }
        let normalized = decoded.replacingOccurrences(of: "\r\n", with: "\n")
        // Fast-path: skip the regex pipeline when no marker substring is present.
        guard normalized.contains("BEGIN CALYX IPC") else { return false }
        return findValidManagedBlocks(in: normalized).isEmpty == false
    }

    // MARK: - Private: Defaults

    private static var defaultConfigPath: String {
        NSHomeDirectory() + "/.hermes/config.yaml"
    }

    // MARK: - Private: Insertion (Case A — append at EOF)

    private static func appendCaseA(to existing: String, urlScalar: String, authScalar: String) -> String {
        let block = """
        \(beginLine)
        mcp_servers:
          calyx-ipc:
            url: \(urlScalar)
            headers:
              Authorization: \(authScalar)
        \(endLine)
        """

        var output = existing
        if !output.isEmpty {
            if !output.hasSuffix("\n") { output += "\n" }
            if !output.hasSuffix("\n\n") { output += "\n" }
        }
        output += block + "\n"
        return output
    }

    // MARK: - Private: Insertion (Case B — child of existing mcp_servers:)

    private static func insertCaseB(
        into content: String,
        mcpServersLineRange: Range<String.Index>,
        urlScalar: String,
        authScalar: String
    ) throws -> String {
        let lines = content.components(separatedBy: "\n")
        let prefix = String(content[..<mcpServersLineRange.lowerBound])
        let headerLineIndex = prefix.components(separatedBy: "\n").count - 1

        // Determine the end of the mcp_servers: block (first subsequent line
        // whose indent is <= 0 spaces and is non-blank). We also need to scan
        // for tab indentation among children to reject early.
        let unitIndent = try learnIndentUnit(lines: lines, startingAfter: headerLineIndex)

        // Find end of block: first non-blank line at indent 0 after header,
        // or EOF.
        var endOfBlockLineIndex = lines.count // exclusive
        for i in (headerLineIndex + 1)..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }
            let indent = leadingSpaceCount(of: line)
            if indent == 0 {
                endOfBlockLineIndex = i
                break
            }
        }

        // Build the managed sub-block, indented to the learned child level.
        let childIndent = String(repeating: " ", count: unitIndent)
        let nestedIndent = String(repeating: " ", count: unitIndent * 2)
        let deepIndent = String(repeating: " ", count: unitIndent * 3)

        let subBlock = [
            "\(childIndent)\(beginLine)",
            "\(childIndent)calyx-ipc:",
            "\(nestedIndent)url: \(urlScalar)",
            "\(nestedIndent)headers:",
            "\(deepIndent)Authorization: \(authScalar)",
            "\(childIndent)\(endLine)",
        ]

        var newLines = lines
        newLines.insert(contentsOf: subBlock, at: endOfBlockLineIndex)
        return newLines.joined(separator: "\n")
    }

    /// Scans lines after the `mcp_servers:` header to learn the child indent
    /// in spaces. Throws on tab indentation. Defaults to 2 if the block has
    /// no children.
    private static func learnIndentUnit(lines: [String], startingAfter headerIndex: Int) throws -> Int {
        for i in (headerIndex + 1)..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }
            // Reject tab indentation outright — splice is not safe.
            if line.first == "\t" {
                throw HermesConfigError.unsupportedYamlStructure("tab indentation not supported")
            }
            let indent = leadingSpaceCount(of: line)
            if indent == 0 {
                // First non-blank line is at top level → no children.
                return 2
            }
            return indent
        }
        return 2
    }

    private static func leadingSpaceCount(of line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 } else { break }
        }
        return n
    }

    // MARK: - Private: Managed-block detection / removal

    /// Returns ranges of all WELL-FORMED managed blocks. A well-formed block
    /// is BEGIN line, followed by a `calyx-ipc:` line, followed by an END
    /// line — with no other BEGIN or END line between them.
    /// Each returned range covers the full BEGIN line through the full END
    /// line (no trailing newline).
    private static func findValidManagedBlocks(in content: String) -> [Range<String.Index>] {
        let beginMatches = matches(of: beginLineRegex, in: content)
        let endMatches = matches(of: endLineRegex, in: content)

        var result: [Range<String.Index>] = []

        for begin in beginMatches {
            // Find the first END whose lower bound is after this BEGIN's upper bound.
            guard let end = endMatches.first(where: { $0.lowerBound > begin.upperBound }) else { continue }

            // Reject if another BEGIN appears between begin and end (nested/orphan).
            if beginMatches.contains(where: { $0.lowerBound > begin.upperBound && $0.lowerBound < end.lowerBound }) {
                continue
            }
            // Reject if another END appears between begin and end (impossible by
            // construction since we picked the first END after begin, but defensive).
            if endMatches.contains(where: { $0.lowerBound > begin.upperBound && $0.lowerBound < end.lowerBound }) {
                continue
            }

            // Require a `calyx-ipc:` line strictly between begin and end.
            let between = begin.upperBound..<end.lowerBound
            if firstMatch(of: calyxIPCKeyRegex, in: content, range: between) == nil {
                continue
            }

            result.append(begin.lowerBound..<end.upperBound)
        }

        return result
    }

    /// Validates that no orphan BEGIN, orphan END, or BEGIN/END pair without
    /// `calyx-ipc:` exists in the content. Throws `.malformedManagedBlock`
    /// with a descriptive reason on the first offense found.
    private static func validateNoMalformedBlocks(in content: String) throws {
        let beginMatches = matches(of: beginLineRegex, in: content)
        let endMatches = matches(of: endLineRegex, in: content)

        if beginMatches.count != endMatches.count {
            if beginMatches.count > endMatches.count {
                throw HermesConfigError.malformedManagedBlock("orphan BEGIN")
            } else {
                throw HermesConfigError.malformedManagedBlock("orphan END")
            }
        }

        // Pair them by order; a misaligned pair (begin appears after end of
        // the corresponding pair) means the order is broken.
        for (begin, end) in zip(beginMatches, endMatches) {
            if begin.lowerBound >= end.lowerBound {
                throw HermesConfigError.malformedManagedBlock("out-of-order markers")
            }
            let between = begin.upperBound..<end.lowerBound
            if firstMatch(of: calyxIPCKeyRegex, in: content, range: between) == nil {
                throw HermesConfigError.malformedManagedBlock("missing calyx-ipc")
            }
        }
    }

    /// Removes well-formed managed blocks from `content`, including a single
    /// leading and trailing newline immediately adjacent to the block (to
    /// avoid leaving stray blank lines where the block used to be).
    private static func stripValidManagedBlocks(from content: String) -> String {
        var working = content
        // Iterate by repeatedly searching for a fresh valid block, since each
        // removal invalidates previously-computed ranges.
        while let range = findValidManagedBlocks(in: working).first {
            var lower = range.lowerBound
            var upper = range.upperBound

            // Eat one trailing newline if present.
            if upper < working.endIndex, working[upper] == "\n" {
                upper = working.index(after: upper)
            }
            // Eat one leading newline if present (so the deleted block doesn't
            // leave behind a blank-line gap).
            if lower > working.startIndex {
                let prev = working.index(before: lower)
                if working[prev] == "\n" {
                    lower = prev
                }
            }
            working.removeSubrange(lower..<upper)
        }
        return working
    }

    /// Self-heal helper used during enableIPC: removes ANY BEGIN line through
    /// its matching END line (or to EOF if no END), regardless of whether a
    /// `calyx-ipc:` body exists between them. Includes the trailing newline.
    private static func stripAllManagedRegions(from content: String) -> String {
        var working = content
        while let beginRange = firstMatch(of: beginLineRegex, in: working) {
            let searchAfterBegin = beginRange.upperBound..<working.endIndex
            let upperBound = firstMatch(of: endLineRegex, in: working, range: searchAfterBegin)?.upperBound
                ?? working.endIndex
            var lower = beginRange.lowerBound
            var upper = upperBound
            if upper < working.endIndex, working[upper] == "\n" {
                upper = working.index(after: upper)
            }
            if lower > working.startIndex {
                let prev = working.index(before: lower)
                if working[prev] == "\n" {
                    lower = prev
                }
            }
            working.removeSubrange(lower..<upper)
        }
        // Self-heal also removes orphan END lines that have no matching BEGIN,
        // so a broken state does not leak into the freshly-written file.
        while let endRange = firstMatch(of: endLineRegex, in: working) {
            var lower = endRange.lowerBound
            var upper = endRange.upperBound
            if upper < working.endIndex, working[upper] == "\n" {
                upper = working.index(after: upper)
            }
            if lower > working.startIndex {
                let prev = working.index(before: lower)
                if working[prev] == "\n" {
                    lower = prev
                }
            }
            working.removeSubrange(lower..<upper)
        }
        return working
    }

    /// Returns all non-overlapping regex matches in `content`, in document order.
    private static func matches(of regex: NSRegularExpression, in content: String) -> [Range<String.Index>] {
        let nsRange = NSRange(content.startIndex..., in: content)
        return regex.matches(in: content, range: nsRange).compactMap {
            Range($0.range, in: content)
        }
    }

    /// Returns the first regex match in `content`, optionally restricted to
    /// `range`. Returns nil if no match.
    private static func firstMatch(
        of regex: NSRegularExpression,
        in content: String,
        range: Range<String.Index>? = nil
    ) -> Range<String.Index>? {
        let searchRange = range ?? (content.startIndex..<content.endIndex)
        let nsRange = NSRange(searchRange, in: content)
        guard let match = regex.firstMatch(in: content, range: nsRange) else { return nil }
        return Range(match.range, in: content)
    }

    // MARK: - Private: YAML scalar escaping

    /// Encodes a string as a YAML double-quoted scalar (returns `"..."`).
    /// Rejects control characters other than `\n` and `\t` since their
    /// YAML representation is ambiguous and would risk silent corruption.
    private static func yamlDoubleQuotedScalar(_ s: String) throws -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            let cp = scalar.value
            if cp < 0x20 && scalar != "\n" && scalar != "\t" {
                throw HermesConfigError.invalidScalarValue
            }
            switch scalar {
            case "\\": out.append("\\\\")
            case "\"": out.append("\\\"")
            case "\n": out.append("\\n")
            case "\t": out.append("\\t")
            default:   out.append(Character(scalar))
            }
        }
        out.append("\"")
        return out
    }
}
