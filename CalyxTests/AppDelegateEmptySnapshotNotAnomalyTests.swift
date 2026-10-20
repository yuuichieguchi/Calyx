//
//  AppDelegateEmptySnapshotNotAnomalyTests.swift
//  CalyxTests
//
//  The window-lifetime redesign's empty-snapshot anomaly
//  guard is now itself the bug. CONTEXT: earlier in this same feature
//  area, closing the last window stopped terminating the app
//  (applicationShouldTerminateAfterLastWindowClosed now returns
//  `false`), and AppDelegate.removeWindowController(_:) was changed to
//  deliberately call saveImmediately() -- synchronously persisting a
//  genuinely EMPTY snapshot to disk -- the instant windowControllers
//  reaches zero. A decodable, genuinely empty on-disk snapshot is
//  therefore now the NORMAL, expected result of a user deliberately
//  closing every window before quitting, not evidence anything went
//  wrong.
//
//  THE BUG: restoreSession()'s empty-snapshot guard (AppDelegate.swift
//  ~1879-1897) still runs the OLDER C4 anomaly check added before that
//  redesign: when hasRunningPersistentSessionsBridged() reports a
//  RUNNING persistent session, it treats the empty snapshot as an
//  anomaly and routes through preserveDiscardedSessionIfAny() +
//  notifyPreviousSessionNotRestored() instead of accepting it. That
//  premise no longer holds. A persistent session can legitimately still
//  be RUNNING in the daemon's ledger after every window closed -- e.g.
//  session.detach deliberately leaves a session running, unattached to
//  any window, for later reattachment -- and this is not evidence that
//  a snapshot was lost. The next launch after such a close-everything
//  quit wrongly fires "Previous session not restored", and the
//  recovery candidate it points the user at is empty (there is nothing
//  to recover -- the empty snapshot was correct all along).
//
//  THE FIX: a decodable empty snapshot must be accepted unconditionally
//  as "no session to restore" -- never preserved, never notified,
//  regardless of what the daemon's ledger reports. A GENUINE loss of
//  the snapshot itself (decode failure, no file at all, or the
//  crash-loop counter exceeding maxRecoveryAttempts) still falls into
//  attemptSessionRestoreFromDisk()'s separate .empty/.timedOut branches
//  above this guard, whose own preserve+notify handling is UNCHANGED by
//  this fix.
//
//  SCOPE NOTE: CalyxTests/AppDelegateEmptySnapshotAnomalyGuardTests.swift
//  pins the OLD hasRunningPersistentSessions()
//  contract in isolation and is left untouched by this file.
//  This file's fake daemon client and
//  NotificationManager spy patterns are deliberately copied from that
//  file's (and AppDelegateNotifyPreviousSessionNotRestoredTests') own
//  established style, not reused by reference, since both source
//  classes are file-private.
//
//  The method under test is AppDelegate
//  .handleEmptyRestoredSnapshot().
//
//  Its API (AppDelegate.swift, replacing the guard body at
//  restoreSession()'s existing `guard !snapshot.windows.isEmpty else {
//  ... }` ~1879-1897): extracted into its own method for the same
//  reason attemptSessionRestoreFromDisk(deadline:)/
//  attemptPreserveDiscardedSessionOnDisk(deadline:)/
//  scheduleRecoveryCounterResetAfterStableLaunch(delay:) were each
//  already extracted (see AppDelegateRecoveryCounterResetTests' own
//  header) -- restoreSession() itself stays private and, PAST this
//  guard, still reaches GhosttyAppController.shared/real window
//  creation, so it remains unsafe to drive directly from a unit test;
//  this extracted method is the safe PREFIX that never reaches that
//  code, mirroring the established pattern exactly instead of loosening
//  restoreSession()'s own access level:
//
//    /// Extracted from restoreSession()'s empty-snapshot guard (C4
//    /// REVERSAL): a decodable, genuinely empty restored snapshot is
//    /// unconditionally "nothing to restore" -- never an anomaly to
//    /// preserve or notify about, regardless of what the daemon's
//    /// ledger reports. See this method's call site in restoreSession()
//    /// for the full close=save-empty-on-last-window-close context this
//    /// reverses. Not private: called directly on a bare AppDelegate()
//    /// by AppDelegateEmptySnapshotNotAnomalyTests, exactly like
//    /// notifyPreviousSessionNotRestored()'s own precedent.
//    func handleEmptyRestoredSnapshot() -> Bool {
//        logger.info("No session to restore")
//        return false
//    }
//
//  restoreSession()'s guard becomes:
//
//    guard !snapshot.windows.isEmpty else {
//        return handleEmptyRestoredSnapshot()
//    }
//
//  NOTE, not this file's concern to
//  decide: once nothing calls hasRunningPersistentSessionsBridged()/
//  hasRunningPersistentSessions() from restoreSession() any more,
//  whether those two methods become dead code to remove, or are kept
//  because something else still needs them, is an implementation
//  choice -- this file does not assume either answer, which is why its
//  own test below still wires a fake daemon client reporting a RUNNING
//  session: that precondition must hold regardless of whether the fixed
//  code path happens to consult it.
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): this file drives
//  handleEmptyRestoredSnapshot() directly on a bare AppDelegate(), with
//  a temp-dir-backed SessionPersistenceActor (mirrors
//  AppDelegateRecoveryCounterResetTests' own pattern) holding a real,
//  decodable, empty sessions.json on disk, and a fake daemon client
//  reporting a RUNNING persistent session (mirrors
//  AppDelegateEmptySnapshotAnomalyGuardTests' own FakeAnomalyGuardDaemonClient
//  shape). So it CAN pin handleEmptyRestoredSnapshot()'s own
//  return-false/never-preserve/never-notify contract exactly. It CANNOT
//  pin that restoreSession() actually calls this method at its
//  empty-snapshot branch instead of something else -- restoreSession()
//  remains private and reaches GhosttyAppController.shared/real window
//  creation once past this guard (see AppDelegateRecoveryCounterResetTests'
//  own header for the identical constraint). That call-site wiring
//  must be verified by reading the code; no test in this file
//  substitutes for that reading.
//
//  Coverage (single scenario, three assertions on one action -- mirrors
//  AppDelegateSessionRestoreDiskTimeoutTests'
//  test_attemptPreserveDiscardedSessionOnDisk_generousDeadline_realSnapshotOnDisk_returnsPreservedAndMovesFile's
//  own multi-assertion-on-one-act shape):
//  - does not call NotificationManager.shared.sendNotification (no bogus
//    "previous session not restored")
//  - does not move sessions.json aside to sessions.recovery.json (no
//    preserve-as-recovery-candidate)
//  - returns false (still nothing to restore -- the caller must fall
//    through to createNewWindow(), unchanged from today)
//

import XCTest
@testable import Calyx

/// Records the canned ledger this fake replays for listAll() -- copies
/// AppDelegateEmptySnapshotAnomalyGuardTests.FakeAnomalyGuardDaemonClient's
/// own shape (that class is file-private, so it cannot be reused by
/// reference here; only listAll()/sessionState(id:)/kill(id:) need real
/// bodies, every other SessionDaemonClientProtocol requirement comes
/// from the untouched protocol extension default, exactly as there).
private final class FakeRunningSessionDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    var sessionsToReturn: [SessionInfo] = []

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async -> SessionKillOutcome { .killed }
    func listAll() async -> [SessionInfo] { sessionsToReturn }
}

@MainActor
final class AppDelegateEmptySnapshotNotAnomalyTests: XCTestCase {

    private final class NotifySpy: NotificationManager {
        private(set) var callCount = 0

        override func sendNotification(title: String, body: String, originSurfaceID: UUID?) {
            callCount += 1
        }
    }

    private func makeInfo(id: String, state: SessionLifecycleState) -> SessionInfo {
        SessionInfo(
            id: id, name: nil, cwd: nil, state: state,
            createdAtMs: 0, attachedClients: 0, pid: 0, meta: [:]
        )
    }

    /// Mirrors AppDelegateRecoveryCounterResetTests.makeSessionDirActor()'s
    /// per-test-method (not setUp/tearDown) teardown-block convention.
    /// Returns the resolved directory alongside the actor so the test can
    /// write/inspect sessions.json and sessions.recovery.json directly by
    /// path -- both are plain, non-async filesystem operations, unlike
    /// every SessionPersistenceActor accessor, which requires `await`
    /// and so cannot be called from this file's deliberately synchronous
    /// test bodies (see the synchronous-call-stack note below).
    private func makeSessionDirActor() throws -> (actor: SessionPersistenceActor, dir: URL) {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateEmptySnapshotNotAnomalyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let dir = raw.resolvingSymlinksInPath()
        setenv("CALYX_UITEST_SESSION_DIR", dir.path, 1)
        addTeardownBlock {
            unsetenv("CALYX_UITEST_SESSION_DIR")
            try? FileManager.default.removeItem(at: dir)
        }
        return (SessionPersistenceActor(), dir)
    }

    /// Writes a decodable, genuinely empty SessionSnapshot directly to
    /// `sessions.json` under `dir`, synchronously -- bypassing
    /// SessionPersistenceActor.saveImmediately(_:), which is `async` and
    /// so cannot be awaited from this file's synchronous test bodies.
    /// Mirrors performSave(_:)'s own plain JSONEncoder-then-write, minus
    /// the temp-file/atomic-rename/backup-rotation steps this fixture
    /// does not need.
    private func writeEmptySnapshot(to dir: URL) throws {
        let data = try JSONEncoder().encode(SessionSnapshot(windows: []))
        try data.write(to: dir.appendingPathComponent("sessions.json"))
    }

    // MARK: - Empty snapshot + running persistent session

    /// SYNCHRONOUS test method deliberately (no `async`), even though the
    /// Proposed API above never itself touches the daemon client: this
    /// defensively matches the one constraint every other call in this
    /// guard's neighborhood must obey. AppDelegate
    /// .hasRunningPersistentSessionsBridged() (the now-obsolete check
    /// this fix stops consulting here) busy-waits on a PLAIN
    /// (non-detached) `Task { }` that inherits MainActor isolation -- see
    /// that method's own doc comment -- which can only run once the
    /// CURRENT MainActor turn returns; an `async` XCTest method already
    /// occupies that turn itself and would deadlock such a busy-wait,
    /// exactly as that doc comment describes. Should
    /// handleEmptyRestoredSnapshot() ever consult the daemon
    /// synchronously (e.g. an
    /// assertion/sanity check that it is never actually reached), this
    /// test must keep working unchanged rather than newly deadlock -- a
    /// plain synchronous test method, like every real production call
    /// site (applicationDidFinishLaunching), never hits that failure
    /// mode.
    func test_emptyDecodedSnapshot_withRunningPersistentSession_isNotTreatedAsAnomaly() throws {
        let (actor, dir) = try makeSessionDirActor()
        try writeEmptySnapshot(to: dir)
        let savePath = dir.appendingPathComponent("sessions.json")
        let recoveryPath = dir.appendingPathComponent("sessions.recovery.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath.path),
                     "precondition: the empty snapshot fixture must actually be on disk before the act")

        let spy = NotifySpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let daemonClient = FakeRunningSessionDaemonClient()
        daemonClient.sessionsToReturn = [makeInfo(id: "detached-session", state: .running)]

        let appDelegate = AppDelegate()
        appDelegate._sessionPersistenceActorForTesting = actor
        appDelegate._sessionDaemonClientForTesting = daemonClient

        let restoredSomething = appDelegate.handleEmptyRestoredSnapshot()

        XCTAssertFalse(restoredSomething,
                       "an empty snapshot is still nothing to restore -- the caller must fall through " +
                       "to createNewWindow(), exactly as before this fix")
        XCTAssertEqual(spy.callCount, 0,
                       "a decodable empty snapshot is now the NORMAL result of a deliberate " +
                       "close-every-window quit (removeWindowController saves it on purpose once the " +
                       "last window closes) -- a still-RUNNING but merely DETACHED persistent session " +
                       "(e.g. session.detach) is not evidence anything was lost, so this must never fire " +
                       "the 'previous session not restored' notification")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryPath.path),
                       "must not preserve/move the on-disk snapshot aside as a recovery candidate -- " +
                       "there is nothing anomalous here to recover from")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savePath.path),
                     "the original sessions.json must stay exactly where it was -- preserving would " +
                     "have moved it to sessions.recovery.json instead of leaving it in place")
    }
}
