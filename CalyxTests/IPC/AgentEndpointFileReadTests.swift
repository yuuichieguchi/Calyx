//
//  AgentEndpointFileReadTests.swift
//  CalyxTests
//
//  Covers AgentEndpointFile.read(directory:) -> Endpoint?, the decode
//  path AgentEndpointFile.remove(directory:port:token:) already carries
//  inline. `read` exists so IPCEndpointReuse's caller (the
//  IPCServerControlling seam) can look up a persisted-session CLI's
//  existing port/token BEFORE calling CalyxMCPServer.start, without
//  duplicating that inline decode a second time.
//
//  Coverage:
//  - read() decodes a file written by AgentEndpointFile.write exactly
//  - read() returns nil when the file is absent
//  - read() returns nil when the file is not valid JSON
//  - read() returns nil when "port" is missing
//  - read() returns nil when "token" is missing
//
//  NOT covered: "read never logs" (L2.2's own requirement). There is no
//  seam in this file to observe NSLog output from a unit test, so this
//  is asserted only by inspection of the production implementation at
//  code-review time, not by an assertion here.
//

import XCTest
@testable import Calyx

final class AgentEndpointFileReadTests: XCTestCase {

    // MARK: - Properties

    private var tempDir: String!
    private var filePath: String!

    // MARK: - Lifecycle

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        filePath = tempDir + "/agent-endpoint.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        filePath = nil
        super.tearDown()
    }

    // MARK: - Success

    func test_read_decodesFileWrittenByWrite() throws {
        try AgentEndpointFile.write(port: 41833, token: "read-token-xyz", directory: tempDir)

        let endpoint = AgentEndpointFile.read(directory: tempDir)

        XCTAssertEqual(endpoint, AgentEndpointFile.Endpoint(port: 41833, token: "read-token-xyz"),
                       "read() must decode exactly the port and token write() persisted")
    }

    // MARK: - Absent

    func test_read_returnsNil_whenFileAbsent() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath),
                       "Precondition: no file has been written in this temp directory")

        XCTAssertNil(AgentEndpointFile.read(directory: tempDir),
                     "read() must return nil when agent-endpoint.json does not exist")
    }

    // MARK: - Malformed JSON

    func test_read_returnsNil_whenFileIsNotValidJSON() {
        FileManager.default.createFile(atPath: filePath, contents: Data("not valid json".utf8))

        XCTAssertNil(AgentEndpointFile.read(directory: tempDir),
                     "read() must return nil when the file cannot be parsed as JSON")
    }

    // MARK: - Partial documents

    func test_read_returnsNil_whenPortIsMissing() {
        let json = "{\"token\":\"only-token-here\"}"
        FileManager.default.createFile(atPath: filePath, contents: Data(json.utf8))

        XCTAssertNil(AgentEndpointFile.read(directory: tempDir),
                     "read() must return nil when the \"port\" key is missing")
    }

    func test_read_returnsNil_whenTokenIsMissing() {
        let json = "{\"port\":41830}"
        FileManager.default.createFile(atPath: filePath, contents: Data(json.utf8))

        XCTAssertNil(AgentEndpointFile.read(directory: tempDir),
                     "read() must return nil when the \"token\" key is missing")
    }
}
