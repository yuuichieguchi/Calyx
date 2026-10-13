//
//  AgentEndpointFileWakeProofTests.swift
//  CalyxTests
//
//  Pins AgentEndpointFile.write with its REQUIRED wake proof key (spec
//  A.3 `AgentEndpointFile`, A.4 `IPC/AgentEndpointFileTests`, audit 5).
//  Kept apart from AgentEndpointFileTests only so that file keeps
//  compiling before the planned API exists.
//
//  Planned API used here:
//    AgentEndpointFile.write(port: Int, token: String,
//                            wakeProofKey: IPCWakeProofKey,
//                            directory: String) throws
//
//  Coverage:
//  - the file holds port, token, wakeProofInner and wakeProofOuter, the
//    blocks equal to the key's (and to a by-hand computation), and never
//    the key bytes
//  - file mode is 0600
//  - read() still returns port and token
//  - remove() still requires the matching port and token
//  - a second write replaces the first key's blocks
//  - the two `sed` expressions of AgentHookScriptPrologue.body, run with
//    /usr/bin/sed, extract the same port and token from the new file
//

import XCTest
@testable import Calyx

final class AgentEndpointFileWakeProofTests: XCTestCase {

    private var tempDir: String!
    private var filePath: String!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentEndpointFileWakeProofTests-" + UUID().uuidString).path
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        filePath = tempDir + "/agent-endpoint.json"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        tempDir = nil
        filePath = nil
        super.tearDown()
    }

    /// 32 bytes of 0x01: 0x01 ^ 0x36 = 0x37, 0x01 ^ 0x5C = 0x5D, padding
    /// gives 0x36 / 0x5C.
    private let onesKey = IPCWakeProofKey(bytes: Data(repeating: 0x01, count: 32))
    private let onesInnerHex = String(repeating: "37", count: 32) + String(repeating: "36", count: 32)
    private let onesOuterHex = String(repeating: "5d", count: 32) + String(repeating: "5c", count: 32)

    private func readJSONObject() throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: filePath))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_write_storesBothBlocks_nextToPortAndToken() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)

        let json = try readJSONObject()
        XCTAssertEqual(json["wakeProofInner"] as? String, onesInnerHex)
        XCTAssertEqual(json["wakeProofOuter"] as? String, onesOuterHex)
        XCTAssertEqual(json["wakeProofInner"] as? String, onesKey.innerBlockHex)
        XCTAssertEqual(json["wakeProofOuter"] as? String, onesKey.outerBlockHex)
        XCTAssertEqual(json["port"] as? Int, 41830)
        XCTAssertEqual(json["token"] as? String, "test-token-abc")
        XCTAssertEqual(Set(json.keys), ["port", "token", "wakeProofInner", "wakeProofOuter", "pid", "pidStart"])
    }

    // MARK: - Liveness identifier (spec Feature C, J1)

    func test_write_storesTheLivenessPidAsANumberAndPidStartAsAString() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)

        let json = try readJSONObject()
        XCTAssertEqual(json["pid"] as? Int, Int(getpid()), "pid must be the writing process's own pid, as a JSON number")
        XCTAssertNil(json["pid"] as? String, "pid must not be a JSON string")
        XCTAssertFalse(TestHostLiveness.startText.isEmpty, "precondition: ps reported the test host's start time")
        XCTAssertEqual(json["pidStart"] as? String, TestHostLiveness.startText,
                       "pidStart must be the normalised UTC `ps -o lstart=` text of the writing process")
    }

    func test_write_readAndRemoveIgnoreTheLivenessKeys() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)
        XCTAssertNotNil(try readJSONObject()["pidStart"], "precondition: the file carries pidStart")

        XCTAssertEqual(AgentEndpointFile.read(directory: tempDir),
                       AgentEndpointFile.Endpoint(port: 41830, token: "test-token-abc"))
        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: "test-token-abc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath))
    }

    func test_write_doesNotStoreTheKeyItself() throws {
        let keyBytes = Data((0..<32).map { UInt8(0xA0 + $0) })
        try writeTestEndpointFile(
            port: 41830, token: "test-token-abc", wakeProofKey: IPCWakeProofKey(bytes: keyBytes), directory: tempDir
        )

        let text = try String(contentsOfFile: filePath, encoding: .utf8)
        XCTAssertTrue(text.contains("wakeProofInner"), "precondition: the file carries the blocks, got: \(text)")
        XCTAssertFalse(text.lowercased().contains(IPCWakeTestCrypto.hex(keyBytes)), "the key must not be in the file")
        let blocks = IPCWakeTestCrypto.blocksHex(keyBytes: keyBytes)
        XCTAssertTrue(text.contains(blocks.inner) && text.contains(blocks.outer),
                      "the blocks must be the by-hand padded key XOR 0x36 / 0x5C")
    }

    func test_write_fileModeIs0600() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)

        let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.uint16Value, 0o600)
        XCTAssertNotNil(try readJSONObject()["wakeProofInner"], "precondition: the file carries the blocks")
    }

    func test_write_readReturnsThePortAndToken() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)

        XCTAssertNotNil(try readJSONObject()["wakeProofOuter"], "precondition: the file carries the blocks")
        XCTAssertEqual(AgentEndpointFile.read(directory: tempDir),
                       AgentEndpointFile.Endpoint(port: 41830, token: "test-token-abc"))
    }

    func test_remove_stillRequiresMatchingPortAndToken() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)

        AgentEndpointFile.remove(directory: tempDir, port: 41831, token: "test-token-abc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))
        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: "other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filePath))
        AgentEndpointFile.remove(directory: tempDir, port: 41830, token: "test-token-abc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: filePath))
    }

    func test_write_replacesAnEarlierKeysBlocks() throws {
        let earlier = IPCWakeProofKey(bytes: Data(repeating: 0x02, count: 32))
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: earlier, directory: tempDir)
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)

        let json = try readJSONObject()
        XCTAssertEqual(json["wakeProofInner"] as? String, onesInnerHex)
        XCTAssertEqual(json["wakeProofOuter"] as? String, onesOuterHex)
    }

    // MARK: - The prologue's sed expressions

    /// The executable line of AgentHookScriptPrologue.body that assigns
    /// `name=$(sed -n '<expr>' "$endpoint_file")`, reduced to `<expr>`.
    private func prologueSedExpression(assigning name: String) throws -> String {
        let line = try XCTUnwrap(
            AgentHookScriptPrologue.body.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("\(name)=$(sed -n '") },
            "the prologue must assign \(name) with sed"
        )
        let afterOpen = try XCTUnwrap(line.range(of: "sed -n '")).upperBound
        let rest = line[afterOpen...]
        let close = try XCTUnwrap(rest.range(of: "' \"$endpoint_file\")"), "unexpected prologue line: \(line)")
        return String(rest[..<close.lowerBound])
    }

    private func runSed(_ expression: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sed")
        process.arguments = ["-n", expression, filePath]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func test_prologueSedExpressions_extractTheSamePortAndToken() throws {
        let token = "7B0D1F5C-2E44-4C0A-9D1B-6A5E3C2F1A00"
        try writeTestEndpointFile(
            port: 41830, token: token, wakeProofKey: IPCWakeProofKey(bytes: Data((0..<32).map { UInt8($0) })),
            directory: tempDir
        )
        XCTAssertNotNil(try readJSONObject()["wakeProofInner"], "precondition: the file carries the blocks")

        XCTAssertEqual(try runSed(try prologueSedExpression(assigning: "port")), "41830")
        XCTAssertEqual(try runSed(try prologueSedExpression(assigning: "token")), token)
    }

    /// J1/J15: the liveness sed lines extract exactly the pid and pidStart
    /// the writer stored, and the pid expression is not fooled by the
    /// `"pidStart"` key that shares its prefix.
    func test_prologueSedExpressions_extractThePidAndPidStart() throws {
        try writeTestEndpointFile(port: 41830, token: "test-token-abc", wakeProofKey: onesKey, directory: tempDir)
        XCTAssertNotNil(try readJSONObject()["pidStart"], "precondition: the file carries pidStart")

        XCTAssertEqual(try runSed(try prologueSedExpression(assigning: "pid")), String(getpid()))
        XCTAssertEqual(try runSed(try prologueSedExpression(assigning: "pid_start")), TestHostLiveness.startText)
        XCTAssertEqual(try runSed(try prologueSedExpression(assigning: "port")), "41830",
                       "the port extraction must be unaffected by the new keys")
    }
}
