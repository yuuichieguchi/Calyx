// PiExtensionManager.swift
// Calyx
//
// Manages `~/.pi/agent/extensions/calyx.ts`, the TypeScript extension pi
// auto-loads from that directory with no settings edit required. pi has
// neither an MCP client nor a hook system, so this single file carries
// the whole integration: the row-state pings, the synchronous approval
// gate, and the MCP tool bridge. Like OpenCode's plugin there is no user
// content to preserve here: the file is entirely Calyx's own, so install
// is a plain overwrite and remove is a plain delete (no BEGIN/END
// markers, no backup).

import Foundation

enum PiExtensionManager: Sendable {

    // MARK: - Constants

    static let fileName = "calyx.ts"

    /// The extension source pi loads. Subscribes to pi's lifecycle events
    /// and forwards them to Calyx's local Agent Monitor IPC endpoint,
    /// normalized to the canonical `hook_event_name` / `session_id` /
    /// `cwd` shape `AgentEvent.decode` already reads, with an
    /// `X-Calyx-Agent-Kind: pi` header. Its `tool_call` handler is
    /// Calyx's approval gate: pi ships no permission prompt of its own,
    /// so nothing else asks the user, and a `{ block: true, reason }`
    /// return is the only thing that stops a tool call.
    ///
    /// The `PermissionRequest` event name and the gate's client deadline
    /// are interpolated from `ApprovalHookEvent` / `ApprovalHookTiming`
    /// rather than written out, so the one cross-layer contract fact each
    /// of those types owns cannot drift inside this string.
    static let scriptBody: String = """
    // calyx.ts
    // Installed by Calyx (PiExtensionManager). Do not edit by hand:
    // reinstalling Calyx's AI Agent IPC support overwrites this file.
    //
    // pi has neither an MCP client configuration nor a hook system, so
    // this one file is the whole integration:
    //   1. Lifecycle events become the pane's row in the Agents sidebar.
    //   2. Every tool call waits on Calyx's approval inbox. pi ships no
    //      permission prompt of its own, so this gate is the only thing
    //      that can stop one.
    //   3. One dispatcher tool exposes Calyx's IPC tools to the model.
    //   4. A second dispatcher, calyx_mcp, exposes the tools of the MCP
    //      servers configured in Calyx (the /calyx-mcp endpoint). It is
    //      the only thing registered inside a herdr pane or outside Calyx.
    //
    // agent-endpoint.json (port and token) is cached by mtime and
    // re-parsed only when the file changes, so a Calyx restart or a token
    // rotation is picked up without reinstalling this extension.

    import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
    import { readFile, stat } from "node:fs/promises";

    const EVENT_MAP = {
      session_start: "SessionStart",
      before_agent_start: "UserPromptSubmit",
      tool_execution_end: "PostToolUse",
      agent_end: "Stop",
      session_shutdown: "SessionEnd",
    };

    export default function (pi: ExtensionAPI) {
      // A persistent pane's CALYX_SESSION_ID stays stable when its
      // Ghostty surface changes, so it is preferred over the launch-time
      // surface UUID.
      const calyxPaneID = process.env.CALYX_SESSION_ID || process.env.CALYX_SURFACE_ID;
      const herdrPaneID = process.env.HERDR_PANE_ID;

      // CALYX_ENDPOINT_FILE is injected by GhosttySurfaceController
      // alongside CALYX_SURFACE_ID, scoped to wherever this Calyx process
      // actually wrote agent-endpoint.json. The literal fallback covers a
      // pane launched before that injection existed.
      const endpointPath =
        process.env.CALYX_ENDPOINT_FILE ?? \(AgentEndpointFile.javascriptFallbackPathExpression);
      let cachedEndpoint = null;
      let cachedEndpointMtimeMs = null;

      async function loadEndpoint() {
        const stats = await stat(endpointPath);
        if (cachedEndpoint && stats.mtimeMs === cachedEndpointMtimeMs) {
          return cachedEndpoint;
        }
        const endpoint = JSON.parse(await readFile(endpointPath, "utf8"));
        cachedEndpoint = endpoint;
        cachedEndpointMtimeMs = stats.mtimeMs;
        return endpoint;
      }

      // The tools of the MCP servers configured in Calyx, reached through
      // /calyx-mcp without a session. The herdr headers let Calyx find
      // the herdr pane; the pane headers find an ordinary one.
      async function callCalyxMCP(method, params, signal) {
        const endpoint = await loadEndpoint();
        const response = await fetch(`http://127.0.0.1:${endpoint.port}/calyx-mcp`, {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${endpoint.token}`,
            "X-Calyx-Surface-ID": calyxPaneID ?? "",
            "X-Calyx-Agent-Kind": "pi",
            "X-Calyx-Herdr-Pane-ID": herdrPaneID ?? "",
            "X-Calyx-Herdr-Socket-Path": process.env.HERDR_SOCKET_PATH ?? "",
            "Content-Type": "application/json",
            "Accept": "application/json",
          },
          body: JSON.stringify({ jsonrpc: "2.0", id: "calyx-pi", method, params }),
          signal,
        });
        const answer = await response.json();
        if (answer.error) {
          throw new Error(answer.error.message);
        }
        return answer.result;
      }

      // Every failure becomes an error result: an unreachable Calyx must
      // never throw out of the tool.
      function registerCalyxMCP(pi) {
        pi.registerTool({
          name: "calyx_mcp",
          label: "Calyx MCP",
          description:
            "Bridge to the MCP servers configured in Calyx. Pass tool: 'list' to enumerate their " +
            "tools, then call one by name with its own arguments in args.",
          promptSnippet: "Reach the MCP servers configured in Calyx",
          parameters: {
            type: "object",
            properties: {
              tool: {
                type: "string",
                description: "Name of the tool to run, or 'list' to enumerate them",
              },
              args: {
                type: "object",
                description: "Arguments for that tool",
              },
            },
            required: ["tool"],
            additionalProperties: false,
          },
          async execute(toolCallId, params, signal, onUpdate, ctx) {
            try {
              const result = params.tool === "list"
                ? await callCalyxMCP("tools/list", {}, signal)
                : await callCalyxMCP("tools/call", { name: params.tool, arguments: params.args ?? {} }, signal);
              return {
                content: [{ type: "text", text: JSON.stringify(result) }],
                details: {},
              };
            } catch (error) {
              return {
                content: [{ type: "text", text: `Calyx MCP is unavailable: ${error}` }],
                details: {},
              };
            }
          },
        });
      }

      // A pi inside a herdr pane is already mirrored into Calyx by herdr
      // itself, and a pi started outside Calyx has no server to answer
      // its gate. Only the calyx_mcp dispatcher is registered in either
      // case: a live gate with nobody behind it would block on a server
      // nobody is running.
      if (!calyxPaneID || herdrPaneID) {
        registerCalyxMCP(pi);
        return;
      }

      function calyxHeaders(endpoint) {
        return {
          "Authorization": `Bearer ${endpoint.token}`,
          "X-Calyx-Surface-ID": calyxPaneID,
          "X-Calyx-Agent-Kind": "pi",
          "Content-Type": "application/json",
        };
      }

      // pi carries no session id in any event payload, so it is read from
      // the session manager, which answers with a plain string in both
      // session modes.
      function sessionID(ctx) {
        return ctx.sessionManager.getSessionId();
      }

      async function postState(hookEventName, ctx) {
        try {
          const endpoint = await loadEndpoint();
          await fetch(`http://127.0.0.1:${endpoint.port}/agent-event`, {
            method: "POST",
            headers: calyxHeaders(endpoint),
            body: JSON.stringify({
              hook_event_name: hookEventName,
              session_id: sessionID(ctx),
              cwd: ctx.cwd,
            }),
            signal: AbortSignal.timeout(2000),
          });
        } catch {
          // Calyx unreachable, endpoint file missing or malformed,
          // request timed out: a failed ping must never disturb pi.
        }
      }

      async function callCalyx(method, params, signal) {
        const endpoint = await loadEndpoint();
        const response = await fetch(`http://127.0.0.1:${endpoint.port}/mcp`, {
          method: "POST",
          headers: calyxHeaders(endpoint),
          body: JSON.stringify({ jsonrpc: "2.0", id: "calyx-pi", method, params }),
          signal,
        });
        const answer = await response.json();
        if (answer.error) {
          throw new Error(answer.error.message);
        }
        return answer.result;
      }

      for (const [piEvent, hookEventName] of Object.entries(EVENT_MAP)) {
        pi.on(piEvent, async (_event, ctx) => {
          await postState(hookEventName, ctx);
        });
      }

      // One handshake per session binds this pane to an IPC peer, which
      // is what gives the row its MCP connection presence and lets an
      // unread message light its badge. Registered after the state ping
      // above so the row exists before the binding lands on it.
      pi.on("session_start", async () => {
        try {
          await callCalyx("initialize", {}, AbortSignal.timeout(2000));
        } catch {
          // The row still reports state without a peer binding, so a
          // failed handshake must not disturb pi either.
        }
      });

      pi.on("tool_call", async (event, ctx) => {
        let answer;
        try {
          const endpoint = await loadEndpoint();
          const response = await fetch(`http://127.0.0.1:${endpoint.port}/approval-request`, {
            method: "POST",
            headers: calyxHeaders(endpoint),
            body: JSON.stringify({
              hook_event_name: "\(ApprovalHookEvent.name)",
              session_id: sessionID(ctx),
              cwd: ctx.cwd,
              tool_name: event.toolName,
              tool_input: event.input,
            }),
            signal: AbortSignal.timeout(\(ApprovalHookTiming.curlTimeoutSeconds * 1000)),
          });
          const text = await response.text();
          answer = text ? JSON.parse(text) : null;
        } catch {
          // Calyx unreachable, endpoint file missing, or this deadline
          // passed. The call runs: pi turns a throw from this handler
          // into a block, so absorbing the failure here is what keeps an
          // unreachable Calyx from becoming a pi that cannot run any tool
          // at all.
          return;
        }
        if (answer && answer.decision === "deny") {
          // reason reaches the model as the tool result content, worded
          // exactly as Calyx worded it. pi supplies its own text when a
          // block carries none.
          return { block: true, reason: answer.reason };
        }
      });

      // One dispatcher rather than one tool per Calyx IPC tool: every
      // registered tool's name and description goes into pi's system
      // prompt on every turn.
      pi.registerTool({
        name: "calyx",
        label: "Calyx",
        description:
          "Bridge to the Calyx terminal this pane runs in. Pass tool: 'list' to enumerate " +
          "the tools Calyx offers (messaging the other agent panes, terminal state, command " +
          "history), then call one by name with its own arguments in args.",
        promptSnippet: "Reach Calyx and the other agent panes running in it",
        parameters: {
          type: "object",
          properties: {
            tool: {
              type: "string",
              description: "Name of the Calyx tool to run, or 'list' to enumerate them",
            },
            args: {
              type: "object",
              description: "Arguments for that tool",
            },
          },
          required: ["tool"],
          additionalProperties: false,
        },
        async execute(toolCallId, params, signal, onUpdate, ctx) {
          const result = params.tool === "list"
            ? await callCalyx("tools/list", {}, signal)
            : await callCalyx("tools/call", { name: params.tool, arguments: params.args }, signal);
          return {
            content: [{ type: "text", text: JSON.stringify(result) }],
            details: {},
          };
        },
      });

      registerCalyxMCP(pi);
    }
    """

    // MARK: - Public API

    /// Installs the extension into `<extensionsDirectory>/extensions/`,
    /// creating that directory if needed, and returns its absolute path.
    /// `extensionsDirectory` is pi's agent root (`~/.pi/agent` by
    /// default), not the `extensions/` directory itself, mirroring
    /// `OpenCodePluginManager.install(pluginsDirectory:)`. Overwrites any
    /// existing file at that path: reinstalling is idempotent since
    /// `scriptBody` is a fixed constant, not something merged with prior
    /// content. A symlink at the destination path (a dotfiles-managed pi
    /// agent root can legitimately symlink `extensions/` or the extension
    /// file itself elsewhere) is followed to its real file
    /// (`ConfigFileUtils.resolveConfigPath`) and overwritten in place,
    /// leaving the symlink itself intact.
    static func install(extensionsDirectory: String? = nil) throws -> String {
        let scriptPath = extensionPath(extensionsDirectory: extensionsDirectory)
        let extensionsDir = (scriptPath as NSString).deletingLastPathComponent

        let fm = FileManager.default
        if !fm.fileExists(atPath: extensionsDir) {
            try fm.createDirectory(atPath: extensionsDir, withIntermediateDirectories: true)
        }

        let data = Data(scriptBody.utf8)
        // 0600: Calyx owns this file outright.
        try ConfigFileUtils.withExclusiveConfig(path: scriptPath, mode: 0o600, restoreModeOnNoWrite: true) { _ in data }
        return scriptPath
    }

    /// Deletes the extension file. A no-op when nothing is installed;
    /// throws if the file exists but could not be removed (e.g. a
    /// permissions error), rather than silently leaving it in place.
    /// Symmetric with `install`: resolves a symlinked destination path
    /// and removes the real target file, leaving the symlink itself
    /// intact (now dangling). Removing the raw path instead would unlink
    /// the symlink and leave the real installed extension behind, still
    /// loaded by pi.
    static func remove(extensionsDirectory: String? = nil) throws {
        let path = extensionPath(extensionsDirectory: extensionsDirectory)
        try ConfigFileUtils.withExclusiveConfig(path: path) { _ in nil }
    }

    static func isInstalled(extensionsDirectory: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: extensionPath(extensionsDirectory: extensionsDirectory))
    }

    // MARK: - Private

    /// `<extensionsDirectory>/extensions/calyx.ts`. `extensionsDirectory`
    /// is pi's agent root (`~/.pi/agent` by default), not the
    /// `extensions/` directory itself, matching the directory-existence
    /// check `AgentHooksCoordinator` runs against that same root.
    private static func extensionPath(extensionsDirectory: String?) -> String {
        let root = extensionsDirectory ?? defaultConfigDirectory
        let extensionsDir = (root as NSString).appendingPathComponent("extensions")
        return (extensionsDir as NSString).appendingPathComponent(fileName)
    }

    private static var defaultConfigDirectory: String {
        AgentToolPaths.piConfigDirectory
    }
}
