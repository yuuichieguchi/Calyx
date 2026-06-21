//
//  LSPSessionPersistence.swift
//  Calyx
//
//  Persists per-(workspaceRoot, languageId) LSP session snapshots to a JSON
//  file under `~/Library/Application Support/Calyx/lsp/sessions.json` so the
//  LSP layer can reconstruct open files and initialization options across
//  application launches.
//
//  Identity of a stored entry is the pair (workspaceRoot, languageId): the
//  same pair persisted twice overwrites; distinct pairs coexist independently.
//
//  `load()` is best-effort and never throws: a missing file or corrupted JSON
//  is treated as "no sessions" (the application then falls back to a
//  fresh-install code path). Mutating operations propagate I/O errors.
//
//  Mutating operations (`persist`, `remove`) do NOT share that best-effort
//  read path: when the on-disk file exists but is undecodable, they rotate
//  the unreadable file to `<storageURL>.bak` and start a fresh entry list,
//  rather than silently overwriting every surviving entry with the single
//  caller-supplied snapshot. This protects against the data-loss scenario
//  where a transient corruption / schema-skew on read would otherwise erase
//  N-1 healthy entries on the next persist.
//
//  All state lives in an `actor` so concurrent `persist` / `remove` / `clear`
//  / `load` from multiple LSP sessions cannot interleave file reads and
//  writes. The on-disk write itself is atomic (`Data.write(options: .atomic)`)
//  to avoid producing a partially-written JSON document if the process is
//  terminated mid-flush.
//

import Foundation

actor LSPSessionPersistence {

    // MARK: - SessionSnapshot

    /// A single persisted LSP session. Nested under `LSPSessionPersistence`
    /// to avoid colliding with the top-level `SessionSnapshot` used for
    /// window/tab persistence under `Calyx/Features/Persistence/`.
    struct SessionSnapshot: Sendable, Codable, Equatable {
        /// Absolute workspace root URL. Part of the entry's identity.
        let workspaceRoot: URL
        /// LSP language id (e.g. `"swift"`, `"typescript"`). Part of the
        /// entry's identity.
        let languageId: String
        /// Document URIs that were open in this session at snapshot time.
        let openFiles: [DocumentUri]
        /// Server-specific blob passed at `initialize` time. `nil` if the
        /// session does not use any initialization options.
        let initializationOptions: AnyCodable?
        /// Monotonic clock value (in milliseconds) at the moment the snapshot
        /// was captured. Used by callers for staleness checks; not part of
        /// the identity.
        let savedAtUptimeMillis: Int64
    }

    // MARK: - Storage location

    /// Absolute path to the JSON file backing this store. Exposed as
    /// `nonisolated` because the location is fixed at init time and is
    /// referenced by callers (and by tests) without crossing the actor.
    nonisolated let storageURL: URL

    // MARK: - Init

    /// - Parameter storageURL: explicit storage URL. When `nil`, defaults to
    ///   `~/Library/Application Support/Calyx/lsp/sessions.json` (resolved
    ///   via `FileManager.applicationSupportDirectory`).
    init(storageURL: URL? = nil) {
        if let storageURL {
            self.storageURL = storageURL
        } else {
            self.storageURL = Self.defaultStorageURL()
        }
    }

    private static func defaultStorageURL() -> URL {
        let fm = FileManager.default
        let appSupport = fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Calyx", isDirectory: true)
            .appendingPathComponent("lsp", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }

    // MARK: - Public API

    /// Persist (or overwrite) the entry for
    /// `(snapshot.workspaceRoot, snapshot.languageId)`. Creates any missing
    /// parent directories. Propagates encoding / I/O errors.
    ///
    /// If the on-disk file exists but cannot be decoded (corruption / schema
    /// skew), the unreadable file is rotated to `<storageURL>.bak` and the
    /// new entry list starts empty rather than overwriting the original file
    /// in place: this preserves the user's data for forensic recovery and
    /// avoids the silent N-1-entry data-loss bug where the best-effort
    /// read-as-empty fallback would otherwise erase every surviving entry
    /// on the very next write.
    func persist(_ snapshot: SessionSnapshot) throws {
        var entries = try readForMutation()
        entries.removeAll {
            $0.workspaceRoot == snapshot.workspaceRoot
                && $0.languageId == snapshot.languageId
        }
        entries.append(snapshot)
        try writeToDisk(entries)
    }

    /// Remove the entry identified by `(workspaceRoot, languageId)`. A
    /// no-op (no throw, no file write) when no such entry exists, so that
    /// the on-disk file is not touched unnecessarily.
    ///
    /// Shares the same corruption-handling semantics as `persist(_:)`: if
    /// the on-disk file exists but cannot be decoded, the unreadable file
    /// is rotated to `<storageURL>.bak` and the working entry list starts
    /// empty (which, combined with the unchanged-count guard, leaves no
    /// new file on disk).
    func remove(workspaceRoot: URL, languageId: String) throws {
        var entries = try readForMutation()
        let before = entries.count
        entries.removeAll {
            $0.workspaceRoot == workspaceRoot && $0.languageId == languageId
        }
        guard entries.count != before else { return }
        try writeToDisk(entries)
    }

    /// Read all persisted snapshots. Returns `[]` for any of:
    ///   - storage file does not exist (fresh install / not yet written),
    ///   - storage file is unreadable,
    ///   - storage file contains malformed / unexpected JSON.
    ///
    /// Never throws: corruption is treated as "no sessions" so the caller
    /// can recover by replaying a fresh-install code path.
    func load() -> [SessionSnapshot] {
        return readFromDisk()
    }

    /// Erase all persisted sessions. Writes an empty JSON array rather than
    /// deleting the file, so a subsequent `persist` does not need to recreate
    /// the parent directory.
    func clear() throws {
        try writeToDisk([])
    }

    // MARK: - Internals

    /// Best-effort read used by `load()`. Returns `[]` for any failure
    /// (missing file, unreadable bytes, malformed JSON). NEVER throws.
    /// MUST NOT be used as the source-of-truth for mutating operations —
    /// callers that are about to overwrite the file must use
    /// `readForMutation()` instead, which distinguishes "no file" from
    /// "file exists but undecodable" to avoid clobbering live data.
    private func readFromDisk() -> [SessionSnapshot] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }
        do {
            return try JSONDecoder().decode([SessionSnapshot].self, from: data)
        } catch {
            // Malformed JSON / partial write / version skew: fall back to a
            // fresh-install state. The contract of `load()` is best-effort.
            return []
        }
    }

    /// Read for the read-modify-write path. Semantics:
    ///   - File does not exist → return `[]` (first-ever write).
    ///   - File exists and decodes → return the decoded entries.
    ///   - File exists but is unreadable / undecodable → rotate the bad
    ///     file to `<storageURL>.bak` (overwriting any previous `.bak`)
    ///     and return `[]`. The rotation is best-effort: a rotation
    ///     failure does NOT throw, because surfacing it would leave the
    ///     caller with an unrecoverable persist (the bad file would block
    ///     every subsequent write). The recovered data lives in `.bak`
    ///     for the user to inspect; the next successful `writeToDisk`
    ///     restores `storageURL` to a healthy state.
    ///
    /// Unlike `readFromDisk()`, this method does NOT silently treat a
    /// corrupted file as "empty entries we should keep as the canonical
    /// state": doing so would let the next mutating call overwrite every
    /// surviving entry with the single caller-supplied snapshot.
    private func readForMutation() throws -> [SessionSnapshot] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: storageURL)
            return try JSONDecoder().decode([SessionSnapshot].self, from: data)
        } catch {
            // Rotate the unreadable file aside so we don't lose the bytes,
            // then start a fresh entry list. Rotation failures are
            // intentionally swallowed: if they propagated, the persist
            // path would be permanently wedged on a broken file.
            let bak = storageURL.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.moveItem(at: storageURL, to: bak)
            return []
        }
    }

    private func writeToDisk(_ entries: [SessionSnapshot]) throws {
        let parent = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: storageURL, options: .atomic)
    }
}
