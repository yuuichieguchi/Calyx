//
//  MCPAppUIResourceValidator.swift
//  Calyx
//
//  Checks a `resources/read` result against the MCP Apps content
//  requirements: exactly one item, `text/html;profile=mcp-app` (case and
//  whitespace ignored, `charset` allowed), text or base64 blob, at most
//  10 MiB, and a `ui://` URI. `_meta.ui` comes from the content item, or
//  from the `resources/list` entry when the item has none.
//

import Foundation

struct MCPUiResourceMetaResolved: Sendable, Equatable {
    let csp: MCPAppCSPBuilder.CSPDomains?
    /// Declared permission names. Only "clipboardWrite" is ever granted.
    let permissions: Set<String>
    let domain: String?
    let prefersBorder: Bool?
}

enum MCPAppUIResourceValidator {
    static let maxBytes = 10 * 1024 * 1024

    enum ValidationError: Error, Sendable, Equatable {
        case contentCount(Int)
        case mimeType(String)
        case invalidBase64
        case missingTextAndBlob
        case tooLarge
        case invalidURIScheme(String)
    }

    struct Resolved: Sendable, Equatable {
        let uri: String
        let html: String
        let meta: MCPUiResourceMetaResolved?
    }

    static func validate(contents: [AnyCodable], listEntryMeta: AnyCodable?) -> Result<Resolved, ValidationError> {
        guard contents.count == 1 else { return .failure(.contentCount(contents.count)) }
        let item = contents[0]

        let uri = item["uri"]?.stringValue ?? ""
        guard uri.hasPrefix("ui://") else { return .failure(.invalidURIScheme(uri)) }

        let mimeType = item["mimeType"]?.stringValue ?? ""
        guard isAppMimeType(mimeType) else { return .failure(.mimeType(mimeType)) }

        let html: String
        if let text = item["text"]?.stringValue {
            guard text.utf8.count <= maxBytes else { return .failure(.tooLarge) }
            html = text
        } else if let blob = item["blob"]?.stringValue {
            guard let data = Data(base64Encoded: blob),
                  let decoded = String(data: data, encoding: .utf8) else {
                return .failure(.invalidBase64)
            }
            guard data.count <= maxBytes else { return .failure(.tooLarge) }
            html = decoded
        } else {
            return .failure(.missingTextAndBlob)
        }

        let meta = uiMeta(item["_meta"]) ?? uiMeta(listEntryMeta)
        return .success(Resolved(uri: uri, html: html, meta: meta))
    }

    /// Error text for the resource error card.
    static func describe(_ error: ValidationError) -> String {
        switch error {
        case .contentCount(let count):
            return count == 0
                ? "The UI resource has no content."
                : "The UI resource has multiple content items (\(count)); exactly one is required."
        case .mimeType(let mimeType):
            return "The UI resource has MIME type \"\(mimeType)\"; text/html;profile=mcp-app is required."
        case .invalidBase64:
            return "The UI resource blob is not valid base64-encoded UTF-8."
        case .missingTextAndBlob:
            return "The UI resource has neither text nor blob."
        case .tooLarge:
            return "The UI resource is too large (over 10 MiB)."
        case .invalidURIScheme(let uri):
            return "The UI resource URI \"\(uri)\" does not use the ui:// scheme."
        }
    }

    // MARK: - Private

    /// `text/html` with `profile=mcp-app` and at most a `charset` besides.
    private static func isAppMimeType(_ mimeType: String) -> Bool {
        let parts = mimeType.lowercased()
            .filter { !$0.isWhitespace }
            .split(separator: ";", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.first == "text/html" else { return false }
        let parameters = parts.dropFirst()
        guard parameters.contains("profile=mcp-app") else { return false }
        return parameters.allSatisfy { $0 == "profile=mcp-app" || $0.hasPrefix("charset=") }
    }

    /// `_meta.ui` of a content item or list entry. An absent or null `ui` is nil.
    private static func uiMeta(_ meta: AnyCodable?) -> MCPUiResourceMetaResolved? {
        guard let ui = meta?["ui"], let object = ui.objectValue else { return nil }

        var csp: MCPAppCSPBuilder.CSPDomains?
        if let cspObject = object["csp"]?.objectValue {
            func strings(_ key: String) -> [String] {
                (cspObject[key]?.arrayValue ?? []).compactMap(\.stringValue)
            }
            csp = MCPAppCSPBuilder.CSPDomains(
                resourceDomains: strings("resourceDomains"),
                connectDomains: strings("connectDomains"),
                frameDomains: strings("frameDomains"),
                baseUriDomains: strings("baseUriDomains")
            )
        }
        let permissions = Set((object["permissions"]?.objectValue ?? [:]).filter { !$0.value.isNull }.keys)
        return MCPUiResourceMetaResolved(
            csp: csp,
            permissions: permissions,
            domain: object["domain"]?.stringValue,
            prefersBorder: object["prefersBorder"]?.boolValue
        )
    }
}
