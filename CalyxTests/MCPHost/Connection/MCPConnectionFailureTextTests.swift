//
//  MCPConnectionFailureTextTests.swift
//  CalyxTests
//
//  `MCPConnectionFailureText` turns the error of a failed connection
//  attempt, and the child's exit when the transport was lost, into the
//  one sentence Settings shows as the row's status.
//

import XCTest
@testable import Calyx

final class MCPConnectionFailureTextTests: XCTestCase {

    private func connectFailure(
        _ error: any Error,
        exit: MCPTransportExitInfo? = nil,
        order: MCPHandshakeOrder = .initializeFirst
    ) -> String {
        MCPConnectionFailureText.connectFailure(error, exit: exit, requestTimeout: 60, handshakeOrder: order)
    }

    func test_handshakeTransportClosed_withExitStatus_namesTheStatus() {
        let error = MCPNegotiationError.handshakeFailed(
            initialize: .transportClosed(reason: "child exited with status 2"),
            discover: .transportClosed(reason: "transport closed")
        )
        XCTAssertEqual(connectFailure(error, exit: .exited(2)), "The server exited with status 2 during the handshake.")
    }

    func test_handshakeTransportClosed_exitStatus127_isCommandNotFound() {
        let error = MCPNegotiationError.handshakeFailed(initialize: .transportClosed(reason: "x"), discover: nil)
        XCTAssertEqual(connectFailure(error, exit: .exited(127)), "The command was not found (exit status 127).")
    }

    func test_handshakeTransportClosed_signal_namesTheSignal() {
        let error = MCPNegotiationError.handshakeFailed(initialize: .transportClosed(reason: "x"), discover: nil)
        XCTAssertEqual(connectFailure(error, exit: .signaled(9)), "The server was terminated by signal 9 during the handshake.")
    }

    func test_handshakeTimeout_namesTheTimeout() {
        let error = MCPNegotiationError.handshakeFailed(initialize: .timeout, discover: .timeout)
        XCTAssertEqual(connectFailure(error), "The server did not reply within 60 seconds during the handshake.")
    }

    func test_handshakeHTTPStatus_namesTheStatus_preferringTheFirstProbeOfTheOrder() {
        let error = MCPNegotiationError.handshakeFailed(
            initialize: .transport(MCPTransportSignal(httpStatus: 500, message: "server error")),
            discover: .transport(MCPTransportSignal(httpStatus: 502, message: "bad gateway"))
        )
        XCTAssertEqual(connectFailure(error, order: .discoverFirst), "The server answered HTTP 502 during the handshake.")
    }

    func test_transportClosed_isPreferredOverTheOtherProbe() {
        let error = MCPNegotiationError.handshakeFailed(
            initialize: .timeout,
            discover: .transportClosed(reason: "x")
        )
        XCTAssertEqual(connectFailure(error, exit: .exited(1)), "The server exited with status 1 during the handshake.")
    }

    func test_factoryFoundationError_usesItsLocalizedDescription() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: [
            NSLocalizedDescriptionKey: "The file “server” doesn’t exist.",
        ])
        XCTAssertEqual(connectFailure(error), "The server could not be started: The file “server” doesn’t exist.")
    }

    func test_connectionLost_withExit_namesTheStatusWithoutAPhase() {
        XCTAssertEqual(
            MCPConnectionFailureText.connectionLost(reason: "child exited with status 3", exit: .exited(3)),
            "The server exited with status 3."
        )
    }

    func test_transportWasLost_onlyForTransportClosedFailures() {
        XCTAssertTrue(MCPConnectionFailureText.transportWasLost(
            MCPNegotiationError.handshakeFailed(initialize: .timeout, discover: .transportClosed(reason: "x"))
        ))
        XCTAssertFalse(MCPConnectionFailureText.transportWasLost(
            MCPNegotiationError.handshakeFailed(initialize: .timeout, discover: .timeout)
        ))
        XCTAssertTrue(MCPConnectionFailureText.transportWasLost(MCPClientProtocolError.transportClosed(reason: "x")))
    }

    // MARK: - Sign-in failures

    func test_signInFailure_clientRegistrationUnavailable_namesTheIssuerAndTheClientIDField() {
        XCTAssertEqual(
            MCPConnectionFailureText.signInFailure(.clientRegistrationUnavailable(issuer: "https://github.com/login/oauth")),
            "https://github.com/login/oauth does not support automatic client registration. "
                + "Enter the client ID of an OAuth app registered with it in Edit."
        )
    }

    func test_signInFailure_everyCase_isASentence() {
        let cases: [(MCPOAuthFlowError, String)] = [
            (.needsAuthorization, "Sign in is required."),
            (.cancelled, "Sign in was cancelled."),
            (.portBusy(33418), "Port 33418 is in use."),
            (.pkceUnsupported, "The authorization server does not support PKCE with S256."),
            (.issuerMismatch, "The sign-in response did not come from the expected authorization server."),
            (.stateMismatch, "The sign-in response does not match the request Calyx sent."),
            (.discoveryFailed("protected resource metadata names no authorization server"),
             "The authorization server could not be found: protected resource metadata names no authorization server."),
            (.registrationFailed("registration endpoint returned HTTP 400"),
             "Client registration failed: registration endpoint returned HTTP 400."),
            (.authorizationFailed(error: "access_denied", description: nil),
             "The authorization server returned access_denied."),
            (.authorizationFailed(error: "access_denied", description: "The user denied access."),
             "The authorization server returned access_denied: The user denied access."),
            (.tokenEndpointFailed(error: "invalid_client", description: nil),
             "The token endpoint returned invalid_client."),
            (.tokenEndpointFailed(error: "invalid_client", description: "Client authentication failed"),
             "The token endpoint returned invalid_client: Client authentication failed."),
            (.storageFailed("keychain locked"), "The sign-in credentials could not be saved: keychain locked."),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(MCPConnectionFailureText.signInFailure(error), expected, "\(error)")
        }
    }

    func test_connectFailure_oauthFlowError_isTheSignInSentence() {
        XCTAssertEqual(
            connectFailure(MCPOAuthFlowError.tokenEndpointFailed(error: "invalid_client", description: nil)),
            "The token endpoint returned invalid_client."
        )
    }

    // MARK: - Supervisor failures

    func test_supervisorFailure_everyCase_isASentence() {
        let cases: [(MCPUpstreamSupervisorError, String)] = [
            (.unknownServer(MCPServerID()), "The server is no longer configured."),
            (.notHTTPServer(MCPServerID()), "Only HTTP servers can sign in."),
            (.invalidURL("not a url"), "\"not a url\" is not a valid URL."),
            (.missingSecret(name: "API_KEY"), "No stored value for API_KEY."),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(MCPConnectionFailureText.supervisorFailure(error), expected, "\(error)")
        }
    }
}
