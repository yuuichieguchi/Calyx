// HermesConfigManager.swift
// Calyx
//
// Manages reading/writing ~/.hermes/config.yaml for the Calyx IPC MCP server.
//
// Hermes uses YAML. Rather than introduce a YAML parser dependency, this
// manager declares its owned-region rules (body ownership predicate,
// foreign-content structural predicate) to the shared
// `MarkerConfigDocumentEditor`, which owns the actual byte-level editing —
// see `.claude/architecture.md`'s "文書の編集はフォーマットごとの編集器" section.
// Two insertion modes:
//
//   - Case A: file has no top-level `mcp_servers:` key — the managed block
//     is appended at EOF and contains its own `mcp_servers:` parent.
//   - Case B: file already has a top-level `mcp_servers:` key — only the
//     `calyx-ipc:` child entry is inserted under it, with comment markers
//     and the entry indented to the learned child indent.
//
// Hermes registers no hooks: a Hermes Agents row is
// `.mcpConnection`-sourced only, never through anything Hermes itself
// reports. Its blocked/working/idle state instead comes from
// AgentRegistry.handleScreenClassification polling the pane's on-screen
// text (Herdr Layer 2), same as every other `.mcpConnection` row; the
// pane's own exit signal (AgentRegistry.handlePaneCommandFinished) only
// ever writes `.done`, and only once Command Tracking is enabled
// (CommandTrackingSettings.trackingEnabled) and the pane is running an
// interactive zsh or fish, the only two shells ShellIntegrationInstaller
// installs into.

import Foundation

// MARK: - HermesConfigError

enum HermesConfigError: Error, LocalizedError {
    case unsupportedYamlStructure(String)
    case invalidScalarValue

    var errorDescription: String? {
        switch self {
        case .unsupportedYamlStructure(let reason):
            return "Unsupported YAML structure in Hermes config: \(reason)"
        case .invalidScalarValue:
            return "Cannot write value: contains characters that are not safe for a YAML double-quoted scalar"
        }
    }
}

// MARK: - HermesConfigManager

struct HermesConfigManager: Sendable {

    // MARK: - Constants

    private static let beginLine = "# BEGIN CALYX IPC (managed by Calyx, do not edit)"
    private static let endLine = "# END CALYX IPC"

    /// The BEGIN/END marker editor shared with every other marker-block
    /// manager. The single owned region is the BEGIN...END span itself —
    /// whether the body happens to contain a `calyx-ipc:` line is never a
    /// condition of ownership. Given `isOwnBodyLine` and
    /// `foreignBodyBytes`, the editor owns the well-formed insert/replace
    /// (`enableIPC`), the well-formed removal with foreign-content
    /// preservation (`disableIPC`), and self-healing an orphan BEGIN or
    /// END entirely on its own.
    private static let markerEditor = MarkerConfigDocumentEditor(
        beginLine: beginLine,
        endLine: endLine,
        isOwnBodyLine: { doc, index in
            isOwnBodyLine(String(decoding: doc.lineBytes(doc.lines[index]), as: UTF8.self))
        },
        foreignBodyBytes: { doc, bodyLines in foreignBodyBytes(in: doc, bodyLines: bodyLines) }
    )

    // MARK: - Public API

    /// Enables Calyx IPC by upserting the managed block in the Hermes
    /// config. Self-heals over any previously malformed managed block
    /// (orphan BEGIN/END, or a BEGIN/END pair whose body isn't
    /// recognizably Calyx's own) via `markerEditor.removeBlock`, which also
    /// preserves any foreign content found inside it, before writing fresh
    /// content.
    static func enableIPC(port: Int, token: String, configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        let url = "http://127.0.0.1:\(port)/mcp"
        let authorization = "Bearer \(token)"
        let urlScalar = try yamlDoubleQuotedScalar(url)
        let authScalar = try yamlDoubleQuotedScalar(authorization)
        let surfaceIDScalar = try yamlDoubleQuotedScalar("${CALYX_SURFACE_ID}")
        let sessionIDScalar = try yamlDoubleQuotedScalar("${CALYX_SESSION_ID}")
        let agentKindScalar = try yamlDoubleQuotedScalar(AgentEntry.hermesKind)

        // 0600: the managed block's `authorization` field carries the
        // bearer token.
        try ConfigFileUtils.withExclusiveConfig(path: path, mode: 0o600) { current in
            let cleaned = try markerEditor.removeBlock(in: current)
            let doc = LineDoc(bytes: cleaned.map { Array($0) } ?? [])

            guard let headerLine = try topLevelMcpServersHeaderLine(in: doc) else {
                let body = managedBlockBody(
                    caseBUnit: nil,
                    urlScalar: urlScalar,
                    authScalar: authScalar,
                    surfaceIDScalar: surfaceIDScalar,
                    sessionIDScalar: sessionIDScalar,
                    agentKindScalar: agentKindScalar
                )
                return try markerEditor.setBlock(body: body, in: cleaned)
            }

            let unit: Int
            do {
                unit = try markerEditor.childIndentUnit(afterLine: headerLine, in: doc)
            } catch MarkerConfigDocumentEditorError.tabIndentation {
                throw HermesConfigError.unsupportedYamlStructure("tab indentation not supported")
            }
            let body = managedBlockBody(
                caseBUnit: unit,
                urlScalar: urlScalar,
                authScalar: authScalar,
                surfaceIDScalar: surfaceIDScalar,
                sessionIDScalar: sessionIDScalar,
                agentKindScalar: agentKindScalar
            )
            return markerEditor.insertBlock(body: body, asChildOfLine: headerLine, unit: unit, in: cleaned)
        }
    }

    /// Disables Calyx IPC by removing the managed block(s) from the config.
    /// Never throws on a malformed shape: an orphan BEGIN/END self-heals,
    /// and any foreign content found inside Calyx's owned span is
    /// preserved in place rather than discarded — both entirely
    /// `markerEditor`'s own responsibility given `isOwnBodyLine` and
    /// `foreignBodyBytes` above.
    static func disableIPC(configPath: String? = nil) throws {
        let path = configPath ?? defaultConfigPath

        // mode: nil -- disable writes no secret, only removes the block
        // that carried one, so it must preserve whatever mode the
        // user's file already has rather than forcing 0600 (that mode
        // belongs to enableIPC, which writes the token).
        try ConfigFileUtils.withExclusiveConfig(path: path) { current in
            try markerEditor.removeBlock(in: current)
        }
    }

    /// Returns true iff `markerEditor` finds a well-formed BEGIN...END
    /// block (or, when self-heal is wired up, an orphan BEGIN/END on its
    /// own) — the same detection rule the write side (`enableIPC` /
    /// `disableIPC`) uses, so this status check never disagrees with what
    /// `disableIPC` would actually remove.
    /// Returns `false` (rather than throwing) when `configPath`'s symlink
    /// chain can't be resolved — this is a read-only status check, and
    /// every other unreadable-file case here already resolves to `false`
    /// the same way.
    static func isIPCEnabled(configPath: String? = nil) -> Bool {
        guard let path = try? ConfigFileUtils.resolveConfigPath(configPath ?? defaultConfigPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return false
        }
        return markerEditor.containsBlock(in: data)
    }

    // MARK: - Private: Defaults

    private static var defaultConfigPath: String {
        AgentToolPaths.hermesConfigPath
    }

    // MARK: - Private: Managed block construction

    /// The managed block's body (everything between the BEGIN and END
    /// lines, which `MarkerConfigDocumentEditor` supplies the indent and
    /// markers for itself). `caseBUnit == nil` builds Case A's
    /// self-contained mapping (`mcp_servers:` parent included, fixed
    /// 2-space nesting — Calyx's own convention for a freshly authored top-
    /// level mapping, unrelated to any existing document's indent). A
    /// non-nil `caseBUnit` builds Case B's body (`calyx-ipc:` as the body's
    /// own root, no `mcp_servers:` parent): each nesting level advances by
    /// exactly `caseBUnit` spaces of the body's OWN relative indent, since
    /// `insertBlock` itself adds one further `unit` on top of every line —
    /// so `calyx-ipc:` (relative 0) lands at the child level, its children
    /// (relative `unit`) land one level deeper, and so on, matching the
    /// existing document's own indent convention throughout instead of
    /// only at the first level.
    private static func managedBlockBody(
        caseBUnit: Int?,
        urlScalar: String,
        authScalar: String,
        surfaceIDScalar: String,
        sessionIDScalar: String,
        agentKindScalar: String
    ) -> String {
        guard let unit = caseBUnit else {
            return """
            mcp_servers:
              calyx-ipc:
                url: \(urlScalar)
                headers:
                  Authorization: \(authScalar)
                  X-Calyx-Surface-ID: \(surfaceIDScalar)
                  X-Calyx-Session-ID: \(sessionIDScalar)
                  X-Calyx-Agent-Kind: \(agentKindScalar)
            """
        }
        let l1 = String(repeating: " ", count: unit)
        let l2 = String(repeating: " ", count: unit * 2)
        return [
            "calyx-ipc:",
            "\(l1)url: \(urlScalar)",
            "\(l1)headers:",
            "\(l2)Authorization: \(authScalar)",
            "\(l2)X-Calyx-Surface-ID: \(surfaceIDScalar)",
            "\(l2)X-Calyx-Session-ID: \(sessionIDScalar)",
            "\(l2)X-Calyx-Agent-Kind: \(agentKindScalar)",
        ].joined(separator: "\n")
    }

    // MARK: - Private: mcp_servers: header detection

    /// Scans `doc` for a top-level (indent-0) `mcp_servers:` key by byte-
    /// level line walk — never a regex or `String.components(separatedBy:)`,
    /// which would leave a CRLF document's `\r` attached to each split
    /// piece. Returns the line index of a block-style `mcp_servers:` key
    /// (empty value after the colon, or only a trailing `#` comment,
    /// introducing nested children), or `nil` if there is none. Throws
    /// `.unsupportedYamlStructure` for an inline form (`mcp_servers: {}` /
    /// `mcp_servers: [...]`) — there's no safe place to splice a child into
    /// that.
    private static func topLevelMcpServersHeaderLine(in doc: LineDoc) throws -> Int? {
        let key = "mcp_servers:"
        for i in doc.lines.indices {
            let raw = doc.lineBytes(doc.lines[i])
            guard let first = raw.first, first != UInt8(ascii: " "), first != UInt8(ascii: "\t") else { continue }
            let text = String(decoding: raw, as: UTF8.self)
            guard text.hasPrefix(key) else { continue }
            let remainder = String(text.dropFirst(key.count)).trimmingCharacters(in: .whitespaces)
            if remainder.isEmpty || remainder.hasPrefix("#") { return i }
            throw HermesConfigError.unsupportedYamlStructure("inline mcp_servers map not supported")
        }
        return nil
    }

    // MARK: - Private: Owned-region predicates

    /// Whether `line` looks like part of Calyx's own generated managed-
    /// block body, for `markerEditor`'s orphan-BEGIN self-heal scan: a
    /// blank line, a `#` comment, or a line beginning (indentation aside)
    /// with one of the keys Calyx's own body ever writes.
    private static func isOwnBodyLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix("#") { return true }
        let ownKeyPrefixes = [
            "mcp_servers:", "calyx-ipc:", "url:", "headers:", "Authorization:",
            "X-Calyx-Surface-ID:", "X-Calyx-Session-ID:", "X-Calyx-Agent-Kind:",
        ]
        return ownKeyPrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// Extracts every line inside a BEGIN...END (or self-healed orphan)
    /// span that is NOT Calyx's own `calyx-ipc:` subtree, by YAML
    /// indentation structure rather than line content: the `calyx-ipc:`
    /// key line and every following line indented strictly deeper than it
    /// are Calyx's own; everything else in the span is foreign and is
    /// returned byte-for-byte (indentation, trailing whitespace, comments,
    /// blank lines, and each line's own original EOL all included), in
    /// original document order.
    ///
    /// No `calyx-ipc:` line in the span at all means nothing was
    /// identified as Calyx's own, so the entire span is foreign and is
    /// returned in full — this is what lets `disableIPC` preserve rather
    /// than throw on a BEGIN/END pair whose body was hand-edited down to
    /// only a user's own content.
    ///
    /// Parent-container rule (mirrors JSON's L1.3.1): when the span also
    /// contains its own `mcp_servers:` parent line (Case A's shape) at an
    /// indent shallower than `calyx-ipc:`'s, that parent line is preserved
    /// too, but ONLY if some other foreign line remains once Calyx's own
    /// subtree is removed — dropping the parent while a foreign child
    /// still hangs under it would leave that child outside any mapping,
    /// corrupting the YAML. If no other foreign line remains, the parent
    /// is Calyx's own region too (it introduced nothing but Calyx's own
    /// entry) and is dropped along with it.
    private static func foreignBodyBytes(in doc: LineDoc, bodyLines: Range<Int>) -> [UInt8] {
        let key = "calyx-ipc:"
        guard let calyxIndex = bodyLines.first(where: {
            String(decoding: doc.lineBytes(doc.lines[$0]), as: UTF8.self)
                .trimmingCharacters(in: .whitespaces).hasPrefix(key)
        }) else {
            var result: [UInt8] = []
            for i in bodyLines { result.append(contentsOf: doc.rawBytes(forLines: i..<(i + 1))) }
            return result
        }
        let calyxIndent = doc.leadingSpaceCount(doc.lines[calyxIndex])

        var subtreeEnd = calyxIndex + 1
        while subtreeEnd < bodyLines.upperBound {
            let raw = doc.lineBytes(doc.lines[subtreeEnd])
            if raw.isEmpty { break }
            if doc.leadingSpaceCount(doc.lines[subtreeEnd]) <= calyxIndent { break }
            subtreeEnd += 1
        }
        var ownIndices = Set(calyxIndex..<subtreeEnd)
        ownIndices.insert(calyxIndex)

        let mcpServersParentIndex = bodyLines.first {
            !ownIndices.contains($0)
                && String(decoding: doc.lineBytes(doc.lines[$0]), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces).hasPrefix("mcp_servers:")
                && doc.leadingSpaceCount(doc.lines[$0]) < calyxIndent
        }

        let otherForeignExists = bodyLines.contains {
            !ownIndices.contains($0) && $0 != mcpServersParentIndex
        }

        var result: [UInt8] = []
        for i in bodyLines {
            if ownIndices.contains(i) { continue }
            if i == mcpServersParentIndex, !otherForeignExists { continue }
            result.append(contentsOf: doc.rawBytes(forLines: i..<(i + 1)))
        }
        return result
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
