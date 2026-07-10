// AgentHookToolCall.swift
// Calyx
//
// Decoded form of a CLI agent's PreToolUse hook stdin JSON payload
// (`tool_name` / `tool_input`, snake_case) into the toolName/payload/
// summary trio the approval inbox needs to render a banner for a
// non-MCP agent hook call. Mirrors AgentEvent.decode's
// JSONSerialization-based style -- see AgentEvent.swift.

import Foundation

struct AgentHookToolCall: Sendable {
    let toolName: String
    let payload: String
    let summary: String

    /// `payload`'s cap, in UTF-8 bytes -- see `decode(from:)` for the
    /// character-boundary truncation contract.
    static let maxPayloadBytes = 16_384

    /// `summary`'s cap, in `Character`s.
    static let maxSummaryLength = 500

    /// `tool_name`s whose `summary` is the string at `tool_input.file_path`.
    /// `NotebookEdit` is deliberately NOT in this set -- Claude Code's
    /// actual PreToolUse schema for it is `tool_input.notebook_path`, a
    /// distinct key of its own (see `derivedSummary`'s own `NotebookEdit`
    /// case).
    private static let filePathToolNames: Set<String> = ["Write", "Edit", "Read"]

    /// Decodes a CLI agent's PreToolUse hook stdin JSON. `tool_name` is
    /// mandatory (a non-empty string) -- a missing/empty/non-string
    /// value rejects the whole payload. `tool_input` is optional; its
    /// absence yields an empty `payload`/`summary`. Unknown top-level
    /// fields are tolerated.
    ///
    /// `payload` is the compact JSON of `tool_input`, truncated to at
    /// most `maxPayloadBytes` UTF-8 bytes without ever splitting a
    /// `Character` (backs off to the last whole character that still
    /// fits, rather than cutting mid-character). `summary` is a
    /// tool-specific human-readable string (the command for `Bash`, the
    /// file path for `Write`/`Edit`/`Read`, the notebook path for
    /// `NotebookEdit` -- its own distinct `tool_input.notebook_path` key,
    /// never `file_path` -- the URL for `WebFetch`) capped at
    /// `maxSummaryLength` characters -- any other `tool_name`, or a
    /// recognized one missing its expected key, falls back to the same
    /// compact JSON of `tool_input` used for `payload`.
    static func decode(from data: Data) -> AgentHookToolCall? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolName = object["tool_name"] as? String, !toolName.isEmpty else {
            return nil
        }

        guard let toolInput = object["tool_input"] as? [String: Any] else {
            return AgentHookToolCall(toolName: toolName, payload: "", summary: "")
        }

        let compactJSON = (try? JSONSerialization.data(withJSONObject: toolInput))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        let payload = truncatedToByteCap(compactJSON, cap: maxPayloadBytes)
        let derivedSummary = derivedSummary(toolName: toolName, toolInput: toolInput, compactJSON: compactJSON)

        return AgentHookToolCall(
            toolName: toolName, payload: payload, summary: String(derivedSummary.prefix(maxSummaryLength))
        )
    }

    /// `summary`'s tool-specific well-known key per tool_name, falling
    /// back to `compactJSON` when `toolName` isn't one of these, or the
    /// expected key is absent/not a string.
    private static func derivedSummary(toolName: String, toolInput: [String: Any], compactJSON: String) -> String {
        switch toolName {
        case "Bash":
            return (toolInput["command"] as? String) ?? compactJSON
        case _ where filePathToolNames.contains(toolName):
            return (toolInput["file_path"] as? String) ?? compactJSON
        case "NotebookEdit":
            return (toolInput["notebook_path"] as? String) ?? compactJSON
        case "WebFetch":
            return (toolInput["url"] as? String) ?? compactJSON
        default:
            return compactJSON
        }
    }

    /// Truncates `text` to at most `cap` UTF-8 bytes without ever
    /// splitting a `Character` in half -- backs off to the last whole
    /// character that still fits under `cap`.
    private static func truncatedToByteCap(_ text: String, cap: Int) -> String {
        guard text.utf8.count > cap else { return text }
        var result = ""
        var byteCount = 0
        for character in text {
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= cap else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
