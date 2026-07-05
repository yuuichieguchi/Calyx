//
//  SessionDaemonClientBoundedListTests.swift
//  CalyxTests
//
//  TDD Red phase, round 10 (r10-fix-spec.md, R10-C item 2): the 5s
//  daemon-round-trip bound currently lives ONLY inside AppDelegate's
//  agent-resume path (listAllSessionsBounded, private, R8-D item 1).
//  SessionBrowserModel.refresh() awaits daemonClient.listAll()
//  completely unbounded (SessionBrowserModel.swift:60), so a hung
//  calyx-session daemon freezes the session browser forever -- the
//  exact failure mode already fixed for the agent-resume path alone.
//  The fix moves that same bounded race down to the
//  SessionDaemonClient(Protocol) level, as `listAllBounded()`, so the
//  browser and agent-resume paths share one bounded implementation and
//  one timeout constant instead of each reimplementing (or, in the
//  browser's case, omitting) it.
//
//  This test targets `SessionDaemonClient.listAllBounded()`, which does
//  NOT exist in the codebase yet. Following this codebase's established
//  convention for new-API RED tests (see
//  CalyxWindowControllerFullScreenTests's header comment), it is
//  expected to FAIL TO COMPILE until the TDD Green phase adds it --
//  that compile failure IS this contract's round-10 RED evidence. Once
//  Green implements `listAllBounded()`, this test exercises it against
//  a REAL SessionDaemonClient (not a protocol-level fake), with a
//  never-completing LSPCommandRunner injected via the client's existing
//  `commandRunner:` seam (mirrors SessionBinaryResolverTests' direct-
//  construction style) standing in for a calyx-session subprocess that
//  never exits, so a passing run demonstrates the bound is enforced by
//  the actual production client, not merely a test double.
//
//  Coverage:
//  - SessionDaemonClient.listAllBounded() returns [] within the bound
//    even when the underlying commandRunner.run(...) never completes
//

import XCTest
@testable import Calyx

/// An LSPCommandRunner whose run(...) awaits a continuation this test
/// never resumes, standing in for a calyx-session subprocess (or
/// daemon) that hangs forever. Harmless to leave suspended for the rest
/// of the process's life: listAllBounded() is bounded by its own
/// timeout race and must reach a terminal [] regardless.
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

final class SessionDaemonClientBoundedListTests: XCTestCase {

    /// R10-C item 2: against a never-completing commandRunner,
    /// listAllBounded() must still reach a terminal [] within a
    /// generous margin over its own bound, exactly mirroring
    /// AppDelegateOfferAgentResumePipelineBoundTests' 8s margin over the
    /// same 5s default.
    func test_listAllBounded_returnsEmptyWithinBound_whenCommandRunnerNeverCompletes() async {
        let resolver = FixedBinaryResolver(path: "/opt/calyx-fixture/bin/calyx-session")
        let client = SessionDaemonClient(resolver: resolver, commandRunner: NeverCompletingCommandRunner())

        let start = Date()
        let sessions = await client.listAllBounded()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(
            sessions, [],
            "listAllBounded() must degrade to [] rather than hang forever when the daemon round-trip never " +
            "completes"
        )
        XCTAssertLessThan(
            elapsed, 8.0,
            "listAllBounded() must be bounded by its own timeout (~5s default), not the unbounded " +
            "subprocess layer"
        )
    }
}
