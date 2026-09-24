//
//  MCPCalyxMCPRouterTestSupport.swift
//  CalyxTests
//
//  Shared helper for installing a minimal, fake-backed `MCPCalyxMCPRouter`
//  via `CalyxMCPServer.setCalyxMCPRouter(_:)` (API contract section
//  10.9: "nil の間は /calyx-mcp が 503 を返す -- テストは偽物入りの
//  router を差し込む"). Every `/calyx-mcp` route-level test file needs
//  SOME router installed or its own tests would all fail with a
//  meaningless 503 instead of the behavior each file actually means to
//  pin, so this lives once, here, rather than duplicated per file.
//
//  `MCPServerRegistry` is a real, disk-backed `@MainActor` class (no
//  protocol seam), so this helper gives it a throwaway temp directory
//  and an `InMemoryMCPSecretStore` -- callers that don't care about
//  registry contents (most of these files: they exercise header
//  validation, error-priority ordering, and pane resolution, none of
//  which touches the registry) get an empty one for free; callers that
//  DO need a registered server (alias/serverID lookups for
//  `resources/read`'s `ui://` reverse lookup) pass their own.
//

import Foundation
@testable import Calyx

@MainActor
enum MCPCalyxMCPRouterTestSupport {

    static func makeEmptyRegistry() -> MCPServerRegistry {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return MCPServerRegistry(directory: dir, secretStore: InMemoryMCPSecretStore())
    }

    static func makeCoordinator(
        connections: FakeConnectionLookup = FakeConnectionLookup(),
        catalog: any MCPCatalogProviding = FakeCatalogProviding(),
        viewHosting: any MCPAppViewHosting,
        authorizationPrompting: any MCPAuthorizationPrompting
    ) -> MCPHostCoordinator {
        MCPHostCoordinator(
            connections: connections,
            catalog: catalog,
            viewHosting: viewHosting,
            elicitationPresenting: FakeElicitationPresenter(scriptedResponses: []),
            authorizationPrompting: authorizationPrompting,
            cwdResolver: { _ in nil },
            clock: SystemMCPClock()
        )
    }

    /// A router with an empty registry, an empty catalog (resolving to
    /// `app_context` only), and no upstream connections -- suitable for
    /// every test that only exercises header validation, error-code
    /// ordering, pane resolution, or the legacy-generation envelope
    /// shape, none of which needs a real upstream tool.
    static func makeMinimalRouter(
        coordinator: MCPHostCoordinator? = nil,
        registry: MCPServerRegistry? = nil,
        catalog: any MCPCatalogProviding = FakeCatalogProviding(),
        connections: FakeConnectionLookup = FakeConnectionLookup(),
        appToolRegistry: any MCPAppToolRegistry = RouterFakeAppToolRegistry(),
        bearerToken: @escaping @Sendable () -> String
    ) -> MCPCalyxMCPRouter {
        let resolvedCoordinator = coordinator ?? makeCoordinator(
            connections: connections, catalog: catalog,
            viewHosting: NoOpAppViewHosting(), authorizationPrompting: NoOpAuthorizationPrompting()
        )
        return MCPCalyxMCPRouter(
            coordinator: resolvedCoordinator,
            registry: registry ?? makeEmptyRegistry(),
            catalog: catalog,
            connections: connections,
            appToolRegistry: appToolRegistry,
            sessionBearerToken: bearerToken,
            clock: SystemMCPClock()
        )
    }
}

@MainActor
final class NoOpAppViewHosting: MCPAppViewHosting {
    func uiToolInvocationDidStart(_ invocation: MCPUIToolInvocation, session: any MCPAppServerSession) async {}
    func hasActiveView(forSurface surfaceID: UUID) -> Bool { false }
    func isStandalonePanel(_ id: MCPInvocationID) -> Bool { false }
    func remapSurface(old: UUID, new: UUID) {}
    func teardownViews(forServer serverID: MCPServerID, reason: String) async {}
    func callAppTool(surfaceID: UUID, name: String, arguments: [String: AnyCodable]) async -> MCPCallToolResult {
        MCPCallToolResult(raw: [:])
    }
    func uiToolInvocationDidFinish(_ id: MCPInvocationID, result: MCPCallToolResult) async {}
    func uiToolInvocationWasCancelled(_ id: MCPInvocationID) async {}
    func serverConnectionChanged(serverID: MCPServerID, state: MCPConnectionState) {}
}

@MainActor
final class NoOpAuthorizationPrompting: MCPAuthorizationPrompting {
    func promptSignIn(serverID: MCPServerID, serverDisplayName: String, surfaceID: UUID?) async {}
}
