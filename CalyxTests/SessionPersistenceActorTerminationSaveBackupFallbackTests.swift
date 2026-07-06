//
//  SessionPersistenceActorTerminationSaveBackupFallbackTests.swift
//  CalyxTests
//
//  TDD Red phase (recovery-feature code review, WARNING F4 --
//  saveAtTermination doesn't fall back to backupPath, so a corrupt
//  savePath + teardown race destroys the last good backup too). ROOT
//  CAUSE: saveAtTermination(_:)'s protective guard only inspects
//  savePath (`if snapshot.windows.isEmpty, let onDisk =
//  loadFromPath(savePath), !onDisk.windows.isEmpty { ... return }`) --
//  unlike restore(), which falls back to backupPath when savePath fails
//  to decode. If savePath happens to be corrupted/undecodable (e.g. a
//  partial write from an unrelated fault) while backupPath still holds
//  the last good non-empty snapshot, and applicationWillTerminate hands
//  this method an empty snapshot (precisely the teardown race this
//  method exists to guard against), `loadFromPath(savePath)` returns nil,
//  the guard's `let onDisk = ...` binding fails, the guard does not fire,
//  and performSave proceeds: it rotates the corrupt savePath INTO
//  backupPath (overwriting and destroying the last good backup) and
//  writes the empty snapshot to savePath. Both copies of the user's
//  session state are lost in this compound (but plausible) failure.
//
//  THE FIX: when savePath fails to decode (returns nil, not merely
//  "decodes to empty"), also check backupPath before concluding there is
//  nothing worth protecting. A savePath that decodes successfully to an
//  empty snapshot is a DIFFERENT, legitimate case (already covered by
//  SessionPersistenceActorTerminationSaveTests
//  .test_emptySnapshot_existingDiskAlreadyEmpty_writesWithoutFalsePositiveProtection)
//  and must NOT trigger the backupPath fallback -- only an actual decode
//  failure of savePath should.
//
//  No new API surface: saveAtTermination(_:) already exists (this same
//  round). This file's RED evidence is therefore an assertion FAILURE at
//  runtime (the corrupt-savePath-plus-good-backup case currently loses
//  both copies), not a compile failure.
//
//  Proposed implementation (SessionPersistenceActor.swift, replacing the
//  current savePath-only guard):
//
//    func saveAtTermination(_ snapshot: SessionSnapshot) async {
//        if snapshot.windows.isEmpty {
//            let onDiskSavePath = loadFromPath(savePath)
//            if let onDiskSavePath, !onDiskSavePath.windows.isEmpty {
//                logger.warning("Refusing to overwrite non-empty on-disk session with an empty snapshot at termination")
//                return
//            }
//            if onDiskSavePath == nil, let onDiskBackup = loadFromPath(backupPath), !onDiskBackup.windows.isEmpty {
//                logger.warning("Refusing to overwrite non-empty backup (savePath undecodable) with an empty snapshot at termination")
//                return
//            }
//        }
//        await performSave(snapshot)
//    }
//
//  This file deliberately does NOT touch
//  SessionPersistenceActorTerminationSaveTests.swift -- its four existing
//  cases (non-empty on-disk savePath protected; no existing file at all
//  writes through; already-empty on-disk savePath writes through with no
//  false-positive protection; a non-empty termination snapshot always
//  overwrites and rotates .bak) are all satisfied unchanged by the
//  proposed implementation above, since none of them ever has an
//  undecodable savePath.
//
//  Coverage:
//  - corrupt (undecodable) savePath + backupPath holding a good
//    non-empty snapshot + empty terminate-snapshot: NEITHER file is
//    modified (savePath stays corrupt-as-is, backupPath is not rotated
//    away, and still decodes to the original good session)
//  - corrupt savePath + NO backupPath at all + empty terminate-snapshot:
//    the write proceeds (no false protection when there is truly nothing
//    to fall back to)
//  - corrupt savePath + backupPath decodes successfully but to an EMPTY
//    snapshot + empty terminate-snapshot: the write proceeds (an empty
//    backup is not "something worth protecting" either)
//

import XCTest
@testable import Calyx

final class SessionPersistenceActorTerminationSaveBackupFallbackTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPersistenceActorTerminationSaveBackupFallbackTests-\(UUID().uuidString)")
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

    private func makeNonEmptySnapshot(windowID: UUID = UUID()) -> SessionSnapshot {
        SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 0, y: 0, width: 800, height: 600))])
    }

    private func backupPath(for actor: SessionPersistenceActor) async -> URL {
        await actor.sessionSavePath().appendingPathExtension("bak")
    }

    private let corruptBytes = Data("not valid json {".utf8)

    // MARK: - Corrupt savePath + good non-empty backup: neither file modified

    func test_emptySnapshot_corruptSavePath_nonEmptyBackup_neitherFileIsModified() async throws {
        let actor = SessionPersistenceActor()
        let goodWindowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: goodWindowID))
        // A second save rotates the first (good) snapshot into backupPath.
        await actor.saveImmediately(makeNonEmptySnapshot())

        let savePath = await actor.sessionSavePath()
        let bakPath = await backupPath(for: actor)
        try corruptBytes.write(to: savePath)
        let bakBytesBefore = try Data(contentsOf: bakPath)

        await actor.saveAtTermination(SessionSnapshot(windows: []))

        let savePathBytesAfter = try Data(contentsOf: savePath)
        XCTAssertEqual(savePathBytesAfter, corruptBytes,
                       "an empty terminate-save must not touch a corrupt savePath when backupPath still holds " +
                       "a good non-empty snapshot")
        let bakBytesAfter = try Data(contentsOf: bakPath)
        XCTAssertEqual(bakBytesAfter, bakBytesBefore,
                       "the last good backup must survive byte-for-byte: it must never be rotated away or overwritten")

        let survivingBackup = try JSONDecoder().decode(SessionSnapshot.self, from: bakBytesAfter)
        XCTAssertEqual(survivingBackup.windows.first?.id, goodWindowID,
                       "the surviving backup must still decode to the original good session")
    }

    // MARK: - Corrupt savePath + nothing worth protecting: write proceeds

    func test_emptySnapshot_corruptSavePath_noBackupPath_writeProceeds() async throws {
        let actor = SessionPersistenceActor()
        let savePath = await actor.sessionSavePath()
        try corruptBytes.write(to: savePath)
        let bakPath = await backupPath(for: actor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakPath.path),
                       "precondition: no backup exists yet")

        await actor.saveAtTermination(SessionSnapshot(windows: []))

        let restored = await actor.restore()
        XCTAssertNotNil(restored,
                        "with savePath corrupt and no usable backup, there is nothing worth protecting, " +
                        "so the write must proceed")
        XCTAssertEqual(restored?.windows.count, 0)
    }

    func test_emptySnapshot_corruptSavePath_emptyBackupPath_writeProceeds() async throws {
        let actor = SessionPersistenceActor()
        // Get an empty (but decodable) snapshot into backupPath: first an
        // empty save (nothing existed yet, no rotation), then a second
        // save whose rotation moves that empty snapshot into .bak.
        await actor.saveImmediately(SessionSnapshot(windows: []))
        await actor.saveImmediately(makeNonEmptySnapshot())

        let bakPath = await backupPath(for: actor)
        let bakSnapshotBefore = try JSONDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: bakPath))
        XCTAssertEqual(bakSnapshotBefore.windows.count, 0, "precondition: backupPath must decode to an EMPTY snapshot")

        let savePath = await actor.sessionSavePath()
        try corruptBytes.write(to: savePath)

        await actor.saveAtTermination(SessionSnapshot(windows: []))

        let restored = await actor.restore()
        XCTAssertNotNil(restored,
                        "an empty (not corrupt) backup holds nothing worth protecting either, " +
                        "so the write must proceed")
        XCTAssertEqual(restored?.windows.count, 0)
    }
}
