//
//  MCPOAuthFlowTests.swift
//  CalyxTests
//
//  API contract section 6.14. `MCPOAuthFlow.authorize` is the single
//  entry point that runs PRM discovery, AS metadata discovery (PKCE
//  S256 required), starts the loopback listener (so the bound host and
//  port are known), client registration, PKCE, opening the browser,
//  the callback wait, RFC 9207 issuer validation, and the token
//  exchange, saving the result through `credentials`.
//
//    enum MCPOAuthFlowError: Error, Sendable, Equatable {
//        case needsAuthorization, clientRegistrationUnavailable(issuer: String), cancelled, portBusy(Int),
//             pkceUnsupported, issuerMismatch, stateMismatch, discoveryFailed(String), registrationFailed(String),
//             authorizationFailed(error: String, description: String?),
//             tokenEndpointFailed(error: String, description: String?), storageFailed(String)
//    }
//    protocol MCPOAuthCredentialStoring: Sendable {
//        func tokens(for serverID: MCPServerID) async throws -> MCPOAuthTokenSet?
//        func setTokens(_ tokens: MCPOAuthTokenSet?, for serverID: MCPServerID) async throws
//        func clientRegistration(for serverID: MCPServerID) async throws -> MCPOAuthStoredClient?
//        func setClientRegistration(_ client: MCPOAuthStoredClient?, for serverID: MCPServerID) async throws
//    }
//    struct MCPOAuthStoredClient: Sendable, Equatable, Codable {
//        let clientID: String; let tokenEndpoint: URL; let clientAuthentication: MCPOAuthClientAuthentication; let grantedScope: String?
//    }
//    actor MCPOAuthFlow {
//        init(
//            session: MCPHTTPSession,
//            discovery: MCPOAuthMetadataDiscovery,
//            registration: MCPOAuthClientRegistration,
//            browser: any MCPOAuthBrowserOpening,
//            redirectConfig: MCPOAuthRedirectConfig,
//            credentials: any MCPOAuthCredentialStoring
//        )
//        func authorize(
//            serverID: MCPServerID,
//            mcpServerURL: URL,
//            resourceMetadataHintURL: URL?,
//            preRegisteredClientID: String?,
//            clientAuthentication: MCPOAuthClientAuthentication,
//            scopeOverride: String?
//        ) async throws -> (tokens: MCPOAuthTokenSet, clientID: String, tokenEndpoint: URL)
//        func makeTransportHooks(serverID: MCPServerID, mcpServerURL: URL) -> MCPOAuthTransportHooks
//    }
//
//  Section 6.14's step order: PRM -> AS metadata (S256 required, else
//  .pkceUnsupported) -> LoopbackRedirectListener.start() (before
//  registration, so the bound host/port is known) -> client
//  registration (DCR's redirect_uris are the four fixed plan §2 URIs:
//  http://127.0.0.1/callback, http://localhost/callback,
//  http://127.0.0.1:41890/callback, http://localhost:41890/callback,
//  independent of which port the listener actually bound; RFC 8252
//  7.3 lets the AS accept any loopback port at the redirect step) ->
//  PKCE -> open the authorization URL (using the actually bound
//  host/port) -> waitForCallback -> issuer validation -> token
//  exchange -> save through `credentials`, keyed by the `serverID`
//  `authorize` was called with (one shared `MCPOAuthFlow` instance
//  serves every configured server).
//

import XCTest
@testable import Calyx

final class MCPOAuthFlowTests: XCTestCase {

    private var recorder: MCPHTTPStubRecorder!
    private var urlSession: URLSession!
    private var httpSession: MCPHTTPSession!

    override func setUp() {
        super.setUp()
        recorder = MCPHTTPStubRecorder()
        urlSession = URLSession(configuration: MCPHTTPStubProtocol.configuration(recorder: recorder))
        httpSession = MCPHTTPSession(urlSession: urlSession)
    }

    override func tearDown() {
        httpSession = nil
        urlSession = nil
        recorder = nil
        super.tearDown()
    }

    private func makeFlow(
        browser: FakeMCPOAuthBrowserOpening,
        registrationStore: InMemoryMCPOAuthClientRegistrationStore = InMemoryMCPOAuthClientRegistrationStore(),
        credentials: InMemoryMCPOAuthCredentialStore = InMemoryMCPOAuthCredentialStore(),
        redirectConfig: MCPOAuthRedirectConfig = MCPOAuthRedirectConfig(host: .loopback, port: .random)
    ) -> MCPOAuthFlow {
        MCPOAuthFlow(
            session: httpSession,
            discovery: MCPOAuthMetadataDiscovery(session: httpSession),
            registration: MCPOAuthClientRegistration(session: httpSession, store: registrationStore),
            browser: browser,
            redirectConfig: redirectConfig,
            credentials: credentials
        )
    }

    private func formParams(from data: Data) -> [String: String] {
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: bodyString.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
    }

    private func queryParams(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func enqueuePRM(resource: String = "https://mcp.example.com/mcp", authorizationServers: [String] = ["https://auth.example.com"], scopesSupported: [String]? = nil) {
        recorder.enqueue { request in
            XCTAssertEqual(request.url.path, "/.well-known/oauth-protected-resource/mcp")
            var object: [String: Any] = ["resource": resource, "authorization_servers": authorizationServers]
            if let scopesSupported { object["scopes_supported"] = scopesSupported }
            let body = try! JSONSerialization.data(withJSONObject: object)
            return .json(status: 200, body: body)
        }
    }

    private func enqueueASMetadata(
        issuer: String = "https://auth.example.com",
        codeChallengeMethods: [String]? = ["S256"],
        registrationEndpoint: String? = nil,
        cimdSupported: Bool? = nil,
        issParameterSupported: Bool? = nil
    ) {
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, "\(issuer)/.well-known/oauth-authorization-server")
            var object: [String: Any] = [
                "issuer": issuer,
                "authorization_endpoint": "\(issuer)/authorize",
                "token_endpoint": "\(issuer)/token",
            ]
            if let codeChallengeMethods { object["code_challenge_methods_supported"] = codeChallengeMethods }
            if let registrationEndpoint { object["registration_endpoint"] = registrationEndpoint }
            if let cimdSupported { object["client_id_metadata_document_supported"] = cimdSupported }
            if let issParameterSupported { object["authorization_response_iss_parameter_supported"] = issParameterSupported }
            let body = try! JSONSerialization.data(withJSONObject: object)
            return .json(status: 200, body: body)
        }
    }

    private func enqueueTokenExchange(accessToken: String, expiresIn: Int = 3600, endpoint: String = "https://auth.example.com/token") {
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, endpoint)
            let body = try! JSONSerialization.data(withJSONObject: ["access_token": accessToken, "token_type": "Bearer", "expires_in": expiresIn])
            return .json(status: 200, body: body)
        }
    }

    /// Fires the loopback callback the browser would have delivered,
    /// via the real network stack (never the stubbed session).
    private func fireCallback(redirectURI: String, code: String, state: String, iss: String? = nil) async throws {
        var components = try XCTUnwrap(URLComponents(string: redirectURI))
        var items = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "state", value: state)]
        if let iss { items.append(URLQueryItem(name: "iss", value: iss)) }
        components.queryItems = items
        let callbackURL = try XCTUnwrap(components.url)
        _ = try? await URLSession.shared.data(from: callbackURL)
    }

    // MARK: - End-to-end: PRM -> AS metadata -> registration -> PKCE -> browser -> callback -> token exchange

    func test_authorize_endToEnd_withPreRegisteredClientID_completesAndCrossLinksPKCE() async throws {
        enqueuePRM()
        enqueueASMetadata()
        enqueueTokenExchange(accessToken: "access-abc")

        let serverID = MCPServerID()
        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        async let outcome = flow.authorize(
            serverID: serverID,
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        XCTAssertEqual(query["client_id"], "preregistered-client-id")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        let state = try XCTUnwrap(query["state"])
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        let codeChallenge = try XCTUnwrap(query["code_challenge"])

        try await fireCallback(redirectURI: redirectURI, code: "auth-code-e2e", state: state)

        let (tokens, clientID, tokenEndpoint) = try await outcome
        XCTAssertEqual(tokens.accessToken, "access-abc")
        XCTAssertEqual(clientID, "preregistered-client-id")
        XCTAssertEqual(tokenEndpoint, URL(string: "https://auth.example.com/token")!)

        XCTAssertEqual(recorder.requests.map(\.url.path), ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server", "/token"])

        let tokenRequest = try XCTUnwrap(recorder.requests.last)
        let params = formParams(from: try XCTUnwrap(tokenRequest.bodyData))
        let verifier = try XCTUnwrap(params["code_verifier"])
        XCTAssertEqual(MCPOAuthPKCE.codeChallenge(forVerifier: verifier), codeChallenge, "the verifier sent to the token endpoint must hash to the challenge sent to the authorization endpoint")
        XCTAssertEqual(params["redirect_uri"]?.removingPercentEncoding, redirectURI, "the redirect_uri sent to the token endpoint must match the one used in the authorization URL")
    }

    // MARK: - .needsUserInput registration outcome surfaces as MCPOAuthFlowError.clientRegistrationUnavailable

    func test_authorize_registrationNeedsUserInput_throwsClientRegistrationUnavailableWithTheIssuer_withoutOpeningBrowser() async throws {
        enqueuePRM()
        enqueueASMetadata()

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        do {
            _ = try await flow.authorize(
                serverID: MCPServerID(),
                mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
                resourceMetadataHintURL: nil,
                preRegisteredClientID: nil,
                clientAuthentication: .none,
                scopeOverride: nil
            )
            XCTFail("expected clientRegistrationUnavailable")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .clientRegistrationUnavailable(issuer: "https://auth.example.com"))
        }

        let openedCount = await browser.openedURLCount()
        XCTAssertEqual(openedCount, 0, "no registration endpoint and no CIMD/pre-registration means the browser must never open")
    }

    // MARK: - .random port: DCR always registers the four fixed plan URIs; the authorization URL uses the actually bound port

    func test_authorize_randomPort_dcrUsesFourPlanRedirectURIs_authorizationURLUsesActuallyBoundPort() async throws {
        enqueuePRM()
        enqueueASMetadata(registrationEndpoint: "https://auth.example.com/register", cimdSupported: false)
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, "https://auth.example.com/register")
            XCTAssertEqual(request.method, "POST")
            let body = try! JSONSerialization.data(withJSONObject: ["client_id": "dcr-client-id"])
            return .json(status: 201, body: body)
        }
        enqueueTokenExchange(accessToken: "access-random-port")

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser, redirectConfig: MCPOAuthRedirectConfig(host: .loopback, port: .random))

        async let outcome = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: nil,
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        let redirectURIComponents = try XCTUnwrap(URLComponents(string: redirectURI))
        XCTAssertEqual(redirectURIComponents.host, "127.0.0.1")
        let boundPort = try XCTUnwrap(redirectURIComponents.port)
        XCTAssertGreaterThan(boundPort, 0)
        XCTAssertNotEqual(boundPort, MCPOAuthRedirectConfig.calyxFixedPort, "a .random port config must not reuse the fixed 41890 port")

        let state = try XCTUnwrap(query["state"])
        try await fireCallback(redirectURI: redirectURI, code: "auth-code-random-port", state: state)

        let (tokens, clientID, _) = try await outcome
        XCTAssertEqual(tokens.accessToken, "access-random-port")
        XCTAssertEqual(clientID, "dcr-client-id")

        XCTAssertEqual(recorder.requests.map(\.url.path), ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server", "/register", "/token"])

        let dcrRequest = try XCTUnwrap(recorder.requests.dropFirst(2).first)
        let dcrObject = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(dcrRequest.bodyData)) as? [String: Any])
        let redirectURIs = try XCTUnwrap(dcrObject["redirect_uris"] as? [String])
        XCTAssertEqual(redirectURIs.count, 4)
        XCTAssertEqual(Set(redirectURIs), [
            "http://127.0.0.1/callback",
            "http://localhost/callback",
            "http://127.0.0.1:41890/callback",
            "http://localhost:41890/callback",
        ], "DCR always registers the four fixed plan section 2 loopback URIs, independent of the port the listener actually bound")
    }

    // MARK: - A per-server redirect config overrides the one the flow was built with (section 13a.1)

    func test_authorize_redirectOverride_reachesTheListener() async throws {
        enqueuePRM()
        enqueueASMetadata()
        enqueueTokenExchange(accessToken: "access-override")

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser, redirectConfig: MCPOAuthRedirectConfig(host: .loopback, port: .random))

        async let outcome = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil,
            redirect: MCPOAuthRedirectConfig(host: .localhost, port: .random)
        )

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        XCTAssertEqual(URLComponents(string: redirectURI)?.host, "localhost",
                       "the listener binds the overriding config's host, not the flow's 127.0.0.1")

        try await fireCallback(redirectURI: redirectURI, code: "auth-code-override-redirect", state: try XCTUnwrap(query["state"]))
        let (tokens, _, _) = try await outcome
        XCTAssertEqual(tokens.accessToken, "access-override")
    }

    // MARK: - AS advertises no S256: .pkceUnsupported, before the listener/browser are ever touched

    func test_authorize_asAdvertisesNoS256_throwsPkceUnsupported_withoutOpeningBrowser() async throws {
        enqueuePRM()
        enqueueASMetadata(codeChallengeMethods: ["plain"])

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        do {
            _ = try await flow.authorize(
                serverID: MCPServerID(),
                mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
                resourceMetadataHintURL: nil,
                preRegisteredClientID: "preregistered-client-id",
                clientAuthentication: .none,
                scopeOverride: nil
            )
            XCTFail("expected pkceUnsupported")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .pkceUnsupported)
        }

        let openedCount = await browser.openedURLCount()
        XCTAssertEqual(openedCount, 0)
        XCTAssertEqual(recorder.requests.map(\.url.path), ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-authorization-server"])
    }

    // MARK: - RFC 9207 iss mismatch: .issuerMismatch, no token exchange

    func test_authorize_issAdvertisedAndMismatched_throwsIssuerMismatch_withoutTokenExchange() async throws {
        enqueuePRM()
        enqueueASMetadata(issParameterSupported: true)

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        async let outcome: (tokens: MCPOAuthTokenSet, clientID: String, tokenEndpoint: URL) = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        let state = try XCTUnwrap(query["state"])
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        try await fireCallback(redirectURI: redirectURI, code: "auth-code-bad-iss", state: state, iss: "https://attacker.example.com")

        do {
            _ = try await outcome
            XCTFail("expected issuerMismatch")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .issuerMismatch)
        }
        XCTAssertFalse(recorder.requests.map(\.url.path).contains("/token"), "an iss mismatch must abort before the token exchange")
    }

    // MARK: - RFC 9207 iss advertised but absent from the callback: also .issuerMismatch

    func test_authorize_issAdvertisedButMissingFromCallback_throwsIssuerMismatch_withoutTokenExchange() async throws {
        enqueuePRM()
        enqueueASMetadata(issParameterSupported: true)

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        async let outcome: (tokens: MCPOAuthTokenSet, clientID: String, tokenEndpoint: URL) = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        let state = try XCTUnwrap(query["state"])
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        try await fireCallback(redirectURI: redirectURI, code: "auth-code-no-iss", state: state, iss: nil)

        do {
            _ = try await outcome
            XCTFail("expected issuerMismatch")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .issuerMismatch)
        }
        XCTAssertFalse(recorder.requests.map(\.url.path).contains("/token"))
    }

    // MARK: - Listener state mismatch surfaces as .stateMismatch, no token exchange

    func test_authorize_callbackWrongState_throwsStateMismatch_withoutTokenExchange() async throws {
        enqueuePRM()
        enqueueASMetadata()

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        async let outcome: (tokens: MCPOAuthTokenSet, clientID: String, tokenEndpoint: URL) = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        try await fireCallback(redirectURI: redirectURI, code: "auth-code-wrong-state", state: "not-the-real-state")

        do {
            _ = try await outcome
            XCTFail("expected stateMismatch")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .stateMismatch)
        }
        XCTAssertFalse(recorder.requests.map(\.url.path).contains("/token"))
    }

    // MARK: - makeTransportHooks: headerProvider

    func test_makeTransportHooks_headerProvider_freshStoredTokens_returnsBearerWithoutNetworkCall() async throws {
        let serverID = MCPServerID()
        let credentials = InMemoryMCPOAuthCredentialStore()
        try await credentials.setTokens(MCPOAuthTokenSet(accessToken: "abc", refreshToken: "ref-1", expiresAt: .distantFuture, scope: "files:read"), for: serverID)
        try await credentials.setClientRegistration(MCPOAuthStoredClient(clientID: "cid", tokenEndpoint: URL(string: "https://auth.example.com/token")!, clientAuthentication: .none, grantedScope: "files:read"), for: serverID)

        let flow = makeFlow(browser: FakeMCPOAuthBrowserOpening(), credentials: credentials)
        let hooks = await flow.makeTransportHooks(serverID: serverID, mcpServerURL: URL(string: "https://mcp.example.com/mcp")!)

        let header = try await hooks.headerProvider()
        XCTAssertEqual(header, "abc")
        XCTAssertEqual(recorder.requests.count, 0, "a still-valid stored token must not trigger a refresh request")
    }

    func test_makeTransportHooks_headerProvider_expiredStoredTokens_refreshesAndSavesBeforeReturning() async throws {
        let serverID = MCPServerID()
        let credentials = InMemoryMCPOAuthCredentialStore()
        try await credentials.setTokens(MCPOAuthTokenSet(accessToken: "old", refreshToken: "ref-1", expiresAt: Date(timeIntervalSince1970: 0), scope: "files:read"), for: serverID)
        try await credentials.setClientRegistration(MCPOAuthStoredClient(clientID: "cid", tokenEndpoint: URL(string: "https://auth.example.com/token")!, clientAuthentication: .none, grantedScope: "files:read"), for: serverID)
        enqueueTokenExchange(accessToken: "new")

        let flow = makeFlow(browser: FakeMCPOAuthBrowserOpening(), credentials: credentials)
        let hooks = await flow.makeTransportHooks(serverID: serverID, mcpServerURL: URL(string: "https://mcp.example.com/mcp")!)

        let header = try await hooks.headerProvider()
        XCTAssertEqual(header, "new")

        let request = try XCTUnwrap(recorder.requests.first)
        let params = formParams(from: try XCTUnwrap(request.bodyData))
        XCTAssertEqual(params["grant_type"], "refresh_token")

        let saved = try await credentials.tokens(for: serverID)
        XCTAssertEqual(saved?.accessToken, "new", "the refreshed token must be saved back through credentials")
    }

    func test_makeTransportHooks_headerProvider_noStoredTokens_throwsNeedsAuthorization() async throws {
        let serverID = MCPServerID()
        let flow = makeFlow(browser: FakeMCPOAuthBrowserOpening())
        let hooks = await flow.makeTransportHooks(serverID: serverID, mcpServerURL: URL(string: "https://mcp.example.com/mcp")!)

        do {
            _ = try await hooks.headerProvider()
            XCTFail("expected needsAuthorization")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .needsAuthorization)
        }
    }

    // MARK: - makeTransportHooks: on401

    func test_makeTransportHooks_on401_refreshesAndSavesTokens() async throws {
        let serverID = MCPServerID()
        let credentials = InMemoryMCPOAuthCredentialStore()
        try await credentials.setTokens(MCPOAuthTokenSet(accessToken: "old", refreshToken: "ref-1", expiresAt: nil, scope: nil), for: serverID)
        try await credentials.setClientRegistration(MCPOAuthStoredClient(clientID: "cid", tokenEndpoint: URL(string: "https://auth.example.com/token")!, clientAuthentication: .none, grantedScope: nil), for: serverID)
        enqueueTokenExchange(accessToken: "after-401")

        let flow = makeFlow(browser: FakeMCPOAuthBrowserOpening(), credentials: credentials)
        let hooks = await flow.makeTransportHooks(serverID: serverID, mcpServerURL: URL(string: "https://mcp.example.com/mcp")!)

        try await hooks.on401()

        let saved = try await credentials.tokens(for: serverID)
        XCTAssertEqual(saved?.accessToken, "after-401")
    }

    func test_makeTransportHooks_on401_invalidGrant_throwsNeedsAuthorization() async throws {
        let serverID = MCPServerID()
        let credentials = InMemoryMCPOAuthCredentialStore()
        try await credentials.setTokens(MCPOAuthTokenSet(accessToken: "old", refreshToken: "ref-1", expiresAt: nil, scope: nil), for: serverID)
        try await credentials.setClientRegistration(MCPOAuthStoredClient(clientID: "cid", tokenEndpoint: URL(string: "https://auth.example.com/token")!, clientAuthentication: .none, grantedScope: nil), for: serverID)
        recorder.enqueue { _ in .json(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)) }

        let flow = makeFlow(browser: FakeMCPOAuthBrowserOpening(), credentials: credentials)
        let hooks = await flow.makeTransportHooks(serverID: serverID, mcpServerURL: URL(string: "https://mcp.example.com/mcp")!)

        do {
            try await hooks.on401()
            XCTFail("expected needsAuthorization")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .needsAuthorization)
        }
    }

    // MARK: - makeTransportHooks: on403InsufficientScope re-authorizes with the merged scope

    func test_makeTransportHooks_on403InsufficientScope_reauthorizesWithMergedScope() async throws {
        let serverID = MCPServerID()
        let credentials = InMemoryMCPOAuthCredentialStore()
        try await credentials.setClientRegistration(MCPOAuthStoredClient(clientID: "cid", tokenEndpoint: URL(string: "https://auth.example.com/token")!, clientAuthentication: .none, grantedScope: "files:read"), for: serverID)
        // Seed the same "previously granted" scope under both plausible sources
        // (the stored client and the stored tokens) so the assertion holds
        // regardless of which one the implementation reads from.
        try await credentials.setTokens(MCPOAuthTokenSet(accessToken: "old", refreshToken: nil, expiresAt: nil, scope: "files:read"), for: serverID)

        enqueuePRM()
        // CIMD advertised and no registration_endpoint so the re-authorize's client
        // resolution (store vs. CIMD) does not affect this assertion either way.
        enqueueASMetadata(cimdSupported: true)
        enqueueTokenExchange(accessToken: "access-stepped-up")

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser, credentials: credentials)
        let hooks = await flow.makeTransportHooks(serverID: serverID, mcpServerURL: URL(string: "https://mcp.example.com/mcp")!)

        async let stepUp = hooks.on403InsufficientScope("files:write")

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        let scopeParam = try XCTUnwrap(query["scope"])
        XCTAssertEqual(Set(scopeParam.split(separator: " ").map(String.init)), ["files:read", "files:write"], "the re-authorization scope must be the union of the previously granted and challenge scopes")

        let state = try XCTUnwrap(query["state"])
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        try await fireCallback(redirectURI: redirectURI, code: "auth-code-stepup", state: state)

        try await stepUp

        let saved = try await credentials.tokens(for: serverID)
        XCTAssertEqual(saved?.accessToken, "access-stepped-up", "the re-authorized tokens from the scope step-up must be saved back through credentials")
    }

    // MARK: - Step-up uses the redirect config the hooks were made with (decision V66)

    func test_makeTransportHooks_on403InsufficientScope_usesTheServersRedirectConfig() async throws {
        let serverID = MCPServerID()
        let credentials = InMemoryMCPOAuthCredentialStore()
        try await credentials.setClientRegistration(MCPOAuthStoredClient(clientID: "cid", tokenEndpoint: URL(string: "https://auth.example.com/token")!, clientAuthentication: .none, grantedScope: "files:read"), for: serverID)
        try await credentials.setTokens(MCPOAuthTokenSet(accessToken: "old", refreshToken: nil, expiresAt: nil, scope: "files:read"), for: serverID)
        enqueuePRM()
        enqueueASMetadata(cimdSupported: true)
        enqueueTokenExchange(accessToken: "access-stepped-up-redirect")

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser, credentials: credentials, redirectConfig: MCPOAuthRedirectConfig(host: .loopback, port: .random))
        let hooks = await flow.makeTransportHooks(
            serverID: serverID,
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            redirect: MCPOAuthRedirectConfig(host: .localhost, port: .random)
        )

        async let stepUp = hooks.on403InsufficientScope("files:write")

        let query = queryParams(of: await browser.nextOpenedURL())
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        XCTAssertEqual(URLComponents(string: redirectURI)?.host, "localhost",
                       "the step-up listener binds the server's redirect config, as the first sign-in did")
        try await fireCallback(redirectURI: redirectURI, code: "auth-code-stepup-redirect", state: try XCTUnwrap(query["state"]))
        try await stepUp
    }

    // MARK: - authorize saves tokens and the stored client through credentials, keyed by serverID

    func test_authorize_savesTokensAndStoredClient_throughCredentials_keyedByServerID() async throws {
        enqueuePRM()
        enqueueASMetadata()
        enqueueTokenExchange(accessToken: "access-saved")

        let serverID = MCPServerID()
        let credentials = InMemoryMCPOAuthCredentialStore()
        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser, credentials: credentials)

        async let outcome = flow.authorize(
            serverID: serverID,
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let openedURL = await browser.nextOpenedURL()
        let query = queryParams(of: openedURL)
        let state = try XCTUnwrap(query["state"])
        let redirectURI = try XCTUnwrap(query["redirect_uri"])
        try await fireCallback(redirectURI: redirectURI, code: "auth-code-saved", state: state)

        let (tokens, clientID, tokenEndpoint) = try await outcome

        let savedTokens = try await credentials.tokens(for: serverID)
        XCTAssertEqual(savedTokens?.accessToken, tokens.accessToken)
        XCTAssertEqual(savedTokens?.accessToken, "access-saved")

        let savedClient = try await credentials.clientRegistration(for: serverID)
        XCTAssertEqual(savedClient?.clientID, clientID)
        XCTAssertEqual(savedClient?.clientID, "preregistered-client-id")
        XCTAssertEqual(savedClient?.tokenEndpoint, tokenEndpoint)
        XCTAssertEqual(savedClient?.clientAuthentication, MCPOAuthClientAuthentication.none)

        // A different serverID must never see these credentials.
        let unrelatedServerID = MCPServerID()
        let unrelatedTokens = try await credentials.tokens(for: unrelatedServerID)
        XCTAssertNil(unrelatedTokens)
    }

    // MARK: - Scope selection: scopeOverride absent -> every scopes_supported value; override wins

    func test_authorize_noScopeOverride_requestsAllScopesSupportedFromPRM() async throws {
        enqueuePRM(scopesSupported: ["files:read", "profile"])
        enqueueASMetadata()
        enqueueTokenExchange(accessToken: "access-scoped")

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        async let outcome = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let query = queryParams(of: await browser.nextOpenedURL())
        XCTAssertEqual(query["scope"], "files:read profile")
        try await fireCallback(redirectURI: try XCTUnwrap(query["redirect_uri"]), code: "auth-code-scoped", state: try XCTUnwrap(query["state"]))
        _ = try await outcome
    }

    func test_authorize_scopeOverride_winsOverScopesSupported() async throws {
        enqueuePRM(scopesSupported: ["files:read", "profile"])
        enqueueASMetadata()
        enqueueTokenExchange(accessToken: "access-override")

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        async let outcome = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: "files:write"
        )

        let query = queryParams(of: await browser.nextOpenedURL())
        XCTAssertEqual(query["scope"], "files:write")
        try await fireCallback(redirectURI: try XCTUnwrap(query["redirect_uri"]), code: "auth-code-override", state: try XCTUnwrap(query["state"]))
        _ = try await outcome
    }

    // MARK: - Error redirect surfaces as .authorizationFailed, no token exchange

    func test_authorize_errorRedirect_throwsAuthorizationFailed_withoutTokenExchange() async throws {
        enqueuePRM()
        enqueueASMetadata()

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = makeFlow(browser: browser)

        async let outcome: (tokens: MCPOAuthTokenSet, clientID: String, tokenEndpoint: URL) = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let query = queryParams(of: await browser.nextOpenedURL())
        var components = try XCTUnwrap(URLComponents(string: try XCTUnwrap(query["redirect_uri"])))
        components.queryItems = [
            URLQueryItem(name: "error", value: "access_denied"),
            URLQueryItem(name: "error_description", value: "User denied"),
            URLQueryItem(name: "state", value: try XCTUnwrap(query["state"])),
        ]
        _ = try? await URLSession.shared.data(from: try XCTUnwrap(components.url))

        do {
            _ = try await outcome
            XCTFail("expected authorizationFailed")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .authorizationFailed(error: "access_denied", description: "User denied"))
        }
        XCTAssertFalse(recorder.requests.map(\.url.path).contains("/token"))
    }

    // MARK: - A throwing credential store surfaces as .storageFailed

    func test_authorize_credentialStoreThrows_throwsStorageFailed() async throws {
        enqueuePRM()
        enqueueASMetadata()
        enqueueTokenExchange(accessToken: "access-unsaved")

        let browser = FakeMCPOAuthBrowserOpening()
        let flow = MCPOAuthFlow(
            session: httpSession,
            discovery: MCPOAuthMetadataDiscovery(session: httpSession),
            registration: MCPOAuthClientRegistration(session: httpSession, store: InMemoryMCPOAuthClientRegistrationStore()),
            browser: browser,
            redirectConfig: MCPOAuthRedirectConfig(host: .loopback, port: .random),
            credentials: FailingMCPOAuthCredentialStore()
        )

        async let outcome: (tokens: MCPOAuthTokenSet, clientID: String, tokenEndpoint: URL) = flow.authorize(
            serverID: MCPServerID(),
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: "preregistered-client-id",
            clientAuthentication: .none,
            scopeOverride: nil
        )

        let query = queryParams(of: await browser.nextOpenedURL())
        try await fireCallback(redirectURI: try XCTUnwrap(query["redirect_uri"]), code: "auth-code-unsaved", state: try XCTUnwrap(query["state"]))

        do {
            _ = try await outcome
            XCTFail("expected storageFailed")
        } catch let error as MCPOAuthFlowError {
            guard case .storageFailed = error else {
                XCTFail("expected storageFailed, got \(error)")
                return
            }
        }
    }
}

/// `MCPOAuthCredentialStoring` whose every call throws.
private struct FailingMCPOAuthCredentialStore: MCPOAuthCredentialStoring {
    struct StoreUnavailable: Error {}

    func tokens(for serverID: MCPServerID) async throws -> MCPOAuthTokenSet? { throw StoreUnavailable() }
    func setTokens(_ tokens: MCPOAuthTokenSet?, for serverID: MCPServerID) async throws { throw StoreUnavailable() }
    func clientRegistration(for serverID: MCPServerID) async throws -> MCPOAuthStoredClient? { throw StoreUnavailable() }
    func setClientRegistration(_ client: MCPOAuthStoredClient?, for serverID: MCPServerID) async throws { throw StoreUnavailable() }
}
