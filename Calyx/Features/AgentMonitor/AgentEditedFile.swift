// AgentEditedFile.swift
// Calyx
//
// The file paths an agent's tool call is about to write, recorded per
// surface so Mission Map can draw a conflict line between two panes
// editing the same file. Only a `PreToolUse` event carries this intent:
// a `PostToolUse` describes a call that already finished, and recording
// it too would only duplicate the same edit under a later timestamp.

import Foundation

// MARK: - Extractor

/// Pure mapping from one tool call's raw `tool_input` object to the file
/// paths that call writes.
///
/// - `Write` / `Edit` / `MultiEdit` -> `tool_input["file_path"]`
/// - `NotebookEdit` -> `tool_input["notebook_path"]`
/// - `apply_patch` (Codex) -> every `*** Add File: p`, `*** Update File: p`
///   and `*** Delete File: p` line of the patch text under
///   `tool_input["input"]`, or `tool_input["patch"]` when `input` is
///   absent. The key Codex uses is not confirmed against a live payload,
///   so both are read; a payload naming neither extracts nothing and the
///   map simply draws no conflict line for it.
/// - `Read` and every other tool, a missing key, or a non-string value
///   -> `[]`. `Read` is excluded on purpose: two agents reading the
///   same file is not a conflict.
///
/// Paths are returned exactly as the tool named them, in document order.
/// `apply_patch` paths are usually relative to the agent's cwd;
/// resolving them is the recorder's job, since only it knows the cwd.
enum AgentEditedFileExtractor {

    private static let filePathToolNames: Set<String> = ["Write", "Edit", "MultiEdit"]
    private static let notebookToolName = "NotebookEdit"
    private static let applyPatchToolName = "apply_patch"

    /// The `apply_patch` header prefixes that name a file the patch
    /// writes. `*** Move to:` is deliberately absent: it only ever
    /// follows an `*** Update File:` line, which already names the file.
    private static let patchFileHeaderPrefixes = [
        "*** Add File: ", "*** Update File: ", "*** Delete File: ",
    ]

    static func paths(toolName: String, toolInput: [String: Any]) -> [String] {
        if filePathToolNames.contains(toolName) {
            return nonEmptyString(toolInput["file_path"]).map { [$0] } ?? []
        }
        if toolName == notebookToolName {
            return nonEmptyString(toolInput["notebook_path"]).map { [$0] } ?? []
        }
        if toolName == applyPatchToolName {
            guard let body = (toolInput["input"] as? String) ?? (toolInput["patch"] as? String) else {
                return []
            }
            return patchPaths(in: body)
        }
        return []
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    private static func patchPaths(in body: String) -> [String] {
        var paths: [String] = []
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let prefix = patchFileHeaderPrefixes.first(where: { line.hasPrefix($0) }) else { continue }
            let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty {
                paths.append(path)
            }
        }
        return paths
    }
}

// MARK: - Record

/// One file one surface's agent was about to write, at the moment its
/// `PreToolUse` hook arrived.
struct AgentEditedFile: Sendable, Equatable {
    let surfaceID: UUID
    /// Absolute when the recorder could resolve it (see
    /// `AgentRegistry.handleHookEvent`), otherwise exactly as the tool
    /// named it.
    let path: String
    let toolName: String
    let at: Date
}

// MARK: - Log

/// The most recent edited-file records across every surface, newest
/// last. A bounded ring rather than a per-surface history: Mission Map
/// only ever asks "who touched this file recently", so records older
/// than the capacity carry no information worth keeping.
///
/// A process-wide singleton for the same reason `AgentRegistry.shared`
/// is one: hook events arrive app-wide, and every window's map reads the
/// same log, filtering to its own panes.
@MainActor
@Observable
final class AgentEditedFileLog {
    static let shared = AgentEditedFileLog()

    static let capacity = 256

    private(set) var records: [AgentEditedFile] = []

    /// Appends one record per path, evicting the oldest records past
    /// `capacity`. An empty `paths` records nothing.
    func record(surfaceID: UUID, paths: [String], toolName: String, at: Date) {
        guard !paths.isEmpty else { return }
        records.append(contentsOf: paths.map {
            AgentEditedFile(surfaceID: surfaceID, path: $0, toolName: toolName, at: at)
        })
        let overflow = records.count - Self.capacity
        if overflow > 0 {
            records.removeFirst(overflow)
        }
    }

    /// Drops every record for `surfaceID`: a destroyed pane can no longer
    /// conflict with anything.
    func removeAll(for surfaceID: UUID) {
        records.removeAll { $0.surfaceID == surfaceID }
    }

    func reset() {
        records.removeAll()
    }
}
