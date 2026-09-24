//
//  MCPOAuthPKCE.swift
//  Calyx
//
//  RFC 7636 PKCE with the `S256` method, plus the authorization request's
//  `state` value.
//

import CryptoKit
import Foundation

enum MCPOAuthPKCE {

    /// Number of random bytes behind a verifier or a state value.
    private static let randomByteCount = 32

    /// base64url-no-padding(SHA256(ASCII(verifier))), RFC 7636 section 4.2.
    static func codeChallenge(forVerifier verifier: String) -> String {
        base64URLNoPadding(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes, base64url-no-padding (43 characters, RFC 7636 section 4.1).
    static func generateVerifier(randomBytes: @Sendable (Int) -> [UInt8] = { count in (0..<count).map { _ in UInt8.random(in: .min ... .max) } }) -> String {
        base64URLNoPadding(Data(randomBytes(randomByteCount)))
    }

    /// 32 random bytes, base64url-no-padding.
    static func generateState(randomBytes: @Sendable (Int) -> [UInt8] = { count in (0..<count).map { _ in UInt8.random(in: .min ... .max) } }) -> String {
        base64URLNoPadding(Data(randomBytes(randomByteCount)))
    }

    private static func base64URLNoPadding(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
