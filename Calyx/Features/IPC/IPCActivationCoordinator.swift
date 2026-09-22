// IPCActivationCoordinator.swift
// Calyx
//
// Owns the exact sequencing behind the Settings > Agents IPC toggle:
// resolve the MCP endpoint, write agent CLI config files,
// install agent hooks/plugins/extensions, then report integration
// issues. Every dependency is expressed as a protocol so the sequencing
// itself is testable without a real file system, a real CalyxMCPServer,
// or any networking.
//
// enable()/disable() are both async and run through
// `IPCActivationChain.shared`, which serializes every activation end to
// end across both production call sites (the Settings toggle and launch-
// time auto-activation) so a rapid enable-then-disable cannot land its
// file writes out of order, and records each outcome as the chain's own
// `lastReport` before the chain's in-flight flag drops. The config/hooks
// I/O inside each call hops off `@MainActor` (`IPCConfigManager` and
// `AgentHooksCoordinator` are synchronous I/O behind an untimed
// `flock`), but stays inside the chain's queued work so ordering and the
// in-flight flag are unaffected.

import Foundation
import Security

// MARK: - Seams

/// The running MCP server's control surface, as this coordinator needs
/// it. `port`/`token` are only meaningful once `isRunning` is true.
@MainActor
protocol IPCServerControlling {
    var isRunning: Bool { get }
    var port: Int { get }
    var token: String { get }
    func start(token: String) async throws
    func stop()
}

/// Writes or removes the calyx-ipc entry in every supported agent CLI's
/// MCP client configuration file.
protocol IPCAgentConfigInstalling: Sendable {
    func enableIPC(port: Int, token: String) -> IPCConfigResult
    func disableIPC() -> IPCConfigResult
}

/// Installs or removes the calyx-agent-hook script plus each agent
/// CLI's own hook/plugin/extension wiring to it.
protocol IPCAgentHooksInstalling: Sendable {
    func install() -> AgentHooksResult
    func remove() -> AgentHooksResult
}

/// Produces the bearer token a freshly started server authenticates
/// with.
protocol IPCTokenGenerating: Sendable {
    func makeToken() throws -> String
}

/// Publishes the current set of agent integration failures to the
/// standing sidebar banner, config and hooks domains reported through
/// separate methods so one domain's write can never overwrite the
/// other's. `AgentRegistry` itself keeps the two domains as separate
/// stored properties for the same reason, since `AppDelegate`'s
/// launch-time hooks re-sync writes the hooks domain directly rather
/// than through this coordinator or this protocol.
@MainActor
protocol IPCIntegrationIssueReporting {
    func reportConfigIssues(_ issues: [String])
    func reportHooksIssues(_ issues: [String])

    /// Publishes the reason a server-start attempt failed (token
    /// generation or `CalyxMCPServer.start` itself) to the sidebar's own
    /// failure domain, or `[]` on a successful `enable()`/`disable()`.
    /// A third, separate domain from config/hooks: a server-start
    /// failure happens before either of those steps runs, so there is
    /// nothing to report through them yet.
    func reportServerIssues(_ issues: [String])
}

// MARK: - Reports

/// The outcome of a successful `enable()` call: the server is up
/// (freshly started or already running) and every independent
/// integration step has run exactly once.
struct IPCActivationReport: Sendable {
    let port: Int
    let wasAlreadyRunning: Bool
    let config: IPCConfigResult
    let hooks: AgentHooksResult

    /// True when at least one agent CLI is reachable through either its
    /// config file or its hooks/plugin/extension axis. pi has no config
    /// axis at all, so `hooks.anySucceeded` is its only signal here.
    var anyAgentWired: Bool { config.anySucceeded || hooks.anySucceeded }
}

enum IPCActivationOutcome: Sendable {
    case enabled(IPCActivationReport)
    case tokenGenerationFailed
    case serverStartFailed(Error)
}

struct IPCDeactivationReport: Sendable {
    let config: IPCConfigResult
    let hooks: AgentHooksResult
}

// MARK: - IPCActivationCoordinator

@MainActor
struct IPCActivationCoordinator {
    private let server: IPCServerControlling
    private let configInstaller: IPCAgentConfigInstalling
    private let hooksInstaller: IPCAgentHooksInstalling
    private let tokenGenerator: IPCTokenGenerating
    private let issueReporter: IPCIntegrationIssueReporting

    init(
        server: IPCServerControlling = LiveIPCServerControl(),
        configInstaller: IPCAgentConfigInstalling = LiveIPCAgentConfigInstaller(),
        hooksInstaller: IPCAgentHooksInstalling = LiveIPCAgentHooksInstaller(),
        tokenGenerator: IPCTokenGenerating = SecureRandomTokenGenerator(),
        issueReporter: IPCIntegrationIssueReporting = AgentRegistryIssueReporter()
    ) {
        self.server = server
        self.configInstaller = configInstaller
        self.hooksInstaller = hooksInstaller
        self.tokenGenerator = tokenGenerator
        self.issueReporter = issueReporter
    }

    /// Resolves the MCP endpoint, then always runs both the agent config
    /// write and the agent hooks install -- neither step is gated on the
    /// other's result, since pi's only integration path is the hooks
    /// install and it has no config axis at all. Never stops the server:
    /// `CalyxMCPServer` also serves the LSP proxy, cockpit tools,
    /// command-log tools and any hand-configured MCP client, none of
    /// which depend on an agent CLI config file. herdr panes reach Calyx
    /// over their own transport, independent of this server entirely.
    ///
    /// Runs through `IPCActivationChain.shared` so a rapid enable-then-
    /// disable (or the reverse) cannot land its file writes out of order
    /// against the other call. The chain itself records the returned
    /// outcome as `lastReport` before its in-flight flag drops.
    func enable() async -> IPCActivationOutcome {
        await IPCActivationChain.shared.runEnable { [self] in
            await enableLocked()
        }
    }

    private func enableLocked() async -> IPCActivationOutcome {
        let port: Int
        let token: String
        let wasAlreadyRunning: Bool

        if server.isRunning {
            // Reuse the live endpoint. CalyxMCPServer.start(token:)
            // stops a running server before starting a new one, which
            // deletes agent-endpoint.json, resets the Agents sidebar,
            // and expires pending approvals -- restarting here would do
            // that to every already-connected agent just to re-run
            // config/hooks install.
            port = server.port
            token = server.token
            wasAlreadyRunning = true
        } else {
            let generatedToken: String
            do {
                generatedToken = try tokenGenerator.makeToken()
            } catch {
                let outcome = IPCActivationOutcome.tokenGenerationFailed
                // Reuses the presenter's own message for this outcome
                // rather than a second copy of the string, so the
                // sidebar banner and the Settings/alert text can never
                // drift apart.
                issueReporter.reportServerIssues([IPCActivationPresenter.enableAlert(for: outcome).message])
                return outcome
            }
            do {
                try await server.start(token: generatedToken)
            } catch {
                let outcome = IPCActivationOutcome.serverStartFailed(error)
                issueReporter.reportServerIssues([IPCActivationPresenter.enableAlert(for: outcome).message])
                return outcome
            }
            // Read BOTH back after start() returns: the server resolves
            // its own token and its actual listening port during start,
            // not before -- LiveIPCServerControl.start(token:) may pass
            // a reused on-disk token/port rather than the freshly
            // generated one, and writing only one of the two back would
            // desync the server's own token from the CLI config's token.
            token = server.token
            port = server.port
            wasAlreadyRunning = false
        }

        let configInstaller = self.configInstaller
        let hooksInstaller = self.hooksInstaller
        let config = await Self.offMainActor { configInstaller.enableIPC(port: port, token: token) }
        let hooks = await Self.offMainActor { hooksInstaller.install() }
        issueReporter.reportConfigIssues(config.issueMessages)
        issueReporter.reportHooksIssues(hooks.issueMessages)
        // Clears any server-start failure banner left standing from an
        // earlier attempt: the server is up now, by definition, past
        // this point.
        issueReporter.reportServerIssues([])

        return .enabled(IPCActivationReport(port: port, wasAlreadyRunning: wasAlreadyRunning, config: config, hooks: hooks))
    }

    /// Stops the server (this type's only stop call site), then removes
    /// the agent config entries and agent hooks independently of each
    /// other. Removal failures are surfaced only in the returned report,
    /// not as a standing banner -- all three banner domains are cleared
    /// right after `server.stop()`, before either removal's off-main-
    /// actor I/O runs, since none of the three depends on that I/O's
    /// result: the switch reads OFF the instant this call starts, so a
    /// banner left standing from an earlier attempt (including a
    /// server-start failure) must not keep showing for the duration of
    /// that I/O.
    ///
    /// Runs through `IPCActivationChain.shared`, same rationale as
    /// `enable()`.
    func disable() async -> IPCDeactivationReport {
        await IPCActivationChain.shared.runDisable { [self] in
            await disableLocked()
        }
    }

    private func disableLocked() async -> IPCDeactivationReport {
        server.stop()
        issueReporter.reportConfigIssues([])
        issueReporter.reportHooksIssues([])
        issueReporter.reportServerIssues([])
        let configInstaller = self.configInstaller
        let hooksInstaller = self.hooksInstaller
        let config = await Self.offMainActor { configInstaller.disableIPC() }
        let hooks = await Self.offMainActor { hooksInstaller.remove() }
        return IPCDeactivationReport(config: config, hooks: hooks)
    }

    /// Hops `body` onto a global concurrent queue and suspends until it
    /// returns. `IPCConfigManager` and `AgentHooksCoordinator` are
    /// synchronous I/O behind `ConfigFileUtils.withExclusiveConfig`'s
    /// untimed `flock` -- running them on `@MainActor` would block the
    /// whole app on that lock. A plain `Task { }` here would not help:
    /// it inherits `@MainActor` from its enclosing context and only
    /// changes WHEN the work runs, not WHERE.
    private static func offMainActor<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: body())
            }
        }
    }
}

// MARK: - Live adapters

@MainActor
struct LiveIPCServerControl: IPCServerControlling {
    var isRunning: Bool { CalyxMCPServer.shared.isRunning }
    var port: Int { CalyxMCPServer.shared.port }
    var token: String { CalyxMCPServer.shared.token }

    /// Reads the currently published endpoint (if any) and decides
    /// whether its token and port should be reused -- independently of
    /// each other, see `IPCEndpointReuse` -- so a persistent-session CLI
    /// that already holds the old token/URL keeps working across a
    /// restart where possible.
    func start(token: String) async throws {
        let existing = AgentEndpointFile.read(directory: CalyxMCPServer.shared.agentEndpointDirectory)
        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: token)
        try await CalyxMCPServer.shared.start(token: decision.token, preferredPort: decision.port)
    }

    /// The server's own stop reports completion through a handle this
    /// coordinator has no use for; discarding it keeps enable/disable
    /// synchronous with respect to the server's own teardown.
    ///
    /// Additionally removes `agent-endpoint.json` when its on-disk token
    /// matches this server's own `token`, using the on-disk PORT rather
    /// than `server.port` -- `CalyxMCPServer.stop()` already removes the
    /// file using the port and token it captured before resetting its
    /// own `port` to `0`, so this second read-then-remove only ever
    /// matters when that first removal's port did not match what is on
    /// disk. That happens on a failed enable that adopted a reused
    /// on-disk token via `IPCEndpointReuse` (`start(token:)` above) but
    /// never got as far as binding a port (`port` stays `0`,
    /// `finishStart` -- the only writer of `agent-endpoint.json` -- is
    /// never reached): the file on disk still holds the OLD, non-zero
    /// port from whoever published it, so `CalyxMCPServer.stop()`'s own
    /// removal (port `0` vs. the file's real port) does not match, and
    /// only this second attempt, matching on the reused token instead of
    /// the never-bound port, actually clears it.
    func stop() {
        let server = CalyxMCPServer.shared
        _ = server.stop()
        if let existing = AgentEndpointFile.read(directory: server.agentEndpointDirectory),
           existing.token == server.token {
            AgentEndpointFile.remove(directory: server.agentEndpointDirectory, port: existing.port, token: existing.token)
        }
    }
}

struct LiveIPCAgentConfigInstaller: IPCAgentConfigInstalling {
    func enableIPC(port: Int, token: String) -> IPCConfigResult {
        IPCConfigManager.enableIPC(port: port, token: token)
    }

    func disableIPC() -> IPCConfigResult {
        IPCConfigManager.disableIPC()
    }
}

struct LiveIPCAgentHooksInstaller: IPCAgentHooksInstalling {
    func install() -> AgentHooksResult {
        AgentHooksCoordinator.install()
    }

    func remove() -> AgentHooksResult {
        AgentHooksCoordinator.remove()
    }
}

/// Thrown by `SecureRandomTokenGenerator.makeToken()` when
/// `SecRandomCopyBytes` reports a non-success status. The presenter
/// renders a fixed message for `.tokenGenerationFailed` regardless of
/// the underlying status, so this carries it only for diagnostics.
enum TokenGenerationError: Error, Sendable {
    case secureRandomFailed(OSStatus)
}

struct SecureRandomTokenGenerator: IPCTokenGenerating {
    func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TokenGenerationError.secureRandomFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
struct AgentRegistryIssueReporter: IPCIntegrationIssueReporting {
    func reportConfigIssues(_ issues: [String]) {
        AgentRegistry.shared.setConfigIssues(issues)
    }

    func reportHooksIssues(_ issues: [String]) {
        AgentRegistry.shared.setHooksIssues(issues)
    }

    func reportServerIssues(_ issues: [String]) {
        AgentRegistry.shared.setServerIssues(issues)
    }
}
