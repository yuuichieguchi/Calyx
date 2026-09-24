//
//  MCPServersJSONImporterTests.swift
//  CalyxTests
//
//  Parses pasted MCP server JSON in the three shapes users copy from
//  various CLI docs: `{"mcpServers": {...}}`, a bare name->server map,
//  and a single server object. Secret-bearing fields (env values,
//  header values) are extracted separately from the config so callers
//  route them to the secret store, never into the JSON file. Contract
//  v2 SS7.7.
//

import XCTest
@testable import Calyx

final class MCPServersJSONImporterTests: XCTestCase {

    // MARK: - `{"mcpServers": {...}}` shape

    func test_parse_mcpServersWrapper_multipleEntries() throws {
        let json = """
        {"mcpServers": {
          "weather": {"command": "python3", "args": ["-m", "weather"]},
          "search": {"command": "node", "args": ["search.js"]}
        }}
        """
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(Set(servers.compactMap(\.name)), ["weather", "search"])
    }

    func test_parse_mcpServersWrapper_stdioFieldsExtracted() throws {
        let json = """
        {"mcpServers": {"weather": {"command": "python3", "args": ["-m", "weather"], "cwd": "/tmp/x"}}}
        """
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        guard case .stdio(let command, let args, _, let cwd) = servers[0].transport else {
            return XCTFail("expected stdio transport")
        }
        XCTAssertEqual(command, "python3")
        XCTAssertEqual(args, ["-m", "weather"])
        XCTAssertEqual(cwd, "/tmp/x")
    }

    // MARK: - Bare name->server map (no "mcpServers" wrapper)

    func test_parse_bareNameToServerMap() throws {
        let json = """
        {"weather": {"command": "python3", "args": []}}
        """
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].name, "weather")
    }

    // MARK: - Single server object

    func test_parse_singleServerObject_yieldsOneServer() throws {
        let json = #"{"command": "python3", "args": ["-m", "weather"]}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        XCTAssertEqual(servers.count, 1)
        guard case .stdio(let command, _, _, _) = servers[0].transport else {
            return XCTFail("expected stdio transport")
        }
        XCTAssertEqual(command, "python3")
    }

    // MARK: - type field: absent/unknown -> stdio, http / streamable-http -> http, sse -> http+legacySSE

    func test_parse_typeAbsent_producesStdioTransport() throws {
        let json = #"{"weather": {"command": "python3", "args": []}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        guard case .stdio = servers[0].transport else { return XCTFail("expected stdio transport") }
    }

    func test_parse_typeUnrecognized_producesStdioTransport() throws {
        let json = #"{"weather": {"type": "carrier-pigeon", "command": "python3", "args": []}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        guard case .stdio = servers[0].transport else { return XCTFail("expected stdio transport for an unrecognized type") }
    }

    func test_parse_typeHTTP_producesHTTPTransport() throws {
        let json = #"{"weather": {"type": "http", "url": "https://mcp.example.com/mcp", "headers": {"X-Region": "${MYVAR}"}}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: ["MYVAR": "xyz"])
        guard case .http(let url, let headerNames, _) = servers[0].transport else {
            return XCTFail("expected http transport")
        }
        XCTAssertEqual(url, "https://mcp.example.com/mcp")
        XCTAssertEqual(headerNames, ["X-Region"])
    }

    func test_parse_typeStreamableHTTP_producesHTTPTransport() throws {
        let json = #"{"weather": {"type": "streamable-http", "url": "https://mcp.example.com/mcp"}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        guard case .http = servers[0].transport else { return XCTFail("expected http transport") }
    }

    func test_parse_typeSSE_producesHTTPTransportWithLegacySSEHint() throws {
        let json = #"{"weather": {"type": "sse", "url": "https://mcp.example.com/sse"}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        guard case .http(_, _, let hint) = servers[0].transport else { return XCTFail("expected http transport") }
        XCTAssertEqual(hint, .legacySSE)
    }

    // MARK: - Unknown keys listed as ignored

    func test_parse_unknownKeys_listedAsIgnored() throws {
        let json = #"{"weather": {"command": "python3", "args": [], "someUnknownField": 42}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        XCTAssertEqual(servers[0].ignoredKeys, ["someUnknownField"])
    }

    // MARK: - Unresolved ${VAR}: value is not substituted, name flagged

    func test_parse_unresolvedEnvVariable_flagged_andValueLeftAsLiteral() throws {
        let json = #"{"weather": {"command": "python3", "args": [], "env": {"MYVAR": "${MISSING}"}}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        XCTAssertEqual(servers[0].unresolvedVariables, ["MISSING"])
        XCTAssertEqual(servers[0].envValues["MYVAR"], "${MISSING}", "an unresolved reference must not be substituted")
    }

    func test_parse_resolvedEnvVariable_notFlagged_andValueSubstituted() throws {
        let json = #"{"weather": {"command": "python3", "args": [], "env": {"MYVAR": "${SRC}"}}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: ["SRC": "xyz"])
        XCTAssertTrue(servers[0].unresolvedVariables.isEmpty)
        XCTAssertEqual(servers[0].envValues["MYVAR"], "xyz")
    }

    func test_parse_resolvedHeaderVariable_landsInHeaderValues_notInHeaderNames() throws {
        let json = #"{"weather": {"type": "http", "url": "https://mcp.example.com/mcp", "headers": {"X-Region": "${SRC}"}}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: ["SRC": "xyz"])
        guard case .http(_, let headerNames, _) = servers[0].transport else { return XCTFail("expected http transport") }
        XCTAssertEqual(headerNames, ["X-Region"])
        XCTAssertEqual(servers[0].headerValues["X-Region"], "xyz")
        XCTAssertFalse(headerNames.contains("xyz"), "the resolved value must not appear among the header names")
    }

    // MARK: - env / header values routed to envValues/headerValues, not the transport config

    func test_parse_envValues_notPresentInTransportEnvNamesOnly() throws {
        let json = #"{"weather": {"command": "python3", "args": [], "env": {"MYVAR": "xyz"}}}"#
        let servers = try MCPServersJSONImporter.parse(json, environment: [:])
        guard case .stdio(_, _, let envNames, _) = servers[0].transport else { return XCTFail("expected stdio") }
        XCTAssertEqual(envNames, ["MYVAR"])
        XCTAssertEqual(servers[0].envValues["MYVAR"], "xyz")
    }

    // MARK: - Parse errors report the 1-based line of the malformed token

    func test_parse_malformedJSON_reportsLineOfTheError() {
        let json = "{\n  \"a\": 1,\n  \"b\": }\n}"
        XCTAssertThrowsError(try MCPServersJSONImporter.parse(json, environment: [:])) { error in
            guard case MCPServersJSONImportError.parseError(let line, _, _) = error else {
                return XCTFail("expected .parseError, got \(error)")
            }
            XCTAssertEqual(line, 3)
        }
    }

    // MARK: - Alias clash resolution: digit suffix

    func test_resolveAliasClashes_duplicateCandidates_secondGetsDigitSuffix() {
        let resolved = MCPServersJSONImporter.resolveAliasClashes(candidates: ["myserver", "myserver"], existingAliases: [])
        XCTAssertEqual(resolved, ["myserver", "myserver2"])
    }

    func test_resolveAliasClashes_candidateClashesWithExisting_getsDigitSuffix() {
        let resolved = MCPServersJSONImporter.resolveAliasClashes(candidates: ["myserver"], existingAliases: ["myserver"])
        XCTAssertEqual(resolved, ["myserver2"])
    }

    func test_resolveAliasClashes_noClash_unchanged() {
        let resolved = MCPServersJSONImporter.resolveAliasClashes(candidates: ["weather", "search"], existingAliases: [])
        XCTAssertEqual(resolved, ["weather", "search"])
    }
}
