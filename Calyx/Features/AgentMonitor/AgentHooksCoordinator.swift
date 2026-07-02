// AgentHooksCoordinator.swift
// Calyx
//
// Coordinates installing/removing calyx-agent-hook plus each agent CLI's
// own hook/plugin wiring (Claude Code's hooks.json, Codex's config.toml
// managed block, OpenCode's plugin file) across the three tools Phase 2
// supports, collecting results independently so one tool's failure does
// not block the others. Mirrors IPCConfigManager's shape (ConfigStatus per
// tool, directory-existence-based skip).

import Foundation

// MARK: - AgentHooksResult

struct AgentHooksResult: Sendable {
    let claudeCode: ConfigStatus
    let codex: ConfigStatus
    let openCode: ConfigStatus
}

// MARK: - AgentHooksCoordinator

struct AgentHooksCoordinator: Sendable {

    // MARK: - Public API

    /// Installs `calyx-agent-hook` once, then wires each tool's own
    /// hook/plugin configuration to invoke it (Claude Code, Codex) or to
    /// POST directly (OpenCode). A `calyx-agent-hook` install failure only
    /// marks Claude Code / Codex `.failed` when that tool is actually
    /// installed (its config directory exists) — an uninstalled tool
    /// reports `.skipped` exactly as it would have regardless of the
    /// script error, rather than a misleading `.failed`. Does not block
    /// OpenCode, whose plugin talks to the IPC endpoint over `fetch`
    /// rather than through the shared shell script.
    static func install() -> AgentHooksResult {
        let scriptPath: String
        do {
            scriptPath = try AgentHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
        } catch {
            return AgentHooksResult(
                claudeCode: scriptFailureStatus(error, directory: AgentToolPaths.claudeConfigDirectory),
                codex: scriptFailureStatus(error, directory: AgentToolPaths.codexConfigDirectory),
                openCode: installOpenCode()
            )
        }

        return AgentHooksResult(
            claudeCode: installClaudeCode(scriptPath: scriptPath),
            codex: installCodex(scriptPath: scriptPath),
            openCode: installOpenCode()
        )
    }

    /// Removes each tool's hook/plugin configuration. Each tool is
    /// `.skipped` up front when it isn't installed at all, rather than
    /// running its (no-op-when-absent) removal and reporting a
    /// misleadingly generic `.success`.
    static func remove() -> AgentHooksResult {
        AgentHooksResult(
            claudeCode: removeClaudeCode(),
            codex: removeCodex(),
            openCode: removeOpenCode()
        )
    }

    // MARK: - Private: Claude Code

    private static func installClaudeCode(scriptPath: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.claudeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath)
        }
    }

    private static func removeClaudeCode() -> ConfigStatus {
        // Unlike installClaudeCode's directory-existence guard ("is the
        // tool present"), removal must check whether Calyx's own hooks are
        // actually installed — the tool itself being present says nothing
        // about that, and removeHooks() is a silent no-op either way, so a
        // directory-existence guard here would report a misleading
        // `.success` ("removed") when nothing was ever installed.
        guard ClaudeHooksConfigManager.areHooksInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try ClaudeHooksConfigManager.removeHooks()
        }
    }

    // MARK: - Private: Codex

    private static func installCodex(scriptPath: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.codexConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try CodexHooksConfigManager.installHooks(scriptPath: scriptPath)
        }
    }

    private static func removeCodex() -> ConfigStatus {
        // See removeClaudeCode's comment: removal must check whether
        // Calyx's managed block is actually installed, not just whether
        // ~/.codex exists.
        guard CodexHooksConfigManager.areHooksInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try CodexHooksConfigManager.removeHooks()
        }
    }

    // MARK: - Private: OpenCode

    private static func installOpenCode() -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.openCodeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            _ = try OpenCodePluginManager.install()
        }
    }

    private static func removeOpenCode() -> ConfigStatus {
        guard OpenCodePluginManager.isInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try OpenCodePluginManager.remove()
        }
    }

    // MARK: - Private: Helpers

    /// Runs `body`, mapping a thrown error to `.failed` and a clean return
    /// to `.success`. Shared by every install/remove path above so the
    /// `do { try ... ; return .success } catch { return .failed(error) }`
    /// boilerplate exists in exactly one place.
    private static func captureStatus(_ body: () throws -> Void) -> ConfigStatus {
        do {
            try body()
            return .success
        } catch {
            return .failed(error)
        }
    }

    /// Status for Claude Code / Codex when the shared `calyx-agent-hook`
    /// script itself failed to install: `.skipped` if the tool isn't even
    /// installed (its config directory is absent — it would have been
    /// skipped regardless of the script error), `.failed(error)` only when
    /// the tool is installed and would otherwise have been wired up.
    private static func scriptFailureStatus(_ error: Error, directory: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: directory) else {
            return .skipped(reason: "not installed")
        }
        return .failed(error)
    }
}
