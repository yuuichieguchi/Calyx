//
//  MCPAppLifecycleTests.swift
//  CalyxTests
//
//  MCPAppLifecycle.reduce is a pure reducer (AgentStateResolver's style,
//  contract v2 §11.11) enforcing the per-view message ordering invariants
//  listed in §11.20: nothing sent before initialized, tool-input exactly
//  once before any outcome, exactly one of tool-result/tool-cancelled, and
//  a teardown request before removing a view that was ever live
//  (wasLive == true).
//
//  Queuing of events received before `initialized` is the caller's
//  responsibility per §11.11 ([choice]); the reducer itself still must
//  never emit an effect for toolInputReady/hostContextChanged while
//  hasReceivedInitialized is false, since that is the literal invariant
//  under test (§11.20 first bullet), and a caller-side queue cannot be
//  exercised through the pure reducer alone.
//

import XCTest
@testable import Calyx

final class MCPAppLifecycleTests: XCTestCase {

    private func initializedState() -> MCPAppLifecycle.State {
        let (state, _) = MCPAppLifecycle.reduce(MCPAppLifecycle.State(
            hasReceivedInitialized: false,
            hasSentToolInput: false,
            outcomeSent: false,
            teardownRequested: false,
            wasLive: false
        ), .clientInitialized)
        return state
    }

    // MARK: - Nothing emitted before initialized

    func test_toolInputReady_beforeInitialized_emitsNoEffects() {
        let state = MCPAppLifecycle.State(
            hasReceivedInitialized: false, hasSentToolInput: false,
            outcomeSent: false, teardownRequested: false, wasLive: false
        )
        let (nextState, effects) = MCPAppLifecycle.reduce(state, .toolInputReady)

        XCTAssertEqual(effects, [])
        XCTAssertFalse(nextState.hasSentToolInput)
    }

    func test_hostContextChanged_beforeInitialized_emitsNoEffects() {
        let state = MCPAppLifecycle.State(
            hasReceivedInitialized: false, hasSentToolInput: false,
            outcomeSent: false, teardownRequested: false, wasLive: false
        )
        let (_, effects) = MCPAppLifecycle.reduce(state, .hostContextChanged)
        XCTAssertEqual(effects, [])
    }

    // MARK: - clientInitialized marks the view live

    func test_clientInitialized_setsHasReceivedInitializedAndWasLive() {
        let state = initializedState()
        XCTAssertTrue(state.hasReceivedInitialized)
        XCTAssertTrue(state.wasLive)
    }

    // MARK: - tool-input exactly once, before any outcome

    func test_toolInputReady_afterInitialized_sendsToolInputExactlyOnce() {
        let (state1, effects1) = MCPAppLifecycle.reduce(initializedState(), .toolInputReady)
        XCTAssertEqual(effects1, [.sendToolInput])
        XCTAssertTrue(state1.hasSentToolInput)

        let (_, effects2) = MCPAppLifecycle.reduce(state1, .toolInputReady)
        XCTAssertEqual(effects2, [], "a second tool-input-ready event must not resend tool-input")
    }

    func test_toolInput_precedesOutcome_whenBothReadyAfterInit() {
        var state = initializedState()
        var effects: [MCPAppLifecycle.Effect]
        (state, effects) = MCPAppLifecycle.reduce(state, .toolInputReady)
        XCTAssertEqual(effects, [.sendToolInput])
        (state, effects) = MCPAppLifecycle.reduce(state, .outcomeReady(.result))
        XCTAssertEqual(effects, [.sendOutcome(.result)])
        XCTAssertTrue(state.outcomeSent)
    }

    // MARK: - outcome exactly once (result xor cancelled, second ignored)

    func test_secondOutcome_afterFirstSent_isIgnored() {
        var state = initializedState()
        var effects: [MCPAppLifecycle.Effect]
        (state, effects) = MCPAppLifecycle.reduce(state, .outcomeReady(.result))
        XCTAssertEqual(effects, [.sendOutcome(.result)])
        XCTAssertTrue(state.outcomeSent)

        (state, effects) = MCPAppLifecycle.reduce(state, .outcomeReady(.cancelled))
        XCTAssertEqual(effects, [], "a second outcome must never be sent once the first has gone out")
    }

    func test_cancelledOutcome_sentOnce_asAlternativeToResult() {
        let (state, effects) = MCPAppLifecycle.reduce(initializedState(), .outcomeReady(.cancelled))
        XCTAssertEqual(effects, [.sendOutcome(.cancelled)])
        XCTAssertTrue(state.outcomeSent)
    }

    // MARK: - Teardown before removal when the view was ever live

    func test_viewRemoval_wasLiveTrue_requestsTeardownBeforeRemove() {
        let state = initializedState()
        let (_, effects) = MCPAppLifecycle.reduce(state, .viewRemovalRequested)

        XCTAssertEqual(effects, [.requestTeardown, .removeView])
    }

    func test_viewRemoval_wasLiveFalse_removesWithoutTeardownRequest() {
        let state = MCPAppLifecycle.State(
            hasReceivedInitialized: false, hasSentToolInput: false,
            outcomeSent: false, teardownRequested: false, wasLive: false
        )
        let (_, effects) = MCPAppLifecycle.reduce(state, .viewRemovalRequested)

        XCTAssertEqual(effects, [.removeView])
    }

    func test_teardownRequested_isRecordedOnState() {
        let state = initializedState()
        let (nextState, _) = MCPAppLifecycle.reduce(state, .viewRemovalRequested)
        XCTAssertTrue(nextState.teardownRequested)
    }

    // MARK: - crash: WebContent process termination resets to initial state, no effects

    func test_crash_resetsStateToInitial_wasLiveFalse_noEffects() {
        var state = initializedState()
        (state, _) = MCPAppLifecycle.reduce(state, .toolInputReady)
        (state, _) = MCPAppLifecycle.reduce(state, .outcomeReady(.result))
        XCTAssertTrue(state.wasLive)

        let (afterCrash, effects) = MCPAppLifecycle.reduce(state, .crash)

        XCTAssertEqual(effects, [], "a dead process cannot receive ui/resource-teardown, so crash sends nothing")
        XCTAssertEqual(afterCrash, MCPAppLifecycle.State(
            hasReceivedInitialized: false, hasSentToolInput: false,
            outcomeSent: false, teardownRequested: false, wasLive: false
        ))
    }

    // MARK: - reload: resets to initial state, emits [.reloadView]

    func test_reload_resetsStateToInitial_emitsReloadView() {
        var state = initializedState()
        (state, _) = MCPAppLifecycle.reduce(state, .toolInputReady)
        (state, _) = MCPAppLifecycle.reduce(state, .outcomeReady(.cancelled))

        let (afterReload, effects) = MCPAppLifecycle.reduce(state, .reload)

        XCTAssertEqual(effects, [.reloadView])
        XCTAssertEqual(afterReload, MCPAppLifecycle.State(
            hasReceivedInitialized: false, hasSentToolInput: false,
            outcomeSent: false, teardownRequested: false, wasLive: false
        ))
    }

    func test_reload_thenClientInitializedAgain_replaysToolInputExactlyOnce() {
        // After reload's reset, the caller re-drives clientInitialized ->
        // toolInputReady -> outcomeReady itself (§11.11); the reducer's own
        // one-shot invariants (tool-input once, outcome once) still apply
        // to that fresh sequence.
        var state = initializedState()
        (state, _) = MCPAppLifecycle.reduce(state, .toolInputReady)
        (state, _) = MCPAppLifecycle.reduce(state, .reload)

        var effects: [MCPAppLifecycle.Effect]
        (state, effects) = MCPAppLifecycle.reduce(state, .clientInitialized)
        XCTAssertEqual(effects, [])
        (state, effects) = MCPAppLifecycle.reduce(state, .toolInputReady)
        XCTAssertEqual(effects, [.sendToolInput])
    }
}
