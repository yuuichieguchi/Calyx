// ApprovalHookResponse.swift
// Calyx
//
// The wire format of a signed `POST /approval-request` 200 answer. When
// the request carries `X-Calyx-Approval-Nonce`, `CalyxMCPServer` answers
// `text/plain; charset=utf-8` with
// `<64 lowercase hex proof> LF <decision body>` (no trailing newline),
// where the proof is `IPCWakeProofKey.proof(over:)` of
// `approval\n<nonce>\n<decision body>`. `calyx-approval-hook` prints the
// body only when the proof verifies against the blocks it read from
// `agent-endpoint.json`.

import Foundation

enum ApprovalHookResponse {

    /// The request header carrying the hook's per-call nonce (an
    /// uppercase canonical UUID).
    static let nonceHeader = "X-Calyx-Approval-Nonce"

    /// The approval domain's message prefix; a wake message starts with
    /// the nonce instead, so the two domains never share a message.
    static let domainPrefix = "approval\n"

    /// 64 hex digits and one LF.
    static let proofLineBytes = 65

    /// `.answered` echoes the whole `tool_input` back as `updatedInput`,
    /// so a decision body may be larger than the request cap.
    static let maxBodyBytes = 4 * CalyxMCPServer.maxEventBodyBytes

    /// The largest signed answer; the hook passes it to curl's
    /// `--max-filesize`.
    static let maxSignedResponseBytes = proofLineBytes + maxBodyBytes

    /// `approval\n` + nonce + `\n` + body, the bytes the proof covers.
    static func message(nonce: String, body: Data) -> Data {
        Data((domainPrefix + nonce + "\n").utf8) + body
    }

    /// proof + LF + body, with no trailing newline.
    static func signedBody(proof: String, body: Data) -> Data {
        Data((proof + "\n").utf8) + body
    }
}
