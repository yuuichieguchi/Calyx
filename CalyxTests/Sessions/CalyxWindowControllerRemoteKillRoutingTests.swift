//
//  CalyxWindowControllerRemoteKillRoutingTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, BUG 1 (five-angle convergence review
//  finding), contract 1b (controller level): CalyxWindowController
//  .killSessionIfPersistent (~:708-723) never consults SessionRef.host
//  before dispatching its kill through SessionKillTracker.track --
//  closing a remote pane always calls SessionDaemonClient.shared.kill(id:),
//  the LOCAL-only operation, silently orphaning the remote calyx-session
//  forever.
//
//  WHERE HOST LIVES AT KILL TIME: exactly like performReconnect's own
//  identical read (see CalyxWindowControllerRemoteReconnectCommandTests'
//  header), no new storage is needed -- killSessionIfPersistent already
//  has `tab` and `surfaceID` in hand, and `tab.sessionRefs` is keyed by
//  leaf (== surface) UUID. The host must be read from
//  `tab.sessionRefs[surfaceID]?.host` BEFORE this method's own
//  `tab.sessionRefs[surfaceID] = nil` clears the entry two lines later.
//
//  PROPOSED FIX (killSessionIfPersistent):
//
//    private func killSessionIfPersistent(tab: Tab, surfaceID: UUID, isTerminating: Bool) {
//        let sessionID = SessionSurfaceMap.shared.sessionID(for: surfaceID)
//        guard SessionCloseKillPolicy.shouldKill(...), let sessionID else { return }
//        let host = tab.sessionRefs[surfaceID]?.host
//        SessionSurfaceMap.shared.unregister(sessionID: sessionID)
//        tab.sessionRefs[surfaceID] = nil
//        sessionReconnectCoordinator.markClosed(sessionID: sessionID)
//        #if DEBUG
//        _killSessionIfPersistentRouteObserverForTesting?(sessionID, host)
//        #endif
//        SessionKillTracker.track {
//            if let host {
//                await SessionDaemonClient.shared.killRemote(host: host, sessionID: sessionID)
//            } else {
//                await SessionDaemonClient.shared.kill(id: sessionID)
//            }
//        }
//    }
//
//  SessionKillTracker interplay preserved: both branches still dispatch
//  through SessionKillTracker.track exactly as today, so
//  applicationWillTerminate's drain-before-quit behavior is unaffected --
//  only WHICH daemon-client operation gets tracked changes.
//
//  THE MISSING OBSERVATION SEAM: SessionDaemonClient.shared is a real
//  singleton backed by a real (if usually binary-unresolvable in this
//  test host) command runner, so a controller-level test cannot
//  distinguish "kill(id:) was dispatched" from "killRemote(host:sessionID:)
//  was dispatched" by inspecting the daemon client itself. This file adds
//  a new, independent, DEBUG-only observer seam, mirroring
//  _performReconnectCommandObserverForTesting's exact "observe right
//  before the real (tracked, fire-and-forget) work; the real work still
//  runs unmodified" style:
//
//    #if DEBUG
//    extension CalyxWindowController {
//        var _killSessionIfPersistentRouteObserverForTesting: ((String, String?) -> Void)? { get set }
//    }
//    #endif
//
//  Called with (sessionID, host) immediately before the SessionKillTracker
//  .track dispatch above. `host` is `nil` for a local kill, non-nil for a
//  remote kill. `nil` (the default) leaves production behavior unchanged.
//
//  Held-out compile-RED file per this codebase's established convention:
//  neither the observer seam above, nor killSessionIfPersistent's
//  host-routing branch, nor SessionDaemonClient.killRemote(host:sessionID:)
//  (see SessionDaemonClientKillRemoteTests, contract 1a) exist yet.
//  Expected to FAIL TO COMPILE until the Green phase adds them. That
//  compile failure IS this file's RED evidence. Must be excluded from the
//  build while running the rest of the round's RED suite and verified
//  separately for its own specific compiler errors.
//
//  Drives the real session.kill command-palette handler (exactly like
//  SessionCommandPaletteTests) against TwoPaneSessionFixture, now with
//  its purely additive `host:` parameter (TwoPaneSessionFixture.swift):
//  a two-pane, single-tab fixture whose focused/tracked leaf carries the
//  SessionRef under test, with an untracked sibling pane so the tab is
//  never the last pane (dodging the confirm-quit gate entirely).
//
//  Coverage:
//  - A local sessionRef (host == nil) close routes through the
//    observer with host == nil, matching today's kill(id:) behavior
//    (regression guard)
//  - A remote sessionRef (host != nil) close routes through the
//    observer with the given host, proving the remote form -- not the
//    local one -- would be dispatched
//

import XCTest
import AppKit
@testable import Calyx

@MainActor
final class CalyxWindowControllerRemoteKillRoutingTests: XCTestCase {

    private var registeredSessionIDs: [String] = []

    override func tearDown() {
        for sessionID in registeredSessionIDs {
            SessionSurfaceMap.shared.unregister(sessionID: sessionID)
        }
        registeredSessionIDs.removeAll()
        super.tearDown()
    }

    private func command(_ id: String, in controller: CalyxWindowController) throws -> PaletteCommand {
        try XCTUnwrap(
            controller.commandRegistry.allCommands.first(where: { $0.id == id }),
            "setupCommandRegistry must register a '\(id)' command"
        )
    }

    func test_sessionKill_localSessionRef_routesObserverWithNilHost() throws {
        let fixture = makeTwoPaneSessionFixture(host: nil)
        registeredSessionIDs.append(fixture.sessionID)
        var observed: (sessionID: String, host: String?)?
        fixture.controller._killSessionIfPersistentRouteObserverForTesting = { sessionID, host in
            observed = (sessionID, host)
        }

        let killCommand = try command("session.kill", in: fixture.controller)
        killCommand.handler()

        let result = try XCTUnwrap(observed, "killSessionIfPersistent must call the route observer")
        XCTAssertEqual(result.sessionID, fixture.sessionID)
        XCTAssertNil(result.host,
                     "A local SessionRef (host == nil) must route with a nil host, matching today's " +
                     "kill(id:)-only behavior -- regression guard for existing, unchanged behavior")
    }

    func test_sessionKill_remoteSessionRef_routesObserverWithGivenHost() throws {
        let fixture = makeTwoPaneSessionFixture(host: "devbox.example.com")
        registeredSessionIDs.append(fixture.sessionID)
        var observed: (sessionID: String, host: String?)?
        fixture.controller._killSessionIfPersistentRouteObserverForTesting = { sessionID, host in
            observed = (sessionID, host)
        }

        let killCommand = try command("session.kill", in: fixture.controller)
        killCommand.handler()

        let result = try XCTUnwrap(observed, "killSessionIfPersistent must call the route observer")
        XCTAssertEqual(result.sessionID, fixture.sessionID)
        XCTAssertEqual(result.host, "devbox.example.com",
                       "A remote SessionRef (host != nil) must route with that host, proving the fix " +
                       "dispatches killRemote(host:sessionID:), never the LOCAL-only kill(id:) that silently " +
                       "orphans the remote calyx-session today")
    }

    func test_sessionKill_afterClose_sessionSurfaceMapAndTabSessionRefsAreClearedRegardlessOfHost() throws {
        let fixture = makeTwoPaneSessionFixture(host: "devbox.example.com")
        registeredSessionIDs.append(fixture.sessionID)
        fixture.controller._killSessionIfPersistentRouteObserverForTesting = { _, _ in }

        let killCommand = try command("session.kill", in: fixture.controller)
        killCommand.handler()

        XCTAssertNil(SessionSurfaceMap.shared.sessionID(for: fixture.trackedLeafID),
                    "Closing a remote-hosted session must still unregister SessionSurfaceMap exactly like " +
                    "the local path -- only WHICH daemon-client operation gets dispatched changes, not the " +
                    "local bookkeeping")
        XCTAssertNil(fixture.tab.sessionRefs[fixture.trackedLeafID],
                    "...and must still clear tab.sessionRefs, matching the local path's existing contract")
    }
}
