//
//  MCPHTTPBearerChallenge.swift
//  Calyx
//
//  `WWW-Authenticate` parsing for the `Bearer` scheme (RFC 6750 section 3,
//  challenge grammar of RFC 9110 section 11). The single parser shared by
//  the HTTP transports and the OAuth flow.
//

import Foundation

struct MCPHTTPBearerChallenge: Sendable, Equatable {
    /// Always "Bearer"; the scheme is matched case-insensitively.
    let scheme: String
    let resourceMetadata: String?
    /// Space-separated scope values, as received.
    let scope: String?
    let error: String?
    let errorDescription: String?

    /// Returns the `Bearer` challenges in `headerValue`, in order. Other
    /// schemes are skipped. Parameter names are matched case-insensitively
    /// and their order is ignored; the first occurrence of a name wins.
    static func parse(_ headerValue: String) -> [MCPHTTPBearerChallenge] {
        var scanner = ChallengeScanner(headerValue)
        var challenges: [MCPHTTPBearerChallenge] = []
        while let (scheme, parameters) = scanner.nextChallenge() {
            guard scheme.lowercased() == "bearer" else { continue }
            challenges.append(MCPHTTPBearerChallenge(
                scheme: "Bearer",
                resourceMetadata: parameters["resource_metadata"],
                scope: parameters["scope"],
                error: parameters["error"],
                errorDescription: parameters["error_description"]
            ))
        }
        return challenges
    }
}

/// Tokenizer for a `WWW-Authenticate` field value:
///   challenge  = auth-scheme [ 1*SP ( token68 / #auth-param ) ]
///   auth-param = token BWS "=" BWS ( token / quoted-string )
/// Challenges and parameters share the comma separator, so a comma
/// followed by `token "="` continues the current challenge and a comma
/// followed by any other token starts the next one.
private struct ChallengeScanner {

    private let characters: [Character]
    private var index = 0

    init(_ value: String) {
        self.characters = Array(value)
    }

    /// The next challenge's scheme and lowercased parameter names, or nil
    /// at the end of the value or at a character no challenge can start with.
    mutating func nextChallenge() -> (scheme: String, parameters: [String: String])? {
        skipWhitespaceAndCommas()
        let scheme = readToken()
        guard !scheme.isEmpty else { return nil }
        skipWhitespace()
        if skipToken68() { return (scheme, [:]) }

        var parameters: [String: String] = [:]
        while let (name, value) = readParameter() {
            let key = name.lowercased()
            if parameters[key] == nil { parameters[key] = value }
            skipWhitespace()
            guard peek() == "," else { break }
            let separator = index
            skipWhitespaceAndCommas()
            guard isAtParameter() else {
                index = separator
                break
            }
        }
        return (scheme, parameters)
    }

    // MARK: - Grammar

    /// Consumes a token68 that forms the whole challenge body. Leaves the
    /// position unchanged when the body is not a token68.
    private mutating func skipToken68() -> Bool {
        let start = index
        while let character = peek(), Self.isToken68Character(character) { index += 1 }
        guard index > start else { return false }
        while peek() == "=" { index += 1 }
        skipWhitespace()
        if peek() == nil || peek() == "," { return true }
        index = start
        return false
    }

    /// True when the position is at `token BWS "="`.
    private mutating func isAtParameter() -> Bool {
        let start = index
        defer { index = start }
        guard !readToken().isEmpty else { return false }
        skipWhitespace()
        return peek() == "="
    }

    private mutating func readParameter() -> (String, String)? {
        let start = index
        let name = readToken()
        skipWhitespace()
        guard !name.isEmpty, peek() == "=" else {
            index = start
            return nil
        }
        index += 1
        skipWhitespace()
        if peek() == "\"" {
            return (name, readQuotedString())
        }
        return (name, readToken())
    }

    private mutating func readToken() -> String {
        var token = ""
        while let character = peek(), Self.isTokenCharacter(character) {
            token.append(character)
            index += 1
        }
        return token
    }

    /// Reads a quoted-string starting at the opening quote, unescaping
    /// quoted-pairs.
    private mutating func readQuotedString() -> String {
        var value = ""
        index += 1
        while let character = peek(), character != "\"" {
            if character == "\\", index + 1 < characters.count {
                index += 1
            }
            value.append(characters[index])
            index += 1
        }
        if peek() == "\"" { index += 1 }
        return value
    }

    private mutating func skipWhitespace() {
        while let character = peek(), character == " " || character == "\t" { index += 1 }
    }

    private mutating func skipWhitespaceAndCommas() {
        while let character = peek(), character == " " || character == "\t" || character == "," { index += 1 }
    }

    private func peek() -> Character? {
        index < characters.count ? characters[index] : nil
    }

    // MARK: - Character Classes

    /// RFC 9110 `tchar`.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII, let scalar = character.unicodeScalars.first else { return false }
        if character.isLetter || character.isNumber { return true }
        return "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
    }

    /// RFC 9110 `token68` characters other than the trailing "=".
    private static func isToken68Character(_ character: Character) -> Bool {
        guard character.isASCII, let scalar = character.unicodeScalars.first else { return false }
        if character.isLetter || character.isNumber { return true }
        return "-._~+/".unicodeScalars.contains(scalar)
    }
}
