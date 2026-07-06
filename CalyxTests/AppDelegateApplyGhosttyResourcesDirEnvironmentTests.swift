//
//  AppDelegateApplyGhosttyResourcesDirEnvironmentTests.swift
//  CalyxTests
//
//  TDD Red phase (persistent-session shell-integration fix), Swift half,
//  R3 (AppDelegate wiring). ROOT CAUSE: persistent panes run
//  `calyx-session attach` as the surface command; the Rust attach client
//  (fixed in parallel) forwards ghostty's zsh shell-integration env to
//  the daemon shell, keyed off GHOSTTY_RESOURCES_DIR in the CLIENT's own
//  environment. ghostty's Exec (ghostty/src/termio/Exec.zig) only exports
//  that variable to surface children when ghostty's OWN process
//  environment already has it, and Calyx never sets it today
//  (architecture.md §3's documented gap) -- so in a Finder/Dock launch
//  the variable is simply absent (the only reason it exists in the
//  current dev session is env inheritance through `open` from a
//  Ghostty-hosted shell, and it then points at /Applications/Ghostty.app's
//  version-mismatched resources, not Calyx's own bundled, version-matched
//  copy at Contents/Resources/ghostty).
//
//  THE FIX: at launch, AppDelegate must set GHOSTTY_RESOURCES_DIR in ITS
//  OWN process environment (so it is inherited by the ghostty engine and,
//  transitively, by every surface it execs) BEFORE
//  GhosttyAppController.shared's very first access anywhere in the app's
//  lifecycle. That first access is applicationDidFinishLaunching itself
//  (AppDelegate.swift:99, `let controller = GhosttyAppController.shared`):
//  main.swift only constructs AppDelegate and calls NSApplication.run(),
//  with no earlier touch (AppSession()/BrowserTabBroker(), AppDelegate's
//  own stored-property initializers, do not reference GhosttyAppController
//  either), and every OTHER GhosttyAppController.shared reference in the
//  codebase (GhosttyThemeProvider, GhosttyAction, CalyxWindowController,
//  SettingsWindowController, QuickTerminalController,
//  SurfaceScrollView) is reached only later, from UI/action callbacks
//  that cannot fire before launch completes. So the new call must be the
//  very first thing applicationDidFinishLaunching does, ahead of even
//  the existing PATH-setenv block at lines 93-97.
//
//  Held-out compile-RED (see SessionCommandSynthesizerRemoteAttachTests's
//  header for this codebase's convention): AppDelegate
//  .applyGhosttyResourcesDirEnvironmentIfNeeded() and the DEBUG-only test
//  seam _ghosttyResourcesRootForTesting do not exist yet, and this file
//  also depends on the sibling RED types GhosttyResourcesDirResolver /
//  GhosttyResourcesDirEnvironment (see GhosttyResourcesDirResolverTests /
//  GhosttyResourcesDirEnvironmentTests, this same round). This file fails
//  to compile until the Green phase adds all three. That compile failure
//  IS this file's RED evidence.
//
//  Proposed API (AppDelegate.swift additions):
//
//    #if DEBUG
//    /// Test seam: overrides the resources root
//    /// applyGhosttyResourcesDirEnvironmentIfNeeded() resolves against,
//    /// instead of Bundle.main.resourceURL. DO NOT use from production code.
//    var _ghosttyResourcesRootForTesting: URL?
//    #endif
//
//    /// Sets GHOSTTY_RESOURCES_DIR in this process's environment to
//    /// Calyx's own bundled ghostty resources directory, if the bundle
//    /// actually contains shell-integration scripts (via
//    /// GhosttyResourcesDirResolver), overwriting any inherited value
//    /// (via GhosttyResourcesDirEnvironment.apply(_:)). Called first
//    /// thing from applicationDidFinishLaunching, before
//    /// GhosttyAppController.shared is ever touched.
//    func applyGhosttyResourcesDirEnvironmentIfNeeded() {
//        let root = _ghosttyResourcesRootForTesting ?? Bundle.main.resourceURL ?? Bundle.main.bundleURL
//        let resolvedPath = GhosttyResourcesDirResolver(resourcesRoot: root).resolve()
//        GhosttyResourcesDirEnvironment.apply(resolvedPath)
//    }
//
//  WHAT THIS FILE CAN AND CANNOT PIN (unit level):
//  Driving applicationDidFinishLaunching for real is not exercisable from
//  this test host -- it reaches GhosttyAppController.shared, a real
//  libghostty engine init, and (on failure paths) blocking
//  NSAlert.runModal() calls; no existing AppDelegate test in this suite
//  drives it, and several neighboring test seams' own doc comments
//  (_attachWindowCreationHookForTesting, _focusWindowForExistingSessionShowHookForTesting)
//  record that reaching real window/surface creation from this test host
//  hangs the XCTest process indefinitely. Exactly like
//  AppDelegateReassertHistoryPersistenceTests's own
//  reassertHistoryPersistenceIfNeeded() precedent (called directly on a
//  bare `AppDelegate()`, bypassing applicationDidFinishLaunching
//  entirely), these tests instead call
//  applyGhosttyResourcesDirEnvironmentIfNeeded() directly, with
//  _ghosttyResourcesRootForTesting standing in for
//  Bundle.main.resourceURL. This CAN pin that the method itself correctly
//  wires GhosttyResourcesDirResolver's result into
//  GhosttyResourcesDirEnvironment.apply(_:), for both a valid and an
//  invalid bundle layout. It CANNOT pin (a) that
//  applicationDidFinishLaunching actually calls this method at all, or
//  (b) that it runs before GhosttyAppController.shared's first access --
//  both are properties of applicationDidFinishLaunching's own body, which
//  has no safe unit-level seam to observe call order against a real
//  singleton access. The Green phase implementer and code review must
//  verify (a)/(b) by reading the diff; no test in this file substitutes
//  for that reading.
//
//  Coverage:
//  - resources root with a valid bundled ghostty/shell-integration:
//    GHOSTTY_RESOURCES_DIR ends up set to that resolved path, overwriting
//    a pre-existing bogus value
//  - resources root WITHOUT shell-integration (e.g. a Debug build that
//    never ran the resource-copy build): a pre-existing
//    GHOSTTY_RESOURCES_DIR value is left completely untouched
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateApplyGhosttyResourcesDirEnvironmentTests: XCTestCase {

    private let variableName = "GHOSTTY_RESOURCES_DIR"
    private var originalValue: String?

    override func setUp() {
        super.setUp()
        originalValue = ProcessInfo.processInfo.environment[variableName]
    }

    override func tearDown() {
        if let originalValue {
            setenv(variableName, originalValue, 1)
        } else {
            unsetenv(variableName)
        }
        super.tearDown()
    }

    private func currentValue() -> String? {
        getenv(variableName).map { String(cString: $0) }
    }

    private func makeTempDir() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDelegateApplyGhosttyResourcesDirEnvironmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let url = raw.resolvingSymlinksInPath()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    @discardableResult
    private func mkdir(_ name: String, under parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - applyGhosttyResourcesDirEnvironmentIfNeeded()

    func test_validBundledShellIntegration_setsResolvedPathOverwritingBogusValue() throws {
        setenv(variableName, "/bogus/inherited/path", 1)
        let root = try makeTempDir()
        let ghosttyDir = try mkdir("ghostty", under: root)
        try mkdir("shell-integration", under: ghosttyDir)

        let appDelegate = AppDelegate()
        appDelegate._ghosttyResourcesRootForTesting = root

        appDelegate.applyGhosttyResourcesDirEnvironmentIfNeeded()

        XCTAssertEqual(
            currentValue(), ghosttyDir.path,
            "with a valid bundled ghostty/shell-integration, launch must set GHOSTTY_RESOURCES_DIR to the bundled path, overwriting any inherited value"
        )
    }

    func test_missingShellIntegration_leavesPreExistingValueUntouched() throws {
        setenv(variableName, "/bogus/inherited/path", 1)
        let root = try makeTempDir()
        try mkdir("ghostty", under: root) // ghostty/ exists but has no shell-integration subdirectory

        let appDelegate = AppDelegate()
        appDelegate._ghosttyResourcesRootForTesting = root

        appDelegate.applyGhosttyResourcesDirEnvironmentIfNeeded()

        XCTAssertEqual(
            currentValue(), "/bogus/inherited/path",
            "when the bundle has no shell-integration, launch must never overwrite (or clear) an already-present GHOSTTY_RESOURCES_DIR value"
        )
    }
}
