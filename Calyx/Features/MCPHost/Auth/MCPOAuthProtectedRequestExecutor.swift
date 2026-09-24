//
//  MCPOAuthProtectedRequestExecutor.swift
//  Calyx
//
//  Sends a protected request and handles a 403 `insufficient_scope`
//  challenge by re-authorizing with the challenge's scope merged into the
//  granted one, a bounded number of times. A 401 is reported, not retried;
//  refreshing is `MCPOAuthTokenClient.refreshAfter401`'s job.
//

import Foundation

actor MCPOAuthProtectedRequestExecutor {

    enum MCPOAuthProtectedRequestError: Error, Sendable, Equatable {
        case scopeStepUpExhausted
        case needsAuthorization
    }

    private let maxScopeStepUps: Int

    init(maxScopeStepUps: Int = 2) {
        self.maxScopeStepUps = maxScopeStepUps
    }

    /// Returns the first response that is neither a 401 nor a 403
    /// `insufficient_scope`. A 401 throws `.needsAuthorization`. A 403
    /// `insufficient_scope` after `maxScopeStepUps` re-authorizations, or
    /// one whose challenge carries no scope, throws `.scopeStepUpExhausted`.
    func execute(
        tokens: MCPOAuthTokenSet,
        send: @Sendable (MCPOAuthTokenSet) async throws -> MCPHTTPSession.Response,
        reauthorizeWithScope: @Sendable (String) async throws -> MCPOAuthTokenSet
    ) async throws -> MCPHTTPSession.Response {
        var current = tokens
        var stepUps = 0
        while true {
            let response = try await send(current)
            if response.statusCode == 401 {
                throw MCPOAuthProtectedRequestError.needsAuthorization
            }
            guard response.statusCode == 403,
                  let challenge = response.headerValue("WWW-Authenticate").flatMap({ MCPHTTPBearerChallenge.parse($0).first }),
                  challenge.error == "insufficient_scope"
            else {
                return response
            }
            guard stepUps < maxScopeStepUps,
                  let challengeScope = challenge.scope,
                  let scope = MCPOAuthScopeStepUp.union(previouslyGrantedScope: current.scope, challengeScope: challengeScope)
            else {
                throw MCPOAuthProtectedRequestError.scopeStepUpExhausted
            }
            stepUps += 1
            current = try await reauthorizeWithScope(scope)
        }
    }
}
