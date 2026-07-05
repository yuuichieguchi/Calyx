//
//  AppDelegateRestoreRemoteSessionTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, contract R2 (COMPILE-RED, HELD-OUT
//  FILE): AppDelegate.createSurfaceWithPwd (the restore-path surface
//  creator, see AppDelegate.swift near :1275) always synthesizes its
//  attach command via SessionCommandSynthesizer.reattachCommand(_:),
//  regardless of SessionRef.host. A restored leaf whose SessionRef
//  carries a non-nil host (a session that was spawned against a remote
//  ssh host, once P5 spawn lands) must instead synthesize
//  SessionCommandSynthesizer.remoteAttachCommand(host:sessionID:cwd:) --
//  ssh, not the local calyx-session binary, no --runtime-dir/--state-dir
//  (those flags are meaningless on the remote machine, see
//  remoteAttachCommand's own doc comment).
//
//  THE MISSING OBSERVATION SEAM: the existing restore-path test seam,
//  AppDelegate._createSurfaceWithPwdHookForTesting ((UUID?) -> UUID?)?,
//  intercepts tab.registry.createSurface(...) itself (via
//  createRegistrySurface) to avoid constructing a real, unsafe ghostty
//  surface -- but it never sees the `command` string that was computed
//  ahead of that call, so a test using it alone cannot tell whether
//  createSurfaceWithPwd chose reattachCommand or remoteAttachCommand for
//  a given leaf. Every existing caller of that hook
//  (AppDelegateRestoreTabSurfacesOwnershipTests,
//  AppDelegateOfferAgentResumePipelineBoundTests) only needs the
//  resulting surfaceID, never the command, so this file adds a second,
//  independent, purely additive observer seam instead of changing that
//  hook's signature (which would force both existing call sites to
//  update their closures for no benefit to them):
//
//    #if DEBUG
//    extension AppDelegate {
//        var _createSurfaceWithPwdCommandObserverForTesting: ((UUID?, String?) -> Void)? { get set }
//    }
//    #endif
//
//  Called with (oldLeafID, command) from inside createSurfaceWithPwd
//  immediately before createRegistrySurface is invoked (both branches:
//  the sessionRef-carrying branch with its local/remote command, and the
//  plain-passthrough branch with command == nil), mirroring
//  _createSurfaceWithPwdOfferAgentResumeCompletedHookForTesting's exact
//  "new, narrow, DEBUG-gated, nil-by-default" shape. `nil` (the default)
//  leaves production behavior unchanged.
//
//  PROPOSED FIX (createSurfaceWithPwd's sessionRef-carrying branch):
//
//    let command: String?
//    if let host = sessionRef.host {
//        command = SessionCommandSynthesizer.remoteAttachCommand(
//            host: host, sessionID: sessionRef.sessionID, cwd: tab.pwd ?? NSHomeDirectory()
//        )
//    } else {
//        command = SessionCommandSynthesizer.reattachCommand(
//            sessionID: sessionRef.sessionID, cwd: tab.pwd ?? NSHomeDirectory()
//        )
//    }
//    _createSurfaceWithPwdCommandObserverForTesting?(oldLeafID, command)
//    guard let command else { <local-binary-unresolvable fallback> }
//
//  remoteAttachCommand never returns nil (SSHBinaryResolver always
//  resolves to a path -- see its own doc comment), so a remote leaf can
//  never hit the "no calyx-session binary resolvable" degrade branch
//  reattachCommand's nil return exists for; only the local branch keeps
//  that guard.
//
//  NONE of `_createSurfaceWithPwdCommandObserverForTesting` or the
//  host-branching logic above exist yet -- this file is expected to FAIL
//  TO COMPILE until the TDD Green phase adds them. That compile failure
//  IS this contract's RED evidence, following this codebase's
//  established held-out-file convention (see
//  SessionReconnectGracePositiveSignalSeamTests's header comment). Must
//  be excluded from the build while running the rest of the round's RED
//  suite (a compile failure anywhere fails the whole CalyxTests target,
//  since Swift compiles a target as one module) and verified separately
//  for its own specific compiler errors.
//
//  Reuses AppDelegateRestoreTabSurfacesOwnershipTests' exact
//  drive-the-real-restoreTabSurfaces-with-a-faked-surface-creation-hook
//  approach (dummyApp, makeWindow(), _createSurfaceWithPwdHookForTesting)
//  -- everything except the new observer is real, unmodified production
//  code.
//
//  Coverage:
//  - A local SessionRef (host == nil) restore still synthesizes
//    reattachCommand (regression guard: the CALYX_SESSION_BIN env
//    sentinel appears, --runtime-dir/--state-dir present, no ssh
//    sentinel anywhere).
//  - A remote SessionRef (host != nil) restore synthesizes
//    remoteAttachCommand instead: the ssh env sentinel is the command's
//    own first word, no --runtime-dir/--state-dir anywhere, and the
//    local calyx-session env sentinel never appears at all.
//

import XCTest
import GhosttyKit
@testable import Calyx

@MainActor
final class AppDelegateRestoreRemoteSessionTests: XCTestCase {

    /// Well-formed 26-character Crockford base32 ULIDs (see
    /// SessionRef.isValidULID) -- required for restoreTabSurfaces to
    /// keep these sessionRefs at all rather than silently stripping them
    /// as corrupt before createSurfaceWithPwd ever runs.
    private let localSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    private let remoteSessionID = "01BX5ZZKBKACTAV9WEVGEMMVRZ"

    /// Never dereferenced: every call this test drives through
    /// createSurfaceWithPwd is intercepted by
    /// _createSurfaceWithPwdHookForTesting before the real ghostty FFI
    /// call that would otherwise use this value.
    private let dummyApp: ghostty_app_t = UnsafeMutableRawPointer(bitPattern: 1)!

    private func makeWindow() -> NSWindow {
        CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    /// Distinguishable sentinel paths (never actually executed --
    /// _createSurfaceWithPwdHookForTesting intercepts surface creation
    /// before any command string is ever run) standing in for the local
    /// calyx-session binary and the ssh binary, so the two synthesized
    /// commands can never be confused with one another by coincidence.
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

    func test_restoreTabSurfaces_localSessionRef_synthesizesReattachCommand_notSSH() throws {
        let localBin = "/tmp/calyx-session-sentinel-\(UUID().uuidString)"
        let sshBin = "/tmp/ssh-sentinel-\(UUID().uuidString)"

        try withBinarySentinels(local: localBin, ssh: sshBin) {
            let appDelegate = AppDelegate()
            let leafID = UUID()
            let newSurfaceID = UUID()
            var observedCommand: String??

            appDelegate._createSurfaceWithPwdHookForTesting = { _ in newSurfaceID }
            appDelegate._createSurfaceWithPwdCommandObserverForTesting = { oldLeafID, command in
                if oldLeafID == leafID { observedCommand = command }
            }

            let tab = Tab(
                splitTree: SplitTree(leafID: leafID),
                sessionRefs: [leafID: SessionRef(sessionID: localSessionID, host: nil)]
            )
            let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())
            defer { SessionSurfaceMap.shared.unregister(sessionID: localSessionID) }

            XCTAssertTrue(restored, "Precondition: the single-leaf restore must fully succeed")
            let command = try XCTUnwrap(observedCommand ?? nil,
                                        "A leaf whose SessionRef has host == nil must still synthesize a command")
            // "'" + localBin, not localBin alone: SessionCommandSynthesizer.shSafeToken
            // unconditionally single-quotes every token, including the binary path itself
            // (see its own doc comment), so the command's first word is always quoted.
            XCTAssertTrue(command.hasPrefix("'\(localBin)"),
                          "A local SessionRef (host == nil) must synthesize reattachCommand, whose first word " +
                          "is the local calyx-session binary -- regression guard for existing, unchanged behavior")
            XCTAssertTrue(command.contains("--runtime-dir"),
                          "The local reattach command must still carry --runtime-dir")
            XCTAssertFalse(command.contains(sshBin),
                           "A local restore must never invoke ssh at all")
        }
    }

    func test_restoreTabSurfaces_remoteSessionRef_synthesizesSSHCommand_notLocalReattach() throws {
        let localBin = "/tmp/calyx-session-sentinel-\(UUID().uuidString)"
        let sshBin = "/tmp/ssh-sentinel-\(UUID().uuidString)"

        try withBinarySentinels(local: localBin, ssh: sshBin) {
            let appDelegate = AppDelegate()
            let leafID = UUID()
            let newSurfaceID = UUID()
            var observedCommand: String??

            appDelegate._createSurfaceWithPwdHookForTesting = { _ in newSurfaceID }
            appDelegate._createSurfaceWithPwdCommandObserverForTesting = { oldLeafID, command in
                if oldLeafID == leafID { observedCommand = command }
            }

            let tab = Tab(
                splitTree: SplitTree(leafID: leafID),
                sessionRefs: [leafID: SessionRef(sessionID: remoteSessionID, host: "devbox.example.com")]
            )
            let restored = appDelegate.restoreTabSurfaces(tab: tab, app: dummyApp, window: makeWindow())
            defer { SessionSurfaceMap.shared.unregister(sessionID: remoteSessionID) }

            XCTAssertTrue(restored, "Precondition: the single-leaf restore must fully succeed")
            let command = try XCTUnwrap(observedCommand ?? nil,
                                        "A leaf whose SessionRef has host != nil must still synthesize a " +
                                        "command -- remoteAttachCommand never returns nil, unlike reattachCommand")
            // "'" + sshBin: same shSafeToken unconditional-quoting note as the local test above.
            XCTAssertTrue(command.hasPrefix("'\(sshBin)"),
                          "A remote SessionRef (host != nil) must synthesize remoteAttachCommand, whose first " +
                          "word is the ssh binary, never the local calyx-session binary")
            XCTAssertFalse(command.contains(localBin),
                           "A remote restore must never invoke the local calyx-session binary directly")
            XCTAssertFalse(command.contains("--runtime-dir"),
                           "A remote command must never carry the local --runtime-dir flag -- meaningless on the remote machine")
            XCTAssertFalse(command.contains("--state-dir"),
                           "A remote command must never carry the local --state-dir flag -- meaningless on the remote machine")
        }
    }
}
