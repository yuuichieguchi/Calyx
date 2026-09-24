//
//  FileMCPSecretStore.swift
//  Calyx
//
//  `MCPSecretStore` that keeps one 0600 file per key in a directory. Used
//  instead of the keychain when `CalyxPathRoot.testRoot` is set.
//

import CryptoKit
import Foundation

/// A file is named `<SHA-256 hex of the server id>-<SHA-256 hex of the
/// storage key>` (`issuer-<...>` for a per-issuer key), so neither the key
/// text nor the value appears in a file name, and `deleteAll(forServer:)`
/// finds a server's files by the first half. The file content is the
/// UTF-8 value.
actor FileMCPSecretStore: MCPSecretStore {

    private let directory: String

    init(directory: String) {
        self.directory = directory
    }

    func get(_ key: MCPSecretKey) async throws -> String? {
        let path = filePath(for: key)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let value = String(data: data, encoding: .utf8) else {
            throw MCPSecretStoreError.undecodableValue
        }
        return value
    }

    func set(_ value: String, forKey key: MCPSecretKey) async throws {
        if !FileManager.default.fileExists(atPath: directory) {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let data = Data(value.utf8)
        try ConfigFileUtils.withExclusiveConfig(path: filePath(for: key), mode: 0o600, restoreModeOnNoWrite: true) { _ in data }
    }

    func delete(_ key: MCPSecretKey) async throws {
        try Self.removeFile(atPath: filePath(for: key))
    }

    func deleteAll(forServer serverID: MCPServerID) async throws {
        guard FileManager.default.fileExists(atPath: directory) else {
            return
        }
        let prefix = Self.serverComponent(serverID) + "-"
        for name in try FileManager.default.contentsOfDirectory(atPath: directory) where name.hasPrefix(prefix) {
            try Self.removeFile(atPath: (directory as NSString).appendingPathComponent(name))
        }
    }

    /// A key without a server is named `issuer-<SHA-256 hex of the
    /// storage key>`, which no server's prefix matches.
    private func filePath(for key: MCPSecretKey) -> String {
        let owner = key.serverID.map(Self.serverComponent) ?? Self.issuerComponent
        let name = owner + "-" + Self.sha256Hex(key.storageKey)
        return (directory as NSString).appendingPathComponent(name)
    }

    private static let issuerComponent = "issuer"

    private static func removeFile(atPath path: String) throws {
        try ConfigFileUtils.withExclusiveConfig(path: path) { _ in nil }
    }

    private static func serverComponent(_ serverID: MCPServerID) -> String {
        sha256Hex(serverID.rawValue.uuidString)
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
