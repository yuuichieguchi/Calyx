//
//  MCPServerRowStatusResolverTests.swift
//  CalyxTests
//
//  Pure state resolver for a Settings > MCP Servers row (contract v2
//  §12.1). Every input is a value the caller already resolved (the
//  shared MCPConnectionState, tool counts, MCPServerAuthState, and
//  whether Agent IPC is on), so this is testable without a live upstream
//  connection or a mounted window. `retryPending` is dropped: the
//  `restarting` wording alone carries the "a restart is already
//  scheduled" meaning (§12.1, §12.3 item 3).
//
//  Wording is pinned verbatim to §12.1's own English literals: "Disabled",
//  "Connecting", "N tools, M with UI" (singular "1 tool"/"1 with UI" at
//  N==1/M==1 per §12.3 item 2), "Sign-in required", "Signing in",
//  "Disconnected (reconnecting)", and for `failed`,
//  statusText = failure.reason / stderrTail = failure.stderrTail.
//

import XCTest
@testable import Calyx

final class MCPServerRowStatusResolverTests: XCTestCase {

    private func serverInfo() -> MCPServerInfo {
        MCPServerInfo(
            negotiatedEra: .v2025_11_25,
            serverInfo: MCPImplementation(name: "fixture-server", version: "1.0.0", title: nil, description: nil, websiteUrl: nil),
            instructions: nil
        )
    }

    // MARK: - disabled

    func test_disabled_statusTextIsDisabled_noActionButtons() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .disabled, toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "Disabled")
        XCTAssertFalse(state.showRetry)
        XCTAssertFalse(state.showSignIn)
        XCTAssertFalse(state.showSignOut)
    }

    // MARK: - connecting

    func test_connecting_statusTextIndicatesConnecting_noActionButtons() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .connecting, toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "Connecting")
        XCTAssertFalse(state.showRetry)
        XCTAssertFalse(state.showSignIn)
        XCTAssertFalse(state.showSignOut)
    }

    // MARK: - needsAuthorization: Sign in only

    func test_needsAuthorization_showsSignInOnly() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .needsAuthorization, toolCount: 0, uiToolCount: 0, authState: .signedOut, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "Sign-in required")
        XCTAssertTrue(state.showSignIn)
        XCTAssertFalse(state.showSignOut)
        XCTAssertFalse(state.showRetry)
    }

    // MARK: - authorizing: no buttons, mid-flow wording

    func test_authorizing_statusTextIndicatesSigningIn_noButtons() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .authorizing, toolCount: 0, uiToolCount: 0, authState: .signedOut, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "Signing in")
        XCTAssertFalse(state.showRetry)
        XCTAssertFalse(state.showSignIn, "already mid-flow -- must not re-offer Sign in")
        XCTAssertFalse(state.showSignOut)
    }

    // MARK: - ready: "N tools, M with UI"; auth is orthogonal to connection phase

    func test_ready_formatsToolCounts_exactWording() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .ready(serverInfo(), toolCount: 7), toolCount: 7, uiToolCount: 2, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "7 tools, 2 with UI")
    }

    func test_ready_zeroUITools_stillReportsZero() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .ready(serverInfo(), toolCount: 3), toolCount: 3, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "3 tools, 0 with UI")
    }

    func test_ready_singularToolCount_usesSingularNoun() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .ready(serverInfo(), toolCount: 1), toolCount: 1, uiToolCount: 1, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "1 tool, 1 with UI")
    }

    func test_ready_signedIn_showsToolCountAndSignOut() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .ready(serverInfo(), toolCount: 5), toolCount: 5, uiToolCount: 1,
            authState: .signedIn(account: "me@example.com"), ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "5 tools, 1 with UI")
        XCTAssertTrue(state.showSignOut)
        XCTAssertFalse(state.showSignIn)
    }

    func test_ready_notRequiredAuth_neverShowsSignOut() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .ready(serverInfo(), toolCount: 5), toolCount: 5, uiToolCount: 1, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertFalse(state.showSignOut)
        XCTAssertFalse(state.showSignIn)
    }

    func test_ready_signedOutAuth_neverShowsSignOut() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .ready(serverInfo(), toolCount: 5), toolCount: 5, uiToolCount: 1, authState: .signedOut, ipcEnabled: true
        )

        XCTAssertFalse(state.showSignOut)
    }

    // MARK: - restarting: "disconnected (reconnecting)", no buttons

    func test_restarting_statusTextIsDisconnectedReconnecting_noButtons() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .restarting(attempt: 2, after: 4),
            toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertEqual(state.statusText, "Disconnected (reconnecting)")
        XCTAssertFalse(state.showRetry, "an automatic exponential-backoff restart must not offer a redundant user Retry")
        XCTAssertFalse(state.showSignIn)
        XCTAssertFalse(state.showSignOut)
    }

    // MARK: - failed: Retry only, stderr tail of the current run only

    func test_failed_showsRetryAndStderrTail() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .failed(MCPConnectionFailure(reason: "command not found", stderrTail: "bash: foo: command not found\n")),
            toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertTrue(state.showRetry)
        XCTAssertFalse(state.showSignIn)
        XCTAssertFalse(state.showSignOut)
        XCTAssertEqual(state.stderrTail, "bash: foo: command not found\n")
    }

    func test_failed_stderrTail_isCurrentRunOnly_notAccumulatedAcrossCalls() {
        let first = MCPServerRowStatusResolver.resolve(
            connectionState: .failed(MCPConnectionFailure(reason: "e1", stderrTail: "first run\n")),
            toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )
        let second = MCPServerRowStatusResolver.resolve(
            connectionState: .failed(MCPConnectionFailure(reason: "e2", stderrTail: "second run\n")),
            toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertEqual(first.stderrTail, "first run\n")
        XCTAssertEqual(second.stderrTail, "second run\n")
        XCTAssertFalse(second.stderrTail?.contains("first run") ?? true)
    }

    func test_failed_alwaysOffersRetry_regardlessOfReason() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .failed(MCPConnectionFailure(reason: "crashed 5 times", stderrTail: "")),
            toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertTrue(state.showRetry)
    }

    func test_failed_nilStderrTail_isNilNotEmptyString() {
        let state = MCPServerRowStatusResolver.resolve(
            connectionState: .failed(MCPConnectionFailure(reason: "e", stderrTail: nil)),
            toolCount: 0, uiToolCount: 0, authState: .notRequired, ipcEnabled: true
        )

        XCTAssertNil(state.stderrTail)
    }

    // MARK: - IPC off banner

    func test_ipcDisabled_bannerVisible_regardlessOfServerPhase() {
        XCTAssertTrue(MCPServerRowStatusResolver.ipcOffBannerVisible(ipcEnabled: false))
    }

    func test_ipcEnabled_bannerHidden() {
        XCTAssertFalse(MCPServerRowStatusResolver.ipcOffBannerVisible(ipcEnabled: true))
    }

    // MARK: - Sign-in label (contract section 13a.1)

    func test_signInText_signedInWithoutAccount() {
        XCTAssertEqual(MCPServerRowStatusResolver.signInText(authState: .signedIn(account: nil)), "Signed in")
    }

    func test_signInText_signedInWithAccount() {
        XCTAssertEqual(MCPServerRowStatusResolver.signInText(authState: .signedIn(account: "me@example.com")), "Signed in as me@example.com")
    }

    func test_signInText_signedOutOrNotRequired_isNil() {
        XCTAssertNil(MCPServerRowStatusResolver.signInText(authState: .signedOut))
        XCTAssertNil(MCPServerRowStatusResolver.signInText(authState: .notRequired))
    }
}
