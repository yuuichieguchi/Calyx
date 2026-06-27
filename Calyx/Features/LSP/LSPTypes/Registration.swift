//
//  Registration.swift
//  Calyx
//
//  LSP 3.18 Registration + RegistrationParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#registration
//
//  Used by the server to dynamically request capability registration via the
//  `client/registerCapability` request. `registerOptions` is method-specific
//  arbitrary JSON; we keep the raw `AnyCodable?` payload for round-trip and
//  back-compat, and provide a typed sidecar (`RegisterOptions`) the registry
//  decodes per-method so downstream code (e.g. file-watch dispatch) can
//  consult the structured shape directly.
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
    /// Options necessary for the registration. Method-specific JSON,
    /// preserved verbatim for round-trip / unknown methods.
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

// MARK: - RegisterOptions

/// Typed, method-discriminated view over a `Registration.registerOptions`
/// payload. Each known LSP registration method has a structured options
/// shape; unknown methods round-trip via the `.raw` case so we never
/// silently lose data.
///
/// The raw `AnyCodable?` slot on `Registration` is preserved unchanged for
/// backwards compatibility; this enum is a sidecar that `CapabilityRegistry`
/// stores alongside the original `Registration` so consumers may consult
/// either form.
enum RegisterOptions: Sendable, Equatable {
    /// `workspace/didChangeWatchedFiles` registration options. The
    /// `watchers` array is the dispatch table the bridge consults when
    /// deciding which file events warrant a notification.
    case didChangeWatchedFiles(DidChangeWatchedFilesRegistrationOptions)
    /// `workspace/willCreateFiles` / `workspace/didCreateFiles` /
    /// `workspace/willRenameFiles` / `workspace/didRenameFiles` /
    /// `workspace/willDeleteFiles` / `workspace/didDeleteFiles`
    /// registration options. All six share the same
    /// `FileOperationRegistrationOptions` shape.
    case fileOperationRegistration(FileOperationRegistrationOptions)
    /// Unknown / unmapped method: keep the raw payload verbatim. `nil`
    /// when the server omitted the `registerOptions` slot entirely.
    case raw(AnyCodable?)

    // MARK: - Method classification

    /// The set of LSP method strings that share the
    /// `FileOperationRegistrationOptions` shape.
    static let fileOperationMethods: Set<String> = [
        "workspace/willCreateFiles",
        "workspace/willRenameFiles",
        "workspace/willDeleteFiles",
        "workspace/didCreateFiles",
        "workspace/didRenameFiles",
        "workspace/didDeleteFiles",
    ]

    /// Decode the typed `RegisterOptions` case appropriate for the given
    /// LSP method. Unknown methods fall through to `.raw`, preserving the
    /// original payload. A decode failure on a known method also falls
    /// through to `.raw` so the registration is never dropped — the
    /// untyped payload remains available to consumers willing to parse it
    /// themselves.
    static func decode(
        method: String,
        registerOptions: AnyCodable?
    ) -> RegisterOptions {
        switch method {
        case "workspace/didChangeWatchedFiles":
            guard let options = registerOptions else {
                return .raw(nil)
            }
            if let typed = try? decodeTyped(
                DidChangeWatchedFilesRegistrationOptions.self,
                from: options
            ) {
                return .didChangeWatchedFiles(typed)
            }
            return .raw(options)

        case let m where fileOperationMethods.contains(m):
            guard let options = registerOptions else {
                return .raw(nil)
            }
            if let typed = try? decodeTyped(
                FileOperationRegistrationOptions.self,
                from: options
            ) {
                return .fileOperationRegistration(typed)
            }
            return .raw(options)

        default:
            return .raw(registerOptions)
        }
    }

    // MARK: - Helpers

    /// Re-encode the `AnyCodable` payload to JSON data and decode it into
    /// the requested concrete `Codable` type. The round trip is necessary
    /// because `AnyCodable` storage is private; the JSON layer is the only
    /// stable surface between the type-erased payload and a typed shape.
    private static func decodeTyped<T: Decodable>(
        _ type: T.Type,
        from value: AnyCodable
    ) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
