//
//  InitializedParams.swift
//  Calyx
//
//  LSP 3.18 InitializedParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#initialized
//
//  The `initialized` notification carries an empty object as its `params`.
//  We model that as an empty struct with explicit Codable conformance so
//  that encoding always produces `{}` and decoding accepts `{}`.
//

import Foundation

/// Empty params object for the `initialized` notification.
struct InitializedParams: Sendable, Codable, Equatable, Hashable {
    init() {}

    init(from decoder: any Decoder) throws {
        // Accept any keyed container; ignore any extra fields a future spec
        // revision might add. We don't require an empty object specifically.
        _ = try decoder.container(keyedBy: EmptyCodingKeys.self)
    }

    func encode(to encoder: any Encoder) throws {
        // Always emit `{}`.
        _ = encoder.container(keyedBy: EmptyCodingKeys.self)
    }

    private struct EmptyCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
