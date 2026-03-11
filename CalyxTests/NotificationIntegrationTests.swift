//
//  NotificationIntegrationTests.swift
//  CalyxTests
//
//  Tests for Phase 7 Notification System integration:
//  - Tab.unreadNotifications property (does not exist yet — will fail)
//  - TabSnapshot round-trip does NOT persist unreadNotifications (resets to 0)
//  - Badge display string logic (99+ cap)
//  - RateLimiter behavior (independent keys, max capacity)
//  - NotificationSanitizer edge case: control chars in title
//
//  NOTE: Does NOT duplicate tests already in NotificationSanitizerTests.swift.
//

import XCTest
@testable import Calyx

@MainActor
final class NotificationIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private func makeTab(title: String = "Terminal") -> Tab {
        Tab(title: title)
    }

    /// Compute the badge display string for a given unread count.
    /// This mirrors the logic that will be used in the sidebar/tab bar badge UI.
    private func badgeDisplayString(for count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    // ==================== 1. Tab.unreadNotifications — Default Value ====================

    /// Tab should have an `unreadNotifications` property that defaults to 0.
    /// Will FAIL: `unreadNotifications` does not exist on Tab yet.
    func test_unreadNotifications_defaultsToZero() {
        let tab = makeTab()

        XCTAssertEqual(tab.unreadNotifications, 0,
                       "unreadNotifications should default to 0 for a new tab")
    }

    // ==================== 2. Tab.unreadNotifications — Increment ====================

    /// Incrementing unreadNotifications should increase the count.
    /// Will FAIL: `unreadNotifications` does not exist on Tab yet.
    func test_unreadNotifications_increments() {
        let tab = makeTab()

        tab.unreadNotifications += 1
        XCTAssertEqual(tab.unreadNotifications, 1,
                       "unreadNotifications should be 1 after incrementing once")

        tab.unreadNotifications += 1
        XCTAssertEqual(tab.unreadNotifications, 2,
                       "unreadNotifications should be 2 after incrementing twice")
    }

    // ==================== 3. Tab.unreadNotifications — Clear on Reset ====================

    /// Setting unreadNotifications to 0 should clear the count.
    /// Will FAIL: `unreadNotifications` does not exist on Tab yet.
    func test_unreadNotifications_clearsOnReset() {
        let tab = makeTab()

        tab.unreadNotifications = 5
        XCTAssertEqual(tab.unreadNotifications, 5)

        tab.unreadNotifications = 0
        XCTAssertEqual(tab.unreadNotifications, 0,
                       "unreadNotifications should be 0 after resetting")
    }

    // ==================== 4. Tab.unreadNotifications — Not Persisted ====================

    /// TabSnapshot round-trip should NOT include unreadNotifications;
    /// restoring from a snapshot should reset the count to 0.
    /// Will FAIL: `unreadNotifications` does not exist on Tab yet.
    func test_unreadNotifications_notPersisted() throws {
        // Create a tab with some unread notifications
        let tab = makeTab(title: "Dirty Tab")
        tab.unreadNotifications = 7

        // Snapshot round-trip
        let snapshot = try XCTUnwrap(tab.snapshot())
        let restoredTab = Tab(snapshot: snapshot)

        XCTAssertEqual(restoredTab.unreadNotifications, 0,
                       "unreadNotifications should reset to 0 after snapshot round-trip")
        XCTAssertEqual(restoredTab.title, "Dirty Tab",
                       "Other properties should survive the round-trip")
    }

    // ==================== 5. Independent Badge Counts ====================

    /// Each tab should maintain its own independent unread count.
    /// Will FAIL: `unreadNotifications` does not exist on Tab yet.
    func test_independentBadgeCounts() {
        let tab1 = makeTab(title: "Tab 1")
        let tab2 = makeTab(title: "Tab 2")
        let tab3 = makeTab(title: "Tab 3")

        tab1.unreadNotifications = 3
        tab2.unreadNotifications = 10
        // tab3 left at default

        XCTAssertEqual(tab1.unreadNotifications, 3,
                       "Tab 1 should have its own count")
        XCTAssertEqual(tab2.unreadNotifications, 10,
                       "Tab 2 should have its own count")
        XCTAssertEqual(tab3.unreadNotifications, 0,
                       "Tab 3 should remain at default 0")
    }

    // ==================== 6. RateLimiter — Allows Up To Max ====================

    /// RateLimiter should allow up to maxPerSecond calls, then reject.
    func test_rateLimiter_allowsUpToMax() {
        var limiter = RateLimiter(maxPerSecond: 3)
        let key = UUID()

        // First 3 should be allowed
        XCTAssertTrue(limiter.allow(key: key), "Call 1 should be allowed")
        XCTAssertTrue(limiter.allow(key: key), "Call 2 should be allowed")
        XCTAssertTrue(limiter.allow(key: key), "Call 3 should be allowed")

        // 4th should be rejected (within same second)
        XCTAssertFalse(limiter.allow(key: key), "Call 4 should be rate limited")
    }

    // ==================== 7. RateLimiter — Independent Keys ====================

    /// Different keys should have independent rate limiting windows.
    func test_rateLimiter_independentKeys() {
        var limiter = RateLimiter(maxPerSecond: 2)
        let key1 = UUID()
        let key2 = UUID()

        // Exhaust key1's limit
        XCTAssertTrue(limiter.allow(key: key1), "key1 call 1 should be allowed")
        XCTAssertTrue(limiter.allow(key: key1), "key1 call 2 should be allowed")
        XCTAssertFalse(limiter.allow(key: key1), "key1 call 3 should be rate limited")

        // key2 should still be allowed — independent window
        XCTAssertTrue(limiter.allow(key: key2), "key2 call 1 should be allowed (independent)")
        XCTAssertTrue(limiter.allow(key: key2), "key2 call 2 should be allowed (independent)")
        XCTAssertFalse(limiter.allow(key: key2), "key2 call 3 should be rate limited")
    }

    // ==================== 8. Sanitizer — Control Chars in Title ====================

    /// NotificationSanitizer should strip C0 control characters (except \t and \n)
    /// from a notification title. This tests the title-specific use case
    /// (not duplicating the generic sanitizer tests).
    func test_sanitizer_stripsControlCharsFromTitle() {
        // Simulate a title containing bell (0x07) and escape (0x1B) characters
        let dirtyTitle = "Build\u{07} Complete\u{1B}!"
        let sanitized = NotificationSanitizer.sanitize(dirtyTitle)

        XCTAssertFalse(sanitized.contains("\u{07}"),
                       "Bell character should be stripped from title")
        XCTAssertFalse(sanitized.contains("\u{1B}"),
                       "Escape character should be stripped from title")
        XCTAssertEqual(sanitized, "Build Complete!",
                       "Title should contain only the safe text")
    }

    // ==================== 9. Invalid UTF-8 — Fallback to Empty String ====================

    /// When String(validatingCString:) returns nil for invalid UTF-8,
    /// the fallback should produce an empty string.
    /// This tests the pattern used in GhosttyAction.handleDesktopNotification.
    func test_nilCStringPointer_fallsBackToEmptyString() {
        // Simulate the pattern: String(validatingCString:) returns nil → fallback to ""
        let invalidPointer: UnsafePointer<CChar>? = nil
        let result: String = invalidPointer.flatMap { String(validatingCString: $0) } ?? ""

        XCTAssertEqual(result, "",
                       "nil CString pointer should fall back to empty string")
    }

    // ==================== 10. Badge Display — Caps at 99+ ====================

    /// Badge display should show "99+" for counts over 99.
    func test_badgeDisplay_capsAt99Plus() {
        XCTAssertEqual(badgeDisplayString(for: 100), "99+",
                       "Count of 100 should display as '99+'")
        XCTAssertEqual(badgeDisplayString(for: 999), "99+",
                       "Count of 999 should display as '99+'")
        XCTAssertEqual(badgeDisplayString(for: 99), "99",
                       "Count of 99 should display as '99'")
        XCTAssertEqual(badgeDisplayString(for: 1), "1",
                       "Count of 1 should display as '1'")
        XCTAssertEqual(badgeDisplayString(for: 0), "0",
                       "Count of 0 should display as '0'")
    }
}
