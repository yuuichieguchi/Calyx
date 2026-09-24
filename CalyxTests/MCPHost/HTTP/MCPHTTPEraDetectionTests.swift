//
//  MCPHTTPEraDetectionTests.swift
//  CalyxTests
//
//  Contract section 5.3: MCPHTTPEraDetector.classify is a pure,
//  non-throwing, single-probe function that maps one HTTP probe's status
//  (and whether its body is a recognized modern JSON-RPC error) to a
//  verdict.
//
//    enum MCPHTTPProbe: Sendable, Equatable { case discover, initialize }
//    enum MCPHTTPProbeVerdict: Sendable, Equatable {
//        case modern
//        case legacyStreamableHTTP
//        case fallBack
//        case legacySSERequired
//        case authorizationRequired
//        case failed
//    }
//    enum MCPHTTPEraDetector {
//        static func classify(probe: MCPHTTPProbe, status: Int, bodyIsRecognizedModernError: Bool) -> MCPHTTPProbeVerdict
//    }
//
//  Verdict table (section 5.3):
//    (.discover, 200, _)              -> .modern
//    (.discover, 400, true)           -> .modern
//    (.discover, 400/404/405, false)  -> .fallBack
//    (.initialize, 200, _)            -> .legacyStreamableHTTP
//    (.initialize, 400/404/405, _)    -> .legacySSERequired
//    (_, 401, _)                      -> .authorizationRequired
//    anything else (e.g. 5xx)         -> .failed
//
//  Waiting for `event: endpoint` and the same-origin check that follows a
//  .legacySSERequired verdict are LegacySSEMCPTransport.openStream()'s
//  responsibility (section 5.6), not this pure function's, and are
//  exercised in LegacySSEMCPTransportTests.swift instead.
//

import XCTest
@testable import Calyx

final class MCPHTTPEraDetectionTests: XCTestCase {

    // MARK: - discover probe

    func test_classify_discover200_isModern() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 200, bodyIsRecognizedModernError: false), .modern)
    }

    func test_classify_discover200_withRecognizedErrorBodyFlagIrrelevant_stillModern() {
        // The 200 status alone determines .modern; the flag only matters
        // for the 400 branch.
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 200, bodyIsRecognizedModernError: true), .modern)
    }

    func test_classify_discover400WithRecognizedModernErrorBody_isModern() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 400, bodyIsRecognizedModernError: true), .modern)
    }

    func test_classify_discover400WithUnrecognizedBody_isFallBack() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 400, bodyIsRecognizedModernError: false), .fallBack)
    }

    func test_classify_discover404WithUnrecognizedBody_isFallBack() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 404, bodyIsRecognizedModernError: false), .fallBack)
    }

    func test_classify_discover405WithUnrecognizedBody_isFallBack() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 405, bodyIsRecognizedModernError: false), .fallBack)
    }

    // MARK: - initialize probe

    func test_classify_initialize200_isLegacyStreamableHTTP() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .initialize, status: 200, bodyIsRecognizedModernError: false), .legacyStreamableHTTP)
    }

    func test_classify_initialize400_isLegacySSERequired() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .initialize, status: 400, bodyIsRecognizedModernError: false), .legacySSERequired)
    }

    func test_classify_initialize404_isLegacySSERequired() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .initialize, status: 404, bodyIsRecognizedModernError: false), .legacySSERequired)
    }

    func test_classify_initialize405_isLegacySSERequired() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .initialize, status: 405, bodyIsRecognizedModernError: false), .legacySSERequired)
    }

    // MARK: - 401 wins over the per-probe rules, for either probe

    func test_classify_discover401_isAuthorizationRequired() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 401, bodyIsRecognizedModernError: false), .authorizationRequired)
    }

    func test_classify_initialize401_isAuthorizationRequired() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .initialize, status: 401, bodyIsRecognizedModernError: false), .authorizationRequired)
    }

    // MARK: - anything else (5xx etc.) is .failed

    func test_classify_discover500_isFailed() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .discover, status: 500, bodyIsRecognizedModernError: false), .failed)
    }

    func test_classify_initialize503_isFailed() {
        XCTAssertEqual(MCPHTTPEraDetector.classify(probe: .initialize, status: 503, bodyIsRecognizedModernError: false), .failed)
    }
}
