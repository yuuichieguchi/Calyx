//
//  MCPToolCatalog.swift
//  Calyx
//
//  The set of tools Calyx re-exports, computed from the upstream servers'
//  tool lists and the calling pane's app tools.
//

import Foundation

enum MCPCatalogToolOrigin: Sendable, Equatable {
    /// A tool of the upstream server.
    case server
    /// A tool registered by the view in that pane. Calls go to the view.
    case app(surfaceID: UUID)
}

struct MCPCatalogResolvedTool: Sendable, Equatable {
    let exportedName: String
    let serverID: MCPServerID
    /// Title for sign-in prompts and standalone panels.
    let serverDisplayName: String
    let upstreamToolName: String
    let origin: MCPCatalogToolOrigin
    let definition: MCPToolDefinition
    /// `definition.raw` with `x-mcp-header` annotations removed and a
    /// `ui://` resource URI rewritten to its exported form.
    let exportedRaw: [String: AnyCodable]
}

struct MCPCatalogExclusion: Sendable, Equatable {
    let serverID: MCPServerID
    let upstreamToolName: String
    /// Shown in Settings.
    let reason: String
}

struct MCPCatalogResult: Sendable, Equatable {
    let tools: [MCPCatalogResolvedTool]
    let exclusions: [MCPCatalogExclusion]
}

struct MCPCatalogPaneAppTool: Sendable, Equatable {
    let surfaceID: UUID
    /// The server that owns the view. Its alias prefixes the exported name.
    let serverID: MCPServerID
    let name: String
    let definition: MCPToolDefinition
}

enum MCPToolCatalog {

    private static let appToolPrefix = "app_"

    /// Servers are processed in alias order, each server's tools in list
    /// order, then `paneAppTools` in order.
    ///
    /// A server tool is excluded when an earlier tool of the same server
    /// has its name, when its top-level `execution.taskSupport` is
    /// `"required"`, or when its `x-mcp-header` annotations are invalid.
    /// Every other server tool gets an exported name, whether or not it is
    /// listed, so names do not depend on `clientDeclaredUI`. Names that
    /// need no change are assigned before the others. A server tool is
    /// listed when its visibility includes `model`, or includes `app` and
    /// `clientDeclaredUI` is true.
    ///
    /// An app tool is exported as `app_<name>` under its server's alias and
    /// is excluded when that name is already taken or its server is absent
    /// from `serverTools`.
    static func build(
        serverTools: [MCPServerID: (alias: MCPServerAlias, displayName: String, tools: [MCPToolDefinition], clientDeclaredUI: Bool)],
        paneAppTools: [MCPCatalogPaneAppTool]
    ) -> MCPCatalogResult {
        let servers = serverTools
            .map { (id: $0.key, alias: $0.value.alias, displayName: $0.value.displayName, tools: $0.value.tools, clientDeclaredUI: $0.value.clientDeclaredUI) }
            .sorted { $0.alias.rawValue < $1.alias.rawValue }

        var exclusions: [MCPCatalogExclusion] = []
        var candidates: [Candidate] = []
        for server in servers {
            var seenNames: Set<String> = []
            for tool in server.tools {
                let firstOccurrence = seenNames.insert(tool.name).inserted
                if let reason = exclusionReason(for: tool, firstOccurrence: firstOccurrence) {
                    exclusions.append(MCPCatalogExclusion(serverID: server.id, upstreamToolName: tool.name, reason: reason))
                    continue
                }
                candidates.append(Candidate(
                    serverID: server.id,
                    alias: server.alias,
                    displayName: server.displayName,
                    clientDeclaredUI: server.clientDeclaredUI,
                    tool: tool,
                    verbatimName: MCPExportedName.verbatimName(alias: server.alias.rawValue, upstreamToolName: tool.name)
                ))
            }
        }

        var takenNames: Set<String> = Set(candidates.compactMap(\.verbatimName))
        var exportedNames: [String?] = []
        for candidate in candidates {
            if let verbatimName = candidate.verbatimName {
                exportedNames.append(verbatimName)
                continue
            }
            let name = MCPExportedName.name(
                alias: candidate.alias.rawValue,
                upstreamToolName: candidate.tool.name,
                isTaken: { takenNames.contains($0) }
            )
            if takenNames.insert(name).inserted {
                exportedNames.append(name)
            } else {
                exclusions.append(MCPCatalogExclusion(
                    serverID: candidate.serverID,
                    upstreamToolName: candidate.tool.name,
                    reason: "exported name \(name) is already used by another tool"
                ))
                exportedNames.append(nil)
            }
        }

        var tools: [MCPCatalogResolvedTool] = []
        for (candidate, exportedName) in zip(candidates, exportedNames) {
            guard let exportedName, isListed(candidate.tool, clientDeclaredUI: candidate.clientDeclaredUI) else { continue }
            tools.append(MCPCatalogResolvedTool(
                exportedName: exportedName,
                serverID: candidate.serverID,
                serverDisplayName: candidate.displayName,
                upstreamToolName: candidate.tool.name,
                origin: .server,
                definition: candidate.tool,
                exportedRaw: exportedRaw(for: candidate.tool, alias: candidate.alias)
            ))
        }

        for appTool in paneAppTools {
            guard let server = serverTools[appTool.serverID] else {
                exclusions.append(MCPCatalogExclusion(
                    serverID: appTool.serverID,
                    upstreamToolName: appTool.name,
                    reason: "the server that owns this app tool is not in the catalog"
                ))
                continue
            }
            let name = MCPExportedName.name(
                alias: server.alias.rawValue,
                upstreamToolName: appToolPrefix + appTool.name,
                isTaken: { takenNames.contains($0) }
            )
            guard takenNames.insert(name).inserted else {
                exclusions.append(MCPCatalogExclusion(
                    serverID: appTool.serverID,
                    upstreamToolName: appTool.name,
                    reason: "exported name \(name) is already used by another tool"
                ))
                continue
            }
            tools.append(MCPCatalogResolvedTool(
                exportedName: name,
                serverID: appTool.serverID,
                serverDisplayName: server.displayName,
                upstreamToolName: appTool.name,
                origin: .app(surfaceID: appTool.surfaceID),
                definition: appTool.definition,
                exportedRaw: appTool.definition.raw
            ))
        }

        return MCPCatalogResult(tools: tools, exclusions: exclusions)
    }

    private struct Candidate {
        let serverID: MCPServerID
        let alias: MCPServerAlias
        let displayName: String
        let clientDeclaredUI: Bool
        let tool: MCPToolDefinition
        let verbatimName: String?
    }

    private static func exclusionReason(for tool: MCPToolDefinition, firstOccurrence: Bool) -> String? {
        guard firstOccurrence else {
            return "an earlier tool of this server has the same name"
        }
        if tool.raw["execution"]?["taskSupport"]?.stringValue == "required" {
            return "execution.taskSupport is \"required\", and Calyx does not support tasks"
        }
        return MCPXMCPHeaderValidation.validationFailureReason(for: tool)
    }

    private static func isListed(_ tool: MCPToolDefinition, clientDeclaredUI: Bool) -> Bool {
        tool.visibility.contains(.model) || (clientDeclaredUI && tool.visibility.contains(.app))
    }

    /// Rewrites both `_meta.ui.resourceUri` and the deprecated flat
    /// `_meta["ui/resourceUri"]` when they hold a `ui://` URI.
    private static func exportedRaw(for tool: MCPToolDefinition, alias: MCPServerAlias) -> [String: AnyCodable] {
        var raw = MCPXMCPHeaderValidation.strippingXMCPHeaderAnnotations(from: tool.raw)
        guard var meta = raw["_meta"]?.objectValue else { return raw }

        if var ui = meta["ui"]?.objectValue,
           let uri = ui["resourceUri"]?.stringValue,
           let exported = MCPUIResourceURI.export(upstreamURI: uri, alias: alias.rawValue) {
            ui["resourceUri"] = AnyCodable(exported)
            meta["ui"] = AnyCodable(ui)
        }
        if let uri = meta["ui/resourceUri"]?.stringValue,
           let exported = MCPUIResourceURI.export(upstreamURI: uri, alias: alias.rawValue) {
            meta["ui/resourceUri"] = AnyCodable(exported)
        }
        raw["_meta"] = AnyCodable(meta)
        return raw
    }
}
