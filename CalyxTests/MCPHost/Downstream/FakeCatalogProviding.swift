//
//  FakeCatalogProviding.swift
//  CalyxTests
//
//  `MCPCatalogProviding` test double (API contract section 10.2 /
//  section 14). `resolve(exportedName:surfaceID:)` looks up a fixed table
//  built by the test, standing in for a real `MCPCatalogResult` produced
//  by `MCPToolCatalog.build`. As in the live catalog (section 13a.1), an
//  app tool resolves only for the pane that registered it; every
//  surfaceID asked for is recorded. `currentCatalog` returns a scripted
//  `MCPCatalogResult`, recording the arguments it was called with so a
//  caller-level test (the router) can assert the pane-scoping inputs it
//  was given.
//

import Foundation
@testable import Calyx

actor FakeCatalogProviding: MCPCatalogProviding {
    private var resolvedTools: [String: MCPCatalogResolvedTool]
    private var scriptedCurrentCatalog: MCPCatalogResult

    private(set) var currentCatalogCalls: [(clientDeclaredUI: Bool, surfaceID: UUID?)] = []
    private(set) var resolveCalls: [(exportedName: String, surfaceID: UUID?)] = []

    init(
        resolvedTools: [String: MCPCatalogResolvedTool] = [:],
        currentCatalog: MCPCatalogResult = MCPCatalogResult(tools: [], exclusions: [])
    ) {
        self.resolvedTools = resolvedTools
        self.scriptedCurrentCatalog = currentCatalog
    }

    func resolve(exportedName: String, surfaceID: UUID?) async -> MCPCatalogResolvedTool? {
        resolveCalls.append((exportedName, surfaceID))
        guard let tool = resolvedTools[exportedName] else { return nil }
        if case .app(let owner, _) = tool.origin, owner != surfaceID {
            return nil
        }
        return tool
    }

    func currentCatalog(clientDeclaredUI: Bool, surfaceID: UUID?) async -> MCPCatalogResult {
        currentCatalogCalls.append((clientDeclaredUI, surfaceID))
        return scriptedCurrentCatalog
    }

    func setResolvedTool(_ tool: MCPCatalogResolvedTool, forExportedName exportedName: String) {
        resolvedTools[exportedName] = tool
    }
}
