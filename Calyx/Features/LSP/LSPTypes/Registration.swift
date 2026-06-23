//
//  Registration.swift
//  Calyx
//
//  LSP 3.18 Registration + RegistrationParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#registration
//
//  Used by the server to dynamically request capability registration via the
//  `client/registerCapability` request. `registerOptions` is method-specific
//  arbitrary JSON and is therefore typed as `AnyCodable?`.
//

import Foundation

// MARK: - Registration

/// General parameters to register for a capability.
struct Registration: Sendable, Codable, Equatable {
    /// The id used to register the request. The id can be used to deregister
    /// the request again. Often a UUID.
    let id: String
    /// The method / capability to register for.
    let method: String
    /// Options necessary for the registration. Method-specific JSON.
    let registerOptions: AnyCodable?

    init(id: String, method: String, registerOptions: AnyCodable? = nil) {
        self.id = id
        self.method = method
        self.registerOptions = registerOptions
    }
}

// MARK: - RegistrationParams

/// Params for `client/registerCapability`. Carries a batch of registrations
/// to apply atomically.
struct RegistrationParams: Sendable, Codable, Equatable {
    let registrations: [Registration]

    init(registrations: [Registration]) {
        self.registrations = registrations
    }
}
