//
//  MCPOAuthClientRegistrationTests.swift
//  CalyxTests
//
//  API contract section 6.10. Client registration priority order:
//  pre-registered > Client ID Metadata Document (only when the AS
//  advertises `client_id_metadata_document_supported: true`) > Dynamic
//  Client Registration > ask the user (`.needsUserInput`).
//
//    enum MCPOAuthClientRegistrationOutcome: Sendable, Equatable {
//        case preRegistered(clientID: String)
//        case cimd(clientID: String)
//        case dynamicallyRegistered(clientID: String)
//        case needsUserInput
//    }
//    protocol MCPOAuthClientRegistrationStoring: Sendable {
//        func clientID(forIssuer issuer: String) async -> String?
//        func store(clientID: String, forIssuer issuer: String) async
//    }
//    struct MCPOAuthClientRegistration: Sendable {
//        static let cimdClientID = "https://getcalyx.app/oauth/mcp-client.json"
//        init(session: MCPHTTPSession, store: any MCPOAuthClientRegistrationStoring)
//        func register(
//            issuer: String,
//            serverMetadata: MCPOAuthAuthorizationServerMetadata,
//            preRegisteredClientID: String?,
//            redirectURIs: [String]
//        ) async throws -> MCPOAuthClientRegistrationOutcome
//    }
//
//  DCR body per section 6.10: `application_type: "native"`,
//  `token_endpoint_auth_method: "none"`,
//  `grant_types: [authorization_code, refresh_token]`, `redirect_uris`.
//

import XCTest
@testable import Calyx

final class MCPOAuthClientRegistrationTests: XCTestCase {

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

    private func metadata(
        issuer: String = "https://auth.example.com",
        registrationEndpoint: String? = "https://auth.example.com/register",
        cimdSupported: Bool? = nil
    ) -> MCPOAuthAuthorizationServerMetadata {
        MCPOAuthAuthorizationServerMetadata(
            issuer: issuer,
            authorizationEndpoint: "\(issuer)/authorize",
            tokenEndpoint: "\(issuer)/token",
            registrationEndpoint: registrationEndpoint,
            scopesSupported: nil,
            codeChallengeMethodsSupported: ["S256"],
            clientIDMetadataDocumentSupported: cimdSupported,
            authorizationResponseIssParameterSupported: nil
        )
    }

    // MARK: - Priority: pre-registered wins over everything else

    func test_register_preRegisteredClientID_usedDirectly_noNetworkCall() async throws {
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: InMemoryMCPOAuthClientRegistrationStore())
        let outcome = try await registration.register(
            issuer: "https://auth.example.com",
            serverMetadata: metadata(cimdSupported: true),
            preRegisteredClientID: "preregistered-client-id",
            redirectURIs: ["http://127.0.0.1:0/callback"]
        )
        XCTAssertEqual(outcome, .preRegistered(clientID: "preregistered-client-id"))
        XCTAssertEqual(recorder.requests.count, 0)
    }

    // MARK: - Priority: CIMD over DCR, only when advertised

    func test_register_noPreRegistered_cimdSupported_usesCIMDClientID_noNetworkCall() async throws {
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: InMemoryMCPOAuthClientRegistrationStore())
        let outcome = try await registration.register(
            issuer: "https://auth.example.com",
            serverMetadata: metadata(cimdSupported: true),
            preRegisteredClientID: nil,
            redirectURIs: ["http://127.0.0.1:0/callback"]
        )
        XCTAssertEqual(outcome, .cimd(clientID: MCPOAuthClientRegistration.cimdClientID))
        XCTAssertEqual(outcome, .cimd(clientID: "https://getcalyx.app/oauth/mcp-client.json"))
        XCTAssertEqual(recorder.requests.count, 0, "CIMD needs no registration round trip -- the URL itself is the client_id")
    }

    func test_register_cimdNotAdvertised_fallsBackToDCR() async throws {
        recorder.enqueue { _ in .json(status: 201, body: Data(#"{"client_id":"dcr-client-id"}"#.utf8)) }
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: InMemoryMCPOAuthClientRegistrationStore())
        let outcome = try await registration.register(
            issuer: "https://auth.example.com",
            serverMetadata: metadata(cimdSupported: false),
            preRegisteredClientID: nil,
            redirectURIs: ["http://127.0.0.1:0/callback"]
        )
        XCTAssertEqual(outcome, .dynamicallyRegistered(clientID: "dcr-client-id"))
    }

    func test_register_cimdFieldAbsent_treatedAsNotSupported_fallsBackToDCR() async throws {
        recorder.enqueue { _ in .json(status: 201, body: Data(#"{"client_id":"dcr-client-id"}"#.utf8)) }
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: InMemoryMCPOAuthClientRegistrationStore())
        let outcome = try await registration.register(
            issuer: "https://auth.example.com",
            serverMetadata: metadata(cimdSupported: nil),
            preRegisteredClientID: nil,
            redirectURIs: ["http://127.0.0.1:0/callback"]
        )
        XCTAssertEqual(outcome, .dynamicallyRegistered(clientID: "dcr-client-id"))
    }

    // MARK: - DCR request body shape

    func test_register_dcrRequest_bodyDeclaresNativeApplicationAndNoAuthMethod() async throws {
        recorder.enqueue { _ in .json(status: 201, body: Data(#"{"client_id":"dcr-client-id"}"#.utf8)) }
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: InMemoryMCPOAuthClientRegistrationStore())
        _ = try await registration.register(
            issuer: "https://auth.example.com",
            serverMetadata: metadata(cimdSupported: false),
            preRegisteredClientID: nil,
            redirectURIs: ["http://127.0.0.1:0/callback", "http://localhost:0/callback"]
        )

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.method, "POST")
        let body = try XCTUnwrap(request.bodyData)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["application_type"] as? String, "native")
        XCTAssertEqual(object["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(Set(object["grant_types"] as? [String] ?? []), ["authorization_code", "refresh_token"])
        XCTAssertEqual(object["redirect_uris"] as? [String], ["http://127.0.0.1:0/callback", "http://localhost:0/callback"])
    }

    func test_register_dcrEndpointMissing_noRegistrationEndpoint_asksUser() async throws {
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: InMemoryMCPOAuthClientRegistrationStore())
        let outcome = try await registration.register(
            issuer: "https://auth.example.com",
            serverMetadata: metadata(registrationEndpoint: nil, cimdSupported: false),
            preRegisteredClientID: nil,
            redirectURIs: ["http://127.0.0.1:0/callback"]
        )
        XCTAssertEqual(outcome, .needsUserInput)
        XCTAssertEqual(recorder.requests.count, 0)
    }

    // MARK: - DCR credentials stored keyed by issuer, never reused with another issuer

    func test_register_dcrCredentials_storedKeyedByIssuer() async throws {
        recorder.enqueue { _ in .json(status: 201, body: Data(#"{"client_id":"dcr-client-id-for-a"}"#.utf8)) }
        let store = InMemoryMCPOAuthClientRegistrationStore()
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: store)
        _ = try await registration.register(
            issuer: "https://auth-a.example.com",
            serverMetadata: metadata(issuer: "https://auth-a.example.com", cimdSupported: false),
            preRegisteredClientID: nil,
            redirectURIs: ["http://127.0.0.1:0/callback"]
        )

        let storedForA = await store.clientID(forIssuer: "https://auth-a.example.com")
        let storedForB = await store.clientID(forIssuer: "https://auth-b.example.com")
        XCTAssertEqual(storedForA, "dcr-client-id-for-a")
        XCTAssertNil(storedForB, "credentials registered with issuer A must never be visible under issuer B's key")
    }

    func test_register_previouslyStoredDCRCredentials_forSameIssuer_reusedWithoutReRegistering() async throws {
        let store = InMemoryMCPOAuthClientRegistrationStore()
        await store.store(clientID: "already-registered", forIssuer: "https://auth.example.com")
        let registration = MCPOAuthClientRegistration(session: MCPHTTPSession(urlSession: urlSession), store: store)
        let outcome = try await registration.register(
            issuer: "https://auth.example.com",
            serverMetadata: metadata(cimdSupported: false),
            preRegisteredClientID: nil,
            redirectURIs: ["http://127.0.0.1:0/callback"]
        )
        XCTAssertEqual(outcome, .dynamicallyRegistered(clientID: "already-registered"))
        XCTAssertEqual(recorder.requests.count, 0, "an issuer with already-stored DCR credentials must not re-register")
    }
}
