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
    func persist(_ snapshot: SessionSnapshot) throws {
        var entries = readFromDisk()
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
    func remove(workspaceRoot: URL, languageId: String) throws {
        var entries = readFromDisk()
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
