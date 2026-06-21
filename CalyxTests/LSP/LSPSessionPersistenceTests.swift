//
//  LSPSessionPersistenceTests.swift
//  Calyx
//
//  Tests for `LSPSessionPersistence` — the actor that persists per-(workspace,
//  language) LSP session snapshots (open files, initialization options) to a
//  JSON file under `~/Library/Application Support/Calyx/lsp/sessions.json`.
//
//  Behaviour under test:
//    - `load()` returns an empty array when the storage file does not exist.
//    - `persist(_:)` writes a snapshot and round-trips through `load()`.
//    - Persisting a second snapshot with the same (workspaceRoot, languageId)
//      overwrites the previous entry (uniqueness key: workspace + language).
//    - Multiple distinct (workspace, language) pairs are stored independently
//      and all visible via `load()`.
//    - `remove(workspaceRoot:languageId:)` deletes a specific entry while
//      preserving all others; removing a non-existent entry is a no-op.
//    - `clear()` empties the storage so `load()` returns `[]`.
//    - The default storage URL resolves under
//      `~/Library/Application Support/Calyx/lsp/sessions.json`.
//    - Corrupted JSON in the storage file does NOT throw — `load()` returns
//      `[]` (and the implementation is expected to log a warning).
//    - `persist(_:)` creates any missing parent directories on first write.
//
//  TDD phase: RED. None of the types under test exist yet. This file is
//  expected to fail to compile until the swift-specialist creates
//  `Calyx/Features/LSP/LSPSessionPersistence.swift` defining:
//    - `actor LSPSessionPersistence`
//    - `LSPSessionPersistence.SessionSnapshot` (nested to avoid colliding
//      with the existing top-level `SessionSnapshot` used for window/tab
//      persistence under `Calyx/Features/Persistence/SessionSnapshot.swift`).
//

import XCTest
@testable import Calyx

@MainActor
final class LSPSessionPersistenceTests: XCTestCase {

    // ====================================================================
    // MARK: - Helpers
    // ====================================================================

    /// Generate a fresh, isolated temp directory URL per test, and schedule
    /// its removal so file-system side effects never leak between tests.
    private func makeTempDir(line: UInt = #line) throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("LSPSessionPersistenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: raw, withIntermediateDirectories: true
        )
        let url = raw.resolvingSymlinksInPath()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Build a default storage URL inside a fresh temp directory. The file
    /// itself is NOT created — its parent directory is.
    private func makeStorageURL() throws -> URL {
        let dir = try makeTempDir()
        return dir.appendingPathComponent("sessions.json")
    }

    /// Build a nested storage URL whose intermediate directories do NOT
    /// exist yet. Used to verify `persist` creates missing parents.
    private func makeNestedStorageURL() throws -> URL {
        let dir = try makeTempDir()
        return dir
            .appendingPathComponent("missing-a")
            .appendingPathComponent("missing-b")
            .appendingPathComponent("sessions.json")
    }

    /// Construct a snapshot with sensible defaults so each test can focus on
    /// the field(s) under examination.
    private func snap(
        workspace: URL,
        languageId: String,
        openFiles: [DocumentUri] = [],
        initializationOptions: AnyCodable? = nil,
        savedAt: Int64 = 1_000
    ) -> LSPSessionPersistence.SessionSnapshot {
        return LSPSessionPersistence.SessionSnapshot(
            workspaceRoot: workspace,
            languageId: languageId,
            openFiles: openFiles,
            initializationOptions: initializationOptions,
            savedAtUptimeMillis: savedAt
        )
    }

    /// Workspace URL helper — uses a stable on-disk-looking path string so
    /// Codable round-trips are deterministic.
    private func workspaceURL(_ name: String) -> URL {
        return URL(fileURLWithPath: "/tmp/ws-\(name)", isDirectory: true)
    }

    // ====================================================================
    // MARK: - 1. load() on empty file returns empty array
    // ====================================================================

    /// Contract: when the storage file does not exist on disk, `load()` must
    /// return `[]` (not throw, not crash). This is the "fresh install" path.
    func test_load_emptyFile_returnsEmptyArray() async throws {
        let storage = try makeStorageURL()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storage.path),
            "precondition: storage file must not exist before load()"
        )

        let persistence = LSPSessionPersistence(storageURL: storage)
        let snapshots = await persistence.load()

        XCTAssertEqual(snapshots, [], "load() on non-existent file must return []")
    }

    // ====================================================================
    // MARK: - 2. persist → load round-trip
    // ====================================================================

    /// Contract: a snapshot persisted via `persist(_:)` must be returned
    /// exactly (Equatable) by a subsequent `load()`.
    func test_persist_thenLoad_returnsSnapshot() async throws {
        let storage = try makeStorageURL()
        let persistence = LSPSessionPersistence(storageURL: storage)

        let ws = workspaceURL("alpha")
        let snapshot = snap(
            workspace: ws,
            languageId: "typescript",
            openFiles: ["file:///tmp/ws-alpha/a.ts", "file:///tmp/ws-alpha/b.ts"],
            initializationOptions: AnyCodable(["preferences": AnyCodable(["importModuleSpecifier": AnyCodable("relative")])]),
            savedAt: 12_345
        )

        try await persistence.persist(snapshot)
        let loaded = await persistence.load()

        XCTAssertEqual(loaded.count, 1, "exactly one snapshot must be persisted")
        XCTAssertEqual(loaded.first, snapshot, "persisted snapshot must round-trip via load()")
    }

    // ====================================================================
    // MARK: - 3. persist twice with same key overwrites
    // ====================================================================

    /// Contract: identity of a persistence entry is the pair
    /// (workspaceRoot, languageId). Persisting a second snapshot with the
    /// same pair must replace the first, not append.
    func test_persist_overwritesExistingEntry() async throws {
        let storage = try makeStorageURL()
        let persistence = LSPSessionPersistence(storageURL: storage)

        let ws = workspaceURL("alpha")
        let first = snap(
            workspace: ws,
            languageId: "swift",
            openFiles: ["file:///tmp/ws-alpha/Old.swift"],
            savedAt: 1_000
        )
        let second = snap(
            workspace: ws,
            languageId: "swift",
            openFiles: ["file:///tmp/ws-alpha/New.swift", "file:///tmp/ws-alpha/Extra.swift"],
            savedAt: 9_999
        )

        try await persistence.persist(first)
        try await persistence.persist(second)

        let loaded = await persistence.load()
        XCTAssertEqual(loaded.count, 1, "same (workspace, language) must yield exactly 1 entry")
        XCTAssertEqual(loaded.first, second, "later persist() must overwrite the earlier one")
    }

    // ====================================================================
    // MARK: - 4. independent entries: distinct (workspace, language) pairs
    // ====================================================================

    /// Contract: different workspaces, and different languages within the
    /// same workspace, are independent. All visible via `load()`.
    func test_persist_multipleEntries_independentSessions() async throws {
        let storage = try makeStorageURL()
        let persistence = LSPSessionPersistence(storageURL: storage)

        let wsA = workspaceURL("a")
        let wsB = workspaceURL("b")

        let aSwift = snap(workspace: wsA, languageId: "swift", openFiles: ["file:///tmp/ws-a/X.swift"], savedAt: 100)
        let aTs    = snap(workspace: wsA, languageId: "typescript", openFiles: ["file:///tmp/ws-a/x.ts"], savedAt: 200)
        let bRust  = snap(workspace: wsB, languageId: "rust", openFiles: ["file:///tmp/ws-b/main.rs"], savedAt: 300)

        try await persistence.persist(aSwift)
        try await persistence.persist(aTs)
        try await persistence.persist(bRust)

        let loaded = await persistence.load()
        XCTAssertEqual(loaded.count, 3, "three distinct (workspace, language) pairs must all be persisted")

        // Order-independent containment checks. Equatable conformance lets us
        // reduce to a Set-like membership check via array contains.
        XCTAssertTrue(loaded.contains(aSwift), "wsA/swift snapshot must be present")
        XCTAssertTrue(loaded.contains(aTs),    "wsA/typescript snapshot must be present")
        XCTAssertTrue(loaded.contains(bRust),  "wsB/rust snapshot must be present")
    }

    // ====================================================================
    // MARK: - 5. remove a specific entry, keep the others
    // ====================================================================

    /// Contract: `remove(workspaceRoot:languageId:)` deletes exactly the
    /// matching entry. All other entries (including those that share the
    /// workspace or share the language but not both) must remain.
    func test_remove_specificEntry_keepsOthers() async throws {
        let storage = try makeStorageURL()
        let persistence = LSPSessionPersistence(storageURL: storage)

        let wsA = workspaceURL("a")
        let wsB = workspaceURL("b")

        let aSwift = snap(workspace: wsA, languageId: "swift",      savedAt: 1)
        let aTs    = snap(workspace: wsA, languageId: "typescript", savedAt: 2)
        let bSwift = snap(workspace: wsB, languageId: "swift",      savedAt: 3)

        try await persistence.persist(aSwift)
        try await persistence.persist(aTs)
        try await persistence.persist(bSwift)

        // Remove only (wsA, swift). (wsA, typescript) and (wsB, swift) must survive.
        try await persistence.remove(workspaceRoot: wsA, languageId: "swift")

        let loaded = await persistence.load()
        XCTAssertEqual(loaded.count, 2, "remove() must delete exactly 1 entry")
        XCTAssertFalse(loaded.contains(aSwift), "removed entry must be gone")
        XCTAssertTrue(loaded.contains(aTs),     "same-workspace different-language entry must remain")
        XCTAssertTrue(loaded.contains(bSwift),  "different-workspace same-language entry must remain")
    }

    // ====================================================================
    // MARK: - 6. remove on missing entry is a no-op
    // ====================================================================

    /// Contract: `remove(workspaceRoot:languageId:)` for an entry that was
    /// never persisted must not throw and must not affect other entries.
    /// Also covers the "remove on empty/non-existent storage" case via the
    /// same code path.
    func test_remove_nonexistent_isNoOp() async throws {
        let storage = try makeStorageURL()
        let persistence = LSPSessionPersistence(storageURL: storage)

        let wsA = workspaceURL("a")
        let aSwift = snap(workspace: wsA, languageId: "swift", savedAt: 1)
        try await persistence.persist(aSwift)

        // Case 1: remove a (workspace, language) that does not exist while
        // OTHER entries are present. Must not throw, must not touch others.
        try await persistence.remove(workspaceRoot: wsA, languageId: "python")

        let afterMissingRemove = await persistence.load()
        XCTAssertEqual(afterMissingRemove, [aSwift],
                       "removing a non-existent entry must not affect the survivors")

        // Case 2: remove on a workspace that has no entries at all.
        try await persistence.remove(workspaceRoot: workspaceURL("never-persisted"), languageId: "swift")

        let afterAnotherMissingRemove = await persistence.load()
        XCTAssertEqual(afterAnotherMissingRemove, [aSwift],
                       "removing a never-seen workspace must not affect the survivors")
    }

    // ====================================================================
    // MARK: - 7. clear() empties storage
    // ====================================================================

    /// Contract: after `clear()`, `load()` returns `[]`. The on-disk file
    /// may be deleted or rewritten as an empty array — either is acceptable;
    /// only the post-condition is asserted.
    func test_clear_emptiesStorage() async throws {
        let storage = try makeStorageURL()
        let persistence = LSPSessionPersistence(storageURL: storage)

        let wsA = workspaceURL("a")
        let wsB = workspaceURL("b")
        try await persistence.persist(snap(workspace: wsA, languageId: "swift"))
        try await persistence.persist(snap(workspace: wsB, languageId: "rust"))

        // Sanity: both present before clear.
        let beforeClear = await persistence.load()
        XCTAssertEqual(beforeClear.count, 2, "precondition: both entries persisted before clear()")

        try await persistence.clear()

        let afterClear = await persistence.load()
        XCTAssertEqual(afterClear, [], "clear() must leave load() returning []")
    }

    // ====================================================================
    // MARK: - 8. default storageURL lives under Application Support/Calyx/lsp
    // ====================================================================

    /// Contract: when constructed with no argument, the actor's `storageURL`
    /// resolves under `Library/Application Support/Calyx/lsp/sessions.json`.
    /// `storageURL` is documented as `nonisolated`, so it is accessible
    /// synchronously without `await`.
    ///
    /// NOTE: this test does NOT call any method that performs disk I/O on the
    /// default path, so the user's real Application Support directory is
    /// never touched.
    func test_storageURL_defaultsToApplicationSupport() {
        let persistence = LSPSessionPersistence()
        let path = persistence.storageURL.path

        XCTAssertTrue(
            path.contains("Library/Application Support/Calyx/lsp/sessions.json"),
            "default storage URL must live under Library/Application Support/Calyx/lsp/sessions.json (got: \(path))"
        )
    }

    // ====================================================================
    // MARK: - 9. corrupted JSON returns [] (does not throw)
    // ====================================================================

    /// Contract: `load()` is best-effort. If the on-disk JSON is malformed
    /// (corruption, partial write, version skew), the actor must NOT throw
    /// from `load()`. It must return `[]` so the application can continue
    /// with a fresh-install code path (and is expected to log a warning,
    /// though logs are out of scope for this unit test).
    func test_load_corruptedJSON_returnsEmptyArray() async throws {
        let storage = try makeStorageURL()
        // Write invalid JSON directly to the storage URL. The parent dir was
        // already created by makeStorageURL → makeTempDir.
        try Data("this is not json {{{".utf8).write(to: storage, options: .atomic)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storage.path),
            "precondition: corrupted file must exist on disk"
        )

        let persistence = LSPSessionPersistence(storageURL: storage)
        let loaded = await persistence.load()

        XCTAssertEqual(loaded, [], "corrupted JSON must result in load() returning [] (no throw)")
    }

    // ====================================================================
    // MARK: - 10. persist creates missing parent directories
    // ====================================================================

    /// Contract: when the configured `storageURL` is nested under directories
    /// that do not yet exist (e.g., first-ever launch where `lsp/` has not
    /// been created), `persist(_:)` must create the missing intermediate
    /// directories rather than failing.
    func test_persist_createsParentDirectoryIfMissing() async throws {
        let storage = try makeNestedStorageURL()
        let parent = storage.deletingLastPathComponent()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: parent.path),
            "precondition: nested parent directory must NOT exist before persist()"
        )

        let persistence = LSPSessionPersistence(storageURL: storage)
        let wsA = workspaceURL("a")
        let snapshot = snap(workspace: wsA, languageId: "swift", openFiles: ["file:///tmp/ws-a/X.swift"], savedAt: 42)

        // Must not throw despite the missing intermediate directories.
        try await persistence.persist(snapshot)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: parent.path),
            "persist() must create missing parent directories"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storage.path),
            "persist() must write the storage file at the configured URL"
        )

        let loaded = await persistence.load()
        XCTAssertEqual(loaded, [snapshot], "snapshot persisted via newly-created directory must round-trip")
    }

    // ====================================================================
    // MARK: - 10b. persist on corrupted file rotates to .bak (no data clobber)
    // ====================================================================

    /// Contract: when `persist(_:)` runs against a storage file that exists
    /// on disk but cannot be decoded (truncated JSON, schema skew, etc.),
    /// the actor MUST move the unreadable file aside to `<storageURL>.bak`
    /// before writing the new entry list. This pins the data-loss fix:
    ///
    /// Previously, `persist` used `load()`'s best-effort read which returned
    /// `[]` for any decode failure; the subsequent atomic write would then
    /// overwrite an N-entry file with a single new snapshot, silently
    /// destroying every healthy entry that happened to share the file. The
    /// expected behaviour now is:
    ///
    ///   - The original (corrupt) bytes survive at `<storageURL>.bak`, so
    ///     the user / operator can forensic-recover whatever they need.
    ///   - The new write proceeds against a fresh entry list (`[snapshot]`),
    ///     so `persist(_:)` does not get permanently wedged on the broken
    ///     file.
    func test_persist_withCorruptedJSON_rotatesToBakAndWritesFreshEntry() async throws {
        let storage = try makeStorageURL()
        let corruptBody = Data("this is not json {{{".utf8)
        try corruptBody.write(to: storage, options: .atomic)

        let bak = storage.appendingPathExtension("bak")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bak.path),
            "precondition: .bak must not exist before persist()"
        )

        let persistence = LSPSessionPersistence(storageURL: storage)
        let ws = workspaceURL("rescue")
        let snapshot = snap(
            workspace: ws,
            languageId: "swift",
            openFiles: ["file:///tmp/ws-rescue/Recover.swift"],
            savedAt: 4242
        )

        try await persistence.persist(snapshot)

        // (a) The new snapshot is the only entry visible via load() — the
        //     fresh-start path correctly produced a 1-element file rather
        //     than blowing up or producing an empty array.
        let loaded = await persistence.load()
        XCTAssertEqual(loaded, [snapshot],
                       "persist() against a corrupt file must yield a single-entry list containing only the new snapshot")

        // (b) The corrupted bytes survive at `<storageURL>.bak`, byte-for-byte.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: bak.path),
            "persist() against a corrupt file must rotate the unreadable file to <storageURL>.bak"
        )
        let bakBytes = try Data(contentsOf: bak)
        XCTAssertEqual(
            bakBytes, corruptBody,
            ".bak must contain the original corrupt bytes verbatim (forensic recovery)"
        )
    }

    // ====================================================================
    // MARK: - 10c. persist after rotation overwrites any stale .bak
    // ====================================================================

    /// Contract: a previous rotation may have already produced a `.bak`
    /// file. A second corruption + persist cycle must replace the stale
    /// `.bak` with the freshly rotated bytes rather than refusing to
    /// rotate (which would leave the current bad file on disk and
    /// re-trigger the data-loss bug on the next write).
    func test_persist_corruptedFileTwice_replacesStaleBak() async throws {
        let storage = try makeStorageURL()
        let bak = storage.appendingPathExtension("bak")

        // Round 1: pre-existing stale .bak from a previous rotation.
        try Data("old-bak-bytes".utf8).write(to: bak, options: .atomic)
        // Current storage file is corrupt.
        let corruptV2 = Data("corrupt-v2 }}}".utf8)
        try corruptV2.write(to: storage, options: .atomic)

        let persistence = LSPSessionPersistence(storageURL: storage)
        let ws = workspaceURL("rescue2")
        let snapshot = snap(
            workspace: ws,
            languageId: "swift",
            openFiles: ["file:///tmp/ws-rescue2/A.swift"],
            savedAt: 7777
        )
        try await persistence.persist(snapshot)

        let bakBytes = try Data(contentsOf: bak)
        XCTAssertEqual(
            bakBytes, corruptV2,
            ".bak must be replaced with the just-rotated corrupt bytes, not retain the stale ones"
        )
        let loaded = await persistence.load()
        XCTAssertEqual(
            loaded, [snapshot],
            "fresh persist after rotation must still produce a one-entry file"
        )
    }

    // ====================================================================
    // MARK: - 11. Bonus: round-trip preserves initializationOptions (AnyCodable)
    // ====================================================================

    /// Contract: the `initializationOptions: AnyCodable?` payload — the
    /// language-server-specific blob a client passes during `initialize` —
    /// must round-trip exactly through JSON persistence so that we can
    /// reconstruct identical sessions across launches. AnyCodable preserves
    /// nested arrays and dictionaries.
    func test_persist_thenLoad_preservesInitializationOptions() async throws {
        let storage = try makeStorageURL()
        let persistence = LSPSessionPersistence(storageURL: storage)

        let ws = workspaceURL("alpha")
        let initOpts = AnyCodable([
            "preferences": AnyCodable([
                "importModuleSpecifier": AnyCodable("relative"),
                "includePackageJsonAutoImports": AnyCodable("auto"),
            ]),
            "maxTsServerMemory": AnyCodable(4096),
            "tsserver": AnyCodable([
                "logVerbosity": AnyCodable("off"),
            ]),
        ])
        let snapshot = snap(
            workspace: ws,
            languageId: "typescript",
            openFiles: ["file:///tmp/ws-alpha/a.ts"],
            initializationOptions: initOpts,
            savedAt: 7_777
        )

        try await persistence.persist(snapshot)

        // Re-open the storage in a fresh actor instance to confirm the
        // payload survives a process restart (not just an in-memory cache).
        let reopened = LSPSessionPersistence(storageURL: storage)
        let loaded = await reopened.load()

        XCTAssertEqual(loaded.count, 1, "single snapshot expected after restart")
        XCTAssertEqual(loaded.first, snapshot, "snapshot (including initializationOptions) must survive restart")
        XCTAssertEqual(
            loaded.first?.initializationOptions,
            initOpts,
            "initializationOptions AnyCodable must round-trip nested dictionaries/numbers/strings"
        )
    }
}
