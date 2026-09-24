//
//  MCPHostCoordinator.swift
//  Calyx
//
//  Runs one proxied `tools/call` from a downstream agent: resolves the
//  exported name, waits for the server's connection, calls the upstream
//  tool, and tells the view host when Calyx renders the result of a tool
//  that declares a UI resource (`_meta.ui`). An app tool (registered by a
//  view) is called on that view through the view host instead.
//
//  Waiting on a connection that is not `ready`:
//    - `connecting` / `restarting`: no timer, until `ready` or `failed`.
//    - `needsAuthorization` / `authorizing`: the sign-in prompt is shown
//      once, then `ready` is awaited for `authorizationWait` seconds on
//      the injected clock. Past that the call fails.
//    - `failed` / `disabled`: fails at once.
//  Cancelling the Task running `callProxiedTool` cancels the upstream call.
//

import Foundation

protocol MCPConnectionLookup: Sendable {
    func connection(forServerID serverID: MCPServerID) async -> (any MCPUpstreamConnecting)?
}

protocol MCPCatalogProviding: Sendable {
    /// The tool `exportedName` names for the caller in `surfaceID`. An app
    /// tool resolves only for the pane whose view registered it.
    func resolve(exportedName: String, surfaceID: UUID?) async -> MCPCatalogResolvedTool?
    func currentCatalog(clientDeclaredUI: Bool, surfaceID: UUID?) async -> MCPCatalogResult
}

@MainActor
final class MCPHostCoordinator {

    /// How long a call waits for a server that needs sign-in.
    static let authorizationWait: TimeInterval = 120

    private let connections: any MCPConnectionLookup
    private let catalog: any MCPCatalogProviding
    private let viewHosting: any MCPAppViewHosting
    private let elicitationPresenting: any MCPElicitationPresenting
    private let authorizationPrompting: any MCPAuthorizationPrompting
    /// Main-actor isolated: the pane's working directory lives in
    /// main-actor state (`SurfacePropertyStore`).
    private let cwdResolver: @MainActor @Sendable (UUID) -> URL?
    private let clock: any MCPClock

    init(
        connections: any MCPConnectionLookup,
        catalog: any MCPCatalogProviding,
        viewHosting: any MCPAppViewHosting,
        elicitationPresenting: any MCPElicitationPresenting,
        authorizationPrompting: any MCPAuthorizationPrompting,
        cwdResolver: @escaping @MainActor @Sendable (UUID) -> URL?,
        clock: any MCPClock = SystemMCPClock()
    ) {
        self.connections = connections
        self.catalog = catalog
        self.viewHosting = viewHosting
        self.elicitationPresenting = elicitationPresenting
        self.authorizationPrompting = authorizationPrompting
        self.cwdResolver = cwdResolver
        self.clock = clock
    }

    /// A resolved pane always renders: the agent in a terminal cannot.
    /// Without a pane, a caller that declared the UI extension renders
    /// itself; any other caller gets a standalone panel.
    nonisolated static func renderDecision(surfaceID: UUID?, clientDeclaredUI: Bool) -> MCPRenderDecision {
        if let surfaceID {
            return .render(surfaceID: surfaceID)
        }
        return clientDeclaredUI ? .stepAside : .render(surfaceID: nil)
    }

    /// Returns the upstream or view result verbatim, or an `isError` result
    /// naming why the call could not be made.
    func callProxiedTool(
        exportedName: String,
        arguments: [String: AnyCodable],
        surfaceID: UUID?,
        clientName: String?,
        clientDeclaredUI: Bool,
        cancellationKey: MCPDownstreamCancellationKey,
        progress: MCPProgressHandler?
    ) async -> MCPCallToolResult {
        guard let resolved = await catalog.resolve(exportedName: exportedName, surfaceID: surfaceID) else {
            return Self.errorResult("Tool \(exportedName) is not offered by any configured MCP server. The server may have been removed.")
        }
        if case .app(let appSurfaceID) = resolved.origin {
            return await viewHosting.callAppTool(surfaceID: appSurfaceID, name: resolved.upstreamToolName, arguments: arguments)
        }
        guard let connection = await connections.connection(forServerID: resolved.serverID) else {
            return Self.errorResult("MCP server \(resolved.serverDisplayName) is no longer configured.")
        }

        switch await waitUntilReady(connection, resolved: resolved, surfaceID: surfaceID) {
        case .ready:
            break
        case .unavailable(let reason):
            return Self.errorResult(reason)
        }

        let cwd = surfaceID.flatMap { cwdResolver($0) }
        let context = MCPToolCallContext(surfaceID: surfaceID, cwd: cwd, progress: progress)

        // Only a tool that declares a UI resource has anything to render.
        var renderedInvocationID: MCPInvocationID?
        if resolved.definition.ui != nil,
           case .render(let renderSurfaceID) = Self.renderDecision(surfaceID: surfaceID, clientDeclaredUI: clientDeclaredUI) {
            let invocation = MCPUIToolInvocation(
                id: MCPInvocationID(),
                serverID: resolved.serverID,
                serverDisplayName: resolved.serverDisplayName,
                tool: resolved.definition,
                upstreamRequestID: cancellationKey.requestID,
                arguments: arguments,
                surfaceID: renderSurfaceID,
                clientName: clientName,
                clientDeclaredUI: clientDeclaredUI,
                requestedAt: clock.now()
            )
            let session = MCPConnectionAppServerSession(connection: connection, serverDisplayName: resolved.serverDisplayName)
            await viewHosting.uiToolInvocationDidStart(invocation, session: session)
            renderedInvocationID = invocation.id
        }

        let outcome = await connection.callTool(name: resolved.upstreamToolName, arguments: arguments, context: context)
        let result = Self.result(for: outcome, serverDisplayName: resolved.serverDisplayName)
        // The view receives the same result the agent does.
        if let renderedInvocationID {
            if case .cancelled = outcome {
                await viewHosting.uiToolInvocationWasCancelled(renderedInvocationID)
            } else {
                await viewHosting.uiToolInvocationDidFinish(renderedInvocationID, result: result)
            }
        }
        return result
    }

    // MARK: - Waiting for the connection

    private enum Readiness {
        case ready
        case unavailable(reason: String)
    }

    /// What one state means for a waiting call.
    private enum StateVerdict {
        case ready
        case wait
        case waitForAuthorization
        case unavailable(reason: String)
    }

    private func waitUntilReady(
        _ connection: any MCPUpstreamConnecting,
        resolved: MCPCatalogResolvedTool,
        surfaceID: UUID?
    ) async -> Readiness {
        // Subscribed before reading the state, so no transition is missed.
        let events = await connection.events
        let serverName = resolved.serverDisplayName
        switch Self.verdict(for: await connection.state(), serverName: serverName) {
        case .ready:
            return .ready
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .waitForAuthorization:
            return await waitForAuthorization(events: events, resolved: resolved, surfaceID: surfaceID)
        case .wait:
            for await event in events {
                guard case .stateChanged(let state) = event else { continue }
                switch Self.verdict(for: state, serverName: serverName) {
                case .ready:
                    return .ready
                case .unavailable(let reason):
                    return .unavailable(reason: reason)
                case .waitForAuthorization:
                    return await waitForAuthorization(events: events, resolved: resolved, surfaceID: surfaceID)
                case .wait:
                    continue
                }
            }
            return .unavailable(reason: Self.endedReason(serverName: serverName))
        }
    }

    private func waitForAuthorization(
        events: AsyncStream<MCPServerEvent>,
        resolved: MCPCatalogResolvedTool,
        surfaceID: UUID?
    ) async -> Readiness {
        await authorizationPrompting.promptSignIn(
            serverID: resolved.serverID,
            serverDisplayName: resolved.serverDisplayName,
            surfaceID: surfaceID
        )
        let serverName = resolved.serverDisplayName
        let clock = self.clock
        let timedOut = Readiness.unavailable(
            reason: "MCP server \(serverName) needs sign-in, and sign-in did not finish within \(Int(Self.authorizationWait)) seconds."
        )
        return await withTaskGroup(of: Readiness?.self) { group in
            group.addTask {
                for await event in events {
                    guard case .stateChanged(let state) = event else { continue }
                    switch Self.verdict(for: state, serverName: serverName) {
                    case .ready:
                        return .ready
                    case .unavailable(let reason):
                        return .unavailable(reason: reason)
                    case .wait, .waitForAuthorization:
                        continue
                    }
                }
                // Cancelled by the timeout, or the connection ended.
                return Task.isCancelled ? nil : .unavailable(reason: Self.endedReason(serverName: serverName))
            }
            group.addTask {
                await clock.sleep(for: Self.authorizationWait)
                return Task.isCancelled ? nil : timedOut
            }
            var outcome: Readiness?
            while outcome == nil, let next = await group.next() {
                outcome = next
            }
            group.cancelAll()
            // Both children return nil only when this Task was cancelled.
            return outcome ?? .unavailable(reason: "The call was cancelled.")
        }
    }

    private nonisolated static func verdict(for state: MCPConnectionState, serverName: String) -> StateVerdict {
        switch state {
        case .ready:
            return .ready
        case .connecting, .restarting:
            return .wait
        case .needsAuthorization, .authorizing:
            return .waitForAuthorization
        case .failed(let failure):
            return .unavailable(reason: "MCP server \(serverName) failed: \(failure.reason)")
        case .disabled:
            return .unavailable(reason: "MCP server \(serverName) is disabled.")
        }
    }

    private nonisolated static func endedReason(serverName: String) -> String {
        "The connection to MCP server \(serverName) was stopped."
    }

    // MARK: - Results

    private static func result(for outcome: MCPUpstreamClient.ToolCallOutcome, serverDisplayName: String) -> MCPCallToolResult {
        switch outcome {
        case .result(let result):
            return result
        case .cancelled:
            return errorResult("The call was cancelled.")
        case .protocolError(let error):
            return errorResult("MCP server \(serverDisplayName) did not complete the call: \(describe(error))")
        }
    }

    private static func describe(_ error: MCPClientProtocolError) -> String {
        switch error {
        case .timeout:
            return "the request timed out"
        case .transport(let signal):
            return "transport error \(signal)"
        case .transportClosed(let reason):
            return "the connection closed (\(reason))"
        case .mrtrRoundLimitExceeded:
            return "too many input rounds"
        case .serverError(let rpcError):
            return "\(rpcError.message) (\(rpcError.code))"
        case .malformedReply(let detail):
            return "malformed reply (\(detail))"
        case .encodingFailed(let detail):
            return "the request could not be encoded (\(detail))"
        }
    }

    static func errorResult(_ text: String) -> MCPCallToolResult {
        MCPCallToolResult(raw: [
            "content": AnyCodable([AnyCodable(["type": AnyCodable("text"), "text": AnyCodable(text)])]),
            "isError": AnyCodable(true),
        ])
    }
}
