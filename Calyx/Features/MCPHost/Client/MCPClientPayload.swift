//
//  MCPClientPayload.swift
//  Calyx
//
//  JSON payloads `MCPUpstreamClient` puts on the wire: declared client
//  capabilities, per-request `_meta`, and replies to elicitation and
//  roots input requests.
//

import Foundation

enum MCPClientPayload {

    /// The MCP Apps extension identifier.
    static let uiExtensionID = "io.modelcontextprotocol/ui"
    /// The MCP Apps view MIME type Calyx renders.
    static let appMIMEType = "text/html;profile=mcp-app"
    /// The `initialize` version sent when no era is known.
    static let latestLegacyVersion = MCPProtocolVersion.v2025_11_25

    /// `ClientCapabilities`. Declares the MCP Apps extension and both
    /// elicitation modes, never `sampling`. `roots` is declared only when
    /// `includeRoots` is true (modern requests with a known cwd).
    static func capabilities(includeRoots: Bool) -> AnyCodable {
        let emptyObject = AnyCodable([String: AnyCodable]())
        var capabilities: [String: AnyCodable] = [
            "extensions": AnyCodable([
                uiExtensionID: AnyCodable([
                    "mimeTypes": AnyCodable([AnyCodable(appMIMEType)]),
                ]),
            ]),
            "elicitation": AnyCodable([
                "form": emptyObject,
                "url": emptyObject,
            ]),
        ]
        if includeRoots {
            capabilities["roots"] = emptyObject
        }
        return AnyCodable(capabilities)
    }

    /// `Implementation`, omitting absent optional fields.
    static func implementation(_ info: MCPImplementation) -> AnyCodable {
        var object: [String: AnyCodable] = [
            "name": AnyCodable(info.name),
            "version": AnyCodable(info.version),
        ]
        if let title = info.title { object["title"] = AnyCodable(title) }
        if let description = info.description { object["description"] = AnyCodable(description) }
        if let websiteUrl = info.websiteUrl { object["websiteUrl"] = AnyCodable(websiteUrl) }
        return AnyCodable(object)
    }

    /// `initialize` params for a legacy handshake at `version`. Never
    /// declares `roots`.
    static func initializeParams(version: MCPProtocolVersion, clientInfo: MCPImplementation) -> [String: AnyCodable] {
        [
            "protocolVersion": AnyCodable(version.rawValue),
            "capabilities": capabilities(includeRoots: false),
            "clientInfo": implementation(clientInfo),
        ]
    }

    /// The 2026-07-28 `RequestMetaObject`.
    static func modernMeta(
        clientInfo: MCPImplementation,
        includeRoots: Bool,
        progressToken: Int?
    ) -> [String: AnyCodable] {
        var meta: [String: AnyCodable] = [
            "io.modelcontextprotocol/protocolVersion": AnyCodable(MCPProtocolVersion.v2026_07_28.rawValue),
            "io.modelcontextprotocol/clientCapabilities": capabilities(includeRoots: includeRoots),
            "io.modelcontextprotocol/clientInfo": implementation(clientInfo),
        ]
        if let progressToken {
            meta["progressToken"] = AnyCodable(progressToken)
        }
        return meta
    }

    /// `ElicitResult`. `content` is present only for an accepted form.
    static func elicitResult(_ response: MCPElicitationResponse, isForm: Bool) -> AnyCodable {
        switch response {
        case .accept(let content):
            var object: [String: AnyCodable] = ["action": AnyCodable("accept")]
            if isForm {
                object["content"] = AnyCodable(content)
            }
            return AnyCodable(object)
        case .decline:
            return AnyCodable(["action": AnyCodable("decline")])
        case .cancel:
            return AnyCodable(["action": AnyCodable("cancel")])
        }
    }

    /// `ListRootsResult` with the single root `cwd`.
    static func listRootsResult(cwd: URL) -> AnyCodable {
        AnyCodable([
            "roots": AnyCodable([
                AnyCodable(["uri": AnyCodable(cwd.absoluteString)]),
            ]),
        ])
    }

    /// The `tools/call` result reported when the server asks for sampling,
    /// which Calyx does not provide.
    static let samplingUnsupportedResult: [String: AnyCodable] = [
        "content": AnyCodable([
            AnyCodable([
                "type": AnyCodable("text"),
                "text": AnyCodable("The tool requested sampling (sampling/createMessage), which Calyx does not support."),
            ]),
        ]),
        "isError": AnyCodable(true),
        "resultType": AnyCodable("complete"),
    ]

    /// The `MCPDiscoverResult` for a server that answered `initialize` with
    /// `-32022` listing 2026-07-28. No `server/discover` result exists in
    /// that case: capabilities are unknown (empty), and the result is not
    /// cacheable (`cacheScope` private, `ttlMs` 0).
    static func discoverResultFromUnsupportedVersionError(supportedVersions: [String]) -> MCPDiscoverResult {
        MCPDiscoverResult(
            resultType: "complete",
            supportedVersions: supportedVersions,
            capabilities: MCPServerCapabilities(),
            cacheScope: "private",
            instructions: nil,
            ttlMs: 0
        )
    }

    /// Decodes a `Decodable` value from a JSON value.
    static func decode<T: Decodable>(_ type: T.Type, from value: AnyCodable) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
