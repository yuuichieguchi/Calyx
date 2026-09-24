//
//  MCPAppWebViewRuntime+Requests.swift
//  Calyx
//
//  What the runtime answers to a view. Proxied requests go only to the
//  view's own server session; while that server is not ready they fail
//  with -32000. `ui/open-link` and `ui/message` ask for consent in the
//  approval panel (`requestConsent(viewID:state:kind:)`).
//

import AppKit
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "MCPAppWebViewRuntime")

extension MCPAppWebViewRuntime: MCPAppBridgeDelegate {

    func bridge(_ bridge: MCPAppBridge, didReceiveRequest method: String, params: [String: AnyCodable]?) async
        -> Result<AnyCodable, JSONRPCError> {
        guard let viewID = viewID(of: bridge), let store, let session = store.session(forView: viewID) else {
            return .failure(Self.serverError("The view is closing."))
        }
        let proxied: Set<String> = ["tools/call", "tools/list", "resources/read", "resources/list", "resources/templates/list", "prompts/list"]
        if proxied.contains(method), store.isUpstreamDisconnected(viewID: viewID) {
            return .failure(Self.serverError("The MCP server \(session.serverDisplayName) is disconnected."))
        }

        switch method {
        case "ui/initialize":
            return initialize(viewID: viewID, params: params)
        case "ping":
            return .success(Self.emptyObject)
        case "ui/open-link":
            return await openLink(viewID: viewID, params: params)
        case "ui/message":
            return await deliverMessage(viewID: viewID, params: params)
        case "ui/request-display-mode":
            return requestDisplayMode(viewID: viewID, params: params)
        case "ui/download-file":
            return await downloadFiles(viewID: viewID, params: params, session: session)
        case "ui/update-model-context":
            return updateModelContext(viewID: viewID, params: params, store: store)
        case "tools/call":
            return await callTool(params: params, session: session)
        case "tools/list":
            let tools = await session.listTools()
            return .success(AnyCodable(["tools": AnyCodable(tools.map { AnyCodable($0.raw) })]))
        case "resources/read":
            guard let uri = params?["uri"]?.stringValue else {
                return .failure(MCPAppBridgeDispatch.invalidParams("resources/read requires a uri."))
            }
            do {
                return .success(AnyCodable(try await session.readResource(uri: uri)))
            } catch {
                return .failure(Self.serverError("resources/read failed: \(error)"))
            }
        case "resources/list":
            return await page(key: "resources", params: params) { try await session.listResources(cursor: $0) }
        case "resources/templates/list":
            return await page(key: "resourceTemplates", params: params) { try await session.listResourceTemplates(cursor: $0) }
        case "prompts/list":
            return await page(key: "prompts", params: params) { try await session.listPrompts(cursor: $0) }
        case "sampling/createMessage":
            return .failure(MCPAppUnsupportedMethods.errorForSampling())
        default:
            return .failure(JSONRPCError(code: -32601, message: "Method not found", data: nil))
        }
    }

    func bridge(_ bridge: MCPAppBridge, didReceiveNotification method: String, params: [String: AnyCodable]?) {
        guard let viewID = viewID(of: bridge), let store else { return }
        switch method {
        case "ui/notifications/initialized":
            store.viewDidInitialize(viewID: viewID)
            if views[viewID]?.appDeclaresTools == true {
                Task { @MainActor [weak self] in await self?.refreshAppTools(viewID: viewID) }
            }
        case "notifications/tools/list_changed":
            Task { @MainActor [weak self] in await self?.refreshAppTools(viewID: viewID) }
        case "ui/notifications/size-changed":
            // The host sets the card's size (the dock width is the user's,
            // the height is the leaf's) and reports it as fixed
            // `containerDimensions`; the view's size does not change it.
            break
        case "ui/notifications/request-teardown":
            Task { @MainActor in await store.viewRequestedTeardown(viewID: viewID) }
        case "notifications/message":
            let level = params?["level"]?.stringValue ?? "info"
            logger.info("MCP App view \(viewID, privacy: .public) [\(level, privacy: .public)]")
        default:
            logger.debug("Ignored view notification \(method, privacy: .public)")
        }
    }

    // MARK: - Lifecycle

    private func viewID(of bridge: MCPAppBridge) -> UUID? {
        views.first { $0.value.mounted?.bridge === bridge }?.key
    }

    private func initialize(viewID: UUID, params: [String: AnyCodable]?) -> Result<AnyCodable, JSONRPCError> {
        guard let state = views[viewID], let store else {
            return .failure(Self.serverError("The view is closing."))
        }
        let capabilities = params?["appCapabilities"]
        state.appDisplayModes = capabilities?["availableDisplayModes"]?.arrayValue?.compactMap(\.stringValue)
        state.appDeclaresTools = capabilities?["tools"].map { !$0.isNull } ?? false
        guard let environment = hostEnvironment(for: viewID) else {
            return .failure(Self.serverError("The view is closing."))
        }

        // The capabilities list the CSP entries the builder applied.
        let applied = store.appliedCSP(forView: viewID)
        let hostContext = MCPAppHostContextBuilder.buildHostContext(environment)
        state.lastHostContext = hostContext
        return .success(AnyCodable(MCPAppHostCapabilities.initializeResult(
            requestedVersion: params?["protocolVersion"]?.stringValue ?? "",
            appliedCSP: applied,
            hostContext: hostContext
        )))
    }

    /// Asks the view for its tools and publishes them to the pane's agent.
    private func refreshAppTools(viewID: UUID) async {
        do {
            let reply = try await send(.request(id: .string("tools"), method: "tools/list", params: [:]), to: viewID)
            guard case .response(_, let result, let error)? = reply, error == nil,
                  let tools = result?["tools"]?.arrayValue else {
                logger.error("MCP App view \(viewID, privacy: .public) did not list its tools")
                return
            }
            var definitions: [MCPToolDefinition] = []
            for tool in tools {
                guard let raw = tool.objectValue else { continue }
                do {
                    definitions.append(try MCPToolDefinition(raw: raw))
                } catch {
                    logger.error("MCP App view \(viewID, privacy: .public) listed a tool without a name: \(error, privacy: .public)")
                }
            }
            store?.registerAppTools(definitions, viewID: viewID)
        } catch {
            logger.error("Listing the tools of MCP App view \(viewID, privacy: .public) failed: \(error, privacy: .public)")
        }
    }

    // MARK: - ui/* requests

    private func openLink(viewID: UUID, params: [String: AnyCodable]?) async -> Result<AnyCodable, JSONRPCError> {
        guard let text = params?["url"]?.stringValue, let url = URL(string: text) else {
            return .failure(MCPAppBridgeDispatch.invalidParams("ui/open-link requires a url string."))
        }
        guard MCPAppOpenLinkPolicy.isAllowedScheme(url) else {
            return .success(Self.errorFlag)
        }
        guard let state = views[viewID] else {
            return .success(Self.errorFlag)
        }
        if openLinkPolicy.requiresPrompt(viewID: viewID) {
            let generation = state.documentGeneration
            let decision = MCPAppOpenLinkPolicy.PromptDecision(await requestConsent(viewID: viewID, state: state, kind: .openLink(url)))
            // The document that asked unloaded (Reload) or the view was
            // removed while the prompt was up: nothing opens, nothing is allowed.
            guard isCurrentDocument(viewID: viewID, state: state, generation: generation) else {
                return .success(Self.errorFlag)
            }
            switch decision {
            case .open:
                break
            case .alwaysForThisView:
                openLinkPolicy.recordAlways(viewID: viewID)
            case .cancel:
                return .success(Self.errorFlag)
            }
        }
        return .success(environment.openLink(url) ? Self.emptyObject : Self.errorFlag)
    }

    private func deliverMessage(viewID: UUID, params: [String: AnyCodable]?) async -> Result<AnyCodable, JSONRPCError> {
        guard let state = views[viewID] else { return .failure(Self.serverError("The view is closing.")) }
        var blocks: [MCPMessageContentBlock] = []
        for item in params?["content"]?.arrayValue ?? [] {
            switch item["type"]?.stringValue {
            case "text":
                guard let text = item["text"]?.stringValue else {
                    return .failure(MCPAppBridgeDispatch.invalidParams("A text content block needs text."))
                }
                blocks.append(.text(text))
            case "image":
                guard let data = item["data"]?.stringValue, Data(base64Encoded: data) != nil,
                      let mimeType = item["mimeType"]?.stringValue else {
                    return .failure(MCPAppBridgeDispatch.invalidParams("An image content block needs base64 data and a mimeType."))
                }
                blocks.append(.image(base64: data, mimeType: mimeType))
            default:
                return .failure(MCPAppBridgeDispatch.invalidParams("ui/message supports only text and image content."))
            }
        }

        let herdrRef = state.surfaceID.flatMap { environment.herdrPaneRef(forSurface: $0) }
        let route = MCPAppMessageDeliveryRoute.choose(surfaceID: state.surfaceID, herdrRef: herdrRef)
        switch consentGate.beginRequest(viewID: viewID, hasPane: route != .copyOnly) {
        case .noPaneCopyOnly:
            do {
                let formatted = try await MCPAppMessageFormatter.formatOffCallerActor(
                    content: blocks, imageDirectory: MCPAppMessageFormatter.imageDirectory
                )
                offerCopy(of: formatted.pastedText, viewID: viewID, state: state)
            } catch {
                return .failure(Self.serverError("The message could not be prepared: \(error)"))
            }
            // The app is answered now; the copy offer waits for the user
            // on its own.
            return .failure(Self.serverError("This view has no pane to send the message to."))
        case .send:
            return await deliver(blocks, route: route, surfaceID: state.surfaceID)
        case nil:
            // One line: the panel would show each newline as `^J`.
            let preview = blocks.compactMap { block -> String? in
                if case .text(let text) = block { return text }
                return "[image]"
            }.joined(separator: "\n").components(separatedBy: .newlines).joined(separator: " ")
            let generation = state.documentGeneration
            let decision = MCPAppMessageConsentGate.PromptDecision(
                await requestConsent(viewID: viewID, state: state, kind: .sendMessage(preview: preview))
            )
            // The document that asked unloaded (Reload, teardown) or the
            // view was removed while the prompt was up: nothing is sent,
            // nothing is approved.
            guard isCurrentDocument(viewID: viewID, state: state, generation: generation) else {
                return .failure(Self.serverError("Message sending denied"))
            }
            switch consentGate.resolvePendingPrompt(viewID: viewID, decision: decision) {
            case .send:
                return await deliver(blocks, route: route, surfaceID: state.surfaceID)
            case .dontSend:
                return .success(Self.errorFlag)
            }
        }
    }

    /// A pane-less view's `ui/message`: offers to copy `text` from the
    /// approval panel ("Copy" / "Dismiss"). Copy puts it on the general
    /// pasteboard; anything else copies nothing.
    private func offerCopy(of text: String, viewID: UUID, state: ViewState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let decision = await self.requestConsent(viewID: viewID, state: state, kind: .copyMessage(text: text))
            guard decision == .allowed else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func deliver(_ blocks: [MCPMessageContentBlock], route: MCPAppMessageDeliveryRoute, surfaceID: UUID?) async
        -> Result<AnyCodable, JSONRPCError> {
        switch route {
        case .cockpit(let surfaceID):
            let delivery = environment.cockpitInputDelivery
            return await MCPAppMessageSending.send(blocks) { text in
                try await delivery.deliverUserMessage(text, to: surfaceID)
            }
        case .herdr(let ref):
            let delivery = MCPAppHerdrInputDelivery(
                herdrInput: HerdrSocketPaneSending.live(socketPath: ref.socketPath),
                isAgentPane: { [environment] in environment.isAgentPane($0) }
            )
            return await MCPAppMessageSending.send(blocks) { text in
                try await delivery.deliverUserMessage(text, to: ref, surfaceID: surfaceID)
            }
        case .copyOnly:
            return .failure(Self.serverError("This view has no pane to send the message to."))
        }
    }

    private func requestDisplayMode(viewID: UUID, params: [String: AnyCodable]?) -> Result<AnyCodable, JSONRPCError> {
        guard let state = views[viewID], let requested = params?["mode"]?.stringValue else {
            return .failure(MCPAppBridgeDispatch.invalidParams("ui/request-display-mode requires a mode string."))
        }
        switch MCPAppDisplayModeRequest.resolve(
            requested: requested, available: availableDisplayModes(for: viewID), current: state.displayMode
        ) {
        case .success(let mode):
            applyDisplayMode(mode, viewID: viewID)
            return .success(AnyCodable(["mode": AnyCodable(mode)]))
        case .failure(let error):
            return .failure(error)
        }
    }

    /// One save panel per item, in order. Any cancel or failure reports
    /// isError. Listing Downloads and writing the file run on
    /// `DispatchQueue.global()`.
    private func downloadFiles(viewID: UUID, params: [String: AnyCodable]?, session: any MCPAppServerSession) async
        -> Result<AnyCodable, JSONRPCError> {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        for item in params?["contents"]?.arrayValue ?? [] {
            let file: (name: String, data: Data)
            do {
                file = try await downloadable(item, session: session)
            } catch {
                logger.error("ui/download-file item could not be read: \(error, privacy: .public)")
                return .success(Self.errorFlag)
            }
            let existing = await Self.fileNames(in: downloads)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = MCPAppFilenameSanitizer.sanitize(file.name, existingNames: existing)
            panel.directoryURL = downloads
            let response: NSApplication.ModalResponse
            if let window = views[viewID]?.pane.window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
            guard response == .OK, let url = panel.url else { return .success(Self.errorFlag) }
            do {
                try await Self.write(file.data, to: url)
            } catch {
                logger.error("ui/download-file could not write \(url.path, privacy: .public): \(error, privacy: .public)")
                return .success(Self.errorFlag)
            }
        }
        return .success(Self.emptyObject)
    }

    /// The names in `directory`, for the save panel's unique default name;
    /// none when there is no directory or it cannot be listed.
    private nonisolated static func fileNames(in directory: URL?) async -> [String] {
        guard let directory else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            }
        }
    }

    private nonisolated static func write(_ data: Data, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global().async {
                do {
                    try data.write(to: url, options: [.atomic])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// An EmbeddedResource's own content, or a ResourceLink read from the server.
    private func downloadable(_ item: AnyCodable, session: any MCPAppServerSession) async throws -> (name: String, data: Data) {
        let resource: AnyCodable
        let name: String?
        switch item["type"]?.stringValue {
        case "resource":
            guard let embedded = item["resource"] else { throw MCPAppDownloadError.malformedItem }
            resource = embedded
            name = nil
        case "resource_link":
            guard let uri = item["uri"]?.stringValue else { throw MCPAppDownloadError.malformedItem }
            let read = try await session.readResource(uri: uri)
            guard let first = read["contents"]?.arrayValue?.first else { throw MCPAppDownloadError.malformedItem }
            resource = first
            name = item["name"]?.stringValue
        default:
            throw MCPAppDownloadError.malformedItem
        }
        let uri = resource["uri"]?.stringValue ?? ""
        let fileName = name ?? URL(string: uri)?.lastPathComponent ?? uri
        if let text = resource["text"]?.stringValue {
            return (fileName, Data(text.utf8))
        }
        if let blob = resource["blob"]?.stringValue, let data = Data(base64Encoded: blob) {
            return (fileName, data)
        }
        throw MCPAppDownloadError.malformedItem
    }

    private func updateModelContext(viewID: UUID, params: [String: AnyCodable]?, store: MCPAppHostStore)
        -> Result<AnyCodable, JSONRPCError> {
        guard let invocation = store.invocation(forView: viewID) else {
            return .failure(Self.serverError("The view is closing."))
        }
        let content = params?["content"]?.arrayValue?.filter { block in
            let type = block["type"]?.stringValue
            return type == "text" || type == "image"
        }
        store.updateModelContext(viewID: viewID, entry: MCPAppModelContextEntry(
            viewID: viewID,
            serverDisplayName: invocation.serverDisplayName,
            toolName: invocation.tool.name,
            content: content,
            structuredContent: params?["structuredContent"]
        ))
        return .success(Self.emptyObject)
    }

    // MARK: - Proxied requests

    /// Only tools whose visibility includes `app`; any other is -32000.
    private func callTool(params: [String: AnyCodable]?, session: any MCPAppServerSession) async -> Result<AnyCodable, JSONRPCError> {
        guard let name = params?["name"]?.stringValue else {
            return .failure(MCPAppBridgeDispatch.invalidParams("tools/call requires a name."))
        }
        let tools = await session.listTools()
        guard let tool = tools.first(where: { $0.name == name }), MCPAppViewToolAccess.isCallable(tool: tool, byApp: true) else {
            return .failure(Self.serverError("The tool \(name) cannot be called from an app."))
        }
        do {
            let result = try await session.callTool(name: name, arguments: params?["arguments"]?.objectValue ?? [:])
            return .success(AnyCodable(result.raw))
        } catch {
            return .failure(Self.serverError("tools/call \(name) failed: \(error)"))
        }
    }

    private func page(
        key: String,
        params: [String: AnyCodable]?,
        list: (String?) async throws -> (items: [[String: AnyCodable]], nextCursor: String?)
    ) async -> Result<AnyCodable, JSONRPCError> {
        do {
            let page = try await list(params?["cursor"]?.stringValue)
            var result: [String: AnyCodable] = [key: AnyCodable(page.items.map { AnyCodable($0) })]
            if let cursor = page.nextCursor { result["nextCursor"] = AnyCodable(cursor) }
            return .success(AnyCodable(result))
        } catch {
            return .failure(Self.serverError("\(key) could not be listed: \(error)"))
        }
    }

    // MARK: - Helpers

    private static var emptyObject: AnyCodable { AnyCodable([String: AnyCodable]()) }
    private static var errorFlag: AnyCodable { AnyCodable(["isError": AnyCodable(true)]) }

    private static func serverError(_ message: String) -> JSONRPCError {
        JSONRPCError(code: -32000, message: message, data: nil)
    }
}

enum MCPAppDownloadError: Error, Equatable {
    /// Neither an EmbeddedResource with text or blob, nor a readable ResourceLink.
    case malformedItem
}
