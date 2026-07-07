//
//  MCPCommandLogBridgeTests.swift
//  CalyxTests
//
//  Coverage for MCPCommandLogBridge: the terminal_list_commands /
//  terminal_read_output / terminal_await_command MCP tool surface over
//  CommandLogStore. Drives handleToolCall(name:arguments:) directly
//  against a fresh, isolated CommandLogStore + SessionSurfaceMap (no
//  CalyxMCPServer / HTTP layer involved -- that's
//  CalyxMCPServerTerminalToolsTests' job).
//
//  Coverage:
//  - terminal_list_commands: missing/unresolvable/non-string surface_id,
//    zero records (shell_integration false), field-correct oldest-first
//    JSON (incl. ISO8601 started_at, duration_ms conversion), a
//    session-ID surface_id, limit (newest-N), state filtering, an
//    unrecognized state filter, an out-of-range/fractional limit
//  - terminal_read_output: unknown/non-string command_id, output
//    present, output nil (output_unavailable, no text key), output
//    empty (text "", total_rows 0) -- the P1 empty-vs-nil distinction
//    must survive serialization
//  - terminal_await_command: already-finished command_id, no running
//    record + nil command_id (fast {"status":"timeout"}), a running
//    record whose end arrives during the wait, timeout_ms clamping
//    (negative -> 0, oversized -> capped, neither traps), an
//    out-of-range/fractional timeout_ms, a non-string command_id, an
//    orphaned record's state surfacing as "orphaned"
//

import XCTest
@testable import Calyx

// MARK: - Fakes

@MainActor
private final class FakeOutputReader: CommandOutputReading {
    var totals: [UUID: UInt64] = [:]
    var tailLines: [UUID: String] = [:]

    func scrollbarTotal(surfaceID: UUID) -> UInt64? {
        totals[surfaceID]
    }

    func readScreenTailLines(surfaceID: UUID, count: Int) -> String? {
        tailLines[surfaceID]
    }
}

@MainActor
final class MCPCommandLogBridgeTests: XCTestCase {

    // MARK: - Helpers

    private let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private func startEvent(cmdID: String, command: String = "echo hi", cwd: String = "/tmp", ts: Date = Date()) -> CommandEvent {
        CommandEvent(phase: .start, cmdID: cmdID, command: command, cwd: cwd, exitCode: nil, ts: ts)
    }

    private func endEvent(cmdID: String, exitCode: Int32? = 0, ts: Date = Date()) -> CommandEvent {
        CommandEvent(phase: .end, cmdID: cmdID, command: nil, cwd: nil, exitCode: exitCode, ts: ts)
    }

    private func jsonDict(_ text: String) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(obj as? [String: Any], "Expected \(text) to parse as a JSON object")
    }

    /// Bounded scheduler-yield loop -- same idiom as
    /// CommandLogStoreTests.yieldToScheduler.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    /// Drives `handleToolCall` expecting it to THROW, and asserts the
    /// thrown error's `localizedDescription` mentions `substring` --
    /// same "mentions X" assertions the pre-typed-error version of this
    /// suite made against a returned error string, just observed via
    /// do/catch now that `handleToolCall` raises a typed
    /// `MCPCommandLogBridgeError` instead of returning error text.
    private func expectError(
        name: String,
        arguments: [String: Any],
        bridge: MCPCommandLogBridge,
        containing substring: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let result = try await bridge.handleToolCall(name: name, arguments: arguments)
            XCTFail("Expected an error but got a result: \(result)", file: file, line: line)
        } catch {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(substring),
                "Expected error mentioning \"\(substring)\"; got: \(error.localizedDescription)",
                file: file, line: line
            )
        }
    }

    // MARK: - terminal_list_commands

    func test_list_missingSurfaceID_returnsErrorText() async {
        let bridge = MCPCommandLogBridge(store: CommandLogStore(), sessionSurfaceMap: SessionSurfaceMap())

        await expectError(
            name: "terminal_list_commands", arguments: [:], bridge: bridge,
            containing: "surface_id"
        )
    }

    func test_list_nonStringSurfaceID_returnsInvalidArgumentError() async {
        let bridge = MCPCommandLogBridge(store: CommandLogStore(), sessionSurfaceMap: SessionSurfaceMap())

        await expectError(
            name: "terminal_list_commands", arguments: ["surface_id": 12345], bridge: bridge,
            containing: "surface_id"
        )
    }

    func test_list_unknownSurfaceUUID_returnsEmptyCommandsAndShellIntegrationFalse() async throws {
        let bridge = MCPCommandLogBridge(store: CommandLogStore(), sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()

        let result = try await bridge.handleToolCall(
            name: "terminal_list_commands", arguments: ["surface_id": surfaceID.uuidString]
        )

        let json = try jsonDict(result)
        let commands = try XCTUnwrap(json["commands"] as? [[String: Any]])
        XCTAssertTrue(commands.isEmpty, "A surface with zero records must return an empty commands array")
        XCTAssertEqual(json["shell_integration"] as? Bool, false,
                       "A surface with zero records must report shell_integration: false")
    }

    func test_list_twoRecords_returnsCorrectFieldsOldestFirst() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        store.reader = reader
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()

        let startedAt1 = Date(timeIntervalSince1970: 1_700_000_000)
        reader.totals[surfaceID] = 100
        store.ingest(startEvent(cmdID: "cmd-1", command: "ls -la", cwd: "/tmp", ts: startedAt1), surfaceID: surfaceID)
        reader.totals[surfaceID] = 103
        reader.tailLines[surfaceID] = "a\nb\nc"
        // finalize() derives durationNanos from endedAt - startedAt (P2
        // GREEN: OSC133's unreliable exit code was dropped, so duration
        // now comes purely from the shell integration's own start/end
        // timestamps) -- a 2s gap here must read back as duration_ms 2000.
        let endedAt1 = startedAt1.addingTimeInterval(2)
        store.ingest(endEvent(cmdID: "cmd-1", exitCode: 0, ts: endedAt1), surfaceID: surfaceID)

        let startedAt2 = startedAt1.addingTimeInterval(10)
        store.ingest(startEvent(cmdID: "cmd-2", command: "npm run dev", cwd: "/Users/dev/repo", ts: startedAt2), surfaceID: surfaceID)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 2, "Precondition: both records must exist before calling the bridge")
        let record1 = records[0]
        let record2 = records[1]

        let result = try await bridge.handleToolCall(
            name: "terminal_list_commands", arguments: ["surface_id": surfaceID.uuidString]
        )
        let json = try jsonDict(result)
        XCTAssertEqual(json["shell_integration"] as? Bool, true,
                       "A surface with at least one record must report shell_integration: true")
        let commands = try XCTUnwrap(json["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 2)

        let dict1 = commands[0]
        XCTAssertEqual(dict1["id"] as? String, record1.id.uuidString, "Oldest-first: the first entry must be cmd-1")
        XCTAssertEqual(dict1["cmd_id"] as? String, "cmd-1")
        XCTAssertEqual(dict1["command"] as? String, "ls -la")
        XCTAssertEqual(dict1["cwd"] as? String, "/tmp")
        XCTAssertEqual(dict1["state"] as? String, "finished")
        XCTAssertEqual(dict1["exit_code"] as? Int, 0)
        XCTAssertEqual(dict1["duration_ms"] as? Double, 2000.0, "durationNanos / 1e6 must convert to milliseconds")
        XCTAssertEqual(dict1["output_total_rows"] as? Int, 3)
        XCTAssertEqual(dict1["output_truncated"] as? Bool, false)
        let startedAtString1 = try XCTUnwrap(dict1["started_at"] as? String)
        let parsedStartedAt1 = try XCTUnwrap(iso8601.date(from: startedAtString1))
        XCTAssertEqual(parsedStartedAt1.timeIntervalSince1970, startedAt1.timeIntervalSince1970, accuracy: 0.001)

        let dict2 = commands[1]
        XCTAssertEqual(dict2["id"] as? String, record2.id.uuidString, "Oldest-first: the second entry must be cmd-2")
        XCTAssertEqual(dict2["cmd_id"] as? String, "cmd-2")
        XCTAssertEqual(dict2["state"] as? String, "running")
        XCTAssertNil(dict2["exit_code"], "A running record must not carry an exit_code")
    }

    func test_list_sessionIDArgument_resolvesViaSessionSurfaceMap() async throws {
        let store = CommandLogStore()
        let sessionMap = SessionSurfaceMap()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: sessionMap)
        let surfaceID = UUID()
        let sessionID = "session-\(UUID().uuidString)"
        sessionMap.register(sessionID: sessionID, surfaceID: surfaceID)
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)

        let result = try await bridge.handleToolCall(name: "terminal_list_commands", arguments: ["surface_id": sessionID])

        let json = try jsonDict(result)
        let commands = try XCTUnwrap(json["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1, "A session-ID surface_id must resolve to the surface it's registered to")
        XCTAssertEqual(commands.first?["cmd_id"] as? String, "cmd-1")
    }

    func test_list_limitOne_returnsNewestRecordOnly() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-old"), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-old", exitCode: 0), surfaceID: surfaceID)
        store.ingest(startEvent(cmdID: "cmd-new"), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-new", exitCode: 0), surfaceID: surfaceID)

        let result = try await bridge.handleToolCall(
            name: "terminal_list_commands",
            arguments: ["surface_id": surfaceID.uuidString, "limit": 1]
        )

        let json = try jsonDict(result)
        let commands = try XCTUnwrap(json["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1, "limit: 1 must cap the result to a single record")
        XCTAssertEqual(commands.first?["cmd_id"] as? String, "cmd-new",
                       "limit must keep the NEWEST record (suffix semantics), not the oldest")
    }

    func test_list_stateFilter_runningAndFinished() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-finished"), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-finished", exitCode: 0), surfaceID: surfaceID)
        store.ingest(startEvent(cmdID: "cmd-running"), surfaceID: surfaceID)

        let runningResult = try await bridge.handleToolCall(
            name: "terminal_list_commands", arguments: ["surface_id": surfaceID.uuidString, "state": "running"]
        )
        let runningJSON = try jsonDict(runningResult)
        let runningCommands = try XCTUnwrap(runningJSON["commands"] as? [[String: Any]])
        XCTAssertEqual(runningCommands.count, 1)
        XCTAssertEqual(runningCommands.first?["cmd_id"] as? String, "cmd-running")

        let finishedResult = try await bridge.handleToolCall(
            name: "terminal_list_commands", arguments: ["surface_id": surfaceID.uuidString, "state": "finished"]
        )
        let finishedJSON = try jsonDict(finishedResult)
        let finishedCommands = try XCTUnwrap(finishedJSON["commands"] as? [[String: Any]])
        XCTAssertEqual(finishedCommands.count, 1)
        XCTAssertEqual(finishedCommands.first?["cmd_id"] as? String, "cmd-finished")
    }

    func test_list_unknownStateFilter_returnsErrorText() async {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)

        await expectError(
            name: "terminal_list_commands",
            arguments: ["surface_id": surfaceID.uuidString, "state": "bogus"],
            bridge: bridge,
            containing: "state"
        )
    }

    func test_list_hugeDoubleLimit_returnsErrorWithoutTrapping() async {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        // Must be a genuine Double (not an Int literal) to exercise the
        // Double branch of the argument decoder -- 1e300 previously
        // reached a direct `Int(_: Double)` conversion there, which
        // fatal-traps for a magnitude beyond Int.max.
        let hugeLimit: Double = 1e300

        await expectError(
            name: "terminal_list_commands",
            arguments: ["surface_id": surfaceID.uuidString, "limit": hugeLimit],
            bridge: bridge,
            containing: "limit"
        )
    }

    // MARK: - terminal_read_output

    func test_readOutput_unknownCommandID_returnsErrorText() async {
        let bridge = MCPCommandLogBridge(store: CommandLogStore(), sessionSurfaceMap: SessionSurfaceMap())

        await expectError(
            name: "terminal_read_output",
            arguments: ["command_id": UUID().uuidString],
            bridge: bridge,
            containing: "command"
        )
    }

    func test_readOutput_nonStringCommandID_returnsInvalidArgumentError() async {
        let bridge = MCPCommandLogBridge(store: CommandLogStore(), sessionSurfaceMap: SessionSurfaceMap())

        await expectError(
            name: "terminal_read_output",
            arguments: ["command_id": 12345],
            bridge: bridge,
            containing: "command_id"
        )
    }

    func test_readOutput_finishedWithOutput_returnsTextTruncatedTotalRows() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        store.reader = reader
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        reader.totals[surfaceID] = 10
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        reader.totals[surfaceID] = 13
        reader.tailLines[surfaceID] = "x\ny\nz"
        store.ingest(endEvent(cmdID: "cmd-1", exitCode: 0), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)

        let result = try await bridge.handleToolCall(
            name: "terminal_read_output", arguments: ["command_id": record.id.uuidString]
        )

        let json = try jsonDict(result)
        XCTAssertEqual(json["command_id"] as? String, record.id.uuidString)
        XCTAssertEqual(json["text"] as? String, "x\ny\nz")
        XCTAssertEqual(json["truncated"] as? Bool, false)
        XCTAssertEqual(json["total_rows"] as? Int, 3)
    }

    func test_readOutput_nilOutput_returnsOutputUnavailableWithNoTextKey() async throws {
        let store = CommandLogStore()
        // No reader injected -- materializeOutput always returns nil
        // without one (P1 contract).
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-1", exitCode: 0), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertNil(record.output, "Precondition: with no reader, output must be nil")

        let result = try await bridge.handleToolCall(
            name: "terminal_read_output", arguments: ["command_id": record.id.uuidString]
        )

        let json = try jsonDict(result)
        XCTAssertEqual(json["output_unavailable"] as? Bool, true)
        XCTAssertNil(json["text"], "output_unavailable must not carry a text key at all")
    }

    func test_readOutput_emptyOutput_returnsEmptyTextZeroTotalRows() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        store.reader = reader
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        reader.totals[surfaceID] = 10
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        // Zero row delta (alt-screen case): output materializes as an
        // explicit empty CommandOutput, not nil (P1 contract).
        store.ingest(endEvent(cmdID: "cmd-1", exitCode: 0), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertNotNil(record.output, "Precondition: a zero row delta must still materialize an explicit (empty) output")

        let result = try await bridge.handleToolCall(
            name: "terminal_read_output", arguments: ["command_id": record.id.uuidString]
        )

        let json = try jsonDict(result)
        XCTAssertEqual(json["text"] as? String, "")
        XCTAssertEqual(json["total_rows"] as? Int, 0)
        XCTAssertNil(json["output_unavailable"], "An explicit empty output is available, not unavailable")
    }

    // MARK: - terminal_await_command

    func test_await_alreadyFinishedCommandID_returnsImmediatelyWithRecordJSON() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        store.reader = reader
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        reader.totals[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        reader.totals[surfaceID] = 4
        reader.tailLines[surfaceID] = "a\nb\nc"
        store.ingest(endEvent(cmdID: "cmd-1", exitCode: 7), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)

        let result = try await bridge.handleToolCall(
            name: "terminal_await_command",
            arguments: ["surface_id": surfaceID.uuidString, "command_id": record.id.uuidString]
        )

        let json = try jsonDict(result)
        XCTAssertEqual(json["state"] as? String, "finished")
        XCTAssertEqual(json["exit_code"] as? Int, 7)
        XCTAssertEqual(json["text"] as? String, "a\nb\nc", "await must include output fields, like read_output")
        XCTAssertEqual(json["total_rows"] as? Int, 3)
    }

    func test_await_nilCommandIDNoRunning_returnsTimeoutStatusFast() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()

        let start = Date()
        let result = try await bridge.handleToolCall(
            name: "terminal_await_command",
            arguments: ["surface_id": surfaceID.uuidString, "timeout_ms": 5000]
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1,
                          "With no running record and a nil command_id, awaitCompletion has nothing to " +
                          "wait for and must return immediately, not wait out the timeout")
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "timeout")
    }

    func test_await_runningCommandIDEndArrivesDuringWait_returnsFinishedRecord() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)

        let waiter = Task { @MainActor in
            try await bridge.handleToolCall(
                name: "terminal_await_command",
                arguments: ["surface_id": surfaceID.uuidString, "command_id": record.id.uuidString, "timeout_ms": 5000]
            )
        }
        await yieldToScheduler()

        store.ingest(endEvent(cmdID: "cmd-1", exitCode: 0), surfaceID: surfaceID)

        let result = try await waiter.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["state"] as? String, "finished")
    }

    func test_await_negativeTimeoutMs_clampsToZero_returnsTimeoutImmediatelyWithoutTrapping() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)

        let start = Date()
        let result = try await bridge.handleToolCall(
            name: "terminal_await_command",
            arguments: ["surface_id": surfaceID.uuidString, "command_id": record.id.uuidString, "timeout_ms": -5]
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.5,
                          "A negative timeout_ms must clamp to 0 (immediate give-up) against a still-" +
                          "running record, not trap or hang")
        let json = try jsonDict(result)
        XCTAssertEqual(json["status"] as? String, "timeout")
    }

    func test_await_fractionalTimeoutMs_returnsInvalidArgumentErrorNotSilentTruncation() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)

        await expectError(
            name: "terminal_await_command",
            arguments: ["surface_id": surfaceID.uuidString, "command_id": record.id.uuidString, "timeout_ms": 30_000.5],
            bridge: bridge,
            containing: "timeout_ms"
        )
    }

    func test_await_hugeDoubleTimeoutMs_returnsErrorWithoutTrapping() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        // Beyond Int64's range (~9.22e18) -- must be a genuine Double
        // (not an Int literal) to exercise the Double branch of the
        // argument decoder.
        let hugeTimeout: Double = 1e19

        await expectError(
            name: "terminal_await_command",
            arguments: ["surface_id": surfaceID.uuidString, "command_id": record.id.uuidString, "timeout_ms": hugeTimeout],
            bridge: bridge,
            containing: "timeout_ms"
        )
    }

    func test_await_nonStringCommandID_returnsInvalidArgumentError() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)

        await expectError(
            name: "terminal_await_command",
            arguments: ["surface_id": surfaceID.uuidString, "command_id": 12345],
            bridge: bridge,
            containing: "command_id"
        )
    }

    func test_await_hugeTimeoutMs_doesNotTrapAndResolvesOnFastCompletion() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)

        let waiter = Task { @MainActor in
            try await bridge.handleToolCall(
                name: "terminal_await_command",
                arguments: [
                    "surface_id": surfaceID.uuidString, "command_id": record.id.uuidString,
                    "timeout_ms": 99_999_999,
                ]
            )
        }
        await yieldToScheduler()
        store.ingest(endEvent(cmdID: "cmd-1", exitCode: 0), surfaceID: surfaceID)

        let result = try await waiter.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["state"] as? String, "finished",
                       "An oversized timeout_ms must clamp to the 55s cap (not trap) and still resolve " +
                       "immediately once the command finishes")
    }

    func test_await_orphanedRecord_returnsStateOrphaned() async throws {
        let store = CommandLogStore()
        let bridge = MCPCommandLogBridge(store: store, sessionSurfaceMap: SessionSurfaceMap())
        let surfaceID = UUID()
        store.ingest(startEvent(cmdID: "cmd-1"), surfaceID: surfaceID)
        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)

        let waiter = Task { @MainActor in
            try await bridge.handleToolCall(
                name: "terminal_await_command",
                arguments: ["surface_id": surfaceID.uuidString, "command_id": record.id.uuidString, "timeout_ms": 5000]
            )
        }
        await yieldToScheduler()
        store.markOrphaned(surfaceID: surfaceID)

        let result = try await waiter.value
        let json = try jsonDict(result)
        XCTAssertEqual(json["state"] as? String, "orphaned",
                       "An orphaned record is a legitimate await result and must expose state: orphaned")
    }
}
