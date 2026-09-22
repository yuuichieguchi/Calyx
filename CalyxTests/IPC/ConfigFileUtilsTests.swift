//
//  ConfigFileUtilsTests.swift
//  CalyxTests
//
//  Direct unit coverage for ConfigFileUtils.directoryExists(at:), added
//  when AgentHooksCoordinator / IPCConfigManager / CodexHooksConfigManager /
//  CodexConfigManager's four duplicated directory-existence-check
//  implementations were consolidated into this single shared helper.
//

import CryptoKit
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

    // MARK: - resolveConfigPath(_:) — symlink-following config writes
    //
    // `~/.claude/settings.json` etc. is commonly a dotfiles-managed
    // symlink, and blanket symlink rejection silently broke hooks
    // installation entirely in that setup. These
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

    // MARK: - resolveConfigPath(_:) — multi-hop resolution
    //
    // The original single-hop implementation only
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
    // atomicWrite's lock file used to live next to the
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

    func test_atomicWrite_underTestHost_createsNoLockFileInRealApplicationSupport() throws {
        let targetPath = tempDir + "/real-locks-directory-must-stay-untouched.json"

        // The real directory's lock path is derived here from first
        // principles instead of from `lockFilePath`, which is the thing
        // under test. Hashing the *resolved* path is what makes this
        // name the file production would actually create: the temp
        // directory these tests write to sits under `/var`, a symlink to
        // `/private/var`, and `atomicWrite` hashes only the resolved form.
        let resolvedPath = try ConfigFileUtils.resolveConfigPath(targetPath)
        let digest = SHA256.hash(data: Data(resolvedPath.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        // Computed independently of AppSupportDirectory.path (the thing
        // under test now also redirects under CalyxPathRoot.testRoot, so
        // calling it here would compare the redirected path against
        // itself): AppSupportDirectory.path(testRoot: nil) is production's
        // own formula, reproduced directly so this test still pins
        // isolation from the REAL directory regardless of which seam
        // implements the redirect.
        let realApplicationSupport = AppSupportDirectory.path(testRoot: nil)
        let realLocksDirectory = (realApplicationSupport as NSString).appendingPathComponent("locks")
        let realLockPath = (realLocksDirectory as NSString).appendingPathComponent(hex + ".lock")

        try ConfigFileUtils.atomicWrite(data: Data("{}".utf8), to: targetPath)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: realLockPath),
            "A config write performed under the unit-test host must not create a lock file in the " +
            "user's real Application Support directory. Lock files are named after a hash of the " +
            "config path and are deliberately never deleted, and every test writes to a fresh UUID " +
            "temp path, so each such write would leave one more permanent file behind: \(realLockPath)"
        )

        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: resolvedPath)
        XCTAssertFalse(
            lockPath.hasPrefix(realApplicationSupport),
            "Under the unit-test host the lock directory must resolve outside the real Application " +
            "Support directory (\(realApplicationSupport)), got: \(lockPath)"
        )
    }


    // MARK: - withExclusiveConfig(path:_:) -- the L1.2 consolidated read-modify-write/delete
    //
    // atomicWrite's flock only ever spans the write. Every manager reads
    // its config BEFORE taking that lock, so two concurrent enable/disable
    // calls can both read the same starting bytes and the later write
    // silently discards the earlier one. withExclusiveConfig closes this
    // by holding one flock across the read, the transform, and the write
    // or delete.

    /// A thread-safe log for the concurrency tests below. `NSLock`-guarded
    /// rather than an actor: the test bodies below block synchronously
    /// (DispatchSemaphore, expectations), so plain synchronous mutual
    /// exclusion is what they need, not Swift concurrency isolation.
    private final class SynchronizedBox<Value>: @unchecked Sendable {
        private var value: Value
        private let lock = NSLock()

        init(_ value: Value) { self.value = value }

        func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// Two threads each perform `iterationsPerThread` increments of a
    /// JSON counter through `withExclusiveConfig`, entirely concurrently
    /// (both start before either finishes). If the lock spans the read,
    /// every increment is preserved and the final count is exactly
    /// `2 * iterationsPerThread` -- if it did not, some increments would
    /// be lost to the same race `test_todaysReadThenAtomicWrite` style
    /// code has, and the final count would be lower.
    func test_withExclusiveConfig_concurrentIncrementsFromTwoThreads_loseNoUpdate() throws {
        let targetPath = tempDir + "/counter.json"
        try ConfigFileUtils.atomicWrite(data: Data(#"{"count":0}"#.utf8), to: targetPath)

        let iterationsPerThread = 25
        let bothStarted = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        func increment() {
            _ = bothStarted.signal()
            _ = bothStarted.wait(timeout: .now() + 5)
            for _ in 0..<iterationsPerThread {
                try? ConfigFileUtils.withExclusiveConfig(path: targetPath) { current in
                    guard let current,
                          let parsed = try? JSONSerialization.jsonObject(with: current) as? [String: Int],
                          let count = parsed["count"] else {
                        return current
                    }
                    return try? JSONSerialization.data(withJSONObject: ["count": count + 1])
                }
            }
        }

        // bothStarted is signaled twice (once per thread) and each thread
        // waits for both signals before its own first increment, so
        // neither thread can race ahead and finish alone -- both bodies
        // genuinely overlap in time rather than merely being scheduled on
        // different queues.
        DispatchQueue(label: "test.withExclusiveConfig.counter.a").async(group: group, execute: increment)
        DispatchQueue(label: "test.withExclusiveConfig.counter.b").async(group: group, execute: increment)

        let waitResult = group.wait(timeout: .now() + 15)
        XCTAssertEqual(waitResult, .success, "Both increment threads must finish within the bounded timeout")

        let finalData = try Data(contentsOf: URL(fileURLWithPath: targetPath))
        let finalCount = (try? JSONSerialization.jsonObject(with: finalData) as? [String: Int])?["count"]
        XCTAssertEqual(
            finalCount, iterationsPerThread * 2,
            "Every increment from both threads must be preserved -- a lock that does not span the read " +
            "would lose some of them to the same race read-then-atomicWrite has"
        )
    }

    /// `transform`'s input is `nil` when the file does not exist yet, and
    /// a `nil` return deletes the file -- verified UNDER THE LOCK: an
    /// external `flock` held on the main thread must delay the delete
    /// until released, exactly like the existing
    /// `test_atomicWrite_concurrentWritesToSameResolvedPath_areSerializedByPersistentLockFile`
    /// pattern for writes.
    func test_withExclusiveConfig_transformReturningNil_deletesFileUnderTheLock() throws {
        let targetPath = tempDir + "/to-delete.json"
        try ConfigFileUtils.atomicWrite(data: Data(#"{"count":0}"#.utf8), to: targetPath)

        let resolvedPath = try ConfigFileUtils.resolveConfigPath(targetPath)
        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: resolvedPath)
        // Establishes the persistent lock file at its final location.
        try ConfigFileUtils.atomicWrite(data: Data(#"{"count":0}"#.utf8), to: targetPath)

        let externalLockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(externalLockFd, 0, "Precondition: the persistent lock file must be openable")
        defer { close(externalLockFd) }
        XCTAssertEqual(flock(externalLockFd, LOCK_EX), 0, "Precondition: test must acquire the lock externally")

        let deleteAttempted = expectation(description: "background delete attempted")
        let deleteCompleted = expectation(description: "background delete completed")
        let observedInput = SynchronizedBox<Data??>(nil)
        DispatchQueue(label: "test.withExclusiveConfig.delete").async {
            deleteAttempted.fulfill()
            try? ConfigFileUtils.withExclusiveConfig(path: targetPath) { current in
                observedInput.withValue { $0 = .some(current) }
                return nil
            }
            deleteCompleted.fulfill()
        }
        wait(for: [deleteAttempted], timeout: 2.0)

        // The delete must not proceed while the external lock is held.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetPath),
                     "A nil-returning withExclusiveConfig must not delete the file while an external flock " +
                     "on the same resolved path is held -- deletion happens under the same lock as everything else")

        XCTAssertEqual(flock(externalLockFd, LOCK_UN), 0)
        wait(for: [deleteCompleted], timeout: 2.0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath),
                       "Once unblocked, a transform returning nil must delete the file")
        XCTAssertEqual(observedInput.withValue { $0 }, .some(Data(#"{"count":0}"#.utf8)),
                       "transform must have received the file's current bytes before returning nil")
    }

    /// `transform`'s input is `nil` when the file does not exist at all
    /// (distinct from the delete case above, where it existed and is
    /// removed).
    func test_withExclusiveConfig_missingFile_passesNilToTransform() throws {
        let targetPath = tempDir + "/does-not-exist-yet.json"
        let observedInput = SynchronizedBox<Data??>(.some(Data()))

        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { current in
            observedInput.withValue { $0 = .some(current) }
            return Data(#"{"created":true}"#.utf8)
        }

        XCTAssertEqual(observedInput.withValue { $0 }, .some(nil),
                       "transform must receive nil input when the file is absent")
        XCTAssertEqual(try String(contentsOfFile: targetPath, encoding: .utf8), #"{"created":true}"#)
    }

    /// A throwing `transform` must leave the file untouched AND release
    /// the lock -- verified with a non-blocking `flock` attempt (cannot
    /// hang: `LOCK_NB` returns immediately either way).
    func test_withExclusiveConfig_throwingTransform_leavesFileUntouchedAndReleasesLock() throws {
        struct Boom: Error {}
        let targetPath = tempDir + "/untouched.json"
        try ConfigFileUtils.atomicWrite(data: Data(#"{"count":0}"#.utf8), to: targetPath)

        XCTAssertThrowsError(
            try ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in throw Boom() }
        ) { error in
            XCTAssertTrue(error is Boom, "The transform's own error must propagate unchanged")
        }

        let contentAfterThrow = try String(contentsOfFile: targetPath, encoding: .utf8)
        XCTAssertEqual(contentAfterThrow, #"{"count":0}"#,
                       "A throwing transform must leave the file byte-for-byte untouched")

        let resolvedPath = try ConfigFileUtils.resolveConfigPath(targetPath)
        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: resolvedPath)
        let lockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        defer { close(lockFd) }
        XCTAssertGreaterThanOrEqual(lockFd, 0, "Precondition: the lock file must be openable")
        XCTAssertEqual(
            flock(lockFd, LOCK_EX | LOCK_NB), 0,
            "The lock must be immediately acquirable (non-blocking) after a throwing transform -- a lock " +
            "still held after the throw would deadlock every future write to this path"
        )
        flock(lockFd, LOCK_UN)

        // A subsequent call must succeed too -- proves the release is
        // real, not merely that flock() itself can be re-acquired.
        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in Data(#"{"count":1}"#.utf8) }
        XCTAssertEqual(try String(contentsOfFile: targetPath, encoding: .utf8), #"{"count":1}"#)
    }

    /// When `transform` returns bytes identical to its input, no write
    /// happens at all -- verified by the file's inode staying the same
    /// (atomicWrite's rename+replace always produces a fresh inode) and
    /// its mtime not advancing.
    func test_withExclusiveConfig_inputEqualsOutput_performsNoWrite() throws {
        let targetPath = tempDir + "/no-op.json"
        try ConfigFileUtils.atomicWrite(data: Data(#"{"count":0}"#.utf8), to: targetPath)

        var statBefore = stat()
        XCTAssertEqual(stat(targetPath, &statBefore), 0)

        // A real filesystem clock tick between the writes, so an
        // incorrectly-always-writes implementation would observably
        // advance mtime.
        Thread.sleep(forTimeInterval: 1.0)

        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { current in current }

        var statAfter = stat()
        XCTAssertEqual(stat(targetPath, &statAfter), 0)

        XCTAssertEqual(statBefore.st_ino, statAfter.st_ino,
                       "An identity transform must not rename a fresh file into place -- the inode must be " +
                       "unchanged")
        XCTAssertEqual(statBefore.st_mtimespec.tv_sec, statAfter.st_mtimespec.tv_sec,
                       "An identity transform must not touch the file at all -- mtime must be unchanged")
    }

    /// `withExclusiveConfig`'s guarantee is "the file holds these bytes
    /// AND has this mode", not just the bytes, for a caller that passes
    /// `restoreModeOnNoWrite: true` (a file Calyx owns outright): a file
    /// whose permissions drifted behind this API's back (a plain `chmod`,
    /// not a `withExclusiveConfig` write) must still be brought back to
    /// the requested `mode` on an identical-content call -- this is what
    /// lets reinstalling a hook script or shell integration file repair a
    /// lost executable/readable bit without needing different content to
    /// force a rewrite. The bytes-unchanged, no-churn property from the
    /// test above must still hold alongside this: mtime must not advance,
    /// since no write happens, only a `chmod`.
    func test_withExclusiveConfig_inputEqualsOutput_modeDrifted_restoresModeWithoutRewritingBytes() throws {
        let targetPath = tempDir + "/mode-drift.sh"
        try ConfigFileUtils.withExclusiveConfig(path: targetPath, mode: 0o755, restoreModeOnNoWrite: true) { _ in
            Data("#!/bin/sh\n".utf8)
        }

        // Simulate drift entirely outside withExclusiveConfig's own API.
        XCTAssertEqual(chmod(targetPath, 0o644), 0)

        var statBefore = stat()
        XCTAssertEqual(stat(targetPath, &statBefore), 0)
        XCTAssertEqual(statBefore.st_mode & ~S_IFMT, 0o644, "precondition: mode must actually be drifted")

        // A real filesystem clock tick between the calls, so an
        // incorrectly-always-writes implementation would observably
        // advance mtime.
        Thread.sleep(forTimeInterval: 1.0)

        try ConfigFileUtils.withExclusiveConfig(path: targetPath, mode: 0o755, restoreModeOnNoWrite: true) { current in
            current
        }

        var statAfter = stat()
        XCTAssertEqual(stat(targetPath, &statAfter), 0)

        XCTAssertEqual(statAfter.st_mode & ~S_IFMT, 0o755,
                       "an identical-content call must still restore the requested mode")
        let content = try String(contentsOfFile: targetPath, encoding: .utf8)
        XCTAssertEqual(content, "#!/bin/sh\n", "restoring the mode must never touch the file's bytes")
        XCTAssertEqual(statBefore.st_ino, statAfter.st_ino,
                       "restoring the mode must chmod in place, never rename a fresh file into place")
        XCTAssertEqual(statBefore.st_mtimespec.tv_sec, statAfter.st_mtimespec.tv_sec,
                       "restoring the mode alone (a bare chmod) must not advance mtime -- no bytes are written")
    }

    /// The default (`restoreModeOnNoWrite: false`) must never assert
    /// `mode` on the no-write path: this is the disable-against-a-config-
    /// Calyx-never-wrote-into case (a user's own dotfile that merely
    /// contains, or once contained, one of Calyx's entries -- Calyx does
    /// not own the whole file, only that entry). A caller like
    /// `ClaudeConfigManager`/`ClaudeHooksConfigManager`/`GrokConfigManager`
    /// passes a non-nil `mode` only because it's writing a secret into an
    /// otherwise user-owned file, never because it owns the file outright,
    /// so when `transform` finds nothing of its own to change (no bytes
    /// differ), the file's mode -- drifted or not -- must be left exactly
    /// as it is. Only `restoreModeOnNoWrite: true` (a file Calyx owns
    /// outright, covered by the test above) may narrow or widen it here.
    func test_withExclusiveConfig_inputEqualsOutput_defaultRestoreModeOnNoWrite_neverTouchesAUserOwnedFilesMode() throws {
        let targetPath = tempDir + "/user-owned-no-entry.json"
        try ConfigFileUtils.withExclusiveConfig(path: targetPath, mode: 0o600) { _ in
            Data(#"{"other":1}"#.utf8)
        }

        // Simulate the file being user-owned at some other mode, drifted
        // entirely outside withExclusiveConfig's own API -- mirrors a
        // user's pre-existing config file Calyx has never written a byte
        // into.
        XCTAssertEqual(chmod(targetPath, 0o644), 0)

        // A no-write call (transform finds nothing of its own to touch,
        // so returns the bytes unchanged), same as a disable that finds
        // no Calyx entry to remove. `restoreModeOnNoWrite` is left at its
        // default (`false`).
        try ConfigFileUtils.withExclusiveConfig(path: targetPath, mode: 0o600) { current in current }

        var statAfter = stat()
        XCTAssertEqual(stat(targetPath, &statAfter), 0)
        XCTAssertEqual(statAfter.st_mode & ~S_IFMT, 0o644,
                       "the default restoreModeOnNoWrite: false must never assert mode on the no-write path -- " +
                       "only a caller that owns the whole file opts into that via restoreModeOnNoWrite: true")
    }

    /// `mode: nil` on a content-changing write to an EXISTING file must
    /// leave that file's current mode exactly as it was: Calyx has no
    /// opinion on this file's permission bits, so a write that changes the
    /// bytes must not incidentally narrow or widen them to whatever the
    /// process umask would have produced for a brand-new file. 0640 is
    /// deliberately not a mode any common umask produces from the 0666
    /// `Data.write(to:)` default, so this test cannot pass by coincidence.
    func test_withExclusiveConfig_nilMode_changedContent_leavesExistingModeUntouched() throws {
        let targetPath = tempDir + "/user-owned.json"
        try Data(#"{"count":0}"#.utf8).write(to: URL(fileURLWithPath: targetPath))
        XCTAssertEqual(chmod(targetPath, 0o640), 0)

        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in Data(#"{"count":1}"#.utf8) }

        var statAfter = stat()
        XCTAssertEqual(stat(targetPath, &statAfter), 0)
        XCTAssertEqual(statAfter.st_mode & ~S_IFMT, 0o640,
                       "a nil-mode write must preserve the file's existing mode across the write, not let the " +
                       "temp file's own umask-derived mode carry through the rename")
        XCTAssertEqual(try String(contentsOfFile: targetPath, encoding: .utf8), #"{"count":1}"#,
                       "the content must still be written")
    }

    /// `mode: nil` creating a brand-new file falls back to `0o600`, not
    /// whatever `0666 & ~umask` would otherwise leave it at: "preserve the
    /// existing mode" has no meaning for a file that didn't exist, and the
    /// process umask's default (typically 0644, world-readable) is not a
    /// mode any freshly created config file should default to -- every
    /// config `atomicWrite` has ever created was 0600.
    func test_withExclusiveConfig_nilMode_newFile_fallsBackTo0600NotTheUmaskDefault() throws {
        let targetPath = tempDir + "/brand-new.json"

        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in Data("{}".utf8) }

        var statAfter = stat()
        XCTAssertEqual(stat(targetPath, &statAfter), 0)
        XCTAssertEqual(statAfter.st_mode & ~S_IFMT, 0o600,
                       "a nil-mode write creating a new file must fall back to 0600 -- there is no prior mode " +
                       "to preserve and no mode was requested, but a brand-new config file must not default " +
                       "to the umask's own (typically world-readable) mode")
    }

    /// An explicit `mode` is still enforced on the content-changing write
    /// path, not just the identical-content path covered above: a caller
    /// that opts into Calyx owning this file's mode gets that mode
    /// regardless of whether the write actually changes bytes.
    func test_withExclusiveConfig_explicitMode_enforcedOnContentChangingWrite() throws {
        let targetPath = tempDir + "/explicit-mode.json"
        try Data(#"{"count":0}"#.utf8).write(to: URL(fileURLWithPath: targetPath))
        XCTAssertEqual(chmod(targetPath, 0o644), 0)

        try ConfigFileUtils.withExclusiveConfig(path: targetPath, mode: 0o600) { _ in Data(#"{"count":1}"#.utf8) }

        var statAfter = stat()
        XCTAssertEqual(stat(targetPath, &statAfter), 0)
        XCTAssertEqual(statAfter.st_mode & ~S_IFMT, 0o600,
                       "an explicit mode must be enforced on the content-changing write path, overriding " +
                       "whatever mode the file held before")
        XCTAssertEqual(try String(contentsOfFile: targetPath, encoding: .utf8), #"{"count":1}"#)
    }

    /// A symlinked path resolves to a single real file for both the read
    /// and the write: reading and writing must never disagree about which
    /// file "the path" means.
    func test_withExclusiveConfig_symlinkedPath_readsAndWritesTheSameResolvedFile() throws {
        let realFile = tempDir + "/real-target.json"
        try Data(#"{"count":0}"#.utf8).write(to: URL(fileURLWithPath: realFile))
        let linkPath = tempDir + "/link-to-target.json"
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realFile)

        let observedInput = SynchronizedBox<Data?>(nil)
        try ConfigFileUtils.withExclusiveConfig(path: linkPath) { current in
            observedInput.withValue { $0 = current }
            return Data(#"{"count":1}"#.utf8)
        }

        XCTAssertEqual(observedInput.withValue { $0 }, Data(#"{"count":0}"#.utf8),
                       "withExclusiveConfig must read the symlink's REAL target, not treat the link itself " +
                       "as empty/absent")
        XCTAssertEqual(try String(contentsOfFile: realFile, encoding: .utf8), #"{"count":1}"#,
                       "The write must land on the real target file")
        XCTAssertTrue(ConfigFileUtils.isSymlink(at: linkPath),
                      "The symlink itself must remain a symlink -- the write must not replace it")

        try ConfigFileUtils.withExclusiveConfig(path: linkPath) { _ in nil }

        XCTAssertFalse(FileManager.default.fileExists(atPath: realFile),
                       "A nil-returning transform through a symlinked path must delete the REAL target")
        XCTAssertTrue(ConfigFileUtils.isSymlink(at: linkPath),
                      "Deleting through a symlinked path must not remove the symlink itself, only its " +
                      "(now-dangling) target")
    }

    /// `withExclusiveConfig`'s lock file must land in
    /// `AppSupportDirectory.locksPath`, exactly like `atomicWrite`'s --
    /// reusing `lockFilePath`, not a sibling of the target file.
    func test_withExclusiveConfig_lockFileLandsInLocksPath_neverBesideTarget() throws {
        let targetDir = tempDir + "/dotfiles-style-config"
        try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        let targetPath = targetDir + "/settings.json"

        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in Data("{}".utf8) }

        let siblingEntries = try FileManager.default.contentsOfDirectory(atPath: targetDir)
        XCTAssertEqual(siblingEntries, ["settings.json"],
                       "withExclusiveConfig must not create any lock (or other) sibling file in the target " +
                       "directory")

        let resolvedPath = try ConfigFileUtils.resolveConfigPath(targetPath)
        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: resolvedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath),
                     "withExclusiveConfig must reuse atomicWrite's lockFilePath location")
    }

    /// No `.bak` is ever written by `withExclusiveConfig`, regardless of
    /// whether the transform writes, deletes, or throws.
    func test_withExclusiveConfig_neverWritesABakFile() throws {
        let targetPath = tempDir + "/no-backup.json"
        try ConfigFileUtils.atomicWrite(data: Data(#"{"count":0}"#.utf8), to: targetPath)

        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in Data(#"{"count":1}"#.utf8) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath + ".bak"),
                       "A successful write must not create a .bak file")

        struct Boom: Error {}
        _ = try? ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in throw Boom() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath + ".bak"),
                       "A throwing transform must not create a .bak file either")

        try ConfigFileUtils.withExclusiveConfig(path: targetPath) { _ in nil }
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetPath + ".bak"),
                       "A deleting transform must not create a .bak file either")
    }

    // MARK: - Bounded lock wait

    /// An externally-held `flock` that never releases must not hang
    /// `withExclusiveConfig` forever: past `lockTimeout`, it must give up
    /// and throw rather than leave the chain's queued work -- and the
    /// Settings row it drives -- stuck indefinitely.
    func test_withExclusiveConfig_lockHeldExternally_throwsAfterLockTimeout() throws {
        let targetPath = tempDir + "/lock-timeout.json"
        try ConfigFileUtils.atomicWrite(data: Data("{}".utf8), to: targetPath)
        let resolvedPath = try ConfigFileUtils.resolveConfigPath(targetPath)
        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: resolvedPath)

        // `flock` is scoped to an open file DESCRIPTION, not the calling
        // process, so a second fd in this SAME process/thread still
        // contends against the first -- this reproduces "another process
        // holds the lock" without needing one.
        let externalLockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(externalLockFd, 0, "Precondition: the lock file must be openable")
        defer {
            flock(externalLockFd, LOCK_UN)
            close(externalLockFd)
        }
        XCTAssertEqual(flock(externalLockFd, LOCK_EX), 0,
                       "Precondition: the test must be able to acquire the lock externally")

        XCTAssertThrowsError(
            try ConfigFileUtils.withExclusiveConfig(path: targetPath, lockTimeout: 0.3) { _ in Data("{}".utf8) }
        ) { error in
            guard case ConfigFileError.writeFailed = error else {
                return XCTFail("Expected ConfigFileError.writeFailed once lockTimeout elapses, got \(error)")
            }
        }
    }

    func test_atomicWrite_lockHeldExternally_throwsAfterLockTimeout() throws {
        let targetPath = tempDir + "/atomic-lock-timeout.json"
        let resolvedPath = try ConfigFileUtils.resolveConfigPath(targetPath)
        let lockPath = try ConfigFileUtils.lockFilePath(forResolvedPath: resolvedPath)

        let externalLockFd = open(lockPath, O_WRONLY | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(externalLockFd, 0, "Precondition: the lock file must be openable")
        defer {
            flock(externalLockFd, LOCK_UN)
            close(externalLockFd)
        }
        XCTAssertEqual(flock(externalLockFd, LOCK_EX), 0,
                       "Precondition: the test must be able to acquire the lock externally")

        XCTAssertThrowsError(
            try ConfigFileUtils.atomicWrite(data: Data("{}".utf8), to: targetPath, lockTimeout: 0.3)
        ) { error in
            guard case ConfigFileError.writeFailed = error else {
                return XCTFail("Expected ConfigFileError.writeFailed once lockTimeout elapses, got \(error)")
            }
        }
    }

    // MARK: - A failed write to .tmp only cleans up a .tmp it created

    /// `data.write` failing (here, because `.tmp` already exists as a
    /// directory) must not delete a `.tmp` path that existed before this
    /// write attempt touched it.
    func test_writeAtomically_dataWriteFails_preExistingTempPathIsNotRemoved() throws {
        let targetPath = tempDir + "/pre-existing-temp.json"
        let tempPath = targetPath + ".tmp"
        try FileManager.default.createDirectory(atPath: tempPath, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ConfigFileUtils.atomicWrite(data: Data("{}".utf8), to: targetPath))

        var isDirectory: ObjCBool = false
        let stillExists = FileManager.default.fileExists(atPath: tempPath, isDirectory: &isDirectory)
        XCTAssertTrue(
            stillExists && isDirectory.boolValue,
            "A .tmp path that existed before this write attempt (here, as a directory) must survive a " +
            "write failure untouched, not be deleted by cleanup"
        )
    }

    /// A `.tmp` file this write itself created must still be cleaned up
    /// on failure (here, `rename` failing because the target path is an
    /// existing directory) -- the guard added for the case above must
    /// not defeat this one.
    func test_writeAtomically_renameFails_newlyCreatedTempPathIsRemoved() throws {
        let targetPath = tempDir + "/rename-fails-target"
        try FileManager.default.createDirectory(atPath: targetPath, withIntermediateDirectories: true)

        XCTAssertThrowsError(try ConfigFileUtils.atomicWrite(data: Data("{}".utf8), to: targetPath))

        let tempPath = targetPath + ".tmp"
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempPath),
            "A .tmp file this write itself created must be cleaned up when the following rename fails"
        )
    }
}
