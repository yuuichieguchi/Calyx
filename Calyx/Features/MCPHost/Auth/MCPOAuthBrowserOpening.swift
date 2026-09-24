//
//  MCPOAuthBrowserOpening.swift
//  Calyx
//
//  Opens the authorization URL in the user's browser. `NSWorkspace` is used
//  because `ASWebAuthenticationSession` cannot receive an http loopback
//  redirect.
//

import AppKit
import Foundation

protocol MCPOAuthBrowserOpening: Sendable {
    func open(_ url: URL) async
}

struct SystemMCPOAuthBrowserOpening: MCPOAuthBrowserOpening {
    func open(_ url: URL) async {
        NSWorkspace.shared.open(url)
    }
}
