//
//  SessionDaemonClientSessionStateBoundTimeoutSeamTests.swift
//  CalyxTests
//
//  TDD Red phase, round 14 (r14-fix-spec.md, R14-B): `bounded()`
//  currently hard-codes ONE shared timeout (`listAllBoundTimeoutSeconds`,
//  5s) for every caller, including `sessionStateBounded(id:)`
//  (SessionReconnectCoordinator.childExited's reconnect decision). But
//  that path feeds a 5-attempt-cap retry/backoff sequence (0/1/2/4/8s),
//  so its bound must be generous enough to separate "daemon truly hung"
//  from "daemon merely busy" -- the 5s value was tuned for the
//  low-consequence session-browser poll `listAllBounded()` serves, not
//  for this. The fix parameterizes `bounded(timeout:)` (default = the
//  general constant, renamed `listAllBoundTimeoutSeconds` ->
//  `daemonQueryBoundTimeoutSeconds`) and gives `sessionStateBounded(id:)`
//  its own dedicated, longer `sessionStateBoundTimeoutSeconds` (15s).
//
//  Asserting the real 15s-vs-5s difference directly would need a 15s+
//  wall-clock test; this codebase's established convention (see
//  SessionSettings._testStore's suite-swap seam, NotificationManager
//  .shared's #if DEBUG var seam, R6-F) is to add a narrow, DEBUG-only
//  override hook instead, so the SAME plumbing (which constant
//  `sessionStateBounded(id:)` actually threads into `bounded(timeout:)`)
//  can be asserted with tiny, clearly-distinguishable overridden values.
//  This test exercises that seam:
//
//    #if DEBUG
//    enum SessionDaemonClientBoundTimeoutOverrides {
//        nonisolated(unsafe) static var daemonQueryBoundTimeoutSeconds: UInt64?
//        nonisolated(unsafe) static var sessionStateBoundTimeoutSeconds: UInt64?
//    }
//    #endif
//
//  -- `nil` (the default) means "use the production value"; each
//  computed property (`SessionDaemonClientProtocol.daemonQueryBoundTimeoutSeconds`
//  / `.sessionStateBoundTimeoutSeconds`) consults its matching override
//  first under `#if DEBUG`. NONE of this exists in the codebase yet.
//  Following this codebase's established convention for new-API RED
//  tests (see SessionDaemonClientBoundedListTests' header comment,
//  itself citing CalyxWindowControllerFullScreenTests), this file is
//  expected to FAIL TO COMPILE until the TDD Green phase adds the
//  overrides enum plus the rename/parameterization above -- that compile
//  failure IS this contract's round-14 RED evidence for R14-B. This is
//  the "held-out" file: run the rest of the round-14 RED suite with this
//  file's new symbols absent from the build, then attempt this file on
//  its own to capture the specific compiler errors.
//
//  Once Green lands, this test overrides the general bound to 3s and the
//  dedicated one to 1s (deliberately different, so a wrongly-wired
//  implementation that used the general bound instead of the dedicated
//  one would show up as ~3s elapsed instead of the expected ~1s) and
//  drives `sessionStateBounded(id:)` against a never-completing
//  commandRunner, asserting the elapsed wait lands near the dedicated 1s
//  override rather than the general 3s one or an unbounded hang.
//
//  Coverage:
//  - sessionStateBounded(id:) threads its OWN dedicated
//    sessionStateBoundTimeoutSeconds into bounded(timeout:), not the
//    general daemonQueryBoundTimeoutSeconds every other bounded call uses
//

import XCTest
@testable import Calyx

/// An LSPCommandRunner whose run(...) awaits a continuation this test
/// never resumes, standing in for a calyx-session subprocess (or daemon)
/// that hangs forever. Mirrors SessionDaemonClientBoundedOperationsTests'
/// own fixture, duplicated here per this codebase's established
/// per-file fixture-duplication convention.
private final class NeverCompletingCommandRunner: LSPCommandRunner, @unchecked Sendable {
    func run(
        executable: String,
        arguments: [String],
        workingDirectory: URL?,
        environment: [String: String]?
    ) async throws -> CommandResult {
        await withCheckedContinuation { (_: CheckedContinuation<CommandResult, Never>) in
            // Deliberately never resumed.
        }
    }

    func locate(_ executable: String) async -> URL? { nil }
}

private struct FixedBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

final class SessionDaemonClientSessionStateBoundTimeoutSeamTests: XCTestCase {

    override func tearDown() {
        // Test isolation: no override must leak into a later test.
        SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds = nil
        SessionDaemonClientBoundTimeoutOverrides.sessionStateBoundTimeoutSeconds = nil
        super.tearDown()
    }

    /// RED (R14-B, compile-RED per this file's header comment):
    /// `SessionDaemonClientBoundTimeoutOverrides` does not exist yet, so
    /// this file fails to compile until Green adds the dedicated bound,
    /// the rename, and the override seam described above.
    func test_sessionStateBounded_usesDedicatedTimeout_notTheGeneralOne() async {
        SessionDaemonClientBoundTimeoutOverrides.daemonQueryBoundTimeoutSeconds = 3
        SessionDaemonClientBoundTimeoutOverrides.sessionStateBoundTimeoutSeconds = 1

        let resolver = FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session")
        let client = SessionDaemonClient(resolver: resolver, commandRunner: NeverCompletingCommandRunner())

        let start = Date()
        let result = await client.sessionStateBounded(id: "any-session-id")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result, .unreachable)
        XCTAssertGreaterThan(
            elapsed, 0.7,
            "sessionStateBounded(id:) must actually wait out its own dedicated " +
            "sessionStateBoundTimeoutSeconds bound (overridden to 1s here), not resolve as soon as an " +
            "unrelated shorter bound would have"
        )
        XCTAssertLessThan(
            elapsed, 2.0,
            "sessionStateBounded(id:) must be governed by its dedicated sessionStateBoundTimeoutSeconds bound " +
            "(1s here), not the general daemonQueryBoundTimeoutSeconds bound every other bounded call shares " +
            "(3s here)"
        )
    }
}
