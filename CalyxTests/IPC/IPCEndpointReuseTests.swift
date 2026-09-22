//
//  IPCEndpointReuseTests.swift
//  CalyxTests
//
//  Covers IPCEndpointReuse, the pure decision behind endpoint reuse
//  across a restart: a persistent-session CLI already holds an old
//  token and URL (from a previously published agent-endpoint.json), so
//  a fresh start should keep both working when possible. Token and port
//  are decided INDEPENDENTLY of each other -- an empty on-disk token
//  must not disqualify reusing a still-valid on-disk port, and a port of
//  0 (never a real bind) must not disqualify reusing a still-valid
//  on-disk token. The caller (IPCServerControlling's live adapter) reads
//  AgentEndpointFile.read(directory:) once and hands the result plus a
//  freshly generated token to decide(existing:freshToken:).
//
//  Coverage:
//  - no persisted endpoint: fresh token, default port (41830)
//  - persisted endpoint present: its token AND its port are both reused
//  - persisted endpoint with an empty token: fresh token, but the port
//    is still reused (a never-started server's default token must never
//    be treated as reusable, mirroring AgentEndpointFile.remove's own
//    empty-token guard)
//  - persisted endpoint with port 0: port falls back to the default
//    regardless of the fresh token, independently of the token decision
//

import XCTest
@testable import Calyx

final class IPCEndpointReuseTests: XCTestCase {

    private let defaultPort = 41830

    func test_noExistingEndpoint_usesFreshTokenAndDefaultPort() {
        let decision = IPCEndpointReuse.decide(existing: nil, freshToken: "fresh-token-1")

        XCTAssertEqual(decision.token, "fresh-token-1",
                       "With no persisted endpoint there is nothing to reuse, so the fresh token must be used")
        XCTAssertEqual(decision.port, defaultPort,
                       "With no persisted endpoint there is nothing to reuse, so the default port must be used")
    }

    func test_existingEndpoint_reusesBothTokenAndPort() {
        let existing = AgentEndpointFile.Endpoint(port: 41837, token: "persisted-token-2")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: "fresh-token-2")

        XCTAssertEqual(decision.token, "persisted-token-2",
                       "A valid persisted token must be reused so already-connected CLIs stay authenticated")
        XCTAssertEqual(decision.port, 41837,
                       "A valid persisted port must be reused so already-connected CLIs keep the same URL")
    }

    func test_existingEndpointWithEmptyToken_usesFreshTokenButStillReusesPort() {
        let existing = AgentEndpointFile.Endpoint(port: 41838, token: "")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: "fresh-token-3")

        XCTAssertEqual(decision.token, "fresh-token-3",
                       "An empty on-disk token can never be a real published token, so a fresh one must be generated")
        XCTAssertEqual(decision.port, 41838,
                       "The empty token must not disqualify reusing the still-valid on-disk port -- token and " +
                       "port are decided independently")
    }

    func test_existingEndpointWithPortZero_fallsBackToDefaultPort_regardlessOfToken() {
        let existing = AgentEndpointFile.Endpoint(port: 0, token: "persisted-token-4")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: "fresh-token-4")

        XCTAssertEqual(decision.token, "persisted-token-4",
                       "Port 0 must not disqualify reusing a still-valid on-disk token -- token and port are " +
                       "decided independently")
        XCTAssertEqual(decision.port, defaultPort,
                       "Port 0 is never a real bind (AgentEndpointFile.remove treats an unset port the same " +
                       "way), so it must fall back to the default rather than being reused literally")
    }
}
