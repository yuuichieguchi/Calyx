//
//  MCPOAuthProtectedRequestExecutorTests.swift
//  CalyxTests
//
//  API contract section 6.8.
//
//    actor MCPOAuthProtectedRequestExecutor {
//        enum MCPOAuthProtectedRequestError: Error, Sendable, Equatable { case scopeStepUpExhausted, needsAuthorization }
//        init(maxScopeStepUps: Int = 2)
//        func execute(
//            tokens: MCPOAuthTokenSet,
//            send: @Sendable (MCPOAuthTokenSet) async throws -> MCPHTTPSession.Response,
//            reauthorizeWithScope: @Sendable (String) async throws -> MCPOAuthTokenSet
//        ) async throws -> MCPHTTPSession.Response
//    }
//
//  A 403 `insufficient_scope` is retried up to `maxScopeStepUps` times
//  with a re-authorized token for the challenge scope; a 401 surfaces
//  as `.needsAuthorization` without any step-up retry (section 6.8:
//  this actor handles only the 403 step-up, not refresh).
//

import XCTest
@testable import Calyx

final class MCPOAuthProtectedRequestExecutorTests: XCTestCase {

    private func deniedResponse(scope: String = "files:write") -> MCPHTTPSession.Response {
        MCPHTTPSession.Response(statusCode: 403, headers: ["WWW-Authenticate": #"Bearer error="insufficient_scope", scope="\#(scope)""#], body: Data())
    }

    // MARK: - Persistent insufficient_scope: retried exactly maxScopeStepUps times, then throws

    func test_execute_persistentInsufficientScope_retriesAtMostMaxScopeStepUps_thenThrowsExhausted() async throws {
        let executor = MCPOAuthProtectedRequestExecutor(maxScopeStepUps: 2)
        let sendCallCount = Locked(0)
        let reauthorizeCallCount = Locked(0)
        let denied = deniedResponse()

        do {
            _ = try await executor.execute(
                tokens: MCPOAuthTokenSet(accessToken: "tok", refreshToken: nil, expiresAt: nil, scope: "files:read"),
                send: { _ in
                    sendCallCount.withLock { $0 += 1 }
                    return denied
                },
                reauthorizeWithScope: { scope in
                    let count = reauthorizeCallCount.withLock { $0 += 1; return $0 }
                    return MCPOAuthTokenSet(accessToken: "tok-\(count)", refreshToken: nil, expiresAt: nil, scope: scope)
                }
            )
            XCTFail("expected scopeStepUpExhausted")
        } catch let error as MCPOAuthProtectedRequestExecutor.MCPOAuthProtectedRequestError {
            XCTAssertEqual(error, .scopeStepUpExhausted)
        }

        XCTAssertEqual(sendCallCount.withLock { $0 }, 3, "the original attempt plus exactly two step-up retries")
        XCTAssertEqual(reauthorizeCallCount.withLock { $0 }, 2)
    }

    // MARK: - Succeeds on first retry: stops retrying immediately

    func test_execute_succeedsOnFirstRetry_stopsRetrying() async throws {
        let executor = MCPOAuthProtectedRequestExecutor(maxScopeStepUps: 2)
        let sendCallCount = Locked(0)
        let denied = deniedResponse()
        let okResponse = MCPHTTPSession.Response(statusCode: 200, headers: [:], body: Data("{}".utf8))

        let result = try await executor.execute(
            tokens: MCPOAuthTokenSet(accessToken: "tok", refreshToken: nil, expiresAt: nil, scope: "files:read"),
            send: { _ in
                let count = sendCallCount.withLock { $0 += 1; return $0 }
                return count == 1 ? denied : okResponse
            },
            reauthorizeWithScope: { scope in MCPOAuthTokenSet(accessToken: "tok-2", refreshToken: nil, expiresAt: nil, scope: scope) }
        )

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(sendCallCount.withLock { $0 }, 2)
    }

    // MARK: - 200 on first attempt: no reauthorization at all

    func test_execute_firstAttemptSucceeds_neverCallsReauthorize() async throws {
        let executor = MCPOAuthProtectedRequestExecutor(maxScopeStepUps: 2)
        let reauthorizeCallCount = Locked(0)
        let okResponse = MCPHTTPSession.Response(statusCode: 200, headers: [:], body: Data("{}".utf8))

        let result = try await executor.execute(
            tokens: MCPOAuthTokenSet(accessToken: "tok", refreshToken: nil, expiresAt: nil, scope: "files:read"),
            send: { _ in okResponse },
            reauthorizeWithScope: { scope in
                reauthorizeCallCount.withLock { $0 += 1 }
                return MCPOAuthTokenSet(accessToken: "tok-2", refreshToken: nil, expiresAt: nil, scope: scope)
            }
        )

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(reauthorizeCallCount.withLock { $0 }, 0)
    }

    // MARK: - 401 surfaces as needsAuthorization, without a step-up retry

    func test_execute_401Response_throwsNeedsAuthorization_withoutStepUpRetry() async throws {
        let executor = MCPOAuthProtectedRequestExecutor(maxScopeStepUps: 2)
        let sendCallCount = Locked(0)
        let reauthorizeCallCount = Locked(0)
        let unauthorizedResponse = MCPHTTPSession.Response(statusCode: 401, headers: [:], body: Data())

        do {
            _ = try await executor.execute(
                tokens: MCPOAuthTokenSet(accessToken: "tok", refreshToken: nil, expiresAt: nil, scope: "files:read"),
                send: { _ in
                    sendCallCount.withLock { $0 += 1 }
                    return unauthorizedResponse
                },
                reauthorizeWithScope: { scope in
                    reauthorizeCallCount.withLock { $0 += 1 }
                    return MCPOAuthTokenSet(accessToken: "tok-2", refreshToken: nil, expiresAt: nil, scope: scope)
                }
            )
            XCTFail("expected needsAuthorization")
        } catch let error as MCPOAuthProtectedRequestExecutor.MCPOAuthProtectedRequestError {
            XCTAssertEqual(error, .needsAuthorization)
        }

        XCTAssertEqual(sendCallCount.withLock { $0 }, 1)
        XCTAssertEqual(reauthorizeCallCount.withLock { $0 }, 0)
    }
}
