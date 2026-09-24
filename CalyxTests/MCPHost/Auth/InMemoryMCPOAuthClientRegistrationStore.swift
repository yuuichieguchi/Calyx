//
//  InMemoryMCPOAuthClientRegistrationStore.swift
//  CalyxTests
//
//  In-memory `MCPOAuthClientRegistrationStoring` double (API contract
//  section 14), keyed by issuer, so tests can assert credentials
//  registered under one issuer never leak to another.
//

import Foundation
@testable import Calyx

actor InMemoryMCPOAuthClientRegistrationStore: MCPOAuthClientRegistrationStoring {
    private var storage: [String: String] = [:]

    func clientID(forIssuer issuer: String) async -> String? {
        storage[issuer]
    }

    func store(clientID: String, forIssuer issuer: String) async {
        storage[issuer] = clientID
    }
}
