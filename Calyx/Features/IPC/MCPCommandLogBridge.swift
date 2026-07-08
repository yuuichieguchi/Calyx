// MCPCommandLogBridge.swift
// Calyx
//
// Bridges the MCP tool surface onto CommandLogStore: exposes
// terminal_list_commands / terminal_read_output / terminal_await_command
// as MCP tools. Small-scale mirror of MCPLSPBridge's shape (see that
// file's header comment for the full-size version) -- three tools here
// instead of dozens, so dispatch is a plain switch rather than a
// per-tool-struct catalogue.

import Foundation

// MARK: - MCPCommandLogBridgeError

/// Failures raised by `MCPCommandLogBridge` before returning a result.
/// Shape mirrors `MCPLSPBridgeError`; unlike that type this one conforms
/// to `LocalizedError` so `CalyxMCPServer.handleTerminalToolCall` can
/// build its error text with a plain `error.localizedDescription`
/// instead of a per-case switch.
enum MCPCommandLogBridgeError: Error, LocalizedError, Equatable {
    /// `handleToolCall` received a `name` not present in `tools`.
    case unknownTool(String)
    /// A required argument was missing from the `arguments` dictionary.
    case missingArgument(String)
    /// An argument was present but failed to coerce into the expected
    /// shape (e.g. a non-string `surface_id`, a fractional `timeout_ms`).
    case invalidArgument(name: String, reason: String)
    /// `surface_id` was a well-formed string but didn't resolve as
    /// either a surface UUID or a registered calyx-session ID.
    case unresolvableSurfaceID(String)
    /// `command_id` didn't resolve to any tracked record.
    case unknownCommandID(String)
    /// `state` wasn't one of `CommandRecord.State`'s raw values.
    case unrecognizedStateFilter(String)

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
        case .unknownCommandID(let raw):
            return "Unknown command_id: \(raw)"
        case .unrecognizedStateFilter(let raw):
            return "Unrecognized state filter: \(raw). Valid values: running, finished, orphaned"
        }
    }
}

// MARK: - MCPCommandLogBridge

@MainActor
final class MCPCommandLogBridge {

    private let store: CommandLogStore
    private let sessionSurfaceMap: SessionSurfaceMap

    init(store: CommandLogStore, sessionSurfaceMap: SessionSurfaceMap = .shared) {
        self.store = store
        self.sessionSurfaceMap = sessionSurfaceMap
    }

    // MARK: - Tool catalogue

    /// The full set of MCP tools published by this bridge:
    /// `terminal_list_commands` / `terminal_read_output` /
    /// `terminal_await_command`. `nonisolated`, matching
    /// `MCPLSPBridge.tools`, so callers (`MCPRouter`, tests) can
    /// enumerate it without hopping onto the main actor.
    nonisolated static let tools: [MCPTool] = [
        MCPTool(
            name: "terminal_list_commands",
            description: "List commands tracked for a terminal surface, oldest-first. surface_id also "
                + "accepts a calyx-session ID in place of the raw surface UUID. Each entry carries "
                + "output_total_rows/output_truncated metadata but never the captured text itself -- "
                + "use terminal_read_output for that.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "surface_id": MCPRouter.prop("string", "Surface UUID or calyx-session ID to list commands for"),
                    "limit": MCPRouter.prop("number", "Cap the result to the N most recently started commands"),
                    "state": MCPRouter.prop("string", "Filter to one state: running, finished, or orphaned"),
                ],
                required: ["surface_id"]
            )
        ),
        MCPTool(
            name: "terminal_read_output",
            description: "Read a specific command's captured output by its id (from "
                + "terminal_list_commands / terminal_await_command). Alt-screen or zero-output commands "
                + "return an empty text with total_rows 0. output_unavailable: true means capture was "
                + "impossible (distinct from a genuinely empty capture).",
            inputSchema: MCPRouter.schema(
                properties: [
                    "command_id": MCPRouter.prop("string", "The command's id, as returned by terminal_list_commands / terminal_await_command"),
                ],
                required: ["command_id"]
            )
        ),
        MCPTool(
            name: "terminal_await_command",
            description: "Block until a running command finishes (or the timeout elapses) and return its "
                + "record. surface_id also accepts a calyx-session ID. Omit command_id to wait on the "
                + "surface's newest running command. On timeout the result is {\"status\": \"timeout\"} "
                + "-- the caller should simply call terminal_await_command again to keep waiting.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "surface_id": MCPRouter.prop("string", "Surface UUID or calyx-session ID to await a command on"),
                    "command_id": MCPRouter.prop("string", "The command's id to wait on; defaults to the surface's newest running command"),
                    "timeout_ms": MCPRouter.prop("number", "Milliseconds to wait before giving up (default 30000, clamped to [0, 55000])"),
                ],
                required: ["surface_id"]
            )
        ),
    ]

    // MARK: - Dispatch

    /// Default `timeout_ms` for `terminal_await_command` when the
    /// argument is omitted.
    private static let defaultAwaitTimeoutMs = 30_000
    /// Ceiling `timeout_ms` is clamped to before reaching
    /// `CommandLogStore.awaitCompletion` -- comfortably under an HTTP
    /// client's own request timeout. `CommandLogStore.awaitCompletion`
    /// clamps to a much larger `[0, 3_600_000]` range itself; this is a
    /// tighter belt-and-suspenders clamp at the MCP tool boundary.
    private static let maxAwaitTimeoutMs = 55_000

    /// Route an MCP `tools/call` to the matching `terminal_*` handler.
    ///
    /// Every tool-level failure (missing/invalid arguments, unresolvable
    /// `surface_id`, unknown `command_id`, an unrecognized `state`
    /// filter, ...) is raised as a thrown `MCPCommandLogBridgeError` --
    /// `CalyxMCPServer.handleTerminalToolCall` catches it and builds the
    /// tool-error text from `error.localizedDescription`, mirroring
    /// `handleLSPToolCall`'s do/catch shape. `{"status": "timeout"}` is
    /// a normal (non-throwing) SUCCESS return, not an error.
    func handleToolCall(name: String, arguments: [String: Any]) async throws -> String {
        switch name {
        case "terminal_list_commands":
            return try handleListCommands(arguments: arguments)
        case "terminal_read_output":
            return try handleReadOutput(arguments: arguments)
        case "terminal_await_command":
            return try await handleAwaitCommand(arguments: arguments)
        default:
            throw MCPCommandLogBridgeError.unknownTool(name)
        }
    }

    // MARK: - terminal_list_commands

    private func handleListCommands(arguments: [String: Any]) throws -> String {
        let rawSurfaceID = try requireString(arguments, "surface_id")
        guard let surfaceID = resolveSurfaceID(rawSurfaceID) else {
            throw MCPCommandLogBridgeError.unresolvableSurfaceID(rawSurfaceID)
        }

        var state: CommandRecord.State?
        if let rawState = try optionalString(arguments, "state") {
            guard let parsed = CommandRecord.State(rawValue: rawState) else {
                throw MCPCommandLogBridgeError.unrecognizedStateFilter(rawState)
            }
            state = parsed
        }

        let limit = try optionalInt(arguments, "limit")

        // shell_integration reflects whether the surface has ANY tracked
        // records at all, independent of the state/limit filters applied
        // to the list itself below.
        let shellIntegration = !store.records(surfaceID: surfaceID, limit: nil, state: nil).isEmpty
        let records = store.records(surfaceID: surfaceID, limit: limit, state: state)

        let responseDict: [String: Any] = [
            "shell_integration": shellIntegration,
            "commands": records.map(listEntryDict),
        ]
        return jsonString(responseDict)
    }

    // MARK: - terminal_read_output

    private func handleReadOutput(arguments: [String: Any]) throws -> String {
        let rawCommandID = try requireString(arguments, "command_id")
        guard let commandID = UUID(uuidString: rawCommandID),
              let record = store.record(id: commandID) else {
            throw MCPCommandLogBridgeError.unknownCommandID(rawCommandID)
        }
        return jsonString(outputDict(commandID: record.id, output: record.output))
    }

    // MARK: - terminal_await_command

    private func handleAwaitCommand(arguments: [String: Any]) async throws -> String {
        let rawSurfaceID = try requireString(arguments, "surface_id")
        guard let surfaceID = resolveSurfaceID(rawSurfaceID) else {
            throw MCPCommandLogBridgeError.unresolvableSurfaceID(rawSurfaceID)
        }

        var commandID: UUID?
        if let rawCommandID = try optionalString(arguments, "command_id") {
            guard let parsed = UUID(uuidString: rawCommandID) else {
                throw MCPCommandLogBridgeError.invalidArgument(name: "command_id", reason: "expected a UUID string")
            }
            commandID = parsed
        }

        let requestedTimeoutMs = try optionalInt(arguments, "timeout_ms") ?? Self.defaultAwaitTimeoutMs
        let timeoutMs = min(max(requestedTimeoutMs, 0), Self.maxAwaitTimeoutMs)

        guard let record = await store.awaitCompletion(
            surfaceID: surfaceID, commandID: commandID, timeoutMs: timeoutMs
        ) else {
            return jsonString(["status": "timeout"])
        }
        return jsonString(fullRecordDict(record))
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
    /// absent, `.invalidArgument` when present but not a `String` (e.g.
    /// `{"surface_id": 12345}` must read as a type error, not "missing").
    private func requireString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] else {
            throw MCPCommandLogBridgeError.missingArgument(key)
        }
        guard let string = value as? String else {
            throw MCPCommandLogBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return string
    }

    /// Optional string argument: `nil` when `key` is absent; throws
    /// `.invalidArgument` when present but not a `String`.
    private func optionalString(_ arguments: [String: Any], _ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        guard let string = value as? String else {
            throw MCPCommandLogBridgeError.invalidArgument(name: key, reason: "expected string")
        }
        return string
    }

    /// Optional integer argument: `nil` when `key` is absent; throws
    /// `.invalidArgument` when present but not a whole number `decodeInt`
    /// can represent exactly.
    private func optionalInt(_ arguments: [String: Any], _ key: String) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let intValue = decodeInt(value) else {
            throw MCPCommandLogBridgeError.invalidArgument(name: key, reason: "expected integer")
        }
        return intValue
    }

    /// Bounds-checked `Int` decode, mirroring `MCPLSPBridge.decodeValue`'s
    /// `Int` branch (reject non-numeric/non-whole values; a JSON `true`/
    /// `false` must not silently coerce to `1`/`0` -- `is Bool` catches
    /// that here, since `NSNumber`'s `CFBooleanRef` backing bridges
    /// straight to Swift `Bool`, before `Int`/`Double` casts even see
    /// it). `Int(exactly:)` never traps and rejects any value that isn't
    /// exactly representable as `Int`: fractional (30000.5), non-finite,
    /// or out of `Int`'s range -- `{"limit": 1e300}` used to reach a
    /// direct `Int(_: Double)` conversion here, which DOES trap for a
    /// magnitude beyond `Int.max` (reproduced empirically); `Int(exactly:)`
    /// returns `nil` for the same input instead.
    private func decodeInt(_ value: Any) -> Int? {
        guard !(value is Bool) else { return nil }
        if let intValue = value as? Int { return intValue }
        guard let doubleValue = value as? Double else { return nil }
        return Int(exactly: doubleValue)
    }

    // MARK: - Record serialization

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Fields common to both the list-entry and full-record JSON shapes.
    /// Optional fields (`exit_code`, `ended_at`, `duration_ms`) are
    /// omitted entirely when unset, rather than serialized as JSON
    /// `null` -- a running record must not carry an `exit_code` key at
    /// all.
    private func baseRecordDict(_ record: CommandRecord) -> [String: Any] {
        var dict: [String: Any] = [
            "id": record.id.uuidString,
            "cmd_id": record.cmdID,
            "command": record.command,
            "cwd": record.cwd,
            "state": record.state.rawValue,
            "started_at": Self.iso8601.string(from: record.startedAt),
        ]
        if let exitCode = record.exitCode {
            dict["exit_code"] = Int(exitCode)
        }
        if let endedAt = record.endedAt {
            dict["ended_at"] = Self.iso8601.string(from: endedAt)
        }
        if let durationNanos = record.durationNanos {
            dict["duration_ms"] = Double(durationNanos) / 1_000_000.0
        }
        return dict
    }

    /// `terminal_list_commands` entry shape: output METADATA
    /// (`output_total_rows` / `output_truncated`) only, never the
    /// captured text itself.
    private func listEntryDict(_ record: CommandRecord) -> [String: Any] {
        var dict = baseRecordDict(record)
        if let output = record.output {
            dict["output_total_rows"] = output.totalRows
            dict["output_truncated"] = output.truncated
        }
        return dict
    }

    /// `terminal_await_command` result shape: the full record, including
    /// the captured output text (unlike the list-entry shape above).
    private func fullRecordDict(_ record: CommandRecord) -> [String: Any] {
        var dict = baseRecordDict(record)
        applyOutputFields(record.output, to: &dict)
        return dict
    }

    /// `terminal_read_output` result shape.
    private func outputDict(commandID: UUID, output: CommandOutput?) -> [String: Any] {
        var dict: [String: Any] = ["command_id": commandID.uuidString]
        applyOutputFields(output, to: &dict)
        return dict
    }

    /// Shared output-shaping rule between `fullRecordDict` and
    /// `outputDict`: a present (possibly empty) `CommandOutput` becomes
    /// `text`/`truncated`/`total_rows`; a nil output (capture was
    /// impossible) becomes `output_unavailable: true` with no `text` key
    /// at all.
    private func applyOutputFields(_ output: CommandOutput?, to dict: inout [String: Any]) {
        if let output {
            dict["text"] = output.text
            dict["truncated"] = output.truncated
            dict["total_rows"] = output.totalRows
        } else {
            dict["output_unavailable"] = true
        }
    }

    /// Every dictionary this bridge serializes is built entirely from
    /// this file's own `String`/`Int`/`Double`/`Bool`/`Array`/
    /// `Dictionary` values, so `JSONSerialization` encoding cannot
    /// actually fail here; `"{}"` is an unreachable-in-practice, still
    /// well-formed-JSON fallback rather than a partial/garbled payload.
    private func jsonString(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
