//
//  LSPSessionPersistenceBugSpecTests.swift
//  CalyxTests
//
//  Regression tests for path-canonicalization bugs in
//  `LSPSessionPersistence`. The `persist(_:)` removeAll predicate compares
//  `workspaceRoot: URL` with `==`. Same workspace expressed under different
//  spellings (trailing slash, `/var` vs `/private/var`, un-resolved
//  symlinks) currently produces TWO persisted rows for one logical
//  workspace; on restore the wrong (older) file list can be replayed.
//
//  These tests pin the post-fix behaviour: persisted entries must be keyed
//  on the CANONICAL form of `workspaceRoot` (resolved symlinks, trailing
//  slash stripped), and `load()` must return the canonical URL.
//
//  TDD phase: RED. Each test MUST FAIL against current code.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPSessionPersistenceBugSpecTests: XCTestCase {

    // ====================================================================
    // MARK: - Per-test isolation
    // ====================================================================

    private var storageURL: URL!
    private var tempDirsToCleanUp: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Unique persistence file per test. The parent dir is created here;
        // the JSON file itself is created lazily by `persist(_:)`.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LSPSessionPersistenceBugSpec-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        tempDirsToCleanUp.append(dir)
        storageURL = dir.appendingPathComponent("sessions.json")
    }

    override func tearDownWithError() throws {
        for dir in tempDirsToCleanUp {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirsToCleanUp.removeAll()
        storageURL = nil
        try super.tearDownWithError()
    }

    // ====================================================================
    // MARK: - Helpers
    // ====================================================================

    private func snap(
        workspace: URL,
        languageId: String,
        openFiles: [DocumentUri] = [],
        savedAt: Int64 = 1
    ) -> LSPSessionPersistence.SessionSnapshot {
        return LSPSessionPersistence.SessionSnapshot(
            workspaceRoot: workspace,
            languageId: languageId,
            openFiles: openFiles,
            initializationOptions: nil,
            savedAtUptimeMillis: savedAt
        )
    }

    // ====================================================================
    // MARK: - 1. Trailing slash must NOT create a duplicate row
    // ====================================================================

    /// Bug: `persist`'s removeAll predicate compares URLs with `==`, so the
    /// trailing-slash variant of an otherwise identical path is treated as
    /// a different workspace and a stale row survives. After the fix, the
    /// two URLs must collapse to a single entry and the second persist
    /// must overwrite the first.
    func test_persist_treatsSamePathDifferentSpellings_asSameWorkspace() async throws {
        let persistence = LSPSessionPersistence(storageURL: storageURL)

        let noSlash = URL(fileURLWithPath: "/tmp/foo")
        let withSlash = URL(fileURLWithPath: "/tmp/foo/")

        // Precondition: the two URL values must differ under `==`, otherwise
        // the test would be vacuous. (`URL(fileURLWithPath:)` probes the
        // filesystem; if `/tmp/foo` already exists as a directory on this
        // host, both forms collapse to the trailing-slash form and the bug
        // is not exercised — skip rather than green-by-accident.)
        try XCTSkipIf(
            noSlash == withSlash,
            "host filesystem produces equal URLs for /tmp/foo and /tmp/foo/ — cannot exercise this code path"
        )

        let firstSnapshot = snap(
            workspace: noSlash,
            languageId: "swift",
            openFiles: ["file:///tmp/foo/Old.swift"],
            savedAt: 1
        )
        let secondSnapshot = snap(
            workspace: withSlash,
            languageId: "swift",
            openFiles: [
                "file:///tmp/foo/New.swift",
                "file:///tmp/foo/Extra.swift",
            ],
            savedAt: 2
        )

        try await persistence.persist(firstSnapshot)
        try await persistence.persist(secondSnapshot)

        let loaded = await persistence.load()

        XCTAssertEqual(
            loaded.count, 1,
            "trailing-slash spelling must NOT produce a duplicate row; "
                + "got \(loaded.count) rows: \(loaded.map { $0.workspaceRoot.absoluteString })"
        )
        XCTAssertEqual(
            loaded.first?.openFiles,
            secondSnapshot.openFiles,
            "second persist must overwrite the first; restore replayed the "
                + "wrong (older) file list — symptom of the duplicate-row bug"
        )
    }

    // ====================================================================
    // MARK: - 2. /var vs /private/var must NOT create a duplicate row
    // ====================================================================

    /// Bug: on macOS, `/var/folders/...` is a symlink resolving to
    /// `/private/var/folders/...`. Persisting the same workspace under both
    /// spellings currently produces two distinct rows because the URLs
    /// differ under `==`. After the fix, both spellings must canonicalize
    /// to the same key and collapse to one entry.
    func test_persist_treatsVarAndPrivateVar_asSameWorkspace() async throws {
        // We need TWO distinct URL spellings pointing to the SAME physical
        // directory. macOS symlinks `/var` → `/private/var`, so any directory
        // under `/private/var/...` can also be addressed via `/var/...`.
        //
        // `FileManager.default.temporaryDirectory` on macOS already returns
        // the resolved `/private/var/folders/.../T/` form on recent OS
        // versions, so we derive the un-resolved `/var/folders/.../T/`
        // form by stripping the `/private` prefix.
        let tempPath = FileManager.default.temporaryDirectory.path
        let varPath: String
        let privateVarPath: String
        if tempPath.hasPrefix("/private/var/") {
            privateVarPath = tempPath
            varPath = String(tempPath.dropFirst("/private".count))  // "/var/..."
        } else if tempPath.hasPrefix("/var/") {
            varPath = tempPath
            privateVarPath = "/private" + tempPath
        } else {
            throw XCTSkip(
                "host's temp dir (\(tempPath)) is not under /var or /private/var; "
                    + "cannot exercise the /var symlink code path"
            )
        }

        // Confirm /var → /private/var symlink actually exists on this host.
        let varResolvedPath = URL(fileURLWithPath: "/var").resolvingSymlinksInPath().path
        try XCTSkipIf(
            varResolvedPath != "/private/var",
            "host does not symlink /var → /private/var (got /var → \(varResolvedPath))"
        )

        // Create the physical workspace dir once (under the resolved path).
        let subdirName = "LSPSessionPersistenceBugSpec-VAR-\(UUID().uuidString)"
        let physicalDir = URL(fileURLWithPath: privateVarPath, isDirectory: true)
            .appendingPathComponent(subdirName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: physicalDir, withIntermediateDirectories: true
        )
        tempDirsToCleanUp.append(physicalDir)

        // Two URL spellings of the SAME physical directory. Use the
        // `isDirectory:` overload so Foundation does NOT silently rewrite
        // the spelling via filesystem probing.
        let varSpelling = URL(
            fileURLWithPath: "\(varPath)/\(subdirName)",
            isDirectory: true
        )
        let privateVarSpelling = URL(
            fileURLWithPath: "\(privateVarPath)/\(subdirName)",
            isDirectory: true
        )

        // Precondition: the two URL values must differ under `==`, otherwise
        // the test would be vacuous.
        try XCTSkipIf(
            varSpelling == privateVarSpelling,
            "could not construct distinct /var vs /private/var URL spellings "
                + "(got \(varSpelling.absoluteString) and \(privateVarSpelling.absoluteString))"
        )

        let persistence = LSPSessionPersistence(storageURL: storageURL)
        let firstSnapshot = snap(
            workspace: varSpelling,
            languageId: "swift",
            openFiles: ["file://\(privateVarPath)/\(subdirName)/Old.swift"],
            savedAt: 1
        )
        let secondSnapshot = snap(
            workspace: privateVarSpelling,
            languageId: "swift",
            openFiles: ["file://\(privateVarPath)/\(subdirName)/New.swift"],
            savedAt: 2
        )

        try await persistence.persist(firstSnapshot)
        try await persistence.persist(secondSnapshot)

        let loaded = await persistence.load()

        XCTAssertEqual(
            loaded.count, 1,
            "/var vs /private/var spellings must collapse to one entry; "
                + "got \(loaded.count) rows: \(loaded.map { $0.workspaceRoot.absoluteString })"
        )
        XCTAssertEqual(
            loaded.first?.openFiles,
            secondSnapshot.openFiles,
            "second persist must overwrite the first regardless of "
                + "/var vs /private/var spelling — wrong file list was replayed"
        )
    }

    // ====================================================================
    // MARK: - 3. restore() must return a canonicalized workspaceRoot
    // ====================================================================

    /// Bug: load() returns the workspaceRoot URL verbatim, preserving any
    /// trailing slash and un-resolved symlinks the caller happened to use
    /// at persist time. Downstream code that compares against a
    /// freshly-built workspace URL therefore sees a spurious mismatch.
    /// After the fix, the restored workspaceRoot must be canonicalized:
    /// no trailing slash AND symlinks resolved.
    func test_restore_returnsCanonicalizedWorkspaceRoot() async throws {
        // Build a physical directory under temp, then construct an
        // intentionally non-canonical URL pointing to it: un-resolved
        // /var/... prefix AND trailing slash. The post-fix canonicalization
        // must strip BOTH.
        let tempPath = FileManager.default.temporaryDirectory.path
        let varPath: String
        let privateVarPath: String
        if tempPath.hasPrefix("/private/var/") {
            privateVarPath = tempPath
            varPath = String(tempPath.dropFirst("/private".count))
        } else if tempPath.hasPrefix("/var/") {
            varPath = tempPath
            privateVarPath = "/private" + tempPath
        } else {
            throw XCTSkip(
                "host's temp dir (\(tempPath)) is not under /var or /private/var"
            )
        }

        let varResolvedPath = URL(fileURLWithPath: "/var").resolvingSymlinksInPath().path
        try XCTSkipIf(
            varResolvedPath != "/private/var",
            "host does not symlink /var → /private/var"
        )

        let subdirName = "LSPSessionPersistenceBugSpec-CANON-\(UUID().uuidString)"
        let physicalDir = URL(fileURLWithPath: privateVarPath, isDirectory: true)
            .appendingPathComponent(subdirName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: physicalDir, withIntermediateDirectories: true
        )
        tempDirsToCleanUp.append(physicalDir)

        // Non-canonical spelling: un-resolved /var prefix AND trailing
        // slash. Build via the explicit `isDirectory: true` overload so
        // Foundation does NOT silently rewrite it via filesystem probing.
        let nonCanonicalPath = "\(varPath)/\(subdirName)"
        let nonCanonical = URL(fileURLWithPath: nonCanonicalPath, isDirectory: true)

        // The expected canonical form: resolved /private/var prefix AND
        // no trailing slash.
        let canonicalPath = "\(privateVarPath)/\(subdirName)"
        let canonical = URL(fileURLWithPath: canonicalPath, isDirectory: false)

        // Sanity: the two forms must differ at the absoluteString level,
        // otherwise canonicalization is a no-op and the test is vacuous.
        try XCTSkipIf(
            nonCanonical.absoluteString == canonical.absoluteString,
            "non-canonical and canonical URL spellings collapsed to one form "
                + "(\(nonCanonical.absoluteString)); cannot exercise this code path"
        )

        let persistence = LSPSessionPersistence(storageURL: storageURL)
        let snapshot = snap(
            workspace: nonCanonical,
            languageId: "swift",
            openFiles: ["file://\(canonicalPath)/A.swift"],
            savedAt: 1
        )

        try await persistence.persist(snapshot)

        let loaded = await persistence.load()
        XCTAssertEqual(loaded.count, 1, "expected exactly one snapshot after persist+load")

        let restoredRoot = try XCTUnwrap(
            loaded.first?.workspaceRoot,
            "missing workspaceRoot on restored snapshot"
        )

        // (a) Symlinks resolved: the restored URL's path must equal the
        //     fully-resolved physical path (/private/var/..., not /var/...).
        XCTAssertEqual(
            restoredRoot.path, canonicalPath,
            "restored workspaceRoot must have symlinks resolved "
                + "(expected \(canonicalPath), got \(restoredRoot.path))"
        )

        // (b) No trailing slash: the restored URL string must not retain
        //     the directory-marker `/` the caller supplied at persist time.
        XCTAssertFalse(
            restoredRoot.absoluteString.hasSuffix("/"),
            "restored workspaceRoot must NOT retain a trailing slash "
                + "(got \(restoredRoot.absoluteString))"
        )

        // (c) Idempotent: re-canonicalizing the restored URL must be a
        //     fixed point. Guards against partial fixes (resolve symlinks
        //     but leave trailing slash, or vice versa).
        XCTAssertEqual(
            restoredRoot.resolvingSymlinksInPath().path,
            restoredRoot.path,
            "canonicalization must be idempotent on the restored URL"
        )
    }
}
