//
//  ClaudeUsageTelemetryConfigTests.swift
//  CalyxTests
//
//  The pure half of the R4a contract: what a Claude Code settings
//  document says about telemetry (`state(of:)`), and the edits Calyx
//  makes to it (`installing`, `removing`). The file belongs to the user,
//  so the byte-preservation tests are the core: for every unusual layout,
//  install / re-install / port change / remove are checked against the
//  exact original bytes.
//

import XCTest
@testable import Calyx

final class ClaudeUsageTelemetryConfigTests: XCTestCase {

    private typealias Config = ClaudeUsageTelemetryConfig

    // MARK: - Fixtures (expected values written by hand from section A)

    private static let port = 41830
    private static let helperPath = "/Users/test/Library/Application Support/Calyx/bin/calyx-usage-headers"
    private static let endpoint41830 = "http://127.0.0.1:41830/usage/v1/metrics"
    /// G5 (spec note 22): the quoted helper path, one space, the port.
    private static let helper = "\"/Users/test/Library/Application Support/Calyx/bin/calyx-usage-headers\" 41830"
    /// `helper` as it appears in the JSON text of the settings file.
    private static let helperJSONText = "\\\"/Users/test/Library/Application Support/Calyx/bin/calyx-usage-headers\\\" 41830"
    /// The pre-G5 form Calyx wrote; still recognised as Calyx's so it can be cleaned up.
    private static let legacyHelper = "cat '/Users/test/Library/Application Support/Calyx/usage-otel-headers.json' 2>/dev/null || printf '{}'"

    private static let expectedEnv: [String: String] = [
        "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
        "OTEL_METRICS_EXPORTER": "otlp",
        "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
        "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://127.0.0.1:41830/usage/v1/metrics",
        "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative",
        "OTEL_EXPORTER_OTLP_METRICS_COMPRESSION": "none",
        "OTEL_METRIC_EXPORT_INTERVAL": "5000",
        "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
        "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "false",
    ]

    private struct Layout {
        let label: String
        let content: String
        /// The user's own env members (decoded) that must survive next to Calyx's.
        let userEnv: [String: String]
    }

    /// User documents in unusual layouts. None holds telemetry settings, so each is `absent`.
    private static let layouts: [Layout] = [
        Layout(label: "tab indentation",
               content: "{\n\t\"zebra\": 1,\n\t\"apple\": [\n\t\t\"x\"\n\t]\n}\n", userEnv: [:]),
        Layout(label: "CRLF line endings",
               content: "{\r\n  \"zebra\": 1,\r\n  \"apple\": 2\r\n}\r\n", userEnv: [:]),
        Layout(label: "leading BOM",
               content: "\u{FEFF}{\n  \"zebra\": 1,\n  \"apple\": 2\n}\n", userEnv: [:]),
        Layout(label: "no trailing newline, compact",
               content: "{\"zebra\":1,\"apple\":2}", userEnv: [:]),
        Layout(label: "keys in odd order with hooks",
               content: "{\n  \"zebra\": 1,\n  \"hooks\": {\n    \"Stop\": []\n  },\n  \"apple\": \"a/b\"\n}\n", userEnv: [:]),
        Layout(label: "env object with the user's members",
               content: "{\n  \"env\": {\n    \"FOO\": \"bar\",\n    \"EXTRA_PATH\": \"/opt/x\"\n  },\n  \"model\": \"opus\"\n}\n",
               userEnv: ["FOO": "bar", "EXTRA_PATH": "/opt/x"]),
        Layout(label: "compact env object with the user's members, CRLF, tabs",
               content: "{\r\n\t\"env\": {\"FOO\": \"bar\"},\r\n\t\"model\": \"opus\"\r\n}",
               userEnv: ["FOO": "bar"]),
    ]

    private func data(_ string: String) -> Data { Data(string.utf8) }

    private func text(_ data: Data?) -> String? { data.map { String(decoding: $0, as: UTF8.self) } }

    private func decodedRoot(_ document: Data?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let document = try XCTUnwrap(document, "document must exist", file: file, line: line)
        var bytes = document
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let object = try JSONSerialization.jsonObject(with: Data(bytes))
        return try XCTUnwrap(object as? [String: Any], "root must be an object", file: file, line: line)
    }

    private func decodedEnv(_ document: Data?, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let root = try decodedRoot(document, file: file, line: line)
        return try XCTUnwrap(root["env"] as? [String: Any], "env must be an object", file: file, line: line)
    }

    /// Whether every byte of `original` appears in `result`, in order: an
    /// edit that only inserts members keeps the original as a subsequence.
    private func isSubsequence(_ original: Data, of result: Data) -> Bool {
        var iterator = result.makeIterator()
        outer: for byte in original {
            while let candidate = iterator.next() {
                if candidate == byte { continue outer }
            }
            return false
        }
        return true
    }

    private func install(_ document: Data?, port: Int = ClaudeUsageTelemetryConfigTests.port) throws -> (document: Data?, result: Config.InstallResult) {
        try Config.installing(port: port, helperPath: Self.helperPath, into: document)
    }

    // MARK: - Constants

    func test_envKeys_areTheNineKeysOfSectionA_inOrder() {
        XCTAssertEqual(Config.envKeys, [
            "CLAUDE_CODE_ENABLE_TELEMETRY",
            "OTEL_METRICS_EXPORTER",
            "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL",
            "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
            "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE",
            "OTEL_EXPORTER_OTLP_METRICS_COMPRESSION",
            "OTEL_METRIC_EXPORT_INTERVAL",
            "OTEL_METRICS_INCLUDE_SESSION_ID",
            "OTEL_METRICS_INCLUDE_ACCOUNT_UUID",
        ])
        XCTAssertEqual(Config.endpointKey, "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")
        XCTAssertEqual(Config.enableKey, "CLAUDE_CODE_ENABLE_TELEMETRY")
        XCTAssertEqual(Config.helperKey, "otelHeadersHelper")
    }

    // MARK: - endpoint / port(ofEndpoint:)

    func test_endpoint_isLoopbackHTTPWithPortAndUsagePath() {
        XCTAssertEqual(Config.endpoint(port: 41830), "http://127.0.0.1:41830/usage/v1/metrics")
        XCTAssertEqual(Config.endpoint(port: 1), "http://127.0.0.1:1/usage/v1/metrics")
    }

    func test_portOfEndpoint_acceptsCalyxEndpointsAcrossThePortRange() {
        XCTAssertEqual(Config.port(ofEndpoint: "http://127.0.0.1:1/usage/v1/metrics"), 1)
        XCTAssertEqual(Config.port(ofEndpoint: "http://127.0.0.1:65535/usage/v1/metrics"), 65535)
        XCTAssertEqual(Config.port(ofEndpoint: "http://127.0.0.1:41830/usage/v1/metrics"), 41830)
        XCTAssertEqual(Config.port(ofEndpoint: "http://127.0.0.1:10/usage/v1/metrics"), 10)
    }

    func test_portOfEndpoint_rejectsEverythingElse() {
        let rejected = [
            "http://127.0.0.1:0/usage/v1/metrics",
            "http://127.0.0.1:65536/usage/v1/metrics",
            "http://127.0.0.1:041830/usage/v1/metrics",
            "http://127.0.0.1:01/usage/v1/metrics",
            "http://127.0.0.1:/usage/v1/metrics",
            "http://127.0.0.1:999999/usage/v1/metrics",
            "http://127.0.0.1:+80/usage/v1/metrics",
            "http://127.0.0.1:-1/usage/v1/metrics",
            "http://localhost:41830/usage/v1/metrics",
            "https://127.0.0.1:41830/usage/v1/metrics",
            "http://127.0.0.1:41830/usage/v1/metrics/",
            "http://127.0.0.1:41830/usage/v1/metrics?x=1",
            "http://127.0.0.1:41830/usage/v1/metrics/extra",
            "http://127.0.0.1:41830/extra/usage/v1/metrics",
            "http://127.0.0.1:41830/v1/metrics",
            " http://127.0.0.1:41830/usage/v1/metrics",
            "http://127.0.0.1:41830/usage/v1/metrics ",
            "http://127.0.0.1/usage/v1/metrics",
            "http://collector.example:4318/v1/metrics",
            "",
        ]
        for value in rejected {
            XCTAssertNil(Config.port(ofEndpoint: value), "must not be a Calyx endpoint: \(value)")
        }
    }

    // MARK: - helperCommand / isHelperCommand

    func test_helperCommand_ordinaryPath() {
        XCTAssertEqual(Config.helperCommand(helperPath: "/tmp/bin/calyx-usage-headers", port: 5001),
                       "\"/tmp/bin/calyx-usage-headers\" 5001")
    }

    func test_helperCommand_pathWithSpaces() {
        XCTAssertEqual(Config.helperCommand(helperPath: Self.helperPath, port: 41830), Self.helper)
    }

    func test_helperCommand_carriesNoToken_onlyPathAndPort() {
        // J17: the settings file holds the helper path and the port, nothing else.
        let command = Config.helperCommand(helperPath: Self.helperPath, port: 41830)
        XCTAssertEqual(command, "\"" + Self.helperPath + "\" " + "41830")
        XCTAssertFalse(command.contains("usage-otel-headers.json"))
        XCTAssertFalse(command.contains("Bearer"))
    }

    func test_isHelperCommand_acceptsCommandsCalyxWrites() {
        XCTAssertTrue(Config.isHelperCommand("cat '/tmp/h.json' 2>/dev/null || printf '{}'"))
        XCTAssertTrue(Config.isHelperCommand(Self.helper))
        XCTAssertTrue(Config.isHelperCommand("cat '/tmp/it'\\''s/h.json' 2>/dev/null || printf '{}'"))
    }

    func test_isHelperCommand_rejectsNearMisses() {
        let rejected = [
            // another file name next to (or instead of) the quoted path
            "cat '/tmp/h.json' '/etc/passwd' 2>/dev/null || printf '{}'",
            "cat /tmp/h.json 2>/dev/null || printf '{}'",
            "/usr/local/bin/my-headers.sh",
            // an unescaped quote inside the path
            "cat '/tmp/it's/h.json' 2>/dev/null || printf '{}'",
            // a different fallback
            "cat '/tmp/h.json' 2>/dev/null || printf '[]'",
            "cat '/tmp/h.json' 2>/dev/null || echo '{}'",
            "cat '/tmp/h.json' 2>/dev/null",
            "cat '/tmp/h.json' || printf '{}'",
            // extra text before or after
            "x; cat '/tmp/h.json' 2>/dev/null || printf '{}'",
            " cat '/tmp/h.json' 2>/dev/null || printf '{}'",
            "cat '/tmp/h.json' 2>/dev/null || printf '{}'; rm -rf /tmp/x",
            "cat '/tmp/h.json' 2>/dev/null || printf '{}' ",
            "",
        ]
        for value in rejected {
            XCTAssertFalse(Config.isHelperCommand(value), "must not be a Calyx helper: \(value)")
        }
    }

    // MARK: - state: absent

    func test_state_isAbsent_forNilEmptyAndEmptyObject() throws {
        XCTAssertEqual(try Config.state(of: nil), .absent)
        XCTAssertEqual(try Config.state(of: Data()), .absent)
        XCTAssertEqual(try Config.state(of: data("{}")), .absent)
    }

    func test_state_isAbsent_forUnrelatedEnvMembersAndHooks() throws {
        let doc = data("{\"env\":{\"FOO\":\"1\",\"CLAUDE_CODE_USE_BEDROCK\":\"1\",\"MY_OTEL\":\"x\"},\"hooks\":{\"Stop\":[]}}")
        XCTAssertEqual(try Config.state(of: doc), .absent)
    }

    // MARK: - state: installed

    private func envDoc(_ members: [(String, String)], extraRoot: String = "") -> Data {
        let body = members.map { "\"\($0.0)\": \"\($0.1)\"" }.joined(separator: ", ")
        return data("{\"env\": {\(body)}\(extraRoot)}")
    }

    private var calyxMembers: [(String, String)] {
        Config.envKeys.compactMap { key in Self.expectedEnv[key].map { (key, $0) } }
    }

    func test_state_isInstalled_forCalyxBlock() throws {
        let doc = envDoc(calyxMembers, extraRoot: ", \"otelHeadersHelper\": \"cat '/tmp/h.json' 2>/dev/null || printf '{}'\"")
        XCTAssertEqual(try Config.state(of: doc), .installed(port: 41830))
    }

    func test_state_isInstalled_withTheEndpointsPort() throws {
        let members = calyxMembers.map { $0.0 == Config.endpointKey ? ($0.0, "http://127.0.0.1:5001/usage/v1/metrics") : $0 }
        XCTAssertEqual(try Config.state(of: envDoc(members)), .installed(port: 5001))
    }

    func test_state_isInstalled_whenAnotherCalyxMemberChanged() throws {
        let members = calyxMembers.map { $0.0 == "OTEL_METRIC_EXPORT_INTERVAL" ? ($0.0, "60000") : $0 }
        XCTAssertEqual(try Config.state(of: envDoc(members)), .installed(port: 41830))
    }

    func test_state_isInstalled_whenAnotherCalyxMemberMissing() throws {
        let members = calyxMembers.filter { $0.0 != Config.enableKey && $0.0 != "OTEL_METRICS_EXPORTER" }
        XCTAssertEqual(try Config.state(of: envDoc(members)), .installed(port: 41830))
    }

    func test_state_isInstalled_withExtraUserOTELKeysNextToTheBlock() throws {
        let members = calyxMembers + [("OTEL_RESOURCE_ATTRIBUTES", "team=x"), ("OTEL_LOGS_EXPORTER", "otlp")]
        XCTAssertEqual(try Config.state(of: envDoc(members)), .installed(port: 41830))
    }

    // MARK: - state: foreign

    func test_state_isForeign_forAnotherEndpoint() throws {
        let doc = envDoc([(Config.endpointKey, "http://collector.example:4318/v1/metrics"), ("OTEL_METRICS_EXPORTER", "otlp")])
        XCTAssertEqual(try Config.state(of: doc), .foreign(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
    }

    func test_state_isForeign_forALocalhostEndpoint() throws {
        let doc = envDoc([(Config.endpointKey, "http://localhost:41830/usage/v1/metrics")])
        XCTAssertEqual(try Config.state(of: doc), .foreign(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
    }

    func test_state_isForeign_forANonStringEndpoint() throws {
        let doc = data("{\"env\": {\"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT\": 41830}}")
        XCTAssertEqual(try Config.state(of: doc), .foreign(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
    }

    func test_state_isForeign_forAnotherHelper() throws {
        let doc = data("{\"otelHeadersHelper\": \"/usr/local/bin/my-headers.sh\"}")
        XCTAssertEqual(try Config.state(of: doc), .foreign(keys: ["otelHeadersHelper"]))
    }

    func test_state_isForeign_forAnotherHelperNextToCalyxBlock() throws {
        let doc = envDoc(calyxMembers, extraRoot: ", \"otelHeadersHelper\": \"/usr/local/bin/my-headers.sh\"")
        XCTAssertEqual(try Config.state(of: doc), .foreign(keys: ["otelHeadersHelper"]))
    }

    func test_state_isForeign_forEnableTelemetryAlone() throws {
        XCTAssertEqual(try Config.state(of: envDoc([("CLAUDE_CODE_ENABLE_TELEMETRY", "1")])),
                       .foreign(keys: ["CLAUDE_CODE_ENABLE_TELEMETRY"]))
    }

    func test_state_isForeign_forMetricsExporterAlone() throws {
        XCTAssertEqual(try Config.state(of: envDoc([("OTEL_METRICS_EXPORTER", "otlp")])),
                       .foreign(keys: ["OTEL_METRICS_EXPORTER"]))
    }

    func test_state_isForeign_forAnUnrelatedOTELKeyAlone() throws {
        XCTAssertEqual(try Config.state(of: envDoc([("OTEL_LOGS_EXPORTER", "console")])),
                       .foreign(keys: ["OTEL_LOGS_EXPORTER"]))
    }

    func test_state_isForeign_withSeveralKeysSorted() throws {
        let doc = envDoc(
            [("OTEL_METRICS_EXPORTER", "otlp"), ("OTEL_LOGS_EXPORTER", "otlp"), ("CLAUDE_CODE_ENABLE_TELEMETRY", "1"), ("FOO", "bar")],
            extraRoot: ", \"otelHeadersHelper\": \"/bin/h\""
        )
        XCTAssertEqual(try Config.state(of: doc), .foreign(keys: [
            "CLAUDE_CODE_ENABLE_TELEMETRY", "OTEL_LOGS_EXPORTER", "OTEL_METRICS_EXPORTER", "otelHeadersHelper",
        ]))
    }

    func test_state_isAbsent_forALoneCalyxHelper() throws {
        let doc = data("{\"otelHeadersHelper\": \"cat '/tmp/h.json' 2>/dev/null || printf '{}'\"}")
        XCTAssertEqual(try Config.state(of: doc), .absent)
    }

    // MARK: - state: errors

    private func assertTypeConflictOnEnv(_ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .typeConflict(let key)? = error as? JSONConfigDocumentEditor.EditorError else {
                return XCTFail("expected typeConflict(\"env\"), got \(error)", file: file, line: line)
            }
            XCTAssertEqual(key, "env", file: file, line: line)
        }
    }

    func test_state_throwsTypeConflict_forANonObjectEnv() {
        assertTypeConflictOnEnv { _ = try Config.state(of: self.data("{\"env\": \"x\"}")) }
        assertTypeConflictOnEnv { _ = try Config.state(of: self.data("{\"env\": [\"OTEL_METRICS_EXPORTER\"]}")) }
        assertTypeConflictOnEnv { _ = try Config.state(of: self.data("{\"env\": null}")) }
    }

    func test_state_throwsInvalidJSON_forANonObjectRootOrBrokenDocument() {
        for doc in ["[]", "\"text\"", "{\"env\": {", "not json"] {
            XCTAssertThrowsError(try Config.state(of: data(doc)), doc) { error in
                XCTAssertEqual(error as? ConfigFileError, .invalidJSON, doc)
            }
        }
    }

    // MARK: - installing

    func test_installing_intoNil_holdsOnlyCalyxBlock() throws {
        let (document, result) = try install(nil)
        XCTAssertEqual(result, .written)
        let root = try decodedRoot(document)
        XCTAssertEqual(Set(root.keys), ["env", "otelHeadersHelper"])
        XCTAssertEqual(root["otelHeadersHelper"] as? String, Self.helper)
        let env = try decodedEnv(document)
        XCTAssertEqual(env.count, 9)
        for (key, value) in Self.expectedEnv {
            XCTAssertEqual(env[key] as? String, value, key)
        }
    }

    func test_installing_intoEmptyData_holdsOnlyCalyxBlock() throws {
        let (document, result) = try install(Data())
        XCTAssertEqual(result, .written)
        XCTAssertEqual(Set(try decodedRoot(document).keys), ["env", "otelHeadersHelper"])
        XCTAssertEqual(try decodedEnv(document).count, 9)
    }

    func test_installing_intoEmptyObject_holdsOnlyCalyxBlock() throws {
        let (document, result) = try install(data("{}"))
        XCTAssertEqual(result, .written)
        XCTAssertEqual(Set(try decodedRoot(document).keys), ["env", "otelHeadersHelper"])
        XCTAssertEqual(try decodedEnv(document).count, 9)
    }

    /// Exact bytes, written by hand: members appended after the last
    /// sibling with the sibling's indentation, nothing else touched.
    func test_installing_intoIndentedDocument_appendsMembersInSectionAOrderWithMatchingIndentation() throws {
        let (document, result) = try install(data("{\n  \"a\": 1\n}\n"))
        XCTAssertEqual(result, .written)
        let expected = """
        {
          "a": 1,
          "env": {
            "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
            "OTEL_METRICS_EXPORTER": "otlp",
            "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "http/json",
            "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://127.0.0.1:41830/usage/v1/metrics",
            "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE": "cumulative",
            "OTEL_EXPORTER_OTLP_METRICS_COMPRESSION": "none",
            "OTEL_METRIC_EXPORT_INTERVAL": "5000",
            "OTEL_METRICS_INCLUDE_SESSION_ID": "true",
            "OTEL_METRICS_INCLUDE_ACCOUNT_UUID": "false"
          },
          "otelHeadersHelper": "\\"/Users/test/Library/Application Support/Calyx/bin/calyx-usage-headers\\" 41830"
        }

        """
        XCTAssertEqual(text(document), expected)
    }

    func test_installing_doesNotEscapeSlashes() throws {
        let (document, _) = try install(data("{\n  \"a\": 1\n}\n"))
        let written = try XCTUnwrap(text(document))
        XCTAssertTrue(written.contains("\"http://127.0.0.1:41830/usage/v1/metrics\""), written)
        XCTAssertTrue(written.contains("\"http/json\""), written)
        XCTAssertTrue(written.contains("/Calyx/bin/calyx-usage-headers"), written)
        XCTAssertFalse(written.contains("\\/"), written)
    }

    func test_installing_everyLayout_writesEverySectionAMemberAndKeepsTheUsersMembers() throws {
        for layout in Self.layouts {
            let (document, result) = try install(data(layout.content))
            XCTAssertEqual(result, .written, layout.label)
            let env = try decodedEnv(document)
            XCTAssertEqual(env.count, 9 + layout.userEnv.count, layout.label)
            for (key, value) in Self.expectedEnv {
                XCTAssertEqual(env[key] as? String, value, "\(layout.label): \(key)")
            }
            for (key, value) in layout.userEnv {
                XCTAssertEqual(env[key] as? String, value, "\(layout.label): user member \(key)")
            }
            XCTAssertEqual(try decodedRoot(document)["otelHeadersHelper"] as? String, Self.helper, layout.label)
        }
    }

    func test_installing_everyLayout_onlyInsertsBytes() throws {
        for layout in Self.layouts {
            let original = data(layout.content)
            let installed = try XCTUnwrap(try install(original).document, layout.label)
            XCTAssertTrue(isSubsequence(original, of: installed),
                          "\(layout.label): every original byte must survive, in order:\n\(text(installed) ?? "")")
        }
    }

    func test_installing_everyLayout_keepsBOMAndLineEndingsAndTrailingBytes() throws {
        for layout in Self.layouts {
            let original = data(layout.content)
            let installed = try XCTUnwrap(try install(original).document, layout.label)
            let hasBOM = original.starts(with: [0xEF, 0xBB, 0xBF])
            XCTAssertEqual(installed.starts(with: [0xEF, 0xBB, 0xBF]), hasBOM, "\(layout.label): BOM")
            XCTAssertEqual(installed.last, original.last, "\(layout.label): last byte")
            let installedText = try XCTUnwrap(text(installed))
            if layout.content.contains("\r\n") {
                let bareLF = installedText.replacingOccurrences(of: "\r\n", with: "").contains("\n")
                XCTAssertFalse(bareLF, "\(layout.label): a CRLF document must not gain bare LF line endings")
            }
        }
    }

    func test_installing_twice_isUnchangedAndByteIdentical_forEveryLayout() throws {
        for layout in Self.layouts + [Layout(label: "nil", content: "", userEnv: [:])] {
            let first = try XCTUnwrap(try install(layout.content.isEmpty ? nil : data(layout.content)).document, layout.label)
            let (second, result) = try install(first)
            XCTAssertEqual(result, .unchanged, layout.label)
            XCTAssertEqual(second, first, layout.label)
        }
    }

    /// G5: a port change rewrites the endpoint AND the helper's port argument, and nothing else.
    func test_installing_withAnotherPort_changesOnlyTheEndpointAndHelperPort_forEveryLayout() throws {
        for layout in Self.layouts {
            let first = try XCTUnwrap(try install(data(layout.content)).document, layout.label)
            let (second, result) = try install(first, port: 41831)
            XCTAssertEqual(result, .written, layout.label)
            let expected = try XCTUnwrap(text(first))
                .replacingOccurrences(
                    of: "\"http://127.0.0.1:41830/usage/v1/metrics\"", with: "\"http://127.0.0.1:41831/usage/v1/metrics\"")
                .replacingOccurrences(of: "calyx-usage-headers\\\" 41830\"", with: "calyx-usage-headers\\\" 41831\"")
            XCTAssertNotEqual(expected, text(first), "\(layout.label): test setup, both replacements apply")
            XCTAssertEqual(text(second), expected, layout.label)
            XCTAssertEqual(try decodedRoot(second)["otelHeadersHelper"] as? String,
                           "\"" + Self.helperPath + "\" 41831", layout.label)
        }
    }

    func test_installing_resetsADriftedCalyxMember() throws {
        let installed = try XCTUnwrap(text(try install(data("{\n  \"a\": 1\n}\n")).document))
        let drifted = installed.replacingOccurrences(of: "\"OTEL_METRIC_EXPORT_INTERVAL\": \"5000\"",
                                                     with: "\"OTEL_METRIC_EXPORT_INTERVAL\": \"60000\"")
        XCTAssertNotEqual(drifted, installed, "test setup: the drift must apply")
        let (document, result) = try install(data(drifted))
        XCTAssertEqual(result, .written)
        XCTAssertEqual(text(document), installed)
    }

    func test_installing_blocked_returnsInputBytesAndKeys() throws {
        let original = data("{\n  \"env\": {\n    \"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT\": \"http://collector:4318/v1/metrics\",\n    \"OTEL_METRICS_EXPORTER\": \"otlp\"\n  }\n}\n")
        let (document, result) = try install(original)
        XCTAssertEqual(result, .blocked(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
        XCTAssertEqual(document, original)
    }

    func test_installing_blocked_byEnableTelemetryAlone_returnsInputBytes() throws {
        let original = data("{\"env\":{\"CLAUDE_CODE_ENABLE_TELEMETRY\":\"1\"}}")
        let (document, result) = try install(original)
        XCTAssertEqual(result, .blocked(keys: ["CLAUDE_CODE_ENABLE_TELEMETRY"]))
        XCTAssertEqual(document, original)
    }

    func test_installing_blocked_byForeignHelper_returnsInputBytes() throws {
        let original = data("{\"otelHeadersHelper\": \"/bin/h\"}")
        let (document, result) = try install(original)
        XCTAssertEqual(result, .blocked(keys: ["otelHeadersHelper"]))
        XCTAssertEqual(document, original)
    }

    func test_installing_throwsTypeConflict_forANonObjectEnv() {
        assertTypeConflictOnEnv { _ = try self.install(self.data("{\"env\": \"x\"}")) }
    }

    func test_installing_throwsInvalidJSON_forABrokenDocument() {
        XCTAssertThrowsError(try install(data("{\"a\": "))) { error in
            XCTAssertEqual(error as? ConfigFileError, .invalidJSON)
        }
    }

    // MARK: - removing

    func test_removing_afterInstall_restoresTheExactOriginalBytes_forEveryLayout() throws {
        for layout in Self.layouts + [Layout(label: "empty object", content: "{}", userEnv: [:])] {
            let original = data(layout.content)
            let installed = try install(original).document
            let (document, result) = try Config.removing(from: installed)
            XCTAssertEqual(result, .removed, layout.label)
            XCTAssertEqual(text(document), layout.content, layout.label)
        }
    }

    func test_removing_afterInstallWithPortChange_restoresTheExactOriginalBytes_forEveryLayout() throws {
        for layout in Self.layouts {
            let first = try install(data(layout.content)).document
            let second = try install(first, port: 41831).document
            XCTAssertEqual(text(try Config.removing(from: second).document), layout.content, layout.label)
        }
    }

    /// The editor removes an `env` object left empty, so an `env: {}` the
    /// user had before does not survive the cycle (contract rule 6).
    func test_removing_afterInstallIntoEmptyEnvObject_removesTheEmptiedEnvMember() throws {
        let installed = try install(data("{\n  \"env\": {},\n  \"a\": 1\n}\n")).document
        XCTAssertEqual(try decodedEnv(installed).count, 9)
        let (document, result) = try Config.removing(from: installed)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(text(document), "{\n  \"a\": 1\n}\n")
    }

    func test_removing_fromNil_isNothingToRemove() throws {
        let (document, result) = try Config.removing(from: nil)
        XCTAssertEqual(result, .nothingToRemove)
        XCTAssertNil(document)
    }

    // MARK: - removing: ownership by key (rule 6)

    private static let plainOriginal = "{\n  \"a\": 1\n}\n"

    /// Installs into `plainOriginal`, then replaces `old` with `new` in the text (the user's edit).
    private func installedThenEdited(_ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let installed = try XCTUnwrap(text(try install(data(Self.plainOriginal)).document), file: file, line: line)
        let edited = installed.replacingOccurrences(of: old, with: new)
        XCTAssertNotEqual(edited, installed, "test setup: the edit must apply", file: file, line: line)
        return data(edited)
    }

    private func assertNextInstallBlocked(_ document: Data?, keys: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Config.state(of: document), .foreign(keys: keys), file: file, line: line)
        let (again, result) = try install(document)
        XCTAssertEqual(result, .blocked(keys: keys), file: file, line: line)
        XCTAssertEqual(again, document, "a blocked install changes no byte", file: file, line: line)
    }

    func test_removing_removesAChangedInterval_withTheRest_restoringTheOriginalBytes() throws {
        let edited = try installedThenEdited("\"OTEL_METRIC_EXPORT_INTERVAL\": \"5000\"", "\"OTEL_METRIC_EXPORT_INTERVAL\": \"60000\"")
        let (document, result) = try Config.removing(from: edited)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(text(document), Self.plainOriginal)
    }

    func test_removing_aChangedInterval_leavesAbsentState_andTheNextInstallIsWritten() throws {
        let edited = try installedThenEdited("\"OTEL_METRIC_EXPORT_INTERVAL\": \"5000\"", "\"OTEL_METRIC_EXPORT_INTERVAL\": \"60000\"")
        let removed = try Config.removing(from: edited).document
        XCTAssertEqual(try Config.state(of: removed), .absent)
        XCTAssertEqual(try install(removed).result, .written)
    }

    func test_removing_removesAChangedEnableFlag_withTheRest_restoringTheOriginalBytes() throws {
        let edited = try installedThenEdited("\"CLAUDE_CODE_ENABLE_TELEMETRY\": \"1\"", "\"CLAUDE_CODE_ENABLE_TELEMETRY\": \"0\"")
        let (document, result) = try Config.removing(from: edited)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(text(document), Self.plainOriginal)
        XCTAssertEqual(try Config.state(of: document), .absent)
        XCTAssertEqual(try install(document).result, .written)
    }

    func test_removing_withAChangedEndpoint_removesNothing() throws {
        let edited = try installedThenEdited(Self.endpoint41830, "http://collector.example:4318/v1/metrics")
        XCTAssertEqual(try Config.state(of: edited), .foreign(keys: ["OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"]))
        let (document, result) = try Config.removing(from: edited)
        XCTAssertEqual(result, .nothingToRemove)
        XCTAssertEqual(document, edited)
    }

    func test_removing_withAChangedHelper_removesNothing_andTheNextInstallIsBlocked() throws {
        let edited = try installedThenEdited(Self.helperJSONText, "/usr/local/bin/my-headers.sh")
        let (document, result) = try Config.removing(from: edited)
        XCTAssertEqual(result, .nothingToRemove)
        XCTAssertEqual(document, edited)
        try assertNextInstallBlocked(document, keys: ["otelHeadersHelper"])
    }

    func test_removing_removesEnableTelemetryToo_whenAUserAddedOTELKeyRemains_andThatKeyStays() throws {
        let edited = try installedThenEdited(
            "\"OTEL_METRICS_INCLUDE_ACCOUNT_UUID\": \"false\"\n",
            "\"OTEL_METRICS_INCLUDE_ACCOUNT_UUID\": \"false\",\n    \"OTEL_LOGS_EXPORTER\": \"otlp\"\n"
        )
        XCTAssertEqual(try Config.state(of: edited), .installed(port: 41830))
        let (document, result) = try Config.removing(from: edited)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(text(document), "{\n  \"a\": 1,\n  \"env\": {\n    \"OTEL_LOGS_EXPORTER\": \"otlp\"\n  }\n}\n")
        try assertNextInstallBlocked(document, keys: ["OTEL_LOGS_EXPORTER"])
    }

    /// Hand-written: each layout after install, the user adding
    /// `"OTEL_LOGS_EXPORTER": "otlp"` as the last env member (placed like
    /// its previous sibling), and remove. Only the user's key and the `env`
    /// object holding it are left beyond the original bytes.
    private static let layoutsWithUserLogsExporter: [String: String] = [
        "tab indentation":
            "{\n\t\"zebra\": 1,\n\t\"apple\": [\n\t\t\"x\"\n\t],\n\t\"env\": {\n\t\t\"OTEL_LOGS_EXPORTER\": \"otlp\"\n\t}\n}\n",
        "CRLF line endings":
            "{\r\n  \"zebra\": 1,\r\n  \"apple\": 2,\r\n  \"env\": {\r\n    \"OTEL_LOGS_EXPORTER\": \"otlp\"\r\n  }\r\n}\r\n",
        "leading BOM":
            "\u{FEFF}{\n  \"zebra\": 1,\n  \"apple\": 2,\n  \"env\": {\n    \"OTEL_LOGS_EXPORTER\": \"otlp\"\n  }\n}\n",
        "no trailing newline, compact":
            "{\"zebra\":1,\"apple\":2,\"env\":{\"OTEL_LOGS_EXPORTER\":\"otlp\"}}",
        "keys in odd order with hooks":
            "{\n  \"zebra\": 1,\n  \"hooks\": {\n    \"Stop\": []\n  },\n  \"apple\": \"a/b\",\n  \"env\": {\n    \"OTEL_LOGS_EXPORTER\": \"otlp\"\n  }\n}\n",
        "env object with the user's members":
            "{\n  \"env\": {\n    \"FOO\": \"bar\",\n    \"EXTRA_PATH\": \"/opt/x\",\n    \"OTEL_LOGS_EXPORTER\": \"otlp\"\n  },\n  \"model\": \"opus\"\n}\n",
        "compact env object with the user's members, CRLF, tabs":
            "{\r\n\t\"env\": {\"FOO\": \"bar\",\"OTEL_LOGS_EXPORTER\": \"otlp\"},\r\n\t\"model\": \"opus\"\r\n}",
    ]

    /// Property, every layout: a remove deletes exactly Calyx's ten members
    /// whatever their values and keeps every other byte, including a
    /// user-added key. Expectations are hand-written (review round 2, T1).
    func test_removing_everyLayout_deletesExactlyTheTenCalyxMembers() throws {
        let edits: [(label: String, key: String, value: String)] = [
            ("changed interval", "OTEL_METRIC_EXPORT_INTERVAL", "60000"),
            ("changed enable flag", "CLAUDE_CODE_ENABLE_TELEMETRY", "0"),
            ("user-added key", "OTEL_LOGS_EXPORTER", "otlp"),
        ]
        for layout in Self.layouts {
            for edit in edits {
                let label = "\(layout.label) / \(edit.label)"
                let installed = try install(data(layout.content)).document
                let edited = try JSONConfigDocumentEditor.setValue(Data("\"\(edit.value)\"".utf8), at: ["env", edit.key], in: installed)
                let (document, result) = try Config.removing(from: edited)
                XCTAssertEqual(result, .removed, label)
                if edit.key == "OTEL_LOGS_EXPORTER" {
                    guard let expected = Self.layoutsWithUserLogsExporter[layout.label] else {
                        XCTFail("\(label): no hand-written expectation"); continue
                    }
                    XCTAssertEqual(text(document), expected, "\(label): the original layout plus exactly the user's key")
                } else {
                    XCTAssertEqual(text(document), layout.content, "\(label): the original bytes come back")
                }
            }
        }
    }

    // MARK: - Written values (review W2)

    /// G5: paths a real `bin` directory can have. Paths holding `"`, `\\`,
    /// `$` or a backquote are not covered: inside the double quotes of the
    /// new form the shell would interpret them, and spec note 22 does not
    /// say how such a path is written (reported as a spec gap).
    private static let unusualHeadersPaths = [
        "/tmp/it's/bin/calyx-usage-headers",
        "/tmp/a b/bin/calyx-usage-headers",
        "/tmp/\u{FC}/bin/calyx-usage-headers",
    ]

    func test_installing_unusualHeadersPaths_decodeToTheHelperCommand() throws {
        for path in Self.unusualHeadersPaths {
            let document = try Config.installing(port: 41830, helperPath: path, into: data("{}")).document
            let helper = try decodedRoot(document)["otelHeadersHelper"] as? String
            XCTAssertEqual(helper, Config.helperCommand(helperPath: path, port: 41830), path.debugDescription)
        }
    }

    func test_isHelperCommand_acceptsTheHelperForUnusualHeadersPaths() throws {
        for path in Self.unusualHeadersPaths {
            let document = try Config.installing(port: 41830, helperPath: path, into: data("{}")).document
            let helper = try XCTUnwrap(try decodedRoot(document)["otelHeadersHelper"] as? String, path.debugDescription)
            XCTAssertTrue(Config.isHelperCommand(helper), path.debugDescription)
            XCTAssertEqual(try Config.state(of: document), .installed(port: 41830), path.debugDescription)
        }
    }

    func test_installing_twice_withUnusualHeadersPaths_isUnchanged() throws {
        for path in Self.unusualHeadersPaths {
            let first = try Config.installing(port: 41830, helperPath: path, into: data("{}")).document
            let (second, result) = try Config.installing(port: 41830, helperPath: path, into: first)
            XCTAssertEqual(result, .unchanged, path.debugDescription)
            XCTAssertEqual(second, first, path.debugDescription)
        }
    }

    // MARK: - Near misses and invalid documents (review S2)

    func test_portOfEndpoint_rejectsIPv6UserinfoAndUpperCaseScheme() {
        for value in [
            "http://[::1]:41830/usage/v1/metrics",
            "http://user@127.0.0.1:41830/usage/v1/metrics",
            "http://user:pw@127.0.0.1:41830/usage/v1/metrics",
            "HTTP://127.0.0.1:41830/usage/v1/metrics",
            "Http://127.0.0.1:41830/usage/v1/metrics",
        ] {
            XCTAssertNil(Config.port(ofEndpoint: value), value)
        }
    }

    private static let invalidDocuments = [
        "   \n\t",
        "{\n  // comment\n  \"a\": 1\n}\n",
        "{\"a\": 1,}",
    ]

    func test_state_installing_removing_throwInvalidJSON_forWhitespaceCommentsAndTrailingComma() {
        for content in Self.invalidDocuments {
            let label = content.debugDescription
            XCTAssertThrowsError(try Config.state(of: data(content)), label) { XCTAssertEqual($0 as? ConfigFileError, .invalidJSON, label) }
            XCTAssertThrowsError(try install(data(content)), label) { XCTAssertEqual($0 as? ConfigFileError, .invalidJSON, label) }
            XCTAssertThrowsError(try Config.removing(from: data(content)), label) { XCTAssertEqual($0 as? ConfigFileError, .invalidJSON, label) }
        }
    }

    func test_removing_removesEnableTelemetryWhenOnlyNonOTELUserKeysRemain() throws {
        let installed = try install(data("{\"env\":{\"FOO\":\"bar\"}}")).document
        let (document, result) = try Config.removing(from: installed)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(text(document), "{\"env\":{\"FOO\":\"bar\"}}")
    }

    func test_removing_isNothingToRemoveAndByteIdentical_forAbsentDocuments() throws {
        for content in ["{}", "{\n  \"env\": {\n    \"FOO\": \"bar\"\n  },\n  \"hooks\": {}\n}\n"] + Self.layouts.map(\.content) {
            let original = data(content)
            let (document, result) = try Config.removing(from: original)
            XCTAssertEqual(result, .nothingToRemove, content)
            XCTAssertEqual(document, original, content)
        }
    }

    func test_removing_isNothingToRemoveAndByteIdentical_forForeignDocuments() throws {
        let foreign = [
            "{\"env\":{\"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT\":\"http://collector:4318/v1/metrics\",\"OTEL_METRICS_EXPORTER\":\"otlp\",\"CLAUDE_CODE_ENABLE_TELEMETRY\":\"1\"}}",
            "{\"env\":{\"CLAUDE_CODE_ENABLE_TELEMETRY\":\"1\",\"OTEL_METRICS_EXPORTER\":\"otlp\"},\"otelHeadersHelper\":\"cat '/tmp/h.json' 2>/dev/null || printf '{}'\"}",
            "{\"env\":{\"OTEL_LOGS_EXPORTER\":\"console\"}}",
        ]
        for content in foreign {
            let original = data(content)
            let (document, result) = try Config.removing(from: original)
            XCTAssertEqual(result, .nothingToRemove, content)
            XCTAssertEqual(document, original, content)
        }
    }

    func test_removing_leavesAForeignHelperNextToTheCalyxBlock() throws {
        let installed = try XCTUnwrap(text(try install(data("{\n  \"a\": 1\n}\n")).document))
        let withForeignHelper = installed.replacingOccurrences(of: Self.helperJSONText, with: "/usr/local/bin/my-headers.sh")
        XCTAssertNotEqual(withForeignHelper, installed, "test setup: the helper must be replaced")
        let (document, result) = try Config.removing(from: data(withForeignHelper))
        XCTAssertEqual(result, .nothingToRemove)
        XCTAssertEqual(text(document), withForeignHelper)
    }

    func test_removing_removesALoneCalyxHelper() throws {
        let original = data("{\n  \"a\": 1,\n  \"otelHeadersHelper\": \"cat '/tmp/it'\\\\''s.json' 2>/dev/null || printf '{}'\"\n}\n")
        XCTAssertEqual(try Config.state(of: original), .absent)
        let (document, result) = try Config.removing(from: original)
        XCTAssertEqual(result, .removed)
        XCTAssertEqual(text(document), "{\n  \"a\": 1\n}\n")
    }

    func test_removing_leavesALoneForeignHelper() throws {
        let original = data("{\n  \"a\": 1,\n  \"otelHeadersHelper\": \"/usr/local/bin/my-headers.sh\"\n}\n")
        let (document, result) = try Config.removing(from: original)
        XCTAssertEqual(result, .nothingToRemove)
        XCTAssertEqual(document, original)
    }

    func test_removing_throwsTypeConflict_forANonObjectEnv() {
        assertTypeConflictOnEnv { _ = try Config.removing(from: self.data("{\"env\": 3}")) }
    }

    // MARK: - G5: legacy `cat` helper is replaced

    private func legacyInstalled(port: Int = 41830) -> Data {
        let members = calyxMembers.map {
            $0.0 == Config.endpointKey ? ($0.0, "http://127.0.0.1:\(port)/usage/v1/metrics") : $0
        }
        return envDoc(members, extraRoot: ", \"otelHeadersHelper\": \"" + Self.legacyHelper + "\"")
    }

    func test_state_isInstalled_forALegacyInstall() throws {
        XCTAssertEqual(try Config.state(of: legacyInstalled()), .installed(port: 41830))
    }

    func test_installing_overALegacyInstall_replacesTheHelperWithTheNewForm() throws {
        let (document, result) = try install(legacyInstalled())
        XCTAssertEqual(result, .written)
        XCTAssertEqual(try decodedRoot(document)["otelHeadersHelper"] as? String, Self.helper)
        let env = try decodedEnv(document)
        XCTAssertEqual(env.count, 9)
        for (key, value) in Self.expectedEnv {
            XCTAssertEqual(env[key] as? String, value, key)
        }
        XCTAssertFalse(try XCTUnwrap(text(document)).contains("usage-otel-headers.json"))
        XCTAssertEqual(try Config.state(of: document), .installed(port: 41830))
    }

    func test_installing_overALegacyInstallOnAnotherPort_rewritesEndpointAndHelper() throws {
        let (document, result) = try install(legacyInstalled(port: 5001))
        XCTAssertEqual(result, .written)
        XCTAssertEqual(try decodedRoot(document)["otelHeadersHelper"] as? String, Self.helper)
        XCTAssertEqual(try decodedEnv(document)[Config.endpointKey] as? String, Self.endpoint41830)
    }

    func test_installing_overALoneLegacyHelper_replacesIt() throws {
        let doc = data("{\"otelHeadersHelper\": \"" + Self.legacyHelper + "\"}")
        let (document, result) = try install(doc)
        XCTAssertEqual(result, .written)
        XCTAssertEqual(try decodedRoot(document)["otelHeadersHelper"] as? String, Self.helper)
    }

    func test_installing_newForm_unchanged_returnsUnchanged() throws {
        let first = try install(data(Self.plainOriginal)).document
        let (second, result) = try install(first)
        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(second, first)
    }

    func test_installing_withAnotherHelperPath_rewritesTheHelper() throws {
        let first = try install(data(Self.plainOriginal)).document
        let (second, result) = try Config.installing(port: 41830, helperPath: "/opt/bin/calyx-usage-headers", into: first)
        XCTAssertEqual(result, .written)
        XCTAssertEqual(try decodedRoot(second)["otelHeadersHelper"] as? String, "\"/opt/bin/calyx-usage-headers\" 41830")
    }

    func test_removing_aLegacyInstall_removesTheBlockAndTheLegacyHelper() throws {
        let (document, result) = try Config.removing(from: legacyInstalled())
        XCTAssertEqual(result, .removed)
        XCTAssertTrue(try decodedRoot(document).isEmpty, text(document) ?? "nil")
    }
}
