//
//  SSHHostCandidateProviderTests.swift
//  CalyxTests
//
//  TDD Red phase, P5 (remote sessions), RED5 cycle (remote UI wiring),
//  contract R1: `SSHHostCandidateProvider` -- the read side that turns
//  SSHConfigParser.hostCandidates(from:) (cycle 1, pure string parsing,
//  already green) into an actual list of remote-host candidates for the
//  "New Remote Session..." picker (R2/R4), by reading ~/.ssh/config's
//  CONTENT through an injectable loader.
//
//  Held-out compile-RED file per this codebase's established convention
//  (see SessionSpawnPlannerRemoteHostTests's header): `SSHHostCandidateProvider`
//  does not exist anywhere in the codebase yet. Expected to FAIL TO
//  COMPILE until the Green phase adds it; that compile failure IS this
//  contract's RED evidence.
//
//  DESIGN: mirrors SessionRootResolver's own HOME-resolution discipline
//  by REUSING SessionRootResolverProtocol directly (never re-deriving
//  HOME independently) -- the config path is
//  "<rootResolver.resolve()>/.ssh/config". The actual file read is
//  isolated behind an injectable `loadConfig` closure
//  ((String) -> String?, nil on any read failure), so no test here ever
//  touches a real filesystem path. `hostCandidates()` delegates ALL
//  parsing to SSHConfigParser.hostCandidates(from:) and adds only: (a)
//  deriving the config path, (b) the injectable read, (c) deduplication
//  that preserves first-seen order -- a contract
//  SSHConfigParser.hostCandidates itself deliberately does NOT provide
//  (see that function's own doc comment).
//
//  Coverage:
//  - The config path handed to loadConfig is exactly
//    "<rootResolver.resolve()>/.ssh/config"
//  - A missing/unreadable config (loadConfig returns nil) yields an
//    empty list, never a crash or thrown error
//  - Real ssh_config content is parsed via SSHConfigParser and returned,
//    wildcard patterns excluded exactly as SSHConfigParserTests already
//    establishes
//  - Repeated aliases across the config are deduplicated, preserving
//    first-seen declaration order
//  - With no rootResolver override, the composed path matches the real
//    production default (mirrors SessionDaemonClientRuntimeDirArgsTests'
//    identical real-default smoke test)
//

import XCTest
@testable import Calyx

private struct FakeRootResolver: SessionRootResolverProtocol {
    let root: String
    func resolve() -> String { root }
}

final class SSHHostCandidateProviderTests: XCTestCase {

    func test_hostCandidates_readsConfigFromRootResolverDerivedPath() {
        var capturedPath: String?
        let provider = SSHHostCandidateProvider(
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home"),
            loadConfig: { path in
                capturedPath = path
                return "Host devbox\n"
            }
        )

        _ = provider.hostCandidates()

        XCTAssertEqual(capturedPath, "/opt/calyx-fixture/custom-home/.ssh/config",
                       "The config path must be derived from the injected SessionRootResolverProtocol's " +
                       "resolve() value, exactly like SessionRootResolver's own HOME-resolution discipline " +
                       "-- never re-derived independently via NSHomeDirectory() or ProcessInfo directly")
    }

    func test_hostCandidates_missingConfig_returnsEmptyList() {
        let provider = SSHHostCandidateProvider(
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home"),
            loadConfig: { _ in nil }
        )

        XCTAssertEqual(provider.hostCandidates(), [],
                       "A missing or unreadable ~/.ssh/config must yield an empty candidate list, never " +
                       "crash or throw")
    }

    func test_hostCandidates_parsesRealConfigContentViaSSHConfigParser() {
        let configText = """
        Host devbox
            HostName devbox.internal

        Host staging *.example.com
            User deploy
        """
        let provider = SSHHostCandidateProvider(
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home"),
            loadConfig: { _ in configText }
        )

        XCTAssertEqual(provider.hostCandidates(), ["devbox", "staging"],
                       "hostCandidates() must delegate to SSHConfigParser.hostCandidates(from:) for actual " +
                       "parsing -- devbox and staging are extracted, the wildcard *.example.com pattern " +
                       "excluded, exactly matching SSHConfigParserTests' own established parsing contract")
    }

    func test_hostCandidates_dedupesRepeatedAliases_preservingFirstSeenOrder() {
        let configText = """
        Host devbox
        Host staging
        Host devbox
        """
        let provider = SSHHostCandidateProvider(
            rootResolver: FakeRootResolver(root: "/opt/calyx-fixture/custom-home"),
            loadConfig: { _ in configText }
        )

        XCTAssertEqual(provider.hostCandidates(), ["devbox", "staging"],
                       "A host alias repeated across multiple Host lines must appear only once in the " +
                       "returned list, at its FIRST declared position -- SSHConfigParser.hostCandidates(from:) " +
                       "itself deliberately does not dedupe (see that function's own doc comment), so this " +
                       "provider must do it")
    }

    func test_hostCandidates_defaultRootResolver_composesRealHOMESSHConfigPath() {
        var capturedPath: String?
        // No rootResolver override: exercises the real production
        // default (SessionRootResolver()), mirroring
        // SessionDaemonClientRuntimeDirArgsTests' identical real-default
        // smoke test.
        let provider = SSHHostCandidateProvider(loadConfig: { path in
            capturedPath = path
            return nil
        })

        _ = provider.hostCandidates()

        XCTAssertEqual(capturedPath, NSHomeDirectory() + "/.ssh/config",
                       "With no rootResolver override, the composed path must equal the real " +
                       "NSHomeDirectory()/.ssh/config, matching SessionRootResolver's own production default")
    }
}
