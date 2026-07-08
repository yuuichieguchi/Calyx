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
//    already visible to this window in the same action
//  - pendingCountForWindow counts only requests this window owns
//    (mirrors current's ownership filter, for a "+N more" affordance)
//

import XCTest
@testable import Calyx

@MainActor
final class ApprovalBannerModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(targetSurfaceID: UUID?, payload: String = "ls", createdAt: Date = Date()) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpTool(name: "pane_run"), targetSurfaceID: targetSurfaceID, payload: payload, createdAt: createdAt)
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
}
