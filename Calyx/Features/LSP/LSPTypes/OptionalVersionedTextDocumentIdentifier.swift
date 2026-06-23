//
//  OptionalVersionedTextDocumentIdentifier.swift
//  Calyx
//
//  LSP 3.18 OptionalVersionedTextDocumentIdentifier type. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#optionalVersionedTextDocumentIdentifier
//
//  Spec: `version: integer | null`. The `null` case is semantically different
//  from "absent" — it means the document has no known version (e.g. it was
//  saved without an open editor managing versions). We therefore implement
//  custom `init(from:)`/`encode(to:)` so that a nil `version` is emitted as
//  an explicit JSON `null` rather than being dropped from the output.
//

import Foundation

/// A text document identifier that may not have a version number. The
/// `version` may be `null` to indicate that the version is unknown.
struct OptionalVersionedTextDocumentIdentifier: Sendable, Codable, Equatable, Hashable {
    let uri: DocumentUri
    let version: Int?

    init(uri: DocumentUri, version: Int?) {
        self.uri = uri
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        case uri
        case version
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uri = try container.decode(DocumentUri.self, forKey: .uri)
        // Accept either a missing `version` key OR an explicit JSON `null` as
        // nil. Per spec the key is always present, but be permissive on input.
        if container.contains(.version) {
            if try container.decodeNil(forKey: .version) {
                self.version = nil
            } else {
                self.version = try container.decode(Int.self, forKey: .version)
            }
        } else {
            self.version = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uri, forKey: .uri)
        // Always emit `version`, encoding nil as explicit JSON null so that
        // round-trips preserve the spec's `version: integer | null` shape.
        if let version {
            try container.encode(version, forKey: .version)
        } else {
            try container.encodeNil(forKey: .version)
        }
    }
}
