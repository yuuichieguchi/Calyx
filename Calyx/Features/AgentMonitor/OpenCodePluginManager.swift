// OpenCodePluginManager.swift
// Calyx
//
// Manages `~/.config/opencode/plugins/calyx-agent-monitor.js`, a
// Bun-runtime plugin OpenCode auto-loads with no `opencode.json` edit
// required — OpenCode's equivalent of Claude Code's hooks.json /  Codex's
// `[[hooks.*]]` block. Unlike those two, there's no user content to
// preserve here: the plugin file is entirely Calyx's own, so install is a
// plain overwrite and remove is a plain delete (no BEGIN/END markers, no
// backup).

import Foundation

// MARK: - OpenCodePluginManager

enum OpenCodePluginManager: Sendable {

    // MARK: - Constants

    static let fileName = "calyx-agent-monitor.js"

    /// OpenCode plugin API: `export default async ({ directory }) => ({
    /// event: async ({ event }) => {...} })`. Forwards OpenCode's plugin
    /// events to Calyx's local Agent Monitor IPC endpoint, normalized to
    /// the same `hook_event_name` / `session_id` / `cwd` shape Claude
    /// Code's hooks send (`AgentEvent.decode`), with an
    /// `X-Calyx-Agent-Kind: opencode` header so the server attributes the
    /// entry to OpenCode rather than Claude Code.
    static let scriptBody: String = """
    // calyx-agent-monitor.js
    // Installed by Calyx (OpenCodePluginManager) — do not edit by hand;
    // reinstalling Calyx's AI Agent IPC support overwrites this file.
    //
    // Forwards OpenCode plugin events to Calyx's local Agent Monitor IPC
    // endpoint. agent-endpoint.json (port/token) is cached by mtime and
    // only re-read/re-parsed when the file actually changes, so a Calyx
    // server restart or token rotation is still picked up without
    // reinstalling this plugin.

    import { stat } from "node:fs/promises";

    // opencode 1.18.18's plugin event vocabulary has no process-exit
    // event, so a plugin cannot report one. Exiting the process leaves
    // the session undeleted, so `session.deleted` (and the
    // `SessionEnd` it maps to below) fires only on an actual session
    // deletion, not on process exit. The pane's own exit signal
    // (AgentRegistry.handlePaneCommandFinished, fed by
    // `/command-event`) is what settles the row once the process is
    // gone -- but only once Command Tracking is enabled
    // (CommandTrackingSettings.trackingEnabled) and the pane is running
    // an interactive zsh or fish, the only two shells
    // ShellIntegrationInstaller installs into.
    const EVENT_MAP = {
      "session.created": "SessionStart",
      "tool.execute.before": "PreToolUse",
      "tool.execute.after": "PostToolUse",
      "permission.asked": "PermissionRequest",
      "permission.replied": "PostToolUse",
      "session.idle": "Stop",
      "session.deleted": "SessionEnd",
    };

    export default async ({ directory }) => {
      // Not launched from a Calyx pane (e.g. a plain terminal running
      // `opencode`) — register no hooks at all. A persistent pane's
      // CALYX_SESSION_ID remains stable when its Ghostty surface changes,
      // so prefer it over the launch-time surface UUID.
      const calyxPaneID =
        process.env.CALYX_SESSION_ID || process.env.CALYX_SURFACE_ID;
      if (!calyxPaneID) {
        return {};
      }

      // session.created's info.parentID marks a subagent's own child
      // session. Every later event for that session ID is translated
      // into a subagent event instead of forwarded as-is: the child's
      // own session.created posts SubagentStart, and everything in
      // between is forwarded with agent_id set to the child's session id
      // in place of session_id. The server-side guard that keeps a child
      // from ever stealing its parent's row (AgentEvent.isSubagentEvent,
      // checked in CalyxMCPServer.routeAgentEvent and AgentStateResolver
      // .resolveHookRow) is what makes sending these at all safe. A
      // child's own session.idle posts SubagentStop and removes the
      // entry: a subagent session going idle is OpenCode reporting that
      // child's work is over, since a subagent never takes another turn.
      // The child's own session.deleted does the same, as a second,
      // independent end signal -- both are what keep this set from
      // growing without bound over a long-lived process.
      const childSessions = new Set();

      // Session IDs with a permission.asked that hasn't yet seen its
      // permission.replied. Suppresses session.idle -> Stop (and the
      // childSessions session.idle -> SubagentStop retirement below) for
      // a pending session so a Stop racing ahead of the reply can't
      // overwrite the blocked row with idle while the prompt is still
      // awaiting a reply. Tracked uniformly for a child session's own
      // sessionID too: a child's permission.asked reaches the parent row
      // through the same resultingState(for:) mapping AgentStateResolver
      //'s subagent branch and SubagentRegistry both reuse, so a child's
      // session.idle can race its own permission.replied exactly the way
      // a parent's can, and needs the same guard. Entries are removed
      // when the owning session ends: on the session's own
      // session.deleted, and for a child session, also on its own
      // session.idle (mirroring childSessions' retirement above) -- a
      // session that ends with an outstanding, never-answered prompt
      // doesn't leak an entry here for the lifetime of the plugin
      // process.
      const pendingPermissions = new Set();

      let cachedEndpoint = null;
      let cachedEndpointMtimeMs = null;

      async function loadEndpoint() {
        // CALYX_ENDPOINT_FILE is injected by GhosttySurfaceController
        // alongside CALYX_SURFACE_ID, scoped to wherever this Calyx
        // process actually wrote agent-endpoint.json. The literal
        // fallback covers a pane launched before that injection existed.
        const endpointPath =
          process.env.CALYX_ENDPOINT_FILE ?? \(AgentEndpointFile.javascriptFallbackPathExpression);
        const stats = await stat(endpointPath);
        if (cachedEndpoint && stats.mtimeMs === cachedEndpointMtimeMs) {
          return cachedEndpoint;
        }
        const endpoint = JSON.parse(await Bun.file(endpointPath).text());
        cachedEndpoint = endpoint;
        cachedEndpointMtimeMs = stats.mtimeMs;
        return endpoint;
      }

      function resolveSessionID(properties) {
        const info = properties && properties.info;
        return (
          properties?.sessionID ??
          properties?.session_id ??
          properties?.sessionId ??
          info?.id ??
          null
        );
      }

      async function postEvent(bodyJSON) {
        try {
          const endpoint = await loadEndpoint();

          await fetch(`http://127.0.0.1:${endpoint.port}/agent-event`, {
            method: "POST",
            headers: {
              "Authorization": `Bearer ${endpoint.token}`,
              "X-Calyx-Surface-ID": calyxPaneID,
              "X-Calyx-Agent-Kind": "opencode",
              "Content-Type": "application/json",
            },
            body: bodyJSON,
            signal: AbortSignal.timeout(2000),
          });
        } catch {
          // Server unreachable, agent-endpoint.json missing/malformed,
          // request timeout, etc. — never let a failed POST affect
          // OpenCode itself.
        }
      }

      return {
        event: async ({ event }) => {
          const hookEventName = EVENT_MAP[event.type];
          if (!hookEventName) return;

          const properties = event.properties || {};
          const sessionID = resolveSessionID(properties);
          // No session ID we can resolve — discard rather than risk
          // corrupting an unrelated pane's row with a guessed ID.
          if (!sessionID) return;

          if (event.type === "session.created") {
            const parentID = properties.info && properties.info.parentID;
            if (parentID) {
              childSessions.add(sessionID);
              await postEvent(JSON.stringify({
                hook_event_name: "SubagentStart",
                agent_id: sessionID,
                cwd: directory,
              }));
              return;
            }
          }

          if (event.type === "permission.asked") {
            pendingPermissions.add(sessionID);
          } else if (event.type === "permission.replied") {
            pendingPermissions.delete(sessionID);
          } else if (event.type === "session.deleted") {
            pendingPermissions.delete(sessionID);
          } else if (event.type === "session.idle" && pendingPermissions.has(sessionID)) {
            return;
          }

          if (childSessions.has(sessionID)) {
            if (event.type === "session.deleted" || event.type === "session.idle") {
              childSessions.delete(sessionID);
              pendingPermissions.delete(sessionID);
              await postEvent(JSON.stringify({
                hook_event_name: "SubagentStop",
                agent_id: sessionID,
                cwd: directory,
              }));
              return;
            }
            await postEvent(JSON.stringify({
              hook_event_name: hookEventName,
              agent_id: sessionID,
              cwd: directory,
            }));
            return;
          }

          await postEvent(JSON.stringify({
            hook_event_name: hookEventName,
            session_id: sessionID,
            cwd: directory,
          }));
        },
      };
    };
    """

    // MARK: - Public API

    /// Installs the plugin into `<pluginsDirectory>/plugins/`, creating
    /// that directory if needed, and returns its absolute path. Overwrites
    /// any existing file at that path — reinstalling is idempotent since
    /// `scriptBody` is a fixed constant, not something merged with prior
    /// content. A symlink at the destination path (a dotfiles-managed
    /// OpenCode config root can legitimately symlink `plugins/` or the
    /// plugin file itself elsewhere) is followed to its real file
    /// (`ConfigFileUtils.resolveConfigPath`) and overwritten in place,
    /// leaving the symlink itself intact. `AgentHooksCoordinator.installOpenCode`
    /// already gates this call on the OpenCode config root existing, so
    /// this function does not repeat that check.
    static func install(pluginsDirectory: String? = nil) throws -> String {
        let scriptPath = pluginPath(pluginsDirectory: pluginsDirectory)
        let pluginsDir = (scriptPath as NSString).deletingLastPathComponent

        let fm = FileManager.default
        if !fm.fileExists(atPath: pluginsDir) {
            try fm.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        }

        let data = Data(scriptBody.utf8)
        // 0600: Calyx owns this file outright.
        try ConfigFileUtils.withExclusiveConfig(path: scriptPath, mode: 0o600, restoreModeOnNoWrite: true) { _ in data }
        return scriptPath
    }

    /// Deletes the plugin file. A no-op when nothing is installed; throws
    /// if the file exists but couldn't be removed (e.g. a permissions
    /// error), rather than silently leaving it in place. Symmetric with
    /// `install`: resolves a symlinked destination path and removes the
    /// real target file, leaving the symlink itself intact (now
    /// dangling) — removing the raw `path` instead would delete the
    /// symlink and leave the real installed file behind un-removed.
    static func remove(pluginsDirectory: String? = nil) throws {
        let path = pluginPath(pluginsDirectory: pluginsDirectory)
        try ConfigFileUtils.withExclusiveConfig(path: path) { _ in nil }
    }

    static func isInstalled(pluginsDirectory: String? = nil) -> Bool {
        FileManager.default.fileExists(atPath: pluginPath(pluginsDirectory: pluginsDirectory))
    }

    // MARK: - Private

    /// `<pluginsDirectory>/plugins/calyx-agent-monitor.js`.
    /// `pluginsDirectory` is the OpenCode config root
    /// (`~/.config/opencode` by default) — not the `plugins/` directory
    /// itself — matching `IPCConfigManager`'s directory-existence check
    /// for the same root.
    private static func pluginPath(pluginsDirectory: String?) -> String {
        let root = pluginsDirectory ?? defaultConfigDirectory
        let pluginsDir = (root as NSString).appendingPathComponent("plugins")
        return (pluginsDir as NSString).appendingPathComponent(fileName)
    }

    private static var defaultConfigDirectory: String {
        AgentToolPaths.openCodeConfigDirectory
    }
}
