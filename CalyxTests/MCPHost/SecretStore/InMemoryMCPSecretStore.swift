//
//  InMemoryMCPSecretStore.swift
//  CalyxTests
//
//  Contract v2 SS7.14: this double is a production type per SS7.14's
//  own text ("置き場所は CalyxTests/MCPHost/SecretStore/..."), even
//  though SS14's summary table calls InMemoryMCPSecretStore a
//  production type living under Calyx/Features/MCPHost/SecretStore/.
//  That contradiction is reported to the caller as a contract gap;
//  this file follows SS7.14 literally, as instructed.
//

import Foundation
@testable import Calyx

actor InMemoryMCPSecretStore: MCPSecretStore {

    private var storage: [MCPSecretKey: String] = [:]

    init() {}

    func get(_ key: MCPSecretKey) async throws -> String? {
        storage[key]
    }

    func set(_ value: String, forKey key: MCPSecretKey) async throws {
        storage[key] = value
    }

    func delete(_ key: MCPSecretKey) async throws {
        storage.removeValue(forKey: key)
    }

    func deleteAll(forServer serverID: MCPServerID) async throws {
        storage = storage.filter { key, _ in
            switch key {
            case .env(let id, _), .header(let id, _), .oauthTokens(let id), .clientSecret(let id):
                return id != serverID
            case .oauthClientRegistration:
                return true
            }
        }
    }
}
