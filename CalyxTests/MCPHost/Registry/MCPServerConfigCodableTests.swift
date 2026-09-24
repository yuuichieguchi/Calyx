//
//  MCPServerConfigCodableTests.swift
//  CalyxTests
//
//  Codable round trip for `MCPServerConfig`, the on-disk shape stored
//  in `mcp-servers.json` (contract v2 SS7.1-SS7.5), and the
//  `MCPServerTransportConfig.fingerprint` used to key the in-memory
//  protocol-era cache.
//

import XCTest
@testable import Calyx

final class MCPServerConfigCodableTests: XCTestCase {

    private let fixedID = MCPServerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    private struct IDBox: Codable { let id: MCPServerID }

    // MARK: - stdio transport round trip

    func test_stdioConfig_encodeDecode_roundTrips() throws {
        let config = MCPServerConfig(
            id: fixedID,
            alias: MCPServerAlias(rawValue: "myserver")!,
            displayName: "My Server",
            isEnabled: true,
            transport: .stdio(command: "/usr/bin/tool", args: ["-m", "myserver"], envNames: ["MYVAR"], cwd: "/Users/me/project"),
            auth: nil
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func test_stdioConfig_cwdNil_roundTrips() throws {
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "s")!, displayName: "S", isEnabled: false,
            transport: .stdio(command: "cmd", args: [], envNames: [], cwd: nil), auth: nil
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        guard case .stdio(_, _, _, let cwd) = decoded.transport else { return XCTFail("expected stdio") }
        XCTAssertNil(cwd)
    }

    // MARK: - http transport round trip

    func test_httpConfig_transportOnly_encodeDecode_roundTrips() throws {
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "remote1")!, displayName: "Remote", isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: ["X-Region"], hint: .legacySSE),
            auth: nil
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        guard case .http(let url, let headerNames, let hint) = decoded.transport else { return XCTFail("expected http") }
        XCTAssertEqual(url, "https://mcp.example.com/mcp")
        XCTAssertEqual(headerNames, ["X-Region"])
        XCTAssertEqual(hint, .legacySSE)
    }

    func test_httpConfig_hintNil_roundTrips() throws {
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "remote2")!, displayName: "Remote2", isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil), auth: nil
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        guard case .http(_, _, let hint) = decoded.transport else { return XCTFail("expected http") }
        XCTAssertNil(hint)
    }

    // MARK: - MCPServerAuthConfig round trip (SS7.4: preRegisteredClientID, clientAuthenticationMethod, redirect, scopeOverride)
    //
    // clientAuthenticationMethod is a secret-free enum (SS6.2
    // MCPOAuthClientAuthenticationMethod): the config file never carries a
    // client-secret string, only which method the supervisor should use
    // when it assembles the real MCPOAuthClientAuthentication from the
    // SecretStore's .clientSecret entry.

    private func makeAuthConfig(method: MCPOAuthClientAuthenticationMethod?, redirect: MCPOAuthRedirectConfig) -> MCPServerAuthConfig {
        MCPServerAuthConfig(
            preRegisteredClientID: "client-1",
            clientAuthenticationMethod: method,
            redirect: redirect,
            scopeOverride: "files:read"
        )
    }

    func test_authConfig_methodNone_redirectRandom_roundTrips() throws {
        let auth = makeAuthConfig(method: .none, redirect: MCPOAuthRedirectConfig(host: .localhost, port: .random))
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "remote3")!, displayName: "Remote3", isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil),
            auth: auth
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded.auth?.redirect.host, .localhost)
        XCTAssertEqual(decoded.auth?.redirect.port, .random)
        XCTAssertEqual(decoded.auth?.clientAuthenticationMethod, .none)
    }

    func test_authConfig_methodClientSecretPost_roundTrips() throws {
        let auth = makeAuthConfig(method: .clientSecretPost, redirect: MCPOAuthRedirectConfig(host: .loopback, port: .random))
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "remote6")!, displayName: "Remote6", isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil),
            auth: auth
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded.auth?.clientAuthenticationMethod, .clientSecretPost)
    }

    func test_authConfig_methodClientSecretBasic_roundTrips() throws {
        let auth = makeAuthConfig(method: .clientSecretBasic, redirect: MCPOAuthRedirectConfig(host: .loopback, port: .random))
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "remote7")!, displayName: "Remote7", isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil),
            auth: auth
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded.auth?.clientAuthenticationMethod, .clientSecretBasic)
    }

    func test_authConfig_calyxFixedPort_roundTrips() throws {
        let auth = MCPServerAuthConfig(
            preRegisteredClientID: nil,
            clientAuthenticationMethod: nil,
            redirect: MCPOAuthRedirectConfig(host: .loopback, port: .calyxFixed),
            scopeOverride: nil
        )
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "remote4")!, displayName: "Remote4", isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil),
            auth: auth
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertEqual(decoded.auth?.redirect.port, .calyxFixed)
        XCTAssertNil(decoded.auth?.clientAuthenticationMethod)
        XCTAssertNil(decoded.auth?.preRegisteredClientID)
    }

    // MARK: - No secret string ever appears in the encoded JSON, for any method

    func test_authConfig_encodedJSON_neverContainsASecretString_forAnyMethod() throws {
        for method in [MCPOAuthClientAuthenticationMethod.none, .clientSecretPost, .clientSecretBasic] {
            let auth = makeAuthConfig(method: method, redirect: MCPOAuthRedirectConfig(host: .loopback, port: .random))
            let config = MCPServerConfig(
                id: fixedID, alias: MCPServerAlias(rawValue: "remote8")!, displayName: "Remote8", isEnabled: true,
                transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil),
                auth: auth
            )
            let data = try JSONEncoder().encode(config)
            let text = String(data: data, encoding: .utf8) ?? ""
            XCTAssertFalse(text.lowercased().contains("secretvalue"), "the config file must never carry an actual client-secret string, only the method \(method)")
        }
    }

    func test_config_authNil_roundTrips() throws {
        let config = MCPServerConfig(
            id: fixedID, alias: MCPServerAlias(rawValue: "remote5")!, displayName: "Remote5", isEnabled: true,
            transport: .http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil), auth: nil
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(MCPServerConfig.self, from: data)
        XCTAssertNil(decoded.auth)
    }

    // MARK: - id is a bare UUID string on disk (SS2.0/SS7.1), not wrapped in an object

    func test_id_encodesAsBareUUIDString() throws {
        let box = IDBox(id: fixedID)
        let data = try JSONEncoder().encode(box)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(object?["id"] as? String, "00000000-0000-0000-0000-000000000001")
    }

    func test_id_decodesFromBareUUIDString() throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000042"}"#
        let decoded = try JSONDecoder().decode(IDBox.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id.rawValue, UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)
    }

    // MARK: - alias rejects invalid raw values at decode time (SS7.5)

    func test_alias_invalidRawValue_failsToDecode() {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000042","alias":"Invalid-Alias!","displayName":"A","isEnabled":true,
         "transport":{"stdio":{"command":"cmd","args":[],"envNames":[],"cwd":null}}}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(MCPServerConfig.self, from: Data(json.utf8)))
    }

    // MARK: - MCPServerTransportConfig.fingerprint (SS7.3)

    func test_fingerprint_equalConfigs_equalFingerprints() {
        let a = MCPServerTransportConfig.stdio(command: "cmd", args: ["-x"], envNames: ["MYVAR"], cwd: "/tmp/x")
        let b = MCPServerTransportConfig.stdio(command: "cmd", args: ["-x"], envNames: ["MYVAR"], cwd: "/tmp/x")
        XCTAssertEqual(a.fingerprint, b.fingerprint)
    }

    func test_fingerprint_differsWhenCwdDiffers() {
        let a = MCPServerTransportConfig.stdio(command: "cmd", args: [], envNames: [], cwd: "/tmp/x")
        let b = MCPServerTransportConfig.stdio(command: "cmd", args: [], envNames: [], cwd: "/tmp/y")
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func test_fingerprint_differsWhenHintDiffers() {
        let a = MCPServerTransportConfig.http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil)
        let b = MCPServerTransportConfig.http(url: "https://mcp.example.com/mcp", headerNames: [], hint: .legacySSE)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func test_fingerprint_differsWhenEnvNamesDiffer() {
        let a = MCPServerTransportConfig.stdio(command: "cmd", args: [], envNames: ["A"], cwd: nil)
        let b = MCPServerTransportConfig.stdio(command: "cmd", args: [], envNames: ["B"], cwd: nil)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func test_fingerprint_differsBetweenStdioAndHttp() {
        let a = MCPServerTransportConfig.stdio(command: "cmd", args: [], envNames: [], cwd: nil)
        let b = MCPServerTransportConfig.http(url: "https://mcp.example.com/mcp", headerNames: [], hint: nil)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func test_fingerprint_isAHexSHA256String() {
        let a = MCPServerTransportConfig.stdio(command: "cmd", args: [], envNames: [], cwd: nil)
        let fingerprint = a.fingerprint
        XCTAssertEqual(fingerprint.count, 64, "SHA-256 hex digest is 64 characters")
        XCTAssertTrue(fingerprint.allSatisfy { $0.isHexDigit }, "fingerprint must be hex")
    }
}
