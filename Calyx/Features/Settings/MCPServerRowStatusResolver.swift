//
//  MCPServerRowStatusResolver.swift
//  Calyx
//
//  Pure state resolver for one Settings > MCP Servers row. Every input is
//  a value the caller already resolved (the connection state, the tool
//  counts, the sign-in state and whether AI Agent IPC is on), so this
//  stays testable without a live connection or a mounted window.
//

import Foundation

enum MCPServerRowStatusResolver {

    struct RowState: Sendable, Equatable {
        let statusText: String
        let showRetry: Bool
        let showSignIn: Bool
        let showSignOut: Bool
        /// The stderr tail of the failure passed to this `resolve` call only.
        let stderrTail: String?
    }

    static func resolve(
        connectionState: MCPConnectionState,
        toolCount: Int,
        uiToolCount: Int,
        authState: MCPServerAuthState,
        ipcEnabled: Bool
    ) -> RowState {
        switch connectionState {
        case .disabled:
            return RowState(statusText: "Disabled", showRetry: false, showSignIn: false, showSignOut: false, stderrTail: nil)
        case .connecting:
            return RowState(statusText: "Connecting", showRetry: false, showSignIn: false, showSignOut: false, stderrTail: nil)
        case .ready:
            let signedIn: Bool
            if case .signedIn = authState {
                signedIn = true
            } else {
                signedIn = false
            }
            return RowState(
                statusText: readyStatusText(toolCount: toolCount, uiToolCount: uiToolCount),
                showRetry: false, showSignIn: false, showSignOut: signedIn, stderrTail: nil
            )
        case .needsAuthorization:
            return RowState(statusText: "Sign-in required", showRetry: false, showSignIn: true, showSignOut: false, stderrTail: nil)
        case .authorizing:
            return RowState(statusText: "Signing in", showRetry: false, showSignIn: false, showSignOut: false, stderrTail: nil)
        case .restarting:
            return RowState(
                statusText: "Disconnected (reconnecting)", showRetry: false, showSignIn: false, showSignOut: false, stderrTail: nil
            )
        case .failed(let failure):
            return RowState(
                statusText: failure.reason, showRetry: true, showSignIn: false, showSignOut: false, stderrTail: failure.stderrTail
            )
        }
    }

    /// The row's sign-in label: "Signed in", or "Signed in as <account>"
    /// when the account is known. Nil when not signed in.
    static func signInText(authState: MCPServerAuthState) -> String? {
        guard case .signedIn(let account) = authState else { return nil }
        guard let account else { return "Signed in" }
        return "Signed in as \(account)"
    }

    /// The pane shows one banner above every row while AI Agent IPC is off.
    static func ipcOffBannerVisible(ipcEnabled: Bool) -> Bool {
        !ipcEnabled
    }

    /// `"N tools, M with UI"`, with `"1 tool"` when N is 1.
    private static func readyStatusText(toolCount: Int, uiToolCount: Int) -> String {
        let tools = toolCount == 1 ? "1 tool" : "\(toolCount) tools"
        return "\(tools), \(uiToolCount) with UI"
    }
}
