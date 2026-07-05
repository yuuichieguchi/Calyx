//
//  SessionInfoTests.swift
//  CalyxTests
//
//  TDD Red Phase for `SessionInfo`/`SessionLifecycleState`: the public
//  Codable types that mirror `proto::SessionInfo`/`proto::SessionState`
//  (the `ls --all --json` wire shape — see
//  `calyx-session/crates/proto/src/control.rs`; `SessionLifecycleState`
//  rather than `SessionState` since the latter name already belongs to
//  an unrelated LSP-layer type). Extended from the former id/state-only
//  `SessionInfoJSON` to carry every field `SessionBrowserModel` needs.
//
//  Coverage:
//  - A running session with no name/cwd/meta decodes with every field
//    matching, `state == .running`
//  - An exited session with name/cwd/meta decodes with every field
//    matching, `state == .exited(code:)`
//  - An array of both together decodes to two `SessionInfo` values in
//    order
//  - Malformed / truncated JSON fails the decode (returns `nil` via
//    `try?`) rather than crashing
//

import XCTest
@testable import Calyx

final class SessionInfoTests: XCTestCase {

    // MARK: - Running session, minimal fields

    func test_decode_runningSessionWithNoNameCwdOrMeta_allFieldsMatch() throws {
        let json = """
        {"id":"01ARZ3NDEKTSV4RRFFQ69G5FAV","name":null,"cwd":null,"state":"Running",\
        "created_at_ms":1700000000000,"attached_clients":1,"pid":12345,"meta":{}}
        """
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))

        XCTAssertEqual(info.id, "01ARZ3NDEKTSV4RRFFQ69G5FAV")
        XCTAssertNil(info.name)
        XCTAssertNil(info.cwd)
        XCTAssertEqual(info.state, .running)
        XCTAssertEqual(info.createdAtMs, 1_700_000_000_000)
        XCTAssertEqual(info.attachedClients, 1)
        XCTAssertEqual(info.pid, 12345)
        XCTAssertEqual(info.meta, [:])
    }

    // MARK: - Exited session, with name/cwd/meta

    func test_decode_exitedSessionWithNameCwdAndMeta_allFieldsMatch() throws {
        let json = """
        {"id":"01BRZ3NDEKTSV4RRFFQ69G5FAX","name":"my-session","cwd":"/Users/dev/repo",\
        "state":{"Exited":{"code":137}},"created_at_ms":1700000001234,"attached_clients":0,\
        "pid":0,"meta":{"agent.claude-code":"abc-123-session-id"}}
        """
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))

        XCTAssertEqual(info.id, "01BRZ3NDEKTSV4RRFFQ69G5FAX")
        XCTAssertEqual(info.name, "my-session")
        XCTAssertEqual(info.cwd, "/Users/dev/repo")
        XCTAssertEqual(info.state, .exited(code: 137))
        XCTAssertEqual(info.createdAtMs, 1_700_000_001_234)
        XCTAssertEqual(info.attachedClients, 0)
        XCTAssertEqual(info.pid, 0)
        XCTAssertEqual(info.meta, ["agent.claude-code": "abc-123-session-id"])
    }

    // MARK: - Array of both, as `ls --all --json` actually emits it

    func test_decode_arrayOfRunningAndExited_decodesBothInOrder() throws {
        let json = """
        [{"id":"session-a","name":null,"cwd":null,"state":"Running",\
        "created_at_ms":1,"attached_clients":1,"pid":100,"meta":{}},\
        {"id":"session-b","name":null,"cwd":null,"state":{"Exited":{"code":0}},\
        "created_at_ms":2,"attached_clients":0,"pid":0,"meta":{}}]
        """
        let sessions = try JSONDecoder().decode([SessionInfo].self, from: Data(json.utf8))

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, "session-a")
        XCTAssertEqual(sessions[0].state, .running)
        XCTAssertEqual(sessions[1].id, "session-b")
        XCTAssertEqual(sessions[1].state, .exited(code: 0))
    }

    // MARK: - Malformed JSON must not crash

    func test_decode_malformedJSON_failsGracefully_doesNotCrash() {
        let malformedCases = [
            "not json at all",
            "{\"id\":\"x\"}", // missing every other required field
            "{\"id\":\"x\",\"name\":null,\"cwd\":null,\"state\":\"NotARealState\",\"created_at_ms\":0,\"attached_clients\":0,\"pid\":0,\"meta\":{}}",
            "", // empty body
            "{\"id\":\"x\",\"name\":null,\"cwd\":null,\"state\":\"Running\",\"created_at_ms\":0,\"attached_clients\":0,\"pid\":0,\"meta\":{}", // truncated
        ]

        for malformed in malformedCases {
            let result = try? JSONDecoder().decode(SessionInfo.self, from: Data(malformed.utf8))
            XCTAssertNil(result, "Malformed JSON (\(malformed.prefix(40))...) must decode to nil, not crash")
        }
    }
}
