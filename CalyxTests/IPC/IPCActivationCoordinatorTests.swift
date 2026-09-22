//
//  IPCActivationCoordinatorTests.swift
//  CalyxTests
//
//  IPCActivationCoordinator owns the exact sequencing enable()/disable()
//  perform: resolve the MCP endpoint, write agent config files, install
//  agent hooks, then report integration issues. Every dependency is a
//  hand-written fake conforming to the coordinator's own seam protocols,
//  so these tests exercise the real sequencing logic without a real
//  file system, real CalyxMCPServer, or any networking.
//

import XCTest
@testable import Calyx

// MARK: - Fakes

/// Stands in for the running MCP server. start(token:) only applies
/// portAfterStart to port once it is actually called, so a test can prove a
/// caller reads port back after start returns rather than before. stop()
/// mirrors CalyxMCPServer.stop()'s own effect on this seam's three
/// properties: isRunning and port are cleared, token is deliberately left
/// alone (the real stop() never touches it either).
@MainActor
private final class FakeIPCServerControl: IPCServerControlling {
    var isRunning = false
    var port = 0
    var token = ""

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var startedWithToken: String?

    var startError: Error?
    var portAfterStart: Int?

    func start(token: String) async throws {
        startCallCount += 1
        startedWithToken = token
        if let startError {
            throw startError
        }
        if let portAfterStart {
            port = portAfterStart
        }
        // Mirrors production: the server resolves its own token during
        // start() (LiveIPCServerControl.start(token:) may reuse an
        // on-disk token instead of the freshly generated one), so the
        // coordinator reads it back from `server.token` after start()
        // returns rather than trusting the token it passed in.
        self.token = token
        isRunning = true
    }

    func stop() {
        stopCallCount += 1
        isRunning = false
        port = 0
    }
}

/// Stands in for IPCConfigManager. Records the port/token it was actually
/// handed so a test can prove the coordinator read the server's live values
/// rather than stale ones captured before start() ran.
private final class FakeIPCAgentConfigInstaller: IPCAgentConfigInstalling, @unchecked Sendable {
    private(set) var enableCallCount = 0
    private(set) var disableCallCount = 0
    private(set) var receivedPort: Int?
    private(set) var receivedToken: String?

    var enableResult = configResult()
    var disableResult = configResult()

    /// Invoked at the start of disableIPC(), before it does anything else,
    /// so a test can record this call's position relative to other fakes'
    /// calls without depending on this installer's own result.
    var onDisableIPC: (() -> Void)?

    func enableIPC(port: Int, token: String) -> IPCConfigResult {
        enableCallCount += 1
        receivedPort = port
        receivedToken = token
        return enableResult
    }

    func disableIPC() -> IPCConfigResult {
        onDisableIPC?()
        disableCallCount += 1
        return disableResult
    }
}

/// Stands in for AgentHooksCoordinator.
private final class FakeIPCAgentHooksInstaller: IPCAgentHooksInstalling, @unchecked Sendable {
    private(set) var installCallCount = 0
    private(set) var removeCallCount = 0

    var installResult = hooksResult()
    var removeResult = hooksResult()

    /// Invoked at the start of remove(), before it does anything else, so
    /// a test can record this call's position relative to other fakes'
    /// calls without depending on this installer's own result.
    var onRemove: (() -> Void)?

    func install() -> AgentHooksResult {
        installCallCount += 1
        return installResult
    }

    func remove() -> AgentHooksResult {
        onRemove?()
        removeCallCount += 1
        return removeResult
    }
}

/// Stands in for SecureRandomTokenGenerator, without touching SecRandomCopyBytes.
private final class FakeIPCTokenGenerator: IPCTokenGenerating, @unchecked Sendable {
    private(set) var makeTokenCallCount = 0
    var tokenToReturn = "a1b2c3"
    var errorToThrow: Error?

    func makeToken() throws -> String {
        makeTokenCallCount += 1
        if let errorToThrow {
            throw errorToThrow
        }
        return tokenToReturn
    }
}

/// Stands in for AgentRegistryIssueReporter. Records every call, split by
/// domain, so a test can assert exactly how many times each domain ran and
/// what each call carried, rather than only the final combined state --
/// config and hooks are reported through separate methods precisely so one
/// domain's write can never be mistaken for (or overwrite) the other's.
@MainActor
private final class FakeIPCIssueReporter: IPCIntegrationIssueReporting {
    private(set) var reportedConfigIssues: [[String]] = []
    private(set) var reportedHooksIssues: [[String]] = []
    private(set) var reportedServerIssues: [[String]] = []

    /// Invoked at the start of reportServerIssues(), before it does
    /// anything else, so a test can record this call's position relative
    /// to the other fakes' calls.
    var onReportServerIssues: (() -> Void)?

    func reportConfigIssues(_ issues: [String]) {
        reportedConfigIssues.append(issues)
    }

    func reportHooksIssues(_ issues: [String]) {
        reportedHooksIssues.append(issues)
    }

    func reportServerIssues(_ issues: [String]) {
        onReportServerIssues?()
        reportedServerIssues.append(issues)
    }
}

// MARK: - Tests
//
// configResult(...) / hooksResult(...) below come from
// IPCActivationResultFixtures.swift, shared with IPCActivationPresenterTests.

@MainActor
final class IPCActivationCoordinatorTests: XCTestCase {

    // MARK: - enable(): pi-only and agentless machines

    func test_enable_piOnlyMachine_installsHooksNeverStopsServerAndReportsWired() async {
        // Given: every IPCConfigResult axis is skipped (no agent has an MCP
        // client config file), but pi's hooks axis succeeded.
        let server = FakeIPCServerControl()
        server.portAfterStart = 41830
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        hooksInstaller.installResult = hooksResult(pi: .success)
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        let outcome = await coordinator.enable()

        XCTAssertEqual(hooksInstaller.installCallCount, 1,
                       "pi has no IPCConfigResult axis at all; the hooks installer is its only integration path and must run")
        XCTAssertEqual(server.stopCallCount, 0,
                       "A pi-only machine must never have the server it just started torn down")
        guard case .enabled(let report) = outcome else {
            XCTFail("Expected .enabled for a machine where every config axis is skipped but pi's hooks installed")
            return
        }
        XCTAssertTrue(report.anyAgentWired,
                      "pi wiring only shows up through hooks.anySucceeded; a pi-only machine must still report as wired")
    }

    func test_enable_nothingInstalledAtAll_stillInstallsHooksNeverStopsServerAndReportsNotWired() async {
        // Given: every config axis skipped AND every hooks axis skipped, i.e.
        // a machine with no supported agent CLI at all.
        let server = FakeIPCServerControl()
        server.portAfterStart = 41830
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        let outcome = await coordinator.enable()

        XCTAssertEqual(hooksInstaller.installCallCount, 1,
                       "Hooks install must still run even when no agent CLI config file could be written")
        XCTAssertEqual(server.stopCallCount, 0,
                       "A completely agentless machine must not have the MCP server it just started torn down. The " +
                       "server keeps serving the LSP proxy, cockpit tools, and any hand-configured MCP client")
        guard case .enabled(let report) = outcome else {
            XCTFail("Expected .enabled even when nothing is wired: the server itself started fine")
            return
        }
        XCTAssertFalse(report.anyAgentWired, "Nothing succeeded on either axis, so anyAgentWired must be false")
    }

    func test_enable_everyConfigAxisFailed_stillInstallsHooksAndNeverStopsServer() async {
        // Given: every config axis failed outright (not skipped). No branch
        // may sit between the config write and the hooks install.
        let server = FakeIPCServerControl()
        server.portAfterStart = 41830
        let configInstaller = FakeIPCAgentConfigInstaller()
        let error = NSError(domain: "test.ipc.config", code: 1)
        configInstaller.enableResult = configResult(
            claudeCode: .failed(error), codex: .failed(error), openCode: .failed(error),
            hermes: .failed(error), grok: .failed(error)
        )
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        _ = await coordinator.enable()

        XCTAssertEqual(hooksInstaller.installCallCount, 1,
                       "A config write failure on every axis must not skip the independent hooks install step")
        XCTAssertEqual(server.stopCallCount, 0,
                       "A config write failure must never stop the MCP server; the two steps are independent")
    }

    // MARK: - enable(): endpoint resolution

    func test_enable_serverAlreadyRunning_reusesEndpointWithoutRestartOrNewToken() async {
        // Given: the server is already running with a live token. Restarting
        // it would tear down connected agents (CalyxMCPServer.start stops
        // any running server first).
        let server = FakeIPCServerControl()
        server.isRunning = true
        server.port = 41835
        server.token = "5f3c9a1e"
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        let outcome = await coordinator.enable()

        XCTAssertEqual(server.startCallCount, 0,
                       "Restarting an already-running server tears down live agent connections; start must never run")
        XCTAssertEqual(tokenGenerator.makeTokenCallCount, 0,
                       "A running server already has a token; generating a new one would desync it from connected agents")
        XCTAssertEqual(configInstaller.receivedPort, 41835,
                       "The config write must target the port the running server actually listens on")
        XCTAssertEqual(configInstaller.receivedToken, "5f3c9a1e",
                       "The config write must use the running server's existing token, not a freshly generated one")
        XCTAssertEqual(configInstaller.enableCallCount, 1,
                       "Re-running enable against a live server must still write agent configs, so a newly " +
                       "installed agent gets wired -- the palette command is always available, so enable() must " +
                       "be safely re-runnable against a live server")
        XCTAssertEqual(hooksInstaller.installCallCount, 1,
                       "Re-running enable against a live server must still install agent hooks, so a newly " +
                       "installed agent gets wired -- a regression that early-returns from this branch must fail here")
        guard case .enabled(let report) = outcome else {
            XCTFail("Expected .enabled when the server is already running and config/hooks are wired")
            return
        }
        XCTAssertTrue(report.wasAlreadyRunning,
                      "The report must flag that enable() reused a running server rather than starting a new one")
        XCTAssertEqual(report.port, 41835, "The reported port must be the running server's own port")
    }

    func test_enable_freshStart_startsServerAndWritesNewPortAndToken() async {
        // Given: the server is not running. The port used to configure agents
        // must come from server.port AFTER start() returns, not before.
        let server = FakeIPCServerControl()
        server.portAfterStart = 41830
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        tokenGenerator.tokenToReturn = "a1b2c3d4"
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        let outcome = await coordinator.enable()

        XCTAssertEqual(server.startCallCount, 1, "A server that is not running must be started exactly once")
        XCTAssertEqual(configInstaller.receivedPort, 41830,
                       "The port written to agent configs must be read back from the server after start() returns, " +
                       "not whatever the port field held before starting")
        XCTAssertEqual(configInstaller.receivedToken, "a1b2c3d4",
                       "The config write must use the freshly generated token")
        guard case .enabled(let report) = outcome else {
            XCTFail("Expected .enabled for a clean fresh start")
            return
        }
        XCTAssertFalse(report.wasAlreadyRunning, "A fresh start must not be reported as reusing an already-running server")
        XCTAssertEqual(report.port, 41830, "The reported port must be the port the server started on")
    }

    // MARK: - enable(): failure short-circuits

    func test_enable_tokenGenerationThrows_touchesNothingElse() async {
        let server = FakeIPCServerControl()
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        tokenGenerator.errorToThrow = NSError(domain: "test.ipc.token", code: 1)
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        let outcome = await coordinator.enable()

        guard case .tokenGenerationFailed = outcome else {
            XCTFail("Expected .tokenGenerationFailed when the token generator throws")
            return
        }
        XCTAssertEqual(server.startCallCount, 0, "The server must never start without a token to hand it")
        XCTAssertEqual(configInstaller.enableCallCount, 0, "No config should be written when there is no port or token to write")
        XCTAssertEqual(hooksInstaller.installCallCount, 0, "No hooks should be installed when the endpoint was never resolved")
        XCTAssertEqual(issueReporter.reportedConfigIssues, [],
                       "A token-generation failure must not report any config issues; there is nothing to report yet")
        XCTAssertEqual(issueReporter.reportedHooksIssues, [],
                       "A token-generation failure must not report any hooks issues; there is nothing to report yet")
        XCTAssertEqual(issueReporter.reportedServerIssues, [["Failed to generate secure token."]],
                       "A token-generation failure must reach the server-issue domain with the same text the enable " +
                       "alert would show, so the sidebar and Settings never disagree")
    }

    func test_enable_serverStartThrows_touchesNothingElse() async {
        let server = FakeIPCServerControl()
        server.startError = NSError(domain: "test.ipc.start", code: 1)
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        let outcome = await coordinator.enable()

        guard case .serverStartFailed = outcome else {
            XCTFail("Expected .serverStartFailed when server.start throws")
            return
        }
        XCTAssertEqual(configInstaller.enableCallCount, 0, "No config should be written when the server never actually started")
        XCTAssertEqual(hooksInstaller.installCallCount, 0, "No hooks should be installed when the server never actually started")
        XCTAssertEqual(server.stopCallCount, 0, "A server that failed to start was never running; there is nothing to stop")
        XCTAssertEqual(issueReporter.reportedServerIssues.count, 1, "A server-start failure must report exactly one server-issue entry")
        XCTAssertEqual(
            issueReporter.reportedServerIssues.first,
            [server.startError!.localizedDescription],
            "The reported reason must match the same text the enable alert shows for .serverStartFailed, not a second copy"
        )
    }

    // MARK: - enable(): issue reporting

    func test_enable_configAndHooksFailOnDifferentAxes_reportsEachDomainSeparately() async {
        // Given: one config axis fails and a different hooks axis fails.
        let server = FakeIPCServerControl()
        server.portAfterStart = 41830
        let configInstaller = FakeIPCAgentConfigInstaller()
        let configError = NSError(domain: "test.ipc.config", code: 2, userInfo: [NSLocalizedDescriptionKey: "config boom"])
        configInstaller.enableResult = configResult(claudeCode: .failed(configError))
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let hooksError = NSError(domain: "test.ipc.hooks", code: 3, userInfo: [NSLocalizedDescriptionKey: "hooks boom"])
        hooksInstaller.installResult = hooksResult(grok: .failed(hooksError))
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        _ = await coordinator.enable()

        XCTAssertEqual(
            issueReporter.reportedConfigIssues,
            [["Claude Code config: config boom"]],
            "A config write failure must reach the config domain's own standing sidebar banner, independently of hooks"
        )
        XCTAssertEqual(
            issueReporter.reportedHooksIssues,
            [["Grok hooks: hooks boom"]],
            "A hooks install failure must reach the hooks domain's own standing sidebar banner, independently of config"
        )
    }

    func test_enable_everythingSucceeded_reportsEmptyIssuesList() async {
        let server = FakeIPCServerControl()
        server.portAfterStart = 41830
        let configInstaller = FakeIPCAgentConfigInstaller()
        configInstaller.enableResult = configResult(claudeCode: .success)
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        hooksInstaller.installResult = hooksResult(claudeCode: .success)
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        _ = await coordinator.enable()

        XCTAssertEqual(issueReporter.reportedConfigIssues, [[]],
                       "A clean enable must report the config domain exactly once with an empty issues list, " +
                       "clearing any banner left over from an earlier failed attempt")
        XCTAssertEqual(issueReporter.reportedHooksIssues, [[]],
                       "A clean enable must report the hooks domain exactly once with an empty issues list, " +
                       "clearing any banner left over from an earlier failed attempt")
        XCTAssertEqual(issueReporter.reportedServerIssues, [[]],
                       "A clean enable must clear the server-issue domain too, in case an earlier attempt left a " +
                       "start-failure banner standing")
    }

    // MARK: - disable()

    func test_disable_stopsServerRemovesConfigAndHooksAndClearsIssues() async {
        let server = FakeIPCServerControl()
        server.isRunning = true
        server.port = 41830
        server.token = "5f3c9a1e"
        let configInstaller = FakeIPCAgentConfigInstaller()
        configInstaller.disableResult = configResult(claudeCode: .success)
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        hooksInstaller.removeResult = hooksResult(claudeCode: .success)
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        let report = await coordinator.disable()

        XCTAssertEqual(server.stopCallCount, 1, "disable() must stop the MCP server exactly once, its only stop call site")
        XCTAssertEqual(configInstaller.disableCallCount, 1, "disable() must remove the agent config entries exactly once")
        XCTAssertEqual(hooksInstaller.removeCallCount, 1, "disable() must remove the agent hooks exactly once")
        XCTAssertEqual(issueReporter.reportedConfigIssues, [[]],
                       "disable() must clear the config domain's banner exactly once; removal failures surface only " +
                       "in the returned alert, not as a standing banner")
        XCTAssertEqual(issueReporter.reportedHooksIssues, [[]],
                       "disable() must clear the hooks domain's banner exactly once; removal failures surface only " +
                       "in the returned alert, not as a standing banner")
        XCTAssertEqual(issueReporter.reportedServerIssues, [[]],
                       "disable() must clear the server-issue domain too, so the sidebar drops a stale start-failure " +
                       "banner once the setting is off")

        if case .success = report.config.claudeCode {
            // pass: report carries the fake config installer's actual result
        } else {
            XCTFail("Expected disable()'s report.config to carry the fake config installer's disableIPC() result")
        }
        if case .success = report.hooks.claudeCode {
            // pass: report carries the fake hooks installer's actual result
        } else {
            XCTFail("Expected disable()'s report.hooks to carry the fake hooks installer's remove() result")
        }
    }

    func test_disable_clearsServerIssuesBanner_beforeConfigAndHooksRemoval() async {
        // The switch reads OFF the instant disable() is called (Settings
        // flips it synchronously before awaiting disable()), so the
        // server-issues banner must be cleared before the off-main-actor
        // config/hooks removal I/O runs, not after: a standing "server
        // failed to start" banner must not outlive the switch turning OFF
        // for the duration of that I/O.
        let server = FakeIPCServerControl()
        server.isRunning = true
        server.port = 41830
        server.token = "5f3c9a1e"
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        final class OrderRecorder: @unchecked Sendable {
            private(set) var events: [String] = []
            func record(_ event: String) { events.append(event) }
        }
        let recorder = OrderRecorder()
        issueReporter.onReportServerIssues = { recorder.record("reportServerIssues") }
        configInstaller.onDisableIPC = { recorder.record("disableIPC") }
        hooksInstaller.onRemove = { recorder.record("remove") }

        _ = await coordinator.disable()

        XCTAssertEqual(
            recorder.events, ["reportServerIssues", "disableIPC", "remove"],
            "reportServerIssues([]) must run before the config/hooks removal I/O, not after"
        )
    }

    func test_disableThenEnable_takesFreshStartBranch() async {
        // Given: a live server, disabled and then immediately re-enabled.
        // FakeIPCServerControl.stop() clears isRunning/port exactly like
        // the real CalyxMCPServer.stop() does, so the following enable()
        // must take the fresh-start branch rather than the reuse branch.
        let server = FakeIPCServerControl()
        server.isRunning = true
        server.port = 41830
        server.token = "5f3c9a1e"
        server.portAfterStart = 41840
        let configInstaller = FakeIPCAgentConfigInstaller()
        let hooksInstaller = FakeIPCAgentHooksInstaller()
        let tokenGenerator = FakeIPCTokenGenerator()
        tokenGenerator.tokenToReturn = "9f8e7d6c"
        let issueReporter = FakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        _ = await coordinator.disable()
        let outcome = await coordinator.enable()

        XCTAssertEqual(tokenGenerator.makeTokenCallCount, 1,
                       "disable() must leave the fake server not-running, so the very next enable() must generate a fresh token")
        XCTAssertEqual(server.startCallCount, 1,
                       "disable() must leave the fake server not-running, so the very next enable() must start it again")
        guard case .enabled(let report) = outcome else {
            XCTFail("Expected .enabled from a fresh start immediately after disable()")
            return
        }
        XCTAssertFalse(report.wasAlreadyRunning,
                       "A disable() immediately followed by enable() must take the fresh-start branch, never the reuse branch")
        XCTAssertEqual(report.port, 41840, "The fresh start must report the newly started port, not the pre-disable port")
    }
}

// MARK: - SecureRandomTokenGenerator

/// SecureRandomTokenGenerator is the only real cryptographic logic among
/// the IPC activation types, and it produces the loopback server's only
/// bearer secret, so its actual output shape is pinned here rather than
/// only exercised indirectly through a fake in the coordinator tests
/// above.
final class SecureRandomTokenGeneratorTests: XCTestCase {
    func test_makeToken_is64LowercaseHexCharacters() throws {
        let token = try SecureRandomTokenGenerator().makeToken()

        XCTAssertEqual(token.count, 64, "32 bytes hex-encoded at two characters per byte must be 64 characters")
        let hexDigits = Set("0123456789abcdef")
        XCTAssertTrue(token.allSatisfy { hexDigits.contains($0) },
                      "Every character must be a lowercase hex digit; a byte below 0x10 formatted with a non-fixed-" +
                      "width specifier would emit one nibble instead of two and silently shorten the token")
    }

    func test_makeToken_twoCallsProduceDifferentTokens() throws {
        let generator = SecureRandomTokenGenerator()

        let first = try generator.makeToken()
        let second = try generator.makeToken()

        XCTAssertNotEqual(first, second, "Each call must draw fresh random bytes rather than reusing a fixed value")
    }
}
