//
//  ApprovalHookResponseTests.swift
//  CalyxTests
//
//  Pins ApprovalHookResponse (spec C.3 G3, J7, C-D9): the wire format of a
//  signed `/approval-request` 200 answer. The expected values are written
//  out by hand from the spec, not derived from the type under test.
//
//  Planned API used here:
//    enum ApprovalHookResponse {
//        static let nonceHeader: String            // "X-Calyx-Approval-Nonce"
//        static let domainPrefix: String           // "approval\n"
//        static let proofLineBytes: Int            // 65 (64 hex digits + LF)
//        static let maxBodyBytes: Int              // 4 * CalyxMCPServer.maxEventBodyBytes
//        static let maxSignedResponseBytes: Int    // proofLineBytes + maxBodyBytes
//        static func message(nonce: String, body: Data) -> Data
//        static func signedBody(proof: String, body: Data) -> Data
//    }
//
//  Coverage:
//  - the constants' values (1,048,576 and 1,048,641 from 262,144)
//  - message = "approval\n" + nonce + "\n" + body, body bytes untouched
//  - signedBody = proof + LF + body, no trailing newline; an empty body
//    gives exactly 65 bytes
//

import XCTest
@testable import Calyx

final class ApprovalHookResponseTests: XCTestCase {

    private let nonce = "6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112"
    /// 64 lowercase hex digits; any value of the right shape will do.
    private let proof = String(repeating: "0123456789abcdef", count: 4)

    // MARK: - Constants

    func test_nonceHeader_isXCalyxApprovalNonce() {
        XCTAssertEqual(ApprovalHookResponse.nonceHeader, "X-Calyx-Approval-Nonce")
    }

    func test_domainPrefix_isApprovalNewline() {
        XCTAssertEqual(ApprovalHookResponse.domainPrefix, "approval\n")
        XCTAssertEqual(Array(ApprovalHookResponse.domainPrefix.utf8), [0x61, 0x70, 0x70, 0x72, 0x6F, 0x76, 0x61, 0x6C, 0x0A])
    }

    func test_proofLineBytes_is65() {
        XCTAssertEqual(ApprovalHookResponse.proofLineBytes, 65, "64 hex digits and one LF")
    }

    func test_maxBodyBytes_isFourTimesTheRequestCap() {
        // 4 * 262_144 (CalyxMCPServer's request body cap): `.answered`
        // echoes the whole tool_input back (spec C-D9).
        XCTAssertEqual(ApprovalHookResponse.maxBodyBytes, 1_048_576)
    }

    func test_maxSignedResponseBytes_isProofLinePlusMaxBody() {
        XCTAssertEqual(ApprovalHookResponse.maxSignedResponseBytes, 1_048_641, "65 + 4 * 262_144")
    }

    func test_approvalHookScript_interpolatesTheCapAndTheHeaderName() {
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("--max-filesize \(ApprovalHookResponse.maxSignedResponseBytes) \\\n"),
                      "curl's --max-filesize is ApprovalHookResponse.maxSignedResponseBytes (spec C-D9)")
        XCTAssertTrue(ApprovalHookScript.scriptBody.contains("-H \"\(ApprovalHookResponse.nonceHeader): $nonce\" \\\n"),
                      "the fifth header carries ApprovalHookResponse.nonceHeader")
    }

    // MARK: - message(nonce:body:)

    func test_message_isPrefixNonceNewlineBody() {
        let body = Data(#"{"hookSpecificOutput":{"decision":{"behavior":"deny"}}}"#.utf8)
        let expected = Data("approval\n6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112\n".utf8) + body
        XCTAssertEqual(ApprovalHookResponse.message(nonce: nonce, body: body), expected)
    }

    func test_message_emptyBody_endsWithTheNonceNewline() {
        XCTAssertEqual(ApprovalHookResponse.message(nonce: nonce, body: Data()),
                       Data("approval\n6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112\n".utf8))
    }

    func test_message_keepsArbitraryBodyBytes() {
        let body = Data([0x00, 0xFF, 0x0D, 0x0A, 0x80, 0x22, 0x5C])
        let message = ApprovalHookResponse.message(nonce: nonce, body: body)
        XCTAssertEqual(message.count, 9 + 36 + 1 + body.count)
        XCTAssertEqual(message.suffix(body.count), body, "the body bytes are appended unchanged")
        XCTAssertEqual(message.prefix(46), Data("approval\n6F1C2A9E-0B7D-4E21-9A53-C4D8E7F00112\n".utf8))
    }

    // MARK: - signedBody(proof:body:)

    func test_signedBody_isProofLFBody_noTrailingNewline() {
        let body = Data(#"{"a":1}"#.utf8)
        let signed = ApprovalHookResponse.signedBody(proof: proof, body: body)
        XCTAssertEqual(signed, Data((proof + "\n" + #"{"a":1}"#).utf8))
        XCTAssertEqual(signed.last, UInt8(ascii: "}"), "no newline is added after the body")
    }

    func test_signedBody_emptyBody_isExactly65Bytes() {
        let signed = ApprovalHookResponse.signedBody(proof: proof, body: Data())
        XCTAssertEqual(signed.count, 65)
        XCTAssertEqual(signed, Data((proof + "\n").utf8))
    }

    func test_signedBody_keepsArbitraryBodyBytes() {
        let body = Data([0x0A, 0x00, 0xFF, 0x0D])
        let signed = ApprovalHookResponse.signedBody(proof: proof, body: body)
        XCTAssertEqual(signed.count, 65 + 4)
        XCTAssertEqual(signed[signed.startIndex + 64], 0x0A, "the 65th byte is LF")
        XCTAssertEqual(signed.suffix(4), body)
    }
}
