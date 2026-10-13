//
//  IPCWakeTestCrypto.swift
//  CalyxTests
//
//  Test-only reference computations for the `/ipc-wake` response proof,
//  written against CryptoKit directly so that tests can compute expected
//  values without the production `IPCWakeProofKey`:
//
//  - `hmacHex(keyBytes:nonce:note:)`: HMAC-SHA256 over the UTF-8 bytes of
//    `nonce + "\n" + note`, as 64 lowercase hex digits.
//  - `blocksHex(keyBytes:)`: HMAC's inner and outer blocks as 128 lowercase
//    hex digits each (the key, SHA-256-hashed first when longer than 64
//    bytes, zero padded to 64 bytes and XORed with 0x36 / 0x5C). This is
//    the minimum needed to write an agent-endpoint.json by hand.
//  - `proofFromBlocks(innerHex:outerHex:nonce:note:)`:
//    SHA256(outer || SHA256(inner || message)), which is what the wake hook
//    computes, and what server tests use after reading the blocks back from
//    the endpoint file (no key accessor on the server is needed).
//  - `endpointJSON(...)`: an agent-endpoint.json body with the four keys.
//

import CryptoKit
import Foundation

enum IPCWakeTestCrypto {

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes lowercase or uppercase hex; nil when `text` is not an even
    /// number of hex digits.
    static func decodeHex(_ text: String) -> Data? {
        let digits = Array(text.utf8)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: digits.count / 2)
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            data.append(byte)
        }
        return data
    }

    static func hmacHex(keyBytes: Data, message: Data) -> String {
        hex(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: keyBytes)))
    }

    static func hmacHex(keyBytes: Data, nonce: String, note: String) -> String {
        hmacHex(keyBytes: keyBytes, message: Data((nonce + "\n" + note).utf8))
    }

    static func blocksHex(keyBytes: Data) -> (inner: String, outer: String) {
        let key = keyBytes.count > 64 ? [UInt8](SHA256.hash(data: keyBytes)) : [UInt8](keyBytes)
        let padded = key + [UInt8](repeating: 0, count: 64 - key.count)
        return (hex(padded.map { $0 ^ 0x36 }), hex(padded.map { $0 ^ 0x5C }))
    }

    /// nil when either block is not hex.
    static func proofFromBlocks(innerHex: String, outerHex: String, message: Data) -> String? {
        guard let inner = decodeHex(innerHex), let outer = decodeHex(outerHex) else { return nil }
        let innerDigest = Data(SHA256.hash(data: inner + message))
        return hex(SHA256.hash(data: outer + innerDigest))
    }

    static func proofFromBlocks(innerHex: String, outerHex: String, nonce: String, note: String) -> String? {
        proofFromBlocks(innerHex: innerHex, outerHex: outerHex, message: Data((nonce + "\n" + note).utf8))
    }

    static func randomKeyBytes(count: Int = 32) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    /// A one-line agent-endpoint.json with `port`, `token`, the liveness
    /// identifier `pid`/`pidStart` (default: the test host's own, see
    /// TestHostLiveness.swift and spec C-D16; nil omits that key) and,
    /// when given, the blocks of `keyBytes`.
    static func endpointJSON(
        port: Int, token: String, keyBytes: Data?,
        pid: Int32? = TestHostLiveness.pid, pidStart: String? = TestHostLiveness.startText
    ) throws -> Data {
        var dict: [String: Any] = ["port": port, "token": token]
        if let pid { dict["pid"] = Int(pid) }
        if let pidStart { dict["pidStart"] = pidStart }
        if let keyBytes {
            let blocks = blocksHex(keyBytes: keyBytes)
            dict["wakeProofInner"] = blocks.inner
            dict["wakeProofOuter"] = blocks.outer
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    }

    /// Writes `endpointJSON` to `<directory>/agent-endpoint.json` (0600),
    /// creating the directory.
    static func writeEndpointFile(
        directory: String, port: Int, token: String, keyBytes: Data?,
        pid: Int32? = TestHostLiveness.pid, pidStart: String? = TestHostLiveness.startText
    ) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/agent-endpoint.json"
        try endpointJSON(port: port, token: token, keyBytes: keyBytes, pid: pid, pidStart: pidStart)
            .write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// The two blocks read from `<directory>/agent-endpoint.json`, or nil
    /// when the file or either block is missing.
    static func readEndpointBlocks(directory: String) -> (inner: String, outer: String)? {
        guard let data = FileManager.default.contents(atPath: directory + "/agent-endpoint.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let inner = json["wakeProofInner"] as? String,
              let outer = json["wakeProofOuter"] as? String
        else { return nil }
        return (inner, outer)
    }
}
