//
//  MCPOAuthCredentialClientTests.swift
//  CalyxTests
//
//  API contract section 6.2. File name avoids "token" per the Auth
//  module's filename constraint; the type itself is `MCPOAuthTokenClient`.
//
//    actor MCPOAuthTokenClient {
//        init(session: MCPHTTPSession, tokenEndpoint: URL, clientID: String, clientAuthentication: MCPOAuthClientAuthentication, now: @Sendable () -> Date = Date.init)
//        func exchangeCode(_ code: String, verifier: String, redirectURI: String, canonicalResourceURI: String) async throws -> MCPOAuthTokenSet
//        func refreshedIfNeeded(_ tokens: MCPOAuthTokenSet) async throws -> MCPOAuthTokenSet
//        func refreshAfter401(_ tokens: MCPOAuthTokenSet) async throws -> MCPOAuthTokenSet
//    }
//    enum MCPOAuthClientAuthentication: Sendable, Equatable {
//        case none
//        case clientSecretPost(secret: String)
//        case clientSecretBasic(secret: String)
//    }
//
//  `exchangeCode`'s body carries `code_verifier`, URL-encoded `resource`,
//  `grant_type=authorization_code`, `code`, `redirect_uri`. When
//  `clientAuthentication` is `.clientSecretPost`/`.clientSecretBasic` the
//  client secret is attached to the body or the `Authorization` header
//  (section 6.2 prose).
//

import XCTest
@testable import Calyx

final class MCPOAuthCredentialClientTests: XCTestCase {

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

    private func makeClient(clientAuthentication: MCPOAuthClientAuthentication = .none, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }) -> MCPOAuthTokenClient {
        MCPOAuthTokenClient(
            session: MCPHTTPSession(urlSession: urlSession),
            tokenEndpoint: URL(string: "https://auth.example.com/token")!,
            clientID: "cid",
            clientAuthentication: clientAuthentication,
            canonicalResourceURI: "https://mcp.example.com/mcp",
            now: now
        )
    }

    // MARK: - exchangeCode body shape

    func test_exchangeCode_requestBody_includesCodeVerifierResourceGrantTypeCodeRedirectURI() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"access_token":"abc","token_type":"Bearer","expires_in":3600}"#.utf8)) }
        let client = makeClient()
        _ = try await client.exchangeCode("auth-code-xyz", verifier: "verifier-value", redirectURI: "http://127.0.0.1:54321/callback", canonicalResourceURI: "https://mcp.example.com/mcp")

        let request = try XCTUnwrap(recorder.requests.first)
        let params = formParams(from: request)
        XCTAssertEqual(params["code_verifier"], "verifier-value")
        XCTAssertEqual(params["resource"], "https%3A%2F%2Fmcp.example.com%2Fmcp")
        XCTAssertEqual(params["grant_type"], "authorization_code")
        XCTAssertEqual(params["code"], "auth-code-xyz")
        XCTAssertEqual(params["redirect_uri"]?.removingPercentEncoding, "http://127.0.0.1:54321/callback")
    }

    func test_exchangeCode_expiresAtComputedFromNowPlusExpiresIn() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"access_token":"abc","token_type":"Bearer","expires_in":3600}"#.utf8)) }
        let client = makeClient(now: { Date(timeIntervalSince1970: 0) })
        let tokens = try await client.exchangeCode("auth-code-xyz", verifier: "verifier-value", redirectURI: "http://127.0.0.1:54321/callback", canonicalResourceURI: "https://mcp.example.com/mcp")
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 3600))
    }

    // MARK: - refreshedIfNeeded: expired refreshes, fresh does not

    func test_refreshedIfNeeded_tokenExpired_refreshesBeforeReturning() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"access_token":"new","token_type":"Bearer","expires_in":3600}"#.utf8)) }
        let client = makeClient(now: { Date(timeIntervalSince1970: 3700) })
        let expired = MCPOAuthTokenSet(accessToken: "old", refreshToken: "ref-1", expiresAt: Date(timeIntervalSince1970: 3600), scope: nil)

        let refreshed = try await client.refreshedIfNeeded(expired)
        XCTAssertEqual(refreshed.accessToken, "new")
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        let params = formParams(from: request)
        XCTAssertEqual(params["grant_type"], "refresh_token")
        XCTAssertEqual(params["refresh_token"], "ref-1")
        XCTAssertEqual(params["resource"], "https%3A%2F%2Fmcp.example.com%2Fmcp")
    }

    func test_refreshedIfNeeded_tokenNotYetExpired_isANoOp() async throws {
        let client = makeClient(now: { Date(timeIntervalSince1970: 10) })
        let fresh = MCPOAuthTokenSet(accessToken: "fresh", refreshToken: "ref-1", expiresAt: Date(timeIntervalSince1970: 3600), scope: nil)

        let result = try await client.refreshedIfNeeded(fresh)
        XCTAssertEqual(result.accessToken, "fresh")
        XCTAssertEqual(recorder.requests.count, 0)
    }

    // MARK: - refreshAfter401 issues exactly one refresh request

    func test_refreshAfter401_issuesExactlyOneRefreshRequest() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"access_token":"after-401","token_type":"Bearer","expires_in":3600}"#.utf8)) }
        let client = makeClient()
        let tokens = MCPOAuthTokenSet(accessToken: "old", refreshToken: "ref-1", expiresAt: nil, scope: nil)

        let refreshed = try await client.refreshAfter401(tokens)
        XCTAssertEqual(refreshed.accessToken, "after-401")
        XCTAssertEqual(recorder.requests.count, 1)
        let request = try XCTUnwrap(recorder.requests.first)
        let params = formParams(from: request)
        XCTAssertEqual(params["grant_type"], "refresh_token")
        XCTAssertEqual(params["refresh_token"], "ref-1")
        XCTAssertEqual(params["resource"], "https%3A%2F%2Fmcp.example.com%2Fmcp")
    }

    // MARK: - invalid_grant -> top-level MCPOAuthFlowError.needsAuthorization

    func test_refreshAfter401_invalidGrant_throwsNeedsAuthorization() async throws {
        recorder.enqueue { _ in .json(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let client = makeClient()
        let tokens = MCPOAuthTokenSet(accessToken: "old", refreshToken: "ref-1", expiresAt: nil, scope: nil)

        do {
            _ = try await client.refreshAfter401(tokens)
            XCTFail("expected needsAuthorization")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .needsAuthorization)
        }
    }

    // MARK: - Other token endpoint errors -> MCPOAuthFlowError.tokenEndpointFailed

    func test_exchangeCode_errorOtherThanInvalidGrant_throwsTokenEndpointFailed() async throws {
        recorder.enqueue { _ in .json(status: 401, body: Data(#"{"error":"invalid_client","error_description":"unknown client"}"#.utf8)) }
        let client = makeClient()

        do {
            _ = try await client.exchangeCode("code", verifier: "verifier", redirectURI: "http://127.0.0.1:0/callback", canonicalResourceURI: "https://mcp.example.com/mcp")
            XCTFail("expected tokenEndpointFailed")
        } catch let error as MCPOAuthFlowError {
            XCTAssertEqual(error, .tokenEndpointFailed(error: "invalid_client", description: "unknown client"))
        }
    }

    // MARK: - Client authentication: none attaches neither header nor secret

    func test_clientAuthenticationNone_noAuthorizationHeader_noClientSecretInBody() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"access_token":"abc","token_type":"Bearer","expires_in":3600}"#.utf8)) }
        let client = makeClient(clientAuthentication: .none)
        _ = try await client.exchangeCode("code", verifier: "verifier", redirectURI: "http://127.0.0.1:0/callback", canonicalResourceURI: "https://mcp.example.com/mcp")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(formParams(from: request)["client_secret"])
    }

    // MARK: - Client authentication: clientSecretPost puts the secret in the body

    func test_clientAuthenticationSecretPost_secretInBody_noAuthorizationHeader() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"access_token":"abc","token_type":"Bearer","expires_in":3600}"#.utf8)) }
        let client = makeClient(clientAuthentication: .clientSecretPost(secret: "abc"))
        _ = try await client.exchangeCode("code", verifier: "verifier", redirectURI: "http://127.0.0.1:0/callback", canonicalResourceURI: "https://mcp.example.com/mcp")

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertEqual(formParams(from: request)["client_secret"], "abc")
    }

    // MARK: - Client authentication: clientSecretBasic puts the secret in the Authorization header

    func test_clientAuthenticationSecretBasic_secretInAuthorizationHeader_notInBody() async throws {
        recorder.enqueue { _ in .json(status: 200, body: Data(#"{"access_token":"abc","token_type":"Bearer","expires_in":3600}"#.utf8)) }
        let client = makeClient(clientAuthentication: .clientSecretBasic(secret: "abc"))
        _ = try await client.exchangeCode("code", verifier: "verifier", redirectURI: "http://127.0.0.1:0/callback", canonicalResourceURI: "https://mcp.example.com/mcp")

        let request = try XCTUnwrap(recorder.requests.first)
        // Independently computed: base64("cid:abc") == "Y2lkOmFiYw==" (python base64.b64encode(b"cid:abc")).
        XCTAssertEqual(request.headers["Authorization"], "Basic Y2lkOmFiYw==")
        XCTAssertNil(formParams(from: request)["client_secret"])
    }

    // MARK: - helpers

    private func formParams(from request: MCPHTTPRecordedRequest) -> [String: String] {
        let bodyString = String(data: request.bodyData ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(uniqueKeysWithValues: bodyString.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })
    }
}
