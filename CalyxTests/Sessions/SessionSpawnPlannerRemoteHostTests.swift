//
//  SessionSpawnPlannerRemoteHostTests.swift
//  CalyxTests
//
//  P5 (remote sessions) RED phase, contract R5 (COMPILE-RED, HELD-OUT
//  FILE): SessionSpawnPlanner.plan(for:) (SessionSpawnPlanner.swift) has
//  no way to spawn a REMOTE persistent session at all today --
//  SessionSpawnContext carries no host, and `plan(for:)` always (a)
//  gates on the LOCAL calyx-session binary being resolvable via
//  `resolver.resolve()`, degrading to `.passthrough` if not, and (b)
//  synthesizes its command via `SessionCommandSynthesizer.attachCommand`,
//  the local-only path.
//
//  SCOPE NOTE (per this round's brief): this contract stays at the
//  PLANNER level. No call site constructs a `SessionSpawnContext` with a
//  host yet -- exactly like `SessionSpawnOrigin.quickTerminal`'s own
//  existing "deliberate tripwire, currently unreachable" precedent (see
//  that case's doc comment in SessionSpawnPlanner.swift). The
//  palette-level UI entry that lets a user actually pick a remote host
//  for a NEW pane is out of scope for this cycle (a later one, per the
//  investigation brief).
//
//  THE NEW FIELD: `SessionSpawnContext` gains a `host: String? = nil`
//  stored property (`nil` for every existing call site, unchanged, plus
//  the "local" case going forward). `plan(for:)` must special-case
//  `context.host != nil`:
//
//    - The LOCAL binary-resolvability guard (`guard let binaryPath =
//      resolver.resolve() else { return .passthrough }`) must NOT apply
//      to a remote context at all -- a remote session's daemon lives
//      entirely on the remote machine; the local calyx-session binary's
//      presence (or absence) says nothing about whether a remote spawn
//      can proceed. Requiring it would wrongly degrade every remote
//      spawn attempt to `.passthrough` on any machine that doesn't
//      happen to also have the LOCAL binary installed.
//    - The command must be built via
//      `SessionCommandSynthesizer.remoteAttachCommand(host:sessionID:cwd:)`
//      instead of `attachCommand(binaryPath:sessionID:cwd:name:)`.
//      `remoteAttachCommand` never returns nil (SSHBinaryResolver always
//      resolves to a path, see its own doc comment), so a remote
//      `.persistent` plan can never itself fail to produce a command the
//      way a local one degrading to `.passthrough` can.
//    - The fresh-ULID-per-call and cwd-priority
//      (`inheritedCwd ?? cwd ?? home`) contracts
//      SessionSpawnPlannerTests already covers for the local path apply
//      identically to the remote path -- no new sessionID-generation or
//      cwd-selection logic, only which command-synthesis function and
//      which gate are used.
//    - `SessionSpawnOrigin.quickTerminal`'s existing exclusion is
//      untouched: it must still win over a remote host being set, for
//      the exact same reason it wins over the feature being enabled at
//      all (ephemeral scratch panes, out of scope for reconnect/restore
//      semantics regardless of locality).
//
//  NONE of `SessionSpawnContext.host` or the remote branch inside
//  `plan(for:)` exist yet -- this file is expected to FAIL TO COMPILE
//  until the TDD Green phase adds them. That compile failure IS this
//  contract's RED evidence, following this codebase's established
//  held-out-file convention (see
//  SessionReconnectGracePositiveSignalSeamTests's header comment). Must
//  be excluded from the build while running the rest of the round's RED
//  suite and verified separately for its own specific compiler errors.
//
//  Reuses SessionSpawnPlannerTests' exact FakeBinaryResolver/
//  SessionSettings._testUseSuite/ULID-validity-check conventions.
//  Deliberately does NOT execute the synthesized command through a real
//  `/bin/sh -c` the way SessionSpawnPlannerTests' cwd-priority tests do
//  (that machinery exists to decompose an escaped `--cwd` argument
//  losslessly, which is not this contract's concern): a remote
//  command's shape is already fully covered at the unit level by
//  SessionCommandSynthesizerRemoteAttachTests, so these tests only
//  need substring-level checks confirming which code path
//  `plan(for:)` took.
//
//  Coverage:
//  - A remote-host context still produces `.persistent` even when the
//    LOCAL binary resolver returns nil (the exact condition that
//    degrades a LOCAL context to `.passthrough`).
//  - The synthesized command carries the given host and never carries
//    the local-only `--runtime-dir`/`--state-dir` flags.
//  - `.quickTerminal` origin still wins even with a remote host set.
//  - Each call still produces a fresh, distinct ULID sessionID.
//

import XCTest
@testable import Calyx

private struct FakeBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

final class SessionSpawnPlannerRemoteHostTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.SessionSpawnPlannerRemoteHostTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    private func isValidULID(_ s: String) -> Bool {
        guard s.count == 26 else { return false }
        let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return s.allSatisfy { crockford.contains($0) }
    }

    func test_plan_remoteHost_noLocalBinaryResolvable_stillReturnsPersistentWithSSHCommand() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/home/dev/repo", host: "devbox.example.com", origin: .tab)

        // FakeBinaryResolver(path: nil) simulates "no local calyx-session
        // binary resolvable" -- exactly the condition that degrades a
        // LOCAL context to .passthrough. A remote spawn must not depend
        // on the local binary at all.
        let plan = SessionSpawnPlanner.plan(for: context, resolver: FakeBinaryResolver(path: nil))

        guard case .persistent(let sessionID, let command) = plan else {
            XCTFail("A remote-host context must produce .persistent even when no local calyx-session binary is resolvable")
            return
        }
        XCTAssertTrue(isValidULID(sessionID), "sessionID must be a fresh ULID, matching the local-path contract")
        XCTAssertTrue(command.contains("devbox.example.com"), "The synthesized command must target the given remote host")
        XCTAssertFalse(command.contains("--runtime-dir"), "A remote spawn must never carry the local --runtime-dir flag")
        XCTAssertFalse(command.contains("--state-dir"), "A remote spawn must never carry the local --state-dir flag")
    }

    func test_plan_remoteHost_quickTerminalOrigin_stillReturnsPassthrough() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/home/dev/repo", host: "devbox.example.com", origin: .quickTerminal)

        XCTAssertEqual(SessionSpawnPlanner.plan(for: context, resolver: FakeBinaryResolver(path: "/dummy/calyx-session")), .passthrough,
                       "QuickTerminal panes must stay excluded even when a remote host is set -- the " +
                       "exclusion is about the pane's ephemeral lifecycle, not about locality")
    }

    func test_plan_remoteHost_distinctCallsProduceDistinctSessionIDs() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/home/dev/repo", host: "devbox.example.com", origin: .tab)
        let resolver = FakeBinaryResolver(path: nil)

        guard case .persistent(let firstID, _) = SessionSpawnPlanner.plan(for: context, resolver: resolver),
              case .persistent(let secondID, _) = SessionSpawnPlanner.plan(for: context, resolver: resolver) else {
            XCTFail("Both calls must produce .persistent for a remote-host context")
            return
        }
        XCTAssertNotEqual(firstID, secondID, "Each new remote surface must get its own freshly generated session ID")
    }

    func test_plan_remoteHostAndInheritedCwdBothSet_inheritedCwdTakesPriority() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(
            cwd: "/home/dev/stale-repo", inheritedCwd: "/home/dev/split-origin", host: "devbox.example.com", origin: .tab
        )

        guard case .persistent(_, let command) = SessionSpawnPlanner.plan(for: context, resolver: FakeBinaryResolver(path: nil)) else {
            XCTFail("A remote-host context must produce .persistent")
            return
        }
        XCTAssertTrue(command.contains("/home/dev/split-origin"),
                     "inheritedCwd must take priority over the tab's own (possibly stale) cwd, matching the " +
                     "existing local-path cwd-priority contract, unchanged for the remote path")
        XCTAssertFalse(command.contains("/home/dev/stale-repo"))
    }
}
