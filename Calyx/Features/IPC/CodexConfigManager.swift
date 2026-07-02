// CodexConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.codex/config.toml for the Calyx IPC MCP server.

import Foundation

// MARK: - CodexConfigError

enum CodexConfigError: Error, LocalizedError {
    case directoryNotFound
    case symlinkDetected
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "The ~/.codex/ directory does not exist"
        case .symlinkDetected:
            return "The config path is a symlink, which is not allowed for security reasons"
        case .writeFailed(let reason):
            return "Failed to write config file: \(reason)"
        }
    }
}

// MARK: - CodexConfigManager

struct CodexConfigManager: Sendable {

    // MARK: - Public API

    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath
        let parentDir = (path as NSString).deletingLastPathComponent

        // Parent directory must exist
        guard ConfigFileUtils.directoryExists(at: parentDir) else {
            throw CodexConfigError.directoryNotFound
        }

        // Security: reject symlinks
        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw CodexConfigError.symlinkDetected
        }

        // Read existing content or start empty
        let content: String
        if FileManager.default.fileExists(atPath: path) {
            content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        } else {
            content = ""
        }

        // Remove existing calyx-ipc sections, normalize line endings
        let cleaned = removeSections(from: content)

        // Build the new section
        let section = """
        [mcp_servers.calyx-ipc]
        url = "http://127.0.0.1:\(port)/mcp"
        http_headers = { "Authorization" = "Bearer \(token)" }
        """

        // Append with proper spacing
        var result = cleaned
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            if !result.hasSuffix("\n") {
                result += "\n"
            }
            result += "\n"
        }
        result += section + "\n"

        // Atomic write
        guard let data = result.data(using: .utf8) else {
            throw CodexConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: data, to: path, lockPath: path + ".lock")
    }

    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        // No file → no-op
        guard FileManager.default.fileExists(atPath: path) else { return }

        // Security: reject symlinks
        guard !ConfigFileUtils.isSymlink(at: path) else {
            throw CodexConfigError.symlinkDetected
        }

        // Unreadable → no-op
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        let cleaned = removeSections(from: content)

        // Only write if content actually changed
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        guard cleaned != normalized else { return }

        guard let data = cleaned.data(using: .utf8) else {
            throw CodexConfigError.writeFailed("UTF-8 encoding failed")
        }
        try ConfigFileUtils.atomicWrite(data: data, to: path, lockPath: path + ".lock")
    }

    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        let path = configPath ?? defaultConfigPath

        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }

        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized.components(separatedBy: "\n").contains { isSectionHeader($0) }
    }

    // MARK: - Private

    private static var defaultConfigPath: String {
        AgentToolPaths.codexConfigDirectory + "/config.toml"
    }

    /// Regex pattern for `[mcp_servers.calyx-ipc]` section header.
    private static let sectionHeaderPattern = #"^[ \t]*\[mcp_servers\.calyx-ipc\][ \t]*(#.*)?$"#

    /// Regex pattern for any TOML table header, standard (`[...]`) or
    /// array-of-tables (`[[...]]`). Per TOML semantics a table header always
    /// starts a new table and therefore always ends whatever table preceded
    /// it — including `[mcp_servers.calyx-ipc]` — regardless of whether a
    /// blank line separates them.
    private static let anyTableHeaderPattern = #"^[ \t]*\["#

    /// Regex pattern for a `[mcp_servers.calyx-ipc.*]` or
    /// `[[mcp_servers.calyx-ipc.*]]` sub-table header. Per TOML's dotted-key
    /// semantics this is still part of the calyx-ipc entry (not a boundary)
    /// and must be removed along with the rest of the section.
    private static let calyxIpcSubTableHeaderPattern = #"^[ \t]*\[\[?mcp_servers\.calyx-ipc\."#

    /// Regex pattern for the BEGIN marker of a Calyx-managed block
    /// (`CodexHooksConfigManager`'s `[[hooks.*]]` block). Recognized as a
    /// section boundary even though it's an ordinary TOML comment, not a
    /// table header.
    private static let calyxManagedBlockMarkerPattern = #"^[ \t]*#\s*BEGIN CALYX"#

    private static func isSectionHeader(_ line: String) -> Bool {
        line.range(of: sectionHeaderPattern, options: .regularExpression) != nil
    }

    private static func isAnyTableHeader(_ line: String) -> Bool {
        line.range(of: anyTableHeaderPattern, options: .regularExpression) != nil
    }

    private static func isCalyxIpcSubTableHeader(_ line: String) -> Bool {
        line.range(of: calyxIpcSubTableHeaderPattern, options: .regularExpression) != nil
    }

    private static func isCalyxManagedBlockMarker(_ line: String) -> Bool {
        line.range(of: calyxManagedBlockMarkerPattern, options: .regularExpression) != nil
    }

    /// Remove all `[mcp_servers.calyx-ipc]` sections from the content.
    /// Normalizes `\r\n` to `\n`.
    ///
    /// A section's body ends at the next TOML table header (`[...]` or
    /// `[[...]]`), or at a `# BEGIN CALYX` managed-block marker — never at a
    /// blank line. Blank lines are ordinary TOML whitespace and can appear
    /// inside a section's body without ending it; treating them as a
    /// terminator would leave the section's tail (including its
    /// `http_headers` / Bearer-token line) behind in the file.
    private static func removeSections(from content: String) -> String {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var result: [String] = []
        var inSection = false

        for line in lines {
            if isSectionHeader(line) {
                // Start of a calyx-ipc section — skip this line
                inSection = true
                continue
            }

            if inSection {
                if isCalyxIpcSubTableHeader(line) {
                    // A [mcp_servers.calyx-ipc.*] sub-table is still part of
                    // this entry — remove it along with the rest.
                    continue
                }
                if isAnyTableHeader(line) || isCalyxManagedBlockMarker(line) {
                    // Hit the next table header, or another managed block's
                    // BEGIN marker comment — end of calyx-ipc section.
                    inSection = false
                    result.append(line)
                    continue
                }
                // Otherwise still inside the section (including blank
                // lines) — skip
                continue
            }

            result.append(line)
        }

        // Join and trim trailing blank lines that were left from removal,
        // but preserve a single trailing newline if the file had content.
        var output = result.joined(separator: "\n")

        // Remove excessive trailing newlines (keep at most one)
        while output.hasSuffix("\n\n") {
            output = String(output.dropLast())
        }

        return output
    }
}
