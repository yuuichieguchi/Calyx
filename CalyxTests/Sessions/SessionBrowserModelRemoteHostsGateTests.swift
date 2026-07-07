//
//  SessionBrowserModelRemoteHostsGateTests.swift
//  CalyxTests
//
//  TDD Red phase (session-UI defect review, DEFECT 2, HIGH priority):
//  the session browser's Remote Hosts section renders (and its own
//  "Attach" button stays enabled) whenever SSH config yields ANY host
//  candidate at all, with NO dependency on
//  SessionSettings.persistentSessionsEnabled --
//  SessionBrowserView.swift's `if !model.remoteHostCandidates.isEmpty`
//  gate never checks the flag, and
//  SessionBrowserWindowController.showBrowser() calls
//  model.refreshRemoteHostCandidates() unconditionally too. Since
//  SessionSpawnPlanner.plan(for:) silently downgrades a host-carrying
//  SessionSpawnContext to `.passthrough` (a PLAIN LOCAL shell, the host
//  discarded entirely) whenever persistentSessionsEnabled is false
//  (SessionSpawnPlanner.swift's own guard, "guard
//  SessionSettings.persistentSessionsEnabled, context.origin !=
//  .quickTerminal"), clicking "Attach" against a listed remote host
//  while the feature is off does not fail loudly or do nothing -- it
//  silently opens an unrelated LOCAL shell that has nothing to do with
//  the host the user just clicked.
//
//  PRECEDENT THIS MIRRORS (investigated, not assumed -- same one
//  SessionCommandPaletteNewRemoteTests's own header cites): the actual
//  existing precedent for gating NEW-remote-session UI surface on this
//  exact flag is `session.newRemote`'s own `isAvailable`
//  (CalyxWindowController's command-palette registration,
//  SessionCommandPaletteNewRemoteTests, already green) -- mirroring
//  SessionSpawnPlanner.plan(for:)'s own gate one layer down. This file
//  applies the identical gate to the session browser's own remote-host
//  UI surface.
//
//  FIX CONTRACT:
//  - refreshRemoteHostCandidates() must never populate
//    remoteHostCandidates from the injected SSHHostCandidateProvider
//    while persistentSessionsEnabled is false, regardless of what the
//    provider itself would return
//  - a new `showRemoteHostsSection` derived property gates the view's
//    section independent of whatever populated remoteHostCandidates,
//    so a STALE non-empty remoteHostCandidates left over from an
//    earlier refresh (taken while the setting was still on) can never
//    make the section render again the instant the user flips the
//    setting off, before any intervening refresh clears it out
//
//  Held-out compile-RED: `showRemoteHostsSection` does not exist on
//  SessionBrowserModel yet. This file fails to compile until the Green
//  phase adds it. refreshRemoteHostCandidates()'s OWN gating is
//  runtime-RED (the method and remoteHostCandidates already exist, see
//  SessionBrowserModelRemoteHostTests) -- an assertion failure against
//  today's ungated implementation, not a compile failure.
//
//  OUT OF SCOPE (per this cycle's handoff): SessionSpawnPlanner.plan(for:)'s
//  own host!=nil + persistentSessionsEnabled==false behavior is left
//  as-is -- the primary fix is the UI-level gate pinned here, which
//  (once landed) means the UI never actually reaches that planner case
//  with a host set while the flag is off in the first place.
//
//  Coverage:
//  - refreshRemoteHostCandidates(), persistentSessionsEnabled == false:
//    remoteHostCandidates stays empty even though the injected provider
//    has real hosts to offer
//  - refreshRemoteHostCandidates(), persistentSessionsEnabled == true:
//    regression guard -- candidates populate exactly as
//    SessionBrowserModelRemoteHostTests already established
//  - showRemoteHostsSection: false when persistentSessionsEnabled is
//    false, even with a non-empty remoteHostCandidates left over from
//    an earlier refresh; true only when the setting is on AND
//    candidates are non-empty; false when the setting is on but there
//    are no candidates (nothing to show)
//

import XCTest
@testable import Calyx

private struct FakeRootResolver: SessionRootResolverProtocol {
    let root: String
    func resolve() -> String { root }
}

/// Minimal SessionDaemonClientProtocol fake -- none of this file's
/// tests exercise daemon interaction at all. A local duplicate of
/// SessionBrowserModelTests'/SessionBrowserModelRemoteHostTests' own
/// fake shape (this codebase's established per-file
/// fixture-duplication convention), narrowed to inert stubs.
private final class FakeDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}
    func listAll() async -> [SessionInfo] { [] }
    func setMeta(id: String, key: String, value: String) async {}
}

@MainActor
final class SessionBrowserModelRemoteHostsGateTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.SessionBrowserModelRemoteHostsGateTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    private func makeModel(configText: String?) -> SessionBrowserModel {
        let provider = SSHHostCandidateProvider(
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home"),
            loadConfig: { _ in configText }
        )
        return SessionBrowserModel(
            daemonClient: FakeDaemonClient(), surfaceMap: SessionSurfaceMap(), hostCandidateProvider: provider
        )
    }

    // MARK: - refreshRemoteHostCandidates() gating

    func test_refreshRemoteHostCandidates_persistentSessionsDisabled_staysEmpty_evenWithRealHostsAvailable() {
        SessionSettings.persistentSessionsEnabled = false
        let model = makeModel(configText: "Host devbox\nHost staging\n")

        model.refreshRemoteHostCandidates()

        XCTAssertEqual(
            model.remoteHostCandidates, [],
            "With persistent sessions disabled, refreshRemoteHostCandidates() must never populate " +
            "remoteHostCandidates -- SessionSpawnPlanner.plan(for:) silently downgrades any host-carrying " +
            "spawn to a local .passthrough while this flag is off, so offering a remote host to attach to " +
            "here would be a silent lie about what \"Attach\" is about to do"
        )
    }

    func test_refreshRemoteHostCandidates_persistentSessionsEnabled_populatesNormally() {
        SessionSettings.persistentSessionsEnabled = true
        let model = makeModel(configText: "Host devbox\nHost staging\n")

        model.refreshRemoteHostCandidates()

        XCTAssertEqual(
            model.remoteHostCandidates, ["devbox", "staging"],
            "Regression guard: with persistent sessions enabled, refreshRemoteHostCandidates() must " +
            "populate exactly as it already does today (SessionBrowserModelRemoteHostTests) -- the gate must " +
            "not break the legitimate case"
        )
    }

    // MARK: - showRemoteHostsSection derivation

    func test_showRemoteHostsSection_falseWhenPersistentSessionsDisabled_evenWithStaleNonEmptyCandidates() {
        SessionSettings.persistentSessionsEnabled = true
        let model = makeModel(configText: "Host devbox\n")
        model.refreshRemoteHostCandidates()
        XCTAssertEqual(
            model.remoteHostCandidates, ["devbox"],
            "precondition: a stale non-empty candidate list from an earlier refresh while the setting was on"
        )

        SessionSettings.persistentSessionsEnabled = false

        XCTAssertFalse(
            model.showRemoteHostsSection,
            "Flipping the setting off must hide the Remote Hosts section immediately, even before the next " +
            "refresh clears out a stale non-empty remoteHostCandidates left over from when the setting was " +
            "still on"
        )
    }

    func test_showRemoteHostsSection_trueWhenEnabledWithCandidates() {
        SessionSettings.persistentSessionsEnabled = true
        let model = makeModel(configText: "Host devbox\n")
        model.refreshRemoteHostCandidates()

        XCTAssertTrue(
            model.showRemoteHostsSection,
            "The section must show once persistent sessions are enabled and there is at least one candidate host"
        )
    }

    func test_showRemoteHostsSection_falseWhenEnabledButNoCandidates() {
        SessionSettings.persistentSessionsEnabled = true
        let model = makeModel(configText: nil)
        model.refreshRemoteHostCandidates()

        XCTAssertFalse(
            model.showRemoteHostsSection,
            "With nothing to attach to, the section must not show even though the setting itself is on"
        )
    }
}
