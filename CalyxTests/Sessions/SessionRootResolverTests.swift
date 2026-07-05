//
//  SessionRootResolverTests.swift
//  CalyxTests
//
//  TDD Red phase (session-root-resolution fix round): the Rust
//  calyx-session daemon/CLI resolves its on-disk state root
//  ($HOME/.calyx: run/sessiond.sock, state/) from the literal HOME env
//  var at process start (see calyx-session/crates/daemon/src/session.rs),
//  while the Swift half of the feature has no single place that agrees
//  with that value -- SessionCommandSynthesizer's synthesized attach
//  command inherits whatever ambient env ghostty passes the surface,
//  and SessionDaemonClient's queries inherit whatever ambient env
//  Calyx.app itself has, and neither consults FileManager
//  .homeDirectoryForCurrentUser (which ignores HOME entirely -- proven
//  live: an app launched with HOME=/tmp/x still wrote ~/.calyx/sessions.json
//  under the real home). `SessionRootResolver` is the new single source
//  of truth both halves must consult (mirrors `SessionBinaryResolver`'s
//  existing role of being the one place `SessionSpawnPlanner` and
//  `SessionDaemonClient` agree on the calyx-session binary path) so a
//  single resolved value can be threaded to both the synthesized attach
//  command (SessionCommandSynthesizerHomeStampTests) and the daemon
//  query environment (SessionDaemonClientHomeEnvironmentTests).
//
//  This file targets `SessionRootResolverProtocol` and
//  `SessionRootResolver`, NEITHER of which exists in the codebase yet.
//  Following this codebase's established convention for new-API RED
//  tests (see SessionDaemonClientBoundedListTests' header comment,
//  itself citing CalyxWindowControllerFullScreenTests), this file is
//  expected to FAIL TO COMPILE until the TDD Green phase adds them --
//  that compile failure IS this contract's RED evidence.
//
//  Coverage:
//  - resolve() returns the injected environment's "HOME" value when
//    present and non-empty
//  - resolve() falls back to NSHomeDirectory() when "HOME" is absent
//    from the injected environment
//  - resolve() falls back to NSHomeDirectory() when "HOME" is present
//    but an empty string (mirrors SessionBinaryResolver's own
//    present-but-empty-string handling for CALYX_SESSION_BIN)
//
//  Deliberately NOT tested here: the production default
//  (`SessionRootResolver()`, reading the real
//  `ProcessInfo.processInfo.environment`) -- asserting on the live
//  test host's real $HOME would only prove the trivial identity
//  `$HOME == $HOME`, not any resolver behavior, and ties the test to
//  the ambient test environment rather than the injectable seam that
//  actually matters for the fix (SessionCommandSynthesizerHomeStampTests
//  and SessionDaemonClientHomeEnvironmentTests exercise the injected
//  seam directly).
//

import XCTest
@testable import Calyx

final class SessionRootResolverTests: XCTestCase {

    func test_resolve_returnsInjectedHOMEValue_whenPresentAndNonEmpty() {
        let resolver = SessionRootResolver(environment: ["HOME": "/opt/calyx-fixture/custom-home"])

        XCTAssertEqual(resolver.resolve(), "/opt/calyx-fixture/custom-home",
                       "With HOME present in the injected environment, resolve() must return exactly that " +
                       "value -- this is the literal env var calyx-session's own daemon/CLI resolves its " +
                       "state root from, so the Swift side must consult the identical source, never " +
                       "FileManager.homeDirectoryForCurrentUser (which ignores HOME entirely)")
    }

    func test_resolve_fallsBackToNSHomeDirectory_whenHOMEAbsentFromEnvironment() {
        let resolver = SessionRootResolver(environment: [:])

        XCTAssertEqual(resolver.resolve(), NSHomeDirectory(),
                       "With no HOME key at all in the injected environment, resolve() must fall back to " +
                       "NSHomeDirectory(), not crash or return an empty/nil value")
    }

    func test_resolve_fallsBackToNSHomeDirectory_whenHOMEPresentButEmpty() {
        let resolver = SessionRootResolver(environment: ["HOME": ""])

        XCTAssertEqual(resolver.resolve(), NSHomeDirectory(),
                       "An empty-string HOME must be treated the same as an absent one and fall back to " +
                       "NSHomeDirectory(), mirroring SessionBinaryResolver's own present-but-empty-string " +
                       "handling for CALYX_SESSION_BIN")
    }
}
