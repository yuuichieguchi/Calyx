//
//  WorkspaceResolverBugSpecTests.swift
//  Calyx
//
//  Wave 1 RETROFIT — independent verification.
//
//  These regression tests target two specific bugs in `WorkspaceResolver`
//  whose fixes must be observable from the test surface:
//
//  Bug 1 — Unbounded caches.
//    `workspaceRootCache` and `languageIdCache` previously grew without
//    bound. POST-FIX they are bounded LRU containers (~1000 entries each)
//    with eviction. Verified here by hammering the resolver with 1500
//    distinct synthetic URLs and asserting the internal count accessors
//    stay <= 1000.
//
//    The internal accessors `workspaceRootCacheCount` and
//    `languageIdCacheCount` MUST exist for these tests to compile. If a
//    future regression strips the LRU plumbing, the tests fail to compile
//    rather than silently report a non-bug. That compile-time fence IS the
//    independent verification signal.
//
//  Bug 2 — Walk-up boundary escape.
//    Walk-up termination compared `current.path == tempPath` exactly. With
//    a symlinked ancestor that doesn't normalize to `tempPath`, the walk
//    slid past the boundary. POST-FIX walk-up also stops when the current
//    directory is an ancestor of home or temp
//    (`tempPath.hasPrefix(currentPath + "/")` etc.). Verified here by
//    starting the walk at the parent of NSTemporaryDirectory() — which IS
//    an ancestor of temp — and asserting the walk does not escape upward.
//

import XCTest
@testable import Calyx

@MainActor
final class WorkspaceResolverBugSpecTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(line: UInt = #line) throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceResolverBugSpec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: raw, withIntermediateDirectories: true
        )
        let url = raw.resolvingSymlinksInPath()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    @discardableResult
    private func mkdir(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }

    @discardableResult
    private func touch(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// Synthetic, on-disk leaf directory used to populate the workspace
    /// root cache. Each call returns a unique URL underneath `root`.
    private func makeSyntheticLeaf(_ index: Int, under root: URL) throws -> URL {
        // Spread across two levels of subdirectories to avoid blowing up a
        // single directory's entry count on systems that get slow with
        // tens of thousands of siblings. (1500 entries / 32 = ~47.)
        let bucket = String(format: "b%02d", index % 32)
        let bucketDir = root.appendingPathComponent(bucket)
        if !FileManager.default.fileExists(atPath: bucketDir.path) {
            try FileManager.default.createDirectory(
                at: bucketDir, withIntermediateDirectories: true
            )
        }
        let leaf = bucketDir.appendingPathComponent("leaf-\(index)")
        try FileManager.default.createDirectory(
            at: leaf, withIntermediateDirectories: true
        )
        return leaf
    }

    /// Synthetic, on-disk file used to populate the languageId cache. The
    /// extension `.ts` is registered to "typescript", but we vary names so
    /// each URL key is distinct.
    private func makeSyntheticFile(_ index: Int, under root: URL) throws -> URL {
        let bucket = String(format: "b%02d", index % 32)
        let bucketDir = root.appendingPathComponent(bucket)
        if !FileManager.default.fileExists(atPath: bucketDir.path) {
            try FileManager.default.createDirectory(
                at: bucketDir, withIntermediateDirectories: true
            )
        }
        let file = bucketDir.appendingPathComponent("file-\(index).ts")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        return file
    }

    private func makeResolver() -> WorkspaceResolver {
        WorkspaceResolver()
    }

    // ====================================================================
    // MARK: - Bug 1: bounded LRU eviction
    // ====================================================================

    func test_workspaceRootCache_evictsLRU_whenExceedingCapacity() async throws {
        let root = try makeTempDir()
        let resolver = makeResolver()

        let total = 1500
        let cap = 1000

        for i in 0..<total {
            let leaf = try makeSyntheticLeaf(i, under: root)
            _ = await resolver.resolveWorkspaceRoot(from: leaf)
        }

        // If `workspaceRootCacheCount` is not exposed by WorkspaceResolver,
        // this line fails at compile time — and that compile-time failure
        // IS the independent signal that the LRU was not wired.
        let count = await resolver.workspaceRootCacheCount
        XCTAssertLessThanOrEqual(
            count, cap,
            "workspaceRootCache must enforce a bounded LRU (cap ~\(cap)). " +
            "After inserting \(total) distinct URLs the cache held \(count) " +
            "entries; bug-fix expectation is <= \(cap)."
        )
        XCTAssertGreaterThan(
            count, 0,
            "Sanity: after \(total) lookups the cache should be non-empty."
        )
    }

    func test_languageIdCache_evictsLRU_whenExceedingCapacity() async throws {
        let root = try makeTempDir()
        let resolver = makeResolver()

        let total = 1500
        let cap = 1000

        for i in 0..<total {
            let file = try makeSyntheticFile(i, under: root)
            _ = await resolver.resolveLanguageId(for: file)
        }

        // Compile-time accessor fence — see note on Bug 1 above.
        let count = await resolver.languageIdCacheCount
        XCTAssertLessThanOrEqual(
            count, cap,
            "languageIdCache must enforce a bounded LRU (cap ~\(cap)). " +
            "After inserting \(total) distinct file URLs the cache held " +
            "\(count) entries; bug-fix expectation is <= \(cap)."
        )
        XCTAssertGreaterThan(
            count, 0,
            "Sanity: after \(total) lookups the cache should be non-empty."
        )
    }

    func test_clearCache_resetsBothCaches_toEmpty() async throws {
        let root = try makeTempDir()
        let resolver = makeResolver()

        // Populate both caches with a small, sane number of entries.
        for i in 0..<8 {
            let leaf = try makeSyntheticLeaf(i, under: root)
            _ = await resolver.resolveWorkspaceRoot(from: leaf)
            let file = try makeSyntheticFile(i, under: root)
            _ = await resolver.resolveLanguageId(for: file)
        }

        let rootCountBefore = await resolver.workspaceRootCacheCount
        let langCountBefore = await resolver.languageIdCacheCount
        XCTAssertGreaterThan(
            rootCountBefore, 0,
            "Precondition: workspaceRootCache must be non-empty before clear."
        )
        XCTAssertGreaterThan(
            langCountBefore, 0,
            "Precondition: languageIdCache must be non-empty before clear."
        )

        await resolver.clearCache()

        let rootCountAfter = await resolver.workspaceRootCacheCount
        let langCountAfter = await resolver.languageIdCacheCount
        XCTAssertEqual(
            rootCountAfter, 0,
            "clearCache must empty workspaceRootCache (was \(rootCountBefore))."
        )
        XCTAssertEqual(
            langCountAfter, 0,
            "clearCache must empty languageIdCache (was \(langCountBefore))."
        )
    }

    // ====================================================================
    // MARK: - Bug 2: walk-up boundary escape
    // ====================================================================

    func test_walkUp_stopsAtAncestor_ofTemporaryDirectory() async throws {
        // Compute the canonical, symlink-resolved path of the system
        // temporary directory and use its PARENT as the walk start. That
        // parent is, by definition, an ancestor of NSTemporaryDirectory()
        // and therefore `tempPath.hasPrefix(parent.path + "/")` is true —
        // which is the exact predicate the post-fix walk-up must honour
        // to refuse traversal upward.
        let tempPath = (NSTemporaryDirectory() as NSString).standardizingPath
        let tempURL = URL(fileURLWithPath: tempPath, isDirectory: true)
            .resolvingSymlinksInPath()
        let tempAncestor = tempURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()

        // Precondition: tempAncestor really is an ancestor of tempURL.
        XCTAssertTrue(
            tempURL.path.hasPrefix(tempAncestor.path + "/"),
            "Precondition failed: \(tempAncestor.path) is not an ancestor " +
            "of \(tempURL.path). Cannot exercise the boundary check."
        )
        // Precondition: tempAncestor must itself exist.
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: tempAncestor.path,
                                           isDirectory: &isDir) && isDir.boolValue,
            "Precondition failed: \(tempAncestor.path) is not an existing " +
            "directory; cannot exercise walk-up boundary."
        )

        // Also create a sibling temp tree that DOES contain a marker, just
        // to prove the resolver is functional in this test process. The
        // sibling lives inside our own scoped temp dir, not at tempAncestor.
        let scoped = try makeTempDir()
        let proj = try mkdir("control-project", under: scoped)
        try touch("package.json", under: proj)
        let resolver = makeResolver()
        let controlResolved = await resolver.resolveWorkspaceRoot(from: proj)
        XCTAssertEqual(
            controlResolved?.standardizedFileURL.path,
            proj.standardizedFileURL.path,
            "Control: resolver must find a real marker on a normal tree, " +
            "otherwise this test environment is broken."
        )

        // Now the actual boundary test: starting from an ancestor of temp,
        // the walk must NOT escape upward into /private/var, /private, or
        // / and pick up an unrelated marker.
        let escaped = await resolver.resolveWorkspaceRoot(from: tempAncestor)

        // The walk should either return nil (no marker found at the
        // boundary itself) or — if a marker happens to live AT tempAncestor
        // — return exactly tempAncestor. It must NEVER return any path
        // that is a strict ancestor of tempAncestor.
        if let escaped {
            let escapedPath = escaped.resolvingSymlinksInPath().path
            let boundaryPath = tempAncestor.path
            XCTAssertFalse(
                boundaryPath.hasPrefix(escapedPath + "/"),
                "Walk-up escaped the temp-ancestor boundary: returned " +
                "\(escapedPath), which is a strict ancestor of " +
                "\(boundaryPath). POST-FIX behaviour: walk-up must stop " +
                "when current is an ancestor of tempPath."
            )
        } else {
            // nil is the expected outcome in a clean environment: no
            // workspace markers exist at the boundary or below it on
            // the way down, so the walk correctly produces nil.
            XCTAssertNil(escaped)
        }
    }
}
