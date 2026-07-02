// IPCConfigManager.swift
// Calyx
//
// Coordinates IPC config registration across Claude Code, Codex, OpenCode,
// and Hermes, collecting results independently so one failure does not block
// the others.

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

    var anySucceeded: Bool {
        if case .success = claudeCode { return true }
        if case .success = codex { return true }
        if case .success = openCode { return true }
        if case .success = hermes { return true }
        return false
    }
}

// MARK: - IPCConfigManager

struct IPCConfigManager: Sendable {

    // MARK: - Public API

    /// Enables IPC MCP server config in Claude Code, Codex, OpenCode, and Hermes config files.
    /// Each tool is handled independently — one failing does not prevent the others.
    static func enableIPC(port: Int, token: String) -> IPCConfigResult {
        let claudeCode = enableClaudeCode(port: port, token: token)
        let codex = enableCodex(port: port, token: token)
        let openCode = enableOpenCode(port: port, token: token)
        let hermes = enableHermes(port: port, token: token)
        return IPCConfigResult(
            claudeCode: claudeCode,
            codex: codex,
            openCode: openCode,
            hermes: hermes
        )
    }

    /// Disables IPC MCP server config in Claude Code, Codex, OpenCode, and Hermes config files.
    /// Does not check directory existence — the individual managers handle missing files as no-ops.
    static func disableIPC() -> IPCConfigResult {
        let claudeCode = disableClaudeCode()
        let codex = disableCodex()
        let openCode = disableOpenCode()
        let hermes = disableHermes()
        return IPCConfigResult(
            claudeCode: claudeCode,
            codex: codex,
            openCode: openCode,
            hermes: hermes
        )
    }

    /// Returns whether IPC is currently enabled in each tool's config.
    static func isIPCEnabled() -> (claudeCode: Bool, codex: Bool, openCode: Bool, hermes: Bool) {
        (
            claudeCode: ClaudeConfigManager.isIPCEnabled(),
            codex: CodexConfigManager.isIPCEnabled(),
            openCode: OpenCodeConfigManager.isIPCEnabled(),
            hermes: HermesConfigManager.isIPCEnabled()
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
        let hermesDir = NSHomeDirectory() + "/.hermes/"
        guard ConfigFileUtils.directoryExists(at: hermesDir) else {
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
}
