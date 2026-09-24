//
//  MCPToolDefinition.swift
//  Calyx
//
//  An upstream `Tool` definition with the MCP Apps metadata Calyx reads from it.
//

import Foundation

/// An upstream tool definition. `raw` is the object exactly as received;
/// the other properties are derived from it.
struct MCPToolDefinition: Sendable, Equatable {
    let name: String
    let title: String?
    /// The upstream definition, unmodified (including `execution.taskSupport`,
    /// `_meta`, and keys the schema does not name).
    let raw: [String: AnyCodable]
    /// From `_meta.ui.visibility`, read whether or not a `resourceUri` is
    /// declared. Defaults to `[.model, .app]` when absent.
    let visibility: Set<MCPToolVisibility>
    /// Non-nil when a `resourceUri` is declared, whatever its scheme.
    let ui: MCPToolUIMeta?
    /// `x-mcp-header` declarations on `inputSchema` properties.
    let headerMirrors: [MCPHTTPHeaderMirror]

    /// Throws only when `name` is missing or not a string.
    init(raw: [String: AnyCodable]) throws {
        guard let name = raw["name"]?.stringValue else {
            throw DecodingError.keyNotFound(
                RawKey.name,
                DecodingError.Context(codingPath: [], debugDescription: "Tool definition has no string \"name\"")
            )
        }
        self.name = name
        self.title = raw["title"]?.stringValue
        self.raw = raw

        let meta = raw["_meta"]
        let uiObject = meta?["ui"]

        if let values = uiObject?["visibility"]?.arrayValue {
            self.visibility = Set(values.compactMap { $0.stringValue.flatMap(MCPToolVisibility.init(rawValue:)) })
        } else {
            self.visibility = [.model, .app]
        }

        // The nested `_meta.ui.resourceUri` form takes precedence over the
        // deprecated flat `_meta["ui/resourceUri"]` key.
        if let uri = uiObject?["resourceUri"]?.stringValue ?? meta?["ui/resourceUri"]?.stringValue {
            self.ui = MCPToolUIMeta(declaredResourceURI: uri, isUIScheme: uri.hasPrefix("ui://"))
        } else {
            self.ui = nil
        }

        self.headerMirrors = Self.headerMirrors(in: raw["inputSchema"], path: [])
    }

    /// Walks `properties` maps only. Declarations reached through `items`,
    /// `oneOf`, `anyOf`, `allOf`, `not`, `if`/`then`/`else`, or `$ref` are
    /// not collected. Keys are visited in sorted order.
    private static func headerMirrors(in schema: AnyCodable?, path: [String]) -> [MCPHTTPHeaderMirror] {
        guard let properties = schema?["properties"]?.objectValue else { return [] }
        var mirrors: [MCPHTTPHeaderMirror] = []
        for key in properties.keys.sorted() {
            let property = properties[key]
            let propertyPath = path + [key]
            if let headerName = property?["x-mcp-header"]?.stringValue {
                mirrors.append(MCPHTTPHeaderMirror(headerName: headerName, propertyPath: propertyPath))
            }
            mirrors.append(contentsOf: headerMirrors(in: property, path: propertyPath))
        }
        return mirrors
    }

    private enum RawKey: String, CodingKey {
        case name
    }
}

/// Audiences listed in `_meta.ui.visibility`.
enum MCPToolVisibility: String, Sendable, Equatable, Hashable, Codable {
    case model
    case app
}

/// The declared UI resource of a tool.
struct MCPToolUIMeta: Sendable, Equatable {
    /// The declared `resourceUri` string, unvalidated.
    let declaredResourceURI: String
    /// Whether `declaredResourceURI` starts with `ui://`.
    let isUIScheme: Bool
}

/// An `inputSchema` property whose argument value is mirrored into an
/// `Mcp-Param-*` HTTP header.
struct MCPHTTPHeaderMirror: Sendable, Equatable {
    /// The `x-mcp-header` value, for example `"Region"`.
    let headerName: String
    /// Property keys from the top-level `properties` down to the declaring
    /// property, for example `["options", "region"]`.
    let propertyPath: [String]
}
