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
//  the dock, and the host context reports the dock's size. The reported
//  height leaves out a shown consent prompt, and showing or hiding one
//  sends `host-context-changed` (K60). A `ui/open-link` the user allows
//  "Always Allow for This View" opens later links from that view without
//  a prompt, while another view still prompts. The "Always" grants of
//  `ui/open-link` and `ui/message` survive a Reload of the view and end
//  when the view is closed; a prompt pending at a Reload resolves as
//  denied, and an answer that arrives after the Reload unmounted the
//  document opens nothing and allows nothing.
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

/// Records every message the store sends to a view, then passes it to
/// the web view runtime.
@MainActor
private final class SendRecordingRuntime: MCPAppViewRuntime {
    let inner: MCPAppWebViewRuntime
    private(set) var sent: [(viewID: UUID, message: JSONRPCMessage)] = []

    init(inner: MCPAppWebViewRuntime) {
        self.inner = inner
    }

    func mount(viewID: UUID, document: MCPAppViewDocument) async throws {
        try await inner.mount(viewID: viewID, document: document)
    }

    func send(_ message: JSONRPCMessage, to viewID: UUID) async throws -> JSONRPCMessage? {
        sent.append((viewID, message))
        return try await inner.send(message, to: viewID)
    }

    func unmount(viewID: UUID) {
        inner.unmount(viewID: viewID)
    }

    func requestTeardown(viewID: UUID) async {
        await inner.requestTeardown(viewID: viewID)
    }

    /// The `containerDimensions.height` of each `host-context-changed` sent to `viewID`, in order.
    func hostContextChangedHeights(viewID: UUID) -> [Double?] {
        sent.compactMap { entry -> Double?? in
            guard entry.viewID == viewID,
                  case .notification(let method, let params) = entry.message,
                  method == "ui/notifications/host-context-changed",
                  let dimensions = params?["containerDimensions"] else { return nil }
            return .some(dimensions["height"]?.doubleValue)
        }
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

/// The prompt buttons under `view`, in view order.
@MainActor
private func actionButtons(in view: NSView) -> [MCPAppActionButton] {
    view.subviews.flatMap { subview -> [MCPAppActionButton] in
        (subview as? MCPAppActionButton).map { [$0] } ?? actionButtons(in: subview)
    }
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

    /// A harness whose store sends through a `SendRecordingRuntime`.
    private func makeRecordingHarness() -> (harness: Harness, recorder: SendRecordingRuntime) {
        let environment = FakeRuntimeEnvironment()
        let runtime = MCPAppWebViewRuntime(environment: environment)
        let recorder = SendRecordingRuntime(inner: runtime)
        let store = MCPAppHostStore(paneResolver: NoPaneResolver(), runtime: recorder, appToolRegistry: FakeAppToolRegistry())
        runtime.store = store
        return (Harness(runtime: runtime, store: store, environment: environment), recorder)
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
    private func startCardOnlyView(_ harness: Harness, surfaceID: UUID) async throws -> UUID {
        let session = FakeMCPAppServerSession(readResourceResult: .failure(FakeSessionError(message: "unreadable")))
        let inv = try invocation(serverID: session.serverID, surfaceID: surfaceID)
        await harness.store.uiToolInvocationDidStart(inv, session: session)
        await harness.store.resourceLoad(forView: inv.id.rawValue)?.value
        return inv.id.rawValue
    }

    /// A view whose web view loaded its document.
    private func startMountedView(_ harness: Harness, surfaceID: UUID) async throws -> UUID {
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

    // MARK: - ui/open-link: "Always Allow for This View"

    private func requestOpenLink(_ harness: Harness, viewID: UUID, url: String) throws -> Box<Result<AnyCodable, JSONRPCError>> {
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        let box = Box<Result<AnyCodable, JSONRPCError>>()
        Task { @MainActor in
            box.value = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/open-link", params: ["url": AnyCodable(url)])
        }
        return box
    }

    private func promptButton(_ harness: Harness, viewID: UUID, identifier: String) -> MCPAppActionButton? {
        guard let pane = harness.runtime.views[viewID]?.pane else { return nil }
        return actionButtons(in: pane).first { $0.accessibilityIdentifier() == identifier }
    }

    func test_openLink_alwaysAllowForThisView_opensLaterLinksWithoutAPrompt_andAnotherViewStillPrompts() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let otherViewID = try await startMountedView(harness, surfaceID: UUID())
        let first = URL(string: "https://www.notion.so/help/guides?utm_source=app&n=learn_more")!
        let second = URL(string: "https://www.notion.so/pricing")!

        let firstRequest = try requestOpenLink(harness, viewID: viewID, url: first.absoluteString)
        try await waitUntil("the open-link prompt shows") {
            self.promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton) != nil
        }
        XCTAssertTrue(harness.environment.openedLinks.isEmpty, "nothing opens before the user chooses")
        try XCTUnwrap(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton)).performClick(nil)
        try await waitUntil("the first request ends") { firstRequest.value != nil }
        guard case .success(let firstResult)? = firstRequest.value else {
            return XCTFail("expected success, got \(String(describing: firstRequest.value))")
        }
        XCTAssertNil(firstResult["isError"], "the link opened")
        XCTAssertEqual(harness.environment.openedLinks, [first])

        let secondRequest = try requestOpenLink(harness, viewID: viewID, url: second.absoluteString)
        try await waitUntil("the second request ends without a prompt") { secondRequest.value != nil }
        XCTAssertEqual(harness.environment.openedLinks, [first, second])
        XCTAssertNil(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptPrimaryButton),
                     "no prompt shows for an allowed view")

        let otherRequest = try requestOpenLink(harness, viewID: otherViewID, url: second.absoluteString)
        try await waitUntil("the other view prompts") {
            self.promptButton(harness, viewID: otherViewID, identifier: AccessibilityID.MCPApps.promptPrimaryButton) != nil
        }
        XCTAssertNil(otherRequest.value, "the other view's request waits for the user")
        XCTAssertEqual(harness.environment.openedLinks, [first, second])
        try XCTUnwrap(promptButton(harness, viewID: otherViewID, identifier: AccessibilityID.MCPApps.promptCancelButton)).performClick(nil)
        try await waitUntil("the other request ends") { otherRequest.value != nil }
        guard case .success(let otherResult)? = otherRequest.value else {
            return XCTFail("expected success, got \(String(describing: otherRequest.value))")
        }
        XCTAssertEqual(otherResult["isError"]?.boolValue, true, "Cancel opens nothing")
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

    // MARK: - "Always" grants last as long as the view, across a Reload

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

    func test_openLink_alwaysAllowForThisView_survivesAReloadOfTheView() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!

        let firstRequest = try requestOpenLink(harness, viewID: viewID, url: first.absoluteString)
        try await waitUntil("the open-link prompt shows") {
            self.promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton) != nil
        }
        try XCTUnwrap(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton)).performClick(nil)
        try await waitUntil("the first request ends") { firstRequest.value != nil }
        XCTAssertEqual(harness.environment.openedLinks, [first])

        try await reloadMountedView(harness, viewID: viewID)
        XCTAssertFalse(harness.runtime.openLinkPolicy.requiresPrompt(viewID: viewID), "a reload keeps the view's allowance")

        let secondRequest = try requestOpenLink(harness, viewID: viewID, url: second.absoluteString)
        try await waitUntil("the second request ends without a prompt") { secondRequest.value != nil }
        guard case .success(let secondResult)? = secondRequest.value else {
            return XCTFail("expected success, got \(String(describing: secondRequest.value))")
        }
        XCTAssertNil(secondResult["isError"], "the link opened")
        XCTAssertEqual(harness.environment.openedLinks, [first, second])
        XCTAssertNil(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptPrimaryButton),
                     "no prompt shows for an allowed view")
        await harness.store.close(viewID: viewID)
    }

    func test_message_alwaysForThisView_survivesAReloadOfTheView() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())

        let firstRequest = try requestMessage(harness, viewID: viewID, text: "first")
        try await waitUntil("the message prompt shows") {
            self.promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton) != nil
        }
        try XCTUnwrap(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton)).performClick(nil)
        try await waitUntil("the first request ends") { firstRequest.value != nil }
        XCTAssertEqual(harness.environment.recordingDelivery.deliveredTexts.count, 1, "the first message reached the pane")

        try await reloadMountedView(harness, viewID: viewID)
        XCTAssertFalse(harness.runtime.consentGate.requiresPrompt(viewID: viewID), "a reload keeps the view's approval")

        let secondRequest = try requestMessage(harness, viewID: viewID, text: "second")
        try await waitUntil("the second request ends without a prompt") { secondRequest.value != nil }
        guard case .success? = secondRequest.value else {
            return XCTFail("expected success, got \(String(describing: secondRequest.value))")
        }
        XCTAssertEqual(harness.environment.recordingDelivery.deliveredTexts.count, 2, "the second message reached the pane")
        XCTAssertNil(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptPrimaryButton),
                     "no prompt shows for an approved view")
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
        try await waitUntil("the new view's open-link prompt shows") {
            self.promptButton(harness, viewID: newViewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton) != nil
        }
        XCTAssertNil(linkRequest.value, "the new view's link waits for the user")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        try XCTUnwrap(promptButton(harness, viewID: newViewID, identifier: AccessibilityID.MCPApps.promptCancelButton)).performClick(nil)
        try await waitUntil("the link request ends") { linkRequest.value != nil }

        let messageRequest = try requestMessage(harness, viewID: newViewID, text: "again")
        try await waitUntil("the new view's message prompt shows") {
            harness.runtime.consentGate.isPending(viewID: newViewID)
        }
        XCTAssertNil(messageRequest.value, "the new view's message waits for the user")
        XCTAssertTrue(harness.environment.recordingDelivery.deliveredTexts.isEmpty)
        try XCTUnwrap(promptButton(harness, viewID: newViewID, identifier: AccessibilityID.MCPApps.promptCancelButton)).performClick(nil)
        try await waitUntil("the message request ends") { messageRequest.value != nil }
        await harness.store.close(viewID: newViewID)
    }

    func test_openLinkPromptPendingAtAReload_resolvesAsDenied() async throws {
        let harness = makeHarness()
        let viewID = try await startMountedView(harness, surfaceID: UUID())
        let request = try requestOpenLink(harness, viewID: viewID, url: "https://example.com/pending")
        try await waitUntil("the open-link prompt shows") {
            self.promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton) != nil
        }

        try await reloadMountedView(harness, viewID: viewID)

        try await waitUntil("the pending request ends") { request.value != nil }
        guard case .success(let result)? = request.value else {
            return XCTFail("expected success, got \(String(describing: request.value))")
        }
        XCTAssertEqual(result["isError"]?.boolValue, true, "the prompt of the unloaded document opens nothing")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        XCTAssertNil(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton),
                     "the prompt is gone")
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
        try await waitUntil("the open-link prompt shows") {
            self.promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton) != nil
        }

        // No suspension between the click and the Reload's unmount: the
        // handler resumes only after the document is gone.
        try XCTUnwrap(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton)).performClick(nil)
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
        try await waitUntil("the later link prompts") {
            self.promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptPrimaryButton) != nil
        }
        XCTAssertNil(later.value, "the later link waits for the user")
        XCTAssertTrue(harness.environment.openedLinks.isEmpty)
        try XCTUnwrap(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptCancelButton)).performClick(nil)
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
        XCTAssertNil(promptButton(harness, viewID: viewID, identifier: AccessibilityID.MCPApps.promptAllowForViewButton),
                     "the prompt is gone")
        XCTAssertTrue(harness.runtime.consentGate.requiresPrompt(viewID: viewID), "nothing was approved")
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

    // MARK: - The consent prompt takes height from the web view

    func test_hostContext_heightShrinksWhileAPromptShows_andReturnsAfterItHides() async throws {
        let harness = makeHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        harness.environment.containers[surfaceID] = container
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        container.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(harness.runtime.views[viewID]?.pane)
        let webView = try XCTUnwrap(pane.webView)
        let fullHeight = Double(600 - MCPAppViewPane.headerHeight)
        XCTAssertEqual(try XCTUnwrap(harness.runtime.hostEnvironment(for: viewID)).containerDimensions.height, fullHeight,
                       "precondition: no prompt")

        pane.showCopyOnly(text: "hello")

        let promptHeight = try XCTUnwrap(try XCTUnwrap(harness.runtime.hostEnvironment(for: viewID)).containerDimensions.height)
        XCTAssertLessThan(promptHeight, fullHeight, "the prompt sits between the header and the web view")
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(Double(webView.frame.height), promptHeight, accuracy: 0.5, "the reported height is the web view's height")

        pane.dismissPrompt()

        XCTAssertEqual(try XCTUnwrap(harness.runtime.hostEnvironment(for: viewID)).containerDimensions.height, fullHeight)
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(Double(webView.frame.height), fullHeight, accuracy: 0.5)
        await harness.store.close(viewID: viewID)
    }

    func test_showingAndHidingAPrompt_sendsHostContextChangedToAnInitializedView() async throws {
        let (harness, recorder) = makeRecordingHarness()
        let surfaceID = UUID()
        let (container, _) = makeContainer(leaves: [surfaceID])
        harness.environment.containers[surfaceID] = container
        let viewID = try await startMountedView(harness, surfaceID: surfaceID)
        let bridge = try XCTUnwrap(harness.runtime.views[viewID]?.mounted?.bridge)
        _ = await harness.runtime.bridge(bridge, didReceiveRequest: "ui/initialize", params: [
            "protocolVersion": AnyCodable("2026-01-26"),
            "appCapabilities": AnyCodable([String: AnyCodable]()),
        ])
        harness.runtime.bridge(bridge, didReceiveNotification: "ui/notifications/initialized", params: nil)
        container.layoutSubtreeIfNeeded()
        let pane = try XCTUnwrap(harness.runtime.views[viewID]?.pane)
        let fullHeight = Double(600 - MCPAppViewPane.headerHeight)
        let before = recorder.hostContextChangedHeights(viewID: viewID).count

        pane.showCopyOnly(text: "hello")

        try await waitUntil("host-context-changed follows the prompt") {
            recorder.hostContextChangedHeights(viewID: viewID).count == before + 1
        }
        let shownHeight = try XCTUnwrap(recorder.hostContextChangedHeights(viewID: viewID).last ?? nil)
        XCTAssertLessThan(shownHeight, fullHeight)

        pane.dismissPrompt()

        try await waitUntil("host-context-changed follows the prompt's dismissal") {
            recorder.hostContextChangedHeights(viewID: viewID).count == before + 2
        }
        XCTAssertEqual(recorder.hostContextChangedHeights(viewID: viewID).last, fullHeight)
        await harness.store.close(viewID: viewID)
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

// MARK: - Finding 7: the ui/message consent prompt shows the whole message;
// the ui/open-link prompt shows a lead line, the whole link, and three choices

@MainActor
final class MCPAppViewPanePromptTests: XCTestCase {

    private func textViews(in view: NSView) -> [NSTextView] {
        view.subviews.flatMap { subview -> [NSTextView] in
            (subview as? NSTextView).map { [$0] } ?? textViews(in: subview)
        }
    }

    func test_messagePrompt_showsTheFullTextInAScrollableReadOnlyTextView() async throws {
        let pane = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        let preview = (1...40).map { "line \($0) of the message" }.joined(separator: "\n")
        let task = Task { @MainActor in await pane.promptForMessage(preview: preview) }

        let deadline = Date().addingTimeInterval(2)
        while textViews(in: pane).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let textView = try XCTUnwrap(textViews(in: pane).first, "the prompt shows its text in a text view")
        XCTAssertTrue(textView.string.hasSuffix(preview), "every line of the message is in the prompt")
        XCTAssertFalse(textView.isEditable)
        XCTAssertNotNil(textView.enclosingScrollView, "a long message scrolls inside the card")

        pane.dismissPrompt()
        let decision = await task.value
        XCTAssertEqual(decision, .dontSend)
    }

    // MARK: - ui/open-link prompt

    /// A Notion-style link: long enough to wrap over several lines in a card.
    private let longLink = URL(string: "https://www.notion.so/help/guides/connect-your-tools-to-notion-with-mcp-apps?utm_source=notion-card&utm_medium=mcp-app&utm_campaign=connected-apps&utm_content=learn-more-link&n=learn_more")!

    private func waitForTextView(in pane: MCPAppViewPane) async throws -> NSTextView {
        let deadline = Date().addingTimeInterval(2)
        while textViews(in: pane).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(textViews(in: pane).first, "the prompt shows its text in a text view")
    }

    private func promptButtons(in view: NSView) -> [MCPAppActionButton] {
        view.subviews.flatMap { subview -> [MCPAppActionButton] in
            (subview as? MCPAppActionButton).map { [$0] } ?? promptButtons(in: subview)
        }
    }

    /// Asserts the text view shows the link's head (scheme and host) inside
    /// the scroll view's visible area, and no line is wider than that area.
    private func assertLinkHeadIsVisible(_ textView: NSTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let scrollView = try XCTUnwrap(textView.enclosingScrollView, file: file, line: line)
        let layoutManager = try XCTUnwrap(textView.layoutManager, file: file, line: line)
        let container = try XCTUnwrap(textView.textContainer, file: file, line: line)
        layoutManager.ensureLayout(for: container)
        let visibleWidth = scrollView.contentView.bounds.width
        XCTAssertGreaterThan(visibleWidth, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(textView.frame.width, visibleWidth + 0.5,
                                 "the text is not wider than the card", file: file, line: line)
        XCTAssertLessThanOrEqual(layoutManager.usedRect(for: container).width, visibleWidth + 0.5,
                                 "every line wraps inside the card", file: file, line: line)
        let hostRange = (textView.string as NSString).range(of: "https://www.notion.so")
        XCTAssertNotEqual(hostRange.location, NSNotFound, file: file, line: line)
        let glyphs = layoutManager.glyphRange(forCharacterRange: hostRange, actualCharacterRange: nil)
        let hostRect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        XCTAssertTrue(scrollView.documentVisibleRect.insetBy(dx: -0.5, dy: -0.5).contains(hostRect),
                      "the link's scheme and host are in view: host \(hostRect), visible \(scrollView.documentVisibleRect)",
                      file: file, line: line)
    }

    func test_openLinkPrompt_showsTheLeadLine_theFullLink_andThreeButtons() async throws {
        let pane = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        let task = Task { @MainActor in await pane.promptForLink(self.longLink) }

        let textView = try await waitForTextView(in: pane)
        XCTAssertEqual(textView.string, "The app wants to open this link:\n" + longLink.absoluteString)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertNotNil(textView.enclosingScrollView, "a long link scrolls inside the card")
        let buttons = promptButtons(in: pane)
        XCTAssertEqual(buttons.map(\.title), ["Open", "Always Allow for This View", "Cancel"])
        XCTAssertEqual(buttons.map { $0.accessibilityIdentifier() }, [
            AccessibilityID.MCPApps.promptPrimaryButton,
            AccessibilityID.MCPApps.promptAllowForViewButton,
            AccessibilityID.MCPApps.promptCancelButton,
        ])

        buttons[1].performClick(nil)
        let decision = await task.value
        XCTAssertEqual(decision, .alwaysForThisView)
    }

    func test_openLinkPrompt_openAndCancel_resolveTheirDecisions() async throws {
        let pane = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        let openTask = Task { @MainActor in await pane.promptForLink(self.longLink) }
        _ = try await waitForTextView(in: pane)
        try XCTUnwrap(promptButtons(in: pane).first).performClick(nil)
        let opened = await openTask.value
        XCTAssertEqual(opened, .open)

        let cancelTask = Task { @MainActor in await pane.promptForLink(self.longLink) }
        _ = try await waitForTextView(in: pane)
        try XCTUnwrap(promptButtons(in: pane).last).performClick(nil)
        let cancelled = await cancelTask.value
        XCTAssertEqual(cancelled, .cancel)
    }

    func test_openLinkPrompt_inALaidOutCard_showsTheLinksHost() async throws {
        let pane = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        pane.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        pane.layoutSubtreeIfNeeded()
        let task = Task { @MainActor in await pane.promptForLink(self.longLink) }

        let textView = try await waitForTextView(in: pane)
        pane.layoutSubtreeIfNeeded()

        try assertLinkHeadIsVisible(textView)
        pane.dismissPrompt()
        let decision = await task.value
        XCTAssertEqual(decision, .cancel)
    }

    func test_openLinkPrompt_shownBeforeTheCardIsLaidOut_showsTheLinksHostOnceItIs() async throws {
        let pane = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        let task = Task { @MainActor in await pane.promptForLink(self.longLink) }

        let textView = try await waitForTextView(in: pane)
        pane.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        pane.layoutSubtreeIfNeeded()

        try assertLinkHeadIsVisible(textView)
        pane.dismissPrompt()
        let decision = await task.value
        XCTAssertEqual(decision, .cancel)
    }

    func test_webView_fillsTheCardBelowTheHeader() {
        let pane = MCPAppViewPane(viewID: UUID(), prefersBorder: nil)
        let webView = WKWebView(frame: .zero)
        pane.setWebView(webView)
        pane.frame = NSRect(x: 0, y: 0, width: 320, height: 600)

        pane.layoutSubtreeIfNeeded()

        XCTAssertEqual(webView.frame.width, 320, accuracy: 0.5)
        XCTAssertEqual(webView.frame.height, 600 - MCPAppViewPane.headerHeight, accuracy: 0.5,
            "the web view takes the whole card below the header")
    }
}
