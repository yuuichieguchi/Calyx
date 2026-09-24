//
//  MCPOAuthFlow.swift
//  Calyx
//
//  The single entry point of OAuth for MCP servers: protected resource and
//  authorization server discovery, the loopback redirect listener, client
//  registration, PKCE, the browser, RFC 9207 issuer validation and the code
//  exchange, with the result saved through `MCPOAuthCredentialStoring`.
//  Also builds the hooks an HTTP transport uses to attach, refresh and step
//  up tokens. One instance serves every configured server, keyed by
//  `MCPServerID`.
//

import Foundation

actor MCPOAuthFlow {

    private static let callbackPath = "/callback"

    /// Registered with Dynamic Client Registration regardless of the port
    /// the listener binds; RFC 8252 section 7.3 has the authorization
    /// server accept any port on a loopback redirect URI. The same four
    /// URIs are in the Client ID Metadata Document.
    private static let registeredRedirectURIs = [
        "http://127.0.0.1\(callbackPath)",
        "http://localhost\(callbackPath)",
        "http://127.0.0.1:\(MCPOAuthRedirectConfig.calyxFixedPort)\(callbackPath)",
        "http://localhost:\(MCPOAuthRedirectConfig.calyxFixedPort)\(callbackPath)",
    ]

    private let session: MCPHTTPSession
    private let discovery: MCPOAuthMetadataDiscovery
    private let registration: MCPOAuthClientRegistration
    private let browser: any MCPOAuthBrowserOpening
    private let redirectConfig: MCPOAuthRedirectConfig
    private let credentials: any MCPOAuthCredentialStoring

    /// The listener of each sign-in in progress. A new sign-in for the same
    /// server cancels the previous one's listener.
    private var activeListeners: [MCPServerID: LoopbackRedirectListener] = [:]
    /// The refresh in flight for each server. Concurrent callers share it,
    /// so a rotated refresh token is never sent twice.
    private var refreshTasks: [MCPServerID: Task<MCPOAuthTokenSet, any Error>] = [:]

    init(
        session: MCPHTTPSession,
        discovery: MCPOAuthMetadataDiscovery,
        registration: MCPOAuthClientRegistration,
        browser: any MCPOAuthBrowserOpening,
        redirectConfig: MCPOAuthRedirectConfig,
        credentials: any MCPOAuthCredentialStoring
    ) {
        self.session = session
        self.discovery = discovery
        self.registration = registration
        self.browser = browser
        self.redirectConfig = redirectConfig
        self.credentials = credentials
    }

    // MARK: - Authorization

    /// Runs the whole authorization code flow for `serverID` and saves the
    /// tokens and the client through `credentials`. Every failure is an
    /// `MCPOAuthFlowError`.
    ///
    /// `scopeOverride` is the requested scope when given; a caller holding a
    /// `WWW-Authenticate` challenge passes the challenge's scope here.
    /// Otherwise every value of the protected resource's `scopes_supported`
    /// is requested, and without that the `scope` parameter is omitted.
    ///
    /// `redirect` is the server's own listener config (for example the
    /// fixed Calyx port); nil uses the config this flow was built with.
    func authorize(
        serverID: MCPServerID,
        mcpServerURL: URL,
        resourceMetadataHintURL: URL?,
        preRegisteredClientID: String?,
        clientAuthentication: MCPOAuthClientAuthentication,
        scopeOverride: String?,
        redirect: MCPOAuthRedirectConfig? = nil
    ) async throws -> (tokens: MCPOAuthTokenSet, clientID: String, tokenEndpoint: URL) {
        let canonicalResourceURI = try Self.canonicalResourceURI(of: mcpServerURL)

        let resourceMetadata: MCPOAuthProtectedResourceMetadata
        let serverMetadata: MCPOAuthAuthorizationServerMetadata
        do {
            resourceMetadata = try await discovery.discoverProtectedResourceMetadata(
                mcpServerURL: mcpServerURL,
                resourceMetadataHintURL: resourceMetadataHintURL,
                canonicalResourceURI: canonicalResourceURI
            )
            guard let issuer = resourceMetadata.authorizationServers.first.flatMap({ URL(string: $0) }) else {
                throw MCPOAuthFlowError.discoveryFailed("protected resource metadata names no authorization server")
            }
            serverMetadata = try await discovery.discoverAuthorizationServerMetadata(issuer: issuer)
        } catch {
            throw Self.discoveryError(error)
        }
        guard let authorizationEndpoint = URL(string: serverMetadata.authorizationEndpoint),
              let tokenEndpoint = URL(string: serverMetadata.tokenEndpoint)
        else {
            throw MCPOAuthFlowError.discoveryFailed("authorization server metadata has an invalid endpoint")
        }
        let requestedScope = scopeOverride ?? Self.joinedScope(resourceMetadata.scopesSupported)

        // The listener checks `state`, so it is generated before the listener.
        let state = MCPOAuthPKCE.generateState()
        let listener = LoopbackRedirectListener(config: redirect ?? redirectConfig, expectedState: state, path: Self.callbackPath)
        if let previous = activeListeners.updateValue(listener, forKey: serverID) {
            await previous.cancel(reason: "replaced by a new sign-in")
        }

        do {
            let bound: (port: Int, host: String)
            do {
                bound = try await listener.start()
            } catch let error as MCPOAuthRedirectListenerError {
                throw Self.flowError(error)
            }
            let redirectURI = "http://\(bound.host):\(bound.port)\(Self.callbackPath)"

            let clientID = try await resolveClientID(serverMetadata: serverMetadata, preRegisteredClientID: preRegisteredClientID)

            let verifier = MCPOAuthPKCE.generateVerifier()
            let authorizationURL = MCPOAuthAuthorizationRequestBuilder.buildURL(
                authorizationEndpoint: authorizationEndpoint,
                clientID: clientID,
                redirectURI: redirectURI,
                codeChallenge: MCPOAuthPKCE.codeChallenge(forVerifier: verifier),
                state: state,
                canonicalResourceURI: canonicalResourceURI,
                scope: requestedScope
            )
            await browser.open(authorizationURL)

            let callback = try await waitForCallback(listener)
            if case .failure = MCPOAuthIssuerValidator.validate(
                issuerParameter: callback.iss,
                recordedIssuer: serverMetadata.issuer,
                serverAdvertisesIss: serverMetadata.authorizationResponseIssParameterSupported == true
            ) {
                throw MCPOAuthFlowError.issuerMismatch
            }

            let tokenClient = MCPOAuthTokenClient(
                session: session,
                tokenEndpoint: tokenEndpoint,
                clientID: clientID,
                clientAuthentication: clientAuthentication,
                canonicalResourceURI: canonicalResourceURI
            )
            let tokens: MCPOAuthTokenSet
            do {
                tokens = try await tokenClient.exchangeCode(callback.code, verifier: verifier, redirectURI: redirectURI, canonicalResourceURI: canonicalResourceURI)
            } catch let error as MCPOAuthFlowError {
                throw error
            } catch {
                throw Task.isCancelled
                    ? MCPOAuthFlowError.cancelled
                    : MCPOAuthFlowError.tokenEndpointFailed(error: "request_failed", description: String(describing: error))
            }

            // RFC 6749 section 5.1: an omitted `scope` equals the requested one.
            let storedClient = MCPOAuthStoredClient(
                clientID: clientID,
                tokenEndpoint: tokenEndpoint,
                clientAuthentication: clientAuthentication,
                grantedScope: tokens.scope ?? requestedScope
            )
            let credentials = self.credentials
            try await Self.storing {
                try await credentials.setTokens(tokens, for: serverID)
                try await credentials.setClientRegistration(storedClient, for: serverID)
            }
            await endSignIn(listener, serverID: serverID, reason: "sign-in finished")
            return (tokens, clientID, tokenEndpoint)
        } catch {
            await endSignIn(listener, serverID: serverID, reason: "sign-in failed")
            throw error
        }
    }

    // MARK: - Transport Hooks

    /// Hooks reading the tokens and client `authorize` saved for `serverID`.
    /// `redirect` is the server's listener config, used again by a scope
    /// step-up; nil uses the config this flow was built with.
    func makeTransportHooks(serverID: MCPServerID, mcpServerURL: URL, redirect: MCPOAuthRedirectConfig? = nil) -> MCPOAuthTransportHooks {
        MCPOAuthTransportHooks(
            headerProvider: {
                try await self.currentTokens(serverID: serverID, mcpServerURL: mcpServerURL, forceRefresh: false).accessToken
            },
            on401: {
                do {
                    _ = try await self.currentTokens(serverID: serverID, mcpServerURL: mcpServerURL, forceRefresh: true)
                } catch {
                    throw MCPOAuthFlowError.needsAuthorization
                }
            },
            on403InsufficientScope: { challengeScope in
                try await self.stepUp(serverID: serverID, mcpServerURL: mcpServerURL, challengeScope: challengeScope, redirect: redirect)
            }
        )
    }

    // MARK: - Private

    private func resolveClientID(serverMetadata: MCPOAuthAuthorizationServerMetadata, preRegisteredClientID: String?) async throws -> String {
        let outcome: MCPOAuthClientRegistrationOutcome
        do {
            outcome = try await registration.register(
                issuer: serverMetadata.issuer,
                serverMetadata: serverMetadata,
                preRegisteredClientID: preRegisteredClientID,
                redirectURIs: Self.registeredRedirectURIs
            )
        } catch let error as MCPOAuthFlowError {
            throw error
        } catch {
            throw Task.isCancelled ? MCPOAuthFlowError.cancelled : MCPOAuthFlowError.registrationFailed(String(describing: error))
        }
        switch outcome {
        case .preRegistered(let clientID), .cimd(let clientID), .dynamicallyRegistered(let clientID):
            return clientID
        case .needsUserInput:
            throw MCPOAuthFlowError.needsAuthorization
        }
    }

    /// Waits for the callback; cancelling the calling task cancels the listener.
    private func waitForCallback(_ listener: LoopbackRedirectListener) async throws -> MCPOAuthCallback {
        do {
            return try await withTaskCancellationHandler {
                try await listener.waitForCallback()
            } onCancel: {
                Task { await listener.cancel(reason: "sign-in task cancelled") }
            }
        } catch let error as MCPOAuthRedirectListenerError {
            throw Self.flowError(error)
        }
    }

    /// Releases `listener`'s port and forgets it, unless a newer sign-in for
    /// the same server has replaced it.
    private func endSignIn(_ listener: LoopbackRedirectListener, serverID: MCPServerID, reason: String) async {
        if activeListeners[serverID] === listener {
            activeListeners[serverID] = nil
        }
        await listener.cancel(reason: reason)
    }

    /// The stored tokens, refreshed when expired or when `forceRefresh`,
    /// with a refreshed set saved back. No stored tokens or client throws
    /// `MCPOAuthFlowError.needsAuthorization`.
    private func currentTokens(serverID: MCPServerID, mcpServerURL: URL, forceRefresh: Bool) async throws -> MCPOAuthTokenSet {
        if let inFlight = refreshTasks[serverID] {
            return try await inFlight.value
        }
        let credentials = self.credentials
        let (storedTokens, storedClient) = try await Self.storing {
            (try await credentials.tokens(for: serverID), try await credentials.clientRegistration(for: serverID))
        }
        guard let tokens = storedTokens, let client = storedClient else {
            throw MCPOAuthFlowError.needsAuthorization
        }
        if let inFlight = refreshTasks[serverID] {
            return try await inFlight.value
        }
        // Only a real refresh is shared, so a forced refresh never joins a
        // call that returns the unchanged tokens.
        if !forceRefresh {
            guard let expiresAt = tokens.expiresAt, expiresAt <= Date() else {
                return tokens
            }
        }

        let tokenClient = MCPOAuthTokenClient(
            session: session,
            tokenEndpoint: client.tokenEndpoint,
            clientID: client.clientID,
            clientAuthentication: client.clientAuthentication,
            canonicalResourceURI: try Self.canonicalResourceURI(of: mcpServerURL)
        )
        let task = Task<MCPOAuthTokenSet, any Error> {
            let refreshed = forceRefresh
                ? try await tokenClient.refreshAfter401(tokens)
                : try await tokenClient.refreshedIfNeeded(tokens)
            if refreshed != tokens {
                try await Self.storing {
                    try await credentials.setTokens(refreshed, for: serverID)
                }
            }
            return refreshed
        }
        refreshTasks[serverID] = task
        let result = await task.result
        refreshTasks[serverID] = nil
        return try result.get()
    }

    /// Re-authorizes `serverID` with the challenge's scope merged into the
    /// granted one, reusing the stored client.
    private func stepUp(serverID: MCPServerID, mcpServerURL: URL, challengeScope: String?, redirect: MCPOAuthRedirectConfig?) async throws {
        let credentials = self.credentials
        let storedClient = try await Self.storing {
            try await credentials.clientRegistration(for: serverID)
        }
        guard let client = storedClient else {
            throw MCPOAuthFlowError.needsAuthorization
        }
        _ = try await authorize(
            serverID: serverID,
            mcpServerURL: mcpServerURL,
            resourceMetadataHintURL: nil,
            preRegisteredClientID: client.clientID,
            clientAuthentication: client.clientAuthentication,
            scopeOverride: MCPOAuthScopeStepUp.union(previouslyGrantedScope: client.grantedScope, challengeScope: challengeScope),
            redirect: redirect
        )
    }

    /// RFC 8707 section 2 canonical form of the MCP server URL: lowercase
    /// scheme and host, no fragment, no trailing slash.
    private static func canonicalResourceURI(of url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme,
              let host = components.host
        else {
            throw MCPOAuthFlowError.discoveryFailed("the server URL has no scheme or host")
        }
        components.scheme = scheme.lowercased()
        components.host = host.lowercased()
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        guard let canonical = components.string else {
            throw MCPOAuthFlowError.discoveryFailed("the server URL has no canonical form")
        }
        return canonical
    }

    /// Runs `body`, reporting an error thrown by `MCPOAuthCredentialStoring`
    /// as `MCPOAuthFlowError.storageFailed`.
    private static func storing<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw MCPOAuthFlowError.storageFailed(String(describing: error))
        }
    }

    /// The values of `scopes_supported` separated by spaces; nil when the
    /// field is absent or empty.
    private static func joinedScope(_ scopes: [String]?) -> String? {
        guard let scopes, !scopes.isEmpty else { return nil }
        return scopes.joined(separator: " ")
    }

    private static func discoveryError(_ error: any Error) -> MCPOAuthFlowError {
        switch error {
        case let error as MCPOAuthFlowError:
            return error
        case MCPOAuthMetadataDiscoveryError.pkceS256Unsupported:
            return .pkceUnsupported
        default:
            return Task.isCancelled ? .cancelled : .discoveryFailed(String(describing: error))
        }
    }

    private static func flowError(_ error: MCPOAuthRedirectListenerError) -> MCPOAuthFlowError {
        switch error {
        case .stateMismatch:
            .stateMismatch
        case .portBusy(let port):
            .portBusy(port)
        case .cancelled:
            .cancelled
        case .authorizationServerError(let error, let description):
            .authorizationFailed(error: error, description: description)
        }
    }
}
