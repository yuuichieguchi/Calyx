// NotificationManager.swift
// Calyx
//
// UNUserNotificationCenter integration with rate limiting.

import AppKit
import UserNotifications
import os

private let logger = Logger(subsystem: "com.calyx.terminal", category: "NotificationManager")

@MainActor
class NotificationManager {

    // `var`, not `let` (P4 round-4 fix RED phase test seam): lets tests
    // swap in a subclass that overrides `sendNotification` to spy on
    // calls instead of going through `UNUserNotificationCenter` (which
    // is a no-op in the test host anyway, `permissionGranted` is never
    // set true under `XCTestCase`, see `requestPermission()` below).
    // Mirrors `AppDelegate`'s existing `NSApp.delegate` swap pattern
    // (see `SessionCommandPaletteTests.withMockAppDelegate`). Restored
    // by every test that swaps it. DO NOT reassign from production code.
    //
    // R6-F (r6-fix-spec.md, round-5 review finding C2): `#if DEBUG`-
    // gated, unlike the other three seams' convention, this and `init`
    // below were not, weakening Release's compile-time singleton
    // guarantee. `static let` (Release) still gives every production
    // reader the same `NotificationManager.shared` API.
    #if DEBUG
    static var shared = NotificationManager()
    #else
    static let shared = NotificationManager()
    #endif

    private let center = UNUserNotificationCenter.current()
    private var rateLimiter = RateLimiter(maxPerSecond: 5)
    private var permissionGranted = false

    // Not `private` in DEBUG (same test seam as `shared` above): a
    // test-only subclass defined outside this file must be able to call
    // `super.init()`. R6-F: `private` in Release, since no Release
    // reader needs to construct a second instance.
    #if DEBUG
    init() {
        requestPermission()
    }
    #else
    private init() {
        requestPermission()
    }
    #endif

    private func requestPermission() {
        // The CalyxTests process is an XCTest host, not a real running
        // app -- requesting notification permission here would either
        // hang the test run on a system permission dialog or spuriously
        // prompt on a developer's machine every test run (review
        // finding). Shares `TestEnvironment.isTestHost` (F12,
        // r4-fix-spec.md) with `AppDelegate.installGlobalEventTap`'s
        // equivalent check, this codebase's established convention for
        // skipping side-effecting setup under test. Also skipped under
        // `--uitesting` (mirrors `installGlobalEventTap`'s combined
        // guard): a give-up/OSC9 notification firing during a UI test
        // must not pop the system permission dialog over the app under test.
        guard !TestEnvironment.isTestHost,
              !ProcessInfo.processInfo.arguments.contains("--uitesting") else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            Task { @MainActor in
                self.permissionGranted = granted
                if let error {
                    logger.error("Notification permission error: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendNotification(title: String, body: String, tabID: UUID) {
        guard permissionGranted else { return }
        let sanitizedTitle = NotificationSanitizer.sanitize(title)
        let sanitizedBody = NotificationSanitizer.sanitize(body)

        guard rateLimiter.allow(key: tabID) else {
            logger.debug("Rate limited notification for tab \(tabID)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = sanitizedTitle
        content.body = sanitizedBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                logger.error("Failed to deliver notification: \(error.localizedDescription)")
            }
        }
    }

    func bounceDockIcon() {
        NSApp.requestUserAttention(.informationalRequest)
    }
}

// MARK: - Rate Limiter

struct RateLimiter {
    let maxPerSecond: Int
    private var windows: [UUID: [Date]]

    init(maxPerSecond: Int) {
        self.maxPerSecond = maxPerSecond
        self.windows = [:]
    }

    mutating func allow(key: UUID) -> Bool {
        let now = Date()
        let cutoff = now.addingTimeInterval(-1)

        var recent = windows[key, default: []]
        recent = recent.filter { $0 > cutoff }

        if recent.count >= maxPerSecond {
            windows[key] = recent
            return false
        }

        recent.append(now)
        windows[key] = recent
        return true
    }
}
