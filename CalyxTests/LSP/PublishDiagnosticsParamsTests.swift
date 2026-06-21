//
//  PublishDiagnosticsParamsTests.swift
//  Calyx
//
//  Round-trip Codable tests for the LSP 3.18 `textDocument/publishDiagnostics`
//  params payload. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_publishDiagnostics
//
//  Wire shape:
//    {
//      "uri": DocumentUri,
//      "version"?: integer,
//      "diagnostics": Diagnostic[]
//    }
//
//  The `version` field is spec'd as `integer | null` but the canonical
//  in-memory representation is a single `Int?` — we accept both an absent
//  key and a present integer value. (LSP servers in practice omit the field
//  rather than send explicit `null`, so we model it as plain optional.)
//
//  TDD phase: RED. `PublishDiagnosticsParams` does not exist yet. This file
//  is expected to fail to compile until the swift-specialist creates
//  `Calyx/Features/LSP/LSPTypes/PublishDiagnosticsParams.swift`.
//

import XCTest
@testable import Calyx

final class PublishDiagnosticsParamsTests: XCTestCase {

    // MARK: - Helpers

    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// Parse a JSON string into a Foundation object for semantic comparison.
    private func parse(_ json: String) throws -> Any {
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Encode an Encodable value to a Foundation object (dict / array / scalar).
    private func toJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try encoder.encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Assert that decoding `json` into `T` and re-encoding produces semantically
    /// equivalent JSON (NSObject equality on the parsed Foundation graph).
    private func assertRoundtrip<T: Codable>(
        _ type: T.Type,
        json: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let data = Data(json.utf8)
        let decoded = try decoder.decode(T.self, from: data)
        let reencoded = try toJSONObject(decoded) as AnyObject
        let original = try parse(json) as AnyObject
        XCTAssertTrue(
            reencoded.isEqual(original),
            "Round-trip mismatch for \(T.self):\n  reencoded=\(reencoded)\n  original=\(original)",
            file: file, line: line
        )
    }

    // ====================================================================
    // MARK: - Empty diagnostics, version present
    // ====================================================================

    func test_publishDiagnosticsParams_emptyDiagnostics_withVersion_roundtrip() throws {
        let json = #"""
        {
          "uri": "file:///tmp/Foo.swift",
          "version": 1,
          "diagnostics": []
        }
        """#
        try assertRoundtrip(PublishDiagnosticsParams.self, json: json)
    }

    func test_publishDiagnosticsParams_emptyDiagnostics_withVersion_decodesFields() throws {
        let json = #"""
        {
          "uri": "file:///tmp/Foo.swift",
          "version": 7,
          "diagnostics": []
        }
        """#
        let decoded = try decoder.decode(PublishDiagnosticsParams.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.uri, "file:///tmp/Foo.swift")
        XCTAssertEqual(decoded.version, 7)
        XCTAssertEqual(decoded.diagnostics, [])
    }

    // ====================================================================
    // MARK: - Version omitted, single diagnostic
    // ====================================================================

    func test_publishDiagnosticsParams_versionOmitted_singleDiagnostic_roundtrip() throws {
        let json = #"""
        {
          "uri": "file:///tmp/Bar.swift",
          "diagnostics": [
            {
              "range": {
                "start": {"line": 0, "character": 0},
                "end":   {"line": 0, "character": 5}
              },
              "message": "unused variable"
            }
          ]
        }
        """#
        try assertRoundtrip(PublishDiagnosticsParams.self, json: json)
    }

    func test_publishDiagnosticsParams_versionOmitted_decodesAsNilVersion() throws {
        let json = #"""
        {
          "uri": "file:///tmp/Bar.swift",
          "diagnostics": []
        }
        """#
        let decoded = try decoder.decode(PublishDiagnosticsParams.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.uri, "file:///tmp/Bar.swift")
        XCTAssertNil(decoded.version)
        XCTAssertEqual(decoded.diagnostics, [])
    }

    // ====================================================================
    // MARK: - Multiple diagnostics with rich fields
    // ====================================================================

    func test_publishDiagnosticsParams_multipleDiagnostics_roundtrip() throws {
        let json = #"""
        {
          "uri": "file:///tmp/Baz.swift",
          "version": 42,
          "diagnostics": [
            {
              "range": {
                "start": {"line": 1, "character": 2},
                "end":   {"line": 1, "character": 8}
              },
              "severity": 1,
              "code": "E001",
              "source": "swiftc",
              "message": "cannot find 'foo' in scope"
            },
            {
              "range": {
                "start": {"line": 10, "character": 0},
                "end":   {"line": 10, "character": 4}
              },
              "severity": 2,
              "code": 99,
              "source": "swiftc",
              "message": "warning: deprecated API",
              "tags": [2]
            }
          ]
        }
        """#
        try assertRoundtrip(PublishDiagnosticsParams.self, json: json)
    }

    func test_publishDiagnosticsParams_multipleDiagnostics_decodesCount() throws {
        let json = #"""
        {
          "uri": "file:///tmp/Baz.swift",
          "version": 42,
          "diagnostics": [
            {
              "range": {"start": {"line": 1, "character": 2}, "end": {"line": 1, "character": 8}},
              "message": "msg1"
            },
            {
              "range": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 1}},
              "message": "msg2"
            },
            {
              "range": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 1}},
              "message": "msg3"
            }
          ]
        }
        """#
        let decoded = try decoder.decode(PublishDiagnosticsParams.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.diagnostics.count, 3)
        XCTAssertEqual(decoded.diagnostics[0].message, "msg1")
        XCTAssertEqual(decoded.diagnostics[2].message, "msg3")
    }

    // ====================================================================
    // MARK: - Programmatic construction
    // ====================================================================

    func test_publishDiagnosticsParams_constructFromAPI_roundtrip() throws {
        let params = PublishDiagnosticsParams(
            uri: "file:///tmp/Qux.swift",
            version: 3,
            diagnostics: [
                Diagnostic(
                    range: LSPRange(
                        start: Position(line: 0, character: 0),
                        end: Position(line: 0, character: 4)
                    ),
                    severity: .error,
                    message: "boom"
                )
            ]
        )
        let data = try encoder.encode(params)
        let redecoded = try decoder.decode(PublishDiagnosticsParams.self, from: data)
        XCTAssertEqual(redecoded, params)
    }

    func test_publishDiagnosticsParams_versionNil_construction() throws {
        let params = PublishDiagnosticsParams(
            uri: "file:///tmp/Quux.swift",
            version: nil,
            diagnostics: []
        )
        XCTAssertNil(params.version)
        XCTAssertEqual(params.uri, "file:///tmp/Quux.swift")
        XCTAssertTrue(params.diagnostics.isEmpty)
    }
}
