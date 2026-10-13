// IPCWakeProof.swift
// Calyx
//
// The key with which `CalyxMCPServer` proves, in a `POST /ipc-wake` 200
// response, that it is the Calyx that wrote `agent-endpoint.json`. The
// wake hook shows the response's note to the model, so it must act only
// on an answer from that Calyx and not on one from whoever happens to
// listen on the port the file names.
//
// The threat: a local process that cannot read the user's files under
// `~/Library/Application Support/Calyx`, but binds the port left behind
// in the endpoint file after a crash. It receives whatever clients send
// there, the bearer token included, and answers. It never sees the key,
// so it cannot produce a proof.
//
// Not addressed: a process of the same user outside a sandbox can read
// the endpoint file and edit `~/.claude/settings.json`. Nothing here
// helps against it.
//
// The proof is HMAC-SHA256 (`proof(over:)`) over a message that binds a
// nonce the client chose for this one poll. Two domains share the key:
// - wake (`POST /ipc-wake`): `<nonce>\n<note>` (`proof(nonce:note:)`)
// - approval (`POST /approval-request`): `approval\n<nonce>\n<body>`
//   (`ApprovalHookResponse.message(nonce:body:)`)
// A wake message starts with an uppercase UUID and an approval message
// with `approval\n`, so a proof from one domain never verifies in the
// other. The nonce binds a proof to one poll, so a proof
// cannot be replayed as the answer to another. The key is fresh on
// every server start, so a proof obtained from a later server instance
// does not verify against the blocks an earlier poll read.
//
// The key must never be sent in a request or a response and never be
// logged. Only `innerBlockHex` and `outerBlockHex` leave this process,
// into the 0600 endpoint file (`AgentEndpointFile.write`).

import CryptoKit
import Foundation

struct IPCWakeProofKey: Sendable, Equatable {

    /// SHA-256's block size in bytes. HMAC (RFC 2104) replaces a key
    /// longer than this by its SHA-256 digest (32 bytes), then pads the
    /// key with zero bytes to this length.
    private static let blockSize = 64

    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    /// A new key of 32 bytes from CryptoKit's generator, different on
    /// every call.
    static func random() -> IPCWakeProofKey {
        IPCWakeProofKey(bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    /// HMAC-SHA256 under `bytes` over the UTF-8 bytes of
    /// `nonce + "\n" + note`, as 64 lowercase hex digits.
    func proof(nonce: String, note: String) -> String {
        proof(over: Data((nonce + "\n" + note).utf8))
    }

    /// HMAC-SHA256 under `bytes` over `message`, as 64 lowercase hex
    /// digits. Callers build the domain-specific message (see the file
    /// header).
    func proof(over message: Data) -> String {
        Self.hex(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: bytes)))
    }

    /// HMAC's inner block, as 128 lowercase hex digits: the key, or its
    /// SHA-256 digest (32 bytes) when the key is longer than 64 bytes,
    /// padded with zero bytes to 64 bytes and XORed with 0x36. A key of
    /// 64 bytes or fewer is not hashed. Together with
    /// `outerBlockHex` it is what the endpoint file carries, so that a
    /// shell script can compute the same HMAC as
    /// `SHA256(outer || SHA256(inner || message))` through pipes
    /// without holding the key in a process argument.
    var innerBlockHex: String {
        blockHex(xoredWith: 0x36)
    }

    /// HMAC's outer block, as 128 lowercase hex digits: the key, or its
    /// SHA-256 digest (32 bytes) when the key is longer than 64 bytes,
    /// padded with zero bytes to 64 bytes and XORed with 0x5C. A key of
    /// 64 bytes or fewer is not hashed.
    var outerBlockHex: String {
        blockHex(xoredWith: 0x5C)
    }

    private func blockHex(xoredWith pad: UInt8) -> String {
        let key = bytes.count > Self.blockSize ? [UInt8](SHA256.hash(data: bytes)) : [UInt8](bytes)
        // `key` holds at most `blockSize` bytes: the key itself when it
        // is that short, its 32-byte digest otherwise. A zero byte XORed
        // with `pad` is `pad`, so the zero padding is the initial value.
        var block = [UInt8](repeating: pad, count: Self.blockSize)
        for (index, byte) in key.enumerated() {
            block[index] ^= byte
        }
        return Self.hex(block)
    }

    private static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
