//
//  Unregistration.swift
//  Calyx
//
//  LSP 3.18 Unregistration + UnregistrationParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#unregistration
//
//  IMPORTANT: the LSP wire format spells the array key as `"unregisterations"`
//  (an extra "er" between "unregist" and "ations"). This is a historical
//  typo that the spec preserves verbatim for backwards compatibility. We
//  expose the Swift property under the correctly-spelled name
//  `unregistrations` and map it to the typo'd JSON key via `CodingKeys`.
//

import Foundation

// MARK: - Unregistration

/// General parameters to unregister a request or notification previously
/// registered via `client/registerCapability`.
struct Unregistration: Sendable, Codable, Equatable {
    /// The id used to unregister the request or notification. Usually an id
    /// provided during the `client/registerCapability` request.
    let id: String
    /// The method / capability to unregister for.
    let method: String

    init(id: String, method: String) {
        self.id = id
        self.method = method
    }
}

// MARK: - UnregistrationParams

/// Params for `client/unregisterCapability`. The on-the-wire JSON key is the
/// typo'd `"unregisterations"` per the LSP spec.
struct UnregistrationParams: Sendable, Codable, Equatable {
    /// The unregistrations to apply. Spelled correctly on the Swift side;
    /// serialized as `"unregisterations"` to match the spec.
    let unregistrations: [Unregistration]

    init(unregistrations: [Unregistration]) {
        self.unregistrations = unregistrations
    }

    private enum CodingKeys: String, CodingKey {
        // Preserve the spec's historical typo on the wire.
        case unregistrations = "unregisterations"
    }
}
