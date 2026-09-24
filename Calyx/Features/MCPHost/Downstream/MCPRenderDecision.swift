//
//  MCPRenderDecision.swift
//  Calyx
//
//  Whether Calyx renders the UI of a proxied tool call, and where.
//

import Foundation

enum MCPRenderDecision: Sendable, Equatable {
    /// Render in the pane `surfaceID`, or in a standalone panel when nil.
    case render(surfaceID: UUID?)
    /// Return `_meta.ui` untouched and render nothing.
    case stepAside
}
