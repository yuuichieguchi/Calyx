//
//  SessionBrowserModelRemoteHostTests.swift
//  CalyxTests
//
//  TDD Red phase, P5 (remote sessions), RED5 cycle (remote UI wiring),
//  contract R4: the session browser's own remote-host attach flow --
//  SessionBrowserModel exposes remote host candidates (via R1's
//  SSHHostCandidateProvider, injected) and, given a chosen host,
//  produces the SAME host-carrying SessionSpawnContext as the palette's
//  session.newRemote command (R2, SessionCommandPaletteNewRemoteTests).
//  Mirrors SessionBrowserModel.attach(_:)'s existing onAttachRequested
//  injectable-closure pattern (SessionBrowserModelTests, P4) rather than
//  driving any real AppKit/SwiftUI picker.
//
//  Held-out compile-RED file per this codebase's established convention:
//  depends on R1's SSHHostCandidateProvider (also new -- see
//  SSHHostCandidateProviderTests), plus remoteHostCandidates /
//  refreshRemoteHostCandidates() / onRemoteSessionRequested /
//  attachToRemoteHost(_:), none of which exist on SessionBrowserModel
//  yet. Expected to FAIL TO COMPILE until the Green phase adds them.
//
//  Coverage:
//  - refreshRemoteHostCandidates() populates remoteHostCandidates from
//    the injected SSHHostCandidateProvider, in its own declaration order
//  - A provider with no readable config yields an empty candidate list
//  - attachToRemoteHost(_:) invokes onRemoteSessionRequested with a
//    SessionSpawnContext carrying the given host and origin == .tab --
//    structurally identical to what
//    CalyxWindowController.remoteSessionSpawnContext(forHost:) (R2)
//    produces for the same host, so both entry points feed the same
//    downstream spawn contract
//

import XCTest
@testable import Calyx

private struct FakeRootResolver: SessionRootResolverProtocol {
    let root: String
    func resolve() -> String { root }
}

/// Minimal SessionDaemonClientProtocol fake -- none of this file's
/// tests exercise daemon interaction at all, so every method is an
/// inert stub. A local duplicate of SessionBrowserModelTests'
/// FakeBrowserDaemonClient shape, narrowed to what this file needs
/// (this codebase's established per-file fixture-duplication
/// convention).
private final class FakeDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}
    func listAll() async -> [SessionInfo] { [] }
    func setMeta(id: String, key: String, value: String) async {}
}

@MainActor
final class SessionBrowserModelRemoteHostTests: XCTestCase {

    private func makeProvider(configText: String?) -> SSHHostCandidateProvider {
        SSHHostCandidateProvider(
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home"),
            loadConfig: { _ in configText }
        )
    }

    // MARK: - refreshRemoteHostCandidates()

    func test_refreshRemoteHostCandidates_populatesFromInjectedProvider() {
        let model = SessionBrowserModel(
            daemonClient: FakeDaemonClient(),
            surfaceMap: SessionSurfaceMap(),
            hostCandidateProvider: makeProvider(configText: "Host devbox\nHost staging\n")
        )

        model.refreshRemoteHostCandidates()

        XCTAssertEqual(model.remoteHostCandidates, ["devbox", "staging"],
                       "refreshRemoteHostCandidates() must populate remoteHostCandidates from the " +
                       "injected SSHHostCandidateProvider's own hostCandidates(), preserving its " +
                       "declaration order")
    }

    func test_refreshRemoteHostCandidates_missingConfig_yieldsEmptyList() {
        let model = SessionBrowserModel(
            daemonClient: FakeDaemonClient(),
            surfaceMap: SessionSurfaceMap(),
            hostCandidateProvider: makeProvider(configText: nil)
        )

        model.refreshRemoteHostCandidates()

        XCTAssertEqual(model.remoteHostCandidates, [],
                       "A provider with no readable ~/.ssh/config must yield an empty candidate list")
    }

    // MARK: - attachToRemoteHost(_:)

    func test_attachToRemoteHost_invokesOnRemoteSessionRequested_withHostCarryingTabOriginContext() {
        let model = SessionBrowserModel(daemonClient: FakeDaemonClient(), surfaceMap: SessionSurfaceMap())
        var requestedContext: SessionSpawnContext?
        model.onRemoteSessionRequested = { requestedContext = $0 }

        model.attachToRemoteHost("devbox.example.com")

        XCTAssertEqual(requestedContext, SessionSpawnContext(host: "devbox.example.com", origin: .tab),
                       "attachToRemoteHost(_:) must invoke onRemoteSessionRequested with a " +
                       "SessionSpawnContext carrying the chosen host and origin == .tab -- structurally " +
                       "identical to what CalyxWindowController.remoteSessionSpawnContext(forHost:) (R2) " +
                       "produces for the same host, so both entry points feed the same downstream spawn " +
                       "contract")
    }
}
