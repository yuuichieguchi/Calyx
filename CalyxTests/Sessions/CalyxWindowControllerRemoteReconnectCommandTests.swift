//
//  CalyxWindowControllerRemoteReconnectCommandTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, contract R3 (COMPILE-RED, HELD-OUT
//  FILE): CalyxWindowController.performReconnect(oldSurfaceID:sessionID:)
//  (CalyxWindowController.swift near :2378) always synthesizes its
//  replacement-surface command via
//  SessionCommandSynthesizer.reattachCommand(sessionID:cwd:), with no
//  awareness of whether the disconnected surface belonged to a remote
//  session at all. A reconnect for a remote surface (its leaf's
//  SessionRef.host != nil) must instead synthesize
//  SessionCommandSynthesizer.remoteAttachCommand(host:sessionID:cwd:).
//
//  WHERE HOST LIVES AT RECONNECT TIME (investigation finding): no new
//  storage is needed. `performReconnect` already has `tab` in hand
//  (`findTab(surfaceID: oldSurfaceID)`), and `tab.sessionRefs` is keyed
//  by leaf (== surface) UUID -- the exact same convention
//  AppDelegate.restoreTabSurfaces/createSurfaceWithPwd already rely on
//  (see AppDelegateRestoreRemoteSessionTests). `tab.sessionRefs[oldSurfaceID]?.host`,
//  read BEFORE the leaf-remap/replaceSurface calls overwrite the old key,
//  is the smallest possible source of truth: SessionSurfaceMap only ever
//  tracks sessionID<->surfaceID, never host, and adding host there would
//  duplicate data already sitting in tab.sessionRefs for no benefit.
//
//  THE MISSING OBSERVATION SEAM: exactly like AppDelegate's identical gap
//  (see AppDelegateRestoreRemoteSessionTests's header comment for the
//  full reasoning), the existing
//  _performReconnectSurfaceCreationHookForTesting: (() -> UUID?)? seam
//  intercepts tab.registry.createSurface(...) itself (via
//  createReconnectSurface) but never sees the `command` string computed
//  ahead of that call. This file adds a second, independent, purely
//  additive observer instead of changing that hook's signature (which
//  would force SessionReconnectAttemptResetTimingTests and
//  SessionReconnectGracePositiveSignalSeamTests to update their closures
//  for no benefit to them):
//
//    #if DEBUG
//    extension CalyxWindowController {
//        var _performReconnectCommandObserverForTesting: ((String?) -> Void)? { get set }
//    }
//    #endif
//
//  Called with the synthesized `command` from inside performReconnect,
//  immediately after it is computed and before createReconnectSurface is
//  invoked. `nil` (the default) leaves production behavior unchanged.
//
//  PROPOSED FIX (performReconnect, replacing its single reattachCommand
//  guard):
//
//    let host = tab.sessionRefs[oldSurfaceID]?.host
//    let command: String
//    if let host {
//        command = SessionCommandSynthesizer.remoteAttachCommand(
//            host: host, sessionID: sessionID, cwd: tab.pwd ?? NSHomeDirectory()
//        )
//    } else {
//        guard let localCommand = SessionCommandSynthesizer.reattachCommand(
//            sessionID: sessionID, cwd: tab.pwd ?? NSHomeDirectory()
//        ) else {
//            logger.error("No calyx-session binary resolvable; cannot reconnect session \(sessionID, privacy: .public)")
//            return
//        }
//        command = localCommand
//    }
//    _performReconnectCommandObserverForTesting?(command)
//
//  remoteAttachCommand never returns nil (see
//  AppDelegateRestoreRemoteSessionTests's identical note), so only the
//  local branch keeps the "no binary resolvable" early-return.
//
//  NONE of `_performReconnectCommandObserverForTesting` or the
//  host-branching logic above exist yet -- this file is expected to FAIL
//  TO COMPILE until the TDD Green phase adds them. That compile failure
//  IS this contract's RED evidence, following this codebase's
//  established held-out-file convention (see
//  SessionReconnectGracePositiveSignalSeamTests's header comment). Must
//  be excluded from the build while running the rest of the round's RED
//  suite and verified separately for its own specific compiler errors.
//
//  Reuses SessionReconnectAttemptResetTimingTests' exact fixture/seam
//  approach (makeReconnectFixture (now with an added, purely additive
//  `host:` parameter -- ReconnectFixture.swift), pumpRunLoop,
//  _performReconnectSurfaceCreationHookForTesting, the CALYX_SESSION_BIN/
//  CALYX_SSH_BIN env sentinel convention from
//  AppDelegateRestoreRemoteSessionTests) -- everything except the new
//  observer is real, unmodified production code.
//
//  Coverage:
//  - A local reconnect (fixture host == nil) still synthesizes
//    reattachCommand (regression guard: local sentinel present,
//    --runtime-dir present, ssh sentinel absent).
//  - A remote reconnect (fixture host != nil) synthesizes
//    remoteAttachCommand instead: ssh sentinel is the command's own
//    first word, no --runtime-dir/--state-dir, local sentinel never
//    appears.
//

import XCTest
import AppKit
import GhosttyKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerRemoteReconnectCommandTests: XCTestCase {

    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    private func withBinarySentinels(
        local: String, ssh: String, _ body: () throws -> Void
    ) rethrows {
        let originalLocal = ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"]
        let originalSSH = ProcessInfo.processInfo.environment["CALYX_SSH_BIN"]
        setenv("CALYX_SESSION_BIN", local, 1)
        setenv("CALYX_SSH_BIN", ssh, 1)
        defer {
            if let originalLocal { setenv("CALYX_SESSION_BIN", originalLocal, 1) } else { unsetenv("CALYX_SESSION_BIN") }
            if let originalSSH { setenv("CALYX_SSH_BIN", originalSSH, 1) } else { unsetenv("CALYX_SSH_BIN") }
        }
        try body()
    }

    func test_performReconnect_localSession_synthesizesReattachCommand_notSSH() throws {
        let localBin = "/tmp/calyx-session-sentinel-\(UUID().uuidString)"
        let sshBin = "/tmp/ssh-sentinel-\(UUID().uuidString)"

        try withBinarySentinels(local: localBin, ssh: sshBin) {
            let fixture = makeReconnectFixture(host: nil)
            registeredSessionIDs.append(fixture.sessionID)

            var observedCommand: String?
            fixture.controller._performReconnectCommandObserverForTesting = { observedCommand = $0 }
            let newSurfaceID = UUID()
            fixture.tab.registry._testInsert(view: SurfaceView(frame: .zero), id: newSurfaceID)
            fixture.controller._performReconnectSurfaceCreationHookForTesting = { newSurfaceID }

            fixture.controller.handleSessionReconnectDecision(
                surfaceID: fixture.trackedLeafID,
                decision: .reconnect(sessionID: fixture.sessionID, attempt: 1)
            )
            pumpRunLoop(timeout: 1.0) { fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID) }

            let command = try XCTUnwrap(observedCommand, "A local reconnect must still synthesize a command")
            // "'" + localBin, not localBin alone: SessionCommandSynthesizer.shSafeToken
            // unconditionally single-quotes every token, including the binary path itself
            // (see its own doc comment), so the command's first word is always quoted.
            XCTAssertTrue(command.hasPrefix("'\(localBin)"),
                          "A local reconnect (SessionRef.host == nil) must synthesize reattachCommand -- " +
                          "regression guard for existing, unchanged behavior")
            XCTAssertTrue(command.contains("--runtime-dir"), "The local reattach command must still carry --runtime-dir")
            XCTAssertFalse(command.contains(sshBin), "A local reconnect must never invoke ssh at all")
        }
    }

    func test_performReconnect_remoteSession_synthesizesSSHCommand_notLocalReattach() throws {
        let localBin = "/tmp/calyx-session-sentinel-\(UUID().uuidString)"
        let sshBin = "/tmp/ssh-sentinel-\(UUID().uuidString)"

        try withBinarySentinels(local: localBin, ssh: sshBin) {
            let fixture = makeReconnectFixture(host: "devbox.example.com")
            registeredSessionIDs.append(fixture.sessionID)

            var observedCommand: String?
            fixture.controller._performReconnectCommandObserverForTesting = { observedCommand = $0 }
            let newSurfaceID = UUID()
            fixture.tab.registry._testInsert(view: SurfaceView(frame: .zero), id: newSurfaceID)
            fixture.controller._performReconnectSurfaceCreationHookForTesting = { newSurfaceID }

            fixture.controller.handleSessionReconnectDecision(
                surfaceID: fixture.trackedLeafID,
                decision: .reconnect(sessionID: fixture.sessionID, attempt: 1)
            )
            pumpRunLoop(timeout: 1.0) { fixture.tab.splitTree.allLeafIDs().contains(newSurfaceID) }

            let command = try XCTUnwrap(observedCommand,
                                        "A remote reconnect must still synthesize a command -- " +
                                        "remoteAttachCommand never returns nil")
            // "'" + sshBin: same shSafeToken unconditional-quoting note as the local test above.
            XCTAssertTrue(command.hasPrefix("'\(sshBin)"),
                          "A remote reconnect (SessionRef.host != nil) must synthesize remoteAttachCommand, " +
                          "whose first word is the ssh binary, never the local calyx-session binary")
            XCTAssertFalse(command.contains(localBin), "A remote reconnect must never invoke the local calyx-session binary directly")
            XCTAssertFalse(command.contains("--runtime-dir"), "A remote command must never carry --runtime-dir")
            XCTAssertFalse(command.contains("--state-dir"), "A remote command must never carry --state-dir")
        }
    }
}
