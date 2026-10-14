//
//  AgentEndpointFileBearerFileTests.swift
//  CalyxTests
//
//  Feature C, C-D17 / spec note 7: `AgentEndpointFile.write` also writes
//  `<directory>/calyx-bearer-token` (the token bytes only, no trailing
//  newline, 0600, atomic), and `remove(directory:port:token:)` removes it
//  exactly when it removes agent-endpoint.json. Grok >= 1.0.52 reads that
//  file per request through `bearer_token_file`.
//
//  The runtime file name is spelled as a literal here on purpose (derived
//  from the spec, not from production), so this class compiles against
//  today's API and fails on behaviour. `AgentEndpointFileBearerPathTests`
//  pins the `bearerFileName`/`bearerFilePath` API.
//

import XCTest
@testable import Calyx

final class AgentEndpointFileBearerFileTests: XCTestCase {

    private var tempDir: String!
    private let key = IPCWakeProofKey(bytes: Data(repeating: 0x01, count: 32))
    private let secret = String(repeating: "ab", count: 32)

    private var bearerPath: String { tempDir + "/calyx-bearer-token" }
    private var endpointPath: String { tempDir + "/agent-endpoint.json" }

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        super.tearDown()
    }

    private func write(port: Int = 41830, token: String? = nil) throws {
        try writeTestEndpointFile(port: port, token: token ?? secret, wakeProofKey: key, directory: tempDir)
    }

    func test_write_createsBearerFile_withExactlyTheTokenBytes_noTrailingNewline() throws {
        try write()
        let data = try XCTUnwrap(FileManager.default.contents(atPath: bearerPath),
                                 "write must also create calyx-bearer-token next to agent-endpoint.json")
        XCTAssertEqual(data, Data(secret.utf8), "the file holds the token bytes and nothing else")
    }

    func test_write_bearerFileMode_is0600() throws {
        try write()
        let attrs = try FileManager.default.attributesOfItem(atPath: bearerPath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_write_secondWrite_replacesTheBearerFileContent() throws {
        try write(token: String(repeating: "cd", count: 32))
        try write()
        XCTAssertEqual(FileManager.default.contents(atPath: bearerPath), Data(secret.utf8))
    }

    func test_write_directoryHoldsExactlyTheEndpointAndBearerFiles() throws {
        try write()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: tempDir))
        XCTAssertEqual(names, ["agent-endpoint.json", "calyx-bearer-token"],
                       "no temp file left behind by the atomic writes")
    }

    func test_write_endpointFileStillHasExactlyTheSixKeys() throws {
        try write()
        let data = try XCTUnwrap(FileManager.default.contents(atPath: endpointPath))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["port", "token", "wakeProofInner", "wakeProofOuter", "pid", "pidStart"])
        XCTAssertEqual(json["token"] as? String, secret)
    }

    func test_remove_matchingPortAndToken_deletesBothFiles() throws {
        try write()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bearerPath), "precondition")
        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: secret)
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bearerPath),
                       "the bearer file goes with the endpoint file")
    }

    func test_remove_mismatchingToken_deletesNeither() throws {
        try write()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bearerPath), "precondition")
        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: String(repeating: "ef", count: 32))
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointPath))
        XCTAssertEqual(FileManager.default.contents(atPath: bearerPath), Data(secret.utf8))
    }

    func test_remove_mismatchingPort_deletesNeither() throws {
        try write()
        XCTAssertTrue(FileManager.default.fileExists(atPath: bearerPath), "precondition")
        AgentEndpointFile.remove(directory: tempDir, port: 41831, token: secret)
        XCTAssertTrue(FileManager.default.fileExists(atPath: endpointPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bearerPath))
    }

    func test_write_bearerPathUnwritable_throws_andPublishesNoEndpointFile() throws {
        try FileManager.default.createDirectory(
            atPath: AgentEndpointFile.bearerFilePath(directory: tempDir), withIntermediateDirectories: false)
        XCTAssertThrowsError(try write(), "a bearer-file failure must throw")
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpointPath),
                       "nothing is published when the bearer file cannot be written")
    }

    func test_write_bearerPathUnwritable_leavesExistingEndpointFileUnchanged() throws {
        try write(token: String(repeating: "cd", count: 32))
        let before = try XCTUnwrap(FileManager.default.contents(atPath: endpointPath))
        try FileManager.default.removeItem(atPath: bearerPath)
        try FileManager.default.createDirectory(
            atPath: AgentEndpointFile.bearerFilePath(directory: tempDir), withIntermediateDirectories: false)
        XCTAssertThrowsError(try write(), "a bearer-file failure must throw")
        XCTAssertEqual(FileManager.default.contents(atPath: endpointPath), before,
                       "the old endpoint file (old token) is left untouched")
    }
}
