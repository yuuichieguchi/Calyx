//
//  MCPServersJSONImporter.swift
//  Calyx
//
//  Parses pasted MCP server JSON. Accepts `{"mcpServers": {...}}`, a bare
//  name-to-server map, and a single server object. Env and header values
//  are returned apart from the transport config so they can go to the
//  secret store.
//

import Foundation

struct MCPImportedServer: Sendable, Equatable {
    /// The map key. `nil` for a single server object.
    let name: String?
    let transport: MCPServerTransportConfig
    let envValues: [String: String]
    let headerValues: [String: String]
    /// Names of `${VAR}` references absent from the environment, in order
    /// of first appearance. Those references are left as written.
    let unresolvedVariables: [String]
    let ignoredKeys: [String]
}

enum MCPServersJSONImportError: Error, Sendable, Equatable {
    /// `line` and `column` are 1-based.
    case parseError(line: Int, column: Int, message: String)
    /// Valid JSON that is not one of the accepted shapes, or a server
    /// whose fields have the wrong type or lack `command` or `url`.
    case invalidServer(name: String?, message: String)
}

enum MCPServersJSONImporter {

    private static let wrapperKey = "mcpServers"
    private static let stdioKeys: Set<String> = ["type", "command", "args", "env", "cwd"]
    private static let httpKeys: Set<String> = ["type", "url", "headers"]

    /// Servers of a map come back sorted by name. Env and header names,
    /// and ignored keys, are sorted.
    static func parse(_ jsonText: String, environment: [String: String]) throws -> [MCPImportedServer] {
        let root = try parseObject(jsonText)
        if let wrapped = root[wrapperKey] {
            guard let servers = wrapped as? [String: Any] else {
                throw MCPServersJSONImportError.invalidServer(name: nil, message: "\"\(wrapperKey)\" is not an object")
            }
            return try parseMap(servers, environment: environment)
        }
        if root["command"] != nil || root["url"] != nil {
            return [try parseServer(root, name: nil, environment: environment)]
        }
        return try parseMap(root, environment: environment)
    }

    /// Adds `2`, `3`, ... to a candidate that clashes with an existing
    /// alias or an earlier candidate, shortening the candidate so the
    /// result stays within `MCPServerAlias.maxLength`.
    static func resolveAliasClashes(candidates: [String], existingAliases: Set<String>) -> [String] {
        var taken = existingAliases
        var resolved: [String] = []
        for candidate in candidates {
            var result = candidate
            var suffix = 2
            while taken.contains(result) {
                let suffixText = String(suffix)
                result = String(candidate.prefix(MCPServerAlias.maxLength - suffixText.count)) + suffixText
                suffix += 1
            }
            taken.insert(result)
            resolved.append(result)
        }
        return resolved
    }

    // MARK: - Shapes

    private static func parseObject(_ jsonText: String) throws -> [String: Any] {
        let data = Data(jsonText.utf8)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch let error as NSError {
            guard let index = error.userInfo["NSJSONSerializationErrorIndex"] as? Int,
                  let message = error.userInfo[NSDebugDescriptionErrorKey] as? String else {
                throw error
            }
            let (line, column) = position(ofByteOffset: index, in: data)
            throw MCPServersJSONImportError.parseError(line: line, column: column, message: message)
        }
        guard let root = object as? [String: Any] else {
            throw MCPServersJSONImportError.invalidServer(name: nil, message: "The top level is not an object")
        }
        return root
    }

    private static func parseMap(_ map: [String: Any], environment: [String: String]) throws -> [MCPImportedServer] {
        try map.keys.sorted().map { name in
            guard let server = map[name] as? [String: Any] else {
                throw MCPServersJSONImportError.invalidServer(name: name, message: "The server is not an object")
            }
            return try parseServer(server, name: name, environment: environment)
        }
    }

    private static func parseServer(_ object: [String: Any], name: String?, environment: [String: String]) throws -> MCPImportedServer {
        var expander = VariableExpander(environment: environment)
        let fields = FieldReader(object: object, serverName: name)
        let type = object["type"] as? String

        let transport: MCPServerTransportConfig
        var envValues: [String: String] = [:]
        var headerValues: [String: String] = [:]
        let knownKeys: Set<String>
        switch type {
        case "http", "streamable-http", "sse":
            let url = expander.expand(try fields.requiredString("url"))
            let headers = try fields.optionalStringMap("headers") ?? [:]
            for (headerName, value) in headers.sorted(by: { $0.key < $1.key }) {
                headerValues[headerName] = expander.expand(value)
            }
            transport = .http(url: url, headerNames: headers.keys.sorted(), hint: type == "sse" ? .legacySSE : nil)
            knownKeys = httpKeys
        default:
            let command = expander.expand(try fields.requiredString("command"))
            let args = (try fields.optionalStringArray("args") ?? []).map { expander.expand($0) }
            let cwd = try fields.optionalString("cwd").map { expander.expand($0) }
            let env = try fields.optionalStringMap("env") ?? [:]
            for (envName, value) in env.sorted(by: { $0.key < $1.key }) {
                envValues[envName] = expander.expand(value)
            }
            transport = .stdio(command: command, args: args, envNames: env.keys.sorted(), cwd: cwd)
            knownKeys = stdioKeys
        }

        return MCPImportedServer(
            name: name,
            transport: transport,
            envValues: envValues,
            headerValues: headerValues,
            unresolvedVariables: expander.unresolved,
            ignoredKeys: object.keys.filter { !knownKeys.contains($0) }.sorted()
        )
    }

    /// 1-based line and column (in characters) of `offset` bytes into `data`.
    private static func position(ofByteOffset offset: Int, in data: Data) -> (line: Int, column: Int) {
        let prefix = String(decoding: data.prefix(offset), as: UTF8.self)
        let line = prefix.count { $0.isNewline } + 1
        let column = prefix.reversed().prefix { !$0.isNewline }.count + 1
        return (line, column)
    }

    // MARK: - Fields

    private struct FieldReader {
        let object: [String: Any]
        let serverName: String?

        func requiredString(_ key: String) throws -> String {
            guard let value = try optionalString(key) else {
                throw MCPServersJSONImportError.invalidServer(name: serverName, message: "\"\(key)\" is missing")
            }
            return value
        }

        func optionalString(_ key: String) throws -> String? {
            try optional(key, as: String.self, expected: "a string")
        }

        func optionalStringArray(_ key: String) throws -> [String]? {
            try optional(key, as: [String].self, expected: "an array of strings")
        }

        func optionalStringMap(_ key: String) throws -> [String: String]? {
            try optional(key, as: [String: String].self, expected: "an object of strings")
        }

        /// An absent key or JSON `null` is `nil`.
        private func optional<T>(_ key: String, as type: T.Type, expected: String) throws -> T? {
            guard let raw = object[key], !(raw is NSNull) else {
                return nil
            }
            guard let value = raw as? T else {
                throw MCPServersJSONImportError.invalidServer(name: serverName, message: "\"\(key)\" is not \(expected)")
            }
            return value
        }
    }

    // MARK: - ${VAR}

    /// Replaces each `${NAME}` found in the environment. A reference to a
    /// missing name stays as written and is recorded once.
    private struct VariableExpander {
        let environment: [String: String]
        private(set) var unresolved: [String] = []

        init(environment: [String: String]) {
            self.environment = environment
        }

        mutating func expand(_ text: String) -> String {
            var result = ""
            var rest = Substring(text)
            while let start = rest.range(of: "${") {
                result += rest[..<start.lowerBound]
                let afterOpen = rest[start.upperBound...]
                guard let close = afterOpen.firstIndex(of: "}"), Self.isVariableName(afterOpen[..<close]) else {
                    result += "${"
                    rest = afterOpen
                    continue
                }
                let name = String(afterOpen[..<close])
                if let value = environment[name] {
                    result += value
                } else {
                    result += "${\(name)}"
                    if !unresolved.contains(name) {
                        unresolved.append(name)
                    }
                }
                rest = afterOpen[afterOpen.index(after: close)...]
            }
            return result + rest
        }

        /// `[A-Za-z_][A-Za-z0-9_]*`.
        private static func isVariableName(_ text: Substring) -> Bool {
            guard let first = text.unicodeScalars.first, first.isASCII, first == "_" || first.properties.isAlphabetic else {
                return false
            }
            return text.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || $0.properties.isAlphabetic || ("0"..."9").contains($0)) }
        }
    }
}
