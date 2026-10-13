//
//  LoopbackOneShotResponder.swift
//  CalyxTests
//
//  A one-shot fake HTTP server for the hook pipeline tests. It stands on
//  the port an agent-endpoint.json names in place of Calyx, the way a
//  process that took over a stale endpoint's port would, and answers one
//  request with a body the test chooses. Shared by
//  IPCWakeHookPipelineIntegrationTests (an oversized body) and
//  ApprovalHookPipelineIntegrationTests (an unsigned allow body and an
//  over-cap signed body).
//

import Darwin
import Foundation

/// A one-shot HTTP responder on a loopback port picked by the kernel: it
/// accepts one connection, reads the request head, answers 200 with a
/// Content-Length and `body`, and closes. The accepted socket has
/// SO_NOSIGPIPE, so a client that hangs up early (curl stopping at
/// `--max-filesize`) ends the write with an error instead of a SIGPIPE
/// that would kill the test host. Every wait has a deadline.
final class LoopbackOneShotResponder: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let body: Data
    private let served = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var acceptedRequest = false
    private var written = 0

    /// Bytes of the response (head and body) the client accepted before
    /// it hung up or the response ended.
    var bytesWritten: Int { lock.withLock { written } }

    init(body: Data) throws {
        self.body = body
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.listenFD = fd
        self.port = Int(UInt16(bigEndian: addr.sin_port))
    }

    func serveOnce() {
        DispatchQueue.global().async { [self] in
            defer {
                close(listenFD)
                served.signal()
            }
            var pending = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&pending, 1, 15_000) == 1 else { return }
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var head = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { return }
                head.append(contentsOf: buffer[0..<count])
            }
            lock.withLock { acceptedRequest = true }
            var response = Data(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8
            )
            response.append(body)
            response.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                // A client that stops reading must not hold this loop
                // forever: each write gives up after SO_SNDTIMEO (5 s)
                // and the whole body after 10 s.
                let writeDeadline = Date().addingTimeInterval(10)
                var offset = 0
                while offset < raw.count, Date() < writeDeadline {
                    let written = write(client, base + offset, raw.count - offset)
                    if written <= 0 { return }
                    offset += written
                    lock.withLock { self.written = offset }
                }
            }
        }
    }

    /// Whether a request head was read and answered within `timeout`
    /// seconds. Waits off the main actor.
    func waitUntilServed(timeout: TimeInterval) async -> Bool {
        let finished = await Task.detached { [served] in
            Self.blockingWait(served, timeout: timeout)
        }.value
        return finished && lock.withLock { acceptedRequest }
    }

    /// A synchronous wrapper, so the semaphore wait happens outside any
    /// async context (it runs on the detached Task's thread).
    private static func blockingWait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}
