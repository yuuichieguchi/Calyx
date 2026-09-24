//
//  MCPAppOpenLinkPolicy.swift
//  Calyx
//
//  Which URLs `ui/open-link` may open.
//

import Foundation

enum MCPAppOpenLinkPolicy {
    private static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func isAllowedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}
