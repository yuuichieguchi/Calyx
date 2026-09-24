//
//  MCPOAuthIssuerValidatorTests.swift
//  CalyxTests
//
//  API contract section 6.6. RFC 9207 `iss` parameter validation
//  (authorization-server-issuer-identification), exact string
//  comparison with no trailing-slash normalization.
//
//    enum MCPOAuthIssuerValidationError: Error, Sendable, Equatable { case missing, mismatch }
//    enum MCPOAuthIssuerValidator {
//        static func validate(issuerParameter: String?, recordedIssuer: String, serverAdvertisesIss: Bool) -> Result<Void, MCPOAuthIssuerValidationError>
//    }
//
//  `Result<Void, E>` is not `Equatable` (`Void` has no `Equatable`
//  conformance), so assertions switch on the case instead of comparing
//  whole `Result` values.
//

import XCTest
@testable import Calyx

final class MCPOAuthIssuerValidatorTests: XCTestCase {

    private func assertSuccess(_ result: Result<Void, MCPOAuthIssuerValidationError>, file: StaticString = #filePath, line: UInt = #line) {
        if case .failure(let error) = result {
            XCTFail("expected success, got \(error)", file: file, line: line)
        }
    }

    private func assertFailure(_ result: Result<Void, MCPOAuthIssuerValidationError>, _ expected: MCPOAuthIssuerValidationError, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success:
            XCTFail("expected failure \(expected)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Advertised, present, matches: succeeds

    func test_advertisedTrue_issPresent_matches_succeeds() {
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: "https://auth.example.com", recordedIssuer: "https://auth.example.com", serverAdvertisesIss: true)
        assertSuccess(result)
    }

    // MARK: - Advertised, absent: rejected (missing)

    func test_advertisedTrue_issAbsent_rejectedAsMissing() {
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: nil, recordedIssuer: "https://auth.example.com", serverAdvertisesIss: true)
        assertFailure(result, .missing)
    }

    // MARK: - Advertised, present, mismatch: rejected

    func test_advertisedTrue_issPresent_mismatch_rejected() {
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: "https://attacker.example.com", recordedIssuer: "https://auth.example.com", serverAdvertisesIss: true)
        assertFailure(result, .mismatch)
    }

    // MARK: - Not advertised, present: still compared

    func test_advertisedFalse_issPresent_mismatch_stillRejected() {
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: "https://attacker.example.com", recordedIssuer: "https://auth.example.com", serverAdvertisesIss: false)
        assertFailure(result, .mismatch)
    }

    func test_advertisedFalse_issPresent_matches_succeeds() {
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: "https://auth.example.com", recordedIssuer: "https://auth.example.com", serverAdvertisesIss: false)
        assertSuccess(result)
    }

    // MARK: - Not advertised, absent: proceeds

    func test_advertisedFalse_issAbsent_proceeds() {
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: nil, recordedIssuer: "https://auth.example.com", serverAdvertisesIss: false)
        assertSuccess(result)
    }

    // MARK: - Exact string comparison, no trailing-slash normalization

    func test_exactStringComparison_trailingSlashMakesItAMismatch() {
        // RFC 3986 6.2.1 simple string comparison: a trailing slash makes
        // the strings different and the validator must not normalize it away.
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: "https://auth.example.com/", recordedIssuer: "https://auth.example.com", serverAdvertisesIss: true)
        assertFailure(result, .mismatch)
    }

    func test_exactStringComparison_caseSensitivePathMakesItAMismatch() {
        let result = MCPOAuthIssuerValidator.validate(issuerParameter: "https://auth.example.com/Tenant1", recordedIssuer: "https://auth.example.com/tenant1", serverAdvertisesIss: true)
        assertFailure(result, .mismatch)
    }
}
