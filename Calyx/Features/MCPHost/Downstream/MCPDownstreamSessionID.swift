//
//  MCPDownstreamSessionID.swift
//  Calyx
//
//  The legacy `/calyx-mcp` `Mcp-Session-Id`: a signed, stateless token.
//
//      v1.<base64url(payload JSON)>.<base64url(HMAC-SHA256(key, payload JSON))>
//
//  The key is derived with HKDF-SHA256 from the IPC bearer token read at
//  runtime (the token `agent-endpoint.json` publishes and
//  `IPCEndpointReuse` keeps across restarts), so no secret file is added
//  and a token stays valid across a restart that reuses the bearer.
//

import CryptoKit
import Foundation

struct MCPDownstreamSessionPayload: Sendable, Equatable {
    let version: Int
    let negotiatedProtocolVersion: String
    let clientDeclaredUI: Bool
    let clientName: String?
    let nonce: String
    let issuedAt: Date
}

enum MCPDownstreamSessionID {

    private static let formatPrefix = "v1"
    private static let keySalt = Data("calyx-mcp-session".utf8)
    private static let keyInfo = Data("calyx-mcp-session-v1".utf8)

    /// The payload's wire form. Short keys keep the header small.
    private struct WirePayload: Codable {
        let v: Int
        let pv: String
        let ui: Bool
        let cn: String?
        let n: String
        let iat: Double
    }

    static func mint(payload: MCPDownstreamSessionPayload, bearerToken: String) -> String {
        let wire = WirePayload(
            v: payload.version,
            pv: payload.negotiatedProtocolVersion,
            ui: payload.clientDeclaredUI,
            cn: payload.clientName,
            n: payload.nonce,
            iat: payload.issuedAt.timeIntervalSince1970
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding a struct of strings, numbers and booleans cannot fail.
        guard let payloadData = try? encoder.encode(wire) else {
            preconditionFailure("MCPDownstreamSessionID payload encoding failed")
        }
        let signature = HMAC<SHA256>.authenticationCode(for: payloadData, using: signingKey(bearerToken: bearerToken))
        return [formatPrefix, base64URLEncode(payloadData), base64URLEncode(Data(signature))].joined(separator: ".")
    }

    /// Nil when the token is malformed, has another version prefix, or its
    /// signature does not verify under `bearerToken`.
    static func validate(_ token: String, bearerToken: String) -> MCPDownstreamSessionPayload? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == formatPrefix,
              let payloadData = base64URLDecode(String(parts[1])),
              let signature = base64URLDecode(String(parts[2]))
        else {
            return nil
        }
        guard HMAC<SHA256>.isValidAuthenticationCode(
            signature, authenticating: payloadData, using: signingKey(bearerToken: bearerToken)
        ) else {
            return nil
        }
        guard let wire = try? JSONDecoder().decode(WirePayload.self, from: payloadData) else {
            return nil
        }
        return MCPDownstreamSessionPayload(
            version: wire.v,
            negotiatedProtocolVersion: wire.pv,
            clientDeclaredUI: wire.ui,
            clientName: wire.cn,
            nonce: wire.n,
            issuedAt: Date(timeIntervalSince1970: wire.iat)
        )
    }

    private static func signingKey(bearerToken: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(bearerToken.utf8)),
            salt: keySalt,
            info: keyInfo,
            outputByteCount: 32
        )
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        guard !text.isEmpty else { return nil }
        var base64 = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
