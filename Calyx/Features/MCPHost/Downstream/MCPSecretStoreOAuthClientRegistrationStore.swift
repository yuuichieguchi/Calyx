//
//  MCPSecretStoreOAuthClientRegistrationStore.swift
//  Calyx
//
//  `MCPOAuthClientRegistrationStoring` over `MCPSecretStore`: the client id
//  Calyx registered with an authorization server through Dynamic Client
//  Registration, kept per issuer under
//  `MCPSecretKey.oauthClientRegistration(issuer:)` so it is reused across
//  launches and never presented to another issuer.
//
//  The protocol cannot throw. A read that fails is logged and returns nil
//  (the next sign-in registers a new client); a write that fails is
//  logged.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "MCPOAuth")

struct MCPSecretStoreOAuthClientRegistrationStore: MCPOAuthClientRegistrationStoring {

    private let secretStore: any MCPSecretStore

    init(secretStore: any MCPSecretStore) {
        self.secretStore = secretStore
    }

    func clientID(forIssuer issuer: String) async -> String? {
        do {
            return try await secretStore.get(.oauthClientRegistration(issuer: issuer))
        } catch {
            logger.error("Reading the OAuth client registration for \(issuer, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func store(clientID: String, forIssuer issuer: String) async {
        do {
            try await secretStore.set(clientID, forKey: .oauthClientRegistration(issuer: issuer))
        } catch {
            logger.error("Saving the OAuth client registration for \(issuer, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }
}
