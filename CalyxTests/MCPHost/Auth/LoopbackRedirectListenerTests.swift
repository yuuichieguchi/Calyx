//
//  LoopbackRedirectListenerTests.swift
//  CalyxTests
//
//  API contract section 6.12. `LoopbackRedirectListener` binds a
//  loopback HTTP listener for exactly one OAuth `/callback` redirect:
//  one shot, exact path match, rejects a wrong `state`, has no timer
//  (ends only on completion, `cancel(reason:)`, or app exit), and fails
//  a busy fixed port with `.portBusy(41890)`.
//
//    struct MCPOAuthCallback: Sendable, Equatable { let code: String; let state: String; let iss: String? }
//    enum MCPOAuthRedirectListenerError: Error, Sendable, Equatable {
//        case stateMismatch
//        case portBusy(Int)
//        case cancelled(reason: String)   // thrown by waitForCallback() after cancel(reason:)
//    }
//    actor LoopbackRedirectListener {
//        init(config: MCPOAuthRedirectConfig, expectedState: String, path: String = "/callback")
//        func start() async throws -> (port: Int, host: String)
//        func waitForCallback() async throws -> MCPOAuthCallback
//        func cancel(reason: String) async
//    }
//
//  This actor binds a real loopback NWListener (same style as
//  `CalyxMCPServerLoopbackBugSpecTests`), so these tests use real
//  127.0.0.1 sockets, never the external network.
//

import XCTest
import Network
@testable import Calyx

final class LoopbackRedirectListenerTests: XCTestCase {

    /// GETs `http://127.0.0.1:<port><path>?<query>` using a short-lived
    /// URLSession, discarding the response body -- just enough to
    /// trigger the listener's callback handling from a real socket.
    private func fireCallback(port: Int, path: String, query: String) async {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = path
        components.percentEncodedQuery = query
        _ = try? await URLSession.shared.data(from: components.url!)
    }

    // MARK: - One shot, exact path match, happy path

    func test_start_thenCallback_matchingState_returnsCodeAndState() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .random), expectedState: "state-abc")
        let (port, host) = try await listener.start()
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertGreaterThan(port, 0)

        async let callback = listener.waitForCallback()
        await fireCallback(port: port, path: "/callback", query: "code=auth-code-1&state=state-abc")

        let result = try await callback
        XCTAssertEqual(result.code, "auth-code-1")
        XCTAssertEqual(result.state, "state-abc")
        XCTAssertNil(result.iss)
    }

    func test_callback_includesIssWhenPresent() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .random), expectedState: "state-abc")
        let (port, _) = try await listener.start()

        async let callback = listener.waitForCallback()
        await fireCallback(port: port, path: "/callback", query: "code=auth-code-1&state=state-abc&iss=https%3A%2F%2Fauth.example.com")

        let result = try await callback
        XCTAssertEqual(result.iss, "https://auth.example.com")
    }

    // MARK: - .localhost host, per MCPOAuthRedirectConfig

    func test_start_localhostConfig_resolvesToLocalhostHostString() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .localhost, port: .random), expectedState: "state-abc")
        let (_, host) = try await listener.start()
        XCTAssertEqual(host, "localhost")
    }

    // MARK: - Exact path match; wrong path is ignored, does not consume the wait

    func test_callback_wrongPath_isIgnored_correctPathStillCompletesTheWait() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .random), expectedState: "state-abc")
        let (port, _) = try await listener.start()

        async let callback = listener.waitForCallback()
        await fireCallback(port: port, path: "/not-the-callback-path", query: "code=x&state=state-abc")
        await fireCallback(port: port, path: "/callback", query: "code=auth-code-2&state=state-abc")

        let result = try await callback
        XCTAssertEqual(result.code, "auth-code-2")
    }

    // MARK: - Rejects wrong state

    func test_callback_wrongState_throwsStateMismatch() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .random), expectedState: "state-abc")
        let (port, _) = try await listener.start()

        async let callback = listener.waitForCallback()
        await fireCallback(port: port, path: "/callback", query: "code=x&state=wrong-state")

        do {
            _ = try await callback
            XCTFail("expected stateMismatch")
        } catch let error as MCPOAuthRedirectListenerError {
            XCTAssertEqual(error, .stateMismatch)
        }
    }

    // MARK: - Error redirect ends the wait with .authorizationServerError

    func test_callback_errorInsteadOfCode_throwsAuthorizationServerError() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .random), expectedState: "state-abc")
        let (port, _) = try await listener.start()

        async let callback = listener.waitForCallback()
        await fireCallback(port: port, path: "/callback", query: "error=access_denied&error_description=User%20denied&state=state-abc")

        do {
            _ = try await callback
            XCTFail("expected authorizationServerError")
        } catch let error as MCPOAuthRedirectListenerError {
            XCTAssertEqual(error, .authorizationServerError(error: "access_denied", description: "User denied"))
        }
    }

    // MARK: - No timer: the wait does not resolve on its own within a short real interval

    func test_waitForCallback_withoutACallbackOrCancel_doesNotResolveWithinAShortInterval() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .random), expectedState: "state-abc")
        _ = try await listener.start()

        let listenerCompleted = Locked(false)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await listener.waitForCallback()
                listenerCompleted.withLock { $0 = true }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertFalse(listenerCompleted.withLock { $0 }, "no timer should have completed the wait on its own")
            await listener.cancel(reason: "test cleanup")
            await group.next()
        }
    }

    // MARK: - cancel(reason:) unblocks a pending wait with .cancelled(reason:)

    func test_cancel_unblocksAPendingWaitForCallback_withCancelledReason() async throws {
        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .random), expectedState: "state-abc")
        _ = try await listener.start()

        let capturedError = Locked<(any Error)?>(nil)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    _ = try await listener.waitForCallback()
                } catch {
                    capturedError.withLock { $0 = error }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            await listener.cancel(reason: "user cancelled sign-in")
            await group.next()
            group.cancelAll()
        }

        let error = capturedError.withLock { $0 }
        XCTAssertEqual(error as? MCPOAuthRedirectListenerError, .cancelled(reason: "user cancelled sign-in"))
    }

    // MARK: - Busy fixed port fails with a reason

    func test_start_fixedPortAlreadyBound_throwsPortBusy() async throws {
        let preBound = try await preBindLoopbackPort(port: UInt16(MCPOAuthRedirectConfig.calyxFixedPort))
        defer { preBound.cancel() }

        let listener = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .calyxFixed), expectedState: "state-abc")
        do {
            _ = try await listener.start()
            XCTFail("expected portBusy")
        } catch let error as MCPOAuthRedirectListenerError {
            XCTAssertEqual(error, .portBusy(MCPOAuthRedirectConfig.calyxFixedPort))
        }
    }

    // MARK: - Fixed port is released by cancel(reason:), so a later listener can bind it

    func test_cancel_releasesFixedPort_soASecondListenerCanBindIt() async throws {
        let first = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .calyxFixed), expectedState: "state-1")
        _ = try await first.start()
        await first.cancel(reason: "replaced by a new sign-in")

        let second = LoopbackRedirectListener(config: MCPOAuthRedirectConfig(host: .loopback, port: .calyxFixed), expectedState: "state-2")
        let (port, _) = try await second.start()
        XCTAssertEqual(port, MCPOAuthRedirectConfig.calyxFixedPort)
        await second.cancel(reason: "test cleanup")
    }

    /// Binds a real loopback listener on the given port and waits for
    /// it to become ready, so `LoopbackRedirectListener.start()` sees
    /// the port as taken.
    private func preBindLoopbackPort(port: UInt16) async throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: params)
        // NWListener fails start() with EINVAL when no newConnectionHandler is set.
        listener.newConnectionHandler = { $0.cancel() }
        let expectation = XCTestExpectation(description: "bound")
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                expectation.fulfill()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [expectation], timeout: 5)
        return listener
    }
}
