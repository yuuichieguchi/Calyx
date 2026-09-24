//
//  MCPOAuthAuthorizationRequestBuilder.swift
//  Calyx
//
//  Builds the authorization endpoint URL for the authorization code grant
//  with PKCE `S256` and an RFC 8707 `resource` parameter.
//

import Foundation

enum MCPOAuthAuthorizationRequestBuilder {

    /// `canonicalResourceURI` is sent as given; the caller supplies the
    /// canonical form (no trailing slash, no fragment). `scope` is omitted
    /// when nil.
    static func buildURL(
        authorizationEndpoint: URL,
        clientID: String,
        redirectURI: String,
        codeChallenge: String,
        state: String,
        canonicalResourceURI: String,
        scope: String?
    ) -> URL {
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: canonicalResourceURI),
        ]
        if let scope {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        return authorizationEndpoint.appending(queryItems: items)
    }
}
