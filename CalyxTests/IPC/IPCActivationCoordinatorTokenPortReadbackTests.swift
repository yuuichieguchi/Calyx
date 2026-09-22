//
//  IPCActivationCoordinatorTokenPortReadbackTests.swift
//  CalyxTests
//
//  Covers the L2.3/L2.5 shape of IPCActivationCoordinator: enable()
//  becomes async, and IPCServerControlling.start(token:) becomes
//  `async throws` (CalyxMCPServer's own start(token:preferredPort:)
//  stops blocking the main thread on a DispatchSemaphore). This file
//  pins one fact not covered by the (still-synchronous) fakes in
//  IPCActivationCoordinatorTests.swift: after start() returns, the
//  coordinator must read BOTH server.token and server.port back from
//  the server, not reuse the token it generated or a port captured
//  before start. A fake whose start() does not assign self.token cannot
//  catch a coordinator that writes the generator's token instead of the
//  server's -- so this fake's start(token:) records the token it was
//  HANDED, then assigns a DIFFERENT token to self.token, exactly the
//  shape needed to prove the readback happens after start(), not before.
//
//  IPCActivationCoordinatorTests.swift's own fakes will need the same
//  `async throws` signature once the coordinator itself changes --
//  that existing file is not modified here.
//

import XCTest
@testable import Calyx

/// Async counterpart to IPCActivationCoordinatorTests.swift's
/// FakeIPCServerControl. start(token:) records the token it was handed
/// (startedWithToken) and then assigns a DIFFERENT value to self.token
/// (tokenAfterStart) plus a self.port distinct from any value the
/// coordinator could have seen before calling start -- so an assertion
/// against configInstaller.receivedToken/receivedPort can tell "read
/// from the server after start" apart from "reused what was passed in".
@MainActor
private final class ReadbackFakeIPCServerControl: IPCServerControlling {
    var isRunning = false
    var port = 0
    var token = ""

    private(set) var startCallCount = 0
    private(set) var startedWithToken: String?

    var tokenAfterStart = "server-assigned-token"
    var portAfterStart = 41834

    func start(token: String) async throws {
        startCallCount += 1
        startedWithToken = token
        // The server resolves its OWN token/port during start, distinct
        // from whatever was passed in -- CalyxMCPServer.start(token:)
        // assigns self.token before bind (CalyxMCPServer.swift:915) and
        // self.port only once a listener actually resolves
        // (finishStart, CalyxMCPServer.swift:1238).
        self.token = tokenAfterStart
        self.port = portAfterStart
        isRunning = true
    }

    func stop() {
        isRunning = false
        port = 0
    }
}

private final class ReadbackFakeIPCAgentConfigInstaller: IPCAgentConfigInstalling, @unchecked Sendable {
    private(set) var receivedPort: Int?
    private(set) var receivedToken: String?

    func enableIPC(port: Int, token: String) -> IPCConfigResult {
        receivedPort = port
        receivedToken = token
        return configResult()
    }

    func disableIPC() -> IPCConfigResult {
        configResult()
    }
}

private final class ReadbackFakeIPCAgentHooksInstaller: IPCAgentHooksInstalling, @unchecked Sendable {
    func install() -> AgentHooksResult { hooksResult() }
    func remove() -> AgentHooksResult { hooksResult() }
}

private final class ReadbackFakeIPCTokenGenerator: IPCTokenGenerating, @unchecked Sendable {
    var tokenToReturn = "generator-token"
    func makeToken() throws -> String { tokenToReturn }
}

@MainActor
private final class ReadbackFakeIPCIssueReporter: IPCIntegrationIssueReporting {
    func reportConfigIssues(_ issues: [String]) {}
    func reportHooksIssues(_ issues: [String]) {}
    func reportServerIssues(_ issues: [String]) {}
}

@MainActor
final class IPCActivationCoordinatorTokenPortReadbackTests: XCTestCase {

    func test_enable_freshStart_writesConfigWithServersOwnTokenAndPort_notTheGeneratorsOrAPreStartValue() async {
        let server = ReadbackFakeIPCServerControl()
        server.tokenAfterStart = "server-assigned-9f8e"
        server.portAfterStart = 41836
        let configInstaller = ReadbackFakeIPCAgentConfigInstaller()
        let hooksInstaller = ReadbackFakeIPCAgentHooksInstaller()
        let tokenGenerator = ReadbackFakeIPCTokenGenerator()
        tokenGenerator.tokenToReturn = "generator-1234"
        let issueReporter = ReadbackFakeIPCIssueReporter()
        let coordinator = IPCActivationCoordinator(
            server: server, configInstaller: configInstaller, hooksInstaller: hooksInstaller,
            tokenGenerator: tokenGenerator, issueReporter: issueReporter
        )

        _ = await coordinator.enable()

        XCTAssertEqual(server.startedWithToken, "generator-1234",
                       "start() must still be handed the freshly generated token")
        XCTAssertEqual(configInstaller.receivedToken, "server-assigned-9f8e",
                       "The config write must use server.token READ BACK AFTER start() returns, not the " +
                       "token the generator produced -- a fake whose start() never reassigns self.token cannot " +
                       "catch a coordinator that writes the generator's token instead")
        XCTAssertNotEqual(configInstaller.receivedToken, tokenGenerator.tokenToReturn,
                          "This fake's start() deliberately assigns a token different from the one it was " +
                          "handed, so the config write must never equal the generator's token")
        XCTAssertEqual(configInstaller.receivedPort, 41836,
                       "The config write must use server.port read back after start() returns")
    }
}
