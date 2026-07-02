// AgentToolPaths.swift
// Calyx
//
// Centralizes the on-disk config-root directory for each agent CLI Phase 2
// wires up, so `AgentHooksCoordinator`, `OpenCodePluginManager`,
// `CodexHooksConfigManager`, `IPCConfigManager`, and `OpenCodeConfigManager`
// all derive the same path from exactly one place rather than re-deriving
// `NSHomeDirectory() + "/..."` independently.

import Foundation

enum AgentToolPaths {

    /// Claude Code's config root: `~/.claude`.
    static var claudeConfigDirectory: String {
        NSHomeDirectory() + "/.claude"
    }

    /// Codex's config root: `~/.codex`.
    static var codexConfigDirectory: String {
        NSHomeDirectory() + "/.codex"
    }

    /// OpenCode's config root: `~/.config/opencode`.
    static var openCodeConfigDirectory: String {
        NSHomeDirectory() + "/.config/opencode"
    }
}
