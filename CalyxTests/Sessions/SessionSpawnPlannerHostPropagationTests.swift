//
//  SessionSpawnPlannerHostPropagationTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, BUG 3 (five-angle convergence review
//  finding), contract 3a (planner level): SpawnPlan.persistent carries
//  only `sessionID`/`command` -- even though SessionSpawnPlanner.plan(for:)
//  already correctly branches on `context.host` (SessionSpawnPlannerRemoteHostTests,
//  already green) and synthesizes the right remote command, the RESULT it
//  hands back drops that host entirely. A caller applying the plan (see
//  CalyxWindowControllerCreateManagedSurfaceRemoteHostTests, contract 3b)
//  has no way to know the plan it just received came from a remote
//  context at all, so it always builds `SessionRef(sessionID:)` with
//  `host: nil` -- silently losing the remote-ness of a session it just
//  spawned.
//
//  FIX CONTRACT: `SpawnPlan.persistent` gains a third associated value,
//  `host: String?`, mirroring `context.host` -- `nil` for a local plan,
//  the given host for a remote one. `plan(for:)`'s two existing
//  `return .persistent(sessionID:, command:)` call sites (one per
//  branch) must each pass their own already-in-hand host value (`nil`
//  for the local branch, `context.host` for the remote branch).
//
//  BREAKING CHANGE, ACKNOWLEDGED: Swift enum pattern matching requires
//  exact arity even when the new associated value has a default -- adding
//  `host` to `.persistent` breaks every existing 2-element
//  `case .persistent(let sessionID, let command):`/
//  `case .persistent(_, let command):` pattern match at once (verified:
//  a 2-element tuple pattern against a 3-element case is a compiler
//  error, not silently accepted). The Green phase must update EVERY one
//  of the following existing call sites to bind (or discard via `_`) the
//  new third element:
//    - SessionSpawnPlanner.swift: both `return .persistent(...)` sites
//    - CalyxWindowController.swift ~660 (createManagedSurface)
//    - CalyxTests/Sessions/SessionSpawnPlannerTests.swift (3 matches)
//    - CalyxTests/Sessions/SessionSpawnPlannerRemoteHostTests.swift (3 matches)
//    - CalyxTests/Sessions/SessionBinaryResolverTests.swift (1 match)
//  None of those files are touched by this RED phase -- they are
//  currently green and must stay compiling unchanged from THIS file's
//  perspective; the arity change is deferred entirely to the Green
//  phase, which fixes all of the above atomically alongside the enum
//  definition itself.
//
//  Held-out compile-RED file per this codebase's established convention:
//  `SpawnPlan.persistent`'s third `host` element does not exist yet --
//  every 3-element pattern match in this file fails to compile against
//  today's 2-element case. Expected to FAIL TO COMPILE until the Green
//  phase adds it. That compile failure IS this file's RED evidence. Must
//  be excluded from the build while running the rest of the round's RED
//  suite (a compile failure anywhere fails the whole CalyxTests target)
//  and verified separately for its own specific compiler errors.
//
//  Reuses SessionSpawnPlannerRemoteHostTests' exact FakeBinaryResolver/
//  SessionSettings._testUseSuite conventions.
//
//  Coverage:
//  - A remote-host context (context.host != nil) produces
//    .persistent(sessionID:, command:, host:) whose host equals exactly
//    the context's host
//  - A local context (context.host == nil) still produces
//    .persistent(..., host: nil) -- regression guard, matching every
//    existing SessionSpawnPlannerTests expectation once updated
//  - .quickTerminal origin with a remote host set still returns
//    .passthrough (no host to propagate at all) -- unaffected by this
//    fix, included here as a completeness regression guard specific to
//    the new associated value's shape
//

import XCTest
@testable import Calyx

private struct FakeBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

final class SessionSpawnPlannerHostPropagationTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.SessionSpawnPlannerHostPropagationTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    func test_plan_remoteHostContext_persistentPlanCarriesTheGivenHost() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/home/dev/repo", host: "devbox.example.com", origin: .tab)

        let plan = SessionSpawnPlanner.plan(for: context, resolver: FakeBinaryResolver(path: nil))

        guard case .persistent(_, _, let host) = plan else {
            XCTFail("A remote-host context must produce .persistent")
            return
        }
        XCTAssertEqual(host, "devbox.example.com",
                       "The plan's own host must carry exactly the context's host, so a caller applying " +
                       "the plan can build SessionRef(sessionID:host:) correctly without needing to " +
                       "separately remember the original context")
    }

    func test_plan_localContext_persistentPlanCarriesNilHost() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/home/dev/repo", origin: .tab)

        let plan = SessionSpawnPlanner.plan(for: context, resolver: FakeBinaryResolver(path: "/dummy/calyx-session"))

        guard case .persistent(_, _, let host) = plan else {
            XCTFail("A local context must still produce .persistent")
            return
        }
        XCTAssertNil(host, "A local context (context.host == nil) must produce a plan whose host is also " +
                     "nil -- regression guard for every existing local-spawn caller")
    }

    func test_plan_remoteHostQuickTerminalOrigin_stillPassthrough_noHostToPropagate() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/home/dev/repo", host: "devbox.example.com", origin: .quickTerminal)

        XCTAssertEqual(SessionSpawnPlanner.plan(for: context, resolver: FakeBinaryResolver(path: "/dummy/calyx-session")), .passthrough,
                       "QuickTerminal panes stay excluded even with a remote host set -- unaffected by this " +
                       "fix, .passthrough itself never carries a host")
    }
}
