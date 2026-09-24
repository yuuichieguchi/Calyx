//
//  MCPAppLifecycle.swift
//  Calyx
//
//  Pure reducer for the per-view message order: nothing is sent before
//  `initialized`, tool-input goes once, exactly one of tool-result and
//  tool-cancelled goes once, and a view that was ever live gets
//  `ui/resource-teardown` before it is removed. Events that arrive before
//  `initialized` produce no effect; the caller holds them and replays them
//  after `clientInitialized`.
//

import Foundation

enum MCPAppLifecycle {
    struct State: Sendable, Equatable {
        var hasReceivedInitialized: Bool
        var hasSentToolInput: Bool
        /// tool-result or tool-cancelled went out.
        var outcomeSent: Bool
        var teardownRequested: Bool
        /// `initialized` arrived at least once since the last crash or reload.
        var wasLive: Bool

        static let initial = State(
            hasReceivedInitialized: false,
            hasSentToolInput: false,
            outcomeSent: false,
            teardownRequested: false,
            wasLive: false
        )
    }

    enum Event: Sendable, Equatable {
        case clientInitialized
        case toolInputReady
        case hostContextChanged
        case outcomeReady(Outcome)
        case viewRemovalRequested
        /// The WebContent process ended.
        case crash
        /// The user asked to reload the view.
        case reload
    }

    enum Outcome: Sendable, Equatable { case result, cancelled }

    enum Effect: Sendable, Equatable {
        case sendToolInput
        case sendHostContextChanged
        case sendOutcome(Outcome)
        case requestTeardown
        case removeView
        /// Load the view again; the order restarts at `clientInitialized`.
        case reloadView
    }

    static func reduce(_ state: State, _ event: Event) -> (State, [Effect]) {
        var next = state
        switch event {
        case .clientInitialized:
            next.hasReceivedInitialized = true
            next.wasLive = true
            return (next, [])

        case .toolInputReady:
            guard state.hasReceivedInitialized, !state.hasSentToolInput else { return (state, []) }
            next.hasSentToolInput = true
            return (next, [.sendToolInput])

        case .hostContextChanged:
            guard state.hasReceivedInitialized else { return (state, []) }
            return (state, [.sendHostContextChanged])

        case .outcomeReady(let outcome):
            guard state.hasReceivedInitialized, !state.outcomeSent else { return (state, []) }
            next.outcomeSent = true
            return (next, [.sendOutcome(outcome)])

        case .viewRemovalRequested:
            next.teardownRequested = true
            return (next, state.wasLive ? [.requestTeardown, .removeView] : [.removeView])

        case .crash:
            // A dead process cannot receive ui/resource-teardown.
            return (.initial, [])

        case .reload:
            return (.initial, [.reloadView])
        }
    }
}
