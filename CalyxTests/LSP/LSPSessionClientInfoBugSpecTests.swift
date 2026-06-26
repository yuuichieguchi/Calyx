//
//  LSPSessionClientInfoBugSpecTests.swift
//  Calyx
//
//  Regression test for the hardcoded `clientInfo.version` in
//  `LSPSession.swift`.
//
//  Bug: `LSPSession.init`'s default `clientInfo` is constructed as
//  `ClientInfo(name: "Calyx", version: "0.26.1")`. The version string is
//  frozen at the moment the source was written and silently drifts on
//  every release — the current build is already 0.26.2.
//
//  The fix should source the marketing version from the app bundle:
//  `Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String`
//  so the value tracks the actual build instead of a literal string.
//
//  TDD phase: RED. The test below sends `initialize` over an in-memory
//  transport, captures the InitializeParams that LSPSession wrote on
//  the wire, and asserts that the `clientInfo.version` field matches
//  the running bundle's short version. Against the current buggy code
//  the literal `"0.26.1"` is sent, which fails both the bundle-match
//  assertion and the explicit "not the literal 0.26.1" check below.
//

import XCTest
@testable import Calyx

@MainActor
final class LSPSessionClientInfoBugSpecTests: XCTestCase {

    // MARK: - Constants

    private let testWorkspaceRoot = URL(fileURLWithPath: "/tmp/calyx-lsp-session-clientinfo-test")
    private let testLanguageId = "swift"

    // MARK: - Construction helper (mirrors LSPSessionTests.makeSession)

    private func makeSession() -> (LSPSession, InMemoryLSPTransport) {
        let transport = InMemoryLSPTransport()
        let client = LSPClient(transport: transport)
        let session = LSPSession(
            workspaceRoot: testWorkspaceRoot,
            languageId: testLanguageId,
            client: client
        )
        return (session, transport)
    }

    // MARK: - Framing / JSON helpers (mirror LSPSessionTests)

    private func lspFrame(_ json: String) -> Data {
        let body = Data(json.utf8)
        let header = "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(header.utf8)
        out.append(body)
        return out
    }

    private func jsonRPCResponse(id: Int, resultJSON: String) -> String {
        return #"{"jsonrpc":"2.0","id":\#(id),"result":\#(resultJSON)}"#
    }

    private func initializeResultJSON() -> String {
        return #"{"capabilities":{"hoverProvider":true},"serverInfo":{"name":"mock","version":"0.0.0"}}"#
    }

    private func parseFramedJSON(_ data: Data) throws -> [String: Any] {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            throw TestError.framingMissing
        }
        let body = data.subdata(in: headerEnd.upperBound..<data.endIndex)
        guard let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TestError.bodyNotObject
        }
        return dict
    }

    private func parseAllFramedJSON(_ data: Data) throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let slice = data.subdata(in: cursor..<data.endIndex)
            guard let headerEnd = slice.range(of: Data("\r\n\r\n".utf8)) else { break }
            let headerData = slice.subdata(in: 0..<headerEnd.lowerBound)
            guard let headerString = String(data: headerData, encoding: .utf8) else { break }
            var contentLength = 0
            for line in headerString.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    contentLength = Int(parts[1]) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            let bodyEnd = bodyStart + contentLength
            guard bodyEnd <= slice.endIndex else { break }
            let body = slice.subdata(in: bodyStart..<bodyEnd)
            if let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
                results.append(dict)
            }
            cursor = cursor + bodyEnd
        }
        return results
    }

    private enum TestError: Error {
        case framingMissing
        case bodyNotObject
        case noInitializeRequest
    }

    /// Watch `transport.sentMessages()` for the first `initialize` request
    /// and reply with the canned result. Mirrors the pattern used in
    /// `LSPSessionTests.respondToInitialize`.
    private func respondToInitialize(
        on transport: InMemoryLSPTransport,
        responseBuilder: @escaping (Int) -> String
    ) -> Task<Void, Never> {
        let frame = self.lspFrame
        let parse = self.parseFramedJSON
        return Task {
            for _ in 0..<400 {
                let sent = await transport.sentMessages()
                for data in sent {
                    if let dict = try? parse(data),
                       (dict["method"] as? String) == "initialize",
                       let idAny = dict["id"] {
                        let idInt = (idAny as? Int) ?? Int(idAny as? String ?? "") ?? 0
                        let body = responseBuilder(idInt)
                        await transport.simulateServerMessage(frame(body))
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // MARK: - The bug-spec test

    /// `clientInfo.version` sent in the `initialize` request must reflect
    /// the running bundle's `CFBundleShortVersionString` — NOT a hardcoded
    /// literal that silently drifts on every release.
    ///
    /// Against the buggy default (`"0.26.1"`):
    ///   - When the test bundle exposes `CFBundleShortVersionString` and it
    ///     differs from `"0.26.1"`, the equality assertion fails.
    ///   - When the test bundle does NOT expose `CFBundleShortVersionString`
    ///     cleanly (the value reaches us as `nil` or an empty string), we
    ///     still enforce the looser invariant: the version on the wire must
    ///     not be the literal `"0.26.1"` and must be non-empty.
    ///
    /// The GREEN fix sources the version from
    /// `Bundle.main.infoDictionary?["CFBundleShortVersionString"]` so the
    /// value tracks the actual build.
    func test_clientInfo_version_matchesBundleShortVersion() async throws {
        let (session, transport) = makeSession()

        let responder = respondToInitialize(on: transport) { id in
            self.jsonRPCResponse(id: id, resultJSON: self.initializeResultJSON())
        }

        try await session.start()
        _ = await responder.value

        let sent = await transport.sentMessages()
        let dicts = try parseAllFramedJSON(Data(sent.reduce(into: Data()) { $0.append($1) }))
        guard let initReq = dicts.first(where: { ($0["method"] as? String) == "initialize" }) else {
            return XCTFail("initialize request was never sent")
        }
        let params = initReq["params"] as? [String: Any]
        let clientInfo = params?["clientInfo"] as? [String: Any]
        guard let versionOnWire = clientInfo?["version"] as? String else {
            return XCTFail(
                "initialize.params.clientInfo.version is missing or not a String — params=\(String(describing: params))"
            )
        }

        // Hard invariant regardless of where the test bundle's
        // CFBundleShortVersionString lands: the hardcoded literal must
        // be gone, and the value must be non-empty.
        XCTAssertNotEqual(
            versionOnWire, "0.26.1",
            "clientInfo.version on the wire is the hardcoded literal \"0.26.1\" — it must be sourced from Bundle.main.infoDictionary[\"CFBundleShortVersionString\"] so it tracks the build"
        )
        XCTAssertFalse(
            versionOnWire.isEmpty,
            "clientInfo.version must be non-empty"
        )

        // Stronger assertion: when the bundle DOES expose
        // CFBundleShortVersionString as a non-empty String at test time,
        // the value on the wire must equal it exactly.
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let bundleVersion, !bundleVersion.isEmpty {
            XCTAssertEqual(
                versionOnWire, bundleVersion,
                "clientInfo.version on the wire must equal Bundle.main.infoDictionary[\"CFBundleShortVersionString\"] — got \"\(versionOnWire)\", expected \"\(bundleVersion)\""
            )
        }
    }
}
