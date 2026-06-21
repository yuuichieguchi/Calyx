//
//  TraceValue.swift
//  Calyx
//
//  LSP 3.18 TraceValue. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#traceValue
//
//  Wire shape is a closed string enum: `"off" | "messages" | "verbose"`.
//  Decoding any other string must fail; we rely on `RawRepresentable`'s
//  default synthesized Decodable behaviour which throws when the raw value
//  is outside the case set.
//

import Foundation

/// Tracing level negotiated between client and server. Spec defines a closed
/// set of three string values.
enum TraceValue: String, Sendable, Codable, Equatable, Hashable {
    case off
    case messages
    case verbose
}
