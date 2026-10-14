//
//  IPCServerControllingShapeTests.swift
//  CalyxTests
//
//  Source-level pin: `IPCServerControlling.start(token:)` reports token
//  rotation through its `Bool` return value, the protocol has no
//  `lastStartRotatedToken` member, and no `extension IPCServerControlling`
//  exists to supply defaults. Reads IPCActivationCoordinator.swift through
//  this file's #filePath, so it runs from the checkout that built the
//  tests.
//

import XCTest

final class IPCServerControllingShapeTests: XCTestCase {

    func testNoExtensionOfIPCServerControllingExists() throws {
        let calyxDir = repoRoot().appendingPathComponent("Calyx", isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: calyxDir, includingPropertiesForKeys: nil))
        var scanned: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned.append(url)
            let code = try strippedSource(atPath: url.path)
            XCTAssertFalse(
                code.contains("extension IPCServerControlling"),
                "\(url.path) extends IPCServerControlling; conformers must implement every member"
            )
        }
        XCTAssertGreaterThan(scanned.count, 0)
        XCTAssertTrue(scanned.contains { $0.lastPathComponent == "IPCActivationCoordinator.swift" })
    }

    func testProtocolStartReturnsRotationFlag() throws {
        let code = try coordinatorCode()
        let bodies = blocks(in: code, openedBy: "protocol IPCServerControlling")
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("func start(token: String) async throws -> Bool") ?? false)
    }

    func testProtocolHasNoLastStartRotatedToken() throws {
        let code = try coordinatorCode()
        let bodies = blocks(in: code, openedBy: "protocol IPCServerControlling")
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies.first?.contains("lastStartRotatedToken") ?? true)
    }

    // MARK: - Helpers

    /// The source without its comment lines, so a comment that mentions
    /// the member does not count.
    private func coordinatorCode() throws -> String {
        let path = repoRoot().appendingPathComponent("Calyx/Features/IPC/IPCActivationCoordinator.swift").path
        return try strippedSource(atPath: path)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func strippedSource(atPath path: String) throws -> String {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Brace-balanced bodies of every block whose header contains `header`.
    private func blocks(in code: String, openedBy header: String) -> [String] {
        var result: [String] = []
        var searchStart = code.startIndex
        while let headerRange = code.range(of: header, range: searchStart..<code.endIndex),
              let open = code[headerRange.upperBound...].firstIndex(of: "{") {
            var depth = 0
            var index = open
            var close: String.Index?
            while index < code.endIndex {
                let character = code[index]
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 { close = index; break }
                }
                index = code.index(after: index)
            }
            guard let end = close else {
                XCTFail("unbalanced braces after \(header)")
                return result
            }
            result.append(String(code[code.index(after: open)..<end]))
            searchStart = code.index(after: end)
        }
        return result
    }
}
