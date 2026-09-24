//
//  MCPServerEditDraft.swift
//  Calyx
//
//  What the add and edit sheets of Settings > MCP Servers produce. Env and
//  header values travel in the draft and are written to the secret store;
//  the server's `MCPServerConfig` keeps their names only.
//

import Foundation

/// The edit sheet's result. The alias is fixed at creation, so it is not
/// part of this draft.
struct MCPServerEditDraft: Sendable, Equatable {
    var displayName: String
    var transport: MCPServerTransportConfigDraft
    var authDraft: MCPServerAuthConfigDraftValue?
}

/// The add sheet's result, the only draft that carries an alias.
struct MCPServerCreateDraft: Sendable, Equatable {
    let alias: String
    var displayName: String
    var transport: MCPServerTransportConfigDraft
    var authDraft: MCPServerAuthConfigDraftValue?
}

enum MCPServerTransportConfigDraft: Sendable, Equatable {
    case stdio(command: String, args: [String], env: [String: String], cwd: String?)
    case http(url: String, headers: [String: String], hint: MCPServerHTTPHint?, useFixedPort: Bool)

    /// The config form: value maps become sorted name lists.
    var transportConfig: MCPServerTransportConfig {
        switch self {
        case .stdio(let command, let args, let env, let cwd):
            return .stdio(command: command, args: args, envNames: env.keys.sorted(), cwd: cwd)
        case .http(let url, let headers, let hint, _):
            return .http(url: url, headerNames: headers.keys.sorted(), hint: hint)
        }
    }

    /// Every env or header value, keyed for `serverID`.
    func secretValues(serverID: MCPServerID) -> [(key: MCPSecretKey, value: String)] {
        switch self {
        case .stdio(_, _, let env, _):
            return env.sorted { $0.key < $1.key }.map { (key: .env(serverID: serverID, name: $0.key), value: $0.value) }
        case .http(_, let headers, _, _):
            return headers.sorted { $0.key < $1.key }.map { (key: .header(serverID: serverID, name: $0.key), value: $0.value) }
        }
    }
}

struct MCPServerAuthConfigDraftValue: Sendable, Equatable {
    var preRegisteredClientID: String?
    /// nil is the `none` method. A secret-bearing case carries the client
    /// secret, which goes to the secret store.
    var clientAuthentication: MCPOAuthClientAuthentication?
}

enum MCPServerDraftConversion {

    /// The auth config of an HTTP server. stdio servers have none. An HTTP
    /// server without an auth draft and without the fixed port has none.
    /// The redirect host and the scope override are not in the draft and
    /// are kept from `existing`; a new config uses the `127.0.0.1` host.
    static func authConfig(
        transport: MCPServerTransportConfigDraft,
        authDraft: MCPServerAuthConfigDraftValue?,
        existing: MCPServerAuthConfig?
    ) -> MCPServerAuthConfig? {
        guard case .http(_, _, _, let useFixedPort) = transport else { return nil }
        guard authDraft != nil || useFixedPort else { return nil }
        return MCPServerAuthConfig(
            preRegisteredClientID: authDraft?.preRegisteredClientID,
            clientAuthenticationMethod: authDraft?.clientAuthentication.map(method(of:)),
            redirect: MCPOAuthRedirectConfig(
                host: existing?.redirect.host ?? .loopback,
                port: useFixedPort ? .calyxFixed : .random
            ),
            scopeOverride: existing?.scopeOverride
        )
    }

    /// The client secret the draft carries, if its method has one.
    static func clientSecret(of authDraft: MCPServerAuthConfigDraftValue?) -> String? {
        switch authDraft?.clientAuthentication {
        case .clientSecretPost(let secret)?, .clientSecretBasic(let secret)?:
            return secret
        case .none?, nil:
            return nil
        }
    }

    static func method(of authentication: MCPOAuthClientAuthentication) -> MCPOAuthClientAuthenticationMethod {
        switch authentication {
        case .none: return .none
        case .clientSecretPost: return .clientSecretPost
        case .clientSecretBasic: return .clientSecretBasic
        }
    }

    /// Env and header keys of `transport` for `serverID`.
    static func secretKeys(of transport: MCPServerTransportConfig, serverID: MCPServerID) -> [MCPSecretKey] {
        switch transport {
        case .stdio(_, _, let envNames, _):
            return envNames.map { .env(serverID: serverID, name: $0) }
        case .http(_, let headerNames, _):
            return headerNames.map { .header(serverID: serverID, name: $0) }
        }
    }
}

/// The add sheet's alias while creating a server: it follows the alias
/// derived from the name until the user edits the alias field, then keeps
/// what the user typed.
struct MCPServerAliasFieldState: Equatable {
    private(set) var alias = ""
    private(set) var followsName = true

    /// The name changed. While following, the alias becomes the one
    /// derived from `name`, or empty when nothing can be derived.
    mutating func nameDidChange(_ name: String) {
        guard followsName else { return }
        alias = MCPServerAliasDeriver.derive(fromDisplayName: name) ?? ""
    }

    /// The user typed into the alias field. A write of the value the
    /// field already holds is not an edit.
    mutating func userDidEdit(_ newAlias: String) {
        guard newAlias != alias else { return }
        alias = newAlias
        followsName = false
    }
}

/// The stdio Arguments field: one line of shell-style words.
enum MCPServerArgumentSplitter {

    enum SplitError: Error, Equatable {
        case unterminatedQuote(Character)
        case trailingBackslash
    }

    /// The scalars that separate arguments. `\r\n` is two of them.
    private static let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r"]
    /// The scalars `split` gives a meaning to.
    private static let special: Set<Unicode.Scalar> = whitespace.union(["'", "\"", "\\"])

    /// Splits `text` into arguments the way a POSIX shell splits words,
    /// without expansions: spaces, tabs and newlines separate arguments;
    /// single quotes keep everything up to the next single quote; double
    /// quotes keep everything up to the next unescaped double quote, where
    /// a backslash escapes only `"` and `\`; outside quotes a backslash
    /// keeps the next scalar, and a backslash before `\n` or `\r\n` joins
    /// the lines. `''` and `""` are empty arguments. The text is read one
    /// Unicode scalar at a time, so a quote, space or backslash followed by
    /// a combining mark, ZWJ, variation selector or emoji modifier keeps
    /// its meaning; the scalar after it is an ordinary one.
    static func split(_ text: String) throws(SplitError) -> [String] {
        var arguments: [String] = []
        var current = String.UnicodeScalarView()
        var inWord = false
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        /// The scalar at `index`, advancing past it; nil at the end.
        func next() -> Unicode.Scalar? {
            guard index < scalars.endIndex else { return nil }
            defer { index = scalars.index(after: index) }
            return scalars[index]
        }
        while let scalar = next() {
            switch scalar {
            case _ where whitespace.contains(scalar):
                if inWord {
                    arguments.append(String(current))
                    current = String.UnicodeScalarView()
                    inWord = false
                }
            case "'":
                inWord = true
                var closed = false
                while let quoted = next() {
                    if quoted == "'" {
                        closed = true
                        break
                    }
                    current.append(quoted)
                }
                guard closed else { throw SplitError.unterminatedQuote("'") }
            case "\"":
                inWord = true
                var closed = false
                while let quoted = next() {
                    if quoted == "\"" {
                        closed = true
                        break
                    }
                    if quoted == "\\" {
                        guard let escaped = next() else { throw SplitError.unterminatedQuote("\"") }
                        if escaped != "\"" && escaped != "\\" {
                            current.append("\\")
                        }
                        current.append(escaped)
                    } else {
                        current.append(quoted)
                    }
                }
                guard closed else { throw SplitError.unterminatedQuote("\"") }
            case "\\":
                guard let escaped = next() else { throw SplitError.trailingBackslash }
                if escaped == "\n" {
                    continue
                }
                if escaped == "\r", index < scalars.endIndex, scalars[index] == "\n" {
                    index = scalars.index(after: index)
                    continue
                }
                inWord = true
                current.append(escaped)
            default:
                inWord = true
                current.append(scalar)
            }
        }
        if inWord {
            arguments.append(String(current))
        }
        return arguments
    }

    /// The Arguments field text for `arguments`, which `split` turns back
    /// into the same arguments. An argument with no scalar that has a
    /// meaning to `split` is written as is; any other is single-quoted,
    /// with each single quote scalar written as `'\''`.
    static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }

    private static func quote(_ argument: String) -> String {
        guard argument.isEmpty || argument.unicodeScalars.contains(where: special.contains) else {
            return argument
        }
        var quoted = String.UnicodeScalarView()
        quoted.append("'")
        for scalar in argument.unicodeScalars {
            if scalar == "'" {
                quoted.append(contentsOf: "'\\''".unicodeScalars)
            } else {
                quoted.append(scalar)
            }
        }
        quoted.append("'")
        return String(quoted)
    }
}
