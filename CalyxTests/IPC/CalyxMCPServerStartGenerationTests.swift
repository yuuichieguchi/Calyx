//
//  CalyxMCPServerStartGenerationTests.swift
//  CalyxTests
//
//  Feature C, G5 (spec note 22): `CalyxMCPServer.startGeneration` counts
//  successful starts (+1 in `finishStart`), so the usage credential holder
//  can renew the usage token once per start whose IPC token rotated.
//

import XCTest
@testable import Calyx

@MainActor
final class CalyxMCPServerStartGenerationTests: XCTestCase {

    private var server: CalyxMCPServer!
    private var agentEndpointDir: String!

    override func setUp() async throws {
        try await super.setUp()
        agentEndpointDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        server = CalyxMCPServer(agentEndpointDirectory: agentEndpointDir)
    }

    override func tearDown() async throws {
        await server?.stopAndWait()
        server = nil
        if let agentEndpointDir { try? FileManager.default.removeItem(atPath: agentEndpointDir) }
        agentEndpointDir = nil
        try await super.tearDown()
    }

    func test_startGeneration_isZeroBeforeAnyStart() {
        XCTAssertEqual(server.startGeneration, 0)
    }

    func test_startGeneration_countsEverySuccessfulStart() async throws {
        try await server.start(token: "generation-token-A", preferredPort: 0)
        XCTAssertTrue(server.isRunning, "precondition: the start succeeded")
        XCTAssertEqual(server.startGeneration, 1)

        try await server.start(token: "generation-token-B", preferredPort: 0)
        XCTAssertTrue(server.isRunning, "precondition: the second start succeeded")
        XCTAssertEqual(server.startGeneration, 2)
    }

    func test_startGeneration_isNotResetByStop() async throws {
        try await server.start(token: "generation-token-A", preferredPort: 0)
        await server.stopAndWait()
        XCTAssertEqual(server.startGeneration, 1, "a stop does not count and does not reset")
    }
}
