//
//  MCPSecretStoreOAuthClientRegistrationStoreTests.swift
//  CalyxTests
//
//  `MCPSecretStoreOAuthClientRegistrationStore` (decision V65): a
//  dynamically registered client id is stored per issuer in the secret
//  store and read back.
//

import XCTest
@testable import Calyx

final class MCPSecretStoreOAuthClientRegistrationStoreTests: XCTestCase {

    func test_storeThenRead_returnsTheClientIDOfThatIssuerOnly() async throws {
        let secretStore = InMemoryMCPSecretStore()
        let store = MCPSecretStoreOAuthClientRegistrationStore(secretStore: secretStore)

        await store.store(clientID: "registered-client", forIssuer: "https://auth.example.com")

        let stored = await store.clientID(forIssuer: "https://auth.example.com")
        let other = await store.clientID(forIssuer: "https://other.example.com")
        let raw = try await secretStore.get(.oauthClientRegistration(issuer: "https://auth.example.com"))
        XCTAssertEqual(stored, "registered-client")
        XCTAssertNil(other)
        XCTAssertEqual(raw, "registered-client", "the registration is kept in the secret store, so it survives a relaunch")
    }
}
