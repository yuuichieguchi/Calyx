//
//  AppDelegateNotifyPreviousSessionNotRestoredTests.swift
//  CalyxTests
//
//  TDD Red phase (session-restore fix, Bug 3b -- silent restore-skip must
//  become recoverable, NOTIFY half). Today when restoreSession() skips
//  (crash-loop) or fails (nothing actually restored), the user gets
//  ZERO indication anything went wrong -- the app just quietly opens a
//  blank new window. Paired with Bug 3a's preservation (the old session
//  is now safely moved aside instead of being overwritten), the user
//  still needs to be TOLD it happened and that recovery is possible.
//
//  PATTERN MIRRORED (investigated, not assumed): the reconnect give-up
//  path's own user-facing notification,
//  CalyxWindowController.sendReconnectGiveUpNotification(tabID:), which
//  calls NotificationManager.shared.sendNotification(title:body:tabID:).
//  Its own test, SessionReconnectGiveUpTests
//  .test_giveUp_notificationText_noLongerClaimsSessionIsLostOrOnlyRecoverableAsNew,
//  spies on NotificationManager via a subclass overriding
//  sendNotification and swapping NotificationManager.shared (the R6-F
//  DEBUG seam, `#if DEBUG static var shared` instead of `static let`,
//  specifically added so tests can substitute a spy instead of going
//  through the real UNUserNotificationCenter, which is a no-op under
//  XCTest regardless per NotificationManager.requestPermission()'s own
//  TestEnvironment.isTestHost guard). This file reuses that exact spy
//  pattern, adapted for a tab-less, app-launch-level event: unlike the
//  give-up notification (which is scoped to one reconnecting tab),
//  restoreSession() fires before any window/tab exists at all, so the
//  new notifyPreviousSessionNotRestored() call passes a fresh, throwaway
//  UUID as sendNotification's tabID parameter -- NotificationManager's
//  rate limiter is keyed per-tabID and this is a once-per-launch event,
//  so a fresh UUID each call is correct, not a workaround.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): AppDelegate
//  .notifyPreviousSessionNotRestored() does not exist yet. This file
//  fails to compile until the Green phase adds it. That compile failure
//  IS this file's RED evidence.
//
//  Proposed API (AppDelegate.swift addition):
//
//    /// Tells the user restoreSession() skipped or failed to restore
//    /// their previous windows/tabs, and that the previous session was
//    /// preserved (see SessionPersistenceActor.preserveSnapshotForRecovery(),
//    /// Bug 3a) and can be recovered via the command palette's
//    /// "Recover Previous Session" action (session.recoverPreviousSession,
//    /// Bug 3c). Called once from restoreSession()'s crash-loop-skip and
//    /// restoredAny-false branches (see
//    /// SessionPersistenceActorRecoveryPreservationTests's wire-point
//    /// note for the full branch list), alongside preserveSnapshotForRecovery().
//    /// Not private: called directly on a bare AppDelegate() by this
//    /// file's tests, exactly like reassertHistoryPersistenceIfNeeded()'s
//    /// own precedent (AppDelegateReassertHistoryPersistenceTests).
//    func notifyPreviousSessionNotRestored() {
//        NotificationManager.shared.sendNotification(
//            title: "Previous session not restored",
//            body: "Calyx didn't restore your previous windows and tabs, but they're safely preserved. " +
//                  "Recover them from the command palette (\"Recover Previous Session\").",
//            tabID: UUID()
//        )
//    }
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level): this file drives
//  notifyPreviousSessionNotRestored() directly on a bare AppDelegate(),
//  so it CAN pin the notification's own text content (does not claim
//  data is lost, does mention the palette recovery path). It CANNOT pin
//  that restoreSession() actually calls this method on its skip/fail
//  branches -- restoreSession() is private and undriveable from this
//  test host (see AppDelegateRecoveryCounterResetTests's own header for
//  why). The Green phase implementer and code review must verify that
//  wiring by reading the diff; no test in this file substitutes for
//  that reading.
//
//  Coverage:
//  - calls NotificationManager.shared.sendNotification exactly once
//  - the notification body does not claim the session/data is lost
//  - the notification body mentions the palette as the recovery path
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateNotifyPreviousSessionNotRestoredTests: XCTestCase {

    /// Mirrors SessionReconnectGiveUpTests.GiveUpNotificationSpy: a
    /// NotificationManager subclass spying on sendNotification instead of
    /// going through the real UNUserNotificationCenter.
    private final class NotifySpy: NotificationManager {
        private(set) var callCount = 0
        private(set) var lastTitle: String?
        private(set) var lastBody: String?

        override func sendNotification(title: String, body: String, tabID: UUID) {
            callCount += 1
            lastTitle = title
            lastBody = body
        }
    }

    func test_notifyPreviousSessionNotRestored_sendsExactlyOneNotification() {
        let spy = NotifySpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let appDelegate = AppDelegate()
        appDelegate.notifyPreviousSessionNotRestored()

        XCTAssertEqual(spy.callCount, 1,
                       "a skipped/failed restore must notify the user exactly once")
    }

    func test_notifyPreviousSessionNotRestored_doesNotClaimDataIsLost() {
        let spy = NotifySpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let appDelegate = AppDelegate()
        appDelegate.notifyPreviousSessionNotRestored()

        let body = spy.lastBody?.lowercased() ?? ""
        let title = spy.lastTitle?.lowercased() ?? ""
        XCTAssertFalse(body.contains("lost"),
                       "the notification must not claim the previous session's tabs/data are lost -- " +
                       "Bug 3a preserves them precisely so this is false")
        XCTAssertFalse(title.contains("lost"))
    }

    func test_notifyPreviousSessionNotRestored_mentionsThePaletteAsTheRecoveryPath() {
        let spy = NotifySpy()
        let originalManager = NotificationManager.shared
        NotificationManager.shared = spy
        defer { NotificationManager.shared = originalManager }

        let appDelegate = AppDelegate()
        appDelegate.notifyPreviousSessionNotRestored()

        let body = spy.lastBody?.lowercased() ?? ""
        XCTAssertTrue(body.contains("palette"),
                     "the notification must point the user at the command palette, where " +
                     "session.recoverPreviousSession (Bug 3c) actually performs the recovery")
    }
}
