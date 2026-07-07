//
//  SessionBrowserModelRemoteInstallStatusTests.swift
//  CalyxTests
//
//  TDD Red phase (session-UI defect review, DEFECT 3, MEDIUM priority):
//  SessionBrowserView.swift's Install button
//  (`Button("Install") { Task { await model.installRemote(host: host) } }`,
//  ~line 108) discards installRemote(host:)'s `CommandResult?` entirely.
//  A failed remote install (bad SSH auth, unreachable host, the CLI's
//  own MissingPayload fail-fast) gives the user NO feedback at all --
//  the button just... does nothing visible, indistinguishable from a
//  real success.
//
//  FIX CONTRACT: SessionBrowserModel exposes a per-host install status
//  (idle -> installing -> succeeded/failed) the row can render,
//  mirroring `isRefreshing`'s existing in-flight-flag precedent
//  (SessionBrowserModel.refresh()) but keyed PER HOST, since different
//  hosts' installs are independent of each other.
//  installRemote(host:) itself keeps returning the daemonClient's raw
//  `CommandResult?` unchanged (SessionRemoteInstallTests' existing
//  forwarding contract, still green) -- this file's fix ADDS a status
//  side effect around that same call, it does not change its return
//  value or signature.
//
//  Held-out compile-RED: `RemoteInstallStatus`,
//  `installStatus(forHost:)` do not exist on SessionBrowserModel yet.
//  This file fails to compile until the Green phase adds them.
//
//  Proposed API (SessionBrowserModel.swift addition):
//
//    enum RemoteInstallStatus: Equatable, Sendable {
//        case idle
//        case installing
//        case succeeded
//        case failed(String?)  // the failing CommandResult's stderr, nil when installRemote returned nil
//    }
//
//    private(set) var remoteInstallStatuses: [String: RemoteInstallStatus] = [:]
//
//    func installStatus(forHost host: String) -> RemoteInstallStatus {
//        remoteInstallStatuses[host] ?? .idle
//    }
//
//    func installRemote(host: String) async -> CommandResult? {
//        remoteInstallStatuses[host] = .installing
//        let result = await daemonClient.installRemote(host: host)
//        if let result, result.exitCode == 0 {
//            remoteInstallStatuses[host] = .succeeded
//        } else {
//            remoteInstallStatuses[host] = .failed(result?.stderr)
//        }
//        return result
//    }
//
//  Coverage:
//  - Before any install attempt: installStatus(forHost:) reports .idle
//  - While installRemote(host:)'s daemon round-trip is in flight:
//    .installing -- observed via a suspending fake daemon client this
//    test resumes explicitly, mirroring
//    SessionBrowserModelRefreshCancellationGuardTests' own
//    SuspendingSessionDaemonClient idiom (duplicated per-file per this
//    codebase's established fixture convention) -- no wall-clock sleep
//  - installRemote(host:) resolves with exitCode == 0: .succeeded
//  - installRemote(host:) resolves with a non-zero exitCode: .failed,
//    carrying the result's stderr
//  - installRemote(host:) resolves with nil (SessionRemoteInstallTests'
//    existing no-local-binary-resolvable case): .failed(nil), not left
//    at .idle or .installing forever
//  - Two different hosts' statuses are independent of each other
//

import XCTest
@testable import Calyx

/// Suspends every `installRemote(host:)` call on a continuation this
/// test resumes explicitly via `resume(host:with:)` -- mirrors
/// SessionBrowserModelRefreshCancellationGuardTests'
/// SuspendingSessionDaemonClient idiom, keyed per-host since this
/// file's own contract is that different hosts' installs are
/// independent. Lets the assertion control exactly when (and with what
/// result) each in-flight install resolves, so the .installing
/// intermediate state is observable with no wall-clock timing
/// dependency.
private final class SuspendingInstallDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingContinuations: [String: CheckedContinuation<CommandResult?, Never>] = [:]

    var pendingHosts: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(pendingContinuations.keys)
    }

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}
    func listAll() async -> [SessionInfo] { [] }
    func setMeta(id: String, key: String, value: String) async {}

    func installRemote(host: String) async -> CommandResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CommandResult?, Never>) in
            self.lock.lock()
            self.pendingContinuations[host] = continuation
            self.lock.unlock()
        }
    }

    func resume(host: String, with result: CommandResult?) {
        lock.lock()
        let continuation = pendingContinuations.removeValue(forKey: host)
        lock.unlock()
        continuation?.resume(returning: result)
    }
}

/// Immediately resolves installRemote(host:) with a fixed canned
/// result -- for the succeeded/failed/nil terminal-state cases, which
/// don't need to observe the .installing intermediate state.
private final class FixedInstallResultDaemonClient: SessionDaemonClientProtocol, @unchecked Sendable {
    var result: CommandResult?

    func sessionState(id: String) async -> SessionQueryResult { .unreachable }
    func kill(id: String) async {}
    func listAll() async -> [SessionInfo] { [] }
    func setMeta(id: String, key: String, value: String) async {}
    func installRemote(host: String) async -> CommandResult? { result }
}

@MainActor
final class SessionBrowserModelRemoteInstallStatusTests: XCTestCase {

    /// Cooperatively yields until `condition()` is true, bounded by
    /// `maxYields` as a safety valve -- mirrors
    /// SessionBrowserModelRefreshCancellationGuardTests' own identical
    /// helper (duplicated per-file per this codebase's established
    /// fixture convention).
    private func waitUntil(maxYields: Int = 10_000, _ condition: () -> Bool) async {
        var iterations = 0
        while !condition(), iterations < maxYields {
            await Task.yield()
            iterations += 1
        }
    }

    // MARK: - Before any attempt

    func test_installStatus_beforeAnyAttempt_isIdle() {
        let model = SessionBrowserModel(daemonClient: FixedInstallResultDaemonClient(), surfaceMap: SessionSurfaceMap())

        XCTAssertEqual(
            model.installStatus(forHost: "devbox.example.com"), .idle,
            "A host with no install attempted yet must report .idle"
        )
    }

    // MARK: - installing (in-flight)

    func test_installStatus_whileInstallInFlight_isInstalling() async {
        let client = SuspendingInstallDaemonClient()
        let model = SessionBrowserModel(daemonClient: client, surfaceMap: SessionSurfaceMap())

        let installTask = Task { await model.installRemote(host: "devbox.example.com") }
        await waitUntil { client.pendingHosts.contains("devbox.example.com") }

        XCTAssertEqual(
            model.installStatus(forHost: "devbox.example.com"), .installing,
            "While the daemon round-trip is in flight, the host's status must be .installing"
        )

        client.resume(host: "devbox.example.com", with: CommandResult(exitCode: 0, stdout: "", stderr: ""))
        _ = await installTask.value
    }

    // MARK: - succeeded / failed / nil terminal states

    func test_installStatus_afterExitCodeZero_isSucceeded() async {
        let daemonClient = FixedInstallResultDaemonClient()
        daemonClient.result = CommandResult(exitCode: 0, stdout: "installed", stderr: "")
        let model = SessionBrowserModel(daemonClient: daemonClient, surfaceMap: SessionSurfaceMap())

        _ = await model.installRemote(host: "devbox.example.com")

        XCTAssertEqual(model.installStatus(forHost: "devbox.example.com"), .succeeded)
    }

    func test_installStatus_afterNonZeroExitCode_isFailed_carryingStderr() async {
        let daemonClient = FixedInstallResultDaemonClient()
        daemonClient.result = CommandResult(exitCode: 1, stdout: "", stderr: "ssh: connection refused")
        let model = SessionBrowserModel(daemonClient: daemonClient, surfaceMap: SessionSurfaceMap())

        _ = await model.installRemote(host: "devbox.example.com")

        XCTAssertEqual(
            model.installStatus(forHost: "devbox.example.com"), .failed("ssh: connection refused"),
            "A non-zero exit code must report .failed, carrying the result's stderr for the row to display"
        )
    }

    func test_installStatus_afterNilResult_isFailed() async {
        let daemonClient = FixedInstallResultDaemonClient()
        daemonClient.result = nil
        let model = SessionBrowserModel(daemonClient: daemonClient, surfaceMap: SessionSurfaceMap())

        _ = await model.installRemote(host: "devbox.example.com")

        XCTAssertEqual(
            model.installStatus(forHost: "devbox.example.com"), .failed(nil),
            "SessionRemoteInstallTests' existing no-local-binary-resolvable nil case must still surface as " +
            ".failed here, not silently stay at .idle or .installing forever -- there is no successful " +
            "outcome to report"
        )
    }

    // MARK: - independence across hosts

    func test_installStatus_isIndependentPerHost() async {
        let daemonClient = FixedInstallResultDaemonClient()
        daemonClient.result = CommandResult(exitCode: 0, stdout: "", stderr: "")
        let model = SessionBrowserModel(daemonClient: daemonClient, surfaceMap: SessionSurfaceMap())

        _ = await model.installRemote(host: "devbox.example.com")

        XCTAssertEqual(model.installStatus(forHost: "devbox.example.com"), .succeeded)
        XCTAssertEqual(
            model.installStatus(forHost: "staging.example.com"), .idle,
            "A different host that was never installed to must be unaffected, still .idle"
        )
    }
}
