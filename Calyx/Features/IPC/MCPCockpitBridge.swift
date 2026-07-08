// MCPCockpitBridge.swift
// Calyx
//
// Bridges CockpitAppAccessing onto the MCP tool surface -- pane_list /
// pane_split / tab_create this round (P4, ungated); pane_run /
// pane_send_keys / palette_execute (gated by the approval flow) arrive
// in P5. Mirrors MCPCommandLogBridge's shape (nonisolated tools
// catalogue, typed LocalizedError+Equatable error enum,
// requireString/optionalString argument helpers, handleToolCall
// dispatch switch, surface_id two-step resolution via
// SessionSurfaceMap, [String: Any] + JSONSerialization response
// building) -- see that file's own header for the full-size version
// this one is scaled down from. See
// CalyxTests/IPC/MCPCockpitBridgeTests.swift for the specced contract
// this satisfies.

import Foundation

// MARK: - MCPCockpitBridgeError

/// Failures raised by `MCPCockpitBridge` before returning a result.
/// Shape mirrors `MCPCommandLogBridgeError`. Palette-related cases
/// (P5) are not added yet.
enum MCPCockpitBridgeError: Error, LocalizedError, Equatable {
    /// `handleToolCall` received a `name` not present in `toolNames`.
    case unknownTool(String)
    /// A required argument was missing from the `arguments` dictionary.
    case missingArgument(String)
    /// An argument was present but failed to coerce into the expected
    /// shape (e.g. a non-string `surface_id`, a `direction` other than
    /// "right"/"down", a `cwd` that isn't an existing directory).
    case invalidArgument(name: String, reason: String)
    /// `surface_id` was a well-formed string but didn't resolve as
    /// either a surface UUID or a registered calyx-session ID.
    case unresolvableSurfaceID(String)
    /// `surface_id` resolved to a UUID, but that pane no longer exists
    /// (mirrors `CockpitAccessError.paneNotFound`).
    case paneNotFound(UUID)
    /// Mirrors `CockpitAccessError.appUnavailable` -- no live app/window
    /// to operate against.
    case appUnavailable
    /// Mirrors `CockpitAccessError.tabCreationFailed` -- `tab_create`'s
    /// own argument validation (cwd existence) passed, but the app-level
    /// creation itself still failed (e.g. no key window).
    case tabCreationFailed

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .missingArgument(let key):
            return "Missing required argument: \(key)"
        case .invalidArgument(let name, let reason):
            return "Invalid argument \(name): \(reason)"
        case .unresolvableSurfaceID(let raw):
            return "Could not resolve surface_id: \(raw)"
        case .paneNotFound(let id):
            return "Pane not found: \(id.uuidString)"
        case .appUnavailable:
            return "The Calyx app is not currently available"
        case .tabCreationFailed:
            return "Failed to create the new tab"
        }
    }
}

// MARK: - MCPCockpitBridge

@MainActor
final class MCPCockpitBridge {

    private let access: CockpitAppAccessing
    private let sessionSurfaceMap: SessionSurfaceMap

    init(access: CockpitAppAccessing, sessionSurfaceMap: SessionSurfaceMap = .shared) {
        self.access = access
        self.sessionSurfaceMap = sessionSurfaceMap
    }

    // MARK: - Tool catalogue

    /// The tool names this bridge currently dispatches. P5 adds
    /// pane_run / pane_send_keys / palette_execute.
    nonisolated static let toolNames: Set<String> = ["pane_list", "pane_split", "tab_create"]

    nonisolated static let tools: [MCPTool] = [
        MCPTool(
            name: "pane_list",
            description: "List every terminal pane across all open Calyx windows. Pane identity is "
                + "split-tree leaf membership -- the same membership every other pane operation "
                + "(pane_split, and pane_run/pane_send_keys once available) resolves against, so a "
                + "pane this tool reports is guaranteed operable.",
            inputSchema: MCPRouter.schema(properties: [:])
        ),
        MCPTool(
            name: "pane_split",
            description: "Split an existing pane, creating a new one alongside it. surface_id also "
                + "accepts a calyx-session ID in place of the raw surface UUID.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "surface_id": MCPRouter.prop("string", "Surface UUID or calyx-session ID of the pane to split"),
                    "direction": MCPRouter.prop("string", "Split direction: \"right\" or \"down\""),
                ],
                required: ["surface_id", "direction"]
            )
        ),
        MCPTool(
            name: "tab_create",
            description: "Create a new tab, optionally in a named group and/or at a specific working "
                + "directory. This visibly changes focus in the live app window -- the new tab "
                + "becomes active immediately, an effect an MCP caller should know it's triggering.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "group_name": MCPRouter.prop("string", "Existing or new tab group name; defaults to the current window's active group"),
                    "cwd": MCPRouter.prop("string", "Working directory for the new tab's shell; must be an existing directory"),
                ]
            )
        ),
    ]

    // MARK: - Dispatch

    /// Route an MCP `tools/call` to the matching handler. Every
    /// tool-level failure (missing/invalid arguments, unresolvable
    /// `surface_id`, a propagated `CockpitAccessError`, ...) is raised
    /// as a thrown `MCPCockpitBridgeError` -- `CalyxMCPServer
    /// .handleCockpitToolCall` catches it and builds the tool-error text
    /// from `error.localizedDescription`, mirroring
    /// `handleTerminalToolCall`'s do/catch shape.
    func handleToolCall(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "pane_list":
            return handlePaneList()
        case "pane_split":
            return try handlePaneSplit(arguments: arguments)
        case "tab_create":
            return try handleTabCreate(arguments: arguments)
        default:
            throw MCPCockpitBridgeError.unknownTool(name)
        }
    }

    // MARK: - pane_list

    private func handlePaneList() -> String {
        jsonString(["panes": access.listPanes().map(paneDict)])
    }

    /// `title`/`cwd`/`agent_kind`/`calyx_session_id` are OMITTED
    /// entirely when `nil`, not serialized as JSON `null` -- mirrors
    /// `MCPCommandLogBridge`'s optional-field omission style (e.g.
    /// `baseRecordDict`'s `exit_code`/`ended_at`).
    private func paneDict(_ pane: CockpitPaneInfo) -> [String: Any] {
        var dict: [String: Any] = [
            "surface_id": pane.surfaceID.uuidString,
            "window_id": pane.windowID.uuidString,
            "group_name": pane.groupName,
            "tab_id": pane.tabID.uuidString,
            "tab_title": pane.tabTitle,
            "is_focused": pane.isFocused,
        ]
        if let title = pane.title { dict["title"] = title }
        if let cwd = pane.cwd { dict["cwd"] = cwd }
        if let agentKind = pane.agentKind { dict["agent_kind"] = agentKind }
        if let calyxSessionID = pane.calyxSessionID { dict["calyx_session_id"] = calyxSessionID }
        return dict
    }

    // MARK: - pane_split

    private func handlePaneSplit(arguments: [String: Any]) throws -> String {
        let rawSurfaceID = try requireString(arguments, "surface_id")
        guard let surfaceID = resolveSurfaceID(rawSurfaceID) else {
            throw MCPCockpitBridgeError.unresolvableSurfaceID(rawSurfaceID)
        }

        let rawDirection = try requireString(arguments, "direction")
        let direction: SplitDirection
        switch rawDirection {
        case "right":
            direction = .horizontal
        case "down":
            direction = .vertical
        default:
            throw MCPCockpitBridgeError.invalidArgument(name: "direction", reason: "expected \"right\" or \"down\"")
        }

        let newSurfaceID: UUID
        do {
            newSurfaceID = try access.splitPane(surfaceID: surfaceID, direction: direction)
        } catch {
            throw mapAccessError(error)
        }

        return jsonString(["surface_id": newSurfaceID.uuidString, "direction": rawDirection])
    }

    // MARK: - tab_create

    private func handleTabCreate(arguments: [String: Any]) throws -> String {
        var groupName = try optionalString(arguments, "group_name")
        if let rawGroupName = groupName {
            let trimmed = rawGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPCockpitBridgeError.invalidArgument(
                    name: "group_name", reason: "must not be blank; omit to use the active group"
                )
            }
            groupName = trimmed
        }

        var cwd = try optionalString(arguments, "cwd")
        if let rawCwd = cwd {
            // Trim BEFORE the blank check and tilde expansion, so a
            // trailing newline (plausible from an agent-constructed
            // payload built from raw shell output, e.g. `$(pwd)`) both
            // validates and reaches access.createTab already cleaned --
            // matches resolveNewTabSpawnCwd's own normalization on the
            // CalyxWindowController seam this ultimately reaches
            // (P3 review W2), rather than rejecting what that seam
            // would accept.
            let trimmed = rawCwd.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPCockpitBridgeError.invalidArgument(
                    name: "cwd", reason: "must not be blank; omit the argument to use the active tab's directory"
                )
            }
            let expanded = NSString(string: trimmed).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MCPCockpitBridgeError.invalidArgument(name: "cwd", reason: "not an existing directory")
            }
            cwd = expanded
        }

        let newTab: CockpitNewTab
        do {
            newTab = try access.createTab(groupName: groupName, cwd: cwd)
        } catch {
            throw mapAccessError(error)
        }

        return jsonString([
            "tab_id": newTab.tabID.uuidString,
            "surface_id": newTab.surfaceID.uuidString,
            "group_name": newTab.groupName,
        ])
    }

    // MARK: - CockpitAccessError translation

    /// Translates a thrown `CockpitAccessError` into this bridge's own
    /// error type, so a caller building tool-error text from
    /// `errorDescription` gets a human-useful message
    /// (`CockpitAccessError` itself isn't `LocalizedError`). Any other
    /// error passes through unchanged.
    private func mapAccessError(_ error: Error) -> Error {
        guard let accessError = error as? CockpitAccessError else { return error }
        switch accessError {
        case .appUnavailable:
            return MCPCockpitBridgeError.appUnavailable
        case .paneNotFound(let id):
            return MCPCockpitBridgeError.paneNotFound(id)
        case .tabCreationFailed:
            return MCPCockpitBridgeError.tabCreationFailed
        case .commandFailed, .paletteCommandNotFound, .paletteCommandUnavailable:
            // Not reachable from splitPane/createTab (this bridge's only
            // two access calls so far) -- P5 adds pane_run/
            // pane_send_keys/palette_execute and their own mappings for
            // these.
            return error
        }
    }

    // MARK: - surface_id resolution

    /// `raw` resolves either as a literal surface UUID, or (falling back)
    /// as a calyx-session ID registered in `sessionSurfaceMap`.
    private func resolveSurfaceID(_ raw: String) -> UUID? {
        if let uuid = UUID(uuidString: raw) { return uuid }
        return sessionSurfaceMap.surfaceID(for: raw)
    }

    // MARK: - Argument extraction

    /// Required string argument: throws `.missingArgument` when `key` is
    /// absent, `.invalidArgument` when present but not a `String`.
    private func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] else {
            throw MCPCockpitBridgeError.missingArgument(key)
        }
        guard let string = value as? String else {
            throw MCPCockpitBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return string
    }

    /// Optional string argument: `nil` when `key` is absent; throws
    /// `.invalidArgument` when present but not a `String`.
    private func optionalString(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else {
            throw MCPCockpitBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return string
    }

    // MARK: - Response serialization

    /// Every dictionary this bridge serializes is built entirely from
    /// this file's own `String`/`Bool`/`Array`/`Dictionary` values, so
    /// `JSONSerialization` encoding cannot actually fail here; `"{}"` is
    /// an unreachable-in-practice, still well-formed-JSON fallback
    /// rather than a partial/garbled payload (mirrors
    /// `MCPCommandLogBridge.jsonString`).
    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
