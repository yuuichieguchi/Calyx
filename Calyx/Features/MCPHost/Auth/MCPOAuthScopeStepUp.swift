//
//  MCPOAuthScopeStepUp.swift
//  Calyx
//
//  Scope for a step-up re-authorization: the challenge's scopes together
//  with the previously granted ones, so a re-authorization does not drop
//  permissions other operations still need.
//

import Foundation

enum MCPOAuthScopeStepUp {

    /// Union of two space-delimited scope strings (RFC 6749 section 3.3),
    /// previously granted values first, duplicates removed. Nil when both
    /// are nil or empty.
    static func union(previouslyGrantedScope: String?, challengeScope: String?) -> String? {
        var seen: Set<Substring> = []
        var merged: [Substring] = []
        for scope in [previouslyGrantedScope, challengeScope] {
            for value in (scope ?? "").split(separator: " ") where seen.insert(value).inserted {
                merged.append(value)
            }
        }
        return merged.isEmpty ? nil : merged.joined(separator: " ")
    }
}
