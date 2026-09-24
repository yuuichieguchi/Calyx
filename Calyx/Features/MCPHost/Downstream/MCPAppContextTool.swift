//
//  MCPAppContextTool.swift
//  Calyx
//
//  The pane-scoped `app_context` tool: the latest model context of every
//  live view in the calling pane. Always listed, outside the catalog.
//

import Foundation

enum MCPAppContextTool {

    static let name = "app_context"

    /// Carries the view, server and tool of each content block.
    static let entryMetaKey = "calyx/appContext"

    /// The definition listed by `tools/list`.
    static let definitionRaw: [String: AnyCodable] = [
        "name": AnyCodable(name),
        "description": AnyCodable(
            "Returns the latest context reported by the MCP App views open in this terminal pane: " +
            "one text block per view, holding that view's structured content as JSON."
        ),
        "inputSchema": AnyCodable([
            "type": AnyCodable("object"),
            "properties": AnyCodable([String: AnyCodable]()),
        ]),
    ]

    /// The result for a pane with no live view.
    static let emptyResult = MCPCallToolResult(raw: [
        "content": AnyCodable([AnyCodable]()),
        "isError": AnyCodable(false),
    ])

    /// One text block per live view of `surfaceID`. The text is the JSON of
    /// the entry's `structuredContent`, else of its `content`, else `{}`.
    /// Empty `content` when `surfaceID` is nil or the pane has no live view.
    @MainActor
    static func result(surfaceID: UUID?, provider: any MCPAppModelContextProviding) -> MCPCallToolResult {
        let entries = surfaceID.map { provider.modelContexts(forSurface: $0) } ?? []
        let blocks = entries.map { entry -> AnyCodable in
            let body: AnyCodable = entry.structuredContent
                ?? entry.content.map { AnyCodable($0) }
                ?? AnyCodable([String: AnyCodable]())
            return AnyCodable([
                "type": AnyCodable("text"),
                "text": AnyCodable(jsonText(body)),
                "_meta": AnyCodable([
                    entryMetaKey: AnyCodable([
                        "viewID": AnyCodable(entry.viewID.uuidString),
                        "serverDisplayName": AnyCodable(entry.serverDisplayName),
                        "toolName": AnyCodable(entry.toolName),
                    ]),
                ]),
            ])
        }
        return MCPCallToolResult(raw: [
            "content": AnyCodable(blocks),
            "isError": AnyCodable(false),
        ])
    }

    private static func jsonText(_ value: AnyCodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `AnyCodable` holds only JSON values, so encoding cannot fail.
        guard let data = try? encoder.encode(value) else {
            preconditionFailure("AnyCodable JSON encoding failed")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
