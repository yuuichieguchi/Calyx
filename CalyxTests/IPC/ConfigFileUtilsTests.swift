//
//  ConfigFileUtilsTests.swift
//  CalyxTests
//
//  Direct unit coverage for ConfigFileUtils.directoryExists(at:), added
//  when AgentHooksCoordinator / IPCConfigManager / CodexHooksConfigManager /
//  CodexConfigManager's four duplicated directory-existence-check
//  implementations were consolidated into this single shared helper.
//

import XCTest
@testable import Calyx

final class ConfigFileUtilsTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - directoryExists(at:)

    func test_directoryExists_existingDirectory_returnsTrue() {
        XCTAssertTrue(ConfigFileUtils.directoryExists(at: tempDir))
    }

    func test_directoryExists_nonexistentPath_returnsFalse() {
        XCTAssertFalse(ConfigFileUtils.directoryExists(at: tempDir + "/does-not-exist"))
    }

    func test_directoryExists_pathIsAFileNotADirectory_returnsFalse() {
        let filePath = tempDir + "/a-file"
        FileManager.default.createFile(atPath: filePath, contents: Data("x".utf8))

        XCTAssertFalse(ConfigFileUtils.directoryExists(at: filePath),
                       "A regular file must not be reported as a directory")
    }

    // MARK: - resolveConfigPath(_:) — Round 3 (symlink-following config writes)
    //
    // Added for the Round 3 fix: `~/.claude/settings.json` etc. is
    // commonly a dotfiles-managed symlink, and blanket symlink rejection
    // silently broke hooks installation entirely in that setup. These
    // cover the real dotfiles-adjacent shapes resolveConfigPath must
    // handle: a plain file, a symlink to an existing file, a dangling
    // symlink (writes should land at the link's destination), a
    // symlinked parent directory, and a relative dangling symlink.

    func test_resolveConfigPath_regularFileAndSymlinkToExistingFile() throws {
        let realFile = tempDir + "/settings.json"
        FileManager.default.createFile(atPath: realFile, contents: Data("{}".utf8))

        // A plain, non-symlinked path must resolve to itself.
        XCTAssertEqual(try ConfigFileUtils.resolveConfigPath(realFile), realFile,
                       "A regular file path must pass through unchanged")

        // A symlink to that file must resolve to the real file's path,
        // not the link's own path.
        let linkPath = tempDir + "/link-settings.json"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realFile)

        XCTAssertEqual(try ConfigFileUtils.resolveConfigPath(linkPath), realFile,
                       "A symlink to an existing file must resolve to the real file's path")
    }

    func test_resolveConfigPath_danglingSymlink_resolvesToDestinationPath() throws {
        let targetPath = tempDir + "/not-yet-created/settings.json"
        let linkPath = tempDir + "/dangling-link.json"
        // The destination's parent need not exist yet — dotfiles tools
        // often pre-create the symlink before the target file exists.
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)

        XCTAssertEqual(try ConfigFileUtils.resolveConfigPath(linkPath), targetPath,
                       "A dangling symlink must resolve to its (not-yet-existing) destination path, " +
                       "so callers can create the file there")
    }

    func test_resolveConfigPath_symlinkedParentDirectory_resolvesToRealDirectory() throws {
        let realDir = tempDir + "/dotfiles/.claude"
        try FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        let realFile = realDir + "/settings.json"
        FileManager.default.createFile(atPath: realFile, contents: Data("{}".utf8))

        let linkedParent = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(
            atPath: (linkedParent as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(atPath: linkedParent, withDestinationPath: realDir)

        let pathThroughLinkedParent = linkedParent + "/settings.json"

        XCTAssertEqual(try ConfigFileUtils.resolveConfigPath(pathThroughLinkedParent), realFile,
                       "A path reached through a symlinked parent directory must resolve to the real file path")
    }

    func test_resolveConfigPath_relativeDanglingSymlink_resolvesRelativeToLinkDirectory() throws {
        let linkDir = tempDir + "/home/.claude"
        try FileManager.default.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
        let linkPath = linkDir + "/settings.json"

        // A relative destination, as `ln -s ../../dotfiles/.claude/settings.json` would create.
        try FileManager.default.createSymbolicLink(
            atPath: linkPath,
            withDestinationPath: "../../dotfiles/.claude/settings.json"
        )
        let expectedResolved = tempDir + "/dotfiles/.claude/settings.json"

        XCTAssertEqual(try ConfigFileUtils.resolveConfigPath(linkPath), expectedResolved,
                       "A relative dangling symlink's destination must be absolutized against the link's own directory")
    }

    // MARK: - resolveConfigPath(_:) — Round 3 fix (multi-hop resolution)
    //
    // Round 3 review: the original single-hop implementation only
    // followed ONE symlink when the target didn't exist, so a two-hop
    // dangling chain (link -> link -> not-yet-existing file) resolved to
    // the INTERMEDIATE link instead of the final destination. Since
    // `atomicWrite`'s `rename(2)` replaces whatever sits at its
    // destination (symlink or not) without following it, writing to that
    // intermediate link destroyed it — replacing it with a regular file
    // and orphaning the real intended target. `resolveConfigPath` must
    // now walk the full chain.

    func test_resolveConfigPath_multiHopDanglingSymlink_resolvesToFinalDestination() throws {
        let finalTarget = tempDir + "/dotfiles/.claude/settings.json"
        let middleLink = tempDir + "/middle-link.json"
        let outerLink = tempDir + "/outer-link.json"

        // outerLink -> middleLink -> finalTarget (finalTarget doesn't exist
        // yet, and neither does middleLink at the time outerLink is
        // created — both hops are dangling).
        try FileManager.default.createSymbolicLink(atPath: middleLink, withDestinationPath: finalTarget)
        try FileManager.default.createSymbolicLink(atPath: outerLink, withDestinationPath: middleLink)

        XCTAssertEqual(try ConfigFileUtils.resolveConfigPath(outerLink), finalTarget,
                       "A multi-hop dangling symlink chain must resolve all the way to its final " +
                       "destination, not stop at the first intermediate link")
    }

    func test_resolveConfigPath_selfReferencingLoop_throwsSymlinkDetected() throws {
        let linkA = tempDir + "/loop-a.json"
        let linkB = tempDir + "/loop-b.json"
        try FileManager.default.createSymbolicLink(atPath: linkA, withDestinationPath: linkB)
        try FileManager.default.createSymbolicLink(atPath: linkB, withDestinationPath: linkA)

        XCTAssertThrowsError(try ConfigFileUtils.resolveConfigPath(linkA)) { error in
            XCTAssertEqual(error as? ConfigFileError, .symlinkDetected,
                           "A self-referencing symlink loop must throw .symlinkDetected rather than " +
                           "hang or silently return a bogus path")
        }
    }

    // MARK: - atomicWrite(_:to:) — lock-file location & persistence
    //
    // Post-review fix: atomicWrite's lock file used to live next to the
    // resolved config path and was unlinked after use, which reintroduces
    // the classic flock "dotlock" TOCTOU race (a process that opens the
    // lock path after it's been unlinked gets an unrelated inode, so two
    // processes can both believe they hold "the" lock while actually
    // holding independent locks). The fix moves the lock file to
    // `<AppSupportDirectory>/locks/<sha256 of resolvedPath>.lock` and
    // never unlinks it — these tests cover both halves of that fix.

    func test_atomicWrite_neverCreatesLockFileInTargetDirectory() throws {
        let targetDir = tempDir + "/dotfiles-style-config"
        try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let targetPath = targetDir + "/settings.json"

        try ConfigFileUtils.atomicWrite(data: Data("{}".utf8), to: targetPath)

        let siblingEntries = try FileManager.default.contentsOfDirectory(atPath: targetDir)
        XCTAssertEqual(siblingEntries, ["settings.json"],
                       "atomicWrite must not create any .lock (or other) sibling file in the " +
                       "target directory — the lock file must live entirely outside it")
    }

    func test_atomicWrite_concurrentWritesToSameResolvedPath_areSerializedByPersistentLockFile() throws {
        let targetPath = tempDir + "/serialize-test.json"

        // The first write establishes the persistent lock file at its
        // final, never-unlinked location.
        try ConfigFileUtils.atomicWrite(data: Data("\"first\"".utf8), to: targetPath)
        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: targetPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath),
                      "Precondition: the lock file must still exist (never unlinked) after a write")

        // Simulate a second process/thread already holding the lock by
        // acquiring it directly from the test, on the exact same path
        // atomicWrite itself would compute.
        let externalLockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(externalLockFd, 0,
                                    "Precondition: the persistent lock file must be openable")
        defer { close(externalLockFd) }
        XCTAssertEqual(flock(externalLockFd, LOCK_EX), 0,
                       "Precondition: the test must be able to acquire the lock externally")

        // A concurrent atomicWrite on the SAME resolved path must block
        // on flock (real kernel-level blocking, not a race window) until
        // the external lock below is released.
        let writeAttempted = expectation(description: "background write attempted")
        let writeCompleted = expectation(description: "background write completed")
        DispatchQueue(label: "test.atomicWrite.background").async {
            writeAttempted.fulfill()
            try? ConfigFileUtils.atomicWrite(data: Data("\"second\"".utf8), to: targetPath)
            writeCompleted.fulfill()
        }
        wait(for: [writeAttempted], timeout: 2.0)

        // Give the background write every opportunity to race ahead if
        // the lock weren't actually serializing it against the same inode.
        Thread.sleep(forTimeInterval: 0.3)
        let contentWhileExternallyLocked = try String(contentsOfFile: targetPath, encoding: .utf8)
        XCTAssertEqual(contentWhileExternallyLocked, "\"first\"",
                       "A concurrent atomicWrite to the same resolved path must be blocked by an " +
                       "externally-held lock on the identical (never-unlinked) lock file, not proceed")

        // Releasing the external lock must be exactly what unblocks it.
        XCTAssertEqual(flock(externalLockFd, LOCK_UN), 0)
        wait(for: [writeCompleted], timeout: 2.0)

        let finalContent = try String(contentsOfFile: targetPath, encoding: .utf8)
        XCTAssertEqual(finalContent, "\"second\"",
                       "Once unblocked, the background write must complete and land its own content")
    }

    func test_atomicWrite_lockFilePathIsStableAcrossCalls() throws {
        // A stable (not process-randomized) hash is what makes two
        // independent atomicWrite calls against the same resolved path
        // contend on the identical lock file/inode in the first place.
        let targetPath = tempDir + "/stable-lock-path.json"

        let lockPath1 = try ConfigFileUtils.lockFilePath(forResolvedPath: targetPath)
        let lockPath2 = try ConfigFileUtils.lockFilePath(forResolvedPath: targetPath)

        XCTAssertEqual(lockPath1, lockPath2,
                       "lockFilePath must be a deterministic function of the resolved path")

        let otherPath = tempDir + "/a-different-stable-lock-path.json"
        let otherLockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: otherPath)
        XCTAssertNotEqual(lockPath1, otherLockPath,
                          "Different resolved paths must map to different lock files")
    }
}
