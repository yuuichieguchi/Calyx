//
//  CalyxMCPServerPortLossRotationTests.swift
//  CalyxTests
//
//  Class CalyxMCPServerTokenRotationTests (spec C.4). The file name
//  differs from the class name only because of local tooling path rules.
//
//  Feature C slice 4a (G2, J4, C-D2, C-D14): CalyxMCPServer rotates its
//  token only on evidence -- when the previous port (`preferredPort`)
//  cannot be bound and the caller supplied `tokenIfPortLost`. V3-1: a
//  process can rebind its own just-closed port, so a failed bind of the
//  previous port means another process holds it.
//
//  The test plays "another process" by holding port P with a raw BSD
//  socket (socket/bind/listen on 127.0.0.1, kernel-assigned port, no
//  SO_REUSEADDR/SO_REUSEPORT) and passing P as `preferredPort`.
//

import Darwin
import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerTokenRotationTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var agentEndpointDir: String!
    /// The raw socket holding port `heldPort`; -1 once closed.
    private var holderFD: Int32 = -1
    private var heldPort = 0

    private let oldToken = "rotation-old-token"
    private let newToken = "rotation-new-token"

    override func setUp() async throws {
        try await super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
        try holdLoopbackPort()
    }

    override func tearDown() async throws {
        await server?.stopAndWait()
        server = nil
        releaseHeldPort()
        if let agentEndpointDir {
            try? FileManager.default.removeItem(atPath: agentEndpointDir)
        }
        agentEndpointDir = nil
        try await super.tearDown()
    }

    // MARK: - Port holder

    private struct HolderError: Error { let step: String; let code: Int32 }

    private func holdLoopbackPort() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HolderError(step: "socket", code: errno) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw HolderError(step: "bind", code: code)
        }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &len) }
        }
        guard named == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            throw HolderError(step: "getsockname/listen", code: code)
        }
        holderFD = fd
        heldPort = Int(UInt16(bigEndian: out.sin_port))
        XCTAssertNotEqual(heldPort, 0)
    }

    private func releaseHeldPort() {
        if holderFD >= 0 {
            close(holderFD)
            holderFD = -1
        }
    }

    // MARK: - (i) previous port lost + alternative supplied -> rotate

    func test_preferredPortHeldElsewhere_withTokenIfPortLost_bindsAnotherPortAndRotatesToken() async throws {
        try await server.start(token: oldToken, preferredPort: heldPort, tokenIfPortLost: newToken)

        XCTAssertNotEqual(server.port, heldPort, "P is held by another socket, so the scan must move on")
        XCTAssertNotEqual(server.port, 0)
        XCTAssertEqual(server.token, newToken, "J4: losing the previous port switches to tokenIfPortLost")
        XCTAssertTrue(server.lastStartRotatedToken)
        XCTAssertEqual(AgentEndpointFile.read(directory: agentEndpointDir),
                       AgentEndpointFile.Endpoint(port: server.port, token: newToken),
                       "agent-endpoint.json must publish the rotated token with the port actually bound")
    }

    // MARK: - (ii) previous port lost, no alternative -> keep token

    func test_preferredPortHeldElsewhere_withoutTokenIfPortLost_keepsToken() async throws {
        try await server.start(token: oldToken, preferredPort: heldPort, tokenIfPortLost: nil)

        XCTAssertNotEqual(server.port, heldPort)
        XCTAssertEqual(server.token, oldToken, "With no alternative there is nothing to rotate to")
        XCTAssertFalse(server.lastStartRotatedToken)
        XCTAssertEqual(AgentEndpointFile.read(directory: agentEndpointDir),
                       AgentEndpointFile.Endpoint(port: server.port, token: oldToken))
    }

    // MARK: - (iii) previous port free -> keep token even with an alternative

    func test_preferredPortFree_withTokenIfPortLost_bindsPreferredPortAndKeepsToken() async throws {
        let freePort = heldPort
        releaseHeldPort()

        try await server.start(token: oldToken, preferredPort: freePort, tokenIfPortLost: newToken)

        XCTAssertEqual(server.port, freePort, "A free previous port must be bound again")
        XCTAssertEqual(server.token, oldToken, "J4: binding the previous port keeps the previous token")
        XCTAssertFalse(server.lastStartRotatedToken)
        XCTAssertEqual(AgentEndpointFile.read(directory: agentEndpointDir),
                       AgentEndpointFile.Endpoint(port: freePort, token: oldToken))
    }

    // MARK: - lastStartRotatedToken describes the latest start only

    func test_lastStartRotatedToken_resetsOnNextNonRotatingStart() async throws {
        try await server.start(token: oldToken, preferredPort: heldPort, tokenIfPortLost: newToken)
        XCTAssertTrue(server.lastStartRotatedToken)

        try await server.start(token: "third-token", preferredPort: heldPort, tokenIfPortLost: nil)

        XCTAssertFalse(server.lastStartRotatedToken, "The flag describes the latest start only")
        XCTAssertEqual(server.token, "third-token")
    }

    // MARK: - lastStartAttemptedToken records the passed token

    func test_lastStartAttemptedToken_recordsPassedTokenEvenWhenRotated() async throws {
        try await server.start(token: "attempt-A", preferredPort: 0)
        XCTAssertEqual(server.lastStartAttemptedToken, "attempt-A")

        try await server.start(token: "attempt-B", preferredPort: heldPort, tokenIfPortLost: "attempt-C")

        XCTAssertEqual(server.lastStartAttemptedToken, "attempt-B",
                       "records the passed token, not the rotated one")
        XCTAssertEqual(server.token, "attempt-C")
    }

    // MARK: - (iv) token is assigned after the bind, not before

    /// Second start passes token B against a held P with alternative C.
    /// The token is decided in finishStart after the scan, so
    /// `server.token` goes from A straight to C and never shows B. A
    /// MainActor observer samples `server.token` at every suspension
    /// point of start() (the scan awaits each bind).
    func test_restartAgainstHeldPort_tokenGoesFromPreviousStraightToAlternative_neverExposesPassedToken() async throws {
        try await server.start(token: "token-A", preferredPort: 0)
        XCTAssertEqual(server.token, "token-A")

        let samples = TokenSamples()
        let server = self.server!
        let observer = Task { @MainActor in
            while !samples.finished {
                samples.observed.append(server.token)
                await Task.yield()
            }
        }

        try await server.start(token: "token-B", preferredPort: heldPort, tokenIfPortLost: "token-C")
        samples.finished = true
        await observer.value

        XCTAssertEqual(server.token, "token-C")
        XCTAssertTrue(server.lastStartRotatedToken)
        XCTAssertFalse(samples.observed.isEmpty, "the observer must sample at least once during start()")
        XCTAssertFalse(samples.observed.contains("token-B"),
                       "self.token must not take the passed token before the bind; observed \(Set(samples.observed))")
    }
}

/// MainActor-isolated sample buffer shared with the observer Task.
@MainActor
private final class TokenSamples {
    var observed: [String] = []
    var finished = false
}
