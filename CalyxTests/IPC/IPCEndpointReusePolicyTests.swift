//
//  IPCEndpointReusePolicyTests.swift
//  CalyxTests
//
//  Feature C slice 4a (G2, J4, C-D2): the rotation policy of
//  IPCEndpointReuse. Under `.onLostPort` (the default) a reused token
//  comes with `tokenIfPortLost == freshToken`, the token the server
//  switches to only when it cannot bind the previous port; a fresh token
//  carries no alternative. Under `.everyStart` every start uses the fresh
//  token. The port decision is the same under both policies, and token
//  and port stay independent of each other.
//
//  Kept apart from IPCEndpointReuseTests.swift (as an extension of the
//  same class) so the original file keeps compiling before `Policy` and
//  `tokenIfPortLost` exist.
//

import XCTest
@testable import Calyx

extension IPCEndpointReuseTests {

    private var fresh: String { "fresh-token-p" }

    func test_defaultPolicy_isOnLostPort() {
        XCTAssertEqual(IPCEndpointReuse.policy, .onLostPort, "C-D2: the shipped policy is .onLostPort")
    }

    func test_decide_withoutPolicyArgument_behavesAsOnLostPort() {
        let existing = AgentEndpointFile.Endpoint(port: 41833, token: "old-token")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: "old-token", port: 41833, tokenIfPortLost: fresh))
    }

    // MARK: - .onLostPort

    func test_onLostPort_noExisting_freshTokenDefaultPortNoAlternative() {
        let decision = IPCEndpointReuse.decide(existing: nil, freshToken: fresh, policy: .onLostPort)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41830, tokenIfPortLost: nil))
    }

    func test_onLostPort_emptyToken_nonZeroPort_freshTokenReusedPortNoAlternative() {
        let existing = AgentEndpointFile.Endpoint(port: 41834, token: "")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .onLostPort)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41834, tokenIfPortLost: nil),
                       "A fresh token is already new; there is nothing to rotate to")
    }

    func test_onLostPort_emptyToken_zeroPort_freshTokenDefaultPortNoAlternative() {
        let existing = AgentEndpointFile.Endpoint(port: 0, token: "")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .onLostPort)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41830, tokenIfPortLost: nil))
    }

    func test_onLostPort_reusedToken_nonZeroPort_alternativeIsFreshToken() {
        let existing = AgentEndpointFile.Endpoint(port: 41836, token: "old-token")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .onLostPort)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: "old-token", port: 41836, tokenIfPortLost: fresh))
    }

    func test_onLostPort_reusedToken_zeroPort_alternativeIsFreshTokenPortDefault() {
        let existing = AgentEndpointFile.Endpoint(port: 0, token: "old-token")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .onLostPort)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: "old-token", port: 41830, tokenIfPortLost: fresh),
                       "Token reuse and its alternative do not depend on the port decision")
    }

    // MARK: - .everyStart

    func test_everyStart_noExisting_freshTokenDefaultPortNoAlternative() {
        let decision = IPCEndpointReuse.decide(existing: nil, freshToken: fresh, policy: .everyStart)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41830, tokenIfPortLost: nil))
    }

    func test_everyStart_emptyToken_nonZeroPort_freshTokenReusedPort() {
        let existing = AgentEndpointFile.Endpoint(port: 41834, token: "")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .everyStart)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41834, tokenIfPortLost: nil))
    }

    func test_everyStart_emptyToken_zeroPort_freshTokenDefaultPort() {
        let existing = AgentEndpointFile.Endpoint(port: 0, token: "")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .everyStart)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41830, tokenIfPortLost: nil))
    }

    func test_everyStart_existingToken_nonZeroPort_freshTokenButPortStillReused() {
        let existing = AgentEndpointFile.Endpoint(port: 41836, token: "old-token")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .everyStart)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41836, tokenIfPortLost: nil),
                       "J4: .everyStart always uses a new token; port reuse is unchanged by the policy")
    }

    func test_everyStart_existingToken_zeroPort_freshTokenDefaultPort() {
        let existing = AgentEndpointFile.Endpoint(port: 0, token: "old-token")

        let decision = IPCEndpointReuse.decide(existing: existing, freshToken: fresh, policy: .everyStart)

        XCTAssertEqual(decision, IPCEndpointReuse.Decision(token: fresh, port: 41830, tokenIfPortLost: nil))
    }
}
