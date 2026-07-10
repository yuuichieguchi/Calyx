//
//  ApprovalBannerModelTests.swift
//  CalyxTests
//
//  TDD Red Phase for ApprovalBannerModel: the per-window view-model
//  behind the Cockpit approval banner, deciding which single pending
//  ApprovalRequest (if any) this window should show, and forwarding
//  Allow/Deny/Always Allow to ApprovalInboxStore.decide(id:_:) /
//  CockpitSettings.autoApproveEnabled.
//
//  Coverage:
//  - current is the OLDEST pending request this window owns
//    (targetSurfaceID resolves true via the injected ownsSurface
//    closure); a request targeting a surface this window doesn't own
//    is invisible to it
//  - a request with a nil targetSurfaceID (window-agnostic, e.g. a
//    palette-level tool call) is shown only while this window is key,
//    so every open window doesn't surface the same banner at once
//  - allow(id:)/deny(id:) decide the id the caller explicitly passed
//    (the request actually rendered), never a re-read of `current` --
//    a stale id (no longer pending) is a safe no-op that never touches
//    whatever request `current` has since advanced to
//  - alwaysAllow(id:) turns on CockpitSettings.autoApproveEnabled,
//    decides the clicked id .allowed, AND drains every other request
//    already visible to this window in the same action -- for an
//    `.mcpTool`-sourced request (unchanged, Stage E), but NEVER a queued
//    `.agentHook`-sourced request on that same drain, even targeting the
//    same surface (source-scoped, see
//    test_alwaysAllow_mcpToolSource_doesNotDrainQueuedAgentHookRequest_onSameSurface).
//    For an `.agentHook`-sourced request (Stage E, NEW), alwaysAllow(id:)
//    instead records PANE Always-Allow memory (surfaceID, kind,
//    toolName) via the injected `memory`, batch-allows only pending
//    requests sharing that EXACT tuple, and never touches
//    CockpitSettings.autoApproveEnabled at all
//  - allowAllPending() (Stage E, NEW) decides EVERY pending request in
//    the store .allowed, store-wide, with no window/ownership filter at
//    all -- leaves no Always-Allow memory behind and never touches any
//    setting
//  - alwaysAllowAcrossPanes(id:) (Stage E, NEW; only meaningful for an
//    `.agentHook`-sourced request) records CROSS Always-Allow memory
//    (kind, toolName only -- no surfaceID) via the injected `memory`,
//    then batch-allows every pending request store-wide sharing that
//    (kind, toolName), regardless of window/pane, leaving a
//    different-tool request pending and never touching any setting
//  - pendingCountForWindow counts only requests this window owns
//    (mirrors current's ownership filter, for a "+N more" affordance)
//
//  Stage E init change: ApprovalBannerModel's initializer gains a new
//  `memory: AgentHookApprovalMemory` parameter, defaulted to `.shared`
//  (mirrors this codebase's `= .shared`-defaulted seam convention, e.g.
//  `CalyxMCPServer.approvalInbox`/`agentRegistry`) -- every PRE-EXISTING
//  test below that never mentions `.agentHook` or the new actions
//  continues to construct `ApprovalBannerModel(store:ownsSurface:isKeyWindow:)`
//  unchanged and is unaffected; only the new tests below inject an
//  isolated `AgentHookApprovalMemory()` instance explicitly, so no test
//  leaks Always-Allow memory into another via the shared singleton.
//

import XCTest
@testable import Calyx

@MainActor
final class ApprovalBannerModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(targetSurfaceID: UUID?, payload: String = "ls", createdAt: Date = Date()) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: targetSurfaceID, payload: payload, createdAt: createdAt)
    }

    /// Stage E helper: an `.agentHook`-sourced request, the source
    /// variant `alwaysAllow(id:)`/`alwaysAllowAcrossPanes(id:)` key their
    /// new memory-recording behavior off of.
    private func makeAgentHookRequest(
        targetSurfaceID: UUID?,
        kind: String = AgentEntry.claudeCodeKind,
        toolName: String = "Bash",
        createdAt: Date = Date()
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID(),
            source: .agentHook(toolName: toolName, kind: kind, summary: "ls -la /tmp"),
            targetSurfaceID: targetSurfaceID,
            payload: "{\"command\":\"ls -la /tmp\"}",
            createdAt: createdAt
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

    // MARK: - current: ownership filter, oldest-first

    func test_current_isOldestPendingRequestOwnedByThisWindow() {
        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        let older = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "older", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "newer", createdAt: Date(timeIntervalSince1970: 1_700_000_100))
        store.submit(older)
        store.submit(newer)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        XCTAssertEqual(model.current?.id, older.id,
                       "current must be the oldest pending request this window owns, ignoring a foreign-surface request even if newer")

        let foreignOnlyStore = ApprovalInboxStore()
        foreignOnlyStore.submit(makeRequest(targetSurfaceID: foreignSurfaceID))
        let foreignOnlyModel = ApprovalBannerModel(store: foreignOnlyStore, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        XCTAssertNil(foreignOnlyModel.current,
                     "a window that owns none of the pending requests' target surfaces must show nothing")
    }

    // MARK: - current: nil targetSurfaceID gated by key-window

    func test_current_nilTargetSurface_shownOnlyInKeyWindow() {
        let store = ApprovalInboxStore()
        store.submit(makeRequest(targetSurfaceID: nil))

        var isKey = true
        let model = ApprovalBannerModel(store: store, ownsSurface: { _ in false }, isKeyWindow: { isKey })

        XCTAssertNotNil(model.current,
                        "a window-agnostic (nil targetSurfaceID) request must show in the key window")

        isKey = false
        XCTAssertNil(model.current,
                     "a window-agnostic request must not show in a non-key window, to avoid every open window surfacing it at once")
    }

    // MARK: - allow / deny

    func test_allow_decidesAllowed_andBannerClears() async throws {
        let store = ApprovalInboxStore()
        let surfaceID = UUID()
        let request = makeRequest(targetSurfaceID: surfaceID)
        store.submit(request)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

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

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.deny(id: request.id)

        XCTAssertTrue(store.pending.isEmpty, "deny(id:) must decide that request, removing it from pending")
        XCTAssertNil(model.current, "the banner must clear once its current request has been decided")

        let result = await waiter.value
        XCTAssertEqual(result, .denied, "deny(id:) must resolve the in-flight awaitDecision with .denied")
    }

    /// F5: the id threaded through must be the one the caller actually
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

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })
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

        store.decide(id: requestB.id, .denied)
        let result = await waiterB.value
        XCTAssertEqual(result, .denied,
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

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiter = Task { @MainActor in
            await store.awaitDecision(id: request.id, timeoutMs: 5_000)
        }
        await yieldToScheduler()

        model.alwaysAllow(id: request.id)

        XCTAssertTrue(CockpitSettings.autoApproveEnabled, "alwaysAllow(id:) must turn on the auto-approve setting")

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "alwaysAllow(id:) must also resolve the clicked request as allowed")
    }

    /// F4: alwaysAllow(id:) must drain the WHOLE backlog visible to this
    /// window, not just the one request that was clicked.
    func test_alwaysAllow_drainsAllVisiblePendingRequests_forThisWindow() async throws {
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

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true })

        let waiterA = Task { @MainActor in await store.awaitDecision(id: requestA.id, timeoutMs: 5_000) }
        let waiterB = Task { @MainActor in await store.awaitDecision(id: requestB.id, timeoutMs: 5_000) }
        let waiterC = Task { @MainActor in await store.awaitDecision(id: requestC.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        let notifyCountBeforeDrain = store._testNotifyCount

        model.alwaysAllow(id: requestA.id)

        XCTAssertTrue(store.pending.isEmpty,
                      "alwaysAllow(id:) must drain every request visible to this window, not just the clicked one")
        XCTAssertEqual(store._testNotifyCount - notifyCountBeforeDrain, 1,
                       "W6: draining 3 requests in one alwaysAllow(id:) action must post exactly one change " +
                       "notification, not one per drained request (which would trigger N full-window " +
                       "rebuilds per open window)")

        let resultA = await waiterA.value
        let resultB = await waiterB.value
        let resultC = await waiterC.value
        XCTAssertEqual(resultA, .allowed)
        XCTAssertEqual(resultB, .allowed, "the backlog drain must resolve B allowed even though only A was clicked")
        XCTAssertEqual(resultC, .allowed, "the backlog drain must resolve C allowed even though only A was clicked")
    }

    /// F4's cross-window scope: a pending request owned by a DIFFERENT
    /// window must be left alone by this window's alwaysAllow(id:) drain.
    func test_alwaysAllow_doesNotDrainRequestsOwnedByAnotherWindow() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowCrossWindow"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }

        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        let ownedRequest = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "owned")
        let foreignRequest = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "foreign")
        store.submit(ownedRequest)
        store.submit(foreignRequest)

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        model.alwaysAllow(id: ownedRequest.id)

        XCTAssertEqual(store.pending.map(\.id), [foreignRequest.id],
                       "alwaysAllow(id:) must leave a request targeting a surface this window doesn't own pending")
    }

    /// R2 fix-pin: the `.mcpTool` branch of `alwaysAllow(id:)` drains
    /// every OTHER pending request visible to this window with NO source
    /// filter -- so a queued `.agentHook` request targeting the SAME
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

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

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

    // MARK: - pendingCountForWindow

    func test_pendingCountForWindow_countsOnlyOwnedRequests() {
        let store = ApprovalInboxStore()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()
        store.submit(makeRequest(targetSurfaceID: ownedSurfaceID, payload: "one"))
        store.submit(makeRequest(targetSurfaceID: ownedSurfaceID, payload: "two"))
        store.submit(makeRequest(targetSurfaceID: foreignSurfaceID, payload: "three"))

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { true })

        XCTAssertEqual(model.pendingCountForWindow, 2,
                       "pendingCountForWindow must count only requests targeting a surface this window owns")
    }

    // MARK: - alwaysAllow(id:) for an .agentHook-sourced request (Stage E)

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

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

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

        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceID }, isKeyWindow: { true }, memory: memory)

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

    // MARK: - allowAllPending() (Stage E, NEW)

    func test_allowAllPending_drainsEveryPendingRequestStoreWide_leavesNoMemory_neverTouchesSettings() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.allowAllPending"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let ownedSurfaceID = UUID()
        let foreignSurfaceID = UUID()

        let ownedMcp = makeRequest(targetSurfaceID: ownedSurfaceID, payload: "owned-mcp")
        let foreignMcp = makeRequest(targetSurfaceID: foreignSurfaceID, payload: "foreign-mcp")
        let foreignAgentHook = makeAgentHookRequest(targetSurfaceID: foreignSurfaceID, toolName: "Bash")
        let windowAgnostic = makeRequest(targetSurfaceID: nil, payload: "agnostic")
        store.submit(ownedMcp)
        store.submit(foreignMcp)
        store.submit(foreignAgentHook)
        store.submit(windowAgnostic)

        // isKeyWindow is false, so the window-agnostic request would
        // normally be invisible to this window too -- proving
        // allowAllPending() applies NO visibility filter at all.
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == ownedSurfaceID }, isKeyWindow: { false }, memory: memory)

        let requests = [ownedMcp, foreignMcp, foreignAgentHook, windowAgnostic]
        let waiters = requests.map { request in
            Task { @MainActor in await store.awaitDecision(id: request.id, timeoutMs: 5_000) }
        }
        await yieldToScheduler()

        model.allowAllPending()

        XCTAssertTrue(store.pending.isEmpty,
                      "allowAllPending() must drain EVERY pending request store-wide, including ones this " +
                      "window neither owns nor could otherwise see")

        for waiter in waiters {
            let result = await waiter.value
            XCTAssertEqual(result, .allowed)
        }

        XCTAssertFalse(memory.isAutoAllowed(surfaceID: foreignSurfaceID, kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                       "allowAllPending() must leave no Always-Allow memory behind")
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "allowAllPending() must never touch the global auto-approve setting")
    }

    // MARK: - alwaysAllowAcrossPanes(id:) (Stage E, NEW)

    func test_alwaysAllowAcrossPanes_recordsCrossMemory_drainsSameToolStoreWide_leavesDifferentToolPending() async throws {
        let suiteName = "com.calyx.tests.ApprovalBannerModelTests.alwaysAllowAcrossPanes"
        CockpitSettings._testUseSuite(named: suiteName)
        defer { CockpitSettings._testTeardownSuite(named: suiteName) }
        XCTAssertFalse(CockpitSettings.autoApproveEnabled, "precondition: the isolated suite starts with auto-approve off")

        let store = ApprovalInboxStore()
        let memory = AgentHookApprovalMemory()
        let surfaceA = UUID()
        let surfaceB = UUID()

        let clicked = makeAgentHookRequest(
            targetSurfaceID: surfaceA, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let sameToolOtherPane = makeAgentHookRequest(
            targetSurfaceID: surfaceB, toolName: "Bash", createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let differentTool = makeAgentHookRequest(
            targetSurfaceID: surfaceA, toolName: "Write", createdAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        store.submit(clicked)
        store.submit(sameToolOtherPane)
        store.submit(differentTool)

        // This window owns only surfaceA -- surfaceB is a pane it does
        // NOT own, proving alwaysAllowAcrossPanes(id:) applies no window
        // filter at all.
        let model = ApprovalBannerModel(store: store, ownsSurface: { $0 == surfaceA }, isKeyWindow: { true }, memory: memory)

        let waiterClicked = Task { @MainActor in await store.awaitDecision(id: clicked.id, timeoutMs: 5_000) }
        let waiterOtherPane = Task { @MainActor in await store.awaitDecision(id: sameToolOtherPane.id, timeoutMs: 5_000) }
        await yieldToScheduler()

        model.alwaysAllowAcrossPanes(id: clicked.id)

        XCTAssertTrue(memory.isAutoAllowed(surfaceID: UUID(), kind: AgentEntry.claudeCodeKind, toolName: "Bash"),
                     "alwaysAllowAcrossPanes(id:) must record CROSS memory for (kind, toolName), auto-allowing " +
                     "an arbitrary surface it has never seen before")
        XCTAssertEqual(store.pending.map(\.id), [differentTool.id],
                       "alwaysAllowAcrossPanes(id:) must drain every pending request sharing the clicked " +
                       "request's (kind, toolName) store-wide, regardless of window ownership, leaving a " +
                       "different tool pending")
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "alwaysAllowAcrossPanes(id:) must never touch the global auto-approve setting")

        let resultClicked = await waiterClicked.value
        let resultOtherPane = await waiterOtherPane.value
        XCTAssertEqual(resultClicked, .allowed)
        XCTAssertEqual(resultOtherPane, .allowed,
                       "a same-tool request on a pane this window doesn't own must still be drained")
    }

    // MARK: - AccessibilityID coverage for the new cross-actions menu (Stage E, spec-level only)
    //
    // SwiftUI Menu rendering itself is not unit-testable (no production
    // view code exercised here) -- this only pins that the new
    // identifiers exist, are distinct from each other and from the
    // pre-existing ApprovalBanner identifiers, and follow the same
    // "calyx.approvalBanner.*" prefix convention as
    // container/allowButton/denyButton/alwaysAllowButton/payload above.

    func test_accessibilityID_approvalBanner_crossActionsMenuIdentifiers_existAndAreDistinct() {
        let newIdentifiers = [
            AccessibilityID.ApprovalBanner.crossActionsMenu,
            AccessibilityID.ApprovalBanner.allowAllPendingItem,
            AccessibilityID.ApprovalBanner.alwaysAllowAllPanesItem,
        ]

        for identifier in newIdentifiers {
            XCTAssertTrue(identifier.hasPrefix("calyx.approvalBanner."),
                         "\(identifier) must follow the existing calyx.approvalBanner.* naming convention")
        }

        let preExistingIdentifiers = [
            AccessibilityID.ApprovalBanner.container,
            AccessibilityID.ApprovalBanner.allowButton,
            AccessibilityID.ApprovalBanner.denyButton,
            AccessibilityID.ApprovalBanner.alwaysAllowButton,
            AccessibilityID.ApprovalBanner.payload,
        ]
        XCTAssertEqual(Set(newIdentifiers).intersection(preExistingIdentifiers), [],
                       "the 3 new identifiers must be distinct from every pre-existing ApprovalBanner identifier")
        XCTAssertEqual(Set(newIdentifiers).count, newIdentifiers.count,
                       "the 3 new identifiers must also be distinct from each other")
    }
}
