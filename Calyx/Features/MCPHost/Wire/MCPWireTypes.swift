//
//  MCPWireTypes.swift
//  Calyx
//
//  MCP wire payloads mirrored from the 2026-07-28 and 2025-11-25 schema.json.
//  A property is non-optional only when the schema lists it in `required`;
//  every optional property decodes an absent key and an explicit `null` to nil.
//

import Foundation

// MARK: - Implementation

/// `Implementation`: name and version of an MCP client or server.
/// `icons` is not retained.
struct MCPImplementation: Sendable, Codable, Equatable {
    let name: String
    let version: String
    let title: String?
    let description: String?
    let websiteUrl: String?
}

// MARK: - Client Capabilities

/// `ClientCapabilities.elicitation`. An empty object (`{}`) declares support
/// for that mode; the contents are opaque.
struct MCPElicitationCapability: Sendable, Codable, Equatable {
    let form: [String: AnyCodable]?
    let url: [String: AnyCodable]?
}

struct MCPRootsCapability: Sendable, Codable, Equatable {
    let listChanged: Bool?
}

/// `ClientCapabilities`. `sampling` is not modeled; Calyx does not declare it.
struct MCPClientCapabilities: Sendable, Codable, Equatable {
    /// Keyed by extension identifier (for example `io.modelcontextprotocol/ui`).
    var extensions: [String: [String: AnyCodable]]?
    var elicitation: MCPElicitationCapability?
    var roots: MCPRootsCapability?
}

// MARK: - Server Capabilities

struct MCPToolsServerCapability: Sendable, Codable, Equatable {
    let listChanged: Bool?
}

struct MCPPromptsServerCapability: Sendable, Codable, Equatable {
    let listChanged: Bool?
}

struct MCPResourcesServerCapability: Sendable, Codable, Equatable {
    let subscribe: Bool?
    let listChanged: Bool?
}

/// `ServerCapabilities`.
struct MCPServerCapabilities: Sendable, Codable, Equatable {
    var tools: MCPToolsServerCapability?
    var prompts: MCPPromptsServerCapability?
    var resources: MCPResourcesServerCapability?
    var logging: [String: AnyCodable]?
    var completions: [String: AnyCodable]?
    var extensions: [String: [String: AnyCodable]]?
}

// MARK: - Handshake Results

/// `InitializeResult` (2025-11-25 and earlier).
struct MCPInitializeResult: Sendable, Codable, Equatable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPImplementation
    /// Shown in Settings only. Never forwarded to downstream clients.
    let instructions: String?
}

/// `DiscoverResult` (2026-07-28, `server/discover`).
struct MCPDiscoverResult: Sendable, Codable, Equatable {
    /// `"complete"` or `"input_required"`.
    let resultType: String
    /// Same shape as `data.supported` of the -32022 error.
    let supportedVersions: [String]?
    let capabilities: MCPServerCapabilities
    /// `"public"` or `"private"`.
    let cacheScope: String
    let instructions: String?
    let ttlMs: Int
    /// From the result `_meta["io.modelcontextprotocol/serverInfo"]`; nil
    /// when absent. Decoded only, never encoded.
    let serverInfo: MCPImplementation?

    init(
        resultType: String,
        supportedVersions: [String]?,
        capabilities: MCPServerCapabilities,
        cacheScope: String,
        instructions: String?,
        ttlMs: Int,
        serverInfo: MCPImplementation? = nil
    ) {
        self.resultType = resultType
        self.supportedVersions = supportedVersions
        self.capabilities = capabilities
        self.cacheScope = cacheScope
        self.instructions = instructions
        self.ttlMs = ttlMs
        self.serverInfo = serverInfo
    }

    private enum CodingKeys: String, CodingKey {
        case resultType, supportedVersions, capabilities, cacheScope, instructions, ttlMs
        case meta = "_meta"
    }

    /// `ResultMetaObject`, reduced to the key read here.
    private struct ResultMeta: Decodable {
        let serverInfo: MCPImplementation?

        private enum CodingKeys: String, CodingKey {
            case serverInfo = "io.modelcontextprotocol/serverInfo"
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resultType = try container.decode(String.self, forKey: .resultType)
        self.supportedVersions = try container.decodeIfPresent([String].self, forKey: .supportedVersions)
        self.capabilities = try container.decode(MCPServerCapabilities.self, forKey: .capabilities)
        self.cacheScope = try container.decode(String.self, forKey: .cacheScope)
        self.instructions = try container.decodeIfPresent(String.self, forKey: .instructions)
        self.ttlMs = try container.decode(Int.self, forKey: .ttlMs)
        self.serverInfo = try container.decodeIfPresent(ResultMeta.self, forKey: .meta)?.serverInfo
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resultType, forKey: .resultType)
        try container.encodeIfPresent(supportedVersions, forKey: .supportedVersions)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(cacheScope, forKey: .cacheScope)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encode(ttlMs, forKey: .ttlMs)
    }
}

// MARK: - Multi Round-Trip Requests (2026-07-28)

/// `InputRequiredResult`.
struct MCPInputRequiredResult: Sendable, Codable, Equatable {
    /// `"input_required"`.
    let resultType: String
    /// Sent back verbatim when the request is retried.
    let requestState: String?
    /// Keyed by server-assigned identifiers.
    let inputRequests: [String: MCPInputRequest]?
}

/// `InputRequest`: `anyOf [CreateMessageRequest, ListRootsRequest, ElicitRequest]`,
/// each of the shape `{method, params}`.
struct MCPInputRequest: Sendable, Codable, Equatable {
    /// `"elicitation/create"`, `"sampling/createMessage"`, or `"roots/list"`.
    let method: String
    let params: AnyCodable?
}

// MARK: - Elicitation

/// `ElicitRequestParams`: `anyOf [ElicitRequestFormParams, ElicitRequestURLParams]`.
struct MCPElicitRequestParams: Sendable, Codable, Equatable {
    let message: String
    /// `"form"` or `"url"`. Absent means form: the form variant does not
    /// require the key.
    let mode: String?
    /// Required by the form variant.
    let requestedSchema: MCPElicitRequestedSchema?
    /// Required by the URL variant.
    let url: String?
    /// Required by the 2025-11-25 URL variant; not present in 2026-07-28.
    /// Matched against `notifications/elicitation/complete`.
    let elicitationId: String?
}

/// `ElicitRequestFormParams.requestedSchema`.
struct MCPElicitRequestedSchema: Sendable, Codable, Equatable {
    /// JSON key `$schema`.
    let schemaDialect: String?
    /// `"object"`.
    let type: String
    let properties: [String: AnyCodable]?
    let required: [String]?

    enum CodingKeys: String, CodingKey {
        case schemaDialect = "$schema"
        case type, properties, required
    }
}

/// `ElicitResult`.
struct MCPElicitResult: Sendable, Codable, Equatable {
    /// `"accept"`, `"decline"`, or `"cancel"`.
    let action: String
    /// Present only for an accepted form-mode elicitation.
    let content: [String: AnyCodable]?
}

// MARK: - Roots

struct MCPRoot: Sendable, Codable, Equatable {
    let uri: String
    let name: String?
}

struct MCPListRootsResult: Sendable, Codable, Equatable {
    let roots: [MCPRoot]
}

// MARK: - Notifications

/// `ProgressNotificationParams`.
struct MCPProgressNotificationParams: Sendable, Codable, Equatable {
    let progress: Double
    let progressToken: JSONRPCId
    let total: Double?
    let message: String?
}

/// `CancelledNotificationParams`. `requestId` is required by 2026-07-28 but
/// not by 2025-11-25, so it is optional here.
struct MCPCancelledNotificationParams: Sendable, Codable, Equatable {
    let requestId: JSONRPCId?
    let reason: String?
}

// MARK: - Request Meta (2026-07-28)

/// `RequestMetaObject`: the per-request `_meta` object, keyed by the
/// `io.modelcontextprotocol/` namespace. `progressToken` is inherited from
/// `MetaObject` and carries no prefix.
struct MCPRequestMetaObject: Sendable, Codable, Equatable {
    let clientCapabilities: MCPClientCapabilities?
    let clientInfo: MCPImplementation?
    let logLevel: String?
    /// Must equal the `MCP-Protocol-Version` header on HTTP.
    let protocolVersion: String?
    let progressToken: JSONRPCId?

    enum CodingKeys: String, CodingKey {
        case clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
        case clientInfo = "io.modelcontextprotocol/clientInfo"
        case logLevel = "io.modelcontextprotocol/logLevel"
        case protocolVersion = "io.modelcontextprotocol/protocolVersion"
        case progressToken
    }
}
