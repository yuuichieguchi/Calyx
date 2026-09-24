//
//  MCPXMCPHeaderValidation.swift
//  Calyx
//
//  Validity of `x-mcp-header` annotations in a tool's `inputSchema`
//  (Streamable HTTP, 2026-07-28, "Schema Extension"), and their removal
//  from the schema Calyx re-exports.
//

import Foundation

enum MCPXMCPHeaderValidation {

    private static let annotationKey = "x-mcp-header"
    private static let permittedTypes: Set<String> = ["string", "integer", "boolean"]
    /// Keywords whose value maps names to subschemas that are not reachable
    /// through `properties`.
    private static let schemaMapKeywords: Set<String> = ["patternProperties", "$defs", "definitions", "dependentSchemas"]
    /// Keywords whose value is instance data, not a schema.
    private static let dataKeywords: Set<String> = ["const", "default", "enum", "examples"]

    /// Nil when every `x-mcp-header` in `inputSchema` is valid (or there is
    /// none). An annotation is valid when it sits on a property reached from
    /// the schema root through `properties` keys only, the property's
    /// `type` is `string`, `integer`, or `boolean`, and the value is a
    /// non-empty RFC 9110 token that no other annotation in the schema
    /// equals case-insensitively.
    static func validationFailureReason(for tool: MCPToolDefinition) -> String? {
        guard let schema = tool.raw["inputSchema"] else { return nil }
        var headerNames: [String: String] = [:]
        return failureReason(inSchema: schema, path: "inputSchema", onPropertiesChain: true, headerNames: &headerNames)
    }

    /// `raw` with every `x-mcp-header` annotation removed from
    /// `inputSchema`. Everything else, including property names and
    /// instance data such as `default`, is kept as is.
    static func strippingXMCPHeaderAnnotations(from raw: [String: AnyCodable]) -> [String: AnyCodable] {
        guard let schema = raw["inputSchema"] else { return raw }
        var stripped = raw
        stripped["inputSchema"] = strippingAnnotations(fromSchema: schema)
        return stripped
    }

    // MARK: - Validation

    /// `headerNames` maps each lowercased header name seen so far to the
    /// path of the property that declared it.
    private static func failureReason(
        inSchema schema: AnyCodable,
        path: String,
        onPropertiesChain: Bool,
        headerNames: inout [String: String]
    ) -> String? {
        if let elements = schema.arrayValue {
            for (index, element) in elements.enumerated() {
                if let reason = failureReason(inSchema: element, path: "\(path)[\(index)]", onPropertiesChain: false, headerNames: &headerNames) {
                    return reason
                }
            }
            return nil
        }
        guard let object = schema.objectValue else { return nil }

        if let annotation = object[annotationKey] {
            if let reason = annotationFailureReason(annotation, on: object, path: path, onPropertiesChain: onPropertiesChain, headerNames: &headerNames) {
                return reason
            }
        }

        for key in object.keys.sorted() where key != annotationKey && !dataKeywords.contains(key) {
            guard let value = object[key] else { continue }
            if key == "properties" || schemaMapKeywords.contains(key) {
                guard let entries = value.objectValue else { continue }
                let childrenOnChain = onPropertiesChain && key == "properties"
                for name in entries.keys.sorted() {
                    guard let entry = entries[name] else { continue }
                    if let reason = failureReason(inSchema: entry, path: "\(path).\(key).\(name)", onPropertiesChain: childrenOnChain, headerNames: &headerNames) {
                        return reason
                    }
                }
            } else if let reason = failureReason(inSchema: value, path: "\(path).\(key)", onPropertiesChain: false, headerNames: &headerNames) {
                return reason
            }
        }
        return nil
    }

    private static func annotationFailureReason(
        _ annotation: AnyCodable,
        on property: [String: AnyCodable],
        path: String,
        onPropertiesChain: Bool,
        headerNames: inout [String: String]
    ) -> String? {
        guard onPropertiesChain else {
            return "x-mcp-header at \(path) is not reached from the schema root through properties alone"
        }
        guard let headerName = annotation.stringValue else {
            return "x-mcp-header at \(path) is not a string"
        }
        guard !headerName.isEmpty else {
            return "x-mcp-header at \(path) is empty"
        }
        guard headerName.unicodeScalars.allSatisfy(isTokenCharacter) else {
            return "x-mcp-header at \(path) is not an HTTP token"
        }
        guard let type = property["type"]?.stringValue, permittedTypes.contains(type) else {
            return "x-mcp-header at \(path) is on a property whose type is not string, integer, or boolean"
        }
        let folded = headerName.lowercased()
        if let earlier = headerNames[folded] {
            return "x-mcp-header \"\(headerName)\" at \(path) duplicates the one at \(earlier)"
        }
        headerNames[folded] = path
        return nil
    }

    /// RFC 9110 section 5.6.2 `tchar`.
    private static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9",
             "!", "#", "$", "%", "&", "'", "*", "+", "-", ".", "^", "_", "`", "|", "~":
            return true
        default:
            return false
        }
    }

    // MARK: - Stripping

    private static func strippingAnnotations(fromSchema schema: AnyCodable) -> AnyCodable {
        if let elements = schema.arrayValue {
            return AnyCodable(elements.map(strippingAnnotations(fromSchema:)))
        }
        guard let object = schema.objectValue else { return schema }

        var result: [String: AnyCodable] = [:]
        for (key, value) in object where key != annotationKey {
            if dataKeywords.contains(key) {
                result[key] = value
            } else if key == "properties" || schemaMapKeywords.contains(key), let entries = value.objectValue {
                result[key] = AnyCodable(entries.mapValues(strippingAnnotations(fromSchema:)))
            } else {
                result[key] = strippingAnnotations(fromSchema: value)
            }
        }
        return AnyCodable(result)
    }
}
