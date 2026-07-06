//
//  SessionPersistenceActorQuarantineCorruptSnapshotTests.swift
//  CalyxTests
//
//  TDD Red phase (recovery-feature code review, CRITICAL F2 -- an
//  undecodable preserved snapshot permanently sticks
//  hasPreservedSessionSnapshot at true with a dead command, ACTOR half).
//  ROOT CAUSE: preserveSnapshotForRecovery()'s own doc comment states it
//  deliberately preserves the raw on-disk file "including one restore()
//  itself failed to decode (corrupt JSON, unknown future schema
//  version)". Since loadPreservedSnapshot() decodes those identically
//  corrupt bytes through the same loadFromPath routine restore() itself
//  uses, it is guaranteed to also return nil for exactly this preserved
//  snapshot. There is currently no way to tell "nothing preserved" apart
//  from "something preserved but unusable" other than
//  hasPreservedSnapshot() (file existence) succeeding while
//  loadPreservedSnapshot() (content) fails -- and no actor-level API to
//  get OUT of that stuck state without a human manually deleting
//  sessions.recovery.json from the filesystem.
//
//  THE FIX, ACTOR half: a new quarantineCorruptPreservedSnapshot()
//  method, called by AppDelegate.recoverPreservedSession() (see
//  AppDelegateRecoverPreservedSessionCorruptSnapshotTests, this same
//  round, for the APP-level wiring half) when it detects exactly this
//  hasPreservedSnapshot()-true-but-loadPreservedSnapshot()-nil state.
//  Renames (does not delete) the unusable file aside to
//  sessions.recovery.json.corrupt, in keeping with
//  preserveSnapshotForRecovery()'s own never-destroy intent -- the bytes
//  might still be forensically useful to the user or a future bug
//  report, they are simply no longer offered through the recovery
//  command. After the call, hasPreservedSnapshot() must report false, so
//  the caller can safely reset hasPreservedSessionSnapshot and retire
//  the dead command.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention):
//  SessionPersistenceActor.quarantineCorruptPreservedSnapshot() does not
//  exist yet. This file fails to compile until the Green phase adds it.
//  That compile failure IS this file's RED evidence.
//
//  Proposed API (SessionPersistenceActor.swift addition, alongside the
//  existing preserveSnapshotForRecovery()/hasPreservedSnapshot()/
//  loadPreservedSnapshot()/clearPreservedSnapshot()):
//
//    /// Called when hasPreservedSnapshot() is true but
//    /// loadPreservedSnapshot() returned nil (corrupt bytes or an
//    /// unknown future schema version): renames the unusable recovery
//    /// file aside to sessions.recovery.json.corrupt instead of
//    /// deleting it -- nothing is destroyed, only retired from the
//    /// active recovery path -- so hasPreservedSnapshot() reports false
//    /// afterwards and the caller can stop offering a dead command. A
//    /// no-op returning false when there is nothing preserved to
//    /// quarantine (mirrors preserveSnapshotForRecovery()'s own
//    /// no-op-when-absent convention).
//    @discardableResult
//    func quarantineCorruptPreservedSnapshot() -> Bool {
//        guard FileManager.default.fileExists(atPath: recoverySnapshotPath.path) else { return false }
//        let quarantinePath = recoverySnapshotPath.appendingPathExtension("corrupt")
//        try? FileManager.default.removeItem(at: quarantinePath)
//        do {
//            try FileManager.default.moveItem(at: recoverySnapshotPath, to: quarantinePath)
//            return true
//        } catch {
//            return false
//        }
//    }
//
//  Coverage:
//  - corrupt bytes preserved (via the real preserveSnapshotForRecovery()
//    path, matching how this state actually arises in production): after
//    the call, the original recovery path is gone, sessions.recovery
//    .json.corrupt exists holding byte-for-byte identical content, and
//    hasPreservedSnapshot() reports false
//  - nothing preserved at all: the call is a safe no-op (returns false,
//    fabricates no .corrupt file, does not crash)
//

import XCTest
@testable import Calyx

final class SessionPersistenceActorQuarantineCorruptSnapshotTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPersistenceActorQuarantineCorruptSnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("CALYX_UITEST_SESSION_DIR")
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    private let corruptBytes = Data("not valid json {".utf8)

    private func quarantinePath(for actor: SessionPersistenceActor) async -> URL {
        await actor.sessionSavePath()
            .deletingLastPathComponent()
            .appendingPathComponent("sessions.recovery.json.corrupt")
    }

    // MARK: - Quarantining a genuinely corrupt preserved snapshot

    func test_quarantine_corruptPreservedSnapshot_movesFileAside_originalGoneCorruptPresentIdenticalBytes() async throws {
        let actor = SessionPersistenceActor()
        let savePath = await actor.sessionSavePath()
        try corruptBytes.write(to: savePath)
        let preserved = await actor.preserveSnapshotForRecovery()
        XCTAssertTrue(preserved, "precondition: the corrupt bytes must actually be moved into the recovery path")
        let loadedBefore = await actor.loadPreservedSnapshot()
        XCTAssertNil(loadedBefore, "precondition: the preserved bytes must fail to decode")

        let quarantined = await actor.quarantineCorruptPreservedSnapshot()

        XCTAssertTrue(quarantined, "quarantining a genuinely corrupt preserved snapshot must succeed")
        let hasPreservedAfter = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasPreservedAfter, "after quarantining, the corrupt file must no longer be reported as preserved")

        let qPath = await quarantinePath(for: actor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: qPath.path),
                     "the quarantined file must exist at sessions.recovery.json.corrupt")
        let quarantinedBytes = try Data(contentsOf: qPath)
        XCTAssertEqual(quarantinedBytes, corruptBytes,
                       "quarantining must preserve the original bytes exactly -- nothing is destroyed, " +
                       "only retired from the active recovery path")
    }

    // MARK: - Nothing preserved: safe no-op

    func test_quarantine_withNothingPreserved_isNoOpReturnsFalse() async throws {
        let actor = SessionPersistenceActor()
        let hasPreserved = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasPreserved, "precondition: nothing has been preserved in this temp dir")

        let quarantined = await actor.quarantineCorruptPreservedSnapshot()

        XCTAssertFalse(quarantined, "quarantining with nothing preserved must report false, not fabricate a file")
        let qPath = await quarantinePath(for: actor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: qPath.path),
                       "no .corrupt file must be created when there was nothing to quarantine")
    }
}
