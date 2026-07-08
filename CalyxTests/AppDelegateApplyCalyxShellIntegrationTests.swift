//
//  AppDelegateApplyCalyxShellIntegrationTests.swift
//  CalyxTests
//
//  TDD Red phase (P4, command-log shell integration). Same shape and
//  same reachability bounds as AppDelegateApplyGhosttyResourcesDirEnvironmentTests
//  (see that file's own header for why applicationDidFinishLaunching
//  itself is not exercisable from this test host): calls
//  applyCalyxShellIntegrationIfEnabled() directly on a bare AppDelegate(),
//  with _shellIntegrationRootForTesting standing in for
//  ShellIntegrationInstaller.defaultInstallDirectory. This pins that the
//  method itself correctly gates install+env-apply on
//  CommandTrackingSettings.trackingEnabled. It cannot pin that
//  applicationDidFinishLaunching actually calls this method, or that it
//  runs after applyGhosttyResourcesDirEnvironmentIfNeeded() -- both are
//  properties of applicationDidFinishLaunching's own body, verified by
//  reading the diff, not by a test in this file.
//
//  Both assertions (installed + ZDOTDIR set) are stub-empty right now --
//  applyCalyxShellIntegrationIfEnabled() does nothing -- so the enabled
//  case fails first, for the right reason, before this test ever reaches
//  the (currently vacuously-passing) disabled case.
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateApplyCalyxShellIntegrationTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.AppDelegateApplyCalyxShellIntegrationTests"
    private var originalZdotdir: String?
    private var originalXdgDataDirs: String?

    override func setUp() {
        super.setUp()
        CommandTrackingSettings._testUseSuite(named: settingsSuiteName)
        originalZdotdir = ProcessInfo.processInfo.environment["ZDOTDIR"]
        originalXdgDataDirs = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"]
    }

    override func tearDown() {
        CommandTrackingSettings._testTeardownSuite(named: settingsSuiteName)
        if let originalZdotdir {
            setenv("ZDOTDIR", originalZdotdir, 1)
        } else {
            unsetenv("ZDOTDIR")
        }
        if let originalXdgDataDirs {
            setenv("XDG_DATA_DIRS", originalXdgDataDirs, 1)
        } else {
            unsetenv("XDG_DATA_DIRS")
        }
        super.tearDown()
    }

    private func currentZdotdir() -> String? {
        getenv("ZDOTDIR").map { String(cString: $0) }
    }

    private func currentXdgDataDirs() -> String? {
        getenv("XDG_DATA_DIRS").map { String(cString: $0) }
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateApplyCalyxShellIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_trackingEnabled_installsAndAppliesEnv_trackingDisabled_leavesBothUntouched() throws {
        CommandTrackingSettings.trackingEnabled = true
        let enabledRoot = try makeTempDir()
        let appDelegate = AppDelegate()
        appDelegate._shellIntegrationRootForTesting = enabledRoot

        appDelegate.applyCalyxShellIntegrationIfEnabled()

        XCTAssertTrue(
            ShellIntegrationInstaller.isInstalled(inDirectory: enabledRoot),
            "when command tracking is enabled, the shell integration scripts must be installed into the seam root"
        )
        XCTAssertEqual(
            currentZdotdir(), enabledRoot.appendingPathComponent("zsh").path,
            "when command tracking is enabled, ZDOTDIR must be pointed at the installed root"
        )
        XCTAssertTrue(
            currentXdgDataDirs()?.contains(enabledRoot.path) ?? false,
            "when command tracking is enabled, XDG_DATA_DIRS must include the installed root"
        )

        unsetenv("ZDOTDIR")
        unsetenv("XDG_DATA_DIRS")
        let disabledRoot = try makeTempDir()
        CommandTrackingSettings.trackingEnabled = false
        let secondAppDelegate = AppDelegate()
        secondAppDelegate._shellIntegrationRootForTesting = disabledRoot

        secondAppDelegate.applyCalyxShellIntegrationIfEnabled()

        XCTAssertFalse(
            ShellIntegrationInstaller.isInstalled(inDirectory: disabledRoot),
            "when command tracking is disabled, nothing must be installed"
        )
        XCTAssertNil(
            currentZdotdir(),
            "when command tracking is disabled, ZDOTDIR must be left untouched"
        )
        XCTAssertNil(
            currentXdgDataDirs(),
            "when command tracking is disabled, XDG_DATA_DIRS must be left untouched"
        )
    }
}
