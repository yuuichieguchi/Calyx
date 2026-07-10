// MCPCockpitBridge.swift
// Calyx
//
// Bridges CockpitAppAccessing onto the MCP tool surface -- pane_list /
// pane_split / tab_create (P4, ungated); pane_run / pane_send_keys /
// palette_execute (P5, gated by the approval flow -- see
// `gate(toolName:targetSurfaceID:payload:)` below). Mirrors
// MCPCommandLogBridge's shape (nonisolated tools catalogue, typed
// LocalizedError+Equatable error enum, requireString/optionalString/
// optionalBool/optionalInt/decodeInt argument helpers, handleToolCall
// dispatch switch, surface_id two-step resolution via SessionSurfaceMap,
// [String: Any] + JSONSerialization response building, and (P5) the
// static CommandRecord serialization helpers it exposes for pane_run's
// `await: true` path) -- see that file's own header for the full-size
// version this one is scaled down from. See
// CalyxTests/IPC/MCPCockpitBridgeTests.swift for the specced contract
// this satisfies.
//
// P5's approval-gate contract: validate args + resolve surface +
// paneExists FIRST (fail fast before bothering the human) -> if
// ApprovalPolicy.requiresApproval(): build an ApprovalRequest (source:
// .mcpTool(name:), targetSurfaceID: the pane's surface for
// pane_run/pane_send_keys, nil for palette_execute, payload: the exact
// command/text/"palette_execute: <id> — <title>") -> approvals.submit
// -> approvals.awaitDecision(id:, timeoutMs: approvalTimeoutMs) ->
// .allowed: re-check Task.isCancelled (approvals' own documented
// caller obligation -- a cancelled Task must NOT execute even on
// .allowed) then EXECUTE / .denied: {"status": "denied"} / .expired:
// {"status": "approval_timeout"} (both non-error success payloads). If
// auto-approve is on, execute immediately without ever calling
// approvals.submit.

import Foundation

// MARK: - MCPCockpitBridgeError

/// Failures raised by `MCPCockpitBridge` before returning a result.
/// Shape mirrors `MCPCommandLogBridgeError`.
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
    /// `palette_execute`'s `command_id` isn't among
    /// `access.availablePaletteCommands()` at all -- `available` lists
    /// every currently-known command id, sorted, so the caller can pick
    /// a valid one without a separate discovery round trip.
    case unknownPaletteCommand(id: String, available: [String])
    /// `palette_execute`'s `command_id` is a real, known command, but
    /// `isAvailable` is false -- either at the initial check (before
    /// ever bothering the human with an approval banner for something
    /// unexecutable) or at the post-approval re-check (its availability
    /// shifted while the human was deciding).
    case paletteCommandUnavailable(String)

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
        case .unknownPaletteCommand(let id, let available):
            return "Unknown palette command: \(id). Available command ids: \(available.joined(separator: ", "))"
        case .paletteCommandUnavailable(let id):
            return "Palette command is not currently available: \(id)"
        }
    }
}

// MARK: - MCPCockpitBridge

@MainActor
final class MCPCockpitBridge {

    private let access: CockpitAppAccessing
    private let sessionSurfaceMap: SessionSurfaceMap
    /// The approval inbox pane_run/pane_send_keys/palette_execute submit
    /// into when `ApprovalPolicy.requiresApproval()` -- see `gate(toolName:targetSurfaceID:payload:)`.
    private let approvals: ApprovalInboxStore
    /// Consulted for pane_run's RETURN MECHANICS ONLY (whether the
    /// target pane has a tracked agent entry, deciding a single vs.
    /// doubled synthetic Return) -- never for the approval decision
    /// itself, which is uniformly gated by ApprovalPolicy regardless of
    /// agent-pane status (no agent-pane exception, per the approved
    /// plan).
    private let agentRegistry: AgentRegistry
    /// Consulted by pane_run's `await: true` path via
    /// `awaitNextCompletion(surfaceID:startedAfter:timeoutMs:)`, which
    /// correlates on `startedAfter` rather than resolving eagerly like
    /// `awaitCompletion(commandID: nil)` -- see `handlePaneRun`'s own
    /// comment for why that distinction matters here.
    private let commandLogStore: CommandLogStore
    /// P5: the timeout `awaitDecision` is given while a gated call waits
    /// on a human's Allow/Deny/Always Allow decision. A settable
    /// initializer parameter (not a hardcoded 55_000) so tests can drive
    /// the timeout path in well under a second rather than actually
    /// waiting out the real 55s production value.
    private let approvalTimeoutMs: Int

    init(
        access: CockpitAppAccessing,
        sessionSurfaceMap: SessionSurfaceMap = .shared,
        approvals: ApprovalInboxStore = .shared,
        agentRegistry: AgentRegistry = .shared,
        commandLogStore: CommandLogStore = .shared,
        approvalTimeoutMs: Int = 55_000
    ) {
        self.access = access
        self.sessionSurfaceMap = sessionSurfaceMap
        self.approvals = approvals
        self.agentRegistry = agentRegistry
        self.commandLogStore = commandLogStore
        self.approvalTimeoutMs = approvalTimeoutMs
    }

    // MARK: - Tool catalogue

    /// The tool names this bridge dispatches.
    nonisolated static let toolNames: Set<String> = [
        "pane_list", "pane_split", "tab_create",
        "pane_run", "pane_send_keys", "palette_execute",
    ]

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
        MCPTool(
            name: "pane_run",
            description: "Run a command in a pane by pasting its text and pressing Return. surface_id "
                + "also accepts a calyx-session ID in place of the raw surface UUID. Requires in-app "
                + "user approval unless auto-approve is enabled; {\"status\":\"denied\"} and "
                + "{\"status\":\"approval_timeout\"} are normal results — after denied, do not retry "
                + "without new user intent.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "surface_id": MCPRouter.prop("string", "Surface UUID or calyx-session ID of the pane to run the command in"),
                    "command": MCPRouter.prop("string", "The command text to send"),
                    "await": MCPRouter.prop("boolean", "Wait for completion of the command THIS call starts (start-time correlated via shell-integration tracking, never an unrelated already-running command); on untracked shells the wait times out"),
                    "timeout_ms": MCPRouter.prop("number", "default 30000, clamped [0,55000]"),
                ],
                required: ["surface_id", "command"]
            )
        ),
        MCPTool(
            name: "pane_send_keys",
            description: "Send raw text to a pane verbatim, with no Return appended. surface_id also "
                + "accepts a calyx-session ID in place of the raw surface UUID. Requires in-app user "
                + "approval unless auto-approve is enabled; {\"status\":\"denied\"} and "
                + "{\"status\":\"approval_timeout\"} are normal results — after denied, do not retry "
                + "without new user intent.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "surface_id": MCPRouter.prop("string", "Surface UUID or calyx-session ID of the pane to send text to"),
                    "text": MCPRouter.prop("string", "verbatim paste; NO Return appended; \\u0003 = Ctrl-C; may be empty"),
                ],
                required: ["surface_id", "text"]
            )
        ),
        MCPTool(
            name: "palette_execute",
            description: "Execute a command-palette entry by its id. An unknown id is rejected with "
                + "the list of currently available ids. Requires in-app user approval unless "
                + "auto-approve is enabled; {\"status\":\"denied\"} and {\"status\":\"approval_timeout\"} "
                + "are normal results — after denied, do not retry without new user intent.",
            inputSchema: MCPRouter.schema(
                properties: [
                    "command_id": MCPRouter.prop("string", "The command-palette entry's id to execute"),
                ],
                required: ["command_id"]
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
        case "pane_run":
            return try await handlePaneRun(arguments: arguments)
        case "pane_send_keys":
            return try await handlePaneSendKeys(arguments: arguments)
        case "palette_execute":
            return try await handlePaletteExecute(arguments: arguments)
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

    // MARK: - pane_run

    /// Default `timeout_ms` for `pane_run`'s `await: true` path when the
    /// argument is omitted, mirroring `MCPCommandLogBridge`'s own
    /// `terminal_await_command` default.
    private static let defaultCommandTimeoutMs = 30_000
    /// Ceiling `timeout_ms` (and the elapsed-time budget `await: true`
    /// shares with the approval gate that may have already run first)
    /// is clamped to, same rationale/value as
    /// `MCPCommandLogBridge.maxAwaitTimeoutMs`: comfortably under an
    /// HTTP client's own request timeout.
    private static let maxCommandTimeoutMs = 55_000

    private func handlePaneRun(arguments: [String: Any]) async throws -> String {
        let entryTime = Date()

        let rawSurfaceID = try requireString(arguments, "surface_id")
        guard let surfaceID = resolveSurfaceID(rawSurfaceID) else {
            throw MCPCockpitBridgeError.unresolvableSurfaceID(rawSurfaceID)
        }
        let command = try requireString(arguments, "command")
        let shouldAwait = try optionalBool(arguments, "await") ?? false
        let requestedTimeoutMs = try optionalInt(arguments, "timeout_ms") ?? Self.defaultCommandTimeoutMs
        let clampedTimeoutMs = min(max(requestedTimeoutMs, 0), Self.maxCommandTimeoutMs)

        // Fail fast on a dead surface_id BEFORE ever bothering the human:
        // a well-formed but nonexistent pane's approval banner is
        // invisible in every window (no window owns a dead surface), so
        // without this check the call would submit an approval that can
        // never actually be seen, then stall for the full approval
        // timeout before finally failing anyway.
        guard access.paneExists(surfaceID) else {
            throw MCPCockpitBridgeError.paneNotFound(surfaceID)
        }

        if case .respond(let dict) = await gate(toolName: "pane_run", targetSurfaceID: surfaceID, payload: command) {
            return jsonString(dict)
        }

        // Return mechanics only: an agent-pane target still requires the
        // same approval gate above (no exception) -- this decides only
        // whether the synthetic Return is sent once or twice.
        let doubleReturn = agentRegistry.entries[surfaceID] != nil
        do {
            try access.sendCommand(surfaceID: surfaceID, command: command, doubleReturn: doubleReturn)
        } catch {
            throw mapAccessError(error)
        }

        guard shouldAwait else {
            return jsonString(["status": "sent", "surface_id": surfaceID.uuidString])
        }

        let elapsedMs = Int(Date().timeIntervalSince(entryTime) * 1000)
        let remainingMs = max(min(clampedTimeoutMs, Self.maxCommandTimeoutMs - elapsedMs), 0)
        // Start-time correlated, NOT awaitCompletion(commandID: nil):
        // this handler holds MainActor synchronously from access.sendCommand
        // through to this await, and the shell integration ingests the
        // command's own .start event asynchronously (a separate
        // /command-event POST it can't process until we yield MainActor
        // back) -- awaitCompletion's eager newest-running-record
        // resolution would either see nothing running yet (instant
        // {"status":"timeout"}) or latch onto a DIFFERENT, already-running
        // command. awaitNextCompletion instead correlates against
        // startedAt > entryTime, so it always resolves to the command
        // THIS call started. See CommandLogStore.awaitNextCompletion's
        // own doc comment.
        guard let record = await commandLogStore.awaitNextCompletion(
            surfaceID: surfaceID, startedAfter: entryTime, timeoutMs: remainingMs
        ) else {
            return jsonString(["status": "timeout"])
        }
        return jsonString(MCPCommandLogBridge.fullRecordDict(record))
    }

    // MARK: - pane_send_keys

    private func handlePaneSendKeys(arguments: [String: Any]) async throws -> String {
        let rawSurfaceID = try requireString(arguments, "surface_id")
        guard let surfaceID = resolveSurfaceID(rawSurfaceID) else {
            throw MCPCockpitBridgeError.unresolvableSurfaceID(rawSurfaceID)
        }
        // requireString accepts an empty string fine (it only rejects a
        // missing key or a non-string value) -- pane_send_keys' own
        // contract explicitly allows an empty text payload, unlike
        // tab_create's cwd/group_name blank-rejection contract.
        let text = try requireString(arguments, "text")

        // Fail fast on a dead surface_id BEFORE the gate -- see
        // handlePaneRun's identical check for the rationale.
        guard access.paneExists(surfaceID) else {
            throw MCPCockpitBridgeError.paneNotFound(surfaceID)
        }

        if case .respond(let dict) = await gate(toolName: "pane_send_keys", targetSurfaceID: surfaceID, payload: text) {
            return jsonString(dict)
        }

        do {
            try access.sendKeys(surfaceID: surfaceID, text: text)
        } catch {
            throw mapAccessError(error)
        }

        return jsonString(["status": "sent", "surface_id": surfaceID.uuidString])
    }

    // MARK: - palette_execute

    private func handlePaletteExecute(arguments: [String: Any]) async throws -> String {
        let commandID = try requireString(arguments, "command_id")

        let initialCommand = try paletteCommandExecutable(commandID)

        let payload = "palette_execute: \(commandID) — \(initialCommand.title)"
        if case .respond(let dict) = await gate(toolName: "palette_execute", targetSurfaceID: nil, payload: payload) {
            return jsonString(dict)
        }

        // Re-check availability after the gate -- a command that was
        // available when the human's approval prompt was raised may no
        // longer be by the time they actually decide. Exactly one more
        // call to access.availablePaletteCommands() here, matching the
        // initial check above: two total per invocation.
        _ = try paletteCommandExecutable(commandID)

        let executed: CockpitPaletteCommand
        do {
            executed = try access.executePaletteCommand(id: commandID)
        } catch {
            throw mapAccessError(error)
        }

        return jsonString(["status": "executed", "command_id": executed.id, "title": executed.title])
    }

    /// Throws `.unknownPaletteCommand` when `commandID` isn't among
    /// `access.availablePaletteCommands()` at all (listing every
    /// currently AVAILABLE id, sorted, so the caller can pick a valid
    /// one without a separate discovery round trip), or
    /// `.paletteCommandUnavailable` when it's known but not currently
    /// executable. Returns the matched command on success so a caller
    /// (e.g. for the approval payload's title) never needs a second,
    /// separate `access.availablePaletteCommands()` call of its own.
    @discardableResult
    private func paletteCommandExecutable(_ commandID: String) throws -> CockpitPaletteCommand {
        let commands = access.availablePaletteCommands()
        guard let command = commands.first(where: { $0.id == commandID }) else {
            throw MCPCockpitBridgeError.unknownPaletteCommand(
                id: commandID, available: commands.filter(\.isAvailable).map(\.id).sorted()
            )
        }
        guard command.isAvailable else {
            throw MCPCockpitBridgeError.paletteCommandUnavailable(commandID)
        }
        return command
    }

    // MARK: - Approval gate

    /// `gate`'s result: this is the whole tool's security control-flow
    /// choke, so it returns a named outcome rather than a `[String: Any]?`
    /// nil-means-proceed sentinel -- `.proceed` vs. `.respond(dict)` is
    /// self-documenting at every call site, where a stray `nil` typo
    /// would otherwise be easy to misread as "denied" instead of
    /// "allowed".
    private enum GateOutcome {
        /// Execute immediately: either auto-approve is on, or the gate
        /// resolved `.allowed` and the awaiting Task was not concurrently
        /// cancelled.
        case proceed
        /// Serialize `dict` and return it as-is, without executing
        /// anything (`"denied"` for a human's explicit denial,
        /// `"approval_timeout"` for the wait itself expiring OR for an
        /// `.allowed` decision racing a concurrent cancellation of this
        /// call's own Task -- `ApprovalInboxStore.awaitDecision`'s own
        /// doc comment requires callers to re-check `Task.isCancelled`
        /// before acting on `.allowed`; the caller is gone either way, so
        /// "approval_timeout" over "denied" better reflects that nobody
        /// actually decided anything).
        case respond([String: Any])
    }

    /// Shared gate for the 3 P5 tools -- see `GateOutcome` for what each
    /// case means to the caller.
    private func gate(
        toolName: String, targetSurfaceID: UUID?, payload: String
    ) async -> GateOutcome {
        guard ApprovalPolicy.requiresApproval() else { return .proceed }

        let request = ApprovalRequest(
            id: UUID(), source: .mcpTool(name: toolName), targetSurfaceID: targetSurfaceID,
            payload: payload, createdAt: Date()
        )
        approvals.submit(request)
        // `awaitDecisionHonoringCancellation` already demotes an
        // `.allowed` result to `.expired` when this call's own Task was
        // concurrently cancelled -- see that method's own doc comment on
        // `ApprovalInboxStore` for the caller obligation it centralizes.
        let decision = await approvals.awaitDecisionHonoringCancellation(id: request.id, timeoutMs: approvalTimeoutMs)

        switch decision {
        case .denied:
            return .respond(["status": "denied"])
        case .expired:
            return .respond(["status": "approval_timeout"])
        case .allowed:
            return .proceed
        }
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
        case .paletteCommandNotFound(let id):
            // `paletteCommandExecutable`'s own pre-execute checks (both
            // the initial one and the post-gate re-check) already
            // confirmed `id` was known, so this is only reachable via a
            // genuine live-app race between that re-check and the actual
            // `access.executePaletteCommand` call -- re-query for the
            // current available list rather than reporting a stale one.
            return MCPCockpitBridgeError.unknownPaletteCommand(
                id: id, available: access.availablePaletteCommands().filter(\.isAvailable).map(\.id).sorted()
            )
        case .paletteCommandUnavailable(let id):
            return MCPCockpitBridgeError.paletteCommandUnavailable(id)
        case .commandFailed:
            // Never actually thrown by LiveCockpitAppAccess today (see
            // CockpitAccessError's own definition); pass through
            // unchanged rather than inventing an unpinned mapping.
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

    /// Optional boolean argument: `nil` when `key` is absent; throws
    /// `.invalidArgument` when present but not a genuine JSON boolean.
    /// A plain `value as? Bool` / `value is Bool` is NOT sufficient to
    /// tell a real boolean apart from a JSON integer `0`/`1`, which
    /// bridges through `NSNumber` and satisfies both casts too (verified
    /// empirically against `JSONSerialization`'s own output; see
    /// `AnyCodable.init(_:)` in `JSONRPC.swift` for the same quirk and
    /// its established fix) -- `CFGetTypeID` against
    /// `CFBooleanGetTypeID()` identifies the genuine boolean variant
    /// explicitly, so `"await": 1` is correctly rejected rather than
    /// silently read as `true`.
    private func optionalBool(_ arguments: [String: Any], _ key: String) throws -> Bool? {
        guard let value = arguments[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw MCPCockpitBridgeError.invalidArgument(name: key, reason: "expected boolean")
        }
        return number.boolValue
    }

    /// Optional integer argument: `nil` when `key` is absent; throws
    /// `.invalidArgument` when present but not a whole number `decodeInt`
    /// can represent exactly. Mirrors `MCPCommandLogBridge.optionalInt`.
    private func optionalInt(_ arguments: [String: Any], _ key: String) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let intValue = decodeInt(value) else {
            throw MCPCockpitBridgeError.invalidArgument(name: key, reason: "expected integer")
        }
        return intValue
    }

    /// Bounds-checked `Int` decode. Mirrors
    /// `MCPCommandLogBridge.decodeInt` -- see that method's own doc
    /// comment for the full rationale (rejects non-numeric/non-whole
    /// values and `Int.max`-exceeding magnitudes via `Int(exactly:)`
    /// rather than a trapping direct conversion).
    private func decodeInt(_ value: Any) -> Int? {
        guard !(value is Bool) else { return nil }
        if let intValue = value as? Int { return intValue }
        guard let doubleValue = value as? Double else { return nil }
        return Int(exactly: doubleValue)
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
