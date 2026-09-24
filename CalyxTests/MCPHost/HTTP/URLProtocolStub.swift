//
//  URLProtocolStub.swift
//  CalyxTests
//
//  In-process URLProtocol stub for MCPHost HTTP tests. Registered per
//  URLSessionConfiguration (never via the process-global
//  URLProtocol.registerClass), so it cannot interfere with other test
//  suites running in the same process. Never touches the real network.
//
//  Usage:
//    let recorder = MCPHTTPStubRecorder()
//    let session = URLSession(configuration: MCPHTTPStubProtocol.configuration(recorder: recorder))
//    recorder.enqueue { request in .json(status: 200, body: ...) }
//    // exercise code that uses `session`
//    XCTAssertEqual(recorder.requests.count, 1)
//

import Foundation

/// One recorded outgoing request, captured before URLSession applies any
/// of its own defaults, plus a synchronous body snapshot (stub requests
/// never stream an unbounded body in these tests).
struct MCPHTTPRecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let bodyData: Data?
}

/// A scripted response. `.sse` delivers each chunk as its own
/// `didLoad` call without ever calling `didFinishLoading`, so tests can
/// observe cancellation (`stopLoading`) on a still-open stream.
enum MCPHTTPStubResponse: Sendable {
    case json(status: Int, headers: [String: String] = [:], body: Data)
    case empty(status: Int, headers: [String: String] = [:])
    /// Delivered as separate `didLoad` chunks; stream is left open
    /// (never calls `didFinishLoading`) unless `thenClose` is true.
    case sse(status: Int, headers: [String: String] = [:], chunks: [Data], thenClose: Bool)
    /// Delivers `first`, then blocks the loading thread until `gate` is
    /// opened, then delivers `second` and finishes. URLSession coalesces
    /// chunks loaded back to back into one delegate callback, so a test
    /// that observes chunk boundaries opens the gate only after it has
    /// received `first`.
    case gatedSSE(status: Int, first: Data, second: Data, gate: MCPHTTPStubGate)
    case redirect(status: Int, location: String)
    case failure(NSError)
}

/// A one-shot gate the test opens and the stub's loading thread waits on.
/// The wait is bounded so a failing test cannot hang the suite.
final class MCPHTTPStubGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func open() {
        semaphore.signal()
    }

    /// Returns false when the gate was not opened within `timeout`.
    func wait(timeout: TimeInterval = 5) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

/// Thread-safe recorder + response queue shared between the test and the
/// `URLProtocol` subclass. Swift 6 safe: all mutable state lives behind
/// a lock, never behind `nonisolated(unsafe)` alone.
final class MCPHTTPStubRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [MCPHTTPRecordedRequest] = []
    private var handlers: [(MCPHTTPRecordedRequest) -> MCPHTTPStubResponse] = []
    private var _stopLoadingCount = 0
    private var _openTasks: [MCPHTTPStubProtocol] = []

    var requests: [MCPHTTPRecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var stopLoadingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopLoadingCount
    }

    /// Enqueue a response handler. Handlers are consumed in FIFO order,
    /// one per request; the last enqueued handler repeats if the queue
    /// is exhausted so simple single-response tests don't need to think
    /// about repetition.
    func enqueue(_ handler: @escaping (MCPHTTPRecordedRequest) -> MCPHTTPStubResponse) {
        lock.lock(); defer { lock.unlock() }
        handlers.append(handler)
    }

    func record(_ request: MCPHTTPRecordedRequest, task: MCPHTTPStubProtocol) -> MCPHTTPStubResponse {
        lock.lock()
        _requests.append(request)
        let handler = handlers.isEmpty ? nil : (handlers.count > 1 ? handlers.removeFirst() : handlers[0])
        _openTasks.append(task)
        lock.unlock()
        guard let handler else {
            return .empty(status: 500)
        }
        return handler(request)
    }

    func recordStopLoading() {
        lock.lock(); defer { lock.unlock() }
        _stopLoadingCount += 1
    }
}

final class MCPHTTPStubProtocol: URLProtocol, @unchecked Sendable {

    static func configuration(recorder: MCPHTTPStubRecorder) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPHTTPStubProtocol.self]
        Self.pendingRecorder.withLock { $0 = recorder }
        return config
    }

    /// URLSession does not let a custom `URLProtocol` read configuration
    /// out-of-band, so the recorder for the *next* request stream is
    /// threaded through this process-wide slot, guarded by a lock. Each
    /// test uses its own `MCPHTTPStubRecorder` instance and its own
    /// `URLSession`, and requests within one session are handled
    /// serially per connection in these tests, so this is safe in
    /// practice for the suite's usage pattern (never used to route
    /// concurrent, cross-test requests).
    private static let pendingRecorder = Locked<MCPHTTPStubRecorder?>(nil)

    private var currentRecorder: MCPHTTPStubRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorder = Self.pendingRecorder.withLock { $0 }
        currentRecorder = recorder
        guard let recorder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MCPHTTPStubProtocol", code: -1))
            return
        }

        var headers: [String: String] = [:]
        request.allHTTPHeaderFields?.forEach { headers[$0.key] = $0.value }
        let bodyData = request.httpBody ?? bodyDataFromStream(request.httpBodyStream)
        let recorded = MCPHTTPRecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: headers,
            bodyData: bodyData
        )

        let response = recorder.record(recorded, task: self)
        deliver(response)
    }

    override func stopLoading() {
        currentRecorder?.recordStopLoading()
    }

    private func bodyDataFromStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private func deliver(_ response: MCPHTTPStubResponse) {
        switch response {
        case .json(let status, let headers, let body):
            var allHeaders = headers
            allHeaders["Content-Type"] = allHeaders["Content-Type"] ?? "application/json"
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: allHeaders)!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)

        case .empty(let status, let headers):
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)

        case .sse(let status, let headers, let chunks, let thenClose):
            var allHeaders = headers
            allHeaders["Content-Type"] = allHeaders["Content-Type"] ?? "text/event-stream"
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: allHeaders)!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            if thenClose {
                client?.urlProtocolDidFinishLoading(self)
            }

        case .gatedSSE(let status, let first, let second, let gate):
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: first)
            guard gate.wait() else {
                client?.urlProtocol(self, didFailWithError: NSError(domain: "MCPHTTPStubProtocol", code: -2))
                return
            }
            client?.urlProtocol(self, didLoad: second)
            client?.urlProtocolDidFinishLoading(self)

        case .redirect(let status, let location):
            let httpResponse = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)

        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

/// Minimal lock-guarded box; avoids pulling in an external dependency
/// just for this test helper.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
