//
//  CommandLogStoreTests.swift
//  CalyxTests
//
//  Covers CommandLogStore: ingesting CommandEvent start/end pairs into
//  per-surface CommandRecord ring buffers, output materialization,
//  pending-end TTL, awaitCompletion coordination, orphaning, and surface
//  remapping.
//
//  Coverage:
//  - start ingest creates a .running record with reader-derived fields
//  - start+end merges to .finished with materialized output, including
//    the zero-row-delta / alt-screen case and the positive-delta-but-
//    empty-tail case, both of which finish with an explicit empty
//    output (not nil) -- nil is reserved for capture actually failing
//  - end-before-start merges via a pending-end once the start arrives; a
//    duplicate/late end for an already-finished cmd_id is never buffered
//    (so a later start reusing that cmd_id can't be spuriously finalized)
//  - an end with no start ever arriving within pendingEndTTL never
//    produces a record
//  - a duplicate start for the same cmd_id is ignored
//  - the ring evicts the oldest record past ringCapacity; an evicted
//    still-running record is orphaned first and resumes its awaiter
//  - output exceeding outputByteCap is truncated but keeps head and
//    tail, trimming any partial multi-byte scalar at the cut edges
//  - awaitCompletion resolves a given commandID immediately if already
//    non-running, else waits (clamping timeoutMs to [0, 3_600_000]); a
//    nil commandID resolves the newest running record at call time, or
//    returns nil immediately if none is running; a timed-out or
//    cancelled wait unregisters its awaiter, leaving no husk behind
//  - awaitNextCompletion resolves the earliest record on a surface whose
//    startedAt is strictly after a given cutoff and has reached
//    .finished -- immediately if one already qualifies, else waiting for
//    a future finalize; an already-running-but-earlier record must never
//    satisfy it, even if it finishes first; a wait survives remapSurface
//    (carried old->new, resolving on the new surface's finalize) and is
//    resumed nil promptly by markOrphaned (nothing will ever finish on a
//    gone surface) -- but NOT by ring eviction, which only ages out one
//    already-irrelevant record and doesn't invalidate a wait for the
//    next one
//  - markOrphaned transitions running records and resumes pending awaits
//  - finalize derives durationNanos from endedAt - startedAt, clamped to
//    [0, a plausibility ceiling] -- 0 for clock skew, the ceiling for a
//    wildly-implausible elapsed gap (never overflowing UInt64 on the
//    nanosecond conversion) -- never exitCode, which is exclusively the
//    script end event's (ghostty's OSC133 duration signal was tried and
//    dropped, see finalize's own doc comment)
//  - remapSurface moves records (clearing contentRowCountAtStart, since
//    the new surfaceID's scrollback counter is unrelated) and pending
//    awaits to a new surfaceID
//  - records(limit:state:) filtering
//  - a non-empty output capture defers redaction/truncation to an async
//    job (state stays .running externally until it attaches output via
//    _testAwaitOutputJobsDrained); a duplicate end arriving mid-gap is
//    dropped, not buffered or re-finalized; markOrphaned mid-gap resumes
//    the awaiter with the orphaned record and the late job then attaches
//    nothing
//  - isFinalizing(id:) reads true for a record mid-async-redaction-gap,
//    false once drained, and false for a genuinely still-running or
//    unknown id
//

import XCTest
@testable import Calyx

// MARK: - Fakes

@MainActor
private final class FakeOutputReader: CommandOutputReading {
    var rowCounts: [UUID: UInt64] = [:]
    var tailLines: [UUID: String] = [:]

    func contentRowCount(surfaceID: UUID) -> UInt64? {
        rowCounts[surfaceID]
    }

    func readScreenTailLines(surfaceID: UUID, count: Int) -> String? {
        tailLines[surfaceID]
    }
}

@MainActor
final class CommandLogStoreTests: XCTestCase {

    // MARK: - Helpers

    private func startEvent(cmdID: String, command: String = "echo hi", cwd: String = "/tmp", ts: Date = Date()) -> CommandEvent {
        CommandEvent(phase: .start, cmdID: cmdID, command: command, cwd: cwd, exitCode: nil, ts: ts)
    }

    private func endEvent(cmdID: String, exitCode: Int32? = 0, ts: Date = Date()) -> CommandEvent {
        CommandEvent(phase: .end, cmdID: cmdID, command: nil, cwd: nil, exitCode: exitCode, ts: ts)
    }

    /// Bounded scheduler-yield loop, so a concurrently-spawned `Task`
    /// awaiting `store.awaitCompletion` has every reasonable opportunity
    /// to actually reach its suspension point before the test proceeds
    /// to trigger completion -- same pattern as
    /// SessionBrowserModelRefreshDedupeTests' bounded yield loop.
    private func yieldToScheduler() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }

    // MARK: - Ingest: start

    func test_ingestStart_createsRunningRecordWithFieldsFromReader() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        reader.rowCounts[surfaceID] = 42
        store.reader = reader
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        store.ingest(startEvent(cmdID: "cmd-1", command: "ls -la", cwd: "/Users/dev/repo", ts: startedAt), surfaceID: surfaceID)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "A start event must create exactly one record")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.cmdID, "cmd-1")
        XCTAssertEqual(record.command, "ls -la")
        XCTAssertEqual(record.cwd, "/Users/dev/repo")
        XCTAssertEqual(record.startedAt, startedAt)
        XCTAssertEqual(record.state, .running)
        XCTAssertEqual(record.contentRowCountAtStart, 42, "contentRowCountAtStart must come from the reader at ingest time")
        XCTAssertEqual(record.surfaceID, surfaceID)
    }

    // MARK: - Ingest: start + end

    func test_ingestStartThenEnd_producesFinishedRecordWithMaterializedOutput() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 100
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.ingest(startEvent(cmdID: "cmd-2", ts: startedAt), surfaceID: surfaceID)

        reader.rowCounts[surfaceID] = 103
        reader.tailLines[surfaceID] = "a\nb\nc"
        let endedAt = startedAt.addingTimeInterval(2)
        store.ingest(endEvent(cmdID: "cmd-2", exitCode: 7, ts: endedAt), surfaceID: surfaceID)
        // A non-empty capture redacts/truncates off the MainActor -- see
        // CommandLogStore.finalize's doc comment -- so the record isn't
        // observably .finished until this drain hook returns.
        await store._testAwaitOutputJobsDrained()

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished)
        XCTAssertEqual(record.exitCode, 7)
        XCTAssertEqual(record.endedAt, endedAt)
        let output = try XCTUnwrap(record.output, "A 3-row delta with non-empty tail lines must materialize output")
        XCTAssertEqual(output.text, "a\nb\nc")
        XCTAssertEqual(output.totalRows, 3)
        XCTAssertFalse(output.truncated)
    }

    func test_ingestStartThenEnd_zeroRowDelta_finishesWithEmptyOutput() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 50
        store.ingest(startEvent(cmdID: "cmd-3"), surfaceID: surfaceID)

        // Alt-screen case: the scrollbar total is unchanged between start
        // and end (e.g. a full-screen TUI that never touched scrollback).
        reader.rowCounts[surfaceID] = 50
        store.ingest(endEvent(cmdID: "cmd-3", exitCode: 0), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished, "A zero row delta must still finish the record, not leave it running")
        let output = try XCTUnwrap(record.output,
                                   "A zero row delta is a genuine capture (nothing changed), not a capture failure -- " +
                                   "it must materialize an explicit empty output, not nil")
        XCTAssertEqual(output.text, "")
        XCTAssertEqual(output.totalRows, 0)
        XCTAssertFalse(output.truncated)
    }

    func test_ingestStartThenEnd_positiveDeltaButEmptyTailLines_finishesWithEmptyOutput() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 50
        store.ingest(startEvent(cmdID: "cmd-3b"), surfaceID: surfaceID)

        // The row counter advanced (delta > 0) but the reader's captured
        // tail is itself an empty string -- still a genuine, successful
        // capture of "no output", not a capture failure.
        reader.rowCounts[surfaceID] = 53
        reader.tailLines[surfaceID] = ""
        store.ingest(endEvent(cmdID: "cmd-3b", exitCode: 0), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        let output = try XCTUnwrap(record.output)
        XCTAssertEqual(output.text, "")
        XCTAssertEqual(output.totalRows, 0)
        XCTAssertFalse(output.truncated)
    }

    func test_ingestStartThenEnd_readerReturnsNilAtEndTime_finishesWithNilOutput() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 50
        store.ingest(startEvent(cmdID: "cmd-reader-nil-at-end"), surfaceID: surfaceID)

        // The surface became unknown to the reader by the time the
        // command ended (e.g. it was torn down) -- this must NOT be
        // silently treated as "unchanged total, zero output"; it's a
        // genuine capture failure, distinct from a real zero-row delta.
        reader.rowCounts.removeValue(forKey: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-reader-nil-at-end", exitCode: 0), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished, "Capture failure at end time must still finish the record")
        XCTAssertNil(record.output, "A reader that can't report the surface's total at end time means capture " +
                     "is impossible, not a genuine zero-row delta")
    }

    func test_endBeforeStart_sameCmdID_mergesIntoFinishedRecord() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 10

        store.ingest(endEvent(cmdID: "cmd-4", exitCode: 3), surfaceID: surfaceID)
        XCTAssertTrue(store.records(surfaceID: surfaceID, limit: nil, state: nil).isEmpty,
                     "Precondition: an end with no prior start must not create a record by itself")

        store.ingest(startEvent(cmdID: "cmd-4", command: "make build"), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.cmdID, "cmd-4")
        XCTAssertEqual(record.command, "make build")
        XCTAssertEqual(record.state, .finished, "The pending end must merge in immediately once the start arrives")
        XCTAssertEqual(record.exitCode, 3)
    }

    func test_endWithUnknownCmdID_noStartWithinTTL_neverProducesRecord() {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        var currentTime = Date(timeIntervalSince1970: 1_700_000_000)
        store.now = { currentTime }

        // Sanity/control: an ordinary, unrelated start+end pair on the
        // same surface must actually produce a record -- otherwise the
        // "no record ever appears" assertion below would be
        // indistinguishable from a store that never produces ANY record.
        store.ingest(startEvent(cmdID: "control", ts: currentTime), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "control", exitCode: 0, ts: currentTime), surfaceID: surfaceID)
        XCTAssertEqual(store.records(surfaceID: surfaceID, limit: nil, state: nil).count, 1,
                       "Precondition: an ordinary start+end pair must produce a record")

        // The orphan end: arrives with no matching start, and none ever comes.
        store.ingest(endEvent(cmdID: "orphan-end", exitCode: 0, ts: currentTime), surfaceID: surfaceID)

        // Advance the injected clock past the pending-end TTL and ingest
        // another event, which is what triggers the sweep.
        currentTime = currentTime.addingTimeInterval(CommandLogStore.pendingEndTTL + 1)
        store.ingest(startEvent(cmdID: "trigger-sweep", ts: currentTime), surfaceID: surfaceID)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertFalse(records.contains(where: { $0.cmdID == "orphan-end" }),
                       "An end event with no start arriving within the TTL must never produce a record, " +
                       "even after the sweep")
    }

    func test_ingestEnd_duplicateEndForAlreadyFinishedCmdID_notBufferedAsPendingEnd() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1

        store.ingest(startEvent(cmdID: "reused-id", command: "first"), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "reused-id", exitCode: 0), surfaceID: surfaceID)
        XCTAssertEqual(store.records(surfaceID: surfaceID, limit: nil, state: nil).count, 1,
                       "Precondition: the first start+end pair must produce one finished record")

        // A duplicate/late end for the SAME already-finished cmd_id.
        store.ingest(endEvent(cmdID: "reused-id", exitCode: 0), surfaceID: surfaceID)

        // A NEW start reusing the same cmd_id, arriving well within the
        // pending-end TTL. If the duplicate end above had been buffered,
        // this start would be spuriously auto-finalized right here.
        store.ingest(startEvent(cmdID: "reused-id", command: "second"), surfaceID: surfaceID)

        let newRecord = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first { $0.command == "second" })
        XCTAssertEqual(newRecord.state, .running,
                       "The new start must stay running, not be spuriously finalized by the stale duplicate end")
    }

    func test_ingestEnd_staleEndFromBeforeCurrentRunningRecordStarted_isDropped() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1

        let tsA = Date(timeIntervalSince1970: 1000)
        store.ingest(startEvent(cmdID: "reused-after-orphan", command: "first", ts: tsA), surfaceID: surfaceID)
        store.markOrphaned(surfaceID: surfaceID)

        let tsB = Date(timeIntervalSince1970: 5000)
        store.ingest(startEvent(cmdID: "reused-after-orphan", command: "second", ts: tsB), surfaceID: surfaceID)

        // A stale end -- timestamped before B ever started, so it must
        // have originated from A's now-orphaned lifetime -- must not
        // finalize B.
        let staleTs = Date(timeIntervalSince1970: 2000)
        store.ingest(endEvent(cmdID: "reused-after-orphan", exitCode: 0, ts: staleTs), surfaceID: surfaceID)

        let stillRunning = store.records(surfaceID: surfaceID, limit: nil, state: .running)
        XCTAssertEqual(stillRunning.count, 1, "B must still be running -- the stale end must not finalize it")
        XCTAssertEqual(stillRunning.first?.command, "second")

        // A real end, timestamped after B started, must finalize it normally.
        let realTs = Date(timeIntervalSince1970: 6000)
        store.ingest(endEvent(cmdID: "reused-after-orphan", exitCode: 0, ts: realTs), surfaceID: surfaceID)

        let finished = store.records(surfaceID: surfaceID, limit: nil, state: .finished)
        XCTAssertEqual(finished.count, 1, "The real end (ts after B started) must finalize B")
        XCTAssertEqual(finished.first?.command, "second")
    }

    func test_duplicateStart_sameCmdID_secondIgnored() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        let firstStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.ingest(startEvent(cmdID: "cmd-6", command: "first", ts: firstStartedAt), surfaceID: surfaceID)

        let secondStartedAt = firstStartedAt.addingTimeInterval(5)
        store.ingest(startEvent(cmdID: "cmd-6", command: "second", ts: secondStartedAt), surfaceID: surfaceID)

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, 1, "A duplicate start for the same cmd_id must not create a second record")
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.command, "first", "The original start's fields must win, not the duplicate's")
        XCTAssertEqual(record.startedAt, firstStartedAt)
    }

    // MARK: - Ring capacity

    func test_ringOverflow_201FinishedCommands_evictsOldestKeepingCapacity() {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader

        for i in 0..<(CommandLogStore.ringCapacity + 1) {
            let cmdID = "cmd-\(i)"
            store.ingest(startEvent(cmdID: cmdID), surfaceID: surfaceID)
            store.ingest(endEvent(cmdID: cmdID, exitCode: 0), surfaceID: surfaceID)
        }

        let records = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(records.count, CommandLogStore.ringCapacity,
                       "The ring must cap at ringCapacity, evicting the oldest record")
        XCTAssertFalse(records.contains(where: { $0.cmdID == "cmd-0" }),
                       "The very first (oldest) command must have been evicted")
        XCTAssertTrue(records.contains(where: { $0.cmdID == "cmd-\(CommandLogStore.ringCapacity)" }),
                     "The most recently finished command must still be present")
    }

    func test_ringOverflow_evictsRunningRecord_orphansItAndResumesItsAwaiter() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader

        // Left running -- as the oldest record, it's the eviction
        // candidate once the ring overflows.
        store.ingest(startEvent(cmdID: "evictee"), surfaceID: surfaceID)
        let evicteeID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        for i in 1..<CommandLogStore.ringCapacity {
            let cmdID = "filler-\(i)"
            store.ingest(startEvent(cmdID: cmdID), surfaceID: surfaceID)
            store.ingest(endEvent(cmdID: cmdID, exitCode: 0), surfaceID: surfaceID)
        }
        XCTAssertEqual(store.records(surfaceID: surfaceID, limit: nil, state: nil).count, CommandLogStore.ringCapacity,
                       "Precondition: the ring must be exactly full before the triggering start")

        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: surfaceID, commandID: evicteeID, timeoutMs: 5000)
        }
        await yieldToScheduler()

        // One more start pushes the ring past capacity, evicting "evictee".
        store.ingest(startEvent(cmdID: "trigger-eviction"), surfaceID: surfaceID)

        let result = await waiter.value
        let evicted = try XCTUnwrap(result, "An evicted running record must resolve its awaiter, not hang until timeout")
        XCTAssertEqual(evicted.state, .orphaned)
        XCTAssertEqual(evicted.cmdID, "evictee")
    }

    // MARK: - Output truncation

    func test_outputExceedingByteCap_isTruncatedWithHeadAndTailPreserved() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-8"), surfaceID: surfaceID)

        let lineCount = 4000
        let filler = String(repeating: "x", count: 80)
        var lines: [String] = []
        lines.reserveCapacity(lineCount)
        lines.append("HEAD_MARKER_UNIQUE_TOKEN \(filler)")
        for i in 1..<(lineCount - 1) {
            lines.append("line-\(i) \(filler)")
        }
        lines.append("TAIL_MARKER_UNIQUE_TOKEN \(filler)")
        let bigText = lines.joined(separator: "\n")
        XCTAssertGreaterThan(bigText.utf8.count, CommandLogStore.outputByteCap,
                             "Precondition: the synthesized fixture must actually exceed the byte cap")

        reader.rowCounts[surfaceID] = UInt64(lineCount)
        reader.tailLines[surfaceID] = bigText
        store.ingest(endEvent(cmdID: "cmd-8", exitCode: 0), surfaceID: surfaceID)
        // A non-empty capture redacts/truncates off the MainActor -- see
        // CommandLogStore.finalize's doc comment.
        await store._testAwaitOutputJobsDrained()

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        let output = try XCTUnwrap(record.output, "A large tail must still materialize output, just truncated")

        XCTAssertTrue(output.truncated, "Output exceeding the byte cap must be marked truncated")
        XCTAssertLessThanOrEqual(output.text.utf8.count, CommandLogStore.outputByteCap,
                                 "Truncated output must never exceed the byte cap")
        XCTAssertTrue(output.text.contains("HEAD_MARKER_UNIQUE_TOKEN"), "Truncated output must retain head content")
        XCTAssertTrue(output.text.contains("TAIL_MARKER_UNIQUE_TOKEN"), "Truncated output must retain tail content")
        XCTAssertTrue(output.text.localizedCaseInsensitiveContains("truncated"),
                     "Truncated output must contain a human-readable truncation marker line")
    }

    func test_outputTruncation_multibyteCutBoundary_noReplacementCharacterInserted() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-multibyte"), surfaceID: surfaceID)

        // "あ" is 3 bytes and "😀" is 4 bytes in UTF-8 -- neither aligns
        // evenly with the byte-count cuts truncatedOutput makes, so the
        // head/tail budgets are highly likely to land mid-scalar without
        // the boundary-trimming fix.
        let unit = "あ😀"
        let lineCount = 40000
        let bigText = Array(repeating: unit, count: lineCount).joined(separator: "\n")
        XCTAssertGreaterThan(bigText.utf8.count, CommandLogStore.outputByteCap,
                             "Precondition: the fixture must exceed the byte cap")

        reader.rowCounts[surfaceID] = UInt64(lineCount)
        reader.tailLines[surfaceID] = bigText
        store.ingest(endEvent(cmdID: "cmd-multibyte", exitCode: 0), surfaceID: surfaceID)
        // A non-empty capture redacts/truncates off the MainActor -- see
        // CommandLogStore.finalize's doc comment.
        await store._testAwaitOutputJobsDrained()

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        let output = try XCTUnwrap(record.output)

        XCTAssertTrue(output.truncated)
        XCTAssertLessThanOrEqual(output.text.utf8.count, CommandLogStore.outputByteCap,
                                 "A boundary-trimmed cut must never push the byte count back over the cap")
        XCTAssertFalse(output.text.unicodeScalars.contains(Unicode.Scalar(0xFFFD)!),
                       "A cut at a multi-byte boundary must never insert a U+FFFD replacement character")
    }

    // MARK: - awaitCompletion

    func test_awaitCompletion_resumesWhenEndArrives() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 5
        store.ingest(startEvent(cmdID: "cmd-9"), surfaceID: surfaceID)

        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: surfaceID, commandID: nil, timeoutMs: 5000)
        }
        await yieldToScheduler()

        reader.rowCounts[surfaceID] = 8
        reader.tailLines[surfaceID] = "x\ny\nz"
        store.ingest(endEvent(cmdID: "cmd-9", exitCode: 0), surfaceID: surfaceID)

        let result = await waiter.value
        let record = try XCTUnwrap(result, "awaitCompletion must resume with the finished record once the end event arrives")
        XCTAssertEqual(record.cmdID, "cmd-9")
        XCTAssertEqual(record.state, .finished)
    }

    // NOTE (deviation flagged, see report): this scenario originally used
    // commandID: nil with nothing running on the surface at all -- under
    // finding 11's corrected semantics that case now returns nil
    // IMMEDIATELY (see test_awaitCompletion_nilCommandID_noRunningRecord_returnsNilImmediately
    // below), which directly contradicted this test's own "must wait
    // close to the full timeout" assertion. Repurposed to a concrete,
    // still-running commandID so the genuine bounded-wait mechanism
    // (the one thing this test exists to prove) still has coverage.
    func test_awaitCompletion_timeoutElapsesWithNoEnd_returnsNilAfterWaiting() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-timeout"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        let start = Date()
        let result = await store.awaitCompletion(surfaceID: surfaceID, commandID: commandID, timeoutMs: 200)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "No end event ever arrived within the timeout, so awaitCompletion must return nil")
        // Guards against a trivial "always return nil immediately"
        // implementation: a real timeout must actually wait close to the
        // full duration before giving up.
        XCTAssertGreaterThanOrEqual(elapsed, 0.15,
                                    "awaitCompletion must wait close to the full timeoutMs before returning nil, " +
                                    "not return immediately")
    }

    func test_awaitCompletion_nilCommandID_noRunningRecord_returnsNilImmediately() async {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader

        let start = Date()
        let result = await store.awaitCompletion(surfaceID: surfaceID, commandID: nil, timeoutMs: 5000)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "With nothing running on the surface, a nil commandID has nothing to wait for")
        XCTAssertLessThan(elapsed, 0.1,
                          "A nil commandID with no running record must return nil immediately, not wait for the timeout")
    }

    func test_awaitCompletion_negativeTimeoutMs_clampsToZero_returnsNilWithoutTrapping() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-neg-timeout"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        let result = await store.awaitCompletion(surfaceID: surfaceID, commandID: commandID, timeoutMs: -1)

        XCTAssertNil(result, "A negative timeoutMs must clamp to 0 and return nil promptly, not trap on UInt64(-1)")
    }

    func test_awaitCompletion_zeroTimeoutMs_returnsNilImmediatelyWhenStillRunning() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-zero-timeout"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        let start = Date()
        let result = await store.awaitCompletion(surfaceID: surfaceID, commandID: commandID, timeoutMs: 0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "The record is still running and never finishes, so a 0ms timeout must give up immediately")
        XCTAssertLessThan(elapsed, 0.1, "timeoutMs: 0 must return nil almost immediately, not wait")
    }

    func test_awaitCompletion_timedOutWait_leavesNoAwaiterHuskBehind() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-husk"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        let result = await store.awaitCompletion(surfaceID: surfaceID, commandID: commandID, timeoutMs: 50)
        XCTAssertNil(result)

        XCTAssertEqual(store._testAwaiterCount, 0,
                       "A timed-out wait must unregister its bridge, not leave a husk behind")

        // A subsequent end-ingest for the same command must not touch any
        // dead bridge (e.g. by double-resuming it) -- it should complete
        // without incident and leave the awaiter count still at zero.
        store.ingest(endEvent(cmdID: "cmd-husk", exitCode: 0), surfaceID: surfaceID)
        XCTAssertEqual(store._testAwaiterCount, 0)
    }

    func test_awaitCompletion_cancelledWait_leavesNoAwaiterHuskBehind() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-husk-cancel"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: surfaceID, commandID: commandID, timeoutMs: 5000)
        }
        await yieldToScheduler()

        waiter.cancel()
        _ = await waiter.value

        // The onCancel handler's cleanup hops onto MainActor asynchronously
        // (see waitForRecord's doc comment); give it a chance to run.
        await yieldToScheduler()

        XCTAssertEqual(store._testAwaiterCount, 0,
                       "A cancelled wait must unregister its bridge, not leave a husk behind")
    }

    func test_testReset_resumesSuspendedAwaitCompletionWithNil() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-reset"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: surfaceID, commandID: commandID, timeoutMs: 5000)
        }
        await yieldToScheduler()

        store._testReset()

        let result = await waiter.value
        XCTAssertNil(result, "_testReset must resume any suspended awaitCompletion with nil instead of leaving it to hang")
    }

    func test_awaitCompletion_nilCommandID_waitsOnNewestRunningRecord() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-11-old"), surfaceID: surfaceID)
        store.ingest(startEvent(cmdID: "cmd-11-new"), surfaceID: surfaceID)

        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: surfaceID, commandID: nil, timeoutMs: 5000)
        }
        await yieldToScheduler()

        // Finish the OLDER command first -- if a nil commandID resolved
        // against the oldest running record instead of the newest, this
        // would incorrectly resume the waiter right here.
        store.ingest(endEvent(cmdID: "cmd-11-old", exitCode: 0), surfaceID: surfaceID)
        await yieldToScheduler()

        // Now finish the newer command -- this is the one a nil-commandID
        // waiter must actually resolve against.
        store.ingest(endEvent(cmdID: "cmd-11-new", exitCode: 0), surfaceID: surfaceID)

        let result = await waiter.value
        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.cmdID, "cmd-11-new",
                       "A nil commandID must wait on the NEWEST running record at call time, not the oldest")
    }

    // MARK: - awaitNextCompletion

    func test_awaitNextCompletion_correlatesToCommandStartedAfterT_notEarlierStillRunning() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        let oldStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        store.ingest(startEvent(cmdID: "cmd-old", ts: oldStartedAt), surfaceID: surfaceID)

        let startedAfter = oldStartedAt.addingTimeInterval(1)

        let waiter = Task { @MainActor in
            await store.awaitNextCompletion(surfaceID: surfaceID, startedAfter: startedAfter, timeoutMs: 5000)
        }
        await yieldToScheduler()

        // Finish the OLDER command first -- it started BEFORE startedAfter,
        // so this must NOT satisfy the waiter (unlike
        // awaitCompletion(commandID: nil)'s eager newest-running-record
        // resolution, which has no such predicate and would latch onto
        // this one).
        store.ingest(endEvent(cmdID: "cmd-old", exitCode: 0, ts: oldStartedAt.addingTimeInterval(0.5)), surfaceID: surfaceID)
        await yieldToScheduler()

        // Now start and finish a NEWER command -- this is the one the
        // waiter must actually resolve against.
        let newStartedAt = startedAfter.addingTimeInterval(1)
        store.ingest(startEvent(cmdID: "cmd-new", ts: newStartedAt), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-new", exitCode: 0, ts: newStartedAt.addingTimeInterval(0.5)), surfaceID: surfaceID)

        let result = await waiter.value
        let record = try XCTUnwrap(result, "awaitNextCompletion must resume once a command started after startedAfter finishes")
        XCTAssertEqual(record.cmdID, "cmd-new",
                       "must correlate to the command that started AFTER startedAfter, not an earlier already-running one")
    }

    func test_awaitNextCompletion_alreadyFinishedRecord_returnsImmediately() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        let startedAfter = Date(timeIntervalSince1970: 1_700_000_000)
        let startedAt = startedAfter.addingTimeInterval(1)
        store.ingest(startEvent(cmdID: "cmd-already-done", ts: startedAt), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-already-done", exitCode: 0, ts: startedAt.addingTimeInterval(0.5)), surfaceID: surfaceID)

        let start = Date()
        let result = await store.awaitNextCompletion(surfaceID: surfaceID, startedAfter: startedAfter, timeoutMs: 5000)
        let elapsed = Date().timeIntervalSince(start)

        let record = try XCTUnwrap(result)
        XCTAssertEqual(record.cmdID, "cmd-already-done")
        XCTAssertLessThan(elapsed, 0.1, "an already-finished qualifying record must resolve immediately, not wait")
    }

    func test_awaitNextCompletion_timeoutElapsesWithNothingStarting_returnsNilAfterWaiting() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader

        let start = Date()
        let result = await store.awaitNextCompletion(surfaceID: surfaceID, startedAfter: Date(), timeoutMs: 200)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "nothing ever started after startedAfter, so awaitNextCompletion must time out to nil")
        XCTAssertGreaterThanOrEqual(elapsed, 0.15,
                                    "must wait close to the full timeoutMs before giving up, not return immediately")
    }

    func test_testReset_resumesSuspendedAwaitNextCompletionWithNil() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader

        let waiter = Task { @MainActor in
            await store.awaitNextCompletion(surfaceID: surfaceID, startedAfter: Date(), timeoutMs: 5000)
        }
        await yieldToScheduler()

        store._testReset()

        let result = await waiter.value
        XCTAssertNil(result, "_testReset must resume any suspended awaitNextCompletion with nil instead of leaving it to hang")
    }

    // MARK: - markOrphaned

    func test_markOrphaned_transitionsRunningRecordsAndResumesAwaiters() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-12"), surfaceID: surfaceID)

        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: surfaceID, commandID: nil, timeoutMs: 5000)
        }
        await yieldToScheduler()

        store.markOrphaned(surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .orphaned, "markOrphaned must transition every running record for the surface to .orphaned")

        let waiterResult = await waiter.value
        let awaited = try XCTUnwrap(waiterResult, "A pending awaitCompletion must resume once its record is orphaned")
        XCTAssertEqual(awaited.state, .orphaned)
    }

    func test_markOrphaned_resumesInFlightAwaitNextCompletionWithNilPromptly() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader

        let waiter = Task { @MainActor in
            await store.awaitNextCompletion(surfaceID: surfaceID, startedAfter: Date(), timeoutMs: 5000)
        }
        await yieldToScheduler()

        let start = Date()
        store.markOrphaned(surfaceID: surfaceID)
        let result = await waiter.value
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(result, "markOrphaned must resume a pending awaitNextCompletion with nil -- no command " +
                     "will ever finish on a gone surface")
        XCTAssertLessThan(elapsed, 0.1, "must resolve promptly on markOrphaned, not idle out the full timeout")
    }

    // MARK: - duration derivation

    func test_finalize_derivesDurationFromStartAndEndTimestamps() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1
        // ts 1_000ms / 1_500ms, expressed as the Date CommandEvent.decode
        // would produce from those raw epoch-millisecond values.
        let startedAt = Date(timeIntervalSince1970: 1.0)
        let endedAt = Date(timeIntervalSince1970: 1.5)
        store.ingest(startEvent(cmdID: "cmd-duration", ts: startedAt), surfaceID: surfaceID)
        store.ingest(endEvent(cmdID: "cmd-duration", exitCode: 0, ts: endedAt), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.durationNanos, 500_000_000, "durationNanos must be endedAt - startedAt in nanoseconds")
    }

    func test_finalize_endBeforeStart_clockSkew_durationClampsToZero_noTrap() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1

        // The end arrives (and buffers) before its matching start, with a
        // ts that's chronologically BEFORE the eventual start's own ts
        // (clock skew between the two hook invocations) -- finalize must
        // clamp the resulting negative interval to 0, not underflow
        // UInt64 or trap.
        let endedAt = Date(timeIntervalSince1970: 1.0)
        store.ingest(endEvent(cmdID: "cmd-skew", exitCode: 0, ts: endedAt), surfaceID: surfaceID)

        let startedAt = Date(timeIntervalSince1970: 2.0)
        store.ingest(startEvent(cmdID: "cmd-skew", ts: startedAt), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished)
        XCTAssertEqual(record.durationNanos, 0,
                       "A negative elapsed time (clock skew, end ts before start ts) must clamp to 0, not " +
                       "underflow UInt64 or trap")
    }

    func test_finalize_endedAtCenturiesAfterStartedAt_durationClampsToCeiling_noTrap() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 1

        let startedAt = Date(timeIntervalSince1970: 0)
        store.ingest(startEvent(cmdID: "cmd-overflow", ts: startedAt), surfaceID: surfaceID)

        // Constructed directly (bypassing CommandEvent.decode, which now
        // rejects a ts this implausible outright -- see
        // test_decode_tsAboveMaximumPlausibleMillisThreshold_treatedAsAbsent):
        // a wildly-far-future endedAt, ~31,700 years past startedAt, must
        // not overflow UInt64 on finalize's `* 1_000_000_000` nanosecond
        // conversion.
        let endedAt = Date(timeIntervalSince1970: 1_000_000_000_000)
        store.ingest(endEvent(cmdID: "cmd-overflow", exitCode: 0, ts: endedAt), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished, "An extreme elapsed duration must still finish the record, not trap")
        XCTAssertEqual(record.durationNanos, 1_000_000_000_000_000_000,
                       "durationNanos must clamp to the plausibility ceiling, not overflow UInt64")
    }

    // MARK: - remapSurface

    func test_remapSurface_movesRecordsClearsScrollbarStart_andResumesAwaitsByCommandID() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let oldSurfaceID = UUID()
        let newSurfaceID = UUID()
        store.reader = reader
        reader.rowCounts[oldSurfaceID] = 1
        reader.rowCounts[newSurfaceID] = 1
        store.ingest(startEvent(cmdID: "cmd-14"), surfaceID: oldSurfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: oldSurfaceID, limit: nil, state: nil).first).id

        // awaitCompletion's commandID path resolves by id regardless of
        // surfaceID (advisory when commandID is given) -- so this waiter,
        // registered against newSurfaceID before the record has even
        // moved there, must still resume once remapSurface moves it and
        // the end event finalizes it.
        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: newSurfaceID, commandID: commandID, timeoutMs: 5000)
        }
        await yieldToScheduler()

        store.remapSurface(old: oldSurfaceID, new: newSurfaceID)

        let newRecords = store.records(surfaceID: newSurfaceID, limit: nil, state: nil)
        XCTAssertEqual(newRecords.count, 1, "remapSurface must move the record to the new surfaceID")
        XCTAssertNil(newRecords.first?.contentRowCountAtStart,
                     "remapSurface must clear contentRowCountAtStart -- the new surfaceID has its own scrollback " +
                     "counter, so the old captured value is meaningless against it")
        XCTAssertTrue(store.records(surfaceID: oldSurfaceID, limit: nil, state: nil).isEmpty,
                     "remapSurface must leave nothing behind under the old surfaceID")

        store.ingest(endEvent(cmdID: "cmd-14", exitCode: 0), surfaceID: newSurfaceID)

        let waiterResult = await waiter.value
        let awaited = try XCTUnwrap(waiterResult,
                                    "A running record's completion via the new surfaceID must resume an await " +
                                    "made against its commandID, unaffected by the surface remap")
        XCTAssertEqual(awaited.cmdID, "cmd-14")
        XCTAssertNil(awaited.output, "Output capture is forfeited for a command remapped mid-flight " +
                     "(contentRowCountAtStart was cleared)")
    }

    func test_remapSurface_movesInFlightAwaitNextCompletionWaiter_resolvesOnNewSurfaceFinalize() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let oldSurfaceID = UUID()
        let newSurfaceID = UUID()
        store.reader = reader
        reader.rowCounts[oldSurfaceID] = 1
        reader.rowCounts[newSurfaceID] = 1

        let startedAfter = Date(timeIntervalSince1970: 1_700_000_000)

        let waiter = Task { @MainActor in
            await store.awaitNextCompletion(surfaceID: oldSurfaceID, startedAfter: startedAfter, timeoutMs: 5000)
        }
        await yieldToScheduler()

        store.remapSurface(old: oldSurfaceID, new: newSurfaceID)

        // The command starts and finishes AFTER the remap, under the new
        // surfaceID -- if the waiter were stranded under oldSurfaceID
        // (not carried over by remapSurface), this finalize would never
        // reach it and the wait would idle out the full timeout instead
        // of resolving, giving the caller a false {"status":"timeout"}
        // despite the command actually succeeding.
        let startedAt = startedAfter.addingTimeInterval(1)
        store.ingest(startEvent(cmdID: "cmd-remap", ts: startedAt), surfaceID: newSurfaceID)
        store.ingest(endEvent(cmdID: "cmd-remap", exitCode: 0, ts: startedAt.addingTimeInterval(0.5)), surfaceID: newSurfaceID)

        let result = await waiter.value
        let record = try XCTUnwrap(result, "a remapped in-flight awaitNextCompletion must resolve on the new " +
                                   "surface's finalize, not strand under the old one")
        XCTAssertEqual(record.cmdID, "cmd-remap")
    }

    // MARK: - records(limit:state:) filtering

    func test_records_limitAndStateFiltering() {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0

        for i in 0..<3 {
            let cmdID = "finished-\(i)"
            store.ingest(startEvent(cmdID: cmdID), surfaceID: surfaceID)
            store.ingest(endEvent(cmdID: cmdID, exitCode: 0), surfaceID: surfaceID)
        }
        store.ingest(startEvent(cmdID: "running-1"), surfaceID: surfaceID)
        store.ingest(startEvent(cmdID: "running-2"), surfaceID: surfaceID)

        let all = store.records(surfaceID: surfaceID, limit: nil, state: nil)
        XCTAssertEqual(all.count, 5, "With no filter, every record for the surface must be returned")

        let runningOnly = store.records(surfaceID: surfaceID, limit: nil, state: .running)
        XCTAssertEqual(runningOnly.count, 2, "state: .running must return only the still-running records")
        XCTAssertTrue(runningOnly.allSatisfy { $0.state == .running })

        let finishedOnly = store.records(surfaceID: surfaceID, limit: nil, state: .finished)
        XCTAssertEqual(finishedOnly.count, 3, "state: .finished must return only the finished records")

        let limited = store.records(surfaceID: surfaceID, limit: 2, state: nil)
        XCTAssertEqual(limited.count, 2, "limit: 2 must cap the returned records to 2")
    }

    // MARK: - Secret redaction

    func test_ingestStart_secretishCommand_storedCommandIsRedacted() throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader

        store.ingest(startEvent(cmdID: "cmd-secret-start", command: "export MY_TOKEN=abc123"), surfaceID: surfaceID)

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.command, "export MY_TOKEN=[redacted]")
        XCTAssertFalse(record.command.contains("abc123"), "the raw secret value must never reach the stored record")
    }

    func test_finalize_outputContainingSecrets_storedOutputIsRedacted() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-secret-output"), surfaceID: surfaceID)

        reader.rowCounts[surfaceID] = 2
        reader.tailLines[surfaceID] = "OPENAI_API_KEY=sk-test1234567890abcdefghij\nplain line"
        store.ingest(endEvent(cmdID: "cmd-secret-output", exitCode: 0), surfaceID: surfaceID)
        // A non-empty capture redacts off the MainActor -- see
        // CommandLogStore.finalize's doc comment.
        await store._testAwaitOutputJobsDrained()

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        let output = try XCTUnwrap(record.output, "a positive row delta with a non-empty tail must materialize output")
        XCTAssertTrue(output.text.contains("OPENAI_API_KEY=[redacted]"))
        XCTAssertFalse(output.text.contains("sk-test1234567890abcdefghij"), "the raw secret value must never reach stored output")
        XCTAssertTrue(output.text.contains("plain line"), "non-secret content must survive redaction untouched")
    }

    func test_finalize_secretAtTruncationBoundary_redactedBeforeTruncation() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-boundary"), surfaceID: surfaceID)

        // A valid ghp_ token (40 raw bytes: "ghp_" + 36 alnum) positioned
        // so it straddles the ~127KB head-budget cut that
        // truncatedOutput(text:totalRows:) makes once text exceeds
        // CommandLogStore.outputByteCap -- redaction must happen BEFORE
        // that cut is computed, so no raw fragment of the token can
        // survive on either side of it, regardless of exactly where the
        // cut lands.
        let token = "ghp_iK2ZWeqhFWCEPyYngFb51yBMWXaSCrUZoL8g"
        XCTAssertEqual(token.utf8.count, 40, "precondition: token must be 40 raw bytes long")
        let before = String(repeating: "x", count: 131_028)
        let after = String(repeating: "y", count: 168_932)
        let bigText = before + token + after
        XCTAssertGreaterThan(bigText.utf8.count, CommandLogStore.outputByteCap,
                             "Precondition: the fixture must exceed the byte cap")

        reader.rowCounts[surfaceID] = 1
        reader.tailLines[surfaceID] = bigText
        store.ingest(endEvent(cmdID: "cmd-boundary", exitCode: 0), surfaceID: surfaceID)
        // A non-empty capture redacts/truncates off the MainActor -- see
        // CommandLogStore.finalize's doc comment.
        await store._testAwaitOutputJobsDrained()

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        let output = try XCTUnwrap(record.output, "a large tail must still materialize output, just truncated")

        XCTAssertTrue(output.truncated, "output exceeding the byte cap must still be marked truncated")
        for start in 0...(token.count - 12) {
            let windowStart = token.index(token.startIndex, offsetBy: start)
            let windowEnd = token.index(windowStart, offsetBy: 12)
            let window = String(token[windowStart..<windowEnd])
            XCTAssertFalse(output.text.contains(window),
                           "no 12-char raw-token fragment must survive truncation -- redaction must happen " +
                           "BEFORE the byte-cap cut, not after")
        }
    }

    // MARK: - Async output redaction

    func test_ingestEnd_duplicateEndDuringAsyncRedactionGap_isDroppedNotBuffered() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-dup-gap", command: "first"), surfaceID: surfaceID)

        // A non-empty capture defers redaction to an async job -- see
        // CommandLogStore.finalize's doc comment -- so the record is still
        // internally "finalizing" (though externally .running) right
        // after this ingest, before the drain hook below runs.
        reader.rowCounts[surfaceID] = 1
        reader.tailLines[surfaceID] = "some output"
        store.ingest(endEvent(cmdID: "cmd-dup-gap", exitCode: 0), surfaceID: surfaceID)

        // A duplicate/late end for the SAME cmd_id, arriving while the
        // first end's output redaction is still in flight, must be
        // dropped -- neither re-finalizing the original record nor
        // buffered as a pending end (which would let the new start just
        // below get spuriously auto-finalized by it).
        store.ingest(endEvent(cmdID: "cmd-dup-gap", exitCode: 99), surfaceID: surfaceID)

        // A new start reusing the same cmd_id, arriving well within the
        // pending-end TTL, must create a genuinely fresh running record --
        // not be swallowed by the "already running" dedup (the original
        // record is only finalizing, not truly still running) and not be
        // spuriously finalized by the buffered duplicate end.
        store.ingest(startEvent(cmdID: "cmd-dup-gap", command: "second"), surfaceID: surfaceID)
        let newRecord = try XCTUnwrap(
            store.records(surfaceID: surfaceID, limit: nil, state: nil).first { $0.command == "second" }
        )
        XCTAssertEqual(newRecord.state, .running,
                       "the new start must stay running, not be spuriously finalized by the dropped duplicate end")

        await store._testAwaitOutputJobsDrained()

        let firstRecord = try XCTUnwrap(
            store.records(surfaceID: surfaceID, limit: nil, state: nil).first { $0.command == "first" }
        )
        XCTAssertEqual(firstRecord.state, .finished, "the original record's own async job must still complete normally")
        XCTAssertEqual(firstRecord.exitCode, 0,
                       "the duplicate end's exitCode (99) must never have re-finalized the original record")
    }

    func test_markOrphaned_duringAsyncRedactionGap_resumesAwaiterWithOrphanedRecord_lateJobAttachesNothing() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-orphan-gap"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        let waiter = Task { @MainActor in
            await store.awaitCompletion(surfaceID: surfaceID, commandID: commandID, timeoutMs: 5000)
        }
        await yieldToScheduler()

        // Non-empty capture -> the async output-redaction job is
        // scheduled but has not yet run (still on this same MainActor
        // turn) when markOrphaned below tears the surface down.
        reader.rowCounts[surfaceID] = 1
        reader.tailLines[surfaceID] = "OPENAI_API_KEY=sk-test1234567890abcdefghij"
        store.ingest(endEvent(cmdID: "cmd-orphan-gap", exitCode: 0), surfaceID: surfaceID)

        store.markOrphaned(surfaceID: surfaceID)

        let result = await waiter.value
        let orphaned = try XCTUnwrap(result, "an in-flight awaitCompletion must resume once its record is " +
                                      "orphaned, even while its output redaction job is still pending")
        XCTAssertEqual(orphaned.state, .orphaned)
        XCTAssertNil(orphaned.output, "the record must be observed as orphaned with no output -- the pending " +
                      "redaction job must not have attached output before markOrphaned resumed the awaiter")

        // The late-arriving job must drop silently rather than resurrect
        // the record as .finished after it was already orphaned.
        await store._testAwaitOutputJobsDrained()

        let afterDrain = try XCTUnwrap(store.record(id: commandID))
        XCTAssertEqual(afterDrain.state, .orphaned,
                       "the late-arriving output job must not overwrite an already-orphaned record's state")
        XCTAssertNil(afterDrain.output, "the late-arriving output job must not attach output to an " +
                     "already-orphaned record")
    }

    func test_isFinalizing_trueDuringAsyncRedactionGap_falseAfterDrain() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-isfinalizing"), surfaceID: surfaceID)
        let commandID = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first).id

        XCTAssertFalse(store.isFinalizing(id: commandID),
                        "a genuinely still-running record (no end event yet) must not read as finalizing")

        // A non-empty capture defers redaction to an async job -- see
        // CommandLogStore.finalize's doc comment -- so immediately after
        // this ingest (same MainActor turn, no yield), the record must
        // read as finalizing until the job attaches output.
        reader.rowCounts[surfaceID] = 1
        reader.tailLines[surfaceID] = "some output"
        store.ingest(endEvent(cmdID: "cmd-isfinalizing", exitCode: 0), surfaceID: surfaceID)

        XCTAssertTrue(store.isFinalizing(id: commandID),
                       "immediately after a non-empty capture's end event, the record must read as " +
                       "finalizing until its async redaction job attaches output")

        await store._testAwaitOutputJobsDrained()

        XCTAssertFalse(store.isFinalizing(id: commandID),
                        "once the job drains and attaches output, the record must no longer read as finalizing")
        XCTAssertFalse(store.isFinalizing(id: UUID()), "an unknown id must simply read false, not throw or trap")
    }

    func test_finalizeAsyncJob_afterDrainHook_recordFinishedWithRedactedOutput() async throws {
        let store = CommandLogStore()
        let reader = FakeOutputReader()
        let surfaceID = UUID()
        store.reader = reader
        reader.rowCounts[surfaceID] = 0
        store.ingest(startEvent(cmdID: "cmd-async-drain"), surfaceID: surfaceID)

        reader.rowCounts[surfaceID] = 1
        reader.tailLines[surfaceID] = "OPENAI_API_KEY=sk-test1234567890abcdefghij"
        store.ingest(endEvent(cmdID: "cmd-async-drain", exitCode: 0), surfaceID: surfaceID)

        // Immediately after ingestEnd (same MainActor turn, no await yet),
        // the async output-redaction job cannot have run -- the record
        // must not yet be observably .finished.
        let midGap = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(midGap.state, .running,
                       "output redaction for a non-empty capture must run asynchronously, not synchronously " +
                       "inside ingest")
        XCTAssertNil(midGap.output, "output must not be attached until the async job completes")

        await store._testAwaitOutputJobsDrained()

        let record = try XCTUnwrap(store.records(surfaceID: surfaceID, limit: nil, state: nil).first)
        XCTAssertEqual(record.state, .finished,
                       "after the drain hook, the async job must have completed and attached output")
        let output = try XCTUnwrap(record.output)
        XCTAssertTrue(output.text.contains("OPENAI_API_KEY=[redacted]"))
        XCTAssertFalse(output.text.contains("sk-test1234567890abcdefghij"),
                       "the raw secret value must never reach stored output")
    }
}
