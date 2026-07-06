//
//  SessionPersistenceActorTerminationSaveTests.swift
//  CalyxTests
//
//  TDD Red phase (session-restore fix, Bug 2 -- quit-save empty
//  overwrite). ROOT CAUSE: AppDelegate.applicationWillTerminate builds a
//  snapshot from `windowControllers` (buildSnapshot(), AppDelegate.swift
//  ~1053) and hands it to SessionPersistenceActor.saveImmediately(_:),
//  the SAME actor method CalyxWindowController.windowWillClose's
//  legitimate "user closed every window on purpose" save already uses
//  (via AppDelegate.saveImmediately(), AppDelegate.swift ~1040). If
//  windowControllers is already empty at terminate time (teardown
//  ordering can race the last window's close against
//  applicationWillTerminate itself), that quit-time call unconditionally
//  overwrites whatever GOOD, non-empty snapshot is already on disk with
//  an empty one, permanently discarding the user's tabs -- there is no
//  later chance to recover once the good on-disk file is gone.
//
//  THE FIX must NOT touch saveImmediately(_:) itself (window-close's
//  "save deliberately-empty state" behavior must keep working exactly as
//  today); it needs a SEPARATE actor method, used ONLY at the
//  termination call site, that refuses to replace a non-empty on-disk
//  snapshot with an empty one.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention):
//  SessionPersistenceActor.saveAtTermination(_:) does not exist yet. This
//  file fails to compile until the Green phase adds it. That compile
//  failure IS this file's RED evidence.
//
//  Proposed API (SessionPersistenceActor.swift addition, alongside the
//  existing save()/saveImmediately(_:)):
//
//    /// Save used ONLY from applicationWillTerminate. Unlike
//    /// saveImmediately(_:), refuses to let an EMPTY snapshot replace a
//    /// non-empty on-disk snapshot -- teardown ordering can hand this
//    /// call an empty snapshot (windowControllers already drained) even
//    /// though a good session is still on disk from an earlier save,
//    /// and there is no recovery once that file is overwritten. A
//    /// user's deliberate "close every window" save keeps going through
//    /// saveImmediately(_:) (via AppDelegate.saveImmediately(), called
//    /// from windowWillClose), which this method does not change.
//    func saveAtTermination(_ snapshot: SessionSnapshot) async {
//        if snapshot.windows.isEmpty, let onDisk = loadFromPath(savePath), !onDisk.windows.isEmpty {
//            logger.warning("Refusing to overwrite non-empty on-disk session with an empty snapshot at termination")
//            return
//        }
//        await performSave(snapshot)
//    }
//
//  AppDelegate call-site switch (applicationWillTerminate, AppDelegate.swift
//  ~258-264): replace the `saveImmediately(snapshot)` call with
//  `saveAtTermination(snapshot)`, keeping the following
//  `resetRecoveryCounter()` call as-is (that reset is orthogonal to this
//  bug and already gated on the same `windowControllers.isEmpty ||
//  appSession.windows.isEmpty` early return above it).
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): this file drives
//  saveAtTermination(_:) directly against a fresh SessionPersistenceActor
//  instance pointed at a temp dir (CALYX_UITEST_SESSION_DIR, this
//  codebase's existing actor-init test seam -- see
//  SessionPersistenceTests.test_persistence_actor_save_path's identical
//  pattern), so it CAN pin the three save-outcome cases below exactly.
//  It CANNOT pin that applicationWillTerminate actually calls
//  saveAtTermination(_:) instead of saveImmediately(_:) at its call
//  site -- driving applicationWillTerminate itself requires a real,
//  non-empty `windowControllers` array of genuine CalyxWindowControllers,
//  which (per AppDelegateApplyGhosttyResourcesDirEnvironmentTests's own
//  precedent) reaches GhosttyAppController.shared and real window/surface
//  creation and hangs this test host. The Green phase implementer and
//  code review must verify the call-site switch by reading the diff; no
//  test in this file substitutes for that reading.
//
//  Coverage:
//  - empty snapshot + non-empty on-disk snapshot: disk file left
//    byte-for-byte equivalent (decodes identically), no .bak rotation
//  - empty snapshot + no on-disk file yet: write proceeds, disk now holds
//    the empty snapshot
//  - empty snapshot + on-disk file that is ALREADY empty: write proceeds
//    (no false-positive "protect" on an already-empty disk state)
//  - non-empty snapshot: behaves exactly like saveImmediately(_:) always
//    has -- overwrites disk and rotates the previous content to .bak
//

import XCTest
@testable import Calyx

final class SessionPersistenceActorTerminationSaveTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPersistenceActorTerminationSaveTests-\(UUID().uuidString)")
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
        SessionSnapshot(windows: [WindowSnapshot(id: windowID, frame: CGRect(x: 10, y: 20, width: 800, height: 600))])
    }

    private func backupPath(for actor: SessionPersistenceActor) async -> URL {
        await actor.sessionSavePath().appendingPathExtension("bak")
    }

    // MARK: - Empty snapshot must never clobber a non-empty on-disk snapshot

    func test_emptySnapshot_nonEmptyOnDisk_leavesDiskSnapshotUnchanged() async throws {
        let actor = SessionPersistenceActor()
        let originalWindowID = UUID()
        let goodSnapshot = makeNonEmptySnapshot(windowID: originalWindowID)
        await actor.saveImmediately(goodSnapshot)

        let restoredBefore = await actor.restore()
        XCTAssertEqual(restoredBefore, SessionSnapshot.migrate(goodSnapshot),
                       "precondition: the good snapshot must actually be on disk before the termination save runs")

        await actor.saveAtTermination(SessionSnapshot(windows: []))

        let restoredAfter = await actor.restore()
        XCTAssertEqual(restoredAfter, SessionSnapshot.migrate(goodSnapshot),
                       "an empty snapshot at termination must never replace a non-empty on-disk snapshot")
        XCTAssertEqual(restoredAfter?.windows.first?.id, originalWindowID,
                       "the on-disk window identity must be exactly the pre-existing one, not merely non-empty")
    }

    func test_emptySnapshot_nonEmptyOnDisk_doesNotRotateBackup() async throws {
        let actor = SessionPersistenceActor()
        await actor.saveImmediately(makeNonEmptySnapshot())
        let bakPath = await backupPath(for: actor)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bakPath.path),
                       "precondition: no .bak file should exist after the very first save")

        await actor.saveAtTermination(SessionSnapshot(windows: []))

        XCTAssertFalse(FileManager.default.fileExists(atPath: bakPath.path),
                       "refusing the overwrite must skip backup rotation entirely, not just skip the final write")
    }

    // MARK: - Empty snapshot is fine to write when disk has nothing worth protecting

    func test_emptySnapshot_noExistingDiskFile_writesEmptySnapshot() async throws {
        let actor = SessionPersistenceActor()
        let savePath = await actor.sessionSavePath()
        XCTAssertFalse(FileManager.default.fileExists(atPath: savePath.path),
                       "precondition: nothing has been saved yet")

        await actor.saveAtTermination(SessionSnapshot(windows: []))

        let restored = await actor.restore()
        XCTAssertNotNil(restored, "an empty snapshot must still be written to disk when there is no prior file to protect")
        XCTAssertEqual(restored?.windows.count, 0, "the written snapshot must have zero windows")
    }

    func test_emptySnapshot_existingDiskAlreadyEmpty_writesWithoutFalsePositiveProtection() async throws {
        let actor = SessionPersistenceActor()
        await actor.saveImmediately(SessionSnapshot(windows: []))

        await actor.saveAtTermination(SessionSnapshot(windows: []))

        let restored = await actor.restore()
        XCTAssertNotNil(restored, "writing an empty snapshot over an already-empty on-disk snapshot must not be treated as a protected overwrite")
        XCTAssertEqual(restored?.windows.count, 0)
    }

    // MARK: - Non-empty snapshot always saves normally, exactly like saveImmediately(_:)

    func test_nonEmptySnapshot_overwritesExistingDiskContentAndRotatesBackup() async throws {
        let actor = SessionPersistenceActor()
        let oldWindowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: oldWindowID))

        let newWindowID = UUID()
        let newSnapshot = makeNonEmptySnapshot(windowID: newWindowID)
        await actor.saveAtTermination(newSnapshot)

        let restored = await actor.restore()
        XCTAssertEqual(restored?.windows.first?.id, newWindowID,
                       "a non-empty termination snapshot must overwrite disk exactly like saveImmediately(_:) always has")

        let bakPath = await backupPath(for: actor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bakPath.path),
                     "a non-empty save must still rotate the previous content to .bak, same as saveImmediately(_:)")
        guard let bakData = try? Data(contentsOf: bakPath),
              let bakSnapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: bakData) else {
            return XCTFail("expected the rotated .bak file to decode as a SessionSnapshot")
        }
        XCTAssertEqual(bakSnapshot.windows.first?.id, oldWindowID,
                       "the rotated .bak file must hold the PREVIOUS (old) snapshot content")
    }
}
