//
//  InMemoryMCPTransportTests.swift
//  CalyxTests
//
//  Contract tests for the InMemoryMCPTransport test double: capture via
//  sentMessages() / sentFrames(), injection via simulateServerMessage /
//  simulateTransportError, crash simulation via simulateCrash()
//  (distinct from the graceful, caller-initiated close()), cancel
//  (requestID:reason:) recording, and inbound stream termination.
//  Mirrors LSPClientTests' coverage of InMemoryLSPTransport.
//

import XCTest
@testable import Calyx

final class InMemoryMCPTransportTests: XCTestCase {

    func test_send_capturesIntoSentMessages() async throws {
        let transport = InMemoryMCPTransport()
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        try await transport.send(payload, kind: .request())
        let sent = await transport.sentMessages()
        XCTAssertEqual(sent, [payload])
    }

    func test_send_recordsKindAlongsidePayload() async throws {
        let transport = InMemoryMCPTransport()
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#.utf8)
        let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#.utf8)
        let response = Data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#.utf8)
        try await transport.send(request, kind: .request())
        try await transport.send(notification, kind: .notification)
        try await transport.send(response, kind: .response)

        let frames = await transport.sentFrames()
        XCTAssertEqual(frames.map(\.data), [request, notification, response])
        XCTAssertEqual(frames[0].kind, .request())
        XCTAssertEqual(frames[1].kind, .notification)
        XCTAssertEqual(frames[2].kind, .response)
    }

    func test_send_afterClose_throwsTransportClosed() async {
        let transport = InMemoryMCPTransport()
        await transport.close()
        do {
            try await transport.send(Data("x".utf8), kind: .request())
            XCTFail("expected send to throw after close()")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("expected MCPTransportError.closed, got \(error)")
        }
        let sent = await transport.sentMessages()
        XCTAssertTrue(sent.isEmpty, "a message sent after close() must not be captured")
    }

    func test_send_afterSimulateCrash_throwsTransportClosed() async {
        let transport = InMemoryMCPTransport()
        await transport.simulateCrash(reason: "child exited unexpectedly")
        do {
            try await transport.send(Data("x".utf8), kind: .request())
            XCTFail("expected send to throw after a simulated crash")
        } catch let error as MCPTransportError {
            XCTAssertEqual(error, .closed)
        } catch {
            XCTFail("expected MCPTransportError.closed, got \(error)")
        }
    }

    func test_simulateServerMessage_deliversThroughInboundStreamAsFrame() async {
        let transport = InMemoryMCPTransport()
        var iterator = transport.inbound.makeAsyncIterator()
        let payload = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        await transport.simulateServerMessage(payload)
        let received = await iterator.next()
        guard case .frame(let data) = received else {
            return XCTFail("expected .frame, got \(String(describing: received))")
        }
        XCTAssertEqual(data, payload)
    }

    func test_simulateTransportError_deliversThroughInboundStream_withoutClosing() async {
        let transport = InMemoryMCPTransport()
        var iterator = transport.inbound.makeAsyncIterator()
        let signal = MCPTransportSignal(httpStatus: nil, message: "malformed frame")
        await transport.simulateTransportError(signal)
        let received = await iterator.next()
        guard case .error(let received) = received else {
            return XCTFail("expected .error, got \(String(describing: received))")
        }
        XCTAssertEqual(received, signal)

        // The transport is still open after a transport error alone: a
        // subsequent server message still delivers as .frame.
        let followUp = Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8)
        await transport.simulateServerMessage(followUp)
        let next = await iterator.next()
        guard case .frame(let data) = next else {
            return XCTFail("expected .frame after a transport error, got \(String(describing: next))")
        }
        XCTAssertEqual(data, followUp)
    }

    func test_simulateCrash_deliversClosedWithReason_andClosesTheTransport() async {
        let transport = InMemoryMCPTransport()
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.simulateCrash(reason: "child exited unexpectedly")
        let received = await iterator.next()
        guard case .closed(let reason, let exit, let stderrTail) = received else {
            return XCTFail("expected .closed, got \(String(describing: received))")
        }
        XCTAssertEqual(reason, "child exited unexpectedly")
        XCTAssertNil(exit)
        XCTAssertNil(stderrTail)

        let next = await iterator.next()
        XCTAssertNil(next, "inbound must finish after a crash")
    }

    func test_simulateCrash_usesDefaultReason_whenNoneGiven() async {
        let transport = InMemoryMCPTransport()
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.simulateCrash()
        let received = await iterator.next()
        guard case .closed(let reason, _, _) = received else {
            return XCTFail("expected .closed, got \(String(describing: received))")
        }
        XCTAssertEqual(reason, "child exited")
    }

    func test_close_finishesInboundStream_withoutYieldingClosed() async {
        let transport = InMemoryMCPTransport()
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.close()
        let received = await iterator.next()
        XCTAssertNil(received, "a graceful close must finish inbound directly, never yielding .closed -- that element is reserved for an unsolicited crash")
    }

    func test_close_afterSimulateCrash_doesNotEmitASecondElement() async {
        // A permitted close arriving after an already-observed crash must
        // not resurrect the stream or trap on a double finish().
        let transport = InMemoryMCPTransport()
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.simulateCrash(reason: "child exited unexpectedly")
        _ = await iterator.next() // consume the .closed element
        await transport.close()
        let next = await iterator.next()
        XCTAssertNil(next)
    }

    func test_simulateCrash_afterClose_isSuppressed() async {
        // A permitted close must not be mistaken for a crash: once close()
        // has run, a later simulateCrash() must not yield .closed.
        let transport = InMemoryMCPTransport()
        await transport.close()
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.simulateCrash(reason: "too late")
        let received = await iterator.next()
        XCTAssertNil(received)
    }

    func test_simulateServerMessage_afterClose_isDropped() async {
        let transport = InMemoryMCPTransport()
        await transport.close()
        var iterator = transport.inbound.makeAsyncIterator()
        await transport.simulateServerMessage(Data("late".utf8))
        let received = await iterator.next()
        XCTAssertNil(received)
    }

    func test_cancel_recordsTheRequestID() async {
        let transport = InMemoryMCPTransport()
        await transport.cancel(requestID: .int(7), reason: "user cancelled")
        let cancelled = await transport.cancelledRequestIDs()
        XCTAssertEqual(cancelled, [.int(7)])
    }

    func test_cancel_supportsStringRequestIDs() async {
        let transport = InMemoryMCPTransport()
        await transport.cancel(requestID: .string("req-42"), reason: nil)
        let cancelled = await transport.cancelledRequestIDs()
        XCTAssertEqual(cancelled, [.string("req-42")])
    }

    func test_cancel_afterClose_isANoOp() async {
        let transport = InMemoryMCPTransport()
        await transport.close()
        await transport.cancel(requestID: .int(1), reason: "too late")
        let cancelled = await transport.cancelledRequestIDs()
        XCTAssertTrue(cancelled.isEmpty, "cancel(requestID:reason:) after close() must not record anything")
    }
}
