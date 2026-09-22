// AgentToolPaths.swift
// Calyx
//
// Centralizes the on-disk config-root directory and file paths for every
// agent CLI Calyx integrates with, so no manager derives
// `NSHomeDirectory() + "/..."` independently. Every property resolves
// beneath `CalyxPathRoot.testRoot` when it is non-nil (a UI test scoped
// by `--calyx-path-root=` or a unit test host), otherwise beneath
// `NSHomeDirectory()` exactly as production always has.

import Foundation

enum AgentToolPaths {

    /// The directory every path below is resolved relative to:
    /// `testRoot` when given, else the real home directory.
    static func homeRoot(testRoot: String?) -> String {
        testRoot ?? NSHomeDirectory()
    }

    private static var homeRoot: String {
        homeRoot(testRoot: CalyxPathRoot.testRoot)
    }

    // MARK: - Claude Code

    /// Claude Code's config root: `~/.claude`.
    static func claudeConfigDirectory(testRoot: String?) -> String {
        homeRoot(testRoot: testRoot) + "/.claude"
    }

    static var claudeConfigDirectory: String {
        claudeConfigDirectory(testRoot: CalyxPathRoot.testRoot)
    }

    /// Claude Code's top-level MCP client config: `~/.claude.json`. Sits
    /// directly under the home root, NOT under `claudeConfigDirectory`.
    static func claudeConfigPath(testRoot: String?) -> String {
        homeRoot(testRoot: testRoot) + "/.claude.json"
    }

    static var claudeConfigPath: String {
        claudeConfigPath(testRoot: CalyxPathRoot.testRoot)
    }

    /// Claude Code's hook settings: `~/.claude/settings.json`.
    static func claudeSettingsPath(testRoot: String?) -> String {
        claudeConfigDirectory(testRoot: testRoot) + "/settings.json"
    }

    static var claudeSettingsPath: String {
        claudeSettingsPath(testRoot: CalyxPathRoot.testRoot)
    }

    // MARK: - Codex

    /// Codex's config root: `~/.codex`.
    static func codexConfigDirectory(testRoot: String?) -> String {
        homeRoot(testRoot: testRoot) + "/.codex"
    }

    static var codexConfigDirectory: String {
        codexConfigDirectory(testRoot: CalyxPathRoot.testRoot)
    }

    // MARK: - OpenCode

    /// OpenCode's config root: `~/.config/opencode`.
    static func openCodeConfigDirectory(testRoot: String?) -> String {
        homeRoot(testRoot: testRoot) + "/.config/opencode"
    }

    static var openCodeConfigDirectory: String {
        openCodeConfigDirectory(testRoot: CalyxPathRoot.testRoot)
    }

    // MARK: - Grok

    /// Grok's config root: `~/.grok`. Holds both `config.toml`
    /// (`GrokConfigManager`'s `[mcp_servers.calyx-ipc]` entry) and
    /// `hooks/calyx.json` (`GrokHooksConfigManager`'s Calyx-owned hook
    /// file).
    static func grokConfigDirectory(testRoot: String?) -> String {
        homeRoot(testRoot: testRoot) + "/.grok"
    }

    static var grokConfigDirectory: String {
        grokConfigDirectory(testRoot: CalyxPathRoot.testRoot)
    }

    // MARK: - pi

    /// pi's agent root: `~/.pi/agent`, the directory holding the
    /// `extensions/` folder `PiExtensionManager` writes into. The path
    /// reaches down to `agent` rather than stopping at `~/.pi` so an
    /// unrelated `~/.pi` directory cannot be read as an installed pi.
    static func piConfigDirectory(testRoot: String?) -> String {
        homeRoot(testRoot: testRoot) + "/.pi/agent"
    }

    static var piConfigDirectory: String {
        piConfigDirectory(testRoot: CalyxPathRoot.testRoot)
    }

    // MARK: - Hermes

    /// Hermes's config root: `~/.hermes`.
    static func hermesConfigDirectory(testRoot: String?) -> String {
        homeRoot(testRoot: testRoot) + "/.hermes"
    }

    static var hermesConfigDirectory: String {
        hermesConfigDirectory(testRoot: CalyxPathRoot.testRoot)
    }

    /// Hermes's MCP client config: `~/.hermes/config.yaml`.
    static func hermesConfigPath(testRoot: String?) -> String {
        hermesConfigDirectory(testRoot: testRoot) + "/config.yaml"
    }

    static var hermesConfigPath: String {
        hermesConfigPath(testRoot: CalyxPathRoot.testRoot)
    }
}
