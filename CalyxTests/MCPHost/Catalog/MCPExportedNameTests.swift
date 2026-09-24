//
//  MCPExportedNameTests.swift
//  CalyxTests
//
//  Coverage: `MCPExportedName.name(alias:upstreamToolName:isTaken:)` -- the
//  re-published tool-name primitive from contract §7.8: `<alias>-<tool>`,
//  <= 48 characters (64 model function-name limit minus the longest CLI
//  prefix, 16), invalid characters in the tool part replaced with `_`, a
//  changed-or-truncated name gets a `-` plus the first 6 lowercase hex
//  characters of SHA-256(upstream name, UTF-8) appended (§7.8's own
//  worked example: `srv-get_wea-3fa9c1`, body truncated so the whole
//  name including the suffix stays within 48 characters), and a residual
//  collision (probed via the `isTaken` callback) extends that suffix to
//  the first 12 hex characters. A name that fits as-is and needs no
//  change must be returned without ever calling `isTaken`
//  ("そのまま収まり未使用の名前は isTaken を一切呼ばずに返す", §7.8 verbatim).
//

import CryptoKit
import XCTest
@testable import Calyx

final class MCPExportedNameTests: XCTestCase {

    /// The exact suffix §7.8 specifies: "-" + the first `hexChars`
    /// lowercase hex characters of SHA-256(upstreamToolName, UTF-8).
    private func hashSuffix(forUpstreamName upstreamToolName: String, hexChars: Int) -> String {
        let digest = SHA256.hash(data: Data(upstreamToolName.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "-" + String(hex.prefix(hexChars))
    }

    // MARK: - Verbatim (no change, fits, not taken)

    func test_verbatimName_unchangedAndFits_returnedAsIs() {
        let name = MCPExportedName.name(alias: "myserver", upstreamToolName: "get_weather", isTaken: { _ in false })
        XCTAssertEqual(name, "myserver-get_weather")
    }

    func test_verbatimAndUntakenName_neverCallsIsTaken() {
        // A candidate that fits and needs no sanitization/truncation is
        // returned without ever probing `isTaken` -- probing only exists
        // to detect and resolve collisions on changed/truncated names.
        var probed: [String] = []
        let name = MCPExportedName.name(alias: "srv", upstreamToolName: "tool", isTaken: { candidate in
            probed.append(candidate)
            return false
        })
        XCTAssertEqual(name, "srv-tool")
        XCTAssertTrue(probed.isEmpty, "a name that fits and needs no change must never call isTaken, actual probes: \(probed)")
    }

    // MARK: - Invalid characters replaced, hash appended

    func test_invalidCharacters_replacedWithUnderscore_andHashAppended() {
        let upstreamName = "get weather!"
        let sanitizedOnly = "srv-get_weather_"   // space and "!" both become "_"
        let name = MCPExportedName.name(alias: "srv", upstreamToolName: upstreamName, isTaken: { _ in false })
        XCTAssertTrue(name.hasPrefix(sanitizedOnly),
                      "invalid characters (space, !) must become _, actual: \(name)")
        let expectedSuffix = hashSuffix(forUpstreamName: upstreamName, hexChars: 6)
        XCTAssertEqual(name, sanitizedOnly + expectedSuffix)
    }

    // MARK: - Exact hash suffix format (§7.8: "-" + first 6 lowercase hex
    // chars of SHA-256(upstream name, UTF-8), worked example "srv-get_wea-3fa9c1")

    func test_hashSuffix_isDashPlusFirstSixLowercaseHexCharsOfSHA256OfUpstreamName() {
        let upstreamName = "bad name!"
        let name = MCPExportedName.name(alias: "srv", upstreamToolName: upstreamName, isTaken: { _ in false })
        let expectedSuffix = hashSuffix(forUpstreamName: upstreamName, hexChars: 6)
        XCTAssertTrue(name.hasSuffix(expectedSuffix),
                      "expected the name to end with \(expectedSuffix) (first 6 lowercase hex chars of " +
                      "SHA-256(\"\(upstreamName)\")), actual: \(name)")
    }

    func test_onlyValidCharacters_neverModified() {
        // [A-Za-z0-9_-] is the accepted charset -- a name using exactly
        // that set must round-trip with no hash suffix at all.
        let name = MCPExportedName.name(alias: "srv", upstreamToolName: "Get-Weather_123", isTaken: { _ in false })
        XCTAssertEqual(name, "srv-Get-Weather_123")
    }

    // MARK: - Too long: truncated, hash appended, total <= 48

    func test_tooLong_truncatedWithHashAppended_totalWithinMaxLength() {
        let longTool = String(repeating: "a", count: 80)
        let name = MCPExportedName.name(alias: "myserver", upstreamToolName: longTool, isTaken: { _ in false })
        XCTAssertLessThanOrEqual(name.count, 48, "exported name must never exceed 48 characters, actual: \(name.count)")
        XCTAssertNotEqual(name, "myserver-" + String(repeating: "a", count: 39),
                          "a truncated name must carry a hash suffix, not just a bare truncation, actual: \(name)")
    }

    func test_tooLong_bodyTruncatedSoTotalIsExactly48CharsWithSuffix() {
        // alias(8) + "-"(1) + body + "-"(1) + hex6(6) must total 48, so
        // body is truncated to 48 - 8 - 1 - 1 - 6 = 32 characters. The
        // hash is over the FULL untruncated upstream name (§7.8: "上流名
        // の SHA-256"), not the truncated body.
        let alias = "myserver"
        let longTool = String(repeating: "a", count: 80)
        let name = MCPExportedName.name(alias: alias, upstreamToolName: longTool, isTaken: { _ in false })
        let suffix = hashSuffix(forUpstreamName: longTool, hexChars: 6)
        let expectedBody = String(repeating: "a", count: 48 - alias.count - 1 - suffix.count)
        XCTAssertEqual(name, "\(alias)-\(expectedBody)\(suffix)")
        XCTAssertEqual(name.count, 48)
    }

    func test_exactly48Chars_unchanged_noHashNeeded() {
        // alias(3) + "-"(1) + tool(44) = 48, fits exactly with no
        // sanitization needed -- must not be truncated or hashed.
        let tool = String(repeating: "b", count: 44)
        let name = MCPExportedName.name(alias: "srv", upstreamToolName: tool, isTaken: { _ in false })
        XCTAssertEqual(name, "srv-" + tool)
        XCTAssertEqual(name.count, 48)
    }

    // MARK: - Determinism and distinctness

    func test_determinism_sameInputs_sameOutput() {
        let a = MCPExportedName.name(alias: "srv", upstreamToolName: "weird tool!", isTaken: { _ in false })
        let b = MCPExportedName.name(alias: "srv", upstreamToolName: "weird tool!", isTaken: { _ in false })
        XCTAssertEqual(a, b, "the same alias/upstream-name pair must always produce the same exported name")
    }

    func test_distinctUpstreamNames_sanitizingToTheSameString_produceDistinctExportedNames() {
        // Two different upstream names that sanitize to the identical
        // tool part must still end up with distinct exported names --
        // the hash is derived from the UPSTREAM name, not the sanitized
        // one, so two genuinely different tools never collide silently.
        let upstreamA = "foo/bar"
        let upstreamB = "foo:bar"
        let a = MCPExportedName.name(alias: "srv", upstreamToolName: upstreamA, isTaken: { _ in false })
        let b = MCPExportedName.name(alias: "srv", upstreamToolName: upstreamB, isTaken: { _ in false })
        let sanitizedOnly = "srv-foo_bar"
        XCTAssertEqual(a, sanitizedOnly + hashSuffix(forUpstreamName: upstreamA, hexChars: 6))
        XCTAssertEqual(b, sanitizedOnly + hashSuffix(forUpstreamName: upstreamB, hexChars: 6))
        XCTAssertNotEqual(a, b, "distinct upstream names sanitizing to the same tool part must not collide")
    }

    // MARK: - Residual collision extends the hash suffix to the first 12 hex characters

    func test_residualCollision_viaIsTaken_extendsSuffixToFirst12HexChars() {
        let upstreamName = "bad name!"
        var callCount = 0
        let collided = MCPExportedName.name(alias: "srv", upstreamToolName: upstreamName, isTaken: { _ in
            callCount += 1
            // The first probed (6-hex-char) candidate is reported taken;
            // every subsequent probe (the 12-hex-char extension) is free.
            return callCount == 1
        })

        XCTAssertGreaterThanOrEqual(callCount, 2, "a collision on the 6-hex-char candidate must trigger a retry")
        let expectedSuffix = hashSuffix(forUpstreamName: upstreamName, hexChars: 12)
        XCTAssertTrue(collided.hasSuffix(expectedSuffix),
                      "expected the name to end with \(expectedSuffix) (first 12 lowercase hex chars of " +
                      "SHA-256(\"\(upstreamName)\")) once the 6-char candidate collides, actual: \(collided)")
        XCTAssertLessThanOrEqual(collided.count, 48)
    }
}
