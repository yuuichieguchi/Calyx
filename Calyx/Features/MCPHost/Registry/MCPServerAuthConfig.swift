//
//  MCPServerAuthConfig.swift
//  Calyx
//
//  Per-server OAuth settings. The client secret value itself is stored
//  under `MCPSecretKey.clientSecret`.
//

import Foundation

struct MCPServerAuthConfig: Sendable, Equatable, Codable {
    let preRegisteredClientID: String?
    let clientAuthenticationMethod: MCPOAuthClientAuthenticationMethod?
    let redirect: MCPOAuthRedirectConfig
    let scopeOverride: String?
}
