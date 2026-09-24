//
//  MCPOAuthPKCETests.swift
//  CalyxTests
//
//  API contract section 6.3.
//
//    enum MCPOAuthPKCE {
//        static func codeChallenge(forVerifier verifier: String) -> String   // base64url-no-padding(SHA256(verifier))
//        static func generateVerifier(randomBytes: @Sendable (Int) -> [UInt8] = ...) -> String   // 32 bytes, base64url-no-padding
//        static func generateState(randomBytes: @Sendable (Int) -> [UInt8] = ...) -> String
//    }
//

import XCTest
@testable import Calyx

final class MCPOAuthPKCETests: XCTestCase {

    // MARK: - codeChallenge: RFC 7636 Appendix B worked example

    func test_codeChallenge_matchesRFC7636AppendixBExample() {
        // RFC 7636 Appendix B's worked example, verified independently
        // with Python's hashlib.sha256 + url-safe base64 (no padding).
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(MCPOAuthPKCE.codeChallenge(forVerifier: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: - generateVerifier: exactly 32 random bytes, base64url-no-padding

    func test_generateVerifier_requestsExactly32Bytes_encodesBase64URLNoPadding() {
        let requestedLengths = Locked<[Int]>([])
        let randomBytes: @Sendable (Int) -> [UInt8] = { count in
            requestedLengths.withLock { $0.append(count) }
            return [UInt8](repeating: 0xAB, count: count)
        }
        let verifier = MCPOAuthPKCE.generateVerifier(randomBytes: randomBytes)
        XCTAssertEqual(requestedLengths.withLock { $0 }, [32])
        // Independently computed: base64.urlsafe_b64encode(bytes([0xAB]*32)).rstrip(b'=')
        XCTAssertEqual(verifier, "q6urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6s")
        XCTAssertFalse(verifier.contains("="))
        XCTAssertFalse(verifier.contains("+"))
        XCTAssertFalse(verifier.contains("/"))
    }

    // MARK: - generateState: exactly 32 random bytes, base64url-no-padding

    func test_generateState_requestsExactly32Bytes_encodesBase64URLNoPadding() {
        let requestedLengths = Locked<[Int]>([])
        let randomBytes: @Sendable (Int) -> [UInt8] = { count in
            requestedLengths.withLock { $0.append(count) }
            return [UInt8](repeating: 0xCD, count: count)
        }
        let state = MCPOAuthPKCE.generateState(randomBytes: randomBytes)
        XCTAssertEqual(requestedLengths.withLock { $0 }, [32])
        // Independently computed: base64.urlsafe_b64encode(bytes([0xCD]*32)).rstrip(b'=')
        XCTAssertEqual(state, "zc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc3Nzc0")
        XCTAssertFalse(state.contains("="))
    }

    // MARK: - Distinct byte sources produce distinct outputs

    func test_generateVerifier_andGenerateState_withDifferentBytes_produceDifferentStrings() {
        let verifier = MCPOAuthPKCE.generateVerifier(randomBytes: { count in [UInt8](repeating: 0x01, count: count) })
        let state = MCPOAuthPKCE.generateState(randomBytes: { count in [UInt8](repeating: 0x02, count: count) })
        XCTAssertNotEqual(verifier, state)
    }
}
