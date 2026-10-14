//
//  IPCWakeProofTests.swift
//  CalyxTests
//
//  Pins IPCWakeProofKey (spec A.3, A.4): the key with which CalyxMCPServer
//  proves, in a `POST /ipc-wake` 200 response, that it is the Calyx that
//  wrote agent-endpoint.json. The key type holds the key, `proof`, and
//  the two HMAC blocks only; the header name and the body layout live on
//  IPCWakeResponse (see IPCWakeResponseWireFormatTests).
//
//  Planned API used here:
//    struct IPCWakeProofKey: Sendable, Equatable {
//        init(bytes: Data); let bytes: Data
//        static func random() -> IPCWakeProofKey
//        func proof(nonce: String, note: String) -> String
//        var innerBlockHex: String { get }
//        var outerBlockHex: String { get }
//    }
//
//  Reference values: RFC 4231 HMAC-SHA-256 test cases 1, 2, 3, 4, 6 and 7
//  (published digests, also reproduced with /usr/bin/openssl), one
//  nonce/note vector computed with `openssl dgst -sha256 -mac HMAC`, and
//  CryptoKit called directly from the test.
//
//  Coverage:
//  - RFC 4231 cases 1-4, 6, 7: the two blocks reproduce the published
//    digest via SHA256(outer || SHA256(inner || data)); for the cases
//    whose data is UTF-8 text (1, 2, 6, 7), proof(nonce:note:) under the
//    same key equals HMAC over nonce + "\n" + note
//  - proof(nonce:note:) equals CryptoKit's HMAC-SHA256 over the UTF-8 of
//    nonce + "\n" + note, is 64 lowercase hex digits, and changes when only
//    the nonce, only the note or only the key changes
//  - innerBlockHex / outerBlockHex for key lengths 0, 3, 32, 63, 64, 65,
//    129, 131: 128 lowercase hex digits, the padded key XOR 0x36 / 0x5C,
//    the key SHA-256-hashed first when longer than 64 bytes; the blocks
//    reproduce proof
//  - textual forms of a key show neither its bytes nor its blocks
//  - random() gives 32 bytes, differs per call
//

import CryptoKit
import XCTest
@testable import Calyx

final class IPCWakeProofTests: XCTestCase {

    // MARK: - Fixtures

    private let nonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"
    private let note = "Calyx IPC: 1 new message from 1 peer."

    /// 32 bytes of 0x01.
    private let onesKey = IPCWakeProofKey(bytes: Data(repeating: 0x01, count: 32))
    private let countingKey = IPCWakeProofKey(bytes: Data((0..<32).map { UInt8($0) }))

    private let nonces = [
        "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112",
        "00000000-0000-0000-0000-000000000000",
        "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
    ]

    private let notes = [
        "Calyx IPC: 1 new message from 1 peer.",
        "Calyx IPC: 2 new messages from 2 peers (5 unread in total). Call the tool to read them.",
        "",
        "\u{65E5}\u{672C}\u{8A9E} caf\u{00E9} \u{1F680}",
    ]

    // MARK: - Helpers

    private typealias C = IPCWakeTestCrypto

    private func fromBlocks(
        _ key: IPCWakeProofKey, message: Data, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        try XCTUnwrap(
            C.proofFromBlocks(innerHex: key.innerBlockHex, outerHex: key.outerBlockHex, message: message),
            "both blocks must be hex", file: file, line: line
        )
    }

    private func assertIsLowercaseHex(
        _ text: String, count: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(text.count, count, "\(what) must be \(count) characters, got: \(text)", file: file, line: line)
        XCTAssertTrue(text.unicodeScalars.allSatisfy { "0123456789abcdef".unicodeScalars.contains($0) },
                      "\(what) must consist of lowercase hex digits only, got: \(text)", file: file, line: line)
    }

    /// The blocks reproduce proof (and CryptoKit's HMAC) for every fixture
    /// nonce and note.
    private func assertBlocksReproduceProof(
        _ key: IPCWakeProofKey, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for nonce in nonces {
            for note in notes {
                let message = Data((nonce + "\n" + note).utf8)
                let computed = try fromBlocks(key, message: message, file: file, line: line)
                XCTAssertEqual(computed, key.proof(nonce: nonce, note: note),
                               "[\(label) key, nonce \(nonce)] the blocks must reproduce proof", file: file, line: line)
                XCTAssertEqual(computed, C.hmacHex(keyBytes: key.bytes, nonce: nonce, note: note),
                               "[\(label) key, nonce \(nonce)] the blocks must reproduce HMAC-SHA256",
                               file: file, line: line)
            }
        }
    }

    // MARK: - RFC 4231

    private struct RFCCase {
        let label: String
        let key: Data
        let data: Data
        let digest: String
        /// Whether `data` is UTF-8 text that can go through proof().
        let textual: Bool
    }

    private var rfcCases: [RFCCase] {
        [
            RFCCase(label: "RFC 4231 case 1", key: Data(repeating: 0x0B, count: 20), data: Data("Hi There".utf8),
                    digest: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", textual: true),
            RFCCase(label: "RFC 4231 case 2", key: Data("Jefe".utf8),
                    data: Data("what do ya want for nothing?".utf8),
                    digest: "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", textual: true),
            RFCCase(label: "RFC 4231 case 3", key: Data(repeating: 0xAA, count: 20),
                    data: Data(repeating: 0xDD, count: 50),
                    digest: "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe", textual: false),
            RFCCase(label: "RFC 4231 case 4", key: Data((1...25).map { UInt8($0) }),
                    data: Data(repeating: 0xCD, count: 50),
                    digest: "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b", textual: false),
            RFCCase(label: "RFC 4231 case 6", key: Data(repeating: 0xAA, count: 131),
                    data: Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8),
                    digest: "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", textual: true),
            RFCCase(label: "RFC 4231 case 7", key: Data(repeating: 0xAA, count: 131),
                    data: Data(("This is a test using a larger than block-size key and a larger than block-size data. "
                                + "The key needs to be hashed before being used by the HMAC algorithm.").utf8),
                    digest: "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2", textual: true),
        ]
    }

    func test_rfc4231_blocksReproduceThePublishedDigests() throws {
        for testCase in rfcCases {
            XCTAssertEqual(C.hmacHex(keyBytes: testCase.key, message: testCase.data), testCase.digest,
                           "[\(testCase.label)] the vector in this test must be the published HMAC-SHA-256")
            let key = IPCWakeProofKey(bytes: testCase.key)
            assertIsLowercaseHex(key.innerBlockHex, count: 128, "[\(testCase.label)] innerBlockHex")
            assertIsLowercaseHex(key.outerBlockHex, count: 128, "[\(testCase.label)] outerBlockHex")
            XCTAssertEqual(try fromBlocks(key, message: testCase.data), testCase.digest,
                           "[\(testCase.label)] SHA256(outer || SHA256(inner || data)) must be the published digest")
        }
    }

    /// The RFC data contain no newline, so they cannot be fed to proof()
    /// as nonce + "\n" + note directly. Instead each textual vector is split
    /// at its first space into (nonce, note); proof under the RFC key must
    /// equal HMAC over nonce + "\n" + note, which CryptoKit (pinned to the
    /// published digest just above) computes.
    func test_rfc4231Keys_proofIsHMACOverNonceNewlineNote() throws {
        for testCase in rfcCases where testCase.textual {
            let text = try XCTUnwrap(String(data: testCase.data, encoding: .utf8))
            let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
            let (nonce, note) = (parts[0], parts[1])
            let key = IPCWakeProofKey(bytes: testCase.key)

            XCTAssertEqual(key.proof(nonce: nonce, note: note),
                           C.hmacHex(keyBytes: testCase.key, message: Data((nonce + "\n" + note).utf8)),
                           "[\(testCase.label)] proof must be HMAC-SHA256 over nonce + \"\\n\" + note")
            XCTAssertNotEqual(key.proof(nonce: nonce, note: note), testCase.digest,
                              "[\(testCase.label)] the separator must be a newline, not the original space")
        }
    }

    // MARK: - proof

    /// `printf '<nonce>\n<note>' | openssl dgst -sha256 -mac HMAC -macopt hexkey:0101...01`
    func test_proof_knownVector_computedWithOpenSSL() {
        XCTAssertEqual(onesKey.proof(nonce: nonce, note: note),
                       "4f24f1dab17f972c9eb885847f97ec4e537c0aa950729190762493d7c27a3c94")
    }

    func test_proof_equalsCryptoKitHMAC_overNonceNewlineNote_is64LowercaseHex() {
        for (label, key) in [("ones", onesKey), ("counting", countingKey)] {
            for nonce in nonces {
                for note in notes {
                    let proof = key.proof(nonce: nonce, note: note)
                    XCTAssertEqual(proof, C.hmacHex(keyBytes: key.bytes, nonce: nonce, note: note),
                                   "[\(label) key, nonce \(nonce), note \"\(note)\"]")
                    assertIsLowercaseHex(proof, count: 64, "[\(label) key] proof")
                }
            }
        }
    }

    /// J9 (spec C.2): the approval proof is HMAC over "approval\n" + nonce +
    /// "\n" + body under the same key. Computed here with CryptoKit so this
    /// file needs no planned API: no wake proof equals the approval proof
    /// for the same nonce and text, so neither verifies as the other.
    func test_proof_neverEqualsTheApprovalDomainProof_forTheSameNonceAndText() {
        for (label, key) in [("ones", onesKey), ("counting", countingKey)] {
            for nonce in nonces {
                for note in notes {
                    let approval = C.hmacHex(keyBytes: key.bytes, message: Data(("approval\n" + nonce + "\n" + note).utf8))
                    XCTAssertNotEqual(key.proof(nonce: nonce, note: note), approval,
                                      "[\(label) key, nonce \(nonce)] a wake proof is not an approval proof")
                }
            }
        }
    }

    func test_proof_changesWithTheNonce_theNote_andTheKey() {
        let base = onesKey.proof(nonce: nonces[0], note: notes[0])
        XCTAssertNotEqual(base, onesKey.proof(nonce: nonces[1], note: notes[0]), "the nonce is authenticated")
        XCTAssertNotEqual(base, onesKey.proof(nonce: nonces[0], note: notes[1]), "the note is authenticated")
        XCTAssertNotEqual(base, countingKey.proof(nonce: nonces[0], note: notes[0]), "the proof depends on the key")
    }

    // MARK: - Blocks by key length

    /// 0x01 ^ 0x36 = 0x37, 0x01 ^ 0x5C = 0x5D; zero padding gives 0x36 / 0x5C.
    func test_blocks_32OnesKey_areTheKeyZeroPaddedAndXORed() throws {
        XCTAssertEqual(onesKey.innerBlockHex, String(repeating: "37", count: 32) + String(repeating: "36", count: 32))
        XCTAssertEqual(onesKey.outerBlockHex, String(repeating: "5d", count: 32) + String(repeating: "5c", count: 32))
        try assertBlocksReproduceProof(onesKey, "32-byte")
    }

    /// 0x00 ^ 0x36 = 0x36, 0x0F ^ 0x36 = 0x39, 0xFF ^ 0x36 = 0xC9;
    /// 0x00 ^ 0x5C = 0x5C, 0x0F ^ 0x5C = 0x53, 0xFF ^ 0x5C = 0xA3.
    func test_blocks_threeByteKey_byHand() {
        let key = IPCWakeProofKey(bytes: Data([0x00, 0x0F, 0xFF]))
        XCTAssertEqual(key.innerBlockHex, "3639c9" + String(repeating: "36", count: 61))
        XCTAssertEqual(key.outerBlockHex, "5c53a3" + String(repeating: "5c", count: 61))
    }

    func test_blocks_emptyKey_areThePadsThemselves() throws {
        let key = IPCWakeProofKey(bytes: Data())
        XCTAssertEqual(key.innerBlockHex, String(repeating: "36", count: 64))
        XCTAssertEqual(key.outerBlockHex, String(repeating: "5c", count: 64))
        try assertBlocksReproduceProof(key, "empty")
    }

    /// 63 bytes of 0x01: one byte of padding at the end.
    func test_blocks_63ByteKey_padOneByte() throws {
        let key = IPCWakeProofKey(bytes: Data(repeating: 0x01, count: 63))
        XCTAssertEqual(key.innerBlockHex, String(repeating: "37", count: 63) + "36")
        XCTAssertEqual(key.outerBlockHex, String(repeating: "5d", count: 63) + "5c")
        try assertBlocksReproduceProof(key, "63-byte")
    }

    /// 64 bytes is the block size: used as it is, not hashed.
    func test_blocks_64ByteKey_areTheKeyItselfXORed() throws {
        let keyBytes = (0..<64).map { UInt8($0) }
        let key = IPCWakeProofKey(bytes: Data(keyBytes))
        XCTAssertEqual(key.innerBlockHex, C.hex(keyBytes.map { $0 ^ 0x36 }))
        XCTAssertEqual(key.outerBlockHex, C.hex(keyBytes.map { $0 ^ 0x5C }))
        try assertBlocksReproduceProof(key, "64-byte")
    }

    /// 65 and 129 bytes: replaced by the 32-byte SHA-256 digest first, then
    /// zero padded.
    func test_blocks_65And129ByteKeys_areTheSHA256OfTheKeyPaddedAndXORed() throws {
        for count in [65, 129] {
            let keyBytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7) })
            let key = IPCWakeProofKey(bytes: keyBytes)
            let hashed = [UInt8](SHA256.hash(data: keyBytes)) + [UInt8](repeating: 0, count: 32)
            XCTAssertEqual(key.innerBlockHex, C.hex(hashed.map { $0 ^ 0x36 }), "[\(count)-byte] inner block")
            XCTAssertEqual(key.outerBlockHex, C.hex(hashed.map { $0 ^ 0x5C }), "[\(count)-byte] outer block")
            assertIsLowercaseHex(key.innerBlockHex, count: 128, "[\(count)-byte] innerBlockHex")
            assertIsLowercaseHex(key.outerBlockHex, count: 128, "[\(count)-byte] outerBlockHex")
            try assertBlocksReproduceProof(key, "\(count)-byte")
        }
    }

    // MARK: - Textual forms

    func test_textualForms_showNeitherTheKeyBytesNorTheBlocks() {
        let keyBytes = (0xA0...0xBF).map { UInt8($0) }
        let key = IPCWakeProofKey(bytes: Data(keyBytes))
        let keyHex = C.hex(keyBytes)
        for (formName, form) in [("describing", String(describing: key)), ("reflecting", String(reflecting: key))] {
            for (secretName, secret) in [
                ("key hex", keyHex), ("KEY HEX", keyHex.uppercased()),
                ("inner block", key.innerBlockHex), ("outer block", key.outerBlockHex),
            ] {
                XCTAssertFalse(form.contains(secret), "String(\(formName):) must not contain the \(secretName): \(form)")
            }
        }
    }

    // MARK: - random

    func test_random_is32Bytes_andDiffersPerCall() {
        let keys = (0..<100).map { _ in IPCWakeProofKey.random() }
        XCTAssertTrue(keys.allSatisfy { $0.bytes.count == 32 }, "random() must give 32 bytes")
        XCTAssertEqual(Set(keys.map(\.bytes)).count, 100, "every call to random() must give a new key")
        XCTAssertFalse(keys.contains { $0.bytes == Data(count: 32) })
    }
}
