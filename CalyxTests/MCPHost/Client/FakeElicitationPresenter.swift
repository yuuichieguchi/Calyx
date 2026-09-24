//
//  FakeElicitationPresenter.swift
//  CalyxTests
//
//  Shared `MCPElicitationPresenting` test double (API contract section
//  3.2 / section 14). Records every elicitation routed to it -- one
//  `present(_:)` call per MRTR `inputRequests` entry whose
//  `method == "elicitation/create"`, or one call for a legacy
//  server-initiated `elicitation/create` -- and returns pre-scripted
//  responses in order. `dismiss(_:)` records the id it was asked to
//  dismiss, for the URL-mode `notifications/elicitation/complete`
//  correlation tests.
//
//  `MCPElicitationPresenting` is a `@MainActor` protocol (an actor
//  cannot conform to it, per section 3.2), so this double is a
//  `@MainActor final class ..., @unchecked Sendable`: every stored
//  property is only ever touched under `@MainActor` isolation.
//

import Foundation
@testable import Calyx

@MainActor
final class FakeElicitationPresenter: MCPElicitationPresenting, @unchecked Sendable {
    private(set) var calls: [MCPElicitationRequest] = []
    private(set) var dismissedIDs: [MCPElicitationID] = []
    private var scriptedResponses: [MCPElicitationResponse]

    init(scriptedResponses: [MCPElicitationResponse]) {
        self.scriptedResponses = scriptedResponses
    }

    func present(_ request: MCPElicitationRequest) async -> MCPElicitationResponse {
        calls.append(request)
        guard !scriptedResponses.isEmpty else { return .decline }
        return scriptedResponses.removeFirst()
    }

    func dismiss(_ id: MCPElicitationID) {
        dismissedIDs.append(id)
    }
}
