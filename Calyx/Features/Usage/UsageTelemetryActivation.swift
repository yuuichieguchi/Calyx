// UsageTelemetryActivation.swift
// Calyx
//
// When Calyx's telemetry block is written to and removed from Claude
// Code's settings file (R4b): a pure target, and a reconciler that
// brings the file in line with it, one run at a time. What install and
// remove do to the file is R4a's (`ClaudeUsageTelemetryConfigManager`).

import Foundation
import OSLog

extension Notification.Name {
    /// Posted (main actor) by `UsageTelemetryActivation.shared` after every reconcile run.
    static let calyxUsageTelemetryStatusDidChange = Notification.Name("com.calyx.usageTelemetryStatusDidChange")
}

// MARK: - Target

enum UsageTelemetryTarget: Equatable {
    case installed(port: Int)
    case removed
    /// Leave the file exactly as it is, and do not read it.
    case untouched
}

enum UsageTelemetryActivationRules {
    /// The block is in the file exactly while both switches are on and
    /// the server is up. A server that is not running (yet, or after a
    /// failed start) never removes it: every Claude Code session started
    /// in that moment would be silent for its whole life.
    static func target(
        trackingOn: Bool, ipcEnabled: Bool, serverPort: Int?, mayTouchAgentFiles: Bool
    ) -> UsageTelemetryTarget {
        guard mayTouchAgentFiles else { return .untouched }
        guard trackingOn, ipcEnabled else { return .removed }
        guard let serverPort else { return .untouched }
        return .installed(port: serverPort)
    }
}

// MARK: - Config status

enum UsageTelemetryConfigStatus: Equatable {
    case unknown                    // nothing attempted yet in this run of the app
    case installed(port: Int)
    case removed
    case blocked(keys: [String])
    case claudeNotFound
    case failed(String)             // the error's description
}

// MARK: - Reconciler

@MainActor
final class UsageTelemetryActivation {
    struct Inputs {
        var trackingOn: @MainActor () -> Bool
        var ipcEnabled: @MainActor () -> Bool
        var serverPort: @MainActor () -> Int?           // nil when the server is not running
        var mayTouchAgentFiles: @MainActor () -> Bool
        /// The server start generation whose IPC token rotated, while that
        /// start's server is running; nil otherwise. Passed to
        /// `loadCredential` on the install path only, so the usage token is
        /// renewed once per such start (G5, C-D19).
        var rotationGeneration: @MainActor () -> Int?
    }

    struct Effects {
        /// Brings the store's durable tracking state in line with the setting (R3b).
        var syncTracking: @Sendable () async -> Void
        /// Loads the credential (creating it when `create`, renewing it
        /// for a non-nil `rotateForGeneration` not yet renewed for) and
        /// hands it to the route. nil: there is none and none was created.
        var loadCredential: @Sendable (_ create: Bool, _ rotateForGeneration: Int?) async throws -> UsageIngestCredential?
        /// Installs the headers helper script and the telemetry block for `port`.
        var install: @Sendable (_ port: Int) async throws -> ClaudeUsageTelemetryConfigManager.Outcome
        var remove: @Sendable () async throws -> ClaudeUsageTelemetryConfigManager.Outcome
    }

    private let inputs: Inputs
    private let effects: Effects
    private let onStatusChange: @MainActor () -> Void

    private(set) var status: UsageTelemetryConfigStatus = .unknown

    // Single flight, all on the main actor.
    private var isRunning = false
    private var rerunRequested = false
    /// Callers that arrived during the current run; resumed after the next one.
    private var waitingForNextRun: [CheckedContinuation<Void, Never>] = []

    init(inputs: Inputs, effects: Effects, onStatusChange: @escaping @MainActor () -> Void) {
        self.inputs = inputs
        self.effects = effects
        self.onStatusChange = onStatusChange
    }

    /// Brings the settings file in line with the target. Returns when the
    /// file is in line with the inputs as they were when the last run started.
    ///
    /// Single flight: a call while a run is in progress makes exactly one
    /// more run happen after it, however many calls arrived, and returns
    /// once that run is done. The caller that found nothing running
    /// drives the runs until no further one is requested.
    func reconcile() async {
        if isRunning {
            rerunRequested = true
            await withCheckedContinuation { continuation in
                waitingForNextRun.append(continuation)
            }
            return
        }
        isRunning = true
        await runOnce()
        while rerunRequested {
            rerunRequested = false
            let batch = waitingForNextRun
            waitingForNextRun = []
            await runOnce()
            for continuation in batch { continuation.resume() }
        }
        isRunning = false
    }

    private func runOnce() async {
        // The inputs are read once per run, here.
        let mayTouchAgentFiles = inputs.mayTouchAgentFiles()
        let target = UsageTelemetryActivationRules.target(
            trackingOn: inputs.trackingOn(),
            ipcEnabled: inputs.ipcEnabled(),
            serverPort: inputs.serverPort(),
            mayTouchAgentFiles: mayTouchAgentFiles)
        let effects = self.effects
        switch target {
        case .installed(let port):
            status = await Self.install(port: port, rotationGeneration: inputs.rotationGeneration(), effects: effects)
        case .removed:
            status = await Self.remove(effects: effects)
        case .untouched:
            if mayTouchAgentFiles {
                await Self.syncAndLoad(effects: effects)
            }
        }
        onStatusChange()
    }

    // The effects are called here, off the main actor (`@concurrent`). In
    // production their blocking file work (behind a lock) runs on the
    // usage file queue (`UsageFileWork`), never on a pool thread.

    @concurrent
    private nonisolated static func install(
        port: Int, rotationGeneration: Int?, effects: Effects
    ) async -> UsageTelemetryConfigStatus {
        await effects.syncTracking()
        do {
            guard try await effects.loadCredential(true, rotationGeneration) != nil else {
                return .failed("The credential file was not created.")
            }
        } catch {
            return .failed(readableText(of: error))
        }
        do {
            switch try await effects.install(port) {
            case .installed(let installedPort): return .installed(port: installedPort)
            case .blocked(let keys): return .blocked(keys: keys)
            case .claudeNotFound: return .claudeNotFound
            case .removed: return .removed
            }
        } catch {
            return .failed(readableText(of: error))
        }
    }

    @concurrent
    private nonisolated static func remove(effects: Effects) async -> UsageTelemetryConfigStatus {
        let status: UsageTelemetryConfigStatus
        do {
            // `.claudeNotFound`: nothing to remove, so the block is not there.
            _ = try await effects.remove()
            status = .removed
        } catch {
            status = .failed(readableText(of: error))
        }
        await effects.syncTracking()
        // Ignored by contract: without a credential the route answers 401.
        _ = try? await effects.loadCredential(false, nil)
        return status
    }

    @concurrent
    private nonisolated static func syncAndLoad(effects: Effects) async {
        await effects.syncTracking()
        // The status is left as it is for `.untouched`; a failed load
        // leaves the route without a credential until the next run, and
        // shows as `.failed` at the reconcile that runs once the server is up.
        do {
            _ = try await effects.loadCredential(true, nil)
        } catch {
            let nsError = error as NSError
            logger.error("""
                Usage credential could not be loaded: \
                \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)
                """)
        }
    }

    private nonisolated static let logger = Logger(subsystem: "com.calyx.terminal", category: "UsageIngest")

    /// The text a person can read: `LocalizedError.errorDescription` when
    /// there is one, an `NSError`'s `localizedDescription`, otherwise
    /// `String(describing:)`. For `ConfigFileError` and `NSError` this is
    /// the same text the AI Agent IPC row shows (`localizedDescription`).
    nonisolated static func readableText(of error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        // Every Swift error bridges to NSError, so test the dynamic type.
        if type(of: error) is NSError.Type {
            return (error as NSError).localizedDescription
        }
        return String(describing: error)
    }

    // MARK: Production wiring

    static let shared = makeProduction()

    /// Inputs: the two settings, the shared server (port, and the start
    /// generation when that start rotated the IPC token), the launch policy.
    /// Effects: the shared ledger, the shared credential holder over
    /// Application Support, the headers helper script in
    /// `AgentHookScript.defaultInstallDirectory`, R4a's manager on the default settings path
    /// (which follows `CalyxPathRoot.testRoot`). The shared objects are
    /// looked up when an effect runs, never here.
    private static func makeProduction() -> UsageTelemetryActivation {
        UsageTelemetryActivation(
            inputs: Inputs(
                trackingOn: { UsageTrackingSettings.enabled },
                ipcEnabled: { IPCSettings.enabled },
                serverPort: {
                    let server = CalyxMCPServer.shared
                    return server.isRunning ? server.port : nil
                },
                mayTouchAgentFiles: { LaunchEnvironmentPolicy.mayPerformAgentIPCActivation() },
                rotationGeneration: {
                    let server = CalyxMCPServer.shared
                    return rotationGeneration(
                        isRunning: server.isRunning, rotated: server.lastStartRotatedToken,
                        generation: server.startGeneration)
                }),
            effects: Effects(
                syncTracking: { await UsageLedger.shared.syncTracking() },
                loadCredential: { create, rotateForGeneration in
                    try await UsageIngestCredentialHolder.shared.load(
                        create: create, directory: AppSupportDirectory.path, rotateForGeneration: rotateForGeneration)
                },
                install: { port in
                    try await UsageFileWork.run {
                        try productionInstall(port: port, binDirectory: AgentHookScript.defaultInstallDirectory)
                    }
                },
                remove: {
                    try await UsageFileWork.run {
                        try productionRemove(binDirectory: AgentHookScript.defaultInstallDirectory)
                    }
                }),
            onStatusChange: {
                NotificationCenter.default.post(name: .calyxUsageTelemetryStatusDidChange, object: nil)
            })
    }

    /// The start generation to renew the usage token for: the server's
    /// `generation` when it is running and that start rotated the IPC
    /// token, otherwise nil (no renewal).
    nonisolated static func rotationGeneration(isRunning: Bool, rotated: Bool, generation: Int) -> Int? {
        isRunning && rotated ? generation : nil
    }

    /// Production `Effects.install`: installs `calyx-usage-headers` into
    /// `binDirectory`, then the telemetry config naming it and `port`.
    /// When the script install throws, Calyx's telemetry block is removed
    /// from the settings file (its outcome and errors ignored: the original
    /// error is what the caller reports) and the original error rethrown,
    /// so no config is left pointing at a missing or stale helper, legacy
    /// `cat` helpers included (G5 disposition 24, 挙動 2).
    /// `settingsPath` nil means the default settings path.
    nonisolated static func productionInstall(port: Int, binDirectory: String, settingsPath: String? = nil) throws -> ClaudeUsageTelemetryConfigManager.Outcome {
        let helperPath: String
        do {
            helperPath = try UsageHeadersHelperScript.install(toDirectory: binDirectory)
        } catch {
            _ = try? ClaudeUsageTelemetryConfigManager.remove(settingsPath: settingsPath)
            throw error
        }
        return try ClaudeUsageTelemetryConfigManager.install(port: port, helperPath: helperPath, settingsPath: settingsPath)
    }

    /// Production `Effects.remove`: removes the telemetry config, then
    /// the script from `binDirectory`.
    nonisolated static func productionRemove(binDirectory: String, settingsPath: String? = nil) throws -> ClaudeUsageTelemetryConfigManager.Outcome {
        let outcome = try ClaudeUsageTelemetryConfigManager.remove(settingsPath: settingsPath)
        UsageHeadersHelperScript.remove(fromDirectory: binDirectory)
        return outcome
    }
}
