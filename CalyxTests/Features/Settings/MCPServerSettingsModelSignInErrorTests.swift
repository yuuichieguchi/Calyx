//
//  MCPServerSettingsModelSignInErrorTests.swift
//  CalyxTests
//
//  A failed Sign In from Settings > MCP Servers shows its error under the
//  server's row as a sentence, not as the name of an error case.
//

import XCTest
@testable import Calyx

@MainActor
private final class FailingSignInActions: MCPServerSettingsActions {
    private let signInError: any Error

    init(signInError: any Error) {
        self.signInError = signInError
    }

    func retry(serverID: MCPServerID) async throws {}
    func signIn(serverID: MCPServerID) async throws { throw signInError }
    func signOut(serverID: MCPServerID) async throws {}
    func authState(for serverID: MCPServerID) async throws -> MCPServerAuthState { .signedOut }
}

@MainActor
final class MCPServerSettingsModelSignInErrorTests: XCTestCase {

    private var registryDirectory: URL?

    override func setUp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registryDirectory = directory
    }

    override func tearDown() async throws {
        if let registryDirectory {
            try FileManager.default.removeItem(at: registryDirectory)
        }
    }

    /// A model over a registry holding one HTTP server, whose Sign In
    /// throws `signInError`.
    private func makeModel(signInError: any Error) async throws -> (MCPServerSettingsModel, MCPServerID) {
        let directory = try XCTUnwrap(registryDirectory)
        let registry = MCPServerRegistry(directory: directory.path, secretStore: InMemoryMCPSecretStore())
        let serverID = MCPServerID()
        try await registry.add(MCPServerConfig(
            id: serverID,
            alias: try XCTUnwrap(MCPServerAlias(rawValue: "github")),
            displayName: "GitHub",
            isEnabled: false,
            transport: .http(url: "https://api.githubcopilot.com/mcp/", headerNames: [], hint: nil),
            auth: nil
        ))
        let model = MCPServerSettingsModel()
        model.configure(MCPServerSettingsModel.Dependencies(
            registry: registry,
            connections: FakeConnectionLookup(),
            catalog: FakeCatalogProviding(),
            secretStore: InMemoryMCPSecretStore(),
            actions: FailingSignInActions(signInError: signInError)
        ))
        return (model, serverID)
    }

    private func waitForRowError(_ model: MCPServerSettingsModel, _ serverID: MCPServerID, timeout: TimeInterval = 5) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while model.rowErrors[serverID] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return model.rowErrors[serverID]
    }

    func test_signIn_clientRegistrationUnavailable_rowErrorNamesTheIssuerAndTheClientIDField() async throws {
        let (model, serverID) = try await makeModel(
            signInError: MCPOAuthFlowError.clientRegistrationUnavailable(issuer: "https://github.com/login/oauth")
        )

        model.signIn(serverID)

        let rowError = try await waitForRowError(model, serverID)
        XCTAssertEqual(
            rowError,
            "https://github.com/login/oauth does not support automatic client registration. "
                + "Enter the client ID of an OAuth app registered with it in Edit."
        )
    }

    func test_signIn_supervisorError_rowErrorIsASentence() async throws {
        let (model, serverID) = try await makeModel(signInError: MCPUpstreamSupervisorError.invalidURL("not a url"))

        model.signIn(serverID)

        let rowError = try await waitForRowError(model, serverID)
        XCTAssertEqual(rowError, "\"not a url\" is not a valid URL.")
    }
}
