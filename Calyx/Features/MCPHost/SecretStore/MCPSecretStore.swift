//
//  MCPSecretStore.swift
//  Calyx
//
//  Storage of MCP server secret values (env values, header values, OAuth
//  tokens, client secrets). Values never enter `mcp-servers.json`.
//

import Foundation

protocol MCPSecretStore: Sendable {
    func get(_ key: MCPSecretKey) async throws -> String?
    func set(_ value: String, forKey key: MCPSecretKey) async throws
    func delete(_ key: MCPSecretKey) async throws
    /// Deletes every key of every kind that belongs to `serverID`.
    func deleteAll(forServer serverID: MCPServerID) async throws
}

enum MCPSecretStoreError: Error, Sendable, Equatable {
    /// A Security framework call returned this status. A locked or denied
    /// keychain surfaces here, and the caller may retry.
    case systemStatus(Int32)
    /// A Security framework call succeeded but returned a result of an
    /// unexpected type.
    case unexpectedSystemResult
    /// A stored value is not valid UTF-8.
    case undecodableValue
}
