//
//  SessionPersistenceActorRecoveryPreservationTests.swift
//  CalyxTests
//
//  TDD Red phase (session-restore fix, Bug 3a -- silent restore-skip must
//  become recoverable, PRESERVE half). ROOT CAUSE (real user incident):
//  when AppDelegate.restoreSession() skips (crash-loop detected) or
//  fails (no window actually restored) even though a real, non-empty
//  session WAS on disk, that snapshot is never surfaced to the user AND
//  the new run's own periodic saves (requestSave()/saveImmediately(),
//  fired the moment the fallback createNewWindow() window is touched)
//  overwrite sessions.json with the fresh, empty-of-history state --
//  making the loss permanent. There is currently no "the old session is
//  still sitting right there, still recoverable" safety net at all.
//
//  THE FIX, PRESERVE half: before a skipped/failed restoreSession() lets
//  control fall through to the caller's createNewWindow() fallback (whose
//  first save would clobber sessions.json), move whatever is CURRENTLY
//  on disk aside to a dedicated recovery file in the same directory,
//  untouched by any of the new run's own saves (which only ever
//  read/write sessions.json/sessions.json.bak, never the recovery path).
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention):
//  SessionPersistenceActor.preserveSnapshotForRecovery() /
//  hasPreservedSnapshot() / loadPreservedSnapshot() /
//  clearPreservedSnapshot() do not exist yet. This file fails to compile
//  until the Green phase adds all four. That compile failure IS this
//  file's RED evidence.
//
//  Proposed API (SessionPersistenceActor.swift additions, alongside the
//  existing savePath/backupPath and their same-directory convention):
//
//    private let recoverySnapshotPath: URL  // calyxDir/"sessions.recovery.json"
//
//    /// Moves whatever is CURRENTLY on disk at savePath aside to the
//    /// recovery path, so the next launch's own saves (which only ever
//    /// touch savePath/backupPath) cannot clobber it. Takes no snapshot
//    /// parameter deliberately: it preserves the RAW on-disk file,
//    /// whatever its content -- including one restore() itself failed to
//    /// decode (corrupt JSON, unknown future schema version) -- since
//    /// something is still worth keeping in that case too. A no-op when
//    /// savePath does not exist (nothing was ever saved, or a prior
//    /// preserve already moved it -- e.g. a second consecutive bad
//    /// launch keeps only the MOST RECENT preserved snapshot, an
//    /// explicit simplification, not an oversight: this call site only
//    /// ever fires once per launch and the caller (AppDelegate) is
//    /// responsible for not calling it at all when restore() decoded a
//    /// genuinely EMPTY snapshot, see the "empty snapshot guard EXCLUDED"
//    /// wire-point note below).
//    func preserveSnapshotForRecovery() {
//        guard FileManager.default.fileExists(atPath: savePath.path) else { return }
//        try? FileManager.default.removeItem(at: recoverySnapshotPath)
//        try? FileManager.default.moveItem(at: savePath, to: recoverySnapshotPath)
//    }
//
//    func hasPreservedSnapshot() -> Bool {
//        FileManager.default.fileExists(atPath: recoverySnapshotPath.path)
//    }
//
//    func loadPreservedSnapshot() -> SessionSnapshot? {
//        loadFromPath(recoverySnapshotPath)  // reuses the existing schema-migration path
//    }
//
//    func clearPreservedSnapshot() {
//        try? FileManager.default.removeItem(at: recoverySnapshotPath)
//    }
//
//  WIRE-POINT NOTE for the Green phase (restoreSession(), AppDelegate.swift
//  ~1059-1112, NOT re-tested here -- see
//  AppDelegateRecoveryCounterResetTests's own header for why restoreSession()
//  itself is undriveable): call preserveSnapshotForRecovery() from the
//  crash-loop-skip branch and the restoredAny-false branch (both currently
//  `return false` after something WAS decoded from disk), and also when
//  restore() returns nil outright (decode failure OR nothing ever
//  existed -- this method's own no-op-when-missing behavior harmlessly
//  absorbs the "nothing ever existed" sub-case, so the caller does not
//  need to distinguish it from "decode failed"). Do NOT call it when
//  restore() decodes a genuinely EMPTY snapshot (windows.isEmpty == true,
//  decoded successfully) -- that represents the user deliberately closing
//  every window before their last quit, which is not a loss to recover
//  from; this requires restoreSession()'s current single combined guard
//  (`guard let snapshot, !snapshot.windows.isEmpty else { return false }`)
//  to split into a nil-check branch (preserve) and a separate
//  empty-check branch (do not preserve).
//
//  Coverage:
//  - preserve moves the on-disk snapshot aside: original savePath gone,
//    recovery path present, content decodes identical to the original
//  - preserve when no on-disk snapshot exists is a no-op (no crash, no
//    recovery file created)
//  - load/clear round-trip: hasPreservedSnapshot()/loadPreservedSnapshot()
//    reflect the preserved content, clearPreservedSnapshot() removes it
//  - end-to-end protection: once preserved, a NEW save (representing the
//    new run's own periodic/empty save) never touches the preserved file
//

import XCTest
@testable import Calyx

final class SessionPersistenceActorRecoveryPreservationTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionPersistenceActorRecoveryPreservationTests-\(UUID().uuidString)")
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

    // MARK: - Preserve moves the on-disk snapshot aside

    func test_preserve_movesOnDiskSnapshotAside_originalGoneRecoveryPresentContentIdentical() async throws {
        let actor = SessionPersistenceActor()
        let windowID = UUID()
        let original = makeNonEmptySnapshot(windowID: windowID)
        await actor.saveImmediately(original)
        let savePath = await actor.sessionSavePath()
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath.path),
                     "precondition: the snapshot must actually be on disk before preserving")

        await actor.preserveSnapshotForRecovery()

        XCTAssertFalse(FileManager.default.fileExists(atPath: savePath.path),
                       "preserving must move the original file away from savePath, not copy it")
        let hasPreserved = await actor.hasPreservedSnapshot()
        XCTAssertTrue(hasPreserved, "a recovery file must exist after preserving")
        let preserved = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preserved, SessionSnapshot.migrate(original),
                       "the preserved snapshot's content must decode identical to what was on disk")
        XCTAssertEqual(preserved?.windows.first?.id, windowID)
    }

    func test_preserve_noExistingOnDiskSnapshot_isNoOp() async throws {
        let actor = SessionPersistenceActor()
        let savePath = await actor.sessionSavePath()
        XCTAssertFalse(FileManager.default.fileExists(atPath: savePath.path),
                       "precondition: nothing has been saved yet")

        await actor.preserveSnapshotForRecovery()

        let hasPreserved = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasPreserved, "preserving with nothing on disk must not fabricate a recovery file")
    }

    // MARK: - load/clear round-trip

    func test_loadAndClearPreservedSnapshot_roundTrip() async throws {
        let actor = SessionPersistenceActor()
        let windowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: windowID))
        await actor.preserveSnapshotForRecovery()

        let hasBeforeClear = await actor.hasPreservedSnapshot()
        XCTAssertTrue(hasBeforeClear)
        let loadedBeforeClear = await actor.loadPreservedSnapshot()
        XCTAssertEqual(loadedBeforeClear?.windows.first?.id, windowID)

        await actor.clearPreservedSnapshot()

        let hasAfterClear = await actor.hasPreservedSnapshot()
        XCTAssertFalse(hasAfterClear, "clearing must remove the recovery file")
        let loadedAfterClear = await actor.loadPreservedSnapshot()
        XCTAssertNil(loadedAfterClear, "loading after clear must return nil, there is nothing left to decode")
    }

    // MARK: - End-to-end: a subsequent save from the NEW run never touches the preserved file

    func test_afterPreserve_aNewRunsOwnSaveNeverTouchesThePreservedSnapshot() async throws {
        let actor = SessionPersistenceActor()
        let oldWindowID = UUID()
        await actor.saveImmediately(makeNonEmptySnapshot(windowID: oldWindowID))
        await actor.preserveSnapshotForRecovery()
        let preservedBefore = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preservedBefore?.windows.first?.id, oldWindowID)

        // Simulate the new run's own fallback createNewWindow() eventually
        // saving its own (unrelated, fresh) state via the ordinary path.
        await actor.saveImmediately(SessionSnapshot(windows: []))

        let preservedAfter = await actor.loadPreservedSnapshot()
        XCTAssertEqual(preservedAfter?.windows.first?.id, oldWindowID,
                       "the new run's own save must never touch the recovery file, only savePath/backupPath")
    }
}
