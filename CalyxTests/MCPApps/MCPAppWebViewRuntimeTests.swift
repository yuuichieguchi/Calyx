//
//  MCPAppWebViewRuntimeTests.swift
//  CalyxTests
//
//  `MCPAppWebViewRuntime` driven by a real `MCPAppHostStore`: a dock is
//  detached through the container it was attached to, fullscreen follows
//  the view to a remapped leaf, closing the picture-in-picture window
//  returns the view inline, a host request to a mounted view fails when
//  its WebContent process ends or its caller is cancelled, a pending
//  `ui/message` fails with -32000 when the pane's conversation ends, and a
//  mount that finishes after the store dropped the view builds no web view.
//  Inline sizing (K55): `ui/notifications/size-changed` does not resize
//  the dock, and the host context reports the dock's size.
//
//  Consent prompts (`ui/open-link` / `ui/message`) no longer show inline
//  in the card: the runtime submits an `ApprovalRequest` (`.mcpApp`) to
//  its `MCPAppRuntimeEnvironment.consentPresenter`, here a dedicated
//  `ApprovalInboxStore` wired through `ApprovalInboxConsentPresenter` --
//  `FakeRuntimeEnvironment.inbox` (never `.shared`, so tests never leak
//  into one another). Tests find a view's pending prompt through
//  `pendingConsent(for:)` and answer it via `inbox.decide(id:_:)`,
//  exactly like a real approval-panel click. A `ui/open-link` the user
//  allows "Always Allow for This View" (`.allowedForView`) opens later
//  links from that view without a new submission, while another view
//  still prompts. The "Always" grants of `ui/open-link` and `ui/message`
//  survive a Reload of the view and end when the view is closed; a
//  prompt pending at a Reload/close/unmount/`expireForSurface` resolves
//  denied with no grant recorded, and an answer that arrives after the
//  Reload unmounted the document opens nothing and allows nothing. A
//  second prompt for the same view expires the first. An unanswered
//  prompt times out after `consentTimeoutMs`. A pane-less `ui/message`
//  submits a `.copyMessage` request instead of showing the card's old
//  copy-only prompt; `.allowed` pastes the text to `NSPasteboard.general`.
//

import AppKit
import WebKit
import XCTest
@testable import Calyx

@MainActor
private final class FakeRuntimeEnvironment: MCPAppRuntimeEnvironment {
    var containers: [UUID: SplitContainerView] = [:]
    let recordingDelivery = RecordingInputDelivery()
    var cockpitInputDelivery: any MCPAppInputDelivering { recordingDelivery }

    /// A dedicated inbox, never `.shared` -- each test gets its own
    /// isolated queue of `.mcpApp` consent requests.
    let inbox = ApprovalInboxStore()
    lazy var consentPresenter: any MCPAppConsentPresenting = ApprovalInboxConsentPresenter(store: inbox)

    func splitContainer(owningSurface surfaceID: UUID) -> SplitContainerView? { containers[surfaceID] }
    func herdrPaneRef(forSurface surfaceID: UUID) -> HerdrPaneRef? { nil }
    func isAgentPane(_ surfaceID: UUID) -> Bool { false }
    func themeInputs() -> MCPAppThemeInputs { MCPAppThemeInputsReader.defaultInputs }

    /// Every URL the runtime asked to open, in order. Nothing is opened.
    private(set) var openedLinks: [URL] = []
    func openLink(_ url: URL) -> Bool {
        openedLinks.append(url)
        return true
    }
}

/// Records every message delivered to a pane.
@MainActor
private final class RecordingInputDelivery: MCPAppInputDelivering {
    private(set) var deliveredTexts: [String] = []
    func deliverUserMessage(_ text: String, to surfaceID: UUID) async throws {
        deliveredTexts.append(text)
    }
}

@MainActor
private final class NoPaneResolver: MCPPaneResolving {
    func paneHost(owningSurface surfaceID: UUID) -> MCPPaneHost? { nil }
}

@MainActor
private final class Box<Value> {
    var value: Value?
}

private struct WaitTimedOut: Error, CustomStringConvertible {
    let description: String
}

@MainActor
final class MCPAppWebViewRuntimeTests: XCTestCase {

    private struct Harness {
        let runtime: MCPAppWebViewRuntime
        let store: MCPAppHostStore
        let environment: FakeRuntimeEnvironment
    }

    private func makeHarness() -> Harness {
        let environment = FakeRuntimeEnvironment()
        let runtime = MCPAppWebViewRuntime(environment: environment)
        let store = MCPAppHostStore(paneResolver: NoPaneResolver(), runtime: runtime, appToolRegistry: FakeAppToolRegistry())
        runtime.store = store
        return Harness(runtime: runtime, store: store, environment: environment)
    }

    private func makeContainer(leaves: [UUID]) -> (container: SplitContainerView, registry: SurfaceRegistry) {
        let registry = SurfaceRegistry()
        let container = SplitContainerView(registry: registry)
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        container.layoutSubtreeIfNeeded()
        for leaf in leaves {
            registry._testInsert(view: SurfaceView(frame: .zero), id: leaf)
        }
        container.updateLayout(tree: tree(leaves))
        return (container, registry)
    }

    private func tree(_ leaves: [UUID]) -> SplitTree {
        if leaves.count == 1 {
            return SplitTree(root: .leaf(id: leaves[0]), focusedLeafID: leaves[0], zoomedLeafID: nil)
        }
        let root = SplitNode.split(SplitData(direction: .horizontal, ratio: 0.5, first: .leaf(id: leaves[0]), second: .leaf(id: leaves[1])))
        return SplitTree(root: root, focusedLeafID: leaves[0], zoomedLeafID: nil)
    }

    private func invocation(serverID: MCPServerID, surfaceID: UUID?) throws -> MCPUIToolInvocation {
        MCPUIToolInvocation(
            id: MCPInvocationID(rawValue: UUID()),
            serverID: serverID,
            serverDisplayName: "Weather",
            tool: try MCPToolDefinition(raw: [
                "name": AnyCodable("dashboard"),
                "_meta": AnyCodable(["ui": AnyCodable(["resourceUri": AnyCodable("ui://server/view")])]),
            ]),
            upstreamRequestID: .int(1),
            arguments: [:],
            surfaceID: surfaceID,
            clientName: nil,
            clientDeclaredUI: false,
            requestedAt: Date()
        )
    }

    private func validResource() -> [String: AnyCodable] {
        ["contents": AnyCodable([AnyCodable([
            "uri": AnyCodable("ui://server/view"),
            "mimeType": AnyCodable("text/html;profile=mcp-app"),
            "text": AnyCodable("<!DOCTYPE html><html><body>view</body></html>"),
        ])])]
    }

    /// A view whose resource read fails: it gets a card but no web view.
    private func startCardOnlyView(_ harness: Harness, surfaceID: UUID?) async throws -> UUID {
        let session = FakeMCPAppServerSession(readResourceResult: .failure(FakeSessionError(message: "unreadable")))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await harness.store.uiToolInvocationDidStart(inv, session: session)
        await harness.store.resourceLoad(forView: inv.id.rawValue)?.value
        return inv.id.rawValue
    }

    /// A view whose web view loaded its document. `surfaceID: nil` mounts
    /// a pane-less view, shown in a standalone panel instead of a dock.
    private func startMountedView(_ harness: Harness, surfaceID: UUID?) async throws -> UUID {
        let session = FakeMCPAppServerSession(readResourceResult: .success(validResource()))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await harness.store.uiToolInvocationDidStart(inv, session: session)
        await harness.store.resourceLoad(forView: inv.id.rawValue)?.value
        let viewID = inv.id.rawValue
        try await waitUntil(timeout: 10, "the view document loads") {
            harness.store.snapshot(viewID: viewID)?.status == .waitingForApp
        }
        return viewID
    }

    private func waitUntil(timeout: TimeInterval = 2, _ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw WaitTimedOut(description: description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Finding 14: the dock is detached through its own container

    func test_viewOfADestroyedSurface_leavesItsContainerWithoutADock() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        harness.environment.containers[surfaceID] = container
        _ = try await startCardOnlyView(harness, surfaceID: surfaceID)
        XCTAssertNotNil(container.dockView(forLeaf: surfaceID), "precondition: the view is docked under its pane")

        // The destroyed surface is no longer found through the registry.
        harness.environment.containers[surfaceID] = nil
        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": surfaceID])

        try await waitUntil("the dock leaves the container") { container.dockView(forLeaf: surfaceID) == nil }
    }

    /// The order of closing a pane: the leaf leaves the tree first (the
    /// container parks its dock), then the surface is destroyed. The
    /// parked dock is forgotten: it is out of the view hierarchy, and a
    /// leaf with the same ID back in the tree gets no dock and no dock
    /// divider.
    func test_viewOfADestroyedSurface_whoseLeafAlreadyLeftTheTree_forgetsTheParkedDock() async throws {
        let harness = makeHarness()
        let closing = UUID()
        let sibling = UUID()
        let (container, _) = makeContainer(leaves: [closing, sibling])
        harness.environment.containers[closing] = container
        _ = try await startCardOnlyView(harness, surfaceID: closing)
        let dock = try XCTUnwrap(container.dockView(forLeaf: closing), "precondition: the view is docked under its pane")

        container.updateLayout(tree: tree([sibling]))
        XCTAssertNil(dock.superview, "precondition: the dock of a leaf out of the tree is parked")

        harness.environment.containers[closing] = nil
        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": closing])
        try await waitUntil("the runtime drops the view") { harness.runtime.views.isEmpty }

        XCTAssertNil(dock.superview)
        container.updateLayout(tree: tree([closing, sibling]))
        XCTAssertNil(container.dockView(forLeaf: closing), "a dock forgotten by the container is not put back")
        XCTAssertFalse(container.subviews.contains { $0 is MCPAppDockView })
        XCTAssertEqual(container.subviews.filter { $0 is SplitDividerView }.count, 1, "only the split divider; no dock divider")
    }

    // MARK: - Finding 10: fullscreen follows the view to a remapped leaf

    func test_remap_keepsAFullscreenViewFullscreenOnTheNewLeaf() async throws {
        let harness = makeHarness()
        let old = UUID()
        let other = UUID()
        let new = UUID()
        let (container, registry) = makeContainer(leaves: [old, other])
        harness.environment.containers[old] = container
        harness.environment.containers[new] = container
        let viewID = try await startCardOnlyView(harness, surfaceID: old)
        harness.runtime.applyDisplayMode("fullscreen", viewID: viewID)
        XCTAssertEqual(container.dockView(forLeaf: old)?.frame, container.bounds, "precondition: the dock covers the container")

        registry._testInsert(view: SurfaceView(frame: .zero), id: new)
        container.updateLayout(tree: tree([new, other]))
        harness.store.remapSurface(old: old, new: new)

        XCTAssertEqual(harness.runtime.views[viewID]?.displayMode, "fullscreen")
        let dock = try XCTUnwrap(container.dockView(forLeaf: new))
        XCTAssertEqual(dock.frame, container.bounds, "the container shows the fullscreen view on the new leaf")
    }

    // MARK: - Finding 11: closing the PiP window returns the view inline

    func test_closingThePiPWindow_returnsTheViewInline() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(container)
        defer { window.close() }
        harness.environment.containers[surfaceID] = container
        let viewID = try await startCardOnlyView(harness, surfaceID: surfaceID)
        harness.runtime.applyDisplayMode("pip", viewID: viewID)
        let pip = try XCTUnwrap(harness.runtime.views[viewID]?.pipWindow, "precondition: the view is in a PiP window")

        pip.close()

        let state = try XCTUnwrap(harness.runtime.views[viewID])
        XCTAssertEqual(state.displayMode, "inline")
        XCTAssertNil(state.pipWindow)
        let dock = try XCTUnwrap(container.dockView(forLeaf: surfaceID) as? MCPAppDockView, "the view is docked again")
        XCTAssertTrue(dock.panes.contains { $0 === state.pane })
    }

    // MARK: - Finding 3: a pending host request ends on a crash or a cancel

    func test_webContentProcessEnding_failsAPendingHostRequest() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let box = Box<Result<JSONRPCMessage?, Error>>()
        Task { @MainActor in
            do {
                box.value = .success(try await harness.runtime.send(.request(id: .string("probe"), method: "tools/list", params: [:]), to: viewID))
            } catch {
                box.value = .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(box.value, "precondition: the view never answers, so the request is pending")

        let mounted = try XCTUnwrap(harness.runtime.views[viewID]?.mounted)
        mounted.navigationGuard.webViewWebContentProcessDidTerminate(mounted.webView)

        try await waitUntil("the pending request fails once the process ended") { box.value != nil }
        guard case .failure? = box.value else { return XCTFail("expected the request to fail, got \(String(describing: box.value))") }
        await harness.store.close(viewID: viewID)
    }

    func test_cancellingTheCallerOfAPendingAppToolCall_returnsPromptly() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        harness.store.viewDidInitialize(viewID: viewID)
        harness.store.registerAppTools([try MCPToolDefinition(raw: ["name": AnyCodable("pick")])], viewID: viewID)

        let box = Box<MCPCallToolResult>()
        let task = Task { @MainActor in
            box.value = await harness.store.callAppTool(surfaceID: surfaceID, viewID: viewID, name: "pick", arguments: [:])
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(box.value, "precondition: the view never answers, so the call is pending")

        task.cancel()

        try await waitUntil(timeout: 1, "the cancelled call returns") { box.value != nil }
        XCTAssertEqual(box.value?.raw["isError"]?.boolValue, true)
        await harness.store.close(viewID: viewID)
    }

    // MARK: - K52: the calling agent's exit ends a pending ui/message

    func test_conversationEnded_failsAPendingMessagePromptWithMinus32000_andDeliversNothing() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        let box = Box<Result<AnyCodable, JSONRPCError>>()
        Task { @MainActor in
            box.value = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/message", params: [
                "role": AnyCodable("user"),
                "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("hello")])]),
            ])
        }
        try await waitUntil("the consent prompt is pending") { harness.runtime.consentGate.isPending(viewID: viewID) }

        NotificationCenter.default.post(name: .calyxAgentConversationEnded, object: nil, userInfo: ["surfaceID": surfaceID])

        try await waitUntil("the message request ends") { box.value != nil }
        guard case .failure(let error)? = box.value else {
            return XCTFail("expected the message request to fail, got \(String(describing: box.value))")
        }
        XCTAssertEqual(error.code, -32000)
        XCTAssertEqual(error.message, "Message sending denied")
        XCTAssertTrue(harness.environment.recordingDelivery.deliveredTexts.isEmpty, "nothing reaches the pane")
        try await waitUntil("the view is removed") { harness.store.snapshot(viewID: viewID) == nil }
    }

    // MARK: - ui/open-link and ui/message consent, through the approval inbox

    private func requestOpenLink(_ harness: Harness, viewID: UUID, url: String) throws -> Box<Result<AnyCodable, JSONRPCError>> {
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        let box = Box<Result<AnyCodable, JSONRPCError>>()
        Task { @MainActor in
            box.value = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/open-link", params: ["url": AnyCodable(url)])
        }
        return box
    }

    private func requestMessage(_ harness: Harness, viewID: UUID, text: String) throws -> Box<Result<AnyCodable, JSONRPCError>> {
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        let box = Box<Result<AnyCodable, JSONRPCError>>()
        Task { @MainActor in
            box.value = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/message", params: [
                "role": AnyCodable("user"),
                "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable(text)])]),
            ])
        }
        return box
    }

    /// `viewID`'s own pending `.mcpApp` request in the fake environment's
    /// dedicated inbox, or nil if there is none.
    private func pendingConsent(_ harness: Harness, viewID: UUID) -> ApprovalRequest? {
        harness.environment.inbox.pending.first { request in
            guard case .mcpApp(let requestViewID, _, _) = request.source else { return false }
            return requestViewID == viewID
        }
    }

    /// Reloads a view from `.waitingForApp` and waits for its new web view
    /// to load its document.
    private func reloadMountedView(_ harness: Harness, viewID: UUID) async throws {
        let oldBridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        await harness.store.reload(viewID: viewID)
        try await waitUntil(timeout: 10, "the reloaded view document loads") {
            harness.store.snapshot(viewID: viewID)?.status == .waitingForApp
                && harness.runtime.views[viewID]?.mounted?.bridge != nil
                && harness.runtime.views[viewID]?.mounted?.bridge !== oldBridge
        }
    }

    func test_openLink_pendingConsent_carriesTheViewsTitleAndTheURL_targetsItsSurface() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        let url = URL(string: "https://example.com/whatever")!

        let request = try requestOpenLink(harness, viewID: viewID, url: url.absoluteString)
        try await waitUntil("the open-link consent request is submitted") { self.pendingConsent(harness, viewID: viewID) != nil }

        let pending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        XCTAssertEqual(pending.targetSurfaceID, surfaceID, "the request targets the view's own surface")
        guard case .mcpApp(let requestViewID, let title, let kind) = pending.source else {
            return XCTFail("expected .mcpApp source, got \(pending.source)")
        }
        XCTAssertEqual(requestViewID, viewID)
        XCTAssertEqual(title, "Weather", "title is the invocation's serverDisplayName")
        XCTAssertEqual(kind, .openLink(url))

        harness.environment.inbox.decide(id: pending.id, .denied(.userRejected))
        try await waitUntil("the request ends") { request.value != nil }
        await harness.store.close(viewID: viewID)
    }

    func test_message_pendingConsent_foldsNewlinesInThePreview_andTargetsNoSurfaceWhenPaneless() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: nil)
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        let box = Box<Result<AnyCodable, JSONRPCError>>()
        Task { @MainActor in
            box.value = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/message", params: [
                "role": AnyCodable("user"),
                "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("line one\nline two")])]),
            ])
        }
        try await waitUntil("the message consent request is submitted") { self.pendingConsent(harness, viewID: viewID) != nil }

        let pending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        XCTAssertNil(pending.targetSurfaceID, "a pane-less view's request targets no surface")
        guard case .mcpApp(_, _, let kind) = pending.source else {
            return XCTFail("expected .mcpApp source, got \(pending.source)")
        }
        // A pane-less view has no pane to send to: this is the copy-only
        // kind, not .sendMessage -- its own newline-folding is covered by
        // test_paneless_uiMessage_submitsCopyMessageRequest below.
        XCTAssertEqual(kind, .copyMessage(text: "line one\nline two"))

        harness.environment.inbox.decide(id: pending.id, .denied(.userRejected))
        try await waitUntil("the request ends") { box.value != nil }
        await harness.store.close(viewID: viewID)
    }

    func test_message_pendingConsent_sendMessageKind_foldsNewlinesInThePreview() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        let box = Box<Result<AnyCodable, JSONRPCError>>()
        Task { @MainActor in
            box.value = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/message", params: [
                "role": AnyCodable("user"),
                "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable("line one\nline two")])]),
            ])
        }
        try await waitUntil("the message consent request is submitted") { self.pendingConsent(harness, viewID: viewID) != nil }

        let pending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        guard case .mcpApp(_, _, let kind) = pending.source, case .sendMessage(let preview) = kind else {
            return XCTFail("expected .mcpApp(.sendMessage) source, got \(pending.source)")
        }
        XCTAssertEqual(preview, "line one line two", "newlines in the preview must be folded to spaces")

        harness.environment.inbox.decide(id: pending.id, .denied(.userRejected))
        try await waitUntil("the request ends") { box.value != nil }
        await harness.store.close(viewID: viewID)
    }

    func test_openLink_allowedForView_opensLaterLinksWithoutANewSubmission_andAnotherViewStillPrompts() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let otherViewID = try await startMountedView(harness, surfaceID: UUID())
        let first = URL(string: "https://www.notion.so/help/guides?utm_source=app&n=learn_more")!
        let second = URL(string: "https://www.notion.so/pricing")!

        let firstRequest = try requestOpenLink(harness, viewID: viewID, url: first.absoluteString)
        try await waitUntil("the open-link request is pending") { self.pendingConsent(harness, viewID: viewID) != nil }
        XCTAssertTrue(harness.environment.openedLinks.isEmpty, "nothing opens before the user decides")
        let firstPending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        harness.environment.inbox.decide(id: firstPending.id, .allowedForView)
        try await waitUntil("the first request ends") { firstRequest.value != nil }
        guard case .success(let firstResult)? = firstRequest.value else {
            return XCTFail("expected success, got \(String(describing: firstRequest.value))")
        }
        XCTAssertNil(firstResult["isError"], "the link opened")
        XCTAssertEqual(harness.environment.openedLinks, [first])

        let notifyCountBeforeSecond = harness.environment.inbox._testNotifyCount
        let secondRequest = try requestOpenLink(harness, viewID: viewID, url: second.absoluteString)
        try await waitUntil("the second request ends without a new submission") { secondRequest.value != nil }
        XCTAssertEqual(harness.environment.openedLinks, [first, second])
        XCTAssertEqual(harness.environment.inbox._testNotifyCount, notifyCountBeforeSecond,
                       "an already-allowed-for-view link must never submit a new consent request")
        XCTAssertNil(pendingConsent(harness, viewID: viewID), "no request shows for an allowed view")

        let otherRequest = try requestOpenLink(harness, viewID: otherViewID, url: second.absoluteString)
        try await waitUntil("the other view prompts") { self.pendingConsent(harness, viewID: otherViewID) != nil }
        XCTAssertNil(otherRequest.value, "the other view's request waits for the user")
        XCTAssertEqual(harness.environment.openedLinks, [first, second])
        let otherPending = try XCTUnwrap(pendingConsent(harness, viewID: otherViewID))
        harness.environment.inbox.decide(id: otherPending.id, .denied(.userRejected))
        try await waitUntil("the other request ends") { otherRequest.value != nil }
        guard case .success(let otherResult)? = otherRequest.value else {
            return XCTFail("expected success, got \(String(describing: otherRequest.value))")
        }
        XCTAssertEqual(otherResult["isError"]?.boolValue, true, "denial opens nothing")
        XCTAssertEqual(harness.environment.openedLinks, [first, second])

        await harness.store.close(viewID: viewID)
        await harness.store.close(viewID: otherViewID)
    }

    func test_openLink_allowance_endsWhenTheViewIsRemoved() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        harness.runtime.openLinkPolicy.recordAlways(viewID: viewID)

        await harness.store.close(viewID: viewID)

        XCTAssertTrue(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID))
    }

    func test_openLink_secondPromptForSameView_expiresTheFirst() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!

        let firstRequest = try requestOpenLink(harness, viewID: viewID, url: first.absoluteString)
        try await waitUntil("the first request is pending") { self.pendingConsent(harness, viewID: viewID) != nil }

        let secondRequest = try requestOpenLink(harness, viewID: viewID, url: second.absoluteString)

        try await waitUntil("the first request ends") { firstRequest.value != nil }
        guard case .success(let firstResult)? = firstRequest.value else {
            return XCTFail("expected success, got \(String(describing: firstRequest.value))")
        }
        XCTAssertEqual(firstResult["isError"]?.boolValue, true, "the superseded first prompt resolves denied")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)

        let stillPending = harness.environment.inbox.pending.filter { request in
            guard case .mcpApp(let requestViewID, _, _) = request.source else { return false }
            return requestViewID == viewID
        }
        XCTAssertEqual(stillPending.count, 1, "only the second prompt remains pending")
        guard case .mcpApp(_, _, let kind) = stillPending.first?.source else {
            return XCTFail("expected .mcpApp source")
        }
        XCTAssertEqual(kind, .openLink(second))

        harness.environment.inbox.decide(id: stillPending[0].id, .denied(.userRejected))
        try await waitUntil("the second request ends") { secondRequest.value != nil }
        await harness.store.close(viewID: viewID)
    }

    func test_openLink_timesOutAfterConsentTimeoutMs_resolvesCancel_recordsNoGrant() async throws {
        let harness = makeHarness()
        harness.runtime.consentTimeoutMs = 50
        let viewID = try await startMountedView(harness, surfaceID: UUID())

        let request = try requestOpenLink(harness, viewID: viewID, url: "https://example.com/timeout")
        try await waitUntil("the prompt is pending") { self.pendingConsent(harness, viewID: viewID) != nil }

        try await waitUntil(timeout: 5, "the request times out") { request.value != nil }
        guard case .success(let result)? = request.value else {
            return XCTFail("expected success, got \(String(describing: request.value))")
        }
        XCTAssertEqual(result["isError"]?.boolValue, true, "a timed-out prompt opens nothing")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        XCTAssertNil(pendingConsent(harness, viewID: viewID))
        XCTAssertTrue(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID), "no grant is recorded")
        await harness.store.close(viewID: viewID)
    }

    // MARK: - "Always" grants last as long as the view, across a Reload

    func test_openLink_alwaysAllowForThisView_survivesAReloadOfTheView() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!

        let firstRequest = try requestOpenLink(harness, viewID: viewID, url: first.absoluteString)
        try await waitUntil("the open-link request is pending") { self.pendingConsent(harness, viewID: viewID) != nil }
        let firstPending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        harness.environment.inbox.decide(id: firstPending.id, .allowedForView)
        try await waitUntil("the first request ends") { firstRequest.value != nil }
        XCTAssertEqual(harness.environment.openedLinks, [first])

        try await reloadMountedView(harness, viewID: viewID)
        XCTAssertFalse(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID), "a reload keeps the view's allowance")

        let secondRequest = try requestOpenLink(harness, viewID: viewID, url: second.absoluteString)
        try await waitUntil("the second request ends without a new submission") { secondRequest.value != nil }
        guard case .success(let secondResult)? = secondRequest.value else {
            return XCTFail("expected success, got \(String(describing: secondRequest.value))")
        }
        XCTAssertNil(secondResult["isError"], "the link opened")
        XCTAssertEqual(harness.environment.openedLinks, [first, second])
        XCTAssertNil(pendingConsent(harness, viewID: viewID), "no request shows for an allowed view")
        await harness.store.close(viewID: viewID)
    }

    func test_message_alwaysForThisView_survivesAReloadOfTheView() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())

        let firstRequest = try requestMessage(harness, viewID: viewID, text: "first")
        try await waitUntil("the message request is pending") { self.pendingConsent(harness, viewID: viewID) != nil }
        let firstPending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        harness.environment.inbox.decide(id: firstPending.id, .allowedForView)
        try await waitUntil("the first request ends") { firstRequest.value != nil }
        XCTAssertEqual(harness.environment.recordingDelivery.deliveredTexts.count, 1, "the first message reached the pane")

        try await reloadMountedView(harness, viewID: viewID)
        XCTAssertFalse(harness.runtime.consentGate.requiresPrompt(viewID: viewID), "a reload keeps the view's approval")

        let secondRequest = try requestMessage(harness, viewID: viewID, text: "second")
        try await waitUntil("the second request ends without a new submission") { secondRequest.value != nil }
        guard case .success? = secondRequest.value else {
            return XCTFail("expected success, got \(String(describing: secondRequest.value))")
        }
        XCTAssertEqual(harness.environment.recordingDelivery.deliveredTexts.count, 2, "the second message reached the pane")
        XCTAssertNil(pendingConsent(harness, viewID: viewID), "no request shows for an approved view")
        await harness.store.close(viewID: viewID)
    }

    func test_closingAView_forgetsItsGrants_andANewViewForTheSameToolPrompts() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        harness.runtime.openLinkPolicy.recordAlways(viewID: viewID)
        harness.runtime.consentGate.recordAlways(viewID: viewID)

        await harness.store.close(viewID: viewID)
        try await waitUntil("the runtime drops the view") { harness.runtime.views[viewID] == nil }

        XCTAssertTrue(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID), "closing forgets the open-link allowance")
        XCTAssertTrue(harness.runtime.consentGate.requiresPrompt(viewID: viewID), "closing forgets the message approval")

        let newViewID = try await startMountedView(harness, surfaceID: surfaceID)
        let linkRequest = try requestOpenLink(harness, viewID: newViewID, url: "https://example.com/again")
        try await waitUntil("the new view's open-link request is pending") { self.pendingConsent(harness, viewID: newViewID) != nil }
        XCTAssertNil(linkRequest.value, "the new view's link waits for the user")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        let linkPending = try XCTUnwrap(pendingConsent(harness, viewID: newViewID))
        harness.environment.inbox.decide(id: linkPending.id, .denied(.userRejected))
        try await waitUntil("the link request ends") { linkRequest.value != nil }

        let messageRequest = try requestMessage(harness, viewID: newViewID, text: "again")
        try await waitUntil("the new view's message request is pending") { self.pendingConsent(harness, viewID: newViewID) != nil }
        XCTAssertNil(messageRequest.value, "the new view's message waits for the user")
        XCTAssertTrue(harness.environment.recordingDelivery.deliveredTexts.isEmpty)
        let messagePending = try XCTUnwrap(pendingConsent(harness, viewID: newViewID))
        harness.environment.inbox.decide(id: messagePending.id, .denied(.userRejected))
        try await waitUntil("the message request ends") { messageRequest.value != nil }
        await harness.store.close(viewID: newViewID)
    }

    // MARK: - reload / close / unmount / expireForSurface each deny a pending prompt

    func test_openLinkPromptPendingAtAReload_resolvesAsDenied() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let request = try requestOpenLink(harness, viewID: viewID, url: "https://example.com/pending")
        try await waitUntil("the open-link request is pending") { self.pendingConsent(harness, viewID: viewID) != nil }

        try await reloadMountedView(harness, viewID: viewID)

        try await waitUntil("the pending request ends") { request.value != nil }
        guard case .success(let result)? = request.value else {
            return XCTFail("expected success, got \(String(describing: request.value))")
        }
        XCTAssertEqual(result["isError"]?.boolValue, true, "the prompt of the unloaded document opens nothing")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        XCTAssertNil(pendingConsent(harness, viewID: viewID), "the request is gone")
        XCTAssertTrue(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID), "nothing was allowed")
        await harness.store.close(viewID: viewID)
    }

    /// The user answers "Always Allow for This View", and a Reload unmounts
    /// the document before the request's handler resumes.
    func test_openLink_alwaysChosenJustBeforeAReload_opensNothing_andRecordsNoGrant() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let oldBridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        let request = try requestOpenLink(harness, viewID: viewID, url: "https://example.com/stale")
        try await waitUntil("the open-link request is pending") { self.pendingConsent(harness, viewID: viewID) != nil }

        // No suspension between the decision and the Reload's unmount: the
        // handler resumes only after the document is gone.
        let pending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        harness.environment.inbox.decide(id: pending.id, .allowedForView)
        XCTAssertNil(request.value, "precondition: the handler has not resumed yet")
        await harness.store.reload(viewID: viewID)

        try await waitUntil("the stale request ends") { request.value != nil }
        guard case .success(let result)? = request.value else {
            return XCTFail("expected success, got \(String(describing: request.value))")
        }
        XCTAssertEqual(result["isError"]?.boolValue, true, "the unloaded document's link opens nothing")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        XCTAssertTrue(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID), "no grant is recorded")

        try await waitUntil(timeout: 10, "the reloaded view document loads") {
            harness.store.snapshot(viewID: viewID)?.status == .waitingForApp
                && harness.runtime.views[viewID]?.mounted?.bridge != nil
                && harness.runtime.views[viewID]?.mounted?.bridge !== oldBridge
        }
        let later = try requestOpenLink(harness, viewID: viewID, url: "https://example.com/later")
        try await waitUntil("the later link prompts") { self.pendingConsent(harness, viewID: viewID) != nil }
        XCTAssertNil(later.value, "the later link waits for the user")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        let laterPending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        harness.environment.inbox.decide(id: laterPending.id, .denied(.userRejected))
        try await waitUntil("the later request ends") { later.value != nil }
        await harness.store.close(viewID: viewID)
    }

    func test_messagePromptPendingAtAReload_resolvesAsDenied() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let request = try requestMessage(harness, viewID: viewID, text: "pending")
        try await waitUntil("the message prompt is pending") { harness.runtime.consentGate.isPending(viewID: viewID) }

        try await reloadMountedView(harness, viewID: viewID)

        try await waitUntil("the pending request ends") { request.value != nil }
        guard case .failure(let error)? = request.value else {
            return XCTFail("expected the message request to fail, got \(String(describing: request.value))")
        }
        XCTAssertEqual(error.code, -32000)
        XCTAssertEqual(error.message, "Message sending denied")
        XCTAssertTrue(harness.environment.recordingDelivery.deliveredTexts.isEmpty, "nothing reaches the pane")
        XCTAssertNil(pendingConsent(harness, viewID: viewID), "the request is gone")
        XCTAssertTrue(harness.runtime.consentGate.requiresPrompt(viewID: viewID), "nothing was approved")
        await harness.store.close(viewID: viewID)
    }

    private enum Teardown: CustomStringConvertible {
        case close, unmount, expireForSurface
        var description: String {
            switch self {
            case .close: return "close"
            case .unmount: return "unmount"
            case .expireForSurface: return "expireForSurface"
            }
        }
    }

    /// close/unmount/expireForSurface each deny a pending `ui/open-link`
    /// prompt without opening anything or recording a grant. All three
    /// resolve `.success({isError:true})`: close/unmount go through
    /// `denyPendingPrompts` (which bumps `documentGeneration`, so
    /// `isCurrentDocument` fails once the handler resumes); expireForSurface
    /// does not bump it, but its `.expired` decision maps to `.cancel`,
    /// which the handler turns into the same success/isError result.
    func test_closeUnmountExpireForSurface_eachDenyThePendingOpenLinkPrompt_recordingNoGrant() async throws {
        for teardown in [Teardown.close, .unmount, .expireForSurface] {
            let harness = makeHarness()
            let surfaceID = UUID()
            let viewID = try await startMountedView(harness, surfaceID: surfaceID)
            let request = try requestOpenLink(harness, viewID: viewID, url: "https://example.com/\(teardown)")
            try await waitUntil("[\(teardown)] the open-link prompt is pending") {
                self.pendingConsent(harness, viewID: viewID) != nil
            }

            switch teardown {
            case .close:
                await harness.store.close(viewID: viewID)
            case .unmount:
                harness.runtime.unmount(viewID: viewID)
            case .expireForSurface:
                harness.environment.inbox.expireForSurface(surfaceID)
            }

            try await waitUntil("[\(teardown)] the request ends") { request.value != nil }
            guard case .success(let result)? = request.value else {
                XCTFail("[\(teardown)] expected success, got \(String(describing: request.value))")
                continue
            }
            XCTAssertEqual(result["isError"]?.boolValue, true, "[\(teardown)] opens nothing")
            XCTAssertTrue(harness.environment.openedLinks.isEmpty, "[\(teardown)]")
            XCTAssertNil(pendingConsent(harness, viewID: viewID), "[\(teardown)] no pending request remains")
            XCTAssertTrue(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID), "[\(teardown)] no grant recorded")

            await harness.store.close(viewID: viewID)
        }
    }

    /// close/unmount deny a pending `ui/message` prompt the same way an
    /// unloading Reload does: `denyPendingPrompts` bumps `documentGeneration`
    /// before the handler resumes, so `isCurrentDocument` fails and the
    /// handler fails with -32000, same as `test_messagePromptPendingAtAReload_resolvesAsDenied`.
    func test_closeUnmount_eachDenyThePendingMessagePrompt() async throws {
        for teardown in [Teardown.close, .unmount] {
            let harness = makeHarness()
            let surfaceID = UUID()
            let viewID = try await startMountedView(harness, surfaceID: surfaceID)
            let request = try requestMessage(harness, viewID: viewID, text: "pending-\(teardown)")
            try await waitUntil("[\(teardown)] the message prompt is pending") { harness.runtime.consentGate.isPending(viewID: viewID) }

            switch teardown {
            case .close:
                await harness.store.close(viewID: viewID)
            case .unmount:
                harness.runtime.unmount(viewID: viewID)
            case .expireForSurface:
                XCTFail("expireForSurface has its own, separate test: it behaves differently")
            }

            try await waitUntil("[\(teardown)] the request ends") { request.value != nil }
            guard case .failure(let error)? = request.value else {
                XCTFail("[\(teardown)] expected failure, got \(String(describing: request.value))")
                continue
            }
            XCTAssertEqual(error.code, -32000, "[\(teardown)]")
            XCTAssertEqual(error.message, "Message sending denied", "[\(teardown)]")
            XCTAssertTrue(harness.environment.recordingDelivery.deliveredTexts.isEmpty, "[\(teardown)]")
            XCTAssertTrue(harness.runtime.consentGate.requiresPrompt(viewID: viewID), "[\(teardown)] nothing approved")

            await harness.store.close(viewID: viewID)
        }
    }

    /// Unlike close/unmount/Reload, `expireForSurface` does not unload the
    /// document (`documentGeneration` is untouched) -- the handler's own
    /// `.expired` -> `.dontSend` outcome resolves it, not the
    /// `isCurrentDocument` guard, so the result is `.success({isError:true})`,
    /// not the -32000 failure the other three produce.
    func test_expireForSurface_deniesThePendingMessagePrompt_withoutBumpingGeneration() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        let request = try requestMessage(harness, viewID: viewID, text: "pending")
        try await waitUntil("the message prompt is pending") { harness.runtime.consentGate.isPending(viewID: viewID) }

        harness.environment.inbox.expireForSurface(surfaceID)

        try await waitUntil("the request ends") { request.value != nil }
        guard case .success(let result)? = request.value else {
            return XCTFail("expected success, got \(String(describing: request.value))")
        }
        XCTAssertEqual(result["isError"]?.boolValue, true)
        XCTAssertTrue(harness.environment.recordingDelivery.deliveredTexts.isEmpty)
        XCTAssertTrue(harness.runtime.consentGate.requiresPrompt(viewID: viewID))
        await harness.store.close(viewID: viewID)
    }

    // MARK: - Pane-less ui/message: a copy-only consent request

    func test_paneless_uiMessage_submitsCopyMessageRequest_allowedWritesThePasteboard() async throws {
        NSPasteboard.general.clearContents()
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: nil)
        let text = "hello copy"

        let request = try requestMessage(harness, viewID: viewID, text: text)

        try await waitUntil("the handler returns immediately, without waiting for a decision") { request.value != nil }
        guard case .failure(let error)? = request.value else {
            return XCTFail("expected failure, got \(String(describing: request.value))")
        }
        XCTAssertEqual(error.code, -32000)
        XCTAssertEqual(error.message, "This view has no pane to send the message to.")

        try await waitUntil("the copy-message consent request is submitted") { self.pendingConsent(harness, viewID: viewID) != nil }
        let pending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))
        XCTAssertNil(pending.targetSurfaceID, "a pane-less view's request targets no surface")
        guard case .mcpApp(_, _, let kind) = pending.source, case .copyMessage(let pastedText) = kind else {
            return XCTFail("expected .mcpApp(.copyMessage) source, got \(pending.source)")
        }
        XCTAssertEqual(pastedText, text)

        harness.environment.inbox.decide(id: pending.id, .allowed)

        try await waitUntil("the pasteboard receives the text") { NSPasteboard.general.string(forType: .string) == text }
        await harness.store.close(viewID: viewID)
    }

    func test_paneless_uiMessage_denied_doesNotWriteThePasteboard() async throws {
        NSPasteboard.general.clearContents()
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: nil)

        let request = try requestMessage(harness, viewID: viewID, text: "not copied")
        try await waitUntil("the handler returns") { request.value != nil }
        try await waitUntil("the copy-message consent request is submitted") { self.pendingConsent(harness, viewID: viewID) != nil }
        let pending = try XCTUnwrap(pendingConsent(harness, viewID: viewID))

        harness.environment.inbox.decide(id: pending.id, .denied(.userRejected))

        try await waitUntil("the request is no longer pending") { self.pendingConsent(harness, viewID: viewID) == nil }
        // Give the detached Task a moment to (not) write.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(NSPasteboard.general.string(forType: .string), "a denied copy-message request must not write the pasteboard")
        await harness.store.close(viewID: viewID)
    }

    // MARK: - K55: the dock's size is the host's, not the view's

    func test_sizeChanged_doesNotResizeTheDock() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        harness.environment.containers[surfaceID] = container
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        let dock = try XCTUnwrap(container.dockView(forLeaf: surfaceID), "precondition: the view is docked")
        let dockFrame = dock.frame
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)

        for size in [["width": 100.0, "height": 50.0], ["width": 700.0, "height": 580.0], ["height": 90.0]] {
            harness.runtime.bridge(bridge, didReceiveNotification: "ui/notifications/size-changed",
                                   params: size.mapValues { AnyCodable($0) })
            container.layoutSubtreeIfNeeded()
            XCTAssertEqual(dock.frame, dockFrame, "size-changed \(size) leaves the dock as it was")
        }
        await harness.store.close(viewID: viewID)
    }

    func test_hostContext_reportsTheDocksSize_andFollowsADrag() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        harness.environment.containers[surfaceID] = container
        let viewID = try await startCardOnlyView(harness, surfaceID: surfaceID)

        let before = try XCTUnwrap(harness.runtime.hostEnvironment(for: viewID)).containerDimensions
        XCTAssertEqual(before, MCPAppDockLayout.ContainerDimensions(
            width: 320, height: Double(600 - MCPAppViewPane.headerHeight), maxWidth: nil, maxHeight: nil
        ))

        let divider = try XCTUnwrap(container.subviews.compactMap { $0 as? SplitDividerView }.first)
        divider._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))

        let after = try XCTUnwrap(harness.runtime.hostEnvironment(for: viewID)).containerDimensions
        XCTAssertEqual(after.width, 200)
        XCTAssertEqual(after.height, Double(600 - MCPAppViewPane.headerHeight))
    }

    func test_draggingTheDockDivider_sendsTheNewWidthToAnInitializedView() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        harness.environment.containers[surfaceID] = container
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        _ = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/initialize", params: [
            "protocolVersion": AnyCodable("2026-01-26"),
            "appCapabilities": AnyCodable([String: AnyCodable]()),
        ])
        container.layoutSubtreeIfNeeded()
        let reportedWidth = { harness.runtime.views[viewID]?.lastHostContext["containerDimensions"]?["width"]?.doubleValue }
        XCTAssertEqual(reportedWidth(), 320, "precondition: initialize reported the default dock width")

        let divider = try XCTUnwrap(container.subviews.compactMap { $0 as? SplitDividerView }.first)
        divider._testSimulateDrag(toSuperviewPoint: NSPoint(x: 600, y: 300))
        container.layoutSubtreeIfNeeded()

        XCTAssertEqual(reportedWidth(), 200, "the card's new size reaches the view's host context")
        await harness.store.close(viewID: viewID)
    }

    func test_hostContext_reportsThePanesSize_whileTheDockIsNotLaidOut() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let registry = SurfaceRegistry()
        registry._testInsert(view: SurfaceView(frame: .zero), id: surfaceID)
        // A zero-bounds container lays nothing out, so the dock keeps a zero frame.
        let container = SplitContainerView(registry: registry)
        container.updateLayout(tree: tree([surfaceID]))
        harness.environment.containers[surfaceID] = container
        let viewID = try await startCardOnlyView(harness, surfaceID: surfaceID)
        let dock = try XCTUnwrap(container.dockView(forLeaf: surfaceID))
        XCTAssertEqual(dock.frame.size, .zero, "precondition: the dock is not laid out")
        let pane = try XCTUnwrap(harness.runtime.views[viewID]?.pane)
        pane.frame = NSRect(x: 0, y: 0, width: 300, height: 400)

        let dimensions = try XCTUnwrap(harness.runtime.hostEnvironment(for: viewID)).containerDimensions

        XCTAssertEqual(dimensions.width, 300)
        XCTAssertEqual(dimensions.height, Double(400 - MCPAppViewPane.headerHeight))
    }

    func test_hostContext_leavesOutTheSwitcher_whenTheDockShowsTwoViews() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        harness.environment.containers[surfaceID] = container
        let viewID = try await startCardOnlyView(harness, surfaceID: surfaceID)
        _ = try await startCardOnlyView(harness, surfaceID: surfaceID)

        let dimensions = try XCTUnwrap(harness.runtime.hostEnvironment(for: viewID)).containerDimensions
        XCTAssertEqual(dimensions.width, 320)
        XCTAssertEqual(dimensions.height, Double(600 - MCPAppDockView.switcherHeight - MCPAppViewPane.headerHeight))
    }

    // MARK: - Finding 1: a mount the store no longer wants builds nothing

    func test_mountOfAViewTheStoreDoesNotHave_throws_andRemovesItsRuleList() async throws {
        let harness = makeHarness()
        let viewID = UUID()
        let hostOrigin = "\(MCPAppWebViewFactory.hostScheme)://\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        let viewOrigin = "\(MCPAppWebViewFactory.appScheme)://\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        let identifier = MCPAppWebViewFactory.contentRuleListIdentifierPrefix + viewID.uuidString
        let document = MCPAppViewDocument(
            html: "<!DOCTYPE html><html></html>",
            viewOrigin: viewOrigin,
            hostOrigin: hostOrigin,
            cspPolicy: MCPAppCSPBuilder.buildPolicy(csp: nil, hostOrigin: hostOrigin).policy,
            contentRuleListJSON: MCPAppCSPBuilder.contentRuleList(csp: nil, hostOrigin: hostOrigin, calyxOrigins: [viewOrigin]),
            contentRuleListIdentifier: identifier
        )

        do {
            try await harness.runtime.mount(viewID: viewID, document: document)
            XCTFail("mounting a view the store does not list must throw")
        } catch {}

        XCTAssertNil(harness.runtime.views[viewID], "no card or web view is built")
        let identifiers = await WKContentRuleListStore.default().availableIdentifiers() ?? []
        XCTAssertFalse(identifiers.contains(identifier), "the compiled rule list is removed")
    }
}

// MARK: - The card is just header + web view: no inline consent prompt
// area survives (that moved to the approval panel -- see
// MCPAppWebViewRuntimeTests above).

@MainActor
final class MCPAppViewPanePromptTests: XCTestCase {

    func test_webView_fillsTheCardBelowTheHeader() {
        let pane = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        let webView = WKWebView(frame: .zero)
        pane.setWebView(webView)
        pane.frame = NSRect(x: 0, y: 0, width: 320, height: 600)

        pane.layoutSubtreeIfNeeded()

        XCTAssertEqual(webView.frame.width, 320, accuracy: 0.5)
        XCTAssertEqual(webView.frame.height, 600 - MCPAppViewPane.headerHeight, accuracy: 0.5,
            "the web view takes the whole card below the header")
        XCTAssertEqual(pane.contentTopInset, MCPAppViewPane.headerHeight,
            "contentTopInset is just the header's height -- there is no consent prompt area to add anymore")
    }
}
