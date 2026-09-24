//
//  MCPAppCSPBuilderTests.swift
//  CalyxTests
//
//  MCPAppCSPBuilder is pure: given the resource's declared `_meta.ui.csp`
//  domains (or none) it produces the exact Content-Security-Policy string
//  the view's WKWebView response carries, plus a WKContentRuleList JSON
//  document providing defense in depth. Values are pinned against the
//  ext-apps reference host (examples/basic-host/serve.ts, buildCspHeader):
//  the same directives whether `csp` is omitted or declared, an omitted
//  `csp` being the declared form with every domain list empty. The
//  reference apps (map/CesiumJS, threejs) rely on its 'unsafe-eval' and
//  blob: workers, so Calyx is not stricter than it.
//  Calyx adds form-action 'none' and frame-ancestors <hostOrigin>.
//

import XCTest
@testable import Calyx

final class MCPAppCSPBuilderTests: XCTestCase {

    private let hostOrigin = "calyx-mcp-host://abc123"

    // MARK: - Exact default policy (csp omitted)

    func test_defaultPolicy_omittedCSP_matchesReferenceHostWithNoDomains() {
        let result = MCPAppCSPBuilder.buildPolicy(csp: nil, hostOrigin: hostOrigin)

        let expected = [
            "default-src 'self' 'unsafe-inline'",
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data:",
            "style-src 'self' 'unsafe-inline' blob: data:",
            "img-src 'self' data: blob:",
            "font-src 'self' data: blob:",
            "media-src 'self' data: blob:",
            "connect-src 'self'",
            "worker-src 'self' blob:",
            "frame-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors \(hostOrigin)",
        ].joined(separator: "; ") + ";"

        XCTAssertEqual(result.policy, expected)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func test_declaredCSP_cesiumResourceDomain_matchesReferenceHostExactly() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["https://*.cesium.com"], connectDomains: [], frameDomains: [], baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        let expected = [
            "default-src 'self' 'unsafe-inline'",
            "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data: https://*.cesium.com",
            "style-src 'self' 'unsafe-inline' blob: data: https://*.cesium.com",
            "img-src 'self' data: blob: https://*.cesium.com",
            "font-src 'self' data: blob: https://*.cesium.com",
            "media-src 'self' data: blob: https://*.cesium.com",
            "connect-src 'self'",
            "worker-src 'self' blob: https://*.cesium.com",
            "frame-src 'none'",
            "object-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-ancestors \(hostOrigin)",
        ].joined(separator: "; ") + ";"

        XCTAssertEqual(result.policy, expected)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func test_defaultPolicy_omittedCSP_hasNoDroppedEntries() {
        let result = MCPAppCSPBuilder.buildPolicy(csp: nil, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - Domain mapping when csp IS declared

    func test_domainMapping_resourceDomains_appliedToScriptStyleImgFontMediaWorkerSrc() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["https://cdn.jsdelivr.net"],
            connectDomains: [],
            frameDomains: [],
            baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        XCTAssertTrue(result.policy.contains("script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data: https://cdn.jsdelivr.net;"))
        XCTAssertTrue(result.policy.contains("style-src 'self' 'unsafe-inline' blob: data: https://cdn.jsdelivr.net;"))
        XCTAssertTrue(result.policy.contains("img-src 'self' data: blob: https://cdn.jsdelivr.net;"))
        XCTAssertTrue(result.policy.contains("font-src 'self' data: blob: https://cdn.jsdelivr.net;"))
        XCTAssertTrue(result.policy.contains("media-src 'self' data: blob: https://cdn.jsdelivr.net;"))
        XCTAssertTrue(result.policy.contains("worker-src 'self' blob: https://cdn.jsdelivr.net;"))
    }

    func test_domainMapping_connectDomains_appliedToConnectSrcWithSelf() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: [], connectDomains: ["https://api.openweathermap.org"], frameDomains: [], baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        XCTAssertTrue(result.policy.contains("connect-src 'self' https://api.openweathermap.org"))
    }

    func test_domainMapping_frameDomains_absent_fallsBackToNone() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        XCTAssertTrue(result.policy.contains("frame-src 'none'"))
    }

    func test_domainMapping_frameDomains_present_usedVerbatim() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: [], connectDomains: [], frameDomains: ["https://embed.example.com"], baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        XCTAssertTrue(result.policy.contains("frame-src https://embed.example.com"))
    }

    func test_domainMapping_baseUriDomains_absent_fallsBackToNone() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        XCTAssertTrue(result.policy.contains("base-uri 'none'"))
    }

    func test_domainMapping_baseUriDomains_present_usedVerbatim() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: [], connectDomains: [], frameDomains: [], baseUriDomains: ["https://example.com"]
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        XCTAssertTrue(result.policy.contains("base-uri https://example.com"))
    }

    // MARK: - Calyx-added hardening directives (always present)

    func test_addedDirectives_objectSrcFormActionFrameAncestors_alwaysPresent() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["https://cdn.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)

        XCTAssertTrue(result.policy.contains("object-src 'none'"))
        XCTAssertTrue(result.policy.contains("form-action 'none'"))
        XCTAssertTrue(result.policy.contains("frame-ancestors \(hostOrigin)"))
    }

    // MARK: - Accepted domain forms

    func test_acceptedForms_bareHost_isKept() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["api.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertTrue(result.policy.contains("api.example.com"))
    }

    func test_acceptedForms_wildcardSubdomain_isKept() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["*.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertTrue(result.policy.contains("*.example.com"))
    }

    func test_acceptedForms_httpsSchemeWithPort_isKept() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["https://example.com:8443"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func test_acceptedForms_wssScheme_isKept() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: ["wss://example.com"], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    func test_acceptedForms_httpLoopback_isKept() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["http://127.0.0.1:9000"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - Scheme-less entries are normalized to https

    func test_schemeless_bareHost_appearsInPolicyAsHTTPSOrigin() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: ["evil.example.com"], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
        let connectDirective = result.policy.components(separatedBy: "; ").first { $0.hasPrefix("connect-src") }
        XCTAssertEqual(connectDirective, "connect-src 'self' https://evil.example.com")
    }

    func test_schemeless_hostWithPort_appearsInPolicyAsHTTPSOrigin() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: ["evil.example.com:8443"], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertTrue(result.dropped.isEmpty)
        let connectDirective = result.policy.components(separatedBy: "; ").first { $0.hasPrefix("connect-src") }
        XCTAssertEqual(connectDirective, "connect-src 'self' https://evil.example.com:8443")
    }

    func test_schemeless_andExplicitHTTPS_sameHost_collapseToOneEntry() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["a.example.com", "https://a.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        let scriptDirective = result.policy.components(separatedBy: "; ").first { $0.hasPrefix("script-src") }
        XCTAssertEqual(scriptDirective, "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data: https://a.example.com")
    }

    func test_schemeless_ruleListLiftsExactlyTheHTTPSOrigin() throws {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: ["evil.example.com"], frameDomains: [], baseUriDomains: [])
        let json = MCPAppCSPBuilder.contentRuleList(csp: csp, hostOrigin: hostOrigin, calyxOrigins: [])
        let rules = try decodeRules(json)
        let ignoreFilters: [String] = rules.dropFirst().compactMap {
            ($0["trigger"] as? [String: String])?["url-filter"]
        }

        let filter = try XCTUnwrap(ignoreFilters.first { $0.contains("evil\\.example\\.com") })
        XCTAssertEqual(filter, "^https://evil\\.example\\.com[:/]")
        let regex = try NSRegularExpression(pattern: filter)
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        XCTAssertTrue(matches("https://evil.example.com/x"))
        XCTAssertFalse(matches("http://evil.example.com/x"))
        XCTAssertFalse(matches("ws://evil.example.com/x"))
    }

    func test_httpNonLoopback_stillDroppedWithInsecureSchemeReason() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [], connectDomains: ["http://evil.example.com"], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["http://evil.example.com"])
        XCTAssertEqual(result.dropped.map(\.reason), ["plain http and ws are allowed only for loopback hosts"])
        XCTAssertFalse(result.policy.contains("evil.example.com"))
    }

    func test_applied_reportsNormalizedAcceptedEntries_withoutDroppedOnes() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["cdn.example.com", "http://evil.example.com"],
            connectDomains: ["api.example.com:8443", "wss://ws.example.com"],
            frameDomains: ["*"],
            baseUriDomains: ["https://base.example.com"]
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.applied, MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["https://cdn.example.com"],
            connectDomains: ["https://api.example.com:8443", "wss://ws.example.com"],
            frameDomains: [],
            baseUriDomains: ["https://base.example.com"]
        ))
    }

    func test_applied_omittedCSP_isNil() {
        let result = MCPAppCSPBuilder.buildPolicy(csp: nil, hostOrigin: hostOrigin)
        XCTAssertNil(result.applied)
    }

    // MARK: - Rejected domain forms, each with a distinct reported reason

    func test_rejectedForms_httpNonLoopback_isDroppedWithReason() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["http://example.com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.count, 1)
        XCTAssertEqual(result.dropped[0].raw, "http://example.com")
        XCTAssertFalse(result.dropped[0].reason.isEmpty)
        XCTAssertFalse(result.policy.contains("http://example.com"))
    }

    func test_rejectedForms_semicolon_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["example.com; evil.com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["example.com; evil.com"])
    }

    func test_rejectedForms_comma_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["example.com,evil.com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["example.com,evil.com"])
    }

    func test_rejectedForms_quote_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["example.com'"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["example.com'"])
    }

    func test_rejectedForms_whitespace_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["example .com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["example .com"])
    }

    func test_rejectedForms_crlf_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["example.com\r\nX-Injected: 1"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["example.com\r\nX-Injected: 1"])
    }

    func test_rejectedForms_controlCharacter_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["example.com\u{0007}"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["example.com\u{0007}"])
    }

    func test_rejectedForms_bareAsterisk_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["*"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["*"])
    }

    func test_rejectedForms_schemeOnly_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["https://"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["https://"])
    }

    func test_rejectedForms_schemelessWithoutHost_isDroppedAsMalformedHost() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["/assets"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), ["/assets"])
        XCTAssertEqual(result.dropped.map(\.reason), ["the host is not a valid host name"])
    }

    func test_rejectedForms_empty_isDropped() {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: [""], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.map(\.raw), [""])
    }

    func test_rejectedForms_httpNonLoopback_and_valid_reportedReasonsAreDistinctByFailureKind() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["http://example.com", "example.com;drop"], connectDomains: [], frameDomains: [], baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(result.dropped.count, 2)
        XCTAssertNotEqual(result.dropped[0].reason, result.dropped[1].reason,
            "each failure kind (insecure scheme vs. illegal character) must report a distinct reason")
    }

    // MARK: - Deterministic ordering and dedup

    func test_ordering_domainsAppearInDeclaredOrder_deterministic() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["z.example.com", "a.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: []
        )
        let first = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        let second = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        XCTAssertEqual(first.policy, second.policy)

        let scriptDirective = first.policy
            .components(separatedBy: "; ")
            .first { $0.hasPrefix("script-src") }
        XCTAssertEqual(scriptDirective, "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data: https://z.example.com https://a.example.com")
    }

    func test_dedup_duplicateDomainsCollapsedToOne() {
        let csp = MCPAppCSPBuilder.CSPDomains(
            resourceDomains: ["a.example.com", "a.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: []
        )
        let result = MCPAppCSPBuilder.buildPolicy(csp: csp, hostOrigin: hostOrigin)
        let scriptDirective = result.policy.components(separatedBy: "; ").first { $0.hasPrefix("script-src") }
        XCTAssertEqual(scriptDirective, "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data: https://a.example.com")
    }

    // MARK: - WKContentRuleList JSON

    func test_contentRuleList_blockAllRuleIsFirst() throws {
        let json = MCPAppCSPBuilder.contentRuleList(csp: nil, hostOrigin: hostOrigin, calyxOrigins: ["calyx-mcp-app://xyz"])
        let rules = try decodeRules(json)

        XCTAssertEqual(rules.first?["trigger"] as? [String: Any] != nil, true)
        let trigger = try XCTUnwrap(rules.first?["trigger"] as? [String: String])
        XCTAssertEqual(trigger["url-filter"], ".*")
        let action = try XCTUnwrap(rules.first?["action"] as? [String: String])
        XCTAssertEqual(action["type"], "block")
    }

    func test_contentRuleList_ignoreRules_coverCalyxOriginsDataBlobAbout() throws {
        let json = MCPAppCSPBuilder.contentRuleList(csp: nil, hostOrigin: hostOrigin, calyxOrigins: ["calyx-mcp-app://xyz"])
        let rules = try decodeRules(json)
        let ignoreFilters: [String] = rules.dropFirst().compactMap {
            guard let action = $0["action"] as? [String: String], action["type"] == "ignore-previous-rules" else { return nil }
            return ($0["trigger"] as? [String: String])?["url-filter"]
        }

        XCTAssertTrue(ignoreFilters.contains(where: { $0.contains("calyx-mcp-host://") }))
        XCTAssertTrue(ignoreFilters.contains(where: { $0.contains("calyx-mcp-app://xyz") }))
        XCTAssertTrue(ignoreFilters.contains(where: { $0.hasPrefix("^data:") }))
        XCTAssertTrue(ignoreFilters.contains(where: { $0.hasPrefix("^blob:") }))
        XCTAssertTrue(ignoreFilters.contains(where: { $0.hasPrefix("^about:") }))
    }

    func test_contentRuleList_appliedDomain_getsIgnoreRule_withEscapedRegex() throws {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["cdn.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let json = MCPAppCSPBuilder.contentRuleList(csp: csp, hostOrigin: hostOrigin, calyxOrigins: [])
        let rules = try decodeRules(json)
        let ignoreFilters: [String] = rules.dropFirst().compactMap {
            ($0["trigger"] as? [String: String])?["url-filter"]
        }

        // a literal dot in the domain must be escaped in the regex (\.), never left
        // as a regex metacharacter that would match any character.
        XCTAssertTrue(ignoreFilters.contains(where: { $0.contains("cdn\\.example\\.com") }))
        XCTAssertFalse(ignoreFilters.contains(where: { $0.contains("cdnXexampleXcom") }))
    }

    func test_contentRuleList_wildcardSubdomain_becomesOptionalSubdomainGroup() throws {
        let csp = MCPAppCSPBuilder.CSPDomains(resourceDomains: ["*.example.com"], connectDomains: [], frameDomains: [], baseUriDomains: [])
        let json = MCPAppCSPBuilder.contentRuleList(csp: csp, hostOrigin: hostOrigin, calyxOrigins: [])
        let rules = try decodeRules(json)
        let ignoreFilters: [String] = rules.dropFirst().compactMap {
            ($0["trigger"] as? [String: String])?["url-filter"]
        }

        // `*.example.com` must match both `example.com` and `foo.example.com`,
        // i.e. the leading label is an OPTIONAL group, not a mandatory one.
        let matching = ignoreFilters.first { $0.contains("example\\.com") }
        let filter = try XCTUnwrap(matching)
        let regex = try NSRegularExpression(pattern: filter)
        func matches(_ s: String) -> Bool {
            regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        XCTAssertTrue(matches("https://example.com/x"))
        XCTAssertTrue(matches("https://foo.example.com/x"))
    }

    private func decodeRules(_ json: String) throws -> [[String: Any]] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(obj as? [[String: Any]])
    }
}
