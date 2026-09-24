//
//  MCPConnectionAppServerSessionTests.swift
//  CalyxTests
//
//  `MCPConnectionAppServerSession` forwards `listResources`,
//  `listResourceTemplates` and `listPrompts` to its connection with the
//  cursor it was given, and returns the connection's page unchanged.
//

import XCTest
@testable import Calyx

final class MCPConnectionAppServerSessionTests: XCTestCase {

    private func session(over connection: FakeUpstreamConnection) -> MCPConnectionAppServerSession {
        MCPConnectionAppServerSession(connection: connection, serverDisplayName: "Weather Service")
    }

    func test_listResources_forwardsCursor_andReturnsTheConnectionPage() async throws {
        let connection = FakeUpstreamConnection(serverID: MCPServerID())
        await connection.setListResourcesResult(.success((
            items: [["uri": AnyCodable("file:///notes.md"), "name": AnyCodable("notes")]],
            nextCursor: "page-3"
        )))

        let page = try await session(over: connection).listResources(cursor: "page-2")

        XCTAssertEqual(page.items, [["uri": AnyCodable("file:///notes.md"), "name": AnyCodable("notes")]])
        XCTAssertEqual(page.nextCursor, "page-3")
        let cursors = await connection.listResourcesCursors
        XCTAssertEqual(cursors, ["page-2"])
    }

    func test_listResourceTemplates_forwardsCursor_andReturnsTheConnectionPage() async throws {
        let connection = FakeUpstreamConnection(serverID: MCPServerID())
        await connection.setListResourceTemplatesResult(.success((
            items: [["uriTemplate": AnyCodable("file:///{path}"), "name": AnyCodable("files")]],
            nextCursor: nil
        )))

        let page = try await session(over: connection).listResourceTemplates(cursor: nil)

        XCTAssertEqual(page.items, [["uriTemplate": AnyCodable("file:///{path}"), "name": AnyCodable("files")]])
        XCTAssertNil(page.nextCursor)
        let cursors = await connection.listResourceTemplatesCursors
        XCTAssertEqual(cursors, [nil])
    }

    func test_listPrompts_forwardsCursor_andReturnsTheConnectionPage() async throws {
        let connection = FakeUpstreamConnection(serverID: MCPServerID())
        await connection.setListPromptsResult(.success((
            items: [["name": AnyCodable("summarize")]],
            nextCursor: ""
        )))

        let page = try await session(over: connection).listPrompts(cursor: "")

        XCTAssertEqual(page.items, [["name": AnyCodable("summarize")]])
        XCTAssertEqual(page.nextCursor, "")
        let cursors = await connection.listPromptsCursors
        XCTAssertEqual(cursors, [""])
    }

    func test_listPrompts_connectionError_isRethrown() async throws {
        let connection = FakeUpstreamConnection(serverID: MCPServerID())
        await connection.setListPromptsResult(.failure(MCPClientProtocolError.timeout))

        do {
            _ = try await session(over: connection).listPrompts(cursor: nil)
            XCTFail("expected the connection's error")
        } catch let error as MCPClientProtocolError {
            XCTAssertEqual(error, .timeout)
        }
    }
}
