// IPCConfigManager.swift
// Calyx
//
// Coordinates IPC config registration across Claude Code, Codex, OpenCode,
// Hermes, and Grok, collecting results independently so one failure does not
// block the others.

import Foundation

// MARK: - ConfigStatus

enum ConfigStatus: Sendable {
    case success
    case skipped(reason: String)
    case failed(Error)
}

// MARK: - IPCConfigResult

struct IPCConfigResult: Sendable {
    let claudeCode: ConfigStatus
    let codex: ConfigStatus
    let openCode: ConfigStatus
    let hermes: ConfigStatus
    let grok: ConfigStatus

    /// Every axis paired with the label rendered for it, in print order.
    /// `anySucceeded` and `issueMessages` both derive from this, and so
    /// does `AgentIPCRowResolver`'s rendering of this result -- a newly
    /// supported agent CLI is added here once, not separately in each of
    /// those.
    var axes: [(name: String, status: ConfigStatus)] {
        [
            ("Claude Code config", claudeCode),
            ("Codex config", codex),
            ("OpenCode config", openCode),
            ("Hermes config", hermes),
            ("Grok config", grok),
        ]
    }

    var anySucceeded: Bool {
        for axis in axes {
            if case .success = axis.status { return true }
        }
        return false
    }

    /// One `"<name>: <localizedDescription>"` line per `.failed` axis.
    /// `[]` when no axis failed. Mirrors `AgentHooksResult.issueMessages`.
    var issueMessages: [String] {
        axes.compactMap { name, status in
            guard case .failed(let error) = status else { return nil }
            return "\(name): \(error.localizedDescription)"
        }
    }
}

// MARK: - IPCConfigManager

struct IPCConfigManager: Sendable {

    // MARK: - Public API

    /// Enables IPC MCP server config in Claude Code, Codex, OpenCode, Hermes, and Grok config files.
    /// Each tool is handled independently — one failing does not prevent the others.
    static func enableIPC(port: Int, token: String) -> IPCConfigResult {
        let claudeCode = enableClaudeCode(port: port, token: token)
        let codex = enableCodex(port: port, token: token)
        let openCode = enableOpenCode(port: port, token: token)
        let hermes = enableHermes(port: port, token: token)
        let grok = enableGrok(port: port, token: token)
        return IPCConfigResult(
            claudeCode: claudeCode,
            codex: codex,
            openCode: openCode,
            hermes: hermes,
            grok: grok
        )
    }

    /// Disables IPC MCP server config in Claude Code, Codex, OpenCode, Hermes, and Grok config files.
    /// Does not check directory existence — the individual managers handle missing files as no-ops.
    static func disableIPC() -> IPCConfigResult {
        let claudeCode = disableClaudeCode()
        let codex = disableCodex()
        let openCode = disableOpenCode()
        let hermes = disableHermes()
        let grok = disableGrok()
        return IPCConfigResult(
            claudeCode: claudeCode,
            codex: codex,
            openCode: openCode,
            hermes: hermes,
            grok: grok
        )
    }

    /// Returns whether IPC is currently enabled in each tool's config.
    static func isIPCEnabled() -> (claudeCode: Bool, codex: Bool, openCode: Bool, hermes: Bool, grok: Bool) {
        (
            claudeCode: ClaudeConfigManager.isIPCEnabled(),
            codex: CodexConfigManager.isIPCEnabled(),
            openCode: OpenCodeConfigManager.isIPCEnabled(),
            hermes: HermesConfigManager.isIPCEnabled(),
            grok: GrokConfigManager.isIPCEnabled()
        )
    }

    // MARK: - Private: Claude Code

    private static func enableClaudeCode(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.claudeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try ClaudeConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableClaudeCode() -> ConfigStatus {
        do {
            try ClaudeConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Codex

    private static func enableCodex(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.codexConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try CodexConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableCodex() -> ConfigStatus {
        do {
            try CodexConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: OpenCode

    private static func enableOpenCode(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.openCodeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try OpenCodeConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableOpenCode() -> ConfigStatus {
        do {
            try OpenCodeConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Hermes

    private static func enableHermes(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.hermesConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try HermesConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableHermes() -> ConfigStatus {
        do {
            try HermesConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }

    // MARK: - Private: Grok

    private static func enableGrok(port: Int, token: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.grokConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        do {
            try GrokConfigManager.enableIPC(port: port, token: token)
            return .success
        } catch {
            return .failed(error)
        }
    }

    private static func disableGrok() -> ConfigStatus {
        do {
            try GrokConfigManager.disableIPC()
            return .success
        } catch {
            return .failed(error)
        }
    }
}
