//
//  StdioMCPTransportTests.swift
//  CalyxTests
//
//  StdioMCPTransport layers NDJSONFramer on top of an MCPByteTransport
//  to conform to the unified MCPMessageTransport contract. The API
//  contract declares no test double for MCPByteTransport (section 14
//  lists only InMemoryMCPTransport, ManualMCPClock,
//  FakeElicitationPresenter, and similar named doubles for later
//  modules -- none for MCPByteTransport), so these tests exercise
//  StdioMCPTransport against the real MCPByteTransport conformer,
//  StdioLSPTransport, spawning /bin/cat and /bin/sh as in
//  StdioLSPTransportLifecycleTests.
//
//  stdio has no wire-level distinction between a request and a
//  notification (unlike HTTP's 202-vs-streamed-reply split), so send
//  frames every MCPOutboundKind identically. cancel(requestID:reason:)
//  DOES produce wire traffic here: stdio frames an explicit
//  notifications/cancelled message over the byte layer, unlike modern
//  HTTP, where cancellation is just stopping a stream task.
//

import XCTest
@testable import Calyx

final class StdioMCPTransportTests: XCTestCase {

    // MARK: - Framing: one JSON line per outbound kind, echoed back by cat

    func test_send_allOutboundKinds_frameAsOneJSONLine_echoedBackByCat() async throws {
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport)
        var iterator = transport.inbound.makeAsyncIterator()

        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        try await transport.send(request, kind: .request())
        let firstReceived = await iterator.next()
        guard case .frame(let firstData) = firstReceived else {
            return XCTFail("expected .frame, got \(String(describing: firstReceived))")
        }
        XCTAssertEqual(firstData, request)

        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#.utf8)
        try await transport.send(notification, kind: .notification)
        let secondReceived = await iterator.next()
        guard case .frame(let secondData) = secondReceived else {
            return XCTFail("expected .frame, got \(String(describing: secondReceived))")
        }
        XCTAssertEqual(secondData, notification)

        let response = Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8)
        try await transport.send(response, kind: .response)
        let thirdReceived = await iterator.next()
        guard case .frame(let thirdData) = thirdReceived else {
            return XCTFail("expected .frame, got \(String(describing: thirdReceived))")
        }
        XCTAssertEqual(thirdData, response)

        await transport.close()
    }

    // MARK: - cancel(requestID:reason:) frames notifications/cancelled

    func test_cancel_intRequestID_framesNotificationsCancelledOverTheByteLayer() async throws {
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport)
        var iterator = transport.inbound.makeAsyncIterator()

        await transport.cancel(requestID: .int(1), reason: "timed out")
        let received = await iterator.next()
        guard case .frame(let data) = received else {
            return XCTFail("expected .frame, got \(String(describing: received))")
        }
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["method"] as? String, "notifications/cancelled")
        let params = decoded?["params"] as? [String: Any]
        XCTAssertEqual(params?["requestId"] as? Int, 1)
        XCTAssertEqual(params?["reason"] as? String, "timed out")

        await transport.close()
    }

    func test_cancel_stringRequestID_framesNotificationsCancelledOverTheByteLayer() async throws {
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport)
        var iterator = transport.inbound.makeAsyncIterator()

        await transport.cancel(requestID: .string("req-42"), reason: nil)
        let received = await iterator.next()
        guard case .frame(let data) = received else {
            return XCTFail("expected .frame, got \(String(describing: received))")
        }
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(decoded?["method"] as? String, "notifications/cancelled")
        let params = decoded?["params"] as? [String: Any]
        XCTAssertEqual(params?["requestId"] as? String, "req-42")

        await transport.close()
    }

    // MARK: - close() uses closeGracefully, not close()

    func test_close_usesGracefulCloseOnByteLayer_neverSurfacesAsClosed() async throws {
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport)
        try await byteTransport.spawn()
        var iterator = transport.inbound.makeAsyncIterator()

        await transport.close()
        let received = await iterator.next()
        XCTAssertNil(received, "a caller-initiated close must never surface as .closed")

        // cat exits cleanly (status 0) on stdin EOF, which is exactly what
        // closeGracefully produces; a SIGTERM-only close() would instead
        // report .signaled, discriminating the two code paths.
        let exit = await byteTransport.waitForExit()
        XCTAssertEqual(exit, .exited(0))
    }

    // MARK: - send/cancel after close

    func test_send_afterClose_throwsTransportClosed() async {
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport)
        await transport.close()
        do {
            try await transport.send(Data("x".utf8), kind: .request())
            XCTFail("expected send to throw after close()")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("expected MCPTransportError.closed, got \(error)")
        }
    }

    func test_cancel_afterClose_isANoOp() async {
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport)
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.close()
        let afterClose = await iterator.next()
        XCTAssertNil(afterClose)

        // Must return promptly without throwing or producing wire
        // traffic once the transport is closed.
        await transport.cancel(requestID: .int(1), reason: "too late")
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    // MARK: - Framer overflow surfaces as .error, then closes the transport

    func test_unterminatedLineExceedingMaxLineBytes_surfacesAsErrorThenClosesTransport() async {
        // Inject a small cap so the test feeds a short unterminated line
        // instead of piping a real 64 MiB payload through a subprocess.
        let cap = 64
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport, maxLineBytes: cap)
        var iterator = transport.inbound.makeAsyncIterator()
        try? await byteTransport.spawn()
        try? await byteTransport.send(Data(repeating: 0x61, count: cap + 1)) // no trailing \n

        let received = await iterator.next()
        guard case .error(let signal) = received else {
            return XCTFail("expected .error, got \(String(describing: received))")
        }
        XCTAssertNil(signal.httpStatus, "stdio transport errors never carry an HTTP status")
        XCTAssertFalse(signal.message.isEmpty)

        // The contract closes the byte layer through the same procedure
        // as close() after a framer overflow, so inbound finishes
        // directly rather than yielding .closed.
        let next = await iterator.next()
        XCTAssertNil(next, "a framer overflow must close through the close() path, never yielding .closed")
    }

    func test_validFrameInSameReadAsOversizedTail_isDeliveredBeforeErrorAndClose() async throws {
        let cap = 64
        let byteTransport = StdioLSPTransport(executable: "/bin/cat")
        let transport = StdioMCPTransport(byteTransport: byteTransport, maxLineBytes: cap)
        var iterator = transport.inbound.makeAsyncIterator()
        try await byteTransport.spawn()

        let frame = Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8)
        try await byteTransport.send(frame + Data([0x0A]) + Data(repeating: 0x61, count: cap + 1)) // no trailing \n

        let first = await iterator.next()
        guard case .frame(let data) = first else {
            return XCTFail("expected .frame, got \(String(describing: first))")
        }
        XCTAssertEqual(data, frame)

        let second = await iterator.next()
        guard case .error(let signal) = second else {
            return XCTFail("expected .error, got \(String(describing: second))")
        }
        XCTAssertNil(signal.httpStatus)

        let third = await iterator.next()
        XCTAssertNil(third, "a framer overflow must close through the close() path, never yielding .closed")
    }

    // MARK: - Unsolicited exit surfaces as .closed with exit status and stderr tail

    func test_unsolicitedChildExit_yieldsClosedWithExitStatusAndStderrTail() async {
        let byteTransport = StdioLSPTransport(
            executable: "/bin/sh",
            arguments: ["-c", "printf 'fatal: config not found' 1>&2; sleep 0.2; exit 3"]
        )
        let transport = StdioMCPTransport(byteTransport: byteTransport)
        var iterator = transport.inbound.makeAsyncIterator()

        try? await byteTransport.spawn()
        let received = await iterator.next()
        guard case .closed(let reason, let exit, let stderrTail) = received else {
            return XCTFail("expected .closed, got \(String(describing: received))")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(exit, .exited(3))
        XCTAssertEqual(stderrTail, Data("fatal: config not found".utf8))

        let next = await iterator.next()
        XCTAssertNil(next)
    }
}
