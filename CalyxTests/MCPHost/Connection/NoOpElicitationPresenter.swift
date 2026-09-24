//
//  NoOpElicitationPresenter.swift
//  CalyxTests
//
//  No-operation `MCPElicitationPresenting` double for Connection tests
//  that do not exercise the MRTR / legacy elicitation path and only
//  need a presenter to satisfy `MCPUpstreamConnection.init`. Always
//  declines, per API contract section 14.
//
//  `MCPElicitationPresenting` is a `@MainActor` protocol (an actor
//  cannot conform to it, per section 3.2), so this double is a
//  `@MainActor final class ..., @unchecked Sendable`: every stored
//  property is only ever touched under `@MainActor` isolation.
//

import Foundation
@testable import Calyx

@MainActor
final class NoOpElicitationPresenter: MCPElicitationPresenting, @unchecked Sendable {
    private(set) var presentCallCount = 0
    private(set) var dismissedIDs: [MCPElicitationID] = []

    func present(_ request: MCPElicitationRequest) async -> MCPElicitationResponse {
        presentCallCount += 1
        return .decline
    }

    func dismiss(_ id: MCPElicitationID) {
        dismissedIDs.append(id)
    }
}
