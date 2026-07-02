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
      // `opencode`) — register no hooks at all, mirroring
      // calyx-agent-hook's CALYX_SURFACE_ID guard.
      if (!process.env.CALYX_SURFACE_ID) {
        return {};
      }

      // session.created's info.parentID marks a subagent's own child
      // session. Once seen, every later event for that session ID is
      // ignored too, so a subagent run never steals its parent pane's row.
      // Entries are removed on the child session's own session.deleted so
      // this set doesn't grow without bound over a long-lived process.
      const childSessions = new Set();

      // Session IDs with a permission.asked that hasn't yet seen its
      // permission.replied. Suppresses session.idle -> Stop for a pending
      // session so a Stop racing ahead of the reply can't overwrite the
      // blocked row with idle while the prompt is still awaiting a reply.
      // Also cleared on the session's own session.deleted (mirroring
      // childSessions' cleanup above), so a session that ends with an
      // outstanding, never-answered prompt doesn't leak an entry here for
      // the lifetime of the plugin process.
      const pendingPermissions = new Set();

      let cachedEndpoint = null;
      let cachedEndpointMtimeMs = null;

      async function loadEndpoint() {
        const endpointPath =
          `${process.env.HOME}/Library/Application Support/Calyx/agent-endpoint.json`;
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
              return;
            }
          }
          if (childSessions.has(sessionID)) {
            if (event.type === "session.deleted") {
              childSessions.delete(sessionID);
            }
            return;
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

          try {
            const endpoint = await loadEndpoint();

            await fetch(`http://127.0.0.1:${endpoint.port}/agent-event`, {
              method: "POST",
              headers: {
                "Authorization": `Bearer ${endpoint.token}`,
                "X-Calyx-Surface-ID": process.env.CALYX_SURFACE_ID,
                "X-Calyx-Agent-Kind": "opencode",
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                hook_event_name: hookEventName,
                session_id: sessionID,
                cwd: directory,
              }),
              signal: AbortSignal.timeout(2000),
            });
          } catch {
            // Server unreachable, agent-endpoint.json missing/malformed,
            // request timeout, etc. — never let a failed POST affect
            // OpenCode itself.
          }
        },
      };
    };
    """

    // MARK: - Public API

    /// Installs the plugin into `<pluginsDirectory>/plugins/`, creating
    /// that directory if needed, and returns its absolute path. Overwrites
    /// any existing file at that path — reinstalling is idempotent since
    /// `scriptBody` is a fixed constant, not something merged with prior
    /// content.
    static func install(pluginsDirectory: String? = nil) throws -> String {
        let scriptPath = pluginPath(pluginsDirectory: pluginsDirectory)
        let pluginsDir = (scriptPath as NSString).deletingLastPathComponent

        let fm = FileManager.default
        if !fm.fileExists(atPath: pluginsDir) {
            try fm.createDirectory(atPath: pluginsDir, withIntermediateDirectories: true)
        }

        guard !ConfigFileUtils.isSymlink(at: scriptPath) else {
            throw ConfigFileError.symlinkDetected
        }

        try scriptBody.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        return scriptPath
    }

    /// Deletes the plugin file. A no-op when nothing is installed; throws
    /// if the file exists but couldn't be removed (e.g. a permissions
    /// error), rather than silently leaving it in place.
    static func remove(pluginsDirectory: String? = nil) throws {
        let path = pluginPath(pluginsDirectory: pluginsDirectory)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try FileManager.default.removeItem(atPath: path)
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
