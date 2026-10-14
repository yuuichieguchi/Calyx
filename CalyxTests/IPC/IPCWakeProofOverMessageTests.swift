//
//  IPCWakeProofOverMessageTests.swift
//  CalyxTests
//
//  Pins `IPCWakeProofKey.proof(over:)` (spec C.3 G3) and the domain
//  separation between the wake proof and the approval proof (J9).
//  `proof(nonce:note:)` delegates to `proof(over:)` with the wake layout
//  `nonce + "\n" + note`; the approval layout is
//  `"approval\n" + nonce + "\n" + body` (ApprovalHookResponse.message).
//
//  Planned API used here:
//    extension IPCWakeProofKey { func proof(over message: Data) -> String }
//    enum ApprovalHookResponse { static func message(nonce: String, body: Data) -> Data }
//
//  Reference values: RFC 4231 HMAC-SHA-256 cases 1-4, 6, 7 (published
//  digests) and CryptoKit via IPCWakeTestCrypto.
//

import XCTest
@testable import Calyx

final class IPCWakeProofOverMessageTests: XCTestCase {

    private typealias C = IPCWakeTestCrypto

    private let keys = [
        IPCWakeProofKey(bytes: Data(repeating: 0x01, count: 32)),
        IPCWakeProofKey(bytes: Data((0..<32).map { UInt8($0) })),
    ]

    private let nonces = [
        "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112",
        "00000000-0000-0000-0000-000000000000",
    ]

    private let notes = [
        "Calyx IPC: 1 new message from 1 peer.",
        "",
        #"{"hookSpecificOutput":{"decision":{"behavior":"deny"}}}"#,
    ]

    func test_proofOver_rfc4231_reproducesThePublishedDigests() {
        let cases: [(String, Data, Data, String)] = [
            ("case 1", Data(repeating: 0x0B, count: 20), Data("Hi There".utf8),
             "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"),
            ("case 2", Data("Jefe".utf8), Data("what do ya want for nothing?".utf8),
             "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"),
            ("case 3", Data(repeating: 0xAA, count: 20), Data(repeating: 0xDD, count: 50),
             "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"),
            ("case 4", Data((1...25).map { UInt8($0) }), Data(repeating: 0xCD, count: 50),
             "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"),
            ("case 6", Data(repeating: 0xAA, count: 131),
             Data("Test Using Larger Than Block-Size Key - Hash Key First".utf8),
             "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"),
            ("case 7", Data(repeating: 0xAA, count: 131),
             Data(("This is a test using a larger than block-size key and a larger than block-size data. "
                   + "The key needs to be hashed before being used by the HMAC algorithm.").utf8),
             "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"),
        ]
        for (label, key, data, digest) in cases {
            XCTAssertEqual(IPCWakeProofKey(bytes: key).proof(over: data), digest, "RFC 4231 \(label)")
        }
    }

    func test_proofOver_wakeLayout_equalsProofNonceNote() {
        for key in keys {
            for nonce in nonces {
                for note in notes {
                    XCTAssertEqual(key.proof(over: Data((nonce + "\n" + note).utf8)), key.proof(nonce: nonce, note: note),
                                   "proof(nonce:note:) is proof(over:) of nonce + LF + note")
                }
            }
        }
    }

    func test_proofOver_approvalMessage_isHMACOverApprovalPrefixNonceBody() {
        for key in keys {
            for nonce in nonces {
                for note in notes {
                    let body = Data(note.utf8)
                    let message = Data(("approval\n" + nonce + "\n").utf8) + body
                    XCTAssertEqual(key.proof(over: ApprovalHookResponse.message(nonce: nonce, body: body)),
                                   C.hmacHex(keyBytes: key.bytes, message: message))
                }
            }
        }
    }

    /// J9: under the same key and nonce, an approval proof never verifies as
    /// a wake proof and a wake proof never verifies as an approval proof.
    func test_domainSeparation_approvalAndWakeProofsNeverCoincide() {
        for key in keys {
            for nonce in nonces {
                for note in notes {
                    let approval = key.proof(over: ApprovalHookResponse.message(nonce: nonce, body: Data(note.utf8)))
                    let wake = key.proof(nonce: nonce, note: note)
                    XCTAssertNotEqual(approval, wake, "an approval proof is not a wake proof for the same nonce and text")
                    // A wake note crafted to look like the approval message
                    // tail still yields a different message: the wake
                    // message starts with the nonce, the approval one with
                    // "approval\n".
                    XCTAssertNotEqual(key.proof(nonce: nonce, note: "approval\n" + nonce + "\n" + note), approval)
                }
            }
        }
    }

    func test_approvalMessage_startsWithApprovalPrefix_wakeMessageWithTheNonce() {
        let nonce = nonces[0]
        let approval = ApprovalHookResponse.message(nonce: nonce, body: Data("x".utf8))
        XCTAssertEqual(approval.prefix(9), Data("approval\n".utf8))
        XCTAssertNotEqual(approval.prefix(36), Data(nonce.utf8))
    }
}
