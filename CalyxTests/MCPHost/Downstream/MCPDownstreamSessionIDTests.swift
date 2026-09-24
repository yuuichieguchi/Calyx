//
//  MCPDownstreamSessionIDTests.swift
//  CalyxTests
//
//  Coverage: `MCPDownstreamSessionID` (API contract section 10.4,
//  verbatim) -- the legacy `/calyx-mcp` HMAC-signed, stateless session
//  identifier minted on `initialize` and returned as `Mcp-Session-Id`.
//  Format: `v1.<b64url(payload)>.<b64url(HMAC-SHA256(key,payload))>`,
//  key derived from the server's own bearer token via HKDF. Signature
//  verification failure returns nil -- the caller (the router) is the
//  one that turns a nil into a 404, per section 10.4/10.10 ("the TS SDK
//  only redoes initialize on 404").
//
//  The HKDF salt/info byte-exact derivation is not pinned by the
//  contract, so these tests assert only externally observable
//  behavior: a session id minted with a given bearer token validates
//  against that SAME bearer token (including from a fresh `validate`
//  call with no shared object, so a restart -- no local state -- still
//  accepts it), never against a different one, and any tampering
//  invalidates it.
//

import XCTest
@testable import Calyx

final class MCPDownstreamSessionIDTests: XCTestCase {

    private func samplePayload(nonce: String = "nonce-1") -> MCPDownstreamSessionPayload {
        MCPDownstreamSessionPayload(
            version: 1,
            negotiatedProtocolVersion: "2025-11-25",
            clientDeclaredUI: true,
            clientName: "claude-code",
            nonce: nonce,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Format

    func test_mint_producesThreeDotSeparatedV1Value() {
        let value = MCPDownstreamSessionID.mint(payload: samplePayload(), bearerToken: "server-bearer-value")
        let parts = value.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 3, "value must be v1.<payload>.<signature>, actual: \(value)")
        XCTAssertEqual(parts[0], "v1")
        XCTAssertFalse(parts[1].isEmpty)
        XCTAssertFalse(parts[2].isEmpty)
    }

    // MARK: - Round trip

    func test_validate_roundTripsAllPayloadFields() {
        let payload = samplePayload()
        let value = MCPDownstreamSessionID.mint(payload: payload, bearerToken: "server-bearer-value")
        let validated = MCPDownstreamSessionID.validate(value, bearerToken: "server-bearer-value")
        XCTAssertEqual(validated, payload)
    }

    func test_validate_survivesAFreshValidatorCallWithTheSameBearerToken() {
        // No server-side state: the value alone (plus the same bearer
        // token) must validate, mirroring "state-less, survives a
        // restart" -- simulated here by validating through a completely
        // independent call.
        let value = MCPDownstreamSessionID.mint(payload: samplePayload(), bearerToken: "server-bearer-value")
        let validatedAgain = MCPDownstreamSessionID.validate(value, bearerToken: "server-bearer-value")
        XCTAssertNotNil(validatedAgain)
    }

    func test_clientDeclaredUIFalse_andNilClientName_roundTrip() {
        let payload = MCPDownstreamSessionPayload(
            version: 1, negotiatedProtocolVersion: "2025-03-26", clientDeclaredUI: false,
            clientName: nil, nonce: "n2", issuedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let value = MCPDownstreamSessionID.mint(payload: payload, bearerToken: "tok")
        XCTAssertEqual(MCPDownstreamSessionID.validate(value, bearerToken: "tok"), payload)
    }

    // MARK: - Wrong key / tampering

    func test_validate_differentBearerValue_returnsNil() {
        let value = MCPDownstreamSessionID.mint(payload: samplePayload(), bearerToken: "bearer-A")
        XCTAssertNil(MCPDownstreamSessionID.validate(value, bearerToken: "bearer-B"))
    }

    func test_validate_tamperedPayloadSegment_returnsNil() {
        let value = MCPDownstreamSessionID.mint(payload: samplePayload(), bearerToken: "tok")
        var parts = value.components(separatedBy: ".")
        XCTAssertEqual(parts.count, 3)
        // Flip the payload segment to a different, still-base64url-valid
        // string so the signature can no longer match.
        parts[1] = String(parts[1].reversed())
        let tampered = parts.joined(separator: ".")
        XCTAssertNil(MCPDownstreamSessionID.validate(tampered, bearerToken: "tok"))
    }

    func test_validate_tamperedSignatureSegment_returnsNil() {
        let value = MCPDownstreamSessionID.mint(payload: samplePayload(), bearerToken: "tok")
        var parts = value.components(separatedBy: ".")
        parts[2] = String(parts[2].reversed())
        let tampered = parts.joined(separator: ".")
        XCTAssertNil(MCPDownstreamSessionID.validate(tampered, bearerToken: "tok"))
    }

    func test_validate_malformedValue_missingSegments_returnsNil() {
        XCTAssertNil(MCPDownstreamSessionID.validate("not-a-value", bearerToken: "tok"))
        XCTAssertNil(MCPDownstreamSessionID.validate("v1.onlyonesegment", bearerToken: "tok"))
        XCTAssertNil(MCPDownstreamSessionID.validate("", bearerToken: "tok"))
    }

    func test_validate_wrongVersionPrefix_returnsNil() {
        let value = MCPDownstreamSessionID.mint(payload: samplePayload(), bearerToken: "tok")
        let parts = value.components(separatedBy: ".")
        let wrongVersion = (["v2"] + parts.dropFirst()).joined(separator: ".")
        XCTAssertNil(MCPDownstreamSessionID.validate(wrongVersion, bearerToken: "tok"))
    }

    // MARK: - Distinctness

    func test_differentNonces_produceDifferentValues() {
        let a = MCPDownstreamSessionID.mint(payload: samplePayload(nonce: "n-a"), bearerToken: "tok")
        let b = MCPDownstreamSessionID.mint(payload: samplePayload(nonce: "n-b"), bearerToken: "tok")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Statelessness: a session id remains valid after being "deleted"

    func test_validate_remainsValidAfterASeparateDeleteOperation_statelessByDesign() {
        // Section 10.4: DELETE /calyx-mcp closes the session's live GET
        // SSE stream and returns 200, but the signed session id itself is
        // never revoked (no server-side revocation memory). This is
        // exercised end-to-end at the router level; here it is pinned as
        // a property of validate() itself, which this file can assert
        // directly: nothing about validate() takes or requires mutable
        // server state, so two independent validate() calls against the
        // same minted value must both succeed.
        let value = MCPDownstreamSessionID.mint(payload: samplePayload(), bearerToken: "tok")
        XCTAssertNotNil(MCPDownstreamSessionID.validate(value, bearerToken: "tok"))
        XCTAssertNotNil(MCPDownstreamSessionID.validate(value, bearerToken: "tok"),
                        "a second, independent validate() call against the same minted value must still " +
                        "succeed -- MCPDownstreamSessionID has no revocation state to consult")
    }
}
