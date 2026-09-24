//
//  MCPAppViewToolAccess.swift
//  Calyx
//
//  Whether a view may call a tool through its own `tools/call`.
//

import Foundation

enum MCPAppViewToolAccess {
    /// For the view (`byApp == true`) only tools whose visibility includes
    /// `app`; for the agent, those that include `model`.
    static func isCallable(tool: MCPToolDefinition, byApp: Bool) -> Bool {
        tool.visibility.contains(byApp ? .app : .model)
    }
}
