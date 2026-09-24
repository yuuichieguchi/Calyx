//
//  MCPSecretStoreOAuthCredentials.swift
//  Calyx
//
//  `MCPOAuthCredentialStoring` over `MCPSecretStore`. A server's tokens and
//  the client they were issued to are one JSON document under
//  `MCPSecretKey.oauthTokens`, so they are written and deleted together.
//

import Foundation

actor MCPSecretStoreOAuthCredentials: MCPOAuthCredentialStoring {

    private struct StoredTokens: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        let scope: String?
    }

    private struct Document: Codable {
        var tokens: StoredTokens?
        var client: MCPOAuthStoredClient?
    }

    private let secretStore: any MCPSecretStore

    init(secretStore: any MCPSecretStore) {
        self.secretStore = secretStore
    }

    func tokens(for serverID: MCPServerID) async throws -> MCPOAuthTokenSet? {
        guard let stored = try await load(serverID).tokens else { return nil }
        return MCPOAuthTokenSet(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            expiresAt: stored.expiresAt,
            scope: stored.scope
        )
    }

    func setTokens(_ tokens: MCPOAuthTokenSet?, for serverID: MCPServerID) async throws {
        var document = try await load(serverID)
        document.tokens = tokens.map {
            StoredTokens(accessToken: $0.accessToken, refreshToken: $0.refreshToken, expiresAt: $0.expiresAt, scope: $0.scope)
        }
        try await save(document, serverID)
    }

    func clientRegistration(for serverID: MCPServerID) async throws -> MCPOAuthStoredClient? {
        try await load(serverID).client
    }

    func setClientRegistration(_ client: MCPOAuthStoredClient?, for serverID: MCPServerID) async throws {
        var document = try await load(serverID)
        document.client = client
        try await save(document, serverID)
    }

    private func load(_ serverID: MCPServerID) async throws -> Document {
        guard let text = try await secretStore.get(.oauthTokens(serverID: serverID)) else {
            return Document(tokens: nil, client: nil)
        }
        return try JSONDecoder().decode(Document.self, from: Data(text.utf8))
    }

    private func save(_ document: Document, _ serverID: MCPServerID) async throws {
        guard document.tokens != nil || document.client != nil else {
            try await secretStore.delete(.oauthTokens(serverID: serverID))
            return
        }
        let data = try JSONEncoder().encode(document)
        try await secretStore.set(String(decoding: data, as: UTF8.self), forKey: .oauthTokens(serverID: serverID))
    }
}
