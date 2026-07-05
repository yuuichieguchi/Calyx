//
//  CalyxWindowControllerCreateManagedSurfaceRemoteHostTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, BUG 3 (five-angle convergence review
//  finding), contract 3b (controller level): CalyxWindowController
//  .createManagedSurface (~647-669) builds its SessionSpawnContext with
//  no `host` at all, and its `.persistent` branch always constructs
//  `SessionRef(sessionID: sessionID)` -- host always nil, regardless of
//  whatever plan it just received. Combined with contract 3a's fix
//  (SpawnPlan.persistent carrying host), createManagedSurface must
//  actually thread that host through into the SessionRef it stores.
//
//  FIX CONTRACT: createManagedSurface gains a `host: String? = nil`
//  parameter (default preserves every one of its 4 existing call sites --
//  setupTerminalSurface, createNewTab, createNewGroup, and the split
//  handler -- unchanged, all still local). Passes `host` into the
//  SessionSpawnContext it builds, and reads the plan's own `host` (not
//  its own parameter directly -- see SessionSpawnPlannerHostPropagationTests,
//  contract 3a, for why the plan itself is the source of truth) when
//  constructing SessionRef.
//
//  PROPOSED FIX (createManagedSurface):
//
//    private func createManagedSurface(
//        tab: Tab, app: ghostty_app_t, config: ghostty_surface_config_s,
//        passthroughPwd: String?, spawnCwd: String, inheritedCwd: String? = nil,
//        origin: SessionSpawnOrigin, host: String? = nil
//    ) -> UUID? {
//        let context = SessionSpawnContext(cwd: spawnCwd, inheritedCwd: inheritedCwd, host: host, origin: origin)
//        switch SessionSpawnPlanner.plan(for: context) {
//        case .passthrough:
//            #if DEBUG
//            if let hook = _createManagedSurfaceHookForTesting { return hook() }
//            #endif
//            return tab.registry.createSurface(app: app, config: config, pwd: passthroughPwd)
//        case .persistent(let sessionID, let command, let planHost):
//            let ghosttyPwd = inheritedCwd ?? spawnCwd
//            #if DEBUG
//            if let hook = _createManagedSurfaceHookForTesting {
//                guard let surfaceID = hook() else { return nil }
//                tab.sessionRefs[surfaceID] = SessionRef(sessionID: sessionID, host: planHost)
//                SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: surfaceID)
//                return surfaceID
//            }
//            #endif
//            guard let surfaceID = tab.registry.createSurface(app: app, config: config, pwd: ghosttyPwd, command: command) else {
//                return nil
//            }
//            tab.sessionRefs[surfaceID] = SessionRef(sessionID: sessionID, host: planHost)
//            SessionSurfaceMap.shared.register(sessionID: sessionID, surfaceID: surfaceID)
//            return surfaceID
//        }
//    }
//
//  NOT `private` any more (mirrors closeAllTabsInGroup(id:)/
//  processChildExited/handleSessionReconnectDecision's own identical
//  "un-privated for direct test access" precedent): this file drives it
//  directly with a dummy ghostty_app_t pointer, exactly like
//  AppDelegateRestoreRemoteSessionTests drives restoreTabSurfaces.
//
//  THE MISSING OBSERVATION/SAFETY SEAM: unlike restoreTabSurfaces/
//  performReconnect (which already have their own hook seams from prior
//  P5 rounds), createManagedSurface has NONE -- it calls
//  tab.registry.createSurface(...) (real ghostty FFI, confirmed unsafe to
//  construct in this test host, see AppDelegateAttachWindowTests' header)
//  directly and unconditionally. This file adds a new DEBUG-only hook,
//  mirroring _createSurfaceWithPwdHookForTesting's/
//  _performReconnectSurfaceCreationHookForTesting's exact
//  intercept-right-before-the-unsafe-FFI-call style:
//
//    #if DEBUG
//    extension CalyxWindowController {
//        var _createManagedSurfaceHookForTesting: (() -> UUID?)? { get set }
//    }
//    #endif
//
//  `nil` (the default) leaves production behavior unchanged: every guard/
//  step around this call, including the sessionRefs/SessionSurfaceMap
//  bookkeeping under test here, remains real, unmodified production code.
//
//  Held-out compile-RED file per this codebase's established convention:
//  neither `createManagedSurface`'s `host` parameter, its un-privated
//  visibility, nor `_createManagedSurfaceHookForTesting` exist yet --
//  and it depends on contract 3a's `SpawnPlan.persistent` host element
//  too. Expected to FAIL TO COMPILE until the Green phase adds all of
//  the above. That compile failure IS this file's RED evidence. Must be
//  excluded from the build while running the rest of the round's RED
//  suite and verified separately for its own specific compiler errors.
//
//  Coverage:
//  - createManagedSurface(..., host: "devbox.example.com", ...) with a
//    .tab origin creates a sessionRefs entry whose host equals exactly
//    the given host
//  - createManagedSurface(..., host: nil, ...) (every existing call
//    site's shape) still creates a sessionRefs entry with host == nil --
//    regression guard
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerCreateManagedSurfaceRemoteHostTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.CalyxWindowControllerCreateManagedSurfaceRemoteHostTests"

    /// Never dereferenced: _createManagedSurfaceHookForTesting intercepts
    /// every call this test drives through createManagedSurface before
    /// the real ghostty FFI call that would otherwise use this value --
    /// mirrors AppDelegateRestoreRemoteSessionTests' identical dummyApp.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
        SessionSettings.persistentSessionsEnabled = true
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    private func makeController() -> CalyxWindowController {
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let tab = Tab(title: "Shell")
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        return CalyxWindowController(window: window, windowSession: session, restoring: true)
    }

    func test_createManagedSurface_remoteHost_sessionRefsEntryCarriesGivenHost() throws {
        let controller = makeController()
        let tab = Tab()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }

        let surfaceID = controller.createManagedSurface(
            tab: tab, app: dummyApp, config: GhosttyFFI.surfaceConfigNew(),
            passthroughPwd: nil, spawnCwd: "/home/dev/repo", origin: .tab, host: "devbox.example.com"
        )
        defer {
            if let sessionID = surfaceID.flatMap({ tab.sessionRefs[$0]?.sessionID }) {
                SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            }
        }

        let createdID = try XCTUnwrap(surfaceID, "A remote spawn plan must still produce a created surface")
        XCTAssertEqual(createdID, newSurfaceID)
        XCTAssertEqual(tab.sessionRefs[createdID]?.host, "devbox.example.com",
                       "The sessionRefs entry created for a remote-host spawn must carry exactly that host, " +
                       "not silently drop it to nil")
    }

    func test_createManagedSurface_localHost_sessionRefsEntryCarriesNilHost() throws {
        let controller = makeController()
        let tab = Tab()
        let newSurfaceID = UUID()
        controller._createManagedSurfaceHookForTesting = { newSurfaceID }

        let surfaceID = controller.createManagedSurface(
            tab: tab, app: dummyApp, config: GhosttyFFI.surfaceConfigNew(),
            passthroughPwd: nil, spawnCwd: "/home/dev/repo", origin: .tab
        )
        defer {
            if let sessionID = surfaceID.flatMap({ tab.sessionRefs[$0]?.sessionID }) {
                SessionSurfaceMap.shared.unregister(sessionID: sessionID)
            }
        }

        let createdID = try XCTUnwrap(surfaceID, "A local spawn plan must still produce a created surface")
        XCTAssertNil(tab.sessionRefs[createdID]?.host,
                     "Every existing call site (host defaulting to nil) must still create a sessionRefs " +
                     "entry with host == nil -- regression guard for unchanged local-spawn behavior")
    }
}
