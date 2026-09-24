//
//  MCPSecretKey.swift
//  Calyx
//
//  Typed key of one secret value: one belonging to a configured MCP
//  server, or an OAuth client registration belonging to an authorization
//  server (issuer), shared by every MCP server that uses it.
//

import Foundation

enum MCPSecretKey: Sendable, Equatable, Hashable {
    case env(serverID: MCPServerID, name: String)
    case header(serverID: MCPServerID, name: String)
    case oauthTokens(serverID: MCPServerID)
    case clientSecret(serverID: MCPServerID)
    /// The dynamically registered client id Calyx uses with `issuer`.
    case oauthClientRegistration(issuer: String)

    /// The server that owns this secret; nil for a per-issuer client
    /// registration, which `deleteAll(forServer:)` never removes.
    var serverID: MCPServerID? {
        switch self {
        case .env(let serverID, _), .header(let serverID, _), .oauthTokens(let serverID), .clientSecret(let serverID):
            return serverID
        case .oauthClientRegistration:
            return nil
        }
    }

    /// `<id>.env.<NAME>`, `<id>.header.<NAME>`, `<id>.oauthTokens`,
    /// `<id>.clientSecret`, each starting with
    /// `MCPSecretKey.storageKeyPrefix(forServer:)`; and
    /// `oauthClientRegistration.<issuer>`, which starts with no server's
    /// prefix.
    var storageKey: String {
        switch self {
        case .env(let serverID, let name):
            return Self.storageKeyPrefix(forServer: serverID) + "env." + name
        case .header(let serverID, let name):
            return Self.storageKeyPrefix(forServer: serverID) + "header." + name
        case .oauthTokens(let serverID):
            return Self.storageKeyPrefix(forServer: serverID) + "oauthTokens"
        case .clientSecret(let serverID):
            return Self.storageKeyPrefix(forServer: serverID) + "clientSecret"
        case .oauthClientRegistration(let issuer):
            return "oauthClientRegistration." + issuer
        }
    }

    /// `<id>.`, the common prefix of every storage key of one server.
    static func storageKeyPrefix(forServer serverID: MCPServerID) -> String {
        serverID.rawValue.uuidString + "."
    }
}
