//
//  MCPOAuthMetadataDiscovery.swift
//  Calyx
//
//  Finds the protected resource metadata (RFC 9728) of an MCP server and
//  the metadata of its authorization server (RFC 8414 / OpenID Connect
//  Discovery), in the order the MCP authorization specification requires.
//  A candidate URL that answers with a non-2xx status or an undecodable
//  body is skipped; a document that decodes but fails validation is
//  rejected outright.
//

import Foundation

struct MCPOAuthProtectedResourceMetadata: Sendable, Equatable, Codable {
    let resource: String
    let authorizationServers: [String]
    let scopesSupported: [String]?

    private enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

struct MCPOAuthAuthorizationServerMetadata: Sendable, Equatable, Codable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let registrationEndpoint: String?
    let scopesSupported: [String]?
    let codeChallengeMethodsSupported: [String]?
    let clientIDMetadataDocumentSupported: Bool?
    let authorizationResponseIssParameterSupported: Bool?

    private enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case clientIDMetadataDocumentSupported = "client_id_metadata_document_supported"
        case authorizationResponseIssParameterSupported = "authorization_response_iss_parameter_supported"
    }
}

enum MCPOAuthMetadataDiscoveryError: Error, Sendable, Equatable {
    case resourceMismatch(expected: String, got: String)
    case issuerMismatch(expected: String, got: String)
    case noDiscoveryEndpointSucceeded
    case pkceS256Unsupported
}

struct MCPOAuthMetadataDiscovery: Sendable {

    private static let protectedResourceWellKnown = "/.well-known/oauth-protected-resource"
    private static let oauthServerWellKnown = "/.well-known/oauth-authorization-server"
    private static let openIDWellKnown = "/.well-known/openid-configuration"

    private let session: MCPHTTPSession

    init(session: MCPHTTPSession) {
        self.session = session
    }

    // MARK: - Protected Resource Metadata

    /// Tries the `resource_metadata` hint from `WWW-Authenticate` when
    /// given, then the path-inserted well-known URL, then the root
    /// well-known URL. The document's `resource` must equal
    /// `canonicalResourceURI` exactly.
    func discoverProtectedResourceMetadata(mcpServerURL: URL, resourceMetadataHintURL: URL?, canonicalResourceURI: String) async throws -> MCPOAuthProtectedResourceMetadata {
        var candidates: [URL] = []
        if let resourceMetadataHintURL {
            candidates.append(resourceMetadataHintURL)
        }
        let path = Self.pathWithoutTrailingSlash(of: mcpServerURL)
        if !path.isEmpty {
            candidates.append(try Self.url(from: mcpServerURL, path: Self.protectedResourceWellKnown + path))
        }
        candidates.append(try Self.url(from: mcpServerURL, path: Self.protectedResourceWellKnown))

        for candidate in candidates {
            guard let metadata = try await fetch(MCPOAuthProtectedResourceMetadata.self, from: candidate) else {
                continue
            }
            guard metadata.resource == canonicalResourceURI else {
                throw MCPOAuthMetadataDiscoveryError.resourceMismatch(expected: canonicalResourceURI, got: metadata.resource)
            }
            return metadata
        }
        throw MCPOAuthMetadataDiscoveryError.noDiscoveryEndpointSucceeded
    }

    // MARK: - Authorization Server Metadata

    /// For an issuer with a path: OAuth path-inserted, OpenID Connect
    /// path-inserted, OpenID Connect path-appended. For an issuer without
    /// a path: OAuth root, OpenID Connect root. The document's `issuer`
    /// must equal `issuer` exactly, and PKCE `S256` must be advertised.
    func discoverAuthorizationServerMetadata(issuer: URL) async throws -> MCPOAuthAuthorizationServerMetadata {
        let expectedIssuer = issuer.absoluteString
        let path = Self.pathWithoutTrailingSlash(of: issuer)
        let candidates: [URL]
        if path.isEmpty {
            candidates = [
                try Self.url(from: issuer, path: Self.oauthServerWellKnown),
                try Self.url(from: issuer, path: Self.openIDWellKnown),
            ]
        } else {
            candidates = [
                try Self.url(from: issuer, path: Self.oauthServerWellKnown + path),
                try Self.url(from: issuer, path: Self.openIDWellKnown + path),
                try Self.url(from: issuer, path: path + Self.openIDWellKnown),
            ]
        }

        for candidate in candidates {
            guard let metadata = try await fetch(MCPOAuthAuthorizationServerMetadata.self, from: candidate) else {
                continue
            }
            guard metadata.issuer == expectedIssuer else {
                throw MCPOAuthMetadataDiscoveryError.issuerMismatch(expected: expectedIssuer, got: metadata.issuer)
            }
            guard metadata.codeChallengeMethodsSupported?.contains("S256") == true else {
                throw MCPOAuthMetadataDiscoveryError.pkceS256Unsupported
            }
            return metadata
        }
        throw MCPOAuthMetadataDiscoveryError.noDiscoveryEndpointSucceeded
    }

    // MARK: - Private

    /// The decoded document, or nil when the URL answered with a non-2xx
    /// status or a body that does not decode as `T`.
    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await session.send(request)
        guard (200..<300).contains(response.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: response.body)
    }

    /// The URL's percent-encoded path with any trailing "/" removed; empty
    /// for a URL with no path or a path of "/".
    private static func pathWithoutTrailingSlash(of url: URL) -> String {
        var path = url.path(percentEncoded: true)
        while path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    /// `base`'s scheme, host and port with `path` and no query or fragment.
    private static func url(from base: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }
}
