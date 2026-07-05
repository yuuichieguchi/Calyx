// TestEnvironment.swift
// Calyx
//
// Shared test-host detection (F12, r4-fix-spec.md): a single source of
// truth for "is this process running under XCTest", replacing two
// separate NSClassFromString("XCTestCase") != nil checks
// (AppDelegate.installGlobalEventTap and
// NotificationManager.requestPermission) that had drifted to opposite
// polarities.

import Foundation

enum TestEnvironment {
    static let isTestHost = NSClassFromString("XCTestCase") != nil
}
