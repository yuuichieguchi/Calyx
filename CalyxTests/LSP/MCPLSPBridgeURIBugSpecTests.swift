//
//  MCPLSPBridgeURIBugSpecTests.swift
//  Calyx
//
//  RED-phase TDD spec for two MCPLSPBridge URI-handling defects:
//
//    1. `ensureFileOpen(session:uri:)` hardcodes a `hasPrefix("file://")`
//       guard and silently no-ops for non-file URI schemes. The spec
//       contract is that for non-`file://` URIs (e.g. `jdt://…` for
//       JDT.LS class-file hovers, `vscode-notebook-cell://…` for notebook
//       cells, or `untitled:…` for unsaved buffers) the bridge must:
//         (a) NOT throw — the caller's request should still dispatch.
//         (b) NOT call `textDocument/didOpen` — the server is responsible
//             for resolving non-file URIs itself; we MUST NOT attempt to
//             read the path off disk.
//
//    2. `normalizeFileURI(_:)` rejects `file://<host>/<path>` URIs whose
//       host component is non-empty. RFC 8089 §3 explicitly allows the
//       `file://<host>/<path>` form (used by SMB-mounted workspaces,
//       Windows UNC paths, etc.). The spec contract is that a URI like
//       `file://server/share/path/main.ts` parses successfully — the
//       returned `fileURL` is non-nil and the returned `uri` preserves
//       the host component (percent-encoded).
//
//  Both tests are written to fail against current `MCPLSPBridge`
//  behaviour; the matching GREEN pass belongs to the Swift specialist.
//

import XCTest
@testable import Calyx

// MARK: - file-private helpers

/// Detach a [String: Any] dictionary from its underlying buffer by
/// round-tripping through JSON. Used by the notification capture path
/// so the `sending` reads don't bleed actor isolation.
fileprivate func freshDictURIBug(fromJSON data: Data) -> sending [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

/// Build a `Content-Length:`-framed LSP message body.
fileprivate func lspFrameURIBug(_ json: String) -> Data {
    let body = Data(json.utf8)
    var out = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
    out.append(body)
    return out
}

/// Parse a framed JSON-RPC body into a Foundation dictionary.
fileprivate func parseFramedJSONURIBug(_ data: Data) -> [String: Any]? {
    guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
    return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
}

/// Extract a JSON-RPC id from the various encodings Foundation may
/// surface (`Int`, `NSNumber`, `String`).
fileprivate func extractIdURIBug(_ any: Any?) -> Int? {
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String { return Int(s) }
    return nil
}

// MARK: - URI-bug method-capturing transport sidecar
//
// Drives an `InMemoryLSPTransport` so that:
//   * The very first `initialize` request is auto-answered (so the
//     session reaches `.running` and `didOpen` would actually be
//     dispatched if the bridge tried to send one).
//   * Every JSON-RPC notification (no `id`) is captured by method name,
//     so the test can assert whether `textDocument/didOpen` was sent.
//
fileprivate actor URIBugNotificationCapture {

    private(set) var sentMethodsByCategory: [String: [String]] = [
        "notification": [],
        "request": [],
    ]

    func recordNotification(method: String) {
        sentMethodsByCategory["notification", default: []].append(method)
    }

    func recordRequest(method: String) {
        sentMethodsByCategory["request", default: []].append(method)
    }

    func notificationMethods() -> [String] {
        sentMethodsByCategory["notification", default: []]
    }

    func requestMethods() -> [String] {
        sentMethodsByCategory["request", default: []]
    }

    /// Pump the in-memory transport: auto-answer `initialize` (and
    /// `shutdown` for completeness), and record every method that the
    /// bridge / session sends out.
    static func drive(
        on transport: InMemoryLSPTransport,
        capture: URIBugNotificationCapture
    ) async {
        var answeredIds: Set<Int> = []
        for _ in 0..<4000 {
            let sent = await transport.sentMessages()
            for data in sent {
                guard let dict = parseFramedJSONURIBug(data) else { continue }
                guard let method = dict["method"] as? String else { continue }

                // Notifications have no id — capture and continue.
                if extractIdURIBug(dict["id"]) == nil {
                    await capture.recordNotification(method: method)
                    continue
                }

                guard let id = extractIdURIBug(dict["id"]) else { continue }
                if answeredIds.contains(id) { continue }

                await capture.recordRequest(method: method)

                if method == "initialize" {
                    let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":{"capabilities":{},"serverInfo":{"name":"mock-lsp"}}}"#
                    await transport.simulateServerMessage(lspFrameURIBug(resp))
                    answeredIds.insert(id)
                    continue
                }
                if method == "shutdown" {
                    let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":null}"#
                    await transport.simulateServerMessage(lspFrameURIBug(resp))
                    answeredIds.insert(id)
                    continue
                }
                // Default: reply null so any unexpected request doesn't
                // block the test indefinitely.
                let resp = #"{"jsonrpc":"2.0","id":\#(id),"result":null}"#
                await transport.simulateServerMessage(lspFrameURIBug(resp))
                answeredIds.insert(id)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Tests

@MainActor
final class MCPLSPBridgeURIBugSpecTests: XCTestCase {

    // Helper: spin up a real `LSPSession` wired to an in-memory
    // transport, start it (so `didOpen` would actually be dispatched if
    // the bridge tried), and return both the session and the capture
    // sidecar that records every outbound method by category.
    private func makeStartedSession() async throws -> (LSPSession, URIBugNotificationCapture, Task<Void, Never>) {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        let session = LSPSession(
            workspaceRoot: URL(fileURLWithPath: "/tmp/calyx-mcp-uri-bug"),
            languageId: "java",
            client: client
        )
        let capture = URIBugNotificationCapture()
        let driverTask = Task {
            await URIBugNotificationCapture.drive(on: transport, capture: capture)
        }
        try await session.start()
        return (session, capture, driverTask)
    }

    // MARK: - Bug 1: non-file URI schemes must be a silent no-op

    /// `ensureFileOpen` MUST treat URIs whose scheme is not `file://`
    /// (e.g. `jdt://contents/foo/bar.class` from JDT.LS class-file
    /// hovers, `vscode-notebook-cell://path` from notebook flows, or
    /// `untitled:foo` for unsaved buffers) as a silent pass-through:
    ///
    ///   * MUST NOT throw — the caller's request must still dispatch.
    ///   * MUST NOT send a `textDocument/didOpen` notification — the
    ///     server is responsible for resolving non-file URIs itself,
    ///     and a synthetic didOpen with a fabricated text payload would
    ///     poison the session's open-doc tracking.
    ///
    /// Today the bridge happens to short-circuit on the
    /// `hasPrefix("file://")` guard for the two `://` cases, but the
    /// contract is broader: ANY non-`file://` scheme must be respected,
    /// including the `scheme:opaque` form (`untitled:foo`).
    func test_ensureFileOpen_silentNoOp_forNonFileScheme() async throws {
        let nonFileURIs: [String] = [
            "jdt://contents/foo/bar.class",
            "vscode-notebook-cell://path/to/cell.ipynb#W1sZmlsZQ%3D%3D",
            "untitled:foo",
        ]

        for uri in nonFileURIs {
            let (session, capture, driverTask) = try await makeStartedSession()
            defer { driverTask.cancel() }

            // Snapshot the captured method list BEFORE the call so we
            // can isolate any didOpen specifically triggered by the
            // ensureFileOpen invocation.
            let beforeNotifications = await capture.notificationMethods()
            XCTAssertFalse(
                beforeNotifications.contains("textDocument/didOpen"),
                "fixture invariant: session.start() must not itself emit a textDocument/didOpen (got \(beforeNotifications)) for uri=\(uri)"
            )

            // The contract: ensureFileOpen for a non-file scheme MUST
            // NOT throw. Any throw is a contract violation.
            do {
                try await MCPLSPBridge.ensureFileOpen(session: session, uri: uri)
            } catch {
                XCTFail("ensureFileOpen for non-file URI \(uri) MUST NOT throw; got: \(error)")
                continue
            }

            // The contract: ensureFileOpen for a non-file scheme MUST
            // NOT dispatch a textDocument/didOpen notification. Anything
            // else means the bridge tried to fabricate a synthetic open
            // for a URI it cannot resolve on disk.
            let afterNotifications = await capture.notificationMethods()
            let didOpenCount = afterNotifications.filter { $0 == "textDocument/didOpen" }.count
            XCTAssertEqual(
                didOpenCount,
                0,
                "ensureFileOpen for non-file URI \(uri) MUST NOT dispatch textDocument/didOpen; captured notifications=\(afterNotifications)"
            )

            // The session MUST NOT have recorded the non-file URI as an
            // open document — if it did, a later didChange / didClose
            // against the same URI would skip the documentNotOpen guard
            // and silently corrupt the wire state.
            let openDocs = await session.openDocuments()
            XCTAssertFalse(
                openDocs.contains(uri),
                "ensureFileOpen for non-file URI \(uri) MUST NOT add the URI to openDocuments; got: \(openDocs)"
            )
        }
    }

    // MARK: - Bug 2: `file://<host>/<path>` (non-empty host) is RFC 8089-valid

    /// RFC 8089 §3 explicitly permits the `file://<host>/<path>` form
    /// (SMB shares, Windows UNC paths). Current `normalizeFileURI`
    /// rejects any `file://` URI whose host component is non-empty:
    /// the fast-path `(url.host?.isEmpty ?? true)` clause fails, the
    /// rebuild fallback then strips `file://` to get `server/share/...`
    /// which lacks the leading `/`, and the function returns
    /// `(input, nil)` — `fileURL` is nil, so `ensureFileOpen` later
    /// raises an "unparseable file URI" error and the request is
    /// rejected.
    ///
    /// Contract:
    ///   * The returned `fileURL` MUST be non-nil — the host form is a
    ///     valid file URI per RFC 8089.
    ///   * The returned `uri` MUST preserve the host component (here
    ///     `server`) and the path component (here `/share/path/main.ts`),
    ///     percent-encoded as needed. We don't pin the exact byte
    ///     representation — the host may be lower-cased, the trailing
    ///     slash policy may differ — but BOTH substrings must appear.
    func test_normalizeFileURI_acceptsNonEmptyHost() {
        let input = "file://server/share/path/main.ts"
        let result = MCPLSPBridge.normalizeFileURI(input)

        XCTAssertNotNil(
            result.fileURL,
            "normalizeFileURI(\(input)) MUST return a non-nil fileURL — `file://<host>/<path>` is valid per RFC 8089 §3 (SMB shares, UNC paths); got uri=\(result.uri)"
        )

        let normalizedURI = result.uri
        let lowered = normalizedURI.lowercased()
        XCTAssertTrue(
            lowered.contains("server"),
            "normalizeFileURI MUST preserve the host component 'server' in the returned uri; got: \(normalizedURI)"
        )
        XCTAssertTrue(
            normalizedURI.contains("/share/path/main.ts")
                || normalizedURI.contains("/share/path/main.ts/"),
            "normalizeFileURI MUST preserve the path component '/share/path/main.ts' in the returned uri (percent-encoded if needed); got: \(normalizedURI)"
        )
        XCTAssertTrue(
            normalizedURI.hasPrefix("file://"),
            "normalizeFileURI MUST keep the 'file://' scheme prefix on its output; got: \(normalizedURI)"
        )

        // Cross-check the parsed URL components if the fileURL is
        // present: a correct implementation that goes through
        // URLComponents will expose host=='server' and path=='/share/path/main.ts'.
        if let fileURL = result.fileURL {
            let comps = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
            // host may be lower-cased or percent-encoded; just assert
            // it is non-empty.
            let host = comps?.host ?? fileURL.host ?? ""
            XCTAssertFalse(
                host.isEmpty,
                "the fileURL returned by normalizeFileURI MUST carry a non-empty host; got url=\(fileURL.absoluteString)"
            )
        }
    }
}
