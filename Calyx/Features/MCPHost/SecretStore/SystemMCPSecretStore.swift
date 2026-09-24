//
//  SystemMCPSecretStore.swift
//  Calyx
//
//  `MCPSecretStore` backed by the login keychain as generic password
//  items: service `KeychainMCPSecretStore.service`, account
//  `MCPSecretKey.storageKey`.
//

import Foundation
import Security

struct KeychainMCPSecretStore: MCPSecretStore {

    static let service = "com.calyx.terminal.mcp"

    /// Performs no keychain access.
    init() {}

    func get(_ key: MCPSecretKey) async throws -> String? {
        var query = Self.itemQuery(account: key.storageKey)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MCPSecretStoreError.systemStatus(status)
        }
        guard let data = result as? Data else {
            throw MCPSecretStoreError.unexpectedSystemResult
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw MCPSecretStoreError.undecodableValue
        }
        return value
    }

    func set(_ value: String, forKey key: MCPSecretKey) async throws {
        let query = Self.itemQuery(account: key.storageKey)
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw MCPSecretStoreError.systemStatus(updateStatus)
        }
        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MCPSecretStoreError.systemStatus(addStatus)
        }
    }

    func delete(_ key: MCPSecretKey) async throws {
        try Self.deleteItem(account: key.storageKey)
    }

    func deleteAll(forServer serverID: MCPServerID) async throws {
        let prefix = MCPSecretKey.storageKeyPrefix(forServer: serverID)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess else {
            throw MCPSecretStoreError.systemStatus(status)
        }
        guard let items = result as? [[String: Any]] else {
            throw MCPSecretStoreError.unexpectedSystemResult
        }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String, account.hasPrefix(prefix) else { continue }
            try Self.deleteItem(account: account)
        }
    }

    /// Security framework queries are CoreFoundation dictionaries, so the
    /// values are untyped.
    private static func itemQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    private static func deleteItem(account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPSecretStoreError.systemStatus(status)
        }
    }
}
