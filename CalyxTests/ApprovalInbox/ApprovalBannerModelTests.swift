//
//  ApprovalBannerModelTests.swift
//  CalyxTests
//
//  Covers ApprovalBannerModel: the app-wide view-model behind the
//  Cockpit approval banner, deciding which single pending
//  ApprovalRequest (if any) to show, and forwarding Allow/Deny/Always
//  Allow to ApprovalInboxStore.decide(id:_:) /
//  CockpitSettings.autoApproveEnabled. `AppDelegate` owns exactly one
//  instance app-wide (see ApprovalBannerModel.swift's own header) --
//  every pending request, regardless of which surface it targets or
//  whether it targets one at all, sits in the SAME queue.
//
//  Coverage:
//  - current is the OLDEST pending request in the app-wide queue,
//    regardless of which surface (or no surface at all) it targets
//  - allow(id:)/deny(id:) decide the id the caller explicitly passed
//    (the request actually rendered), never a re-read of `current` --
//    a stale id (no longer pending) is a safe no-op that never touches
//    whatever request `current` has since advanced to
//  - alwaysAllow(id:) turns on CockpitSettings.autoApproveEnabled,
//    decides the clicked id .allowed, AND drains every other pending
//    `.mcpTool`-sourced request app-wide in the same action, but NEVER a
//    queued `.agentHook`-sourced request on that same drain, even
//    targeting the same surface (source-scoped, see
//    test_alwaysAllow_mcpToolSource_doesNotDrainQueuedAgentHookRequest_onSameSurface).
//    For an `.agentHook`-sourced request, alwaysAllow(id:) instead
//    records PANE Always-Allow memory (surfaceID, kind, toolName) via
//    the injected `memory`, batch-allows only pending requests sharing
//    that EXACT tuple, and never touches CockpitSettings.autoApproveEnabled
//    at all
//  - answer(id:answers:)/chatAboutQuestion(id:) invoke the injected
//    `restoreTerminalFocus` closure with the decided request's own
//    `targetSurfaceID`, read BEFORE `store.decide` removes it;
//    restoreTerminalFocusAfterInput() forwards the target it is given
//
//  ApprovalBannerModel's initializer takes a `memory: AgentHookApprovalMemory`
//  parameter, defaulted to `.shared` (mirrors this codebase's
//  `= .shared`-defaulted seam convention, e.g.
//  `CalyxMCPServer.approvalInbox`/`agentRegistry`) -- every test below
//  that never mentions `.agentHook` continues to construct
//  `ApprovalBannerModel(store:)` unchanged and is unaffected; only the
//  tests exercising `.agentHook` inject an isolated
//  `AgentHookApprovalMemory()` instance explicitly, so no test leaks
//  Always-Allow memory into another via the shared singleton.
//

import XCTest
@testable import Calyx

@MainActor
final class ApprovalBannerModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(targetSurfaceID: UUID?, payload: String = "ls", createdAt: Date = Date()) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: targetSurfaceID, payload: payload, createdAt: createdAt)
    }

    /// An `.agentHook`-sourced request, the source variant
    /// `alwaysAllow(id:)` keys its memory-recording behavior off of.
    private func makeAgentHookRequest(
        targetSurfaceID: UUID?,
        kind: String = AgentEntry.claudeCodeKind,
        toolName: String = "Bash",
        createdAt: Date = Date(),
        offers: AgentHookOffers = .none
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID(),
            source: .agentHook(toolName: toolName, kind: kind, summary: "ls -la /tmp", offers: offers),
            targetSurfaceID: targetSurfaceID,
            payload: "{\"command\":\"ls -la /tmp\"}",
            createdAt: createdAt
        )
    }

    /// Compact JSON `Data` for an `AgentHookToolCall.decode(from:)`
    /// fixture -- mirrors AgentHookToolCallTests.swift's own `json(_:)`
    /// helper.
    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// Realistic `.agentHook`-sourced fixture for the `previewLine` tests
    /// below: routes through the REAL `AgentHookToolCall.decode(from:)`
    /// rather than hand-writing a summary string, mirroring exactly how
    /// `CalyxMCPServer` builds an `.agentHook` `ApprovalRequest` from a
    /// decoded `AgentHookToolCall` (`source: .agentHook(toolName:
    /// call.toolName, kind: kind, summary: call.summary)`).
    private func agentHookRequest(_ toolInput: [String: Any], toolName: String) throws -> ApprovalRequest {
        let call = try XCTUnwrap(AgentHookToolCall.decode(
            from: json(["tool_name": toolName, "tool_input": toolInput]), kind: AgentEntry.claudeCodeKind
        ))
        return ApprovalRequest(
            id: UUID(), source: .agentHook(toolName: call.toolName, kind: AgentEntry.claudeCodeKind, summary: call.summary, offers: .none),
            targetSurfaceID: nil, payload: call.payload, createdAt: Date()
        )
    }

    /// Bounded scheduler-yield loop, so a concurrently-spawned `Task`
    /// awaiting `store.awaitDecision` has every reasonable opportunity
    /// to actually reach its suspension point before the test proceeds
    /// to trigger a decision -- same pattern as
    /// ApprovalInboxStoreTests.yieldToScheduler / CommandLogStoreTests's.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    /// An `.agentQuestion`-sourced request: the source variant
    /// `answer(id:answers:)`/`chatAboutQuestion(id:)` operate on, and the
    /// one every allow-family action (`allow`/`deny`/`alwaysAllow`) must
    /// leave untouched.
    private func makeAgentQuestionRequest(
        targetSurfaceID: UUID?,
        kind: String = AgentEntry.claudeCodeKind,
        createdAt: Date = Date()
    ) -> ApprovalRequest {
        let toolInput: [String: Any] = ["questions": [["question": "Which shell?", "options": [["label": "zsh"], ["label": "bash"]]]]]
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [
                    AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil),
                    AgentQuestionPrompt.Option(label: "bash", description: nil, preview: nil),
                ],
                multiSelect: false
            )],
            originalToolInputJSON: try! JSONSerialization.data(withJSONObject: toolInput)
        )
        return ApprovalRequest(
            id: UUID(), source: .agentQuestion(kind: kind, prompt: prompt),
            targetSurfaceID: targetSurfaceID, payload: "", createdAt: createdAt
        )
    }

    /// Records every `UUID?` the injected `restoreTerminalFocus` closure
    /// was invoked with -- a plain reference-type box rather than a
    /// captured `var`, so it can be read after being handed to
    /// `ApprovalBannerModel`'s `@escaping` init parameter. The recorded
    /// target (not just a call count) is what distinguishes "read the
    /// request's own `targetSurfaceID` before deciding it" from an
    /// implementation that reads it too late, after `store.decide` has
    /// already removed the request.
    private final class RestoreFocusSpy {
        private(set) var targets: [UUID?] = []
        var callCount: Int { targets.count }
        func call(_ target: UUID?) { targets.append(target) }
    }

    // MARK: - current: app-wide queue, oldest-first

    func test_current_isOldestPendingRequest_acrossSurfaces() {
        let store = ApprovalInboxStore()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let older = makeRequest(targetSurfaceID: surfaceA, payload: "older", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeRequest(targetSurfaceID: surfaceB, payload: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(older)
        store.submit(newer)

        let model = ApprovalBannerModel(store: store)

        XCTAssertEqual(model.current?.id, older.id,
                       "current must be the oldest pending request in the app-wide queue, regardless of which surface it targets")
    }

    func test_current_emptyStore_isNil() {
        let store = ApprovalInboxStore()

        let model = ApprovalBannerModel(store: store)

        XCTAssertNil(model.current, "with nothing pending, current must be nil")
    }

    // MARK: - current: nil targetSurfaceID request is visible in the same app-wide queue

    func test_current_nilTargetSurface_isVisible() {
        let store = ApprovalInboxStore()
        let request = makeRequest(targetSurfaceID: nil)
        store.submit(request)

        let model = ApprovalBannerModel(store: store)

        XCTAssertEqual(model.current?.id, request.id,
                       "a window-agnostic (nil targetSurfaceID) request must be visible in the single, app-wide queue -- there is no per-window gating left")
    }

    // MARK: - allow / deny

    func test_allow_decidesAllowed_andBannerClears() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)

        let model = ApprovalBannerModel(store: store)

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.allow(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "allow(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "allow(id:) must resolve the in-flight awaitDecision with .allowed")
    }

    func test_deny_decidesDenied() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)

        let model = ApprovalBannerModel(store: store)

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.deny(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "deny(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")

        let result = await waiter.value
        XCTAssertEqual(result, .denied(.userRejected), "deny(id:) must resolve the in-flight awaitDecision with .denied(.userRejected)")
    }

    /// The id threaded through must be the one the caller actually
    /// rendered, never a silent re-read of `current` -- proven by
    /// resolving A out from under the model via a raw `store.decide`
    /// call (simulating some other path deciding it first), then
    /// clicking Deny with A's now-stale id and confirming B (which
    /// `current` has since advanced to) is completely untouched.
    func test_deny_staleID_afterCurrentAdvanced_isNoOp_doesNotAffectNewCurrent() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let requestA = makeRequest(targetSurfaceID: surfaceID, payload: "A", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let requestB = makeRequest(targetSurfaceID: surfaceID, payload: "B", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(requestA)
        store.submit(requestB)

        let model = ApprovalBannerModel(store: store)
        XCTAssertEqual(model.current?.id, requestA.id, "precondition: A is the oldest, currently-displayed request")

        let waiterB = Task { @MainActor in
            await store.awaitDecision(id: requestB.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        // Some other path resolves A while the view still holds A's id
        // from its last render.
        store.decide(id: requestA.id, .allowed)
        XCTAssertEqual(model.current?.id, requestB.id, "current must have advanced to B once A left pending")

        model.deny(id: requestA.id)

        XCTAssertEqual(store.pending.map(\.id), [requestB.id],
                       "a stale deny(id: A) must not touch B, which is still pending")

        store.decide(id: requestB.id, .denied(.userRejected))
        let result = await waiterB.value
        XCTAssertEqual(result, .denied(.userRejected),
                       "B must remain independently decidable after the stale deny(id: A) no-op")
    }

    // MARK: - alwaysAllow

    func test_alwaysAllow_enablesAutoApproveSetting_andAllows() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllow"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)

        let model = ApprovalBannerModel(store: store)

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.alwaysAllow(id: request.id)

        XCTAssertTrue(CockpitSettings.autoApproveEnabled, "alwaysAllow(id:) must turn on the auto-approve setting")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "alwaysAllow(id:) must also resolve the clicked request as allowed")
    }

    /// alwaysAllow(id:) must drain the WHOLE app-wide backlog, not just
    /// the one request that was clicked.
    func test_alwaysAllow_drainsAllVisiblePendingRequests() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowDrain"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let requestA = makeRequest(targetSurfaceID: surfaceID, payload: "A")
        let requestB = makeRequest(targetSurfaceID: surfaceID, payload: "B")
        let requestC = makeRequest(targetSurfaceID: surfaceID, payload: "C")
        store.submit(requestA)
        store.submit(requestB)
        store.submit(requestC)

        let model = ApprovalBannerModel(store: store)

        let waiterA = Task { @MainActor in await store.awaitDecision(id: requestA.id, timeoutMs: 5_000) }
        let waiterB = Task { @MainActor in await store.awaitDecision(id: requestB.id, timeoutMs: 5_000) }
        let waiterC = Task { @MainActor in await store.awaitDecision(id: requestC.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        let notifyCountBeforeDrain = store._testNotifyCount

        model.alwaysAllow(id: requestA.id)

        XCTAssertTrue(store.pending.isEmpty,
                      "alwaysAllow(id:) must drain every pending request in the app-wide queue, not just the clicked one")
        XCTAssertEqual(store._testNotifyCount - notifyCountBeforeDrain, 1,
                       "draining 3 requests in one alwaysAllow(id:) action must post exactly one change " +
                       "notification, not one per drained request (which would trigger N full-window " +
                       "rebuilds per open window)")

        let resultA = await waiterA.value
        let resultB = await waiterB.value
        let resultC = await waiterC.value
        XCTAssertEqual(resultA, .allowed)
        XCTAssertEqual(resultB, .allowed, "the backlog drain must resolve B allowed even though only A was clicked")
        XCTAssertEqual(resultC, .allowed, "the backlog drain must resolve C allowed even though only A was clicked")
    }

    /// The `.mcpTool` drain is scoped app-wide, not per-surface: a
    /// pending `.mcpTool` request targeting a DIFFERENT surface (and one
    /// with no target at all) must both be drained too, since there is
    /// exactly one queue for the whole app now. Only an `.agentHook`
    /// request is left out of this drain -- that's the SOURCE-scoped
    /// exclusion `test_alwaysAllow_mcpToolSource_doesNotDrainQueuedAgentHookRequest_onSameSurface`
    /// below covers, not a per-window one.
    func test_alwaysAllow_mcpTool_drainsEveryOtherMcpToolRequest_regardlessOfSurface() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowDrainsAcrossSurfaces"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let clickedSurfaceID = UUID()
        let otherSurfaceID = UUID()
        let clickedRequest = makeRequest(targetSurfaceID: clickedSurfaceID, payload: "clicked")
        let otherSurfaceRequest = makeRequest(targetSurfaceID: otherSurfaceID, payload: "other-surface")
        let nilTargetRequest = makeRequest(targetSurfaceID: nil, payload: "nil-target")
        store.submit(clickedRequest)
        store.submit(otherSurfaceRequest)
        store.submit(nilTargetRequest)

        let model = ApprovalBannerModel(store: store)

        model.alwaysAllow(id: clickedRequest.id)

        XCTAssertTrue(store.pending.isEmpty,
                      "alwaysAllow(id:) on an .mcpTool request must drain every other pending .mcpTool request app-wide, regardless of which surface (or no surface at all) it targets")
    }

    /// The `.mcpTool` branch of `alwaysAllow(id:)` drains every OTHER
    /// pending `.mcpTool` request app-wide -- so a queued `.agentHook`
    /// request targeting the SAME
    /// surface must NOT be swept up in an mcpTool click's drain. Only
    /// that agentHook request's own (separate) always-allow action may
    /// ever decide it -- see the `.agentHook` branch below, which records
    /// its own pane/cross memory instead of touching the global setting.
    func test_alwaysAllow_mcpToolSource_doesNotDrainQueuedAgentHookRequest_onSameSurface() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowMcpToolDoesNotDrainAgentHook"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let mcpToolRequest = makeRequest(
            targetSurfaceID: surfaceID, payload: "pane_run", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let agentHookRequest = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        store.submit(mcpToolRequest)
        store.submit(agentHookRequest)

        let model = ApprovalBannerModel(store: store, memory: memory)

        let waiterMcp = Task { @MainActor in await store.awaitDecision(id: mcpToolRequest.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: mcpToolRequest.id)

        XCTAssertTrue(CockpitSettings.autoApproveEnabled,
                      "the mcpTool branch must still flip global auto-approve, unchanged")
        XCTAssertEqual(store.pending.map(\.id), [agentHookRequest.id],
                       "alwaysAllow(id:) on an .mcpTool request must decide only that request, leaving a " +
                       "queued .agentHook request on the SAME surface pending -- it has its own, separate " +
                       "always-allow action")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "the mcpTool branch must never record agent-hook Always-Allow memory as a side effect")

        let resultMcp = await waiterMcp.value
        XCTAssertEqual(resultMcp, .allowed)

        // Drain the still-pending agentHook request so this test doesn't
        // leak a suspended awaitDecision waiter.
        store.decide(id: agentHookRequest.id, .allowed)
    }

    // MARK: - alwaysAllow(id:) for an .agentHook-sourced request

    /// Distinguishes the NEW agentHook branch from the existing mcpTool
    /// branch above: instead of flipping the global auto-approve
    /// setting, it must record PANE memory scoped to the clicked
    /// request's own (targetSurfaceID, kind, toolName).
    func test_alwaysAllow_agentHookSource_recordsPaneMemory_neverTouchesGlobalAutoApprove() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowAgentHookPaneMemory"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let foreignSurfaceID = UUID()
        let clicked = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Bash")
        store.submit(clicked)

        let model = ApprovalBannerModel(store: store, memory: memory)

        let waiter = Task { @MainActor in await store.awaitDecision(id: clicked.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: clicked.id)

        XCTAssertTrue(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                     "alwaysAllow(id:) for an agentHook request must record PANE memory for the clicked " +
                     "request's own (targetSurfaceID, kind, toolName)")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: foreignSurfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "the recorded memory must be scoped to the clicked request's own surface, not every surface")
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "an agentHook alwaysAllow(id:) must NOT flip the global auto-approve toggle -- it only " +
                       "records scoped Always-Allow memory")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "alwaysAllow(id:) must still resolve the clicked request as allowed")
    }

    /// The batch-drain half of the same behavior: only a pending request
    /// sharing the clicked request's EXACT (targetSurfaceID, kind,
    /// toolName) is drained -- a different tool on the SAME pane, and
    /// the SAME tool on a DIFFERENT pane, are each independently left
    /// pending.
    func test_alwaysAllow_agentHookSource_drainsOnlySamePaneSameToolPending() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowAgentHookDrain"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let foreignSurfaceID = UUID()

        let clicked = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let samePaneSameTool = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let samePaneDifferentTool = makeAgentHookRequest(
            targetSurfaceID: surfaceID, toolName: "Write", createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let differentPaneSameTool = makeAgentHookRequest(
            targetSurfaceID: foreignSurfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_300)
        )
        store.submit(clicked)
        store.submit(samePaneSameTool)
        store.submit(samePaneDifferentTool)
        store.submit(differentPaneSameTool)

        let model = ApprovalBannerModel(store: store, memory: memory)

        let waiterClicked = Task { @MainActor in await store.awaitDecision(id: clicked.id, timeoutMs: 5_000) }
        let waiterSamePane = Task { @MainActor in await store.awaitDecision(id: samePaneSameTool.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: clicked.id)

        XCTAssertEqual(Set(store.pending.map(\.id)), Set([samePaneDifferentTool.id, differentPaneSameTool.id]),
                       "alwaysAllow(id:) must drain only pending requests sharing the clicked request's exact " +
                       "(targetSurfaceID, kind, toolName) -- a different tool on the same pane, and the same " +
                       "tool on a different pane, must both stay pending")

        let resultClicked = await waiterClicked.value
        let resultSamePane = await waiterSamePane.value
        XCTAssertEqual(resultClicked, .allowed)
        XCTAssertEqual(resultSamePane, .allowed, "the same-pane-same-tool backlog match must also be drained allowed")
    }

    // MARK: - Queue navigation (prev/next cursor)
    //
    // A stored, private `selectedRequestID: UUID?` cursor lets the
    // app-wide queue step through every pending request, instead of
    // only ever showing the oldest one. `current` returns the selected
    // request while it's still pending, else falls back to the oldest
    // pending request (mirrors today's behavior when nothing has been
    // explicitly selected yet, or the selection has been resolved out
    // from under it). `positionInfo` is the 1-based (index, count) of
    // `current` within the app-wide pending queue, nil exactly when
    // `current` is nil. Deciding the DISPLAYED
    // request (the id `current` actually returned at the time of the
    // call) via allow(id:)/deny(id:)/alwaysAllow(id:) advances the
    // cursor to its successor in that pre-removal visible queue
    // (predecessor if it was last, nil if it was the only one visible)
    // -- so the banner keeps stepping forward through the backlog
    // instead of always snapping back to the oldest. A stale id -- one that is
    // NOT the currently-displayed request, e.g. already resolved by some
    // other path -- must never move the cursor; and a brand-new arrival
    // submitted after a selection has been made must never move that
    // existing selection either.

    func test_selectNext_advancesCurrentAndPositionInfo() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)

        XCTAssertEqual(model.current?.id, first.id, "precondition: current starts at the oldest pending request")
        XCTAssertEqual(model.positionInfo?.index, 1, "positionInfo's index is 1-based")
        XCTAssertEqual(model.positionInfo?.count, 3, "positionInfo's count is the size of the app-wide pending queue")

        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "selectNext() must advance current to the next request in the visible queue")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 3)

        model.selectNext()
        XCTAssertEqual(model.current?.id, third.id, "a second selectNext() must advance current to the newest request")
        XCTAssertEqual(model.positionInfo?.index, 3)
        XCTAssertEqual(model.positionInfo?.count, 3)
    }

    func test_navigation_clampsAtQueueEnds() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store)

        XCTAssertFalse(model.canSelectPrevious, "at the oldest (first) request, there is nothing before it to select")
        model.selectPrevious()
        XCTAssertEqual(model.current?.id, first.id, "selectPrevious() at the start of the queue must be a no-op")

        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: navigated to the newest request")
        XCTAssertFalse(model.canSelectNext, "at the newest (last) request, there is nothing after it to select")
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "selectNext() at the end of the queue must be a no-op")
    }

    func test_navigation_includesRequestsAcrossDifferentSurfaces() {
        let store = ApprovalInboxStore()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let t1 = makeRequest(targetSurfaceID: surfaceA, payload: "t1", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let t2 = makeRequest(targetSurfaceID: surfaceB, payload: "t2", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let t3 = makeRequest(targetSurfaceID: surfaceA, payload: "t3", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(t1)
        store.submit(t2)
        store.submit(t3)

        let model = ApprovalBannerModel(store: store)

        XCTAssertEqual(model.positionInfo?.count, 3,
                       "positionInfo's count must reflect every pending request app-wide, regardless of which surface it targets")

        model.selectNext()
        XCTAssertEqual(model.current?.id, t2.id,
                       "selectNext() must step through requests targeting different surfaces in the SAME app-wide queue")
    }

    func test_current_fallsBackToOldestVisible_whenSelectionResolvedExternally() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)

        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.current?.id, third.id, "precondition: navigated to the newest request")

        store.decide(id: third.id, .allowed)

        XCTAssertEqual(model.current?.id, first.id,
                       "once the selected request is resolved externally (bypassing the model), current must fall back to the oldest still-visible request")
        XCTAssertEqual(model.positionInfo?.index, 1)
        XCTAssertEqual(model.positionInfo?.count, 2)
    }

    func test_allow_onDisplayedRequest_advancesToSuccessor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: second.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.allow(id: second.id)

        XCTAssertEqual(model.current?.id, third.id,
                       "allow(id:) on the currently-displayed request must advance the cursor to its successor in the visible queue")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 2)

        let result = await waiter.value
        XCTAssertEqual(result, .allowed)
    }

    func test_deny_onLastDisplayedRequest_fallsBackToPredecessor() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.current?.id, third.id, "precondition: navigated to the last (newest) displayed request")

        model.deny(id: third.id)

        XCTAssertEqual(model.current?.id, second.id,
                       "deny(id:) on the last displayed request must fall back to its predecessor in the visible queue, since there is no successor")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 2)
    }

    /// Mirrors the pre-existing stale-id contract above, but for the
    /// NEW cursor: once the SELECTED request has been resolved out from
    /// under the model by some other path, `current` has already fallen
    /// back to the oldest visible request -- a subsequent `allow(id:)`
    /// call using the (now stale) selected id must not move the cursor
    /// again, and must leave every still-pending request untouched.
    func test_allow_withStaleID_doesNotMoveCursor() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        // Some other path resolves the selected request while the model
        // still holds it as `selectedRequestID`.
        store.decide(id: second.id, .allowed)
        XCTAssertEqual(model.current?.id, first.id,
                       "precondition: current has already fallen back to the oldest visible request")

        model.allow(id: second.id)

        XCTAssertEqual(model.current?.id, first.id,
                       "a stale allow(id:) for a request that is no longer the displayed one must not move the cursor")
        XCTAssertEqual(store.pending.map(\.id), [first.id, third.id],
                       "the stale allow(id:) call must not touch any request that is still pending")
    }

    /// Same successor-advance contract as `allow(id:)`/`deny(id:)` above,
    /// exercised through the `.agentHook` branch of `alwaysAllow(id:)`
    /// instead. The two requests deliberately use DIFFERENT `toolName`s
    /// so the pane-scoped memory drain (see `alwaysAllow(id:)`'s own doc
    /// comment) takes only the clicked one, keeping this test isolated to
    /// the cursor-advance behavior rather than the drain's own matching
    /// rules (already covered elsewhere).
    func test_alwaysAllow_agentHook_onDisplayedRequest_advancesToSuccessor() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.navigationAlwaysAllowAgentHook"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let first = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "Write", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store, memory: memory)
        XCTAssertEqual(model.current?.id, first.id, "precondition: current defaults to the oldest (first) request")

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: first.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.alwaysAllow(id: first.id)

        XCTAssertEqual(store.pending.map(\.id), [second.id],
                       "precondition: the different-toolName request must be left pending by the pane-scoped drain")
        XCTAssertEqual(model.current?.id, second.id,
                       "alwaysAllow(id:) on the displayed request must advance the cursor to its successor, same as allow(id:)/deny(id:)")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed)
    }

    /// Bug reproducer: `advanceCursor(pastDisplayed:)` picks the
    /// immediate visible neighbor (index + 1, computed from the
    /// PRE-removal `visibleRequests`) as the new cursor before the drain
    /// actually runs -- but the `.agentHook` branch's pane-scoped drain
    /// (same surface + kind + toolName) can sweep that very neighbor away
    /// in the SAME call. Here, clicking Always-Allow on B (tool "bravo")
    /// drains both B and C (C shares B's toolName), so the neighbor
    /// `advanceCursor` picked (C) never survives. Once C is gone,
    /// `current`'s `selectedRequestID` lookup misses and falls all the
    /// way back to the OLDEST visible request (A) -- the banner snaps
    /// backward -- instead of stepping to the nearest FORWARD survivor,
    /// D, which is what the forward-triage contract actually promises.
    func test_alwaysAllow_agentHook_drainSweepsSuccessor_cursorLandsOnForwardSurvivor() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.drainSweepsSuccessor"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let a = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "alpha", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let b = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "bravo", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let c = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "bravo", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        let d = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "delta", createdAt: Date(timeIntervalSince1970: 1_700_000_300))
        store.submit(a)
        store.submit(b)
        store.submit(c)
        store.submit(d)

        let model = ApprovalBannerModel(store: store, memory: memory)

        model.selectNext()
        XCTAssertEqual(model.current?.id, b.id, "precondition: current is the displayed (2nd) request, B")

        let waiterB = Task { @MainActor in await store.awaitDecision(id: b.id, timeoutMs: 5_000) }
        let waiterC = Task { @MainActor in await store.awaitDecision(id: c.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: b.id)

        XCTAssertEqual(Set(store.pending.map(\.id)), Set([a.id, d.id]),
                       "precondition: the pane-scoped drain must decide both B and C (same surface+kind+tool " +
                       "'bravo'), leaving only A and D pending")

        XCTAssertEqual(model.current?.id, d.id,
                       "alwaysAllow(id:) must advance the cursor to the nearest FORWARD survivor (D) once its " +
                       "immediate successor (C) is itself swept up by the very same drain -- not fall back to " +
                       "the oldest visible request (A)")
        XCTAssertEqual(model.positionInfo?.index, 2, "D is now the 2nd (newest) of the 2 remaining visible requests")
        XCTAssertEqual(model.positionInfo?.count, 2)

        let resultB = await waiterB.value
        let resultC = await waiterC.value
        XCTAssertEqual(resultB, .allowed)
        XCTAssertEqual(resultC, .allowed)
    }

    /// Same underlying bug as the reproducer above, but here the
    /// drain sweeps the cursor's clicked request (C) AND its immediate
    /// successor (D) both, leaving NO forward survivor at all. The
    /// correct fallback in that case is the nearest BACKWARD survivor
    /// (B), not simply the oldest visible request (A) -- those two only
    /// coincide when the cursor itself was already at the oldest
    /// surviving position, which is NOT the case here. Distinct tool
    /// names (alpha/bravo/charlie/charlie) keep B out of the drain's own
    /// match (only same-toolName "charlie" requests, C and D, are
    /// swept), so B survives purely as the nearest predecessor, never as
    /// a side effect of the drain's own filtering. This is a second bug
    /// reproducer, not merely a pinning test: today's code also lands on
    /// A here (stale cursor -> oldest fallback), which is the wrong
    /// answer once a correct nearest-survivor fallback is implemented.
    func test_alwaysAllow_agentHook_drainSweepsAllForward_cursorFallsBackToNearestPredecessor() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.drainSweepsAllForward"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let a = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "alpha", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let b = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "bravo", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let c = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "charlie", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        let d = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "charlie", createdAt: Date(timeIntervalSince1970: 1_700_000_300))
        store.submit(a)
        store.submit(b)
        store.submit(c)
        store.submit(d)

        let model = ApprovalBannerModel(store: store, memory: memory)

        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.current?.id, c.id, "precondition: current is the displayed (3rd) request, C")

        let waiterC = Task { @MainActor in await store.awaitDecision(id: c.id, timeoutMs: 5_000) }
        let waiterD = Task { @MainActor in await store.awaitDecision(id: d.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllow(id: c.id)

        XCTAssertEqual(Set(store.pending.map(\.id)), Set([a.id, b.id]),
                       "precondition: the pane-scoped drain must decide both C and D (same surface+kind+tool " +
                       "'charlie'), leaving only A and B pending")

        XCTAssertEqual(model.current?.id, b.id,
                       "alwaysAllow(id:) must fall back to the nearest BACKWARD survivor (B) once BOTH the " +
                       "clicked request (C) and its immediate successor (D) are swept by the drain, leaving no " +
                       "forward survivor at all -- not fall back to the oldest visible request (A), which is " +
                       "not the correct predecessor")
        XCTAssertEqual(model.positionInfo?.index, 2, "B is now the 2nd (newest) of the 2 remaining visible requests")
        XCTAssertEqual(model.positionInfo?.count, 2)

        let resultC = await waiterC.value
        let resultD = await waiterD.value
        XCTAssertEqual(resultC, .allowed)
        XCTAssertEqual(resultD, .allowed)
    }

    func test_newArrival_neverMovesSelection() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store)
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the newest (second) request")

        let newer = makeRequest(targetSurfaceID: surfaceID, payload: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(newer)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival submitted with a NEWER createdAt (appended after the selection) must never move an existing selection")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 3)

        let older = makeRequest(targetSurfaceID: surfaceID, payload: "older", createdAt: Date(timeIntervalSince1970: 1_699_999_900))
        store.submit(older)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival submitted with an OLDER createdAt (inserted at the head of the queue) must also never move an existing selection")
        XCTAssertEqual(model.positionInfo?.index, 3)
        XCTAssertEqual(model.positionInfo?.count, 4)
    }

    // MARK: - previewLine (Queue preview menu)
    //
    // ApprovalRequest.previewLine is "\(displayToolName): \(compactTarget)",
    // where compactTarget takes displayPayload through two steps: (1)
    // collapse every run of whitespace (including newlines and tabs) into
    // a single space, (2) trim leading/trailing whitespace. Its length is
    // deliberately not capped by a character count: the finished menu row
    // is bounded in points, and elided in its middle, by
    // ApprovalBannerView.fittedToMenuWidth(_:). An empty compactTarget
    // after steps (1)-(2) omits the trailing colon entirely, rendering
    // displayToolName alone. RAW, unescaped -- same caveat as
    // displayToolName/displayPayload themselves (ControlCharacterDisplay
    // escaping is the view layer's job, applied later, not here).

    func test_previewLine_agentHookBash_combinesDisplayToolNameAndCommand() throws {
        let request = try agentHookRequest(["command": "npm test"], toolName: "Bash")

        XCTAssertEqual(request.previewLine, "Claude Code · Bash: npm test",
                       "previewLine must combine displayToolName and the compacted target with a colon separator")
    }

    func test_previewLine_agentHookEdit_usesFilePathAsTarget() throws {
        let request = try agentHookRequest(["file_path": "/Users/dev/project/Sources/App.swift"], toolName: "Edit")

        XCTAssertEqual(request.previewLine, "Claude Code · Edit: /Users/dev/project/Sources/App.swift")
    }

    func test_previewLine_agentHookWrite_usesFilePathAsTarget() throws {
        let request = try agentHookRequest(["file_path": "/Users/dev/project/README.md"], toolName: "Write")

        XCTAssertEqual(request.previewLine, "Claude Code · Write: /Users/dev/project/README.md")
    }

    func test_previewLine_agentHookNotebookEdit_usesNotebookPathAsTarget() throws {
        let request = try agentHookRequest(["notebook_path": "/Users/dev/repo/notebook.ipynb"], toolName: "NotebookEdit")

        XCTAssertEqual(request.previewLine, "Claude Code · NotebookEdit: /Users/dev/repo/notebook.ipynb",
                       "NotebookEdit's target must come from tool_input.notebook_path, its own distinct key, never file_path")
    }

    func test_previewLine_agentHookWebFetch_usesUrlAsTarget() throws {
        let request = try agentHookRequest(["url": "https://example.com/docs"], toolName: "WebFetch")

        XCTAssertEqual(request.previewLine, "Claude Code · WebFetch: https://example.com/docs")
    }

    func test_previewLine_mcpToolSource_usesPayloadAsTarget() {
        let request = makeRequest(targetSurfaceID: nil, payload: "ls -la /tmp")

        XCTAssertEqual(request.previewLine, "pane_run: ls -la /tmp")
    }

    func test_previewLine_collapsesNewlinesAndTabsToSingleSpaces() {
        let request = makeRequest(targetSurfaceID: nil, payload: "line one\n\nline   two\t\tend")

        XCTAssertEqual(request.previewLine, "pane_run: line one line two end",
                       "every run of whitespace, including newlines and tabs, must collapse to exactly one space")
    }

    func test_previewLine_longTarget_notTruncatedByCharacterCount() {
        let target = String(repeating: "a", count: 400)
        let request = makeRequest(targetSurfaceID: nil, payload: target)

        XCTAssertEqual(request.previewLine, "pane_run: " + target,
                       "previewLine must leave its target's length alone: how long a menu row may be is bounded in points by ApprovalBannerView.fittedToMenuWidth(_:), not by a character count here")
    }

    func test_previewLine_longTarget_carriesNoEllipsis() {
        let target = String(repeating: "a", count: 400)
        let request = makeRequest(targetSurfaceID: nil, payload: target)

        XCTAssertFalse(request.previewLine.contains("…"),
                       "previewLine must not append an ellipsis of its own: the view elides the row's MIDDLE, and a trailing ellipsis here would be what survives that as the row's tail")
    }

    func test_previewLine_emptyTarget_omitsTrailingColon() {
        let request = makeRequest(targetSurfaceID: nil, payload: "   \n\t  ")

        XCTAssertEqual(request.previewLine, "pane_run",
                       "a payload that collapses to an empty compact target must render as displayToolName alone, with no trailing colon")
    }

    // MARK: - queueEntries (Queue preview menu)
    //
    // ApprovalBannerModel.queueEntries lists every pending request
    // app-wide, oldest-first, as a QueueEntry(id, 1-based position,
    // previewLine, isCurrent) -- the data the banner's queue menu
    // renders one row per pending request from.

    func test_queueEntries_oldestFirst_onebasedPositions_isCurrentOnlyOnCurrentPage() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        let entries = model.queueEntries

        XCTAssertEqual(entries.map(\.id), [first.id, second.id, third.id],
                       "queueEntries must list every visible request oldest-first, same order as visibleRequests")
        XCTAssertEqual(entries.map(\.position), [1, 2, 3], "position must be a 1-based index into that same order")
        XCTAssertEqual(entries.map(\.isCurrent), [false, true, false],
                       "isCurrent must be true only for the entry matching current's own id")
        XCTAssertEqual(entries.map(\.previewLine), ["pane_run: first", "pane_run: second", "pane_run: third"],
                       "each entry's previewLine must be its own request's previewLine")
    }

    func test_queueEntries_includesRequestsAcrossDifferentSurfaces() {
        let store = ApprovalInboxStore()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let t1 = makeRequest(targetSurfaceID: surfaceA, payload: "t1", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let t2 = makeRequest(targetSurfaceID: surfaceB, payload: "t2", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let t3 = makeRequest(targetSurfaceID: surfaceA, payload: "t3", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(t1)
        store.submit(t2)
        store.submit(t3)

        let model = ApprovalBannerModel(store: store)

        let entries = model.queueEntries

        XCTAssertEqual(entries.map(\.id), [t1.id, t2.id, t3.id],
                       "queueEntries must list every pending request app-wide, regardless of which surface it targets")
        XCTAssertEqual(entries.map(\.position), [1, 2, 3], "position is a 1-based index over the whole app-wide queue")
    }

    func test_queueEntries_emptyStore_isEmpty() {
        let store = ApprovalInboxStore()
        let model = ApprovalBannerModel(store: store)

        XCTAssertEqual(model.queueEntries, [], "queueEntries must be empty when nothing is pending")
    }

    /// The selected request is resolved through the store directly, not
    /// through model.allow(id:)/deny(id:): those advance the cursor onto
    /// a surviving neighbor (see advanceCursor(pastDisplayed:excluding:)),
    /// which is the opposite of the stale cursor this pins -- one still
    /// pointing at a request that has left visibleRequests, with nothing
    /// having reassigned it.
    func test_queueEntries_withStaleCursor_marksOldestVisibleEntryCurrent() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        model.select(id: second.id)
        XCTAssertEqual(model.current?.id, second.id, "precondition: the cursor points at the middle request")

        store.decide(id: second.id, .allowed)

        let entries = model.queueEntries

        XCTAssertEqual(entries.map(\.id), [first.id, third.id],
                       "precondition: the selected request has left visibleRequests, leaving the cursor stale")
        XCTAssertEqual(entries.map(\.isCurrent), [true, false],
                       "a stale cursor must mark the OLDEST visible entry current, exactly where current itself falls back to -- never leave every entry unmarked")
        XCTAssertEqual(model.current?.id, first.id,
                       "queueEntries and current must resolve the same stale cursor to the same request")
    }

    // MARK: - select(id:) (Queue preview menu jump)
    //
    // select(id:) is the queue menu's row-click action: jump straight to a
    // chosen request instead of stepping one at a time via selectNext()/
    // selectPrevious(). Same pending-membership contract as those two --
    // an id outside the app-wide pending queue (never submitted, or
    // already decided) is a no-op.
    // Unlike those two, a select that actually moves the cursor posts
    // .calyxApprovalInboxChanged itself, since an NSMenuItem's action runs
    // outside the rendered view hierarchy (see select(id:)'s own doc
    // comment in ApprovalBannerModel.swift).

    func test_select_movesCurrentAndPositionInfoToTheChosenRequest() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        XCTAssertEqual(model.current?.id, first.id, "precondition: current starts at the oldest pending request")

        model.select(id: third.id)

        XCTAssertEqual(model.current?.id, third.id, "select(id:) must move current directly to the chosen request")
        XCTAssertEqual(model.positionInfo?.index, 3, "positionInfo must follow the newly selected request")
        XCTAssertEqual(model.positionInfo?.count, 3)
    }

    /// A wrong implementation that unconditionally assigns the cursor
    /// (skipping the visibleRequests membership check) would still make a
    /// bogus id LOOK like a no-op here, since `current`'s own fallback for
    /// an unresolvable selectedRequestID lands on the oldest visible
    /// request anyway -- so this starts from an explicit prior selection
    /// (second, not the oldest) to actually distinguish "stayed at second"
    /// from "silently fell back to first".
    func test_select_withIDNotInVisibleRequests_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store)
        model.select(id: second.id)
        XCTAssertEqual(model.current?.id, second.id, "precondition: current follows an explicit select(id:) to the second request")

        model.select(id: UUID())

        XCTAssertEqual(model.current?.id, second.id,
                       "select(id:) with an id absent from visibleRequests must be a no-op, leaving the prior explicit selection at second untouched")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 2)
    }

    /// A request targeting a DIFFERENT surface than whatever is
    /// currently selected is still a member of the single, app-wide
    /// queue -- select(id:) must move to it, not treat it as foreign.
    func test_select_withRequestOnADifferentSurface_movesCurrent() {
        let store = ApprovalInboxStore()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let first = makeRequest(targetSurfaceID: surfaceA, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceA, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let onOtherSurface = makeRequest(targetSurfaceID: surfaceB, payload: "other-surface", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(onOtherSurface)

        let model = ApprovalBannerModel(store: store)
        model.select(id: second.id)
        XCTAssertEqual(model.current?.id, second.id, "precondition: current follows an explicit select(id:) to the second request")

        model.select(id: onOtherSurface.id)

        XCTAssertEqual(model.current?.id, onOtherSurface.id,
                       "select(id:) must move to a request targeting a DIFFERENT surface -- there is one app-wide queue, no per-window membership check")
    }

    func test_select_thenNewArrival_neverMovesSelection() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store)
        model.select(id: second.id)
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the explicitly selected (second) request")

        let newer = makeRequest(targetSurfaceID: surfaceID, payload: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(newer)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival submitted with a NEWER createdAt after select(id:) must never move that existing selection")
        XCTAssertEqual(model.positionInfo?.index, 2)
        XCTAssertEqual(model.positionInfo?.count, 3)

        let older = makeRequest(targetSurfaceID: surfaceID, payload: "older", createdAt: Date(timeIntervalSince1970: 1_699_999_900))
        store.submit(older)

        XCTAssertEqual(model.current?.id, second.id,
                       "a new arrival with an OLDER createdAt, inserted at the head of the queue, must also never move the select(id:) selection")
        XCTAssertEqual(model.positionInfo?.index, 3)
        XCTAssertEqual(model.positionInfo?.count, 4)
    }

    // MARK: - AccessibilityID coverage for queue navigation (spec-level only)
    //
    // SwiftUI Menu rendering itself is not unit-testable (no production
    // view code exercised here) -- this only pins that these identifiers
    // exist, are distinct from each other and from the pre-existing
    // ApprovalBanner identifiers, and follow the same
    // "calyx.approvalBanner.*" prefix convention as
    // container/allowButton/optionsMenu/payload above. Deny/Always Allow/
    // Chat about this/Back/Add notes carry no identifier of their own --
    // they are `optionsMenu` rows looked up by title, not by identifier
    // (see AccessibilityID.ApprovalBanner's own doc comment).

    func test_accessibilityID_approvalBanner_optionsMenuAndPayloadExpandedIdentifiers_existAndAreDistinct() {
        XCTAssertEqual(AccessibilityID.ApprovalBanner.optionsMenu, "calyx.approvalBanner.optionsMenu")
        XCTAssertEqual(AccessibilityID.ApprovalBanner.payloadExpanded, "calyx.approvalBanner.payloadExpanded")

        let newIdentifiers = [
            AccessibilityID.ApprovalBanner.optionsMenu,
            AccessibilityID.ApprovalBanner.payloadExpanded,
        ]

        for identifier in newIdentifiers {
            XCTAssertTrue(identifier.hasPrefix("calyx.approvalBanner."),
                         "\(identifier) must follow the existing calyx.approvalBanner.* naming convention")
        }

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.payload,
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
            AccessibilityID.ApprovalBanner.queueMenu,
        ]
        XCTAssertEqual(Set(newIdentifiers).intersection(preExistingIdentifiers), [],
                       "optionsMenu/payloadExpanded must be distinct from every pre-existing ApprovalBanner identifier")
        XCTAssertEqual(Set(newIdentifiers).count, newIdentifiers.count,
                       "optionsMenu and payloadExpanded must also be distinct from each other")
    }

    func test_accessibilityID_approvalBanner_queueNavigationIdentifiers_existAndAreDistinct() {
        // Queue navigation (prev/next cursor): the banner's Previous/Next
        // buttons and their "N / M" position label.
        let newIdentifiers = [
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
        ]

        for identifier in newIdentifiers {
            XCTAssertTrue(identifier.hasPrefix("calyx.approvalBanner."),
                         "\(identifier) must follow the existing calyx.approvalBanner.* naming convention")
        }

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.optionsMenu,
            AccessibilityID.ApprovalBanner.payload,
        ]
        XCTAssertEqual(Set(newIdentifiers).intersection(preExistingIdentifiers), [],
                       "the 3 identifiers must be distinct from every pre-existing ApprovalBanner identifier")
        XCTAssertEqual(Set(newIdentifiers).count, newIdentifiers.count,
                       "the 3 identifiers must also be distinct from each other")
    }

    // MARK: - AccessibilityID coverage for the new queue preview menu (spec-level only, same shape as the queue navigation coverage above)

    func test_accessibilityID_approvalBanner_queueMenuIdentifier_existsAndIsDistinct() {
        let newIdentifier = AccessibilityID.ApprovalBanner.queueMenu

        XCTAssertTrue(newIdentifier.hasPrefix("calyx.approvalBanner."),
                     "\(newIdentifier) must follow the existing calyx.approvalBanner.* naming convention")

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.optionsMenu,
            AccessibilityID.ApprovalBanner.payload,
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
        ]
        XCTAssertFalse(preExistingIdentifiers.contains(newIdentifier),
                       "queueMenu must be distinct from every pre-existing ApprovalBanner identifier")
    }

    // MARK: - AccessibilityID coverage for the dismiss button (spec-level only, same shape as the queue menu coverage above)

    func test_accessibilityID_approvalBanner_dismissButtonIdentifier_existsAndIsDistinct() {
        XCTAssertEqual(AccessibilityID.ApprovalBanner.dismissButton, "calyx.approvalBanner.dismissButton")

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.payload,
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
            AccessibilityID.ApprovalBanner.queueMenu,
            AccessibilityID.ApprovalBanner.optionsMenu,
            AccessibilityID.ApprovalBanner.payloadExpanded,
        ]
        XCTAssertFalse(preExistingIdentifiers.contains(AccessibilityID.ApprovalBanner.dismissButton),
                       "dismissButton must be distinct from every pre-existing ApprovalBanner identifier")
    }

    // MARK: - AccessibilityID coverage for the AskUserQuestion prompt UI (spec-level only, same shape as the other coverage above)
    //
    // Only the identifiers that still exist on `AgentQuestionBannerView`'s
    // question UI: "Other…"/Add notes/Back/Chat about this render as
    // `optionsMenu` (or, for a multi-select/preview-carrying question, an
    // inline list) rows looked up by title, so they carry no identifier of
    // their own -- see AccessibilityID.ApprovalBanner's own doc comment.

    func test_accessibilityID_approvalBanner_questionIdentifiers_existAndAreDistinct() {
        let newIdentifiers = [
            AccessibilityID.ApprovalBanner.questionText,
            AccessibilityID.ApprovalBanner.optionButton(0),
            AccessibilityID.ApprovalBanner.optionButton(1),
            AccessibilityID.ApprovalBanner.otherButton,
            AccessibilityID.ApprovalBanner.otherTextField,
            AccessibilityID.ApprovalBanner.answerButton,
            AccessibilityID.ApprovalBanner.questionPosition,
            AccessibilityID.ApprovalBanner.previewText,
            AccessibilityID.ApprovalBanner.notesTextField,
        ]

        for identifier in newIdentifiers {
            XCTAssertTrue(identifier.hasPrefix("calyx.approvalBanner."),
                         "\(identifier) must follow the existing calyx.approvalBanner.* naming convention")
        }

        XCTAssertEqual(AccessibilityID.ApprovalBanner.optionButton(0), "calyx.approvalBanner.optionButton.0")
        XCTAssertEqual(AccessibilityID.ApprovalBanner.optionButton(1), "calyx.approvalBanner.optionButton.1")

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.optionsMenu,
            AccessibilityID.ApprovalBanner.payload,
            AccessibilityID.ApprovalBanner.previousButton,
            AccessibilityID.ApprovalBanner.nextButton,
            AccessibilityID.ApprovalBanner.positionLabel,
            AccessibilityID.ApprovalBanner.queueMenu,
        ]
        XCTAssertEqual(Set(newIdentifiers).intersection(preExistingIdentifiers), [],
                       "the new question identifiers must be distinct from every pre-existing ApprovalBanner identifier")
        XCTAssertEqual(Set(newIdentifiers).count, newIdentifiers.count,
                       "the new question identifiers must also be distinct from each other")
    }

    // MARK: - answer(id:answers:) / chatAboutQuestion(id:) (AskUserQuestion prompt)

    private func makeAnswers(for prompt: AgentQuestionPrompt) -> AgentQuestionAnswers {
        AgentQuestionAnswers(prompt: prompt, entries: prompt.questions.map { _ in .init(answer: .selectedOne("zsh"), notes: nil) })
    }

    func test_answer_resolvesAnswered_advancesCursor_invokesRestoreFocusOnceWithTargetSurfaceID() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, restoreTerminalFocus: { spy.call($0) }
        )

        guard case .agentQuestion(_, let prompt) = request.source else {
            XCTFail("precondition: request must be .agentQuestion")
            return
        }
        let answers = makeAnswers(for: prompt)

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.answer(id: request.id, answers: answers)

        XCTAssertTrue(store.pending.isEmpty, "answer(id:answers:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")
        XCTAssertEqual(spy.targets, [surfaceID],
                       "answer(id:answers:) must invoke restoreTerminalFocus exactly once, with the decided request's own targetSurfaceID, read before store.decide removes it")

        let result = await waiter.value
        XCTAssertEqual(result, .answered(answers), "answer(id:answers:) must resolve the awaiter with .answered(answers)")
    }

    // MARK: - chatAboutQuestion(id:)

    func test_chatAboutQuestion_resolvesInterruptedChatAboutQuestion_advancesCursor_invokesRestoreFocusOnceWithTargetSurfaceID() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, restoreTerminalFocus: { spy.call($0) }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.chatAboutQuestion(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "chatAboutQuestion(id:) must decide that request, removing it from pending")
        XCTAssertEqual(spy.targets, [surfaceID],
                       "chatAboutQuestion(id:) must invoke restoreTerminalFocus exactly once, with the decided request's own targetSurfaceID")

        let result = await waiter.value
        XCTAssertEqual(result, .interrupted(.chatAboutQuestion))
    }

    /// Mirrors test_allow_onDisplayedRequest_advancesToSuccessor:
    /// chatAboutQuestion(id:) must advance the banner's cursor to the next
    /// queued request, not just clear the queue down to one element.
    func test_chatAboutQuestion_onDisplayedRequest_advancesToSuccessor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        model.selectNext()
        XCTAssertEqual(model.current?.id, second.id, "precondition: current is the displayed (middle) request")

        let waiter = Task { @MainActor in await store.awaitDecision(id: second.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.chatAboutQuestion(id: second.id)

        XCTAssertEqual(model.current?.id, third.id,
                       "chatAboutQuestion(id:) on the currently-displayed request must advance the cursor to its successor in the visible queue")

        let result = await waiter.value
        XCTAssertEqual(result, .interrupted(.chatAboutQuestion))
    }

    func test_chatAboutQuestion_onNonQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.chatAboutQuestion(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "chatAboutQuestion(id:) must never decide a non-.agentQuestion request")
    }

    // MARK: - dismiss(id:)
    //
    // Unlike allow(id:)/deny(id:) (which no-op on an .agentQuestion) and
    // answer(id:answers:)/chatAboutQuestion(id:) (which no-op on
    // anything else), dismiss(id:) works for EVERY source -- "Calyx does
    // not answer this request" applies regardless of what asked.

    /// After a × dismiss, the interaction continues in the pane (the
    /// CLI's own prompt for `.mcpTool`/`.agentHook`), so `dismiss(id:)`
    /// must invoke `restoreTerminalFocus` exactly once with the decided
    /// request's own `targetSurfaceID`.
    func test_dismiss_mcpToolSource_decidesDismissed_advancesCursor_invokesRestoreFocusOnceWithTargetSurfaceID() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, restoreTerminalFocus: { spy.call($0) }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.dismiss(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "dismiss(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")
        XCTAssertEqual(spy.targets, [surfaceID],
                       "dismiss(id:) on an .mcpTool-sourced request must invoke restoreTerminalFocus exactly once with its targetSurfaceID")

        let result = await waiter.value
        XCTAssertEqual(result, .dismissed, "dismiss(id:) must resolve the in-flight awaitDecision with .dismissed")
    }

    func test_dismiss_agentHookSource_decidesDismissed_invokesRestoreFocusOnceWithTargetSurfaceID() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, restoreTerminalFocus: { spy.call($0) }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.dismiss(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "dismiss(id:) must decide an .agentHook-sourced request too")
        XCTAssertEqual(spy.targets, [surfaceID],
                       "dismiss(id:) on an .agentHook-sourced request must invoke restoreTerminalFocus exactly once with its targetSurfaceID")
        let result = await waiter.value
        XCTAssertEqual(result, .dismissed)
    }

    /// For an `.agentQuestion`, `dismiss(id:)` goes through
    /// `resolveQuestion(id:_:)`, which restores terminal focus after
    /// `store.decide` (see that method's own doc comment) -- the
    /// injected `restoreTerminalFocus` spy must see exactly one call,
    /// with the decided request's own `targetSurfaceID`.
    func test_dismiss_agentQuestionSource_decidesDismissed_invokesRestoreFocusOnceWithTargetSurfaceID() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let spy = RestoreFocusSpy()

        let model = ApprovalBannerModel(
            store: store, restoreTerminalFocus: { spy.call($0) }
        )

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.dismiss(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "dismiss(id:) must decide an .agentQuestion-sourced request too")
        XCTAssertEqual(spy.targets, [surfaceID],
                       "dismiss(id:) on an .agentQuestion must invoke restoreTerminalFocus exactly once with its targetSurfaceID")

        let result = await waiter.value
        XCTAssertEqual(result, .dismissed)
    }

    /// grok/pi requests are never dismissible (`ApprovalRequest.
    /// isDismissible`, false for either kind: Calyx's gate is their only
    /// prompt, there is nothing else to hand a dismissed call back to) --
    /// `dismiss(id:)` must leave the request pending, undecided.
    func test_dismiss_nonDismissibleAgentHookSource_isNoOp() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID, kind: AgentEntry.grokKind)
        store.submit(request)

        let model = ApprovalBannerModel(store: store)

        model.dismiss(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "dismiss(id:) on a non-dismissible (grok) request must leave it pending, undecided")
        XCTAssertEqual(model.current?.id, request.id)
    }

    func test_dismiss_staleID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let requestA = makeRequest(targetSurfaceID: surfaceID, payload: "A", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let requestB = makeRequest(targetSurfaceID: surfaceID, payload: "B", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(requestA)
        store.submit(requestB)

        let model = ApprovalBannerModel(store: store)
        store.decide(id: requestA.id, .allowed)
        XCTAssertEqual(model.current?.id, requestB.id, "precondition: current has advanced to B once A left pending")

        model.dismiss(id: requestA.id)

        XCTAssertEqual(store.pending.map(\.id), [requestB.id],
                       "a stale dismiss(id: A) must not touch B, which is still pending")
    }

    /// Mirrors `test_deny_onLastDisplayedRequest_fallsBackToPredecessor`:
    /// dismissing the currently-displayed (and here, last) request must
    /// fall back to its predecessor in the visible queue.
    func test_dismiss_onLastDisplayedRequest_fallsBackToPredecessor() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeRequest(targetSurfaceID: surfaceID, payload: "first", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeRequest(targetSurfaceID: surfaceID, payload: "second", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        let third = makeRequest(targetSurfaceID: surfaceID, payload: "third", createdAt: Date(timeIntervalSince1970: 1_700_000_200))
        store.submit(first)
        store.submit(second)
        store.submit(third)

        let model = ApprovalBannerModel(store: store)
        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.current?.id, third.id, "precondition: navigated to the last (newest) displayed request")

        model.dismiss(id: third.id)

        XCTAssertEqual(model.current?.id, second.id,
                       "dismiss(id:) on the last displayed request must fall back to its predecessor in the visible queue, since there is no successor")
    }

    // MARK: - allowWithPermissions(id:offer:)

    private func makeOffer() -> AgentPermissionOffer {
        AgentPermissionOffer(
            label: "Yes, and always allow access to /tmp",
            entryJSON: try! JSONSerialization.data(withJSONObject: ["type": "addDirectories", "directories": ["/tmp"]])
        )
    }

    func test_allowWithPermissions_decidesAllowedWithPermissions_forAgentHookRequest() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)
        let offer = makeOffer()

        let waiter = Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.allowWithPermissions(id: request.id, offer: offer)

        XCTAssertTrue(store.pending.isEmpty)
        let result = await waiter.value
        XCTAssertEqual(result, .allowedWithPermissions(offer))
    }

    func test_allowWithPermissions_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.allowWithPermissions(id: request.id, offer: makeOffer())

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    func test_allowWithPermissions_onMcpToolID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.allowWithPermissions(id: request.id, offer: makeOffer())

        XCTAssertEqual(store.pending.map(\.id), [request.id])
    }

    // MARK: - alwaysAllow no-op when offers.cliOwnsPersistence

    func test_alwaysAllow_agentHookRequest_cliOwnsPersistence_isNoOp() {
        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(
            targetSurfaceID: surfaceID,
            offers: AgentHookOffers(permissionUpdates: [makeOffer()], cliOwnsPersistence: true)
        )
        store.submit(request)
        let model = ApprovalBannerModel(store: store, memory: memory)

        model.alwaysAllow(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "alwaysAllow(id:) must be a no-op when the CLI itself owns persistence of the permission decision")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "no pane memory may be recorded either")
    }

    func test_answer_onDisplayedRequest_advancesToSuccessor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let first = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeAgentQuestionRequest(targetSurfaceID: surfaceID, createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store)
        XCTAssertEqual(model.current?.id, first.id, "precondition: first is the oldest, currently-displayed request")

        guard case .agentQuestion(_, let prompt) = first.source else {
            XCTFail("precondition: request must be .agentQuestion")
            return
        }

        model.answer(id: first.id, answers: makeAnswers(for: prompt))

        XCTAssertEqual(model.current?.id, second.id,
                       "answer(id:answers:) on the currently-displayed request must advance the cursor to its successor")
    }

    func test_restoreTerminalFocusAfterInput_invokesClosureOnce() {
        let store = ApprovalInboxStore()
        let spy = RestoreFocusSpy()
        let model = ApprovalBannerModel(
            store: store, restoreTerminalFocus: { spy.call($0) }
        )
        let surfaceID = UUID()

        model.restoreTerminalFocusAfterInput(targetSurfaceID: surfaceID)

        XCTAssertEqual(spy.targets, [surfaceID], "restoreTerminalFocusAfterInput(targetSurfaceID:) must invoke restoreTerminalFocus exactly once, forwarding the passed target")
    }

    func test_restoreTerminalFocus_defaultsToNoOp_neverCrashesWhenOmitted() {
        let store = ApprovalInboxStore()
        // No restoreTerminalFocus argument at all -- must default to a no-op.
        let model = ApprovalBannerModel(store: store)

        model.restoreTerminalFocusAfterInput(targetSurfaceID: UUID())
    }

    // MARK: - .agentQuestion requests are excluded from the allow-family actions

    func test_alwaysAllow_agentHook_neverDrainsAgentQuestionRequest_withSameKindAndToolName() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowNeverDrainsQuestion"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceID = UUID()
        let clicked = makeAgentHookRequest(targetSurfaceID: surfaceID, toolName: "AskUserQuestion")
        let questionRequest = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(clicked)
        store.submit(questionRequest)

        let model = ApprovalBannerModel(store: store, memory: memory)

        model.alwaysAllow(id: clicked.id)

        XCTAssertEqual(store.pending.map(\.id), [questionRequest.id],
                       "alwaysAllow(id:) must never sweep a queued .agentQuestion request into its drain, " +
                       "even sharing the exact same (surface, kind, toolName)")
    }

    // MARK: - allow(id:)/deny(id:)/alwaysAllow(id:) on an .agentQuestion id are no-ops

    func test_allow_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.allow(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "allow(id:) must never decide an .agentQuestion request")
    }

    func test_deny_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.deny(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "deny(id:) must never decide an .agentQuestion request")
    }

    func test_alwaysAllow_onAgentQuestionID_isNoOp_recordsNoMemory() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let memory = AgentHookApprovalMemory()
        let model = ApprovalBannerModel(store: store, memory: memory)

        model.alwaysAllow(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "alwaysAllow(id:) must never decide an .agentQuestion request")
        XCTAssertFalse(memory.isAutoAllowed(surfaceID: surfaceID, kind: AgentEntry.claudeCodeKind, toolName: "AskUserQuestion"),
                       "alwaysAllow(id:) on an .agentQuestion request must never record Always-Allow memory")
    }

    // MARK: - allowForView(id:) / alwaysAllow(id:) / dismiss(id:) for an .mcpApp-sourced request
    //
    // allowForView(id:) is the "Always Allow for This View" action for an
    // .mcpApp request (openLink/sendMessage only -- copyMessage has no
    // "for this view" concept, since a pane-less view has no pane to
    // remember an allowance against). It decides .allowedForView and
    // advances the cursor exactly like allow(id:)/deny(id:). alwaysAllow(id:)
    // (the panel's OWN, separate global/pane-memory action) must never
    // touch an .mcpApp request at all -- MCPAppOpenLinkPolicy/
    // MCPAppMessageConsentGate own that memory, not ApprovalBannerModel/
    // CockpitSettings.autoApproveEnabled. dismiss(id:) decides .dismissed
    // and, unlike .mcpTool/.agentHook, never restores terminal focus --
    // the runtime denies its own pending prompt, it does not hand
    // anything back to a CLI waiting in the pane.

    private func makeMcpAppRequest(
        targetSurfaceID: UUID?, kind: MCPAppConsentKind, createdAt: Date = Date()
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID(), source: .mcpApp(viewID: UUID(), title: "Notion", kind: kind),
            targetSurfaceID: targetSurfaceID, payload: "payload", createdAt: createdAt
        )
    }

    func test_allowForView_openLink_decidesAllowedForView_advancesCursor() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let url = URL(string: "https://example.com")!
        let first = makeMcpAppRequest(targetSurfaceID: surfaceID, kind: .openLink(url), createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let second = makeMcpAppRequest(targetSurfaceID: surfaceID, kind: .openLink(url), createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(first)
        store.submit(second)

        let model = ApprovalBannerModel(store: store)
        XCTAssertEqual(model.current?.id, first.id, "precondition: current is the oldest (first) request")

        let waiter = Task { @MainActor in await store.awaitDecision(id: first.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.allowForView(id: first.id)

        XCTAssertEqual(store.pending.map(\.id), [second.id], "allowForView(id:) must decide only the clicked request")
        XCTAssertEqual(model.current?.id, second.id,
                       "allowForView(id:) on the displayed request must advance the cursor to its successor, same as allow(id:)/deny(id:)")

        let result = await waiter.value
        XCTAssertEqual(result, .allowedForView)
    }

    func test_allowForView_sendMessage_decidesAllowedForView() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeMcpAppRequest(targetSurfaceID: surfaceID, kind: .sendMessage(preview: "hi"))
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        let waiter = Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.allowForView(id: request.id)

        XCTAssertTrue(store.pending.isEmpty)
        let result = await waiter.value
        XCTAssertEqual(result, .allowedForView)
    }

    func test_allowForView_copyMessage_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeMcpAppRequest(targetSurfaceID: surfaceID, kind: .copyMessage(text: "hi"))
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.allowForView(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "allowForView(id:) must be a no-op for .copyMessage -- a pane-less view has no \"this view\" to remember an allowance against")
    }

    func test_allowForView_onMcpToolID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.allowForView(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "allowForView(id:) must never decide a non-.mcpApp request")
    }

    func test_allowForView_onAgentHookID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentHookRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.allowForView(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "allowForView(id:) must never decide a non-.mcpApp request")
    }

    func test_allowForView_onAgentQuestionID_isNoOp() {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeAgentQuestionRequest(targetSurfaceID: surfaceID)
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.allowForView(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id], "allowForView(id:) must never decide a non-.mcpApp request")
    }

    func test_alwaysAllow_mcpAppSource_isNoOp_leavesRequestPending_neverTouchesAutoApprove() {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowMcpAppIsNoOp"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let url = URL(string: "https://example.com")!
        let request = makeMcpAppRequest(targetSurfaceID: surfaceID, kind: .openLink(url))
        store.submit(request)
        let model = ApprovalBannerModel(store: store)

        model.alwaysAllow(id: request.id)

        XCTAssertEqual(store.pending.map(\.id), [request.id],
                       "alwaysAllow(id:) must never decide an .mcpApp request -- MCPAppOpenLinkPolicy owns that memory, not this action")
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "alwaysAllow(id:) on an .mcpApp request must never flip the global Cockpit auto-approve toggle")
    }

    func test_dismiss_mcpAppSource_decidesDismissed_neverRestoresTerminalFocus() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let url = URL(string: "https://example.com")!
        let request = makeMcpAppRequest(targetSurfaceID: surfaceID, kind: .openLink(url))
        store.submit(request)
        let spy = RestoreFocusSpy()
        let model = ApprovalBannerModel(store: store, restoreTerminalFocus: { spy.call($0) })

        let waiter = Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.dismiss(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "dismiss(id:) must decide an .mcpApp-sourced request too")
        XCTAssertEqual(spy.callCount, 0,
                       "dismiss(id:) on an .mcpApp request must never restore terminal focus -- the WebView never held first responder")

        let result = await waiter.value
        XCTAssertEqual(result, .dismissed)
    }

}
