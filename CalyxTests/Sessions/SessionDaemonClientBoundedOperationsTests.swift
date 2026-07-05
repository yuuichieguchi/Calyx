//
//  SessionDaemonClientBoundedOperationsTests.swift
//  CalyxTests
//
//  TDD Red phase, round 12 (r12-fix-spec.md, R12-B, as narrowed by the
//  round-11 sweep addendum item 1): the 5s daemon-round-trip bound
//  `listAllBounded()` established (round 10, see
//  SessionDaemonClientBoundedListTests) covers only the ledger listing
//  call. `sessionState(id:)` (SessionReconnectCoordinator.childExited's
//  reconnect decision) still awaits the underlying
//  commandRunner.run(...) completely unbounded, so a hung
//  calyx-session daemon can stall the reconnect decision indefinitely,
//  exactly the failure mode `listAllBounded()` already fixed for the
//  ledger listing alone.
//
//  Scope note (binding, sweep addendum item 1): ONLY `sessionState` is
//  covered here. It is read-only, so racing it against a timeout and
//  cancelling the loser (mirroring `listAllBounded()`'s shape exactly)
//  is safe. `kill(id:)` is deliberately EXCLUDED from this bounded
//  treatment: now that R12-A makes Task cancellation reach the actual
//  Process (SIGTERM), cancelling a slow `calyx-session kill` mid-IPC-write
//  would silently lose the kill -- worse than a slow-but-eventually-
//  completed one. `kill(id:)` keeps its current unbounded
//  complete-or-watchdog semantics; `SessionKillTracker`'s 2s quit-drain
//  already abandons (without cancelling) rather than needing a new
//  bounded wrapper. `setMeta(id:key:value:)` is a similar WRITE and, per
//  the same addendum, is left to Green's discretion (abandon-style
//  bound -- resume the caller on timeout WITHOUT cancelling the write
//  -- if bounded at all); it is out of this RED contract's scope.
//
//  This test targets `SessionDaemonClientProtocol.sessionStateBounded(id:)`,
//  which does NOT exist in the codebase yet. Following this codebase's
//  established convention for new-API RED tests (see
//  SessionDaemonClientBoundedListTests' header comment, itself citing
//  CalyxWindowControllerFullScreenTests), this file is expected to FAIL
//  TO COMPILE until the TDD Green phase adds it -- that compile failure
//  IS this contract's round-12 RED evidence. Once Green adds the
//  bounded wrapper, this test exercises it against a REAL
//  SessionDaemonClient (not a protocol-level fake), with a
//  never-completing LSPCommandRunner injected via the client's existing
//  `commandRunner:` seam (mirrors SessionDaemonClientBoundedListTests'
//  own fixture, duplicated here per this codebase's established
//  per-file fixture-duplication convention rather than shared) standing
//  in for a calyx-session subprocess that never exits, so a passing run
//  demonstrates the bound is enforced by the actual production client.
//
//  Coverage:
//  - SessionDaemonClient.sessionStateBounded(id:) returns .unreachable
//    (the timeout sentinel; SessionReconnectCoordinator already treats
//    .unreachable as a retry/give-up input) within the bound, even when
//    the underlying commandRunner.run(...) never completes
//

import XCTest
@testable import Calyx

/// An LSPCommandRunner whose run(...) awaits a continuation this test
/// never resumes, standing in for a calyx-session subprocess (or
/// daemon) that hangs forever. Harmless to leave suspended for the rest
/// of the process's life: the bounded call below is bounded by its own
/// timeout race and must reach a terminal result regardless.
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

final class SessionDaemonClientBoundedOperationsTests: XCTestCase {

    override func tearDown() {
        // R14-B (r14-fix-spec.md): test isolation, mirroring
        // SessionDaemonClientSessionStateBoundTimeoutSeamTests' own
        // tearDown -- no override must leak into a later test.
        SessionDaemonClientBoundTimeoutOverrides.sessionStateBoundTimeoutSeconds = nil
        super.tearDown()
    }

    /// R12-B: against a never-completing commandRunner,
    /// sessionStateBounded(id:) must still reach a terminal
    /// .unreachable within a generous margin over its own bound.
    /// R14-B (r14-fix-spec.md): overrides `sessionStateBoundTimeoutSeconds`
    /// to 1s via the DEBUG timeout seam so this test runs in
    /// milliseconds instead of burning the real ~5s default.
    func test_sessionStateBounded_returnsUnreachableWithinBound_whenCommandRunnerNeverCompletes() async {
        SessionDaemonClientBoundTimeoutOverrides.sessionStateBoundTimeoutSeconds = 1

        let resolver = FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session")
        let client = SessionDaemonClient(resolver: resolver, commandRunner: NeverCompletingCommandRunner())

        let start = Date()
        let result = await client.sessionStateBounded(id: "any-session-id")
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            result, .unreachable,
            "sessionStateBounded(id:) must degrade to .unreachable rather than hang forever when the daemon " +
            "round-trip never completes"
        )
        XCTAssertLessThan(
            elapsed, 3.0,
            "sessionStateBounded(id:) must be bounded by its own timeout (overridden to 1s here), not the " +
            "unbounded subprocess layer"
        )
    }
}
