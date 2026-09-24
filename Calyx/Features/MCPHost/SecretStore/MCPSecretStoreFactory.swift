//
//  MCPSecretStoreFactory.swift
//  Calyx
//
//  Chooses the secret store: the file store under a test root, the
//  keychain otherwise.
//

import Foundation

enum MCPSecretStoreFactory {

    /// `directory` holds the files of the file store and is unused by the
    /// keychain store.
    static func make(directory: String, testRoot: String? = CalyxPathRoot.testRoot) -> any MCPSecretStore {
        if testRoot != nil {
            return FileMCPSecretStore(directory: directory)
        }
        return KeychainMCPSecretStore()
    }
}
