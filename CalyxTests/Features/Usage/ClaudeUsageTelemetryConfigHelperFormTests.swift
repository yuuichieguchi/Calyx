//
//  ClaudeUsageTelemetryConfigHelperFormTests.swift
//  CalyxTests
//
//  Feature C, G5 (spec note 22): `isHelperCommand` recognises the new
//  helper form `"<path ending in /calyx-usage-headers>" <digits>` AND the
//  legacy `cat '<...>' 2>/dev/null || printf '{}'` form, so `state` and
//  `removing` treat either as Calyx's. Uses only `isHelperCommand`,
//  `state(of:)` and `removing(from:)`; values are written by hand.
//

import XCTest
@testable import Calyx

final class ClaudeUsageTelemetryConfigHelperFormTests: XCTestCase {

    private typealias Config = ClaudeUsageTelemetryConfig

    private static let newHelper = "\"/Users/test/Library/Application Support/Calyx/bin/calyx-usage-headers\" 41830"
    /// `newHelper` as a JSON string literal.
    private static let newHelperJSON = "\"\\\"/Users/test/Library/Application Support/Calyx/bin/calyx-usage-headers\\\" 41830\""
    private static let legacyHelper = "cat '/Users/test/Library/Application Support/Calyx/usage-otel-headers.json' 2>/dev/null || printf '{}'"

    private static let calyxEnvJSON = """
    {"CLAUDE_CODE_ENABLE_TELEMETRY":"1","OTEL_METRICS_EXPORTER":"otlp",\
    "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL":"http/json",\
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT":"http://127.0.0.1:41830/usage/v1/metrics",\
    "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE":"cumulative",\
    "OTEL_EXPORTER_OTLP_METRICS_COMPRESSION":"none","OTEL_METRIC_EXPORT_INTERVAL":"5000",\
    "OTEL_METRICS_INCLUDE_SESSION_ID":"true","OTEL_METRICS_INCLUDE_ACCOUNT_UUID":"false"}
    """

    private func data(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - isHelperCommand

    func test_isHelperCommand_acceptsTheNewForm() {
        XCTAssertTrue(Config.isHelperCommand(Self.newHelper))
        XCTAssertTrue(Config.isHelperCommand("\"/tmp/bin/calyx-usage-headers\" 1"))
        XCTAssertTrue(Config.isHelperCommand("\"/tmp/bin/calyx-usage-headers\" 65535"))
        XCTAssertTrue(Config.isHelperCommand("\"/tmp/it's/bin/calyx-usage-headers\" 41830"))
    }

    func test_isHelperCommand_stillAcceptsTheLegacyForm() {
        XCTAssertTrue(Config.isHelperCommand(Self.legacyHelper))
    }

    func test_isHelperCommand_rejectsNewFormNearMisses() {
        let rejected = [
            // another script name
            "\"/tmp/bin/calyx-mcp-headers\" 41830",
            "\"/tmp/bin/calyx-usage-headers.sh\" 41830",
            "\"/tmp/bin/my-calyx-usage-headers\" 41830",
            "\"/tmp/bin/calyx-usage-headers/x\" 41830",
            // missing or malformed port
            "\"/tmp/bin/calyx-usage-headers\"",
            "\"/tmp/bin/calyx-usage-headers\" ",
            "\"/tmp/bin/calyx-usage-headers\" abc",
            "\"/tmp/bin/calyx-usage-headers\"  41830",
            "\"/tmp/bin/calyx-usage-headers\"41830",
            // an inner `"` in the path, or an opening `"` never closed
            "\"/a\"b/calyx-usage-headers\" 1",
            "\"/tmp/bin/calyx-usage-headers 41830",
            // unquoted path
            "/tmp/bin/calyx-usage-headers 41830",
            // trailing or leading garbage
            "\"/tmp/bin/calyx-usage-headers\" 41830; rm -rf /tmp/x",
            "\"/tmp/bin/calyx-usage-headers\" 41830 ",
            "\"/tmp/bin/calyx-usage-headers\" 41830 extra",
            " \"/tmp/bin/calyx-usage-headers\" 41830",
            "x; \"/tmp/bin/calyx-usage-headers\" 41830",
            // cat of another file is a user's command
            "cat '/tmp/other.json'",
            "cat '/Users/test/usage-otel-headers.json'",
        ]
        for value in rejected {
            XCTAssertFalse(Config.isHelperCommand(value), "must not be a Calyx helper: \(value)")
        }
    }

    // MARK: - state

    func test_state_isInstalled_forTheBlockWithTheNewHelper() throws {
        let doc = data("{\"env\":\(Self.calyxEnvJSON),\"otelHeadersHelper\":\(Self.newHelperJSON)}")
        XCTAssertEqual(try Config.state(of: doc), .installed(port: 41830))
    }

    func test_state_isAbsent_forALoneNewHelper() throws {
        XCTAssertEqual(try Config.state(of: data("{\"otelHeadersHelper\":\(Self.newHelperJSON)}")), .absent)
    }

    func test_state_isForeign_forAnotherScriptNextToTheBlock() throws {
        let doc = data("{\"env\":\(Self.calyxEnvJSON),\"otelHeadersHelper\":\"\\\"/tmp/bin/other-headers\\\" 41830\"}")
        XCTAssertEqual(try Config.state(of: doc), .foreign(keys: ["otelHeadersHelper"]))
    }

    // MARK: - removing

    func test_removing_theBlockWithTheNewHelper_restoresTheOriginal() throws {
        let doc = data("{\n  \"a\": 1,\n  \"env\": \(Self.calyxEnvJSON),\n  \"otelHeadersHelper\": \(Self.newHelperJSON)\n}\n")
        let (document, result) = try Config.removing(from: doc)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(document.map { String(decoding: $0, as: UTF8.self) }, "{\n  \"a\": 1\n}\n")
    }

    func test_removing_aLoneNewHelper() throws {
        let doc = data("{\n  \"a\": 1,\n  \"otelHeadersHelper\": \(Self.newHelperJSON)\n}\n")
        let (document, result) = try Config.removing(from: doc)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(document.map { String(decoding: $0, as: UTF8.self) }, "{\n  \"a\": 1\n}\n")
    }
}
