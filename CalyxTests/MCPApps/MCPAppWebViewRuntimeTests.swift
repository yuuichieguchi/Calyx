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
//  sends `host-context-changed` (K60).
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

// MARK: - Finding 7: the ui/message consent prompt shows the whole message

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
