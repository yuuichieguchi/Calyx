// UsageIngestCredential.swift
// Calyx
//
// The usage route's own bearer token, kept in `usage-otel-credential.json`
// so `calyx-usage-headers` (Claude Code's `otelHeadersHelper`) can print
// it as headers.
//
// Why the file was renamed from `usage-otel-headers.json` (G5, C-D19):
// Claude Code sessions started under an older build keep running the
// legacy helper, a plain `cat` of `usage-otel-headers.json`, which prints
// whatever that file holds to whatever process now serves the session's
// port. Those sessions must never read a renewed token, so the credential
// lives under a name only `calyx-usage-headers` knows, and `loadOrCreate`
// removes the legacy file: legacy helpers then print `{}` (fail closed).

import Foundation

/// The token Claude Code presents on the usage route, and the file its `otelHeadersHelper` command prints.
struct UsageIngestCredential: Sendable, Equatable {
    let token: String              // 64 lowercase hex characters
    let headersFilePath: String
}

/// Thrown by `UsageIngestCredentialStore.loadOrCreate`. Carries no part
/// of any token, so it can never leak one.
enum UsageIngestCredentialError: Error, Sendable, Equatable {
    /// `makeToken` returned something that is not 64 lowercase hex characters.
    case malformedGeneratedToken
    /// The locked read-or-write finished without deciding a token; the
    /// locked section always decides one, so this marks a broken invariant
    /// rather than a state of the file.
    case missingCredentialAfterWrite
}

enum UsageIngestCredentialStore {

    static let fileName = "usage-otel-credential.json"

    /// The name older builds used, still `cat`ed by legacy helpers of
    /// sessions started under those builds; `loadOrCreate` removes it.
    static let legacyFileName = "usage-otel-headers.json"

    private static let tokenLength = 64

    /// `<directory>/usage-otel-credential.json`; the default directory is `AppSupportDirectory.path`.
    static func headersFilePath(directory: String = AppSupportDirectory.path) -> String {
        (directory as NSString).appendingPathComponent(fileName)
    }

    /// The credential in the file, or nil when the file is missing or not exactly a credential file. Creates nothing.
    /// Reads through a symbolic link at the file's place.
    static func read(directory: String = AppSupportDirectory.path) -> UsageIngestCredential? {
        let path = headersFilePath(directory: directory)
        guard let data = FileManager.default.contents(atPath: path),
              let token = token(inHeadersFile: data)
        else { return nil }
        return UsageIngestCredential(token: token, headersFilePath: path)
    }

    /// The credential in the file; when it is missing or unusable, a new token is generated and the file written.
    /// Always leaves the file at mode 0600. Creates `directory` when needed.
    ///
    /// Reading, deciding and writing happen under one exclusive lock
    /// (`ConfigFileUtils.withExclusiveConfig`, which also resolves a
    /// symbolic link at the file's place once, so read, mode and write
    /// apply to the resolved file and the link stays a link). Callers
    /// that start at once therefore end with the same token: a later one
    /// finds the earlier one's file under the lock. A usable file is never
    /// rewritten, only its mode corrected: running Claude Code processes
    /// refresh their headers rarely, so the token must stay the same for as
    /// long as the file is intact. An unusable file is replaced whole.
    ///
    /// The lock is keyed by the resolved path, which can be spelled
    /// differently before and after `directory` exists. So when
    /// `directory` is missing, the token is made and checked first, the
    /// directory created, and only then the lock taken and the file looked
    /// at again; a usable file found there wins and the made token is
    /// dropped. Otherwise `makeToken` runs only for an unusable file. A
    /// failing or malformed `makeToken` leaves `directory` as it was.
    ///
    /// `replaceExisting: true` renews the token: a fresh checked token is
    /// written whatever the file holds (G5, C-D19: the usage token is
    /// renewed with the IPC token when the previous port was lost). A
    /// failing or malformed `makeToken` throws and leaves the file as it was.
    ///
    /// The legacy `usage-otel-headers.json` in `directory` is removed
    /// first (best-effort, only when it is a regular file; errors are
    /// ignored), so legacy `cat` helpers print `{}` from then on.
    static func loadOrCreate(
        directory: String = AppSupportDirectory.path,
        makeToken: () throws -> String,
        replaceExisting: Bool = false
    ) throws -> UsageIngestCredential {
        let fm = FileManager.default
        var preparedToken: String?
        if !fm.fileExists(atPath: directory) {
            preparedToken = try makeCheckedToken(makeToken)
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }

        removeLegacyFile(directory: directory)
        let path = headersFilePath(directory: directory)
        var resultToken: String?
        try ConfigFileUtils.withExclusiveConfig(path: path, mode: 0o600, restoreModeOnNoWrite: true) { current in
            if !replaceExisting, let current, let existing = token(inHeadersFile: current) {
                resultToken = existing
                return current
            }
            let token = try preparedToken ?? makeCheckedToken(makeToken)
            resultToken = token
            return contents(for: token)
        }
        guard let token = resultToken else {
            throw UsageIngestCredentialError.missingCredentialAfterWrite
        }
        return UsageIngestCredential(token: token, headersFilePath: path)
    }

    /// Removes `<directory>/usage-otel-headers.json` when it is a regular
    /// file (a directory or a symbolic link is left alone). Best-effort by
    /// design (G5 disposition 24): a failed removal must not stop the
    /// credential from being written, so its error is ignored.
    private static func removeLegacyFile(directory: String) {
        let fm = FileManager.default
        let legacyPath = (directory as NSString).appendingPathComponent(legacyFileName)
        guard let attributes = try? fm.attributesOfItem(atPath: legacyPath),
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return }
        try? fm.removeItem(atPath: legacyPath)
    }

    /// `makeToken`'s token, or `malformedGeneratedToken` when it is not 64
    /// lowercase hex characters.
    private static func makeCheckedToken(_ makeToken: () throws -> String) throws -> String {
        let token = try makeToken()
        guard isWellFormedToken(token) else {
            throw UsageIngestCredentialError.malformedGeneratedToken
        }
        return token
    }

    // MARK: - Contents

    private static let contentsPrefix = Data("{\"Authorization\":\"Bearer ".utf8)
    private static let contentsSuffix = Data("\"}".utf8)

    /// Exactly the bytes Calyx writes: `{"Authorization":"Bearer <token>"}`.
    private static func contents(for token: String) -> Data {
        contentsPrefix + Data(token.utf8) + contentsSuffix
    }

    /// The token of a credential file, whose bytes must be exactly
    /// `contents(for:)` of a well-formed token. Calyx is the only writer
    /// of this file, so a byte comparison is enough, and it refuses a
    /// repeated member that JSON parsers could each read differently.
    private static func token(inHeadersFile data: Data) -> String? {
        guard data.count == contentsPrefix.count + tokenLength + contentsSuffix.count,
              data.starts(with: contentsPrefix),
              data.suffix(contentsSuffix.count).elementsEqual(contentsSuffix)
        else { return nil }
        let tokenBytes = data.dropFirst(contentsPrefix.count).prefix(tokenLength)
        guard let token = String(data: tokenBytes, encoding: .utf8), isWellFormedToken(token) else { return nil }
        return token
    }

    /// Exactly 64 characters, each `0`-`9` or `a`-`f`.
    private static func isWellFormedToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard bytes.count == tokenLength else { return false }
        return bytes.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
