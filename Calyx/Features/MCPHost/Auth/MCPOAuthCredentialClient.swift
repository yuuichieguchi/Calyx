//
//  MCPOAuthCredentialClient.swift
//  Calyx
//
//  Token endpoint client (authorization code exchange and refresh), the
//  Auth module's failure type, and the persistence seam for OAuth state.
//  Credential values are never logged.
//

import Foundation

actor MCPOAuthTokenClient {

    private let session: MCPHTTPSession
    private let tokenEndpoint: URL
    private let clientID: String
    private let clientAuthentication: MCPOAuthClientAuthentication
    /// Sent as `resource` (RFC 8707) on every refresh request.
    private let canonicalResourceURI: String
    private let now: @Sendable () -> Date

    init(session: MCPHTTPSession, tokenEndpoint: URL, clientID: String, clientAuthentication: MCPOAuthClientAuthentication, canonicalResourceURI: String, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.tokenEndpoint = tokenEndpoint
        self.clientID = clientID
        self.clientAuthentication = clientAuthentication
        self.canonicalResourceURI = canonicalResourceURI
        self.now = now
    }

    // MARK: - Grants

    /// Authorization code grant with the PKCE verifier and the RFC 8707
    /// `resource` parameter given here. `invalid_grant` throws
    /// `MCPOAuthFlowError.needsAuthorization`; any other token endpoint
    /// error throws `MCPOAuthFlowError.tokenEndpointFailed`.
    func exchangeCode(_ code: String, verifier: String, redirectURI: String, canonicalResourceURI: String) async throws -> MCPOAuthTokenSet {
        try await requestTokens(
            parameters: [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", redirectURI),
                ("code_verifier", verifier),
                ("resource", canonicalResourceURI),
            ],
            previous: nil
        )
    }

    /// Returns `tokens` unchanged before `expiresAt` and refreshed from then
    /// on. Tokens without `expiresAt` are returned unchanged.
    func refreshedIfNeeded(_ tokens: MCPOAuthTokenSet) async throws -> MCPOAuthTokenSet {
        guard let expiresAt = tokens.expiresAt, expiresAt <= now() else {
            return tokens
        }
        return try await refresh(tokens)
    }

    /// Refreshes unconditionally, after the resource server rejected the
    /// access token.
    func refreshAfter401(_ tokens: MCPOAuthTokenSet) async throws -> MCPOAuthTokenSet {
        try await refresh(tokens)
    }

    // MARK: - Private

    /// `invalid_grant`, or no refresh token to send, throws
    /// `MCPOAuthFlowError.needsAuthorization`.
    private func refresh(_ tokens: MCPOAuthTokenSet) async throws -> MCPOAuthTokenSet {
        guard let refreshToken = tokens.refreshToken else {
            throw MCPOAuthFlowError.needsAuthorization
        }
        return try await requestTokens(
            parameters: [
                ("grant_type", "refresh_token"),
                ("refresh_token", refreshToken),
                ("resource", canonicalResourceURI),
            ],
            previous: tokens
        )
    }

    /// POSTs a form-encoded token request with the client authentication
    /// applied. On a refresh (`previous` non-nil) an omitted `refresh_token`
    /// or `scope` keeps the previous value (RFC 6749 sections 6 and 5.1).
    private func requestTokens(parameters: [(String, String)], previous: MCPOAuthTokenSet?) async throws -> MCPOAuthTokenSet {
        var form = parameters
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch clientAuthentication {
        case .none:
            form.append(("client_id", clientID))
        case .clientSecretPost(let secret):
            form.append(("client_id", clientID))
            form.append(("client_secret", secret))
        case .clientSecretBasic(let secret):
            // RFC 6749 section 2.3.1: both parts are form-encoded before base64.
            let pair = "\(MCPOAuthFormEncoding.encode(clientID)):\(MCPOAuthFormEncoding.encode(secret))"
            request.setValue("Basic \(Data(pair.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data(MCPOAuthFormEncoding.body(form).utf8)

        let response = try await session.send(request)
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            // RFC 6749 section 5.2. A body without `error` is reported by
            // its HTTP status.
            guard let errorCode = object?["error"] as? String else {
                throw MCPOAuthFlowError.tokenEndpointFailed(error: "http_\(response.statusCode)", description: nil)
            }
            if errorCode == "invalid_grant" {
                throw MCPOAuthFlowError.needsAuthorization
            }
            throw MCPOAuthFlowError.tokenEndpointFailed(error: errorCode, description: object?["error_description"] as? String)
        }
        guard let object,
              let accessToken = object["access_token"] as? String,
              let tokenType = object["token_type"] as? String,
              tokenType.caseInsensitiveCompare("Bearer") == .orderedSame
        else {
            throw MCPOAuthFlowError.tokenEndpointFailed(error: "invalid_response", description: "the response has no Bearer access_token")
        }
        let expiresAt = (object["expires_in"] as? NSNumber).map { now().addingTimeInterval($0.doubleValue) }
        return MCPOAuthTokenSet(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String ?? previous?.refreshToken,
            expiresAt: expiresAt,
            scope: object["scope"] as? String ?? previous?.scope
        )
    }
}

/// `application/x-www-form-urlencoded` encoding for request bodies. Every
/// byte outside ALPHA / DIGIT / "-" / "." / "_" / "~" is percent-encoded.
enum MCPOAuthFormEncoding {

    static func encode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                encoded.append(Character(Unicode.Scalar(byte)))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    static func body(_ parameters: [(String, String)]) -> String {
        parameters.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}

/// The failure type shared by the whole Auth module.
enum MCPOAuthFlowError: Error, Sendable, Equatable {
    /// No stored tokens, or a refresh rejected with `invalid_grant`.
    case needsAuthorization
    /// The authorization server has no `registration_endpoint`, does not
    /// support client ID metadata documents, and no pre-registered client
    /// ID is configured, so sign-in needs a client ID from the user.
    case clientRegistrationUnavailable(issuer: String)
    /// The loopback redirect listener was cancelled.
    case cancelled
    case portBusy(Int)
    /// The authorization server does not advertise PKCE `S256`.
    case pkceUnsupported
    /// RFC 9207: the callback's `iss` is missing (when advertised) or differs.
    case issuerMismatch
    /// The callback's `state` differs from the one sent.
    case stateMismatch
    /// Protected resource or authorization server metadata is unavailable.
    case discoveryFailed(String)
    /// Dynamic client registration failed.
    case registrationFailed(String)
    /// The authorization server redirected back with an error instead of a
    /// code (RFC 6749 section 4.1.2.1).
    case authorizationFailed(error: String, description: String?)
    /// The token endpoint answered with an error other than `invalid_grant`.
    case tokenEndpointFailed(error: String, description: String?)
    /// `MCPOAuthCredentialStoring` threw.
    case storageFailed(String)
}

/// Persistence seam for OAuth state, keyed by server. The Auth module does
/// not know the secret store; the owner of the connections adapts its
/// secret store to this protocol.
protocol MCPOAuthCredentialStoring: Sendable {
    func tokens(for serverID: MCPServerID) async throws -> MCPOAuthTokenSet?
    func setTokens(_ tokens: MCPOAuthTokenSet?, for serverID: MCPServerID) async throws
    func clientRegistration(for serverID: MCPServerID) async throws -> MCPOAuthStoredClient?
    func setClientRegistration(_ client: MCPOAuthStoredClient?, for serverID: MCPServerID) async throws
}

/// The client a server's tokens were issued to, kept so tokens can be
/// refreshed and scopes stepped up without repeating registration.
struct MCPOAuthStoredClient: Sendable, Equatable, Codable {
    let clientID: String
    let tokenEndpoint: URL
    let clientAuthentication: MCPOAuthClientAuthentication
    let grantedScope: String?
}

/// Token endpoint authentication method of a pre-registered client, as kept
/// in configuration (no secret value).
enum MCPOAuthClientAuthenticationMethod: String, Sendable, Equatable, Codable {
    case none
    case clientSecretPost
    case clientSecretBasic
}

/// Token endpoint authentication used at run time. Carries the secret value
/// and is never written to configuration.
enum MCPOAuthClientAuthentication: Sendable, Equatable, Codable {
    case none
    case clientSecretPost(secret: String)
    case clientSecretBasic(secret: String)
}
