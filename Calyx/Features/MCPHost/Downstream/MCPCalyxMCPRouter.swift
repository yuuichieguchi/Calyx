//
//  MCPCalyxMCPRouter.swift
//  Calyx
//
//  Serves `/calyx-mcp`: the dynamic catalog of the configured upstream
//  servers' tools, re-published to downstream agent CLIs, in both
//  protocol generations.
//
//  A POST whose body carries `params._meta["io.modelcontextprotocol/protocolVersion"]`
//  is modern (2026-07-28, stateless). It is validated in this order:
//    1. `MCP-Protocol-Version`, `Mcp-Method` and, for `tools/call`,
//       `resources/read` and `prompts/get`, `Mcp-Name` must be present and
//       match the body: otherwise 400 / -32020.
//    2. `_meta` must carry `clientCapabilities`: otherwise 400 / -32602.
//    3. The version must be 2026-07-28: otherwise 400 / -32022 listing
//       `supportedVersions`.
//    4. An unknown method is 404 / -32601.
//  No operation requires a client capability, so -32021 is never sent.
//
//  Any other POST is legacy (2025-11-25 and earlier): `initialize` mints a
//  signed `Mcp-Session-Id`, a request without a session is still served,
//  a notification is answered 202, an unknown method is 200 / -32601, and
//  a batch is answered with a batch. A session id that does not verify is
//  404. GET opens the session's SSE stream; DELETE closes it.
//
//  `tools/call` of a tool whose visibility lacks `model` is -32000 in both
//  generations, before the call is proxied. A `tools/call` is answered
//  with plain JSON when its result arrives before any progress and before
//  the first keep-alive interval; otherwise the response turns into an SSE
//  stream carrying `notifications/progress` (when the request asked for
//  progress), keep-alive comments, and finally the response. A stream
//  opened because the first interval elapsed sends only its head then.
//  A legacy request gets a stream only when its `Accept` lists
//  `text/event-stream`. When the consumer of a streamed response is
//  cancelled (in production, when the request's connection drops), the
//  call is cancelled.
//

import Foundation
import Observation

/// The pane `CalyxMCPServer` resolved for a request.
struct MCPPaneResolutionContext: Sendable, Equatable {
    let surfaceID: UUID?
    let clientName: String?
    let herdrPaneRef: HerdrPaneRef?
}

struct MCPCalyxMCPRouter: Sendable {

    private let coordinator: MCPHostCoordinator
    private let registry: MCPServerRegistry
    private let catalog: any MCPCatalogProviding
    private let connections: any MCPConnectionLookup
    private let appToolRegistry: any MCPAppToolRegistry
    private let sessionBearerToken: @Sendable () -> String
    private let clock: any MCPClock
    private let hub: MCPCalyxMCPNotificationHub

    private static let sessionPayloadVersion = 1
    private static let legacyFallbackVersion = MCPProtocolVersion.v2025_11_25
    private static let sessionHeader = "Mcp-Session-Id"
    /// Methods whose target name travels in `Mcp-Name`, and the param
    /// holding it.
    private static let mcpNameParams = ["tools/call": "name", "prompts/get": "name", "resources/read": "uri"]

    @MainActor
    init(
        coordinator: MCPHostCoordinator,
        registry: MCPServerRegistry,
        catalog: any MCPCatalogProviding,
        connections: any MCPConnectionLookup,
        appToolRegistry: any MCPAppToolRegistry,
        sessionBearerToken: @escaping @Sendable () -> String,
        clock: any MCPClock = SystemMCPClock()
    ) {
        self.coordinator = coordinator
        self.registry = registry
        self.catalog = catalog
        self.connections = connections
        self.appToolRegistry = appToolRegistry
        self.sessionBearerToken = sessionBearerToken
        self.clock = clock
        let hub = MCPCalyxMCPNotificationHub(clock: clock)
        self.hub = hub

        let paneChanges = appToolRegistry.changes
        Task {
            for await surfaceID in paneChanges {
                await hub.paneAppToolsChanged(surfaceID: surfaceID)
            }
        }
        Self.watchRegistry(registry, hub: hub, connections: connections)
    }

    /// Re-arms itself on every change of `registry.servers`.
    @MainActor
    private static func watchRegistry(
        _ registry: MCPServerRegistry,
        hub: MCPCalyxMCPNotificationHub,
        connections: any MCPConnectionLookup
    ) {
        let serverIDs = withObservationTracking {
            registry.servers.map(\.id)
        } onChange: {
            Task { @MainActor in
                watchRegistry(registry, hub: hub, connections: connections)
            }
        }
        Task {
            await hub.watchServers(serverIDs, connections: connections)
        }
    }

    // MARK: - POST

    /// POST /calyx-mcp.
    @MainActor
    func routeCalyxMCP(request: HTTPRequest, paneContext: MCPPaneResolutionContext) async -> RoutedResponse {
        await routeCalyxMCP(request: request, paneContext: paneContext, modelContextProvider: nil)
    }

    /// POST /calyx-mcp with the provider `app_context` reads. Without a
    /// provider no view host is attached, so no pane has a live view and
    /// `app_context` reports none.
    @MainActor
    func routeCalyxMCP(
        request: HTTPRequest,
        paneContext: MCPPaneResolutionContext,
        modelContextProvider: (any MCPAppModelContextProviding)?
    ) async -> RoutedResponse {
        await hub.watchServers(registry.servers.map(\.id), connections: connections)

        guard let body = request.body, let parsed = try? JSONSerialization.jsonObject(with: body) else {
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 400,
                message: MCPCalyxMCPWire.errorMessage(id: nil, code: MCPCalyxMCPWire.parseErrorCode, message: "Parse error")
            ))
        }
        let object = AnyCodable(parsed)
        if let batch = object.arrayValue {
            return .buffered(await routeLegacyBatch(batch, request: request, paneContext: paneContext, modelContextProvider: modelContextProvider))
        }
        guard let incoming = MCPCalyxMCPIncoming(object: object) else {
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 400,
                message: MCPCalyxMCPWire.errorMessage(id: nil, code: MCPCalyxMCPWire.invalidRequestCode, message: "Invalid Request")
            ))
        }
        if incoming.params?["_meta"]?[MCPCalyxMCPWire.protocolVersionMetaKey] != nil {
            return await routeModern(incoming, request: request, paneContext: paneContext, modelContextProvider: modelContextProvider)
        }
        return await routeLegacy(incoming, request: request, paneContext: paneContext, modelContextProvider: modelContextProvider)
    }

    // MARK: - GET / DELETE

    /// GET /calyx-mcp: the legacy session's SSE stream. The modern
    /// generation has no GET stream.
    @MainActor
    func routeCalyxMCPStream(request: HTTPRequest) async -> RoutedResponse {
        guard MCPCalyxMCPWire.acceptsEventStream(MCPCalyxMCPWire.header("Accept", in: request.headers)) else {
            return .buffered(MCPCalyxMCPWire.emptyResponse(statusCode: 406))
        }
        guard let token = MCPCalyxMCPWire.header(Self.sessionHeader, in: request.headers),
              let payload = MCPDownstreamSessionID.validate(token, bearerToken: sessionBearerToken())
        else {
            return .buffered(MCPCalyxMCPWire.emptyResponse(statusCode: 404))
        }
        let stream = await hub.openStream(
            surfaceID: nil,
            sessionNonce: payload.nonce,
            subscriptionID: nil,
            wantsToolsListChanged: true,
            initialFrames: [MCPCalyxMCPWire.keepAliveFrame]
        )
        return .stream(head: MCPCalyxMCPWire.eventStreamHead(), body: stream)
    }

    /// DELETE /calyx-mcp: closes the session's GET stream. The session id
    /// is not revoked.
    @MainActor
    func routeCalyxMCPDelete(request: HTTPRequest) async -> HTTPResponse {
        guard let token = MCPCalyxMCPWire.header(Self.sessionHeader, in: request.headers) else {
            return MCPCalyxMCPWire.emptyResponse(statusCode: 400)
        }
        guard let payload = MCPDownstreamSessionID.validate(token, bearerToken: sessionBearerToken()) else {
            return MCPCalyxMCPWire.emptyResponse(statusCode: 404)
        }
        await hub.closeSession(nonce: payload.nonce)
        return MCPCalyxMCPWire.emptyResponse(statusCode: 200)
    }

    // MARK: - Modern generation

    @MainActor
    private func routeModern(
        _ incoming: MCPCalyxMCPIncoming,
        request: HTTPRequest,
        paneContext: MCPPaneResolutionContext,
        modelContextProvider: (any MCPAppModelContextProviding)?
    ) async -> RoutedResponse {
        let id = incoming.id
        let params = incoming.params ?? [:]
        let meta = params["_meta"]?.objectValue ?? [:]
        let bodyVersion = meta[MCPCalyxMCPWire.protocolVersionMetaKey]?.stringValue

        if let mismatch = headerMismatch(incoming, bodyVersion: bodyVersion, headers: request.headers) {
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 400,
                message: MCPCalyxMCPWire.errorMessage(id: id, code: MCPCalyxMCPWire.headerMismatchCode, message: mismatch)
            ))
        }
        guard let capabilities = meta[MCPCalyxMCPWire.clientCapabilitiesMetaKey]?.objectValue else {
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 400,
                message: MCPCalyxMCPWire.errorMessage(
                    id: id, code: MCPCalyxMCPWire.invalidParamsCode,
                    message: "_meta is missing \(MCPCalyxMCPWire.clientCapabilitiesMetaKey)"
                )
            ))
        }
        guard let bodyVersion, MCPProtocolVersion(rawValue: bodyVersion)?.isModern == true else {
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 400,
                message: MCPCalyxMCPWire.errorMessage(
                    id: id, code: MCPCalyxMCPWire.unsupportedProtocolVersionCode,
                    message: "Unsupported protocol version",
                    data: AnyCodable([
                        "supported": AnyCodable(MCPCalyxMCPWire.supportedVersions.map { AnyCodable($0) }),
                        "requested": bodyVersion.map { AnyCodable($0) } ?? AnyCodable.null,
                    ])
                )
            ))
        }

        let clientDeclaredUI = capabilities["extensions"]?[MCPCalyxMCPWire.uiExtensionID] != nil
        let clientName = meta[MCPCalyxMCPWire.clientInfoMetaKey]?["name"]?.stringValue ?? paneContext.clientName

        guard let id else {
            return .buffered(MCPCalyxMCPWire.emptyResponse(statusCode: 202))
        }

        switch incoming.method {
        case "server/discover":
            return .buffered(modernResult(id: id, cacheable: true, [
                "supportedVersions": AnyCodable(MCPCalyxMCPWire.supportedVersions.map { AnyCodable($0) }),
                "capabilities": Self.serverCapabilities,
            ]))
        case "ping":
            return .buffered(modernResult(id: id, cacheable: false, [:]))
        case "tools/list":
            let tools = await listedTools(clientDeclaredUI: clientDeclaredUI, surfaceID: paneContext.surfaceID)
            return .buffered(modernResult(id: id, cacheable: true, ["tools": AnyCodable(tools)]))
        case "resources/list":
            return .buffered(modernResult(id: id, cacheable: true, ["resources": AnyCodable([AnyCodable]())]))
        case "resources/templates/list":
            return .buffered(modernResult(id: id, cacheable: true, ["resourceTemplates": AnyCodable([AnyCodable]())]))
        case "prompts/list":
            return .buffered(modernResult(id: id, cacheable: true, ["prompts": AnyCodable([AnyCodable]())]))
        case "resources/read":
            return .buffered(await readResource(id: id, params: params) { result in
                var decorated = result
                for (key, value) in Self.cacheableFields where decorated[key] == nil {
                    decorated[key] = value
                }
                return Self.addingServerInfo(to: decorated)
            })
        case "subscriptions/listen":
            let filter = params["notifications"]?.objectValue ?? [:]
            let ack = MCPCalyxMCPWire.sseFrame(MCPCalyxMCPWire.notificationMessage(
                method: "notifications/subscriptions/acknowledged",
                params: ["_meta": AnyCodable([MCPCalyxMCPWire.subscriptionIDMetaKey: MCPCalyxMCPWire.idValue(id)])]
            ))
            let stream = await hub.openStream(
                surfaceID: paneContext.surfaceID,
                sessionNonce: nil,
                subscriptionID: id,
                wantsToolsListChanged: filter["toolsListChanged"]?.boolValue == true,
                initialFrames: [ack]
            )
            return .stream(head: MCPCalyxMCPWire.eventStreamHead(), body: stream)
        case "tools/call":
            return await callTool(
                id: id, params: params, meta: meta, paneContext: paneContext,
                clientName: clientName, clientDeclaredUI: clientDeclaredUI,
                sessionNonce: nil, isLegacy: false, allowStream: true, modelContextProvider: modelContextProvider,
                decorate: { Self.addingServerInfo(to: $0) }
            )
        default:
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 404,
                message: MCPCalyxMCPWire.errorMessage(id: id, code: MCPCalyxMCPWire.methodNotFoundCode, message: "Method not found: \(incoming.method)")
            ))
        }
    }

    /// The first header that is missing or disagrees with the body, as a
    /// message; nil when all match.
    private func headerMismatch(_ incoming: MCPCalyxMCPIncoming, bodyVersion: String?, headers: [String: String]) -> String? {
        guard let headerVersion = MCPCalyxMCPWire.header("MCP-Protocol-Version", in: headers) else {
            return "MCP-Protocol-Version header is missing"
        }
        guard headerVersion == bodyVersion else {
            return "MCP-Protocol-Version header does not match _meta"
        }
        guard let headerMethod = MCPCalyxMCPWire.header("Mcp-Method", in: headers) else {
            return "Mcp-Method header is missing"
        }
        guard headerMethod == incoming.method else {
            return "Mcp-Method header does not match the method"
        }
        guard let nameParam = Self.mcpNameParams[incoming.method] else { return nil }
        guard let rawName = MCPCalyxMCPWire.header("Mcp-Name", in: headers) else {
            return "Mcp-Name header is missing"
        }
        guard let headerName = MCPCalyxMCPWire.decodeMcpNameHeader(rawName),
              headerName == incoming.params?[nameParam]?.stringValue
        else {
            return "Mcp-Name header does not match params.\(nameParam)"
        }
        return nil
    }

    private static let cacheableFields: [String: AnyCodable] = [
        "resultType": AnyCodable("complete"),
        "ttlMs": AnyCodable(0),
        "cacheScope": AnyCodable("private"),
    ]

    private static var serverCapabilities: AnyCodable {
        AnyCodable([
            "tools": AnyCodable(["listChanged": AnyCodable(true)]),
            "resources": AnyCodable([String: AnyCodable]()),
        ])
    }

    private static func addingServerInfo(to result: [String: AnyCodable]) -> [String: AnyCodable] {
        var decorated = result
        var meta = decorated["_meta"]?.objectValue ?? [:]
        meta[MCPCalyxMCPWire.serverInfoMetaKey] = MCPCalyxMCPWire.serverInfo
        decorated["_meta"] = AnyCodable(meta)
        return decorated
    }

    private func modernResult(id: JSONRPCId, cacheable: Bool, _ result: [String: AnyCodable]) -> HTTPResponse {
        var decorated = result
        if cacheable {
            decorated.merge(Self.cacheableFields) { current, _ in current }
        }
        return MCPCalyxMCPWire.jsonResponse(
            statusCode: 200,
            message: MCPCalyxMCPWire.resultMessage(id: id, result: Self.addingServerInfo(to: decorated))
        )
    }

    // MARK: - Legacy generation

    /// The verified session of a legacy request.
    private enum LegacySession {
        case none
        case valid(MCPDownstreamSessionPayload)
        case invalid
    }

    @MainActor
    private func legacySession(of request: HTTPRequest, paneContext: MCPPaneResolutionContext) async -> LegacySession {
        guard let token = MCPCalyxMCPWire.header(Self.sessionHeader, in: request.headers) else { return .none }
        guard let payload = MCPDownstreamSessionID.validate(token, bearerToken: sessionBearerToken()) else { return .invalid }
        if let surfaceID = paneContext.surfaceID {
            await hub.recordPane(surfaceID, forSessionNonce: payload.nonce)
        }
        return .valid(payload)
    }

    @MainActor
    private func routeLegacy(
        _ incoming: MCPCalyxMCPIncoming,
        request: HTTPRequest,
        paneContext: MCPPaneResolutionContext,
        modelContextProvider: (any MCPAppModelContextProviding)?
    ) async -> RoutedResponse {
        let session = await legacySession(of: request, paneContext: paneContext)
        if case .invalid = session, incoming.method != "initialize" {
            return .buffered(MCPCalyxMCPWire.emptyResponse(statusCode: 404))
        }
        let allowStream = MCPCalyxMCPWire.acceptsEventStream(MCPCalyxMCPWire.header("Accept", in: request.headers))
        switch await handleLegacy(incoming, session: session, paneContext: paneContext, allowStream: allowStream, modelContextProvider: modelContextProvider) {
        case .none:
            return .buffered(MCPCalyxMCPWire.emptyResponse(statusCode: 202))
        case .message(let message, let headers):
            return .buffered(MCPCalyxMCPWire.jsonResponse(statusCode: 200, message: message, headers: headers))
        case .routed(let routed):
            return routed
        }
    }

    @MainActor
    private func routeLegacyBatch(
        _ batch: [AnyCodable],
        request: HTTPRequest,
        paneContext: MCPPaneResolutionContext,
        modelContextProvider: (any MCPAppModelContextProviding)?
    ) async -> HTTPResponse {
        let session = await legacySession(of: request, paneContext: paneContext)
        if case .invalid = session {
            return MCPCalyxMCPWire.emptyResponse(statusCode: 404)
        }
        var responses: [AnyCodable] = []
        var headers: [String: String] = [:]
        for element in batch {
            guard let incoming = MCPCalyxMCPIncoming(object: element) else {
                responses.append(AnyCodable(MCPCalyxMCPWire.errorMessage(id: nil, code: MCPCalyxMCPWire.invalidRequestCode, message: "Invalid Request")))
                continue
            }
            switch await handleLegacy(incoming, session: session, paneContext: paneContext, allowStream: false, modelContextProvider: modelContextProvider) {
            case .none:
                continue
            case .message(let message, let messageHeaders):
                responses.append(AnyCodable(message))
                headers.merge(messageHeaders) { _, added in added }
            case .routed(let routed):
                // Streams are disabled in a batch, so this is buffered JSON.
                if case .buffered(let response) = routed, let body = response.body,
                   let object = try? JSONSerialization.jsonObject(with: body) {
                    responses.append(AnyCodable(object))
                }
            }
        }
        guard !responses.isEmpty else {
            return MCPCalyxMCPWire.emptyResponse(statusCode: 202)
        }
        return MCPCalyxMCPWire.jsonResponse(statusCode: 200, body: AnyCodable(responses), headers: headers)
    }

    private enum LegacyOutcome {
        /// A notification: no response message.
        case none
        case message([String: AnyCodable], headers: [String: String])
        case routed(RoutedResponse)
    }

    @MainActor
    private func handleLegacy(
        _ incoming: MCPCalyxMCPIncoming,
        session: LegacySession,
        paneContext: MCPPaneResolutionContext,
        allowStream: Bool,
        modelContextProvider: (any MCPAppModelContextProviding)?
    ) async -> LegacyOutcome {
        let params = incoming.params ?? [:]
        guard let id = incoming.id else {
            if incoming.method == "notifications/cancelled", let requestID = Self.requestID(params["requestId"]) {
                let nonce: String?
                if case .valid(let payload) = session { nonce = payload.nonce } else { nonce = nil }
                await hub.cancelCall(MCPDownstreamCancellationKey(sessionNonce: nonce, requestID: requestID))
            }
            return .none
        }

        let payload: MCPDownstreamSessionPayload?
        if case .valid(let valid) = session { payload = valid } else { payload = nil }
        let clientDeclaredUI = payload?.clientDeclaredUI ?? false
        let clientName = payload?.clientName ?? paneContext.clientName

        switch incoming.method {
        case "initialize":
            return await initialize(id: id, params: params, paneContext: paneContext)
        case "ping":
            return .message(MCPCalyxMCPWire.resultMessage(id: id, result: [:]), headers: [:])
        case "tools/list":
            let tools = await listedTools(clientDeclaredUI: clientDeclaredUI, surfaceID: paneContext.surfaceID)
            return .message(MCPCalyxMCPWire.resultMessage(id: id, result: ["tools": AnyCodable(tools)]), headers: [:])
        case "resources/list":
            return .message(MCPCalyxMCPWire.resultMessage(id: id, result: ["resources": AnyCodable([AnyCodable]())]), headers: [:])
        case "resources/templates/list":
            return .message(MCPCalyxMCPWire.resultMessage(id: id, result: ["resourceTemplates": AnyCodable([AnyCodable]())]), headers: [:])
        case "prompts/list":
            return .message(MCPCalyxMCPWire.resultMessage(id: id, result: ["prompts": AnyCodable([AnyCodable]())]), headers: [:])
        case "resources/read":
            return .routed(.buffered(await readResource(id: id, params: params) { $0 }))
        case "tools/call":
            return .routed(await callTool(
                id: id, params: params, meta: params["_meta"]?.objectValue ?? [:], paneContext: paneContext,
                clientName: clientName, clientDeclaredUI: clientDeclaredUI,
                sessionNonce: payload?.nonce, isLegacy: true, allowStream: allowStream, modelContextProvider: modelContextProvider,
                decorate: { $0 }
            ))
        default:
            return .message(
                MCPCalyxMCPWire.errorMessage(id: id, code: MCPCalyxMCPWire.methodNotFoundCode, message: "Method not found: \(incoming.method)"),
                headers: [:]
            )
        }
    }

    /// Echoes a supported requested version, otherwise answers 2025-11-25,
    /// and mints the session id.
    @MainActor
    private func initialize(id: JSONRPCId, params: [String: AnyCodable], paneContext: MCPPaneResolutionContext) async -> LegacyOutcome {
        let requested = params["protocolVersion"]?.stringValue.flatMap(MCPProtocolVersion.init(rawValue:))
        let negotiated = requested.flatMap { $0.isModern ? nil : $0 } ?? Self.legacyFallbackVersion
        let clientDeclaredUI = params["capabilities"]?["extensions"]?[MCPCalyxMCPWire.uiExtensionID] != nil
        let clientName = params["clientInfo"]?["name"]?.stringValue ?? paneContext.clientName
        let payload = MCPDownstreamSessionPayload(
            version: Self.sessionPayloadVersion,
            negotiatedProtocolVersion: negotiated.rawValue,
            clientDeclaredUI: clientDeclaredUI,
            clientName: clientName,
            nonce: UUID().uuidString,
            issuedAt: clock.now()
        )
        if let surfaceID = paneContext.surfaceID {
            await hub.recordPane(surfaceID, forSessionNonce: payload.nonce)
        }
        let sessionID = MCPDownstreamSessionID.mint(payload: payload, bearerToken: sessionBearerToken())
        let result: [String: AnyCodable] = [
            "protocolVersion": AnyCodable(negotiated.rawValue),
            "capabilities": Self.serverCapabilities,
            "serverInfo": MCPCalyxMCPWire.serverInfo,
        ]
        return .message(MCPCalyxMCPWire.resultMessage(id: id, result: result), headers: [Self.sessionHeader: sessionID])
    }

    private static func requestID(_ value: AnyCodable?) -> JSONRPCId? {
        if let int = value?.intValue { return .int(int) }
        if let string = value?.stringValue { return .string(string) }
        return nil
    }

    // MARK: - Shared methods

    /// The catalog for the calling pane, plus `app_context`.
    private func listedTools(clientDeclaredUI: Bool, surfaceID: UUID?) async -> [AnyCodable] {
        let result = await catalog.currentCatalog(clientDeclaredUI: clientDeclaredUI, surfaceID: surfaceID)
        return result.tools.map { tool -> AnyCodable in
            var raw = tool.exportedRaw
            raw["name"] = AnyCodable(tool.exportedName)
            return AnyCodable(raw)
        } + [AnyCodable(MCPAppContextTool.definitionRaw)]
    }

    /// `resources/read` of a `ui://<alias>/...` URI, answered with the
    /// owning server's result passed through `decorate`.
    @MainActor
    private func readResource(
        id: JSONRPCId,
        params: [String: AnyCodable],
        decorate: ([String: AnyCodable]) -> [String: AnyCodable]
    ) async -> HTTPResponse {
        guard let uri = params["uri"]?.stringValue,
              let (alias, upstreamURI) = MCPUIResourceURI.resolve(exportedURI: uri),
              let server = registry.servers.first(where: { $0.alias.rawValue == alias }),
              let connection = await connections.connection(forServerID: server.id)
        else {
            return MCPCalyxMCPWire.jsonResponse(
                statusCode: 200,
                message: MCPCalyxMCPWire.errorMessage(id: id, code: MCPCalyxMCPWire.invalidParamsCode, message: "Unknown resource")
            )
        }
        do {
            let result = try await connection.readResource(uri: upstreamURI)
            return MCPCalyxMCPWire.jsonResponse(statusCode: 200, message: MCPCalyxMCPWire.resultMessage(id: id, result: decorate(result)))
        } catch MCPClientProtocolError.serverError(let rpcError) {
            return MCPCalyxMCPWire.jsonResponse(
                statusCode: 200,
                message: MCPCalyxMCPWire.errorMessage(id: id, code: rpcError.code, message: rpcError.message, data: rpcError.data)
            )
        } catch {
            return MCPCalyxMCPWire.jsonResponse(
                statusCode: 200,
                message: MCPCalyxMCPWire.errorMessage(id: id, code: MCPCalyxMCPWire.internalErrorCode, message: "resources/read failed: \(error)")
            )
        }
    }

    // MARK: - tools/call

    private enum CallEvent: Sendable {
        case progress(MCPProgressUpdate)
        case keepAliveDue
        case finished(MCPCallToolResult)
    }

    @MainActor
    private func callTool(
        id: JSONRPCId,
        params: [String: AnyCodable],
        meta: [String: AnyCodable],
        paneContext: MCPPaneResolutionContext,
        clientName: String?,
        clientDeclaredUI: Bool,
        sessionNonce: String?,
        isLegacy: Bool,
        allowStream: Bool,
        modelContextProvider: (any MCPAppModelContextProviding)?,
        decorate: @escaping @Sendable ([String: AnyCodable]) -> [String: AnyCodable]
    ) async -> RoutedResponse {
        guard let name = params["name"]?.stringValue else {
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 200,
                message: MCPCalyxMCPWire.errorMessage(id: id, code: MCPCalyxMCPWire.invalidParamsCode, message: "params.name is missing")
            ))
        }
        let arguments = params["arguments"]?.objectValue ?? [:]

        if name == MCPAppContextTool.name {
            let result = modelContextProvider.map { MCPAppContextTool.result(surfaceID: paneContext.surfaceID, provider: $0) }
                ?? MCPAppContextTool.emptyResult
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 200, message: MCPCalyxMCPWire.resultMessage(id: id, result: decorate(result.raw))
            ))
        }

        if let resolved = await catalog.resolve(exportedName: name, surfaceID: paneContext.surfaceID),
           !resolved.definition.visibility.contains(.model) {
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 200,
                message: MCPCalyxMCPWire.errorMessage(
                    id: id, code: MCPCalyxMCPWire.appOnlyToolCode,
                    message: "Tool \(name) is only callable from its MCP App view"
                )
            ))
        }

        let progressToken = meta["progressToken"]
        let (events, eventSink) = AsyncStream<CallEvent>.makeStream()
        let progress: MCPProgressHandler? = progressToken == nil ? nil : { @Sendable update in
            eventSink.yield(.progress(update))
        }
        let cancellationKey = MCPDownstreamCancellationKey(sessionNonce: sessionNonce, requestID: id)
        let coordinator = self.coordinator
        let callTask = Task { @MainActor in
            let result = await coordinator.callProxiedTool(
                exportedName: name,
                arguments: arguments,
                surfaceID: paneContext.surfaceID,
                clientName: clientName,
                clientDeclaredUI: clientDeclaredUI,
                cancellationKey: cancellationKey,
                progress: progress
            )
            eventSink.yield(.finished(result))
            eventSink.finish()
        }
        let clock = self.clock
        let keepAliveTask: Task<Void, Never>? = allowStream ? Task {
            while !Task.isCancelled {
                await clock.sleep(for: MCPCalyxMCPNotificationHub.keepAliveInterval)
                guard !Task.isCancelled else { return }
                eventSink.yield(.keepAliveDue)
            }
        } : nil
        let stopAll: @Sendable () -> Void = {
            callTask.cancel()
            keepAliveTask?.cancel()
        }

        let hub = self.hub
        let callToken = UUID()
        // Only the legacy generation cancels by `notifications/cancelled`.
        if isLegacy {
            await hub.registerCall(cancellationKey, token: callToken, cancel: stopAll)
        }

        let responseFrame: @Sendable (MCPCallToolResult) -> [String: AnyCodable] = { result in
            MCPCalyxMCPWire.resultMessage(id: id, result: decorate(result.raw))
        }
        let progressFrame: @Sendable (MCPProgressUpdate) -> Data = { update in
            var progressParams: [String: AnyCodable] = [
                "progress": AnyCodable(update.progress),
            ]
            if let progressToken { progressParams["progressToken"] = progressToken }
            if let total = update.total { progressParams["total"] = AnyCodable(total) }
            if let message = update.message { progressParams["message"] = AnyCodable(message) }
            return MCPCalyxMCPWire.sseFrame(MCPCalyxMCPWire.notificationMessage(method: "notifications/progress", params: progressParams))
        }

        // Plain JSON unless something must be sent before the result.
        let first: CallEvent? = await withTaskCancellationHandler {
            for await event in events {
                switch event {
                case .finished:
                    return event
                case .progress, .keepAliveDue:
                    if allowStream { return event }
                }
            }
            return nil
        } onCancel: {
            stopAll()
        }

        switch first {
        case .finished(let result):
            keepAliveTask?.cancel()
            await hub.unregisterCall(cancellationKey, token: callToken)
            return .buffered(MCPCalyxMCPWire.jsonResponse(statusCode: 200, message: responseFrame(result)))
        case nil:
            stopAll()
            await hub.unregisterCall(cancellationKey, token: callToken)
            return .buffered(MCPCalyxMCPWire.jsonResponse(
                statusCode: 200,
                message: MCPCalyxMCPWire.errorMessage(id: id, code: MCPCalyxMCPWire.internalErrorCode, message: "The call was cancelled")
            ))
        case .progress, .keepAliveDue:
            let (body, bodySink) = AsyncStream<Data>.makeStream()
            // A stream opened by the keep-alive tick starts with the head
            // alone; the next tick sends the first comment.
            if case .progress(let update)? = first {
                bodySink.yield(progressFrame(update))
            }
            let forwarder = Task {
                for await event in events {
                    switch event {
                    case .progress(let update):
                        bodySink.yield(progressFrame(update))
                    case .keepAliveDue:
                        bodySink.yield(MCPCalyxMCPWire.keepAliveFrame)
                    case .finished(let result):
                        bodySink.yield(MCPCalyxMCPWire.sseFrame(responseFrame(result)))
                    }
                }
                keepAliveTask?.cancel()
                await hub.unregisterCall(cancellationKey, token: callToken)
                bodySink.finish()
            }
            bodySink.onTermination = { _ in
                stopAll()
                forwarder.cancel()
            }
            return .stream(head: MCPCalyxMCPWire.eventStreamHead(), body: body)
        }
    }
}
