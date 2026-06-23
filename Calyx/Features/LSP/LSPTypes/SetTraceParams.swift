//
//  SetTraceParams.swift
//  Calyx
//
//  LSP 3.18 SetTraceParams. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#setTrace
//
//  Sent from client to server to change the trace level.
//

import Foundation

/// Params for the `$/setTrace` notification.
struct SetTraceParams: Sendable, Codable, Equatable, Hashable {
    /// The new trace value.
    let value: TraceValue

    init(value: TraceValue) {
        self.value = value
    }
}
