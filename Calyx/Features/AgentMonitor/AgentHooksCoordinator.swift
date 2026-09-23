// AgentHooksCoordinator.swift
// Calyx
//
// Coordinates installing/removing calyx-agent-hook plus each agent CLI's
// own hook/plugin wiring (Claude Code's hooks.json, Codex's config.toml
// managed block, OpenCode's plugin file, Grok's own hook file under
// ~/.grok/hooks, pi's extension file under ~/.pi/agent/extensions) across
// the tools Calyx supports, collecting results independently so one
// tool's failure does not block the others. Mirrors IPCConfigManager's
// shape (ConfigStatus per tool, directory-existence-based skip).

import Foundation

// MARK: - AgentHooksResult

struct AgentHooksResult: Sendable {
    let claudeCode: ConfigStatus
    let codex: ConfigStatus
    let openCode: ConfigStatus
    let grok: ConfigStatus
    /// pi's axis. pi has no MCP client configuration file at all, so
    /// unlike the other tools it reaches Calyx through this one axis
    /// only: `PiExtensionManager`'s extension file is the entire
    /// integration, and `IPCConfigResult` has no pi counterpart.
    let pi: ConfigStatus

    /// Every axis paired with the label rendered for it, in print order.
    /// `anySucceeded` and `issueMessages` both derive from this, and so
    /// does `AgentIPCRowResolver`'s rendering of this result -- a newly
    /// supported agent CLI is added here once, not separately in each of
    /// those.
    var axes: [(name: String, status: ConfigStatus)] {
        [
            ("Claude Code hooks", claudeCode),
            ("Codex hooks", codex),
            ("OpenCode plugin", openCode),
            ("Grok hooks", grok),
            ("pi extension", pi),
        ]
    }

    /// One `"<name>: <localizedDescription>"` line per `.failed` tool,
    /// for `AgentRegistry.hooksIssues`'s persistent sidebar banner. `[]`
    /// when every tool installed successfully (or was skipped) --
    /// `AgentStatusView` only renders the banner when
    /// `AgentRegistry.integrationIssues` is non-empty. Shared by every
    /// `AgentHooksCoordinator.install()`/`.remove()`/`.resyncInstalled()`
    /// caller that feeds `AgentRegistry.shared.setHooksIssues(_:)`
    /// (`IPCActivationCoordinator` and `AppDelegate`'s own launch-time
    /// re-sync), rather than each recomputing it.
    var issueMessages: [String] {
        axes.compactMap { name, status in
            guard case .failed(let error) = status else { return nil }
            return "\(name): \(error.localizedDescription)"
        }
    }

    /// True when at least one of the five axes, pi included, is
    /// `.success`. pi has no `IPCConfigResult` counterpart, so this is
    /// the only signal that a pi-only machine counts as wired.
    var anySucceeded: Bool {
        for axis in axes {
            if case .success = axis.status { return true }
        }
        return false
    }
}

// MARK: - AgentHooksCoordinator

struct AgentHooksCoordinator: Sendable {

    // MARK: - Public API

    /// Installs `calyx-agent-hook` and `calyx-approval-hook` once, then
    /// wires each tool's own hook/plugin configuration to invoke them
    /// (Claude Code, Codex, Grok) or to POST directly (OpenCode, pi).
    /// Either script's install failure only marks Claude Code / Codex /
    /// Grok `.failed` when that tool is actually installed (its config
    /// directory exists): an uninstalled tool reports `.skipped` exactly
    /// as it would have regardless of the script error, rather than a
    /// misleading `.failed`. Does not block OpenCode or pi, whose plugin
    /// and extension talk to the IPC endpoint over `fetch` rather than
    /// through the shared shell scripts.
    static func install() -> AgentHooksResult {
        let scriptPath: String
        let approvalScriptPath: String
        do {
            scriptPath = try AgentHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
            approvalScriptPath = try ApprovalHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
        } catch {
            return AgentHooksResult(
                claudeCode: scriptFailureStatus(error, directory: AgentToolPaths.claudeConfigDirectory),
                codex: scriptFailureStatus(error, directory: AgentToolPaths.codexConfigDirectory),
                openCode: installOpenCode(),
                grok: scriptFailureStatus(error, directory: AgentToolPaths.grokConfigDirectory),
                pi: installPi()
            )
        }

        return AgentHooksResult(
            claudeCode: installClaudeCode(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath),
            codex: installCodex(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath),
            openCode: installOpenCode(),
            grok: installGrok(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath),
            pi: installPi()
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
            openCode: removeOpenCode(),
            grok: removeGrok(),
            pi: removePi()
        )
    }

    /// Re-installs each tool's hook/plugin configuration, but ONLY for a
    /// tool that already has Calyx's own hooks/plugin installed --
    /// `install()`'s counterpart for an unattended launch-time resync,
    /// where wiring up a tool the user never opted into (`install()`'s
    /// own directory-existence-only gate) would be silent, unrequested
    /// scope creep: enabling IPC for one CLI must never spread Calyx's
    /// hooks to a second CLI the user only installed afterward, and a
    /// user who removed Calyx's entries from one tool by hand must never
    /// have them silently reinstated by the next launch. Each tool is
    /// independently checked (`areHooksInstalled`/`isInstalled`) and
    /// `.skipped` when it isn't already present, exactly like `remove()`
    /// above.
    ///
    /// When none of the tools already have Calyx's hooks, returns
    /// every tool `.skipped` WITHOUT installing the shared
    /// `calyx-agent-hook`/`calyx-approval-hook` scripts at all -- a user
    /// who has never opted into IPC for any tool must never get hook
    /// files written to disk on their behalf just from this running.
    static func resyncInstalled() -> AgentHooksResult {
        let claudeInstalled = ClaudeHooksConfigManager.areHooksInstalled()
        let codexInstalled = CodexHooksConfigManager.areHooksInstalled()
        let openCodeInstalled = OpenCodePluginManager.isInstalled()
        let grokInstalled = GrokHooksConfigManager.areHooksInstalled()
        let piInstalled = PiExtensionManager.isInstalled()

        guard claudeInstalled || codexInstalled || openCodeInstalled || grokInstalled || piInstalled else {
            let skipped = ConfigStatus.skipped(reason: "not installed")
            return AgentHooksResult(
                claudeCode: skipped, codex: skipped, openCode: skipped, grok: skipped, pi: skipped
            )
        }

        let scriptPath: String
        let approvalScriptPath: String
        do {
            scriptPath = try AgentHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
            approvalScriptPath = try ApprovalHookScript.install(toDirectory: AgentHookScript.defaultInstallDirectory)
        } catch {
            return AgentHooksResult(
                claudeCode: resyncScriptFailureStatus(error, alreadyInstalled: claudeInstalled),
                codex: resyncScriptFailureStatus(error, alreadyInstalled: codexInstalled),
                openCode: resyncOpenCode(alreadyInstalled: openCodeInstalled),
                grok: resyncScriptFailureStatus(error, alreadyInstalled: grokInstalled),
                pi: resyncPi(alreadyInstalled: piInstalled)
            )
        }

        return AgentHooksResult(
            claudeCode: resyncClaudeCode(
                alreadyInstalled: claudeInstalled, scriptPath: scriptPath, approvalScriptPath: approvalScriptPath
            ),
            codex: resyncCodex(
                alreadyInstalled: codexInstalled, scriptPath: scriptPath, approvalScriptPath: approvalScriptPath
            ),
            openCode: resyncOpenCode(alreadyInstalled: openCodeInstalled),
            grok: resyncGrok(
                alreadyInstalled: grokInstalled, scriptPath: scriptPath, approvalScriptPath: approvalScriptPath
            ),
            pi: resyncPi(alreadyInstalled: piInstalled)
        )
    }

    // MARK: - Private: Claude Code

    private static func installClaudeCode(scriptPath: String, approvalScriptPath: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.claudeConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
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

    /// `resyncInstalled()`'s Claude Code leg: `alreadyInstalled` is
    /// `resyncInstalled()`'s own pre-captured `areHooksInstalled()`
    /// snapshot, not re-queried here, so it stays consistent with the
    /// value that decided whether the shared scripts were installed at
    /// all.
    private static func resyncClaudeCode(
        alreadyInstalled: Bool, scriptPath: String, approvalScriptPath: String
    ) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try ClaudeHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
        }
    }

    // MARK: - Private: Codex

    private static func installCodex(scriptPath: String, approvalScriptPath: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.codexConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
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

    /// `resyncInstalled()`'s Codex leg -- see `resyncClaudeCode`'s own
    /// doc comment for why `alreadyInstalled` is a pre-captured snapshot
    /// rather than a fresh `areHooksInstalled()` call.
    private static func resyncCodex(
        alreadyInstalled: Bool, scriptPath: String, approvalScriptPath: String
    ) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try CodexHooksConfigManager.installHooks(scriptPath: scriptPath, approvalScriptPath: approvalScriptPath)
        }
    }

    // MARK: - Private: Grok

    private static func installGrok(scriptPath: String, approvalScriptPath: String) -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.grokConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try GrokHooksConfigManager.installHooks(
                scriptPath: scriptPath, approvalScriptPath: approvalScriptPath
            )
        }
    }

    private static func removeGrok() -> ConfigStatus {
        // See removeClaudeCode's comment: removal must check whether
        // Calyx's own hook file is actually installed, not just whether
        // ~/.grok exists.
        guard GrokHooksConfigManager.areHooksInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try GrokHooksConfigManager.removeHooks()
        }
    }

    /// `resyncInstalled()`'s Grok leg -- see `resyncClaudeCode`'s own doc
    /// comment for why `alreadyInstalled` is a pre-captured snapshot
    /// rather than a fresh `areHooksInstalled()` call.
    private static func resyncGrok(
        alreadyInstalled: Bool, scriptPath: String, approvalScriptPath: String
    ) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try GrokHooksConfigManager.installHooks(
                scriptPath: scriptPath, approvalScriptPath: approvalScriptPath
            )
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

    /// `resyncInstalled()`'s OpenCode leg -- see `resyncClaudeCode`'s own
    /// doc comment for why `alreadyInstalled` is a pre-captured snapshot
    /// rather than a fresh `isInstalled()` call. Runs independently of
    /// whether the shared `calyx-agent-hook` scripts installed cleanly:
    /// OpenCode's plugin POSTs to the IPC endpoint directly rather than
    /// through them (see `install()`'s own doc comment).
    private static func resyncOpenCode(alreadyInstalled: Bool) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            _ = try OpenCodePluginManager.install()
        }
    }

    // MARK: - Private: pi

    private static func installPi() -> ConfigStatus {
        guard ConfigFileUtils.directoryExists(at: AgentToolPaths.piConfigDirectory) else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            _ = try PiExtensionManager.install()
        }
    }

    private static func removePi() -> ConfigStatus {
        // See removeClaudeCode's comment: removal must check whether
        // Calyx's own extension file is actually installed, not just
        // whether ~/.pi/agent exists.
        guard PiExtensionManager.isInstalled() else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            try PiExtensionManager.remove()
        }
    }

    /// `resyncInstalled()`'s pi leg -- see `resyncClaudeCode`'s own doc
    /// comment for why `alreadyInstalled` is a pre-captured snapshot
    /// rather than a fresh `isInstalled()` call. Runs independently of
    /// whether the shared `calyx-agent-hook` scripts installed cleanly:
    /// pi's extension POSTs to the IPC endpoint directly rather than
    /// through them, exactly like OpenCode's plugin above.
    private static func resyncPi(alreadyInstalled: Bool) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return captureStatus {
            _ = try PiExtensionManager.install()
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

    /// Status for Claude Code / Codex / Grok when the shared `calyx-agent-hook`
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

    /// `resyncInstalled()`'s counterpart to `scriptFailureStatus` above:
    /// `.skipped` when this tool didn't already have Calyx's hooks (it
    /// would have stayed skipped regardless of the script error),
    /// `.failed(error)` only when it did and would otherwise have been
    /// refreshed.
    private static func resyncScriptFailureStatus(_ error: Error, alreadyInstalled: Bool) -> ConfigStatus {
        guard alreadyInstalled else {
            return .skipped(reason: "not installed")
        }
        return .failed(error)
    }
}
