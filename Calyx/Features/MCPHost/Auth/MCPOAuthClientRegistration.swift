//
//  MCPOAuthClientRegistration.swift
//  Calyx
//
//  Resolves the client id to use with an authorization server, in the
//  order: pre-registered, Client ID Metadata Document (only when the server
//  advertises support), Dynamic Client Registration (RFC 7591), and
//  otherwise asking the user. Dynamically registered client ids are stored
//  per issuer and reused, never presented to another issuer.
//

import Foundation

enum MCPOAuthClientRegistrationOutcome: Sendable, Equatable {
    case preRegistered(clientID: String)
    case cimd(clientID: String)
    case dynamicallyRegistered(clientID: String)
    case needsUserInput
}

protocol MCPOAuthClientRegistrationStoring: Sendable {
    func clientID(forIssuer issuer: String) async -> String?
    func store(clientID: String, forIssuer issuer: String) async
}

struct MCPOAuthClientRegistration: Sendable {

    /// The Client ID Metadata Document URL, which is itself the client id.
    static let cimdClientID = "https://getcalyx.app/oauth/mcp-client.json"

    private let session: MCPHTTPSession
    private let store: any MCPOAuthClientRegistrationStoring

    init(session: MCPHTTPSession, store: any MCPOAuthClientRegistrationStoring) {
        self.session = session
        self.store = store
    }

    /// A failed registration request throws
    /// `MCPOAuthFlowError.registrationFailed`.
    func register(
        issuer: String,
        serverMetadata: MCPOAuthAuthorizationServerMetadata,
        preRegisteredClientID: String?,
        redirectURIs: [String]
    ) async throws -> MCPOAuthClientRegistrationOutcome {
        if let preRegisteredClientID {
            return .preRegistered(clientID: preRegisteredClientID)
        }
        if serverMetadata.clientIDMetadataDocumentSupported == true {
            return .cimd(clientID: Self.cimdClientID)
        }
        if let storedClientID = await store.clientID(forIssuer: issuer) {
            return .dynamicallyRegistered(clientID: storedClientID)
        }
        guard let registrationEndpoint = serverMetadata.registrationEndpoint else {
            return .needsUserInput
        }
        let clientID = try await registerDynamically(endpoint: registrationEndpoint, redirectURIs: redirectURIs)
        await store.store(clientID: clientID, forIssuer: issuer)
        return .dynamicallyRegistered(clientID: clientID)
    }

    // MARK: - Private

    /// RFC 7591 registration of a native public client.
    private func registerDynamically(endpoint: String, redirectURIs: [String]) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw MCPOAuthFlowError.registrationFailed("invalid registration_endpoint")
        }
        let metadata: [String: Any] = [
            "client_name": "Calyx",
            "application_type": "native",
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "redirect_uris": redirectURIs,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let response = try await session.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw MCPOAuthFlowError.registrationFailed("registration endpoint returned HTTP \(response.statusCode)")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let clientID = object["client_id"] as? String
        else {
            throw MCPOAuthFlowError.registrationFailed("registration response has no client_id")
        }
        return clientID
    }
}
