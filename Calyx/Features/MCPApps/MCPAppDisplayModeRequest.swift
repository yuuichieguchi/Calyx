//
//  MCPAppDisplayModeRequest.swift
//  Calyx
//
//  `ui/request-display-mode`: the host returns the resulting mode whether
//  or not it changed, and never switches to a mode outside the view's
//  available modes.
//

import Foundation

enum MCPAppDisplayModeRequest {
    /// The modes the MCP Apps spec defines.
    static let definedModes: Set<String> = ["inline", "fullscreen", "pip"]

    /// A defined but unavailable mode leaves `current` unchanged. Only a
    /// string that is not a defined mode is invalid params (-32602).
    static func resolve(requested: String, available: [String], current: String) -> Result<String, JSONRPCError> {
        guard definedModes.contains(requested) else {
            return .failure(JSONRPCError(code: -32602, message: "Unknown display mode \"\(requested)\".", data: nil))
        }
        return .success(available.contains(requested) ? requested : current)
    }
}
