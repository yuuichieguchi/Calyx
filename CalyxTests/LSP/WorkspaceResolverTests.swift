//
//  WorkspaceResolverTests.swift
//  Calyx
//
//  Tests for `WorkspaceResolver` — the actor that, given a CWD or a file
//  path, infers (a) the workspace root and (b) the LSP `languageId` to
//  use, by walking the file system upwards looking for the workspace
//  markers declared in `LSPServerRegistry`.
//
//  TDD phase: RED. `WorkspaceResolver` does not exist yet. This file is
//  expected to fail to compile until the swift-specialist creates
//  `Calyx/Features/LSP/WorkspaceResolver.swift` per the API contract
//  documented in the parent task brief.
//
//  Contract under test:
//    - resolveWorkspaceRoot(from:) walks upwards from cwd. The first
//      directory that contains either `.git` or any of the literal
//      `workspaceMarkers` from any registry entry is returned. The walk
//      stops at the home directory or the filesystem root.
//    - resolveLanguageId(for:) inspects a file URL. It first asks the
//      registry by file extension, then falls back to matching the file
//      name itself against any registry entry's workspaceMarkers (so
//      `Cargo.toml` → rust even though it has no useful extension).
//    - inferLanguageId(fromWorkspace:) enumerates the root's immediate
//      children and returns the first registry-known language.
//    - Both `resolveWorkspaceRoot` and `resolveLanguageId` cache results
//      per input URL; `clearCache()` wipes both caches.
//
//  All tests use real temp directories so that the actor exercises real
//  FileManager I/O, matching the production code path.
//

import XCTest
@testable import Calyx

@MainActor
final class WorkspaceResolverTests: XCTestCase {

    // MARK: - Helpers

    /// Generate a fresh, isolated temp directory URL per test, and schedule
    /// its removal. We resolve `.standardizedFileURL` so that paths under
    /// `/var` (a symlink to `/private/var` on macOS) compare correctly when
    /// the resolver walks up the tree.
    private func makeTempDir(line: UInt = #line) throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: raw, withIntermediateDirectories: true
        )
        let url = raw.resolvingSymlinksInPath()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Create a subdirectory `name` underneath `parent` and return it.
    @discardableResult
    private func mkdir(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    /// Create an empty file `name` under `parent` and return its URL.
    @discardableResult
    private func touch(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    private func makeResolver() -> WorkspaceResolver {
        WorkspaceResolver()
    }

    // ====================================================================
    // MARK: - resolveWorkspaceRoot(from:)
    // ====================================================================

    func test_resolveWorkspaceRoot_findsTsconfigJson_returnsContainingDir() async throws {
        let root = try makeTempDir()
        let project = try mkdir("my-app", under: root)
        try touch("tsconfig.json", under: project)
        let sub = try mkdir("src", under: project)

        let resolver = makeResolver()
        let resolved = await resolver.resolveWorkspaceRoot(from: sub)

        XCTAssertEqual(
            resolved?.standardizedFileURL.path,
            project.standardizedFileURL.path,
            "Walking up from \(sub.path) should find tsconfig.json at \(project.path)"
        )
    }

    func test_resolveWorkspaceRoot_findsCargoToml() async throws {
        let root = try makeTempDir()
        let project = try mkdir("crate", under: root)
        try touch("Cargo.toml", under: project)
        let sub = try mkdir("src", under: project)

        let resolver = makeResolver()
        let resolved = await resolver.resolveWorkspaceRoot(from: sub)

        XCTAssertEqual(
            resolved?.standardizedFileURL.path,
            project.standardizedFileURL.path
        )
    }

    func test_resolveWorkspaceRoot_findsGitDir() async throws {
        let root = try makeTempDir()
        let project = try mkdir("repo", under: root)
        // `.git` is conventionally a directory at the project root.
        try mkdir(".git", under: project)
        let sub = try mkdir("nested/deeper", under: project)

        let resolver = makeResolver()
        let resolved = await resolver.resolveWorkspaceRoot(from: sub)

        XCTAssertEqual(
            resolved?.standardizedFileURL.path,
            project.standardizedFileURL.path,
            ".git presence alone must mark the directory as a workspace root."
        )
    }

    func test_resolveWorkspaceRoot_walksUpMultipleLevels() async throws {
        let root = try makeTempDir()
        let project = try mkdir("project", under: root)
        try touch("package.json", under: project)
        // Start three levels below the project root.
        let deep = try mkdir("a/b/c", under: project)

        let resolver = makeResolver()
        let resolved = await resolver.resolveWorkspaceRoot(from: deep)

        XCTAssertEqual(
            resolved?.standardizedFileURL.path,
            project.standardizedFileURL.path,
            "Resolver must walk up multiple parent directories to find the marker."
        )
    }

    func test_resolveWorkspaceRoot_noMarkerFound_returnsNil() async throws {
        // Build a self-contained tree under temp with NO markers anywhere.
        // The walk must terminate (at the temp tree root / fs root / home)
        // without producing a false positive.
        let root = try makeTempDir()
        let deep = try mkdir("plain/nested/dir", under: root)

        let resolver = makeResolver()
        let resolved = await resolver.resolveWorkspaceRoot(from: deep)

        XCTAssertNil(
            resolved,
            "With no markers anywhere in the tree, resolver must return nil " +
            "rather than picking an arbitrary ancestor. Got: " +
            "\(String(describing: resolved?.path))"
        )
    }

    func test_resolveWorkspaceRoot_cachesResult() async throws {
        // Cache behaviour is observable indirectly: calling twice yields
        // the same answer. We additionally confirm that after `clearCache()`
        // the resolver still returns the same answer when the FS is
        // unchanged.
        let root = try makeTempDir()
        let project = try mkdir("cached", under: root)
        try touch("go.mod", under: project)
        let sub = try mkdir("pkg", under: project)

        let resolver = makeResolver()
        let first = await resolver.resolveWorkspaceRoot(from: sub)
        let second = await resolver.resolveWorkspaceRoot(from: sub)
        XCTAssertEqual(first?.standardizedFileURL.path,
                       second?.standardizedFileURL.path,
                       "Repeated lookups for the same cwd must return the same root.")
        XCTAssertEqual(first?.standardizedFileURL.path,
                       project.standardizedFileURL.path)

        await resolver.clearCache()
        let third = await resolver.resolveWorkspaceRoot(from: sub)
        XCTAssertEqual(third?.standardizedFileURL.path,
                       project.standardizedFileURL.path,
                       "After clearCache, a fresh lookup must still find the root.")
    }

    // ====================================================================
    // MARK: - resolveLanguageId(for:)
    // ====================================================================

    func test_resolveLanguageId_byExtension_tsFile_returnsTypescript() async throws {
        let root = try makeTempDir()
        let file = try touch("App.ts", under: root)

        let resolver = makeResolver()
        let id = await resolver.resolveLanguageId(for: file)

        XCTAssertEqual(id, "typescript")
    }

    func test_resolveLanguageId_byExtension_rsFile_returnsRust() async throws {
        let root = try makeTempDir()
        let file = try touch("main.rs", under: root)

        let resolver = makeResolver()
        let id = await resolver.resolveLanguageId(for: file)

        XCTAssertEqual(id, "rust")
    }

    func test_resolveLanguageId_byMarkerName_cargoToml_returnsRust() async throws {
        // `Cargo.toml` has no language-specific extension (TOML is generic),
        // but the file *name* is a registered workspace marker for Rust.
        let root = try makeTempDir()
        let file = try touch("Cargo.toml", under: root)

        let resolver = makeResolver()
        let id = await resolver.resolveLanguageId(for: file)

        XCTAssertEqual(
            id, "rust",
            "Cargo.toml must be recognised as rust via workspaceMarkers fallback."
        )
    }

    func test_resolveLanguageId_unknownExtension_returnsNil() async throws {
        let root = try makeTempDir()
        let file = try touch("data.unknown", under: root)

        let resolver = makeResolver()
        let id = await resolver.resolveLanguageId(for: file)

        XCTAssertNil(id)
    }

    // ====================================================================
    // MARK: - inferLanguageId(fromWorkspace:)
    // ====================================================================

    func test_inferLanguageId_fromWorkspace_withCargoToml_returnsRust() async throws {
        let root = try makeTempDir()
        let project = try mkdir("rust-crate", under: root)
        try touch("Cargo.toml", under: project)
        try touch("README.md", under: project)

        let resolver = makeResolver()
        let id = await resolver.inferLanguageId(fromWorkspace: project)

        XCTAssertEqual(id, "rust")
    }

    func test_inferLanguageId_fromWorkspace_empty_returnsNil() async throws {
        let root = try makeTempDir()
        let project = try mkdir("empty-project", under: root)

        let resolver = makeResolver()
        let id = await resolver.inferLanguageId(fromWorkspace: project)

        XCTAssertNil(
            id,
            "An empty workspace has no files to infer a language from."
        )
    }

    // ====================================================================
    // MARK: - caching / clearCache
    // ====================================================================

    func test_resolveLanguageId_cachesResult() async throws {
        let root = try makeTempDir()
        let file = try touch("App.ts", under: root)

        let resolver = makeResolver()
        let first = await resolver.resolveLanguageId(for: file)
        let second = await resolver.resolveLanguageId(for: file)

        XCTAssertEqual(first, "typescript")
        XCTAssertEqual(first, second,
                       "Repeated lookups for the same file must return the same id.")
    }

    // ====================================================================
    // MARK: - LRU bound / walk-up termination (regression)
    // ====================================================================

    /// Repeatedly resolve 2000 distinct (synthetic) paths and assert
    /// the workspace-root cache stays bounded at the LRU capacity of
    /// 1000. Without the LRU, this cache grew unbounded — a long-running
    /// session that opened tens of thousands of files would accumulate
    /// one entry per file forever.
    func test_workspaceRootCache_isBoundedAt1000() async throws {
        let resolver = makeResolver()
        // Anchor the synthetic paths under the user's home directory so
        // every walk terminates quickly at the home boundary (no markers
        // exist anywhere along the synthetic chain).
        let home = FileManager.default.homeDirectoryForCurrentUser
        let unique = UUID().uuidString
        for i in 0..<2000 {
            let fake = home.appendingPathComponent("__lru-bound-\(unique)-\(i)")
            _ = await resolver.resolveWorkspaceRoot(from: fake)
        }
        let count = await resolver.workspaceRootCacheCount
        XCTAssertLessThanOrEqual(
            count, 1000,
            "Workspace-root cache must be LRU-bounded at 1000, got \(count)."
        )
        XCTAssertGreaterThan(
            count, 0,
            "Sanity check: at least some entries should be cached."
        )
    }

    /// The walk-up termination check used to compare `current.path`
    /// against `tempPath` for exact equality. On sandboxed temp
    /// layouts (`/private/var/folders/.../T`) an ancestor of the temp
    /// dir would silently slide past the boundary, letting the walk
    /// scan `/private/var/folders/`, `/private/var/`, etc. — and pick
    /// up bogus markers from those directories.
    ///
    /// We construct a trap registry whose only `workspaceMarker` is
    /// the *name* of the temp dir itself (e.g. `"T"`). That name
    /// definitely exists inside the temp dir's parent directory (it
    /// *is* the temp dir). If the walk-up does not terminate at or
    /// before the temp ancestor, it will match this marker and
    /// return that ancestor as a workspace root — which is wrong.
    func test_walkUp_doesNotEscapeHome_throughSymlinkedAncestor() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let tempParent = tempRoot.deletingLastPathComponent()
        let trapMarker = tempRoot.lastPathComponent
        XCTAssertFalse(
            trapMarker.isEmpty,
            "Sanity: temp directory must have a non-empty last component."
        )

        let trapDefinition = LSPServerDefinition(
            languageId: "calyx-test-trap",
            displayName: "trap",
            executable: "noop",
            arguments: [],
            versionArguments: nil,
            fileExtensions: [],
            workspaceMarkers: [trapMarker],
            installation: LSPInstallationSpec(
                command: "",
                prerequisites: [],
                safeToAutoRun: false
            ),
            defaultInitializationOptions: nil
        )
        let trapRegistry = LSPServerRegistry(entries: [trapDefinition])
        let resolver = WorkspaceResolver(registry: trapRegistry)

        // `tempParent` is an ancestor of NSTemporaryDirectory(). If the
        // walk-up terminates correctly, we return nil immediately.
        // If it slides past, it will inspect `tempParent`, find the
        // temp dir entry there, match the trap marker, and return a
        // false positive.
        let resolved = await resolver.resolveWorkspaceRoot(from: tempParent)
        XCTAssertNil(
            resolved,
            "Walk-up must terminate at or before NSTemporaryDirectory(); "
            + "instead it escaped past and returned "
            + "\(String(describing: resolved?.path))"
        )
    }

    func test_clearCache_resetsBothCaches() async throws {
        // Populate both the workspace-root cache and the language-id cache,
        // then clear, then verify subsequent lookups still produce the same
        // answers (i.e. the resolver tolerates being recomputed).
        let root = try makeTempDir()
        let project = try mkdir("dual", under: root)
        try touch("package.json", under: project)
        let file = try touch("index.ts", under: project)

        let resolver = makeResolver()
        let rootBefore = await resolver.resolveWorkspaceRoot(from: project)
        let idBefore = await resolver.resolveLanguageId(for: file)
        XCTAssertEqual(rootBefore?.standardizedFileURL.path,
                       project.standardizedFileURL.path)
        XCTAssertEqual(idBefore, "typescript")

        await resolver.clearCache()

        let rootAfter = await resolver.resolveWorkspaceRoot(from: project)
        let idAfter = await resolver.resolveLanguageId(for: file)
        XCTAssertEqual(rootAfter?.standardizedFileURL.path,
                       project.standardizedFileURL.path,
                       "Workspace cache must be re-populated correctly after clear.")
        XCTAssertEqual(idAfter, "typescript",
                       "Language cache must be re-populated correctly after clear.")
    }
}
