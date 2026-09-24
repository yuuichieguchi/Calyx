//
//  InMemoryMCPOAuthCredentialStore.swift
//  CalyxTests
//
//  In-memory `MCPOAuthCredentialStoring` double (API contract section
//  6.2/14), keyed by `MCPServerID`, standing in for the SecretStore
//  wrapper `MCPUpstreamSupervisor` would provide in production.
//

import Foundation
@testable import Calyx

actor InMemoryMCPOAuthCredentialStore: MCPOAuthCredentialStoring {
    private var tokensByServer: [MCPServerID: MCPOAuthTokenSet] = [:]
    private var registrationsByServer: [MCPServerID: MCPOAuthStoredClient] = [:]

    func tokens(for serverID: MCPServerID) async throws -> MCPOAuthTokenSet? {
        tokensByServer[serverID]
    }

    func setTokens(_ tokens: MCPOAuthTokenSet?, for serverID: MCPServerID) async throws {
        tokensByServer[serverID] = tokens
    }

    func clientRegistration(for serverID: MCPServerID) async throws -> MCPOAuthStoredClient? {
        registrationsByServer[serverID]
    }

    func setClientRegistration(_ client: MCPOAuthStoredClient?, for serverID: MCPServerID) async throws {
        registrationsByServer[serverID] = client
    }
}
