//
//  MCPOAuthMetadataDiscoveryTests.swift
//  CalyxTests
//
//  API contract section 6.9. RFC 9728 protected-resource discovery
//  order (WWW-Authenticate `resource_metadata` hint, then path-inserted
//  well-known, then root) and RFC 8414 / OIDC authorization-server
//  metadata discovery order, with `issuer` exact match.
//
//    struct MCPOAuthProtectedResourceMetadata: Sendable, Equatable, Codable {
//        let resource: String; let authorizationServers: [String]
//    }
//    struct MCPOAuthAuthorizationServerMetadata: Sendable, Equatable, Codable {
//        let issuer: String
//        let authorizationEndpoint: String
//        let tokenEndpoint: String
//        let registrationEndpoint: String?
//        let scopesSupported: [String]?
//        let codeChallengeMethodsSupported: [String]?
//        let clientIDMetadataDocumentSupported: Bool?
//        let authorizationResponseIssParameterSupported: Bool?
//    }
//    enum MCPOAuthMetadataDiscoveryError: Error, Sendable, Equatable {
//        case resourceMismatch(expected: String, got: String)
//        case issuerMismatch(expected: String, got: String)
//        case noDiscoveryEndpointSucceeded
//        case pkceS256Unsupported
//    }
//    struct MCPOAuthMetadataDiscovery: Sendable {
//        init(session: MCPHTTPSession)
//        func discoverProtectedResourceMetadata(mcpServerURL: URL, resourceMetadataHintURL: URL?, canonicalResourceURI: String) async throws -> MCPOAuthProtectedResourceMetadata
//        func discoverAuthorizationServerMetadata(issuer: URL) async throws -> MCPOAuthAuthorizationServerMetadata
//    }
//

import XCTest
@testable import Calyx

final class MCPOAuthMetadataDiscoveryTests: XCTestCase {

    private var recorder: MCPHTTPStubRecorder!
    private var urlSession: URLSession!

    override func setUp() {
        super.setUp()
        recorder = MCPHTTPStubRecorder()
        urlSession = URLSession(configuration: MCPHTTPStubProtocol.configuration(recorder: recorder))
    }

    override func tearDown() {
        urlSession = nil
        recorder = nil
        super.tearDown()
    }

    private func discovery() -> MCPOAuthMetadataDiscovery {
        MCPOAuthMetadataDiscovery(session: MCPHTTPSession(urlSession: urlSession))
    }

    private func prmJSON(resource: String, authorizationServers: [String] = ["https://auth.example.com"]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["resource": resource, "authorization_servers": authorizationServers])
    }

    // MARK: - Protected Resource Metadata discovery order

    func test_discoverProtectedResourceMetadata_headerHint_usedDirectly_noWellKnownProbe() async throws {
        recorder.enqueue { _ in .json(status: 200, body: self.prmJSON(resource: "https://mcp.example.com/mcp")) }
        let result = try await discovery().discoverProtectedResourceMetadata(
            mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
            resourceMetadataHintURL: URL(string: "https://mcp.example.com/custom-metadata-location")!,
            canonicalResourceURI: "https://mcp.example.com/mcp"
        )
        XCTAssertEqual(result.resource, "https://mcp.example.com/mcp")
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.url.path, "/custom-metadata-location")
    }

    func test_discoverProtectedResourceMetadata_noHint_triesPathInsertedWellKnownFirst() async throws {
        recorder.enqueue { request in
            XCTAssertEqual(request.url.path, "/.well-known/oauth-protected-resource/public/mcp")
            return .json(status: 200, body: self.prmJSON(resource: "https://mcp.example.com/public/mcp"))
        }
        let result = try await discovery().discoverProtectedResourceMetadata(
            mcpServerURL: URL(string: "https://mcp.example.com/public/mcp")!,
            resourceMetadataHintURL: nil,
            canonicalResourceURI: "https://mcp.example.com/public/mcp"
        )
        XCTAssertEqual(result.resource, "https://mcp.example.com/public/mcp")
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func test_discoverProtectedResourceMetadata_noHint_pathInsertedMissing_fallsBackToRoot() async throws {
        recorder.enqueue { _ in .empty(status: 404) } // path-inserted well-known missing
        recorder.enqueue { request in
            XCTAssertEqual(request.url.path, "/.well-known/oauth-protected-resource")
            return .json(status: 200, body: self.prmJSON(resource: "https://mcp.example.com/public/mcp"))
        }
        let result = try await discovery().discoverProtectedResourceMetadata(
            mcpServerURL: URL(string: "https://mcp.example.com/public/mcp")!,
            resourceMetadataHintURL: nil,
            canonicalResourceURI: "https://mcp.example.com/public/mcp"
        )
        XCTAssertEqual(result.resource, "https://mcp.example.com/public/mcp")
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func test_discoverProtectedResourceMetadata_bothWellKnownsFail_throwsNoDiscoveryEndpointSucceeded() async throws {
        recorder.enqueue { _ in .empty(status: 404) }
        recorder.enqueue { _ in .empty(status: 404) }
        do {
            _ = try await discovery().discoverProtectedResourceMetadata(
                mcpServerURL: URL(string: "https://mcp.example.com/public/mcp")!,
                resourceMetadataHintURL: nil,
                canonicalResourceURI: "https://mcp.example.com/public/mcp"
            )
            XCTFail("expected noDiscoveryEndpointSucceeded")
        } catch let error as MCPOAuthMetadataDiscoveryError {
            XCTAssertEqual(error, .noDiscoveryEndpointSucceeded)
        }
    }

    func test_discoverProtectedResourceMetadata_resourceMustMatchCanonicalURI() async throws {
        recorder.enqueue { _ in .json(status: 200, body: self.prmJSON(resource: "https://other.example.com/mcp")) }
        do {
            _ = try await discovery().discoverProtectedResourceMetadata(
                mcpServerURL: URL(string: "https://mcp.example.com/mcp")!,
                resourceMetadataHintURL: URL(string: "https://mcp.example.com/.well-known/oauth-protected-resource")!,
                canonicalResourceURI: "https://mcp.example.com/mcp"
            )
            XCTFail("expected resourceMismatch")
        } catch let error as MCPOAuthMetadataDiscoveryError {
            XCTAssertEqual(error, .resourceMismatch(expected: "https://mcp.example.com/mcp", got: "https://other.example.com/mcp"))
        }
    }

    // MARK: - Authorization Server Metadata discovery order: issuer with path

    private func asJSON(issuer: String, codeChallengeMethods: [String]? = ["S256"]) -> Data {
        var object: [String: Any] = [
            "issuer": issuer,
            "authorization_endpoint": "\(issuer)/authorize",
            "token_endpoint": "\(issuer)/token",
        ]
        if let codeChallengeMethods {
            object["code_challenge_methods_supported"] = codeChallengeMethods
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    func test_discoverAuthorizationServerMetadata_issuerWithPath_triesOAuthPathInsertFirst() async throws {
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, "https://auth.example.com/.well-known/oauth-authorization-server/tenant1")
            return .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com/tenant1"))
        }
        let result = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com/tenant1")!)
        XCTAssertEqual(result.issuer, "https://auth.example.com/tenant1")
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func test_discoverAuthorizationServerMetadata_issuerWithPath_fallsBackToOIDCPathInsert() async throws {
        recorder.enqueue { _ in .empty(status: 404) } // OAuth path-insert
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, "https://auth.example.com/.well-known/openid-configuration/tenant1")
            return .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com/tenant1"))
        }
        let result = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com/tenant1")!)
        XCTAssertEqual(result.issuer, "https://auth.example.com/tenant1")
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func test_discoverAuthorizationServerMetadata_issuerWithPath_fallsBackToOIDCPathAppend() async throws {
        recorder.enqueue { _ in .empty(status: 404) } // OAuth path-insert
        recorder.enqueue { _ in .empty(status: 404) } // OIDC path-insert
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, "https://auth.example.com/tenant1/.well-known/openid-configuration")
            return .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com/tenant1"))
        }
        let result = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com/tenant1")!)
        XCTAssertEqual(result.issuer, "https://auth.example.com/tenant1")
        XCTAssertEqual(recorder.requests.count, 3)
    }

    // MARK: - Authorization Server Metadata discovery order: issuer without path

    func test_discoverAuthorizationServerMetadata_issuerWithoutPath_triesOAuthRootFirst() async throws {
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, "https://auth.example.com/.well-known/oauth-authorization-server")
            return .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com"))
        }
        let result = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com")!)
        XCTAssertEqual(result.issuer, "https://auth.example.com")
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func test_discoverAuthorizationServerMetadata_issuerWithoutPath_fallsBackToOIDCRoot() async throws {
        recorder.enqueue { _ in .empty(status: 404) }
        recorder.enqueue { request in
            XCTAssertEqual(request.url.absoluteString, "https://auth.example.com/.well-known/openid-configuration")
            return .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com"))
        }
        let result = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com")!)
        XCTAssertEqual(result.issuer, "https://auth.example.com")
        XCTAssertEqual(recorder.requests.count, 2)
    }

    // MARK: - Exact issuer match

    func test_discoverAuthorizationServerMetadata_issuerMismatch_rejected() async throws {
        recorder.enqueue { _ in .json(status: 200, body: self.asJSON(issuer: "https://honest.example.com")) }
        do {
            _ = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://attacker.example.com")!)
            XCTFail("expected issuerMismatch")
        } catch let error as MCPOAuthMetadataDiscoveryError {
            XCTAssertEqual(error, .issuerMismatch(expected: "https://attacker.example.com", got: "https://honest.example.com"))
        }
    }

    // MARK: - PKCE S256 required

    func test_discoverAuthorizationServerMetadata_codeChallengeMethodsMissingS256_refused() async throws {
        recorder.enqueue { _ in .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com", codeChallengeMethods: ["plain"])) }
        do {
            _ = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com")!)
            XCTFail("expected pkceS256Unsupported")
        } catch let error as MCPOAuthMetadataDiscoveryError {
            XCTAssertEqual(error, .pkceS256Unsupported)
        }
    }

    func test_discoverAuthorizationServerMetadata_codeChallengeMethodsAbsent_refused() async throws {
        recorder.enqueue { _ in .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com", codeChallengeMethods: nil)) }
        do {
            _ = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com")!)
            XCTFail("expected pkceS256Unsupported")
        } catch let error as MCPOAuthMetadataDiscoveryError {
            XCTAssertEqual(error, .pkceS256Unsupported)
        }
    }

    func test_discoverAuthorizationServerMetadata_codeChallengeMethodsIncludesS256_succeeds() async throws {
        recorder.enqueue { _ in .json(status: 200, body: self.asJSON(issuer: "https://auth.example.com", codeChallengeMethods: ["plain", "S256"])) }
        let result = try await discovery().discoverAuthorizationServerMetadata(issuer: URL(string: "https://auth.example.com")!)
        XCTAssertEqual(result.codeChallengeMethodsSupported, ["plain", "S256"])
    }
}
