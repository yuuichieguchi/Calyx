//
//  MCPAppHostStore.swift
//  Calyx
//
//  Owns every MCP Apps view, keyed by the calling pane's surface UUID
//  (nil for a standalone panel). Drives each view's message order through
//  `MCPAppLifecycle`, and reaches the web views only through
//  `MCPAppViewRuntime`. The upstream result goes back to the agent
//  whatever state the view is in; the view gets it once it is live.
//

import Foundation
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "MCPApp")

enum MCPAppViewStatus: Sendable, Equatable {
    /// `resources/read` in flight.
    case loadingResource
    /// The resource failed validation. Shown as a finished error card.
    case resourceError(reason: String)
    /// `resources/read` itself failed. Retry reads again.
    case readFailed(reason: String)
    /// The document loaded; `initialized` not received yet. No timer.
    case waitingForApp
    case live
    /// The WebContent process ended. Reload or Close.
    case stopped
    /// The server is not ready. Proxied requests fail with -32000.
    case upstreamDisconnected
    /// tool-result was sent.
    case completed
    /// tool-cancelled was sent.
    case cancelled
}

struct MCPAppViewSnapshot: Sendable, Equatable {
    let viewID: UUID
    let invocationID: MCPInvocationID
    /// Nil for a standalone panel.
    let surfaceID: UUID?
    let serverID: MCPServerID
    let status: MCPAppViewStatus
    /// "<tool> · <server> · <client>", without the client when it is unknown.
    let title: String
}

@MainActor
protocol MCPPaneResolving: AnyObject {
    func paneHost(owningSurface surfaceID: UUID) -> MCPPaneHost?
}

enum MCPPaneHost: Sendable, Equatable {
    case window(windowID: UUID, tabID: UUID)
    case quickTerminal
}

extension Notification.Name {
    /// Posted by `MCPAppHostStore` after any view is added, removed or
    /// changes status. `object` is the store.
    static let calyxMCPAppViewsChanged = Notification.Name("com.calyx.mcpApps.viewsChanged")
}

@MainActor
final class MCPAppHostStore: MCPAppViewHosting, MCPAppModelContextProviding {

    /// The upstream outcome, held until the view can be told.
    private enum RecordedOutcome {
        case result(MCPCallToolResult)
        case cancelled
    }

    /// Where a view is in its own life, before the upstream connection
    /// state is applied.
    private enum Phase: Equatable {
        case loadingResource
        case resourceError(String)
        case readFailed(String)
        case waitingForApp
        case live
        case stopped
        case completed
        case cancelled
    }

    private struct ViewRecord {
        let invocation: MCPUIToolInvocation
        let session: any MCPAppServerSession
        var surfaceID: UUID?
        var phase: Phase = .loadingResource
        var lifecycle: MCPAppLifecycle.State = .initial
        var outcome: RecordedOutcome?
        var document: MCPAppViewDocument?
        var resolved: MCPAppUIResourceValidator.Resolved?
        var droppedCSPEntries: [(raw: String, reason: String)] = []
        var appliedCSP: MCPAppCSPBuilder.CSPDomains?
        var isMounted = false
        var appTools: [String: MCPToolDefinition] = [:]
        var modelContext: MCPAppModelContextEntry?
        var pendingHostContext: [String: AnyCodable] = [:]
        /// Serializes host-to-view sends so they arrive in reducer order.
        var sendChain: Task<Void, Never>?

        var viewID: UUID { invocation.id.rawValue }
    }

    private let paneResolver: any MCPPaneResolving
    private let runtime: any MCPAppViewRuntime
    private let appToolRegistry: any MCPAppToolRegistry
    private var records: [UUID: ViewRecord] = [:]
    private var order: [UUID] = []
    private var disconnectedServers: Set<MCPServerID> = []
    private var nextRequestNumber = 0
    private var surfaceObserver: SurfaceDestroyedObserver?

    init(paneResolver: any MCPPaneResolving, runtime: any MCPAppViewRuntime, appToolRegistry: any MCPAppToolRegistry) {
        self.paneResolver = paneResolver
        self.runtime = runtime
        self.appToolRegistry = appToolRegistry
        let observer = SurfaceDestroyedObserver()
        observer.store = self
        NotificationCenter.default.addObserver(
            observer, selector: #selector(SurfaceDestroyedObserver.handleSurfaceDestroyed(_:)),
            name: .calyxSurfaceDestroyed, object: nil
        )
        surfaceObserver = observer
    }

    // MARK: - MCPAppViewHosting

    func uiToolInvocationDidStart(_ invocation: MCPUIToolInvocation, session: any MCPAppServerSession) async {
        let paneKey: MCPAppGeneration.PaneKey = invocation.surfaceID.map { .pane($0) } ?? .paneless
        let retired = MCPAppGeneration.viewsToRetire(
            existing: order.compactMap { id in records[id].map { generationSnapshot($0) } },
            newCallPaneKey: paneKey
        )
        for viewID in order where retired.contains(viewID) {
            await remove(viewID: viewID)
        }

        let record = ViewRecord(invocation: invocation, session: session, surfaceID: invocation.surfaceID)
        records[record.viewID] = record
        order.append(record.viewID)
        postChange()

        await loadResource(viewID: record.viewID)
    }

    func uiToolInvocationDidFinish(_ id: MCPInvocationID, result: MCPCallToolResult) async {
        recordOutcome(.result(result), viewID: id.rawValue)
    }

    func uiToolInvocationWasCancelled(_ id: MCPInvocationID) async {
        recordOutcome(.cancelled, viewID: id.rawValue)
    }

    func callAppTool(surfaceID: UUID, name: String, arguments: [String: AnyCodable]) async -> MCPCallToolResult {
        let owner = order.reversed().compactMap { records[$0] }.first { record in
            record.surfaceID == surfaceID && record.appTools[name] != nil && record.lifecycle.hasReceivedInitialized
        }
        guard let owner else {
            return Self.errorResult("No live MCP App view in this pane provides the tool \(name).")
        }
        nextRequestNumber += 1
        let request = JSONRPCMessage.request(
            id: .string("calyx-app-tool-\(nextRequestNumber)"),
            method: "tools/call",
            params: ["name": AnyCodable(name), "arguments": AnyCodable(arguments)]
        )
        do {
            let reply = try await runtime.send(request, to: owner.viewID)
            guard case .response(_, let result, let error)? = reply else {
                return Self.errorResult("The MCP App view did not answer the call to \(name).")
            }
            if let error {
                return Self.errorResult("The MCP App view rejected the call to \(name): \(error.message)")
            }
            guard let object = result?.objectValue else {
                return Self.errorResult("The MCP App view answered the call to \(name) without a result object.")
            }
            return MCPCallToolResult(raw: object)
        } catch {
            return Self.errorResult("The call to \(name) could not reach the MCP App view: \(error)")
        }
    }

    func hasActiveView(forSurface surfaceID: UUID) -> Bool {
        records.values.contains { $0.surfaceID == surfaceID }
    }

    func isStandalonePanel(_ id: MCPInvocationID) -> Bool {
        guard let record = records[id.rawValue] else { return false }
        return record.surfaceID == nil
    }

    /// Moves the views to the reconnected surface without rebuilding them.
    func remapSurface(old: UUID, new: UUID) {
        for viewID in order where records[viewID]?.surfaceID == old {
            records[viewID]?.surfaceID = new
            guard let record = records[viewID], !record.appTools.isEmpty else { continue }
            appToolRegistry.unregisterAppTools(forView: viewID)
            appToolRegistry.registerAppTools(
                Array(record.appTools.values), forSurface: new, viewID: viewID, serverID: record.invocation.serverID
            )
        }
        postChange()
    }

    func teardownViews(forServer serverID: MCPServerID, reason: String) async {
        let viewIDs = order.filter { records[$0]?.invocation.serverID == serverID }
        if !viewIDs.isEmpty {
            logger.info("Tearing down \(viewIDs.count) MCP App view(s): \(reason, privacy: .public)")
        }
        for viewID in viewIDs {
            await remove(viewID: viewID)
        }
    }

    /// Any state but ready marks the server's views disconnected.
    func serverConnectionChanged(serverID: MCPServerID, state: MCPConnectionState) {
        if case .ready = state {
            disconnectedServers.remove(serverID)
        } else {
            disconnectedServers.insert(serverID)
        }
        postChange()
    }

    // MARK: - MCPAppModelContextProviding

    /// Keeps only the latest entry per view.
    func updateModelContext(viewID: UUID, entry: MCPAppModelContextEntry) {
        records[viewID]?.modelContext = entry
    }

    func modelContexts(forSurface surfaceID: UUID) -> [MCPAppModelContextEntry] {
        order.compactMap { records[$0] }.filter { $0.surfaceID == surfaceID }.compactMap(\.modelContext)
    }

    // MARK: - Notifications from the runtime

    func viewDidLoadDocument(viewID: UUID) {
        guard records[viewID] != nil else { return }
        records[viewID]?.phase = .waitingForApp
        postChange()
    }

    /// `ui/notifications/initialized`: sends tool-input, then any recorded
    /// outcome and held host-context changes.
    func viewDidInitialize(viewID: UUID) {
        guard records[viewID] != nil else { return }
        apply(.clientInitialized, viewID: viewID)
        records[viewID]?.phase = .live
        apply(.toolInputReady, viewID: viewID)
        if let outcome = records[viewID]?.outcome {
            apply(.outcomeReady(Self.lifecycleOutcome(outcome)), viewID: viewID)
        }
        if let pending = records[viewID]?.pendingHostContext, !pending.isEmpty {
            apply(.hostContextChanged, viewID: viewID)
        }
        postChange()
    }

    func viewProcessDidTerminate(viewID: UUID) {
        guard records[viewID] != nil else { return }
        apply(.crash, viewID: viewID)
        records[viewID]?.phase = .stopped
        postChange()
    }

    /// The view asked to be closed.
    func viewRequestedTeardown(viewID: UUID) async {
        await remove(viewID: viewID)
    }

    /// Publishes the view's tools to the agent of the pane that owns it. A
    /// standalone view has no pane agent to publish to.
    func registerAppTools(_ tools: [MCPToolDefinition], viewID: UUID) {
        guard var record = records[viewID] else { return }
        for tool in tools {
            record.appTools[tool.name] = tool
        }
        records[viewID] = record
        guard let surfaceID = record.surfaceID else { return }
        appToolRegistry.registerAppTools(
            Array(record.appTools.values), forSurface: surfaceID, viewID: viewID, serverID: record.invocation.serverID
        )
    }

    /// Host context keys that changed. Sent at once when the view is live,
    /// otherwise held until `initialized`.
    func hostContextDidChange(viewID: UUID, changes: [String: AnyCodable]) {
        guard !changes.isEmpty, records[viewID] != nil else { return }
        records[viewID]?.pendingHostContext.merge(changes) { _, new in new }
        apply(.hostContextChanged, viewID: viewID)
    }

    // MARK: - User actions

    /// Reads the resource again and mounts a fresh web view. Only from
    /// `.readFailed`, `.stopped` and `.waitingForApp`.
    func reload(viewID: UUID) async {
        guard let record = records[viewID] else { return }
        switch record.phase {
        case .readFailed, .stopped, .waitingForApp:
            break
        default:
            return
        }
        apply(.reload, viewID: viewID)
        await loadResource(viewID: viewID)
    }

    /// Tears a live view down, then removes it.
    func close(viewID: UUID) async {
        await remove(viewID: viewID)
    }

    // MARK: - Observation

    func snapshots(forSurface surfaceID: UUID) -> [MCPAppViewSnapshot] {
        order.compactMap { records[$0] }.filter { $0.surfaceID == surfaceID }.map(makeSnapshot)
    }

    func standaloneSnapshots() -> [MCPAppViewSnapshot] {
        order.compactMap { records[$0] }.filter { $0.surfaceID == nil }.map(makeSnapshot)
    }

    /// Every view, pane and standalone, in creation order.
    func allSnapshots() -> [MCPAppViewSnapshot] {
        order.compactMap { records[$0] }.map(makeSnapshot)
    }

    func snapshot(viewID: UUID) -> MCPAppViewSnapshot? {
        records[viewID].map(makeSnapshot)
    }

    /// Whether the tab (or Quick Terminal) has a live or waiting view.
    func hasBackgroundActivity(in paneHost: MCPPaneHost) -> Bool {
        records.values.contains { record in
            guard let surfaceID = record.surfaceID, paneResolver.paneHost(owningSurface: surfaceID) == paneHost else {
                return false
            }
            let status = status(of: record)
            return status == .live || status == .waitingForApp
        }
    }

    // MARK: - Lookups for the bridge

    func invocation(forView viewID: UUID) -> MCPUIToolInvocation? {
        records[viewID]?.invocation
    }

    func session(forView viewID: UUID) -> (any MCPAppServerSession)? {
        records[viewID]?.session
    }

    func surfaceID(forView viewID: UUID) -> UUID? {
        records[viewID]?.surfaceID
    }

    func resolvedResource(forView viewID: UUID) -> MCPAppUIResourceValidator.Resolved? {
        records[viewID]?.resolved
    }

    /// CSP entries the builder dropped, for the header warning.
    func droppedCSPEntries(forView viewID: UUID) -> [(raw: String, reason: String)] {
        records[viewID]?.droppedCSPEntries ?? []
    }

    /// The CSP entries the view's policy uses, as the builder wrote them.
    /// Nil when the resource declared no `csp` or before the view document is built.
    func appliedCSP(forView viewID: UUID) -> MCPAppCSPBuilder.CSPDomains? {
        records[viewID]?.appliedCSP
    }

    func isUpstreamDisconnected(viewID: UUID) -> Bool {
        guard let record = records[viewID] else { return false }
        return disconnectedServers.contains(record.invocation.serverID)
    }

    // MARK: - .calyxSurfaceDestroyed

    /// Drops the surface's views from the table at once, then tears their
    /// web views down. `Task.immediate` reaches the runtime before the
    /// notification post returns.
    fileprivate func surfaceDestroyed(_ surfaceID: UUID) {
        let viewIDs = order.filter { records[$0]?.surfaceID == surfaceID }
        guard !viewIDs.isEmpty else { return }
        let removed = viewIDs.compactMap { detach(viewID: $0) }
        postChange()
        Task.immediate { @MainActor [runtime] in
            for record in removed where record.isMounted {
                await runtime.requestTeardown(viewID: record.viewID)
                runtime.unmount(viewID: record.viewID)
            }
        }
    }

    // MARK: - Private

    private func loadResource(viewID: UUID) async {
        guard let record = records[viewID] else { return }
        guard let ui = record.invocation.tool.ui else {
            setPhase(.resourceError("The tool declares no UI resource."), viewID: viewID)
            return
        }
        guard ui.isUIScheme else {
            setPhase(
                .resourceError(MCPAppUIResourceValidator.describe(.invalidURIScheme(ui.declaredResourceURI))),
                viewID: viewID
            )
            return
        }

        let contents: [AnyCodable]
        do {
            let result = try await record.session.readResource(uri: ui.declaredResourceURI)
            contents = result["contents"]?.arrayValue ?? []
        } catch {
            setPhase(.readFailed("The UI resource could not be read: \(error)"), viewID: viewID)
            return
        }
        let listEntryMeta = await listEntryMetaIfNeeded(
            contents: contents, uri: ui.declaredResourceURI, session: record.session
        )
        guard records[viewID] != nil else { return }

        switch MCPAppUIResourceValidator.validate(contents: contents, listEntryMeta: listEntryMeta) {
        case .failure(let error):
            setPhase(.resourceError(MCPAppUIResourceValidator.describe(error)), viewID: viewID)
        case .success(let resolved):
            await mount(resolved: resolved, viewID: viewID)
        }
    }

    /// `_meta.ui` of the `resources/list` entry, looked up only when the
    /// content item carries none. The lookup is only a fallback source: when
    /// it fails the view continues with no list metadata, which applies the
    /// undeclared defaults (the strictest CSP, no permissions, no domain).
    private func listEntryMetaIfNeeded(
        contents: [AnyCodable], uri: String, session: any MCPAppServerSession
    ) async -> AnyCodable? {
        if contents.count == 1, let ui = contents[0]["_meta"]?["ui"], !ui.isNull {
            return nil
        }
        var cursor: String?
        do {
            repeat {
                let page = try await session.listResources(cursor: cursor)
                if let entry = page.items.first(where: { $0["uri"]?.stringValue == uri }) {
                    return entry["_meta"]
                }
                cursor = page.nextCursor
            } while cursor != nil
        } catch {
            logger.error("resources/list for the metadata of \(uri, privacy: .public) failed; using the undeclared defaults: \(error, privacy: .public)")
        }
        return nil
    }

    private func mount(resolved: MCPAppUIResourceValidator.Resolved, viewID: UUID) async {
        let viewHost = resolved.meta?.domain.flatMap { MCPAppSchemeHandler.isValidViewHost($0) ? $0.lowercased() : nil }
            ?? Self.randomHost()
        let viewOrigin = "\(MCPAppWebViewFactory.appScheme)://\(viewHost)"
        let hostOrigin = "\(MCPAppWebViewFactory.hostScheme)://\(Self.randomHost())"
        let built = MCPAppCSPBuilder.buildPolicy(csp: resolved.meta?.csp, hostOrigin: hostOrigin)
        let document = MCPAppViewDocument(
            html: resolved.html,
            viewOrigin: viewOrigin,
            hostOrigin: hostOrigin,
            cspPolicy: built.policy,
            contentRuleListJSON: MCPAppCSPBuilder.contentRuleList(
                csp: resolved.meta?.csp, hostOrigin: hostOrigin, calyxOrigins: [viewOrigin]
            ),
            contentRuleListIdentifier: MCPAppWebViewFactory.contentRuleListIdentifierPrefix + viewID.uuidString
        )
        records[viewID]?.resolved = resolved
        records[viewID]?.document = document
        records[viewID]?.droppedCSPEntries = built.dropped
        records[viewID]?.appliedCSP = built.applied

        do {
            records[viewID]?.isMounted = true
            try await runtime.mount(viewID: viewID, document: document)
        } catch {
            records[viewID]?.isMounted = false
            setPhase(.readFailed("The view could not be loaded: \(error)"), viewID: viewID)
            return
        }
        postChange()
    }

    private func recordOutcome(_ outcome: RecordedOutcome, viewID: UUID) {
        guard records[viewID] != nil else { return }
        records[viewID]?.outcome = outcome
        apply(.outcomeReady(Self.lifecycleOutcome(outcome)), viewID: viewID)
    }

    /// Runs one lifecycle event and performs its effects.
    private func apply(_ event: MCPAppLifecycle.Event, viewID: UUID) {
        guard let record = records[viewID] else { return }
        let (state, effects) = MCPAppLifecycle.reduce(record.lifecycle, event)
        records[viewID]?.lifecycle = state
        for effect in effects {
            perform(effect, viewID: viewID)
        }
    }

    private func perform(_ effect: MCPAppLifecycle.Effect, viewID: UUID) {
        guard let record = records[viewID] else { return }
        switch effect {
        case .sendToolInput:
            enqueueNotification(
                "ui/notifications/tool-input",
                params: ["arguments": AnyCodable(record.invocation.arguments)],
                viewID: viewID
            )
        case .sendHostContextChanged:
            let changes = record.pendingHostContext
            records[viewID]?.pendingHostContext = [:]
            enqueueNotification("ui/notifications/host-context-changed", params: changes, viewID: viewID)
        case .sendOutcome(.result):
            guard case .result(let result)? = record.outcome else { return }
            enqueueNotification("ui/notifications/tool-result", params: result.raw, viewID: viewID)
            records[viewID]?.phase = .completed
            postChange()
        case .sendOutcome(.cancelled):
            enqueueNotification(
                "ui/notifications/tool-cancelled",
                params: ["reason": AnyCodable("The tool call was cancelled.")],
                viewID: viewID
            )
            records[viewID]?.phase = .cancelled
            postChange()
        case .requestTeardown, .removeView:
            // Removal goes through `remove(viewID:)`, which awaits the teardown.
            break
        case .reloadView:
            if record.isMounted {
                runtime.unmount(viewID: viewID)
                records[viewID]?.isMounted = false
            }
            // `reload(viewID:)` reads the resource again after this.
            records[viewID]?.phase = .loadingResource
            postChange()
        }
    }

    /// Sends in the order enqueued. A failed send has no caller to return
    /// to (the upstream result already went back to the agent), so it is logged.
    private func enqueueNotification(_ method: String, params: [String: AnyCodable], viewID: UUID) {
        let previous = records[viewID]?.sendChain
        let runtime = runtime
        let message = JSONRPCMessage.notification(method: method, params: params)
        records[viewID]?.sendChain = Task { @MainActor in
            await previous?.value
            do {
                _ = try await runtime.send(message, to: viewID)
            } catch {
                logger.error("Sending \(method, privacy: .public) to MCP App view \(viewID, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }

    /// Tears the view down (when it has a web view) and removes it.
    private func remove(viewID: UUID) async {
        guard records[viewID] != nil else { return }
        apply(.viewRemovalRequested, viewID: viewID)
        guard let record = detach(viewID: viewID) else { return }
        postChange()
        if record.isMounted {
            await runtime.requestTeardown(viewID: viewID)
            runtime.unmount(viewID: viewID)
        }
    }

    /// Removes the record and its app tools from every table.
    private func detach(viewID: UUID) -> ViewRecord? {
        guard let record = records.removeValue(forKey: viewID) else { return nil }
        order.removeAll { $0 == viewID }
        appToolRegistry.unregisterAppTools(forView: viewID)
        return record
    }

    private func setPhase(_ phase: Phase, viewID: UUID) {
        guard records[viewID] != nil else { return }
        records[viewID]?.phase = phase
        postChange()
    }

    private func postChange() {
        NotificationCenter.default.post(name: .calyxMCPAppViewsChanged, object: self)
    }

    private func status(of record: ViewRecord) -> MCPAppViewStatus {
        let isDisconnected = disconnectedServers.contains(record.invocation.serverID)
        switch record.phase {
        case .loadingResource: return .loadingResource
        case .resourceError(let reason): return .resourceError(reason: reason)
        case .readFailed(let reason): return .readFailed(reason: reason)
        case .stopped: return .stopped
        case .waitingForApp: return isDisconnected ? .upstreamDisconnected : .waitingForApp
        case .live: return isDisconnected ? .upstreamDisconnected : .live
        case .completed: return isDisconnected ? .upstreamDisconnected : .completed
        case .cancelled: return isDisconnected ? .upstreamDisconnected : .cancelled
        }
    }

    private func makeSnapshot(_ record: ViewRecord) -> MCPAppViewSnapshot {
        let invocation = record.invocation
        let title = ([invocation.tool.name, invocation.serverDisplayName] + (invocation.clientName.map { [$0] } ?? []))
            .joined(separator: " · ")
        return MCPAppViewSnapshot(
            viewID: record.viewID,
            invocationID: invocation.id,
            surfaceID: record.surfaceID,
            serverID: invocation.serverID,
            status: status(of: record),
            title: title
        )
    }

    /// A finished view (outcome sent, or a resource error card) retires;
    /// everything else is still in flight.
    private func generationSnapshot(_ record: ViewRecord) -> MCPAppGeneration.ViewSnapshot {
        let status: MCPAppGeneration.Status
        switch record.phase {
        case .completed, .resourceError: status = .completed
        case .cancelled: status = .cancelled
        default: status = .inFlight
        }
        return MCPAppGeneration.ViewSnapshot(
            id: record.viewID,
            paneKey: record.surfaceID.map { .pane($0) } ?? .paneless,
            status: status
        )
    }

    private static func lifecycleOutcome(_ outcome: RecordedOutcome) -> MCPAppLifecycle.Outcome {
        switch outcome {
        case .result: return .result
        case .cancelled: return .cancelled
        }
    }

    private static func randomHost() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    static func errorResult(_ text: String) -> MCPCallToolResult {
        MCPCallToolResult(raw: [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable(text)])]),
            "isError": AnyCodable(true),
        ])
    }
}

/// Receives `.calyxSurfaceDestroyed` on the posting thread, the way
/// `SurfacePropertyStore` does, and forwards it to the store.
@MainActor
private final class SurfaceDestroyedObserver: NSObject {
    weak var store: MCPAppHostStore?

    @objc func handleSurfaceDestroyed(_ notification: Notification) {
        guard let surfaceID = notification.userInfo?["surfaceID"] as? UUID else { return }
        store?.surfaceDestroyed(surfaceID)
    }
}
