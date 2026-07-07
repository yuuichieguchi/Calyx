// CommandLogStore.swift
// Calyx
//
// In-memory, per-surface ring buffer of CommandRecord, built by ingesting
// CommandEvent start/end pairs from the shell integration. Mirrors
// IPCStore's appendCapped ring-eviction pattern (see
// IPCStore.appendCapped(_:to:)), scoped per surfaceID instead of a single
// global store.

import Foundation

@MainActor
final class CommandLogStore {

    static let shared = CommandLogStore()

    /// Injectable output reader -- production wires this to the live
    /// Ghostty surface; tests substitute a fake.
    var reader: CommandOutputReading?
    /// Injectable clock, for deterministic pendingEndTTL sweep tests.
    var now: () -> Date = { Date() }

    static let ringCapacity = 200
    static let pendingEndCapacityPerSurface = 32
    static let pendingEndTTL: TimeInterval = 10
    static let outputByteCap = 256 * 1024

    /// Marker line inserted between the kept head and tail halves of a
    /// truncated output, per `truncatedOutput(text:totalRows:)`.
    private static let truncationMarker = "\n…[truncated]…\n"

    private var recordsBySurface: [UUID: [CommandRecord]] = [:]
    /// End events that arrived before their matching start, keyed by the
    /// surface they were ingested on; swept lazily (oldest-first) by
    /// `sweepExpiredPendingEnds(surfaceID:)` on every subsequent ingest.
    private var pendingEndsBySurface: [UUID: [PendingEnd]] = [:]
    /// Awaiters resolved by a specific record's completion. `awaitCompletion`
    /// always resolves to a concrete record id before registering here --
    /// see that method's doc comment.
    private var awaitersByRecordID: [UUID: [CommandAwaitBridge]] = [:]

    private struct PendingEnd {
        let cmdID: String
        let exitCode: Int32?
        let ts: Date?
        let receivedAt: Date
    }

    init() {}

    // MARK: - Ingest

    func ingest(_ event: CommandEvent, surfaceID: UUID) {
        sweepExpiredPendingEnds(surfaceID: surfaceID)
        switch event.phase {
        case .start:
            ingestStart(event, surfaceID: surfaceID)
        case .end:
            ingestEnd(event, surfaceID: surfaceID)
        }
    }

    private func ingestStart(_ event: CommandEvent, surfaceID: UUID) {
        // decode(from:) guarantees command_b64 was present on a .start
        // event; a hand-built CommandEvent (as tests construct) that
        // violates that invariant is simply dropped rather than crashing.
        guard let command = event.command else { return }
        let cwd = event.cwd ?? ""
        let startedAt = event.ts ?? now()

        let alreadyRunning = recordsBySurface[surfaceID]?.contains {
            $0.cmdID == event.cmdID && $0.state == .running
        } ?? false
        if alreadyRunning { return }

        let record = CommandRecord(
            id: UUID(),
            cmdID: event.cmdID,
            surfaceID: surfaceID,
            command: command,
            cwd: cwd,
            startedAt: startedAt,
            endedAt: nil,
            exitCode: nil,
            durationNanos: nil,
            output: nil,
            state: .running,
            scrollbarTotalAtStart: reader?.scrollbarTotal(surfaceID: surfaceID)
        )
        appendCapped(record, surfaceID: surfaceID)

        if let pending = takePendingEnd(surfaceID: surfaceID, cmdID: event.cmdID) {
            finalize(surfaceID: surfaceID, recordID: record.id, scriptExitCode: pending.exitCode, endedAt: pending.ts ?? now())
        }
    }

    private func ingestEnd(_ event: CommandEvent, surfaceID: UUID) {
        guard let running = runningRecord(surfaceID: surfaceID, cmdID: event.cmdID) else {
            // A duplicate/late end for a cmd_id that's already finalized
            // on this surface must NOT be buffered: buffering it would
            // let a LATER start that reuses the same cmd_id (a real
            // possibility -- shell integrations commonly recycle a
            // counter) get spuriously auto-finalized by this stale end
            // the moment it starts.
            guard !hasNonRunningRecord(surfaceID: surfaceID, cmdID: event.cmdID) else { return }
            bufferPendingEnd(event, surfaceID: surfaceID)
            return
        }
        // A stale end generated before the CURRENT running record even
        // started -- e.g. the previous instance of this cmd_id was
        // orphaned (markOrphaned) and the shell integration later reused
        // the same cmd_id for a fresh command -- must not finalize the
        // new one. Same clock domain: both startedAt and event.ts derive
        // from the shell integration's own hook ts.
        if let ts = event.ts, ts < running.startedAt { return }
        finalize(surfaceID: surfaceID, recordID: running.id, scriptExitCode: event.exitCode, endedAt: event.ts ?? now())
    }

    /// Ceiling on `finalize`'s derived `durationNanos`, in seconds
    /// (1e9s ≈ 31.7 years -- far beyond any real command, but small
    /// enough that `* 1_000_000_000` lands at exactly 1e18ns, safely
    /// inside `UInt64.max` (~1.8e19) with headroom to spare). A plain
    /// `Double(UInt64.max) / 1_000_000_000` ceiling looks equivalent but
    /// ISN'T: `Double` can't represent `UInt64.max` exactly, so dividing
    /// then re-multiplying by 1e9 rounds back up past `UInt64.max` and
    /// `UInt64(...)` still traps at that "ceiling" -- verified empirically.
    /// This fixed, round-trip-safe constant sidesteps that entirely.
    private static let maximumPlausibleDurationSeconds: Double = 1_000_000_000

    /// Transitions a running record to `.finished`: applies the script's
    /// own exit code, derives `durationNanos` from `endedAt - startedAt`
    /// clamped to `[0, maximumPlausibleDurationSeconds]` -- 0 for clock
    /// skew (an `endedAt` at or before `startedAt` must never underflow
    /// the unsigned nanosecond count), the ceiling for a wildly-implausible
    /// `endedAt` (e.g. a garbage-but-decode-plausible `ts`, which would
    /// otherwise overflow `UInt64` on the `* 1_000_000_000` conversion
    /// below and fatal-trap the whole app on one authenticated
    /// `/command-event` POST) -- materializes output, and resumes any
    /// awaiters. This is the ONLY place `durationNanos` is ever set:
    /// ghostty's own OSC133 command-finished signal reports an unreliable
    /// exit code (ghostty always sends 0 for "unknown", indistinguishable
    /// from a real success) and was dropped entirely in favor of this --
    /// deriving duration from the shell integration's own start/end
    /// timestamps is both simpler and always correct to millisecond
    /// precision.
    private func finalize(surfaceID: UUID, recordID: UUID, scriptExitCode: Int32?, endedAt: Date) {
        guard var records = recordsBySurface[surfaceID],
              let index = records.firstIndex(where: { $0.id == recordID }) else { return }
        var record = records[index]
        guard record.state == .running else { return }

        record.endedAt = endedAt
        record.exitCode = scriptExitCode
        let elapsedSeconds = endedAt.timeIntervalSince(record.startedAt)
        let clampedSeconds = min(max(elapsedSeconds, 0), Self.maximumPlausibleDurationSeconds)
        record.durationNanos = UInt64(clampedSeconds * 1_000_000_000)
        record.output = materializeOutput(surfaceID: surfaceID, record: record)
        record.state = .finished

        records[index] = record
        recordsBySurface[surfaceID] = records
        resumeAwaiters(for: record)
    }

    // MARK: - Output materialization

    /// Capture is impossible (nil) only when there's no reader, no
    /// captured starting counter, or the surface's counter somehow went
    /// backwards. Every other case -- a genuine zero-row delta (e.g. an
    /// alt-screen TUI that never touched scrollback) or a positive delta
    /// whose captured tail happens to be empty -- materializes as an
    /// explicit empty `CommandOutput`, not nil, so callers can tell
    /// "captured, nothing there" from "couldn't capture at all".
    private func materializeOutput(surfaceID: UUID, record: CommandRecord) -> CommandOutput? {
        guard let reader, let start = record.scrollbarTotalAtStart else { return nil }
        // The surface being unknown to the reader at end time (e.g. torn
        // down) is a genuine capture failure, not "unchanged total" --
        // falling back to `start` here would silently misreport it as a
        // real zero-row-delta output.
        guard let end = reader.scrollbarTotal(surfaceID: surfaceID) else { return nil }
        guard end >= start else { return nil }
        guard end > start else {
            return CommandOutput(text: "", truncated: false, totalRows: 0)
        }
        let delta = end - start
        guard let text = reader.readScreenTailLines(surfaceID: surfaceID, count: Int(delta)), !text.isEmpty else {
            return CommandOutput(text: "", truncated: false, totalRows: 0)
        }
        return Self.truncatedOutput(text: text, totalRows: Int(delta))
    }

    /// Keeps the head and tail halves of `text` under `outputByteCap`
    /// bytes (splitting the remaining budget after the marker line in
    /// half), joined by `truncationMarker`. Cuts on raw UTF-8 byte
    /// offsets, not row boundaries, so `trimmingIncompleteUTF8Suffix`/
    /// `trimmingIncompleteUTF8Prefix` drop any partial multi-byte scalar
    /// stranded at a cut edge before decoding -- otherwise
    /// `String(decoding:as:)` would repair it with a U+FFFD replacement
    /// character, which both corrupts the text and can push the final
    /// byte count back over the cap.
    private static func truncatedOutput(text: String, totalRows: Int) -> CommandOutput {
        guard text.utf8.count > outputByteCap else {
            return CommandOutput(text: text, truncated: false, totalRows: totalRows)
        }

        let bytes = Array(text.utf8)
        let markerBytes = Array(truncationMarker.utf8)
        let remaining = max(outputByteCap - markerBytes.count, 0)
        let headBudget = remaining / 2
        let tailBudget = remaining - headBudget

        let headBytes = trimmingIncompleteUTF8Suffix(Array(bytes.prefix(headBudget)))
        let tailBytes = trimmingIncompleteUTF8Prefix(Array(bytes.suffix(tailBudget)))

        let head = String(decoding: headBytes, as: UTF8.self)
        let tail = String(decoding: tailBytes, as: UTF8.self)

        return CommandOutput(text: head + truncationMarker + tail, truncated: true, totalRows: totalRows)
    }

    /// Drops at most 3 trailing bytes (the longest UTF-8 scalar is 4
    /// bytes) so `bytes` never ends mid-scalar. `bytes` is always a
    /// prefix of a valid Swift `String`'s own UTF-8 view, so the only
    /// way `String(bytes:encoding:)` can fail here is an incomplete
    /// trailing sequence -- never a genuinely malformed one.
    private static func trimmingIncompleteUTF8Suffix(_ bytes: [UInt8]) -> [UInt8] {
        var candidate = bytes
        var trimmed = 0
        while trimmed < 3, !candidate.isEmpty, String(bytes: candidate, encoding: .utf8) == nil {
            candidate.removeLast()
            trimmed += 1
        }
        return candidate
    }

    /// Drops at most 3 leading bytes so `bytes` never begins mid-scalar
    /// (an orphaned continuation-byte run left over from a cut lead
    /// byte). Same reasoning as `trimmingIncompleteUTF8Suffix`.
    private static func trimmingIncompleteUTF8Prefix(_ bytes: [UInt8]) -> [UInt8] {
        var candidate = bytes
        var trimmed = 0
        while trimmed < 3, !candidate.isEmpty, String(bytes: candidate, encoding: .utf8) == nil {
            candidate.removeFirst()
            trimmed += 1
        }
        return candidate
    }

    // MARK: - Pending ends

    private func bufferPendingEnd(_ event: CommandEvent, surfaceID: UUID) {
        var pending = pendingEndsBySurface[surfaceID, default: []]
        pending.append(PendingEnd(cmdID: event.cmdID, exitCode: event.exitCode, ts: event.ts, receivedAt: now()))
        if pending.count > Self.pendingEndCapacityPerSurface {
            pending.removeFirst(pending.count - Self.pendingEndCapacityPerSurface)
        }
        pendingEndsBySurface[surfaceID] = pending
    }

    private func takePendingEnd(surfaceID: UUID, cmdID: String) -> PendingEnd? {
        guard var pending = pendingEndsBySurface[surfaceID],
              let index = pending.firstIndex(where: { $0.cmdID == cmdID }) else {
            return nil
        }
        let match = pending.remove(at: index)
        pendingEndsBySurface[surfaceID] = pending
        return match
    }

    private func sweepExpiredPendingEnds(surfaceID: UUID) {
        guard var pending = pendingEndsBySurface[surfaceID], !pending.isEmpty else { return }
        let currentTime = now()
        pending.removeAll { currentTime.timeIntervalSince($0.receivedAt) > Self.pendingEndTTL }
        pendingEndsBySurface[surfaceID] = pending
    }

    private func hasNonRunningRecord(surfaceID: UUID, cmdID: String) -> Bool {
        recordsBySurface[surfaceID]?.contains { $0.cmdID == cmdID && $0.state != .running } ?? false
    }

    // MARK: - Ring buffer

    private func appendCapped(_ record: CommandRecord, surfaceID: UUID) {
        recordsBySurface[surfaceID, default: []].append(record)
        trimRing(surfaceID: surfaceID)
    }

    /// Caps `surfaceID`'s record array at `ringCapacity`, evicting the
    /// oldest overflow -- shared by `appendCapped` (new start) and
    /// `remapSurface` (bulk move), which both need identical eviction.
    /// Any evicted record still `.running` is first transitioned to
    /// `.orphaned` and its awaiters resumed (same semantics as
    /// `markOrphaned`), so a command whose record ages out of the ring
    /// resolves its waiter instead of leaving it to hang until timeout.
    private func trimRing(surfaceID: UUID) {
        guard var records = recordsBySurface[surfaceID], records.count > Self.ringCapacity else { return }
        let overflow = records.count - Self.ringCapacity
        var evicted = Array(records.prefix(overflow))
        records.removeFirst(overflow)
        recordsBySurface[surfaceID] = records
        for index in evicted.indices where evicted[index].state == .running {
            evicted[index].state = .orphaned
            resumeAwaiters(for: evicted[index])
        }
    }

    private func runningRecord(surfaceID: UUID, cmdID: String) -> CommandRecord? {
        recordsBySurface[surfaceID]?.first { $0.cmdID == cmdID && $0.state == .running }
    }

    private func newestRunningRecord(surfaceID: UUID) -> CommandRecord? {
        recordsBySurface[surfaceID]?.last { $0.state == .running }
    }

    // MARK: - Queries

    /// `surfaceID`'s tracked records, oldest-first. `state` filters to a
    /// single state when given; `limit` (clamped to non-negative) caps
    /// the result to the most recent `limit` records after filtering.
    func records(surfaceID: UUID, limit: Int?, state: CommandRecord.State?) -> [CommandRecord] {
        var results = recordsBySurface[surfaceID] ?? []
        if let state {
            results = results.filter { $0.state == state }
        }
        if let limit {
            results = Array(results.suffix(max(0, limit)))
        }
        return results
    }

    func record(id: UUID) -> CommandRecord? {
        guard let (surfaceID, index) = locate(recordID: id) else { return nil }
        return recordsBySurface[surfaceID]?[index]
    }

    /// Linear scan across every surface's records -- `finalize` no
    /// longer needs this (its callers already have `surfaceID` in hand),
    /// so this is now `record(id:)`'s sole caller.
    private func locate(recordID: UUID) -> (surfaceID: UUID, index: Int)? {
        for (surfaceID, records) in recordsBySurface {
            if let index = records.firstIndex(where: { $0.id == recordID }) {
                return (surfaceID, index)
            }
        }
        return nil
    }

    // MARK: - awaitCompletion

    /// Resolves the wait target at call time -- a given `commandID`
    /// resolves to that exact record regardless of `surfaceID` (which is
    /// therefore purely advisory when `commandID` is supplied: `record(id:)`
    /// searches every surface), returning immediately if it has already
    /// left `.running`. A nil `commandID` resolves to `surfaceID`'s
    /// newest running record at call time; if none is running, there is
    /// nothing meaningful to wait for, so this returns nil immediately
    /// rather than waiting out `timeoutMs`. Either way, `timeoutMs` is
    /// clamped to `[0, 3_600_000]` before use.
    func awaitCompletion(surfaceID: UUID, commandID: UUID?, timeoutMs: Int) async -> CommandRecord? {
        let timeoutMs = min(max(timeoutMs, 0), 3_600_000)
        if let commandID {
            if let existing = record(id: commandID), existing.state != .running {
                return existing
            }
            return await waitForRecord(id: commandID, timeoutMs: timeoutMs)
        }
        guard let target = newestRunningRecord(surfaceID: surfaceID) else {
            return nil
        }
        return await waitForRecord(id: target.id, timeoutMs: timeoutMs)
    }

    /// Bounded wait for record `id` to leave `.running`, same race shape
    /// as SessionDaemonClient.bounded(operation:onTimeout:): a
    /// `CommandAwaitBridge` arbitrates exactly-once resume between three
    /// call sites -- a matching store mutation (finalize/markOrphaned/
    /// trimRing, all MainActor-isolated), the timeout Task (also
    /// MainActor-isolated), and `withTaskCancellationHandler`'s onCancel,
    /// which is NOT actor-isolated and may run concurrently with the
    /// other two on a different thread. The timeout and cancellation
    /// paths also unregister the bridge from `awaitersByRecordID` (the
    /// real-completion path already does, via `resumeAwaiters`'s
    /// `removeValue`) so a wait that's given up leaves no husk behind.
    private func waitForRecord(id: UUID, timeoutMs: Int) async -> CommandRecord? {
        let bridge = CommandAwaitBridge()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CommandRecord?, Never>) in
                awaitersByRecordID[id, default: []].append(bridge)
                let timeoutTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
                    guard !Task.isCancelled else { return }
                    self.unregisterAwaiter(bridge, id: id)
                    bridge.resume(with: nil)
                }
                let alreadyCancelled = bridge.register(continuation: continuation, timeoutTask: timeoutTask)
                if alreadyCancelled {
                    timeoutTask.cancel()
                    unregisterAwaiter(bridge, id: id)
                    bridge.resume(with: nil)
                }
            }
        } onCancel: {
            bridge.cancel()
            Task { @MainActor in
                self.unregisterAwaiter(bridge, id: id)
            }
        }
    }

    /// Identity-based, idempotent removal -- safe to race a successful
    /// `resumeAwaiters` (which may have already removed the whole entry)
    /// from either the timeout Task or the non-isolated `onCancel` hop.
    private func unregisterAwaiter(_ bridge: CommandAwaitBridge, id: UUID) {
        guard var boxes = awaitersByRecordID[id] else { return }
        boxes.removeAll { $0 === bridge }
        if boxes.isEmpty {
            awaitersByRecordID.removeValue(forKey: id)
        } else {
            awaitersByRecordID[id] = boxes
        }
    }

    /// Resumes and removes every awaiter registered for `record.id`.
    private func resumeAwaiters(for record: CommandRecord) {
        guard let boxes = awaitersByRecordID.removeValue(forKey: record.id) else { return }
        for box in boxes { box.resume(with: record) }
    }

    /// Test seam: total pending-awaiter count across every record, for
    /// asserting a timed-out/cancelled wait leaves no husk behind.
    var _testAwaiterCount: Int {
        awaitersByRecordID.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - markOrphaned

    func markOrphaned(surfaceID: UUID) {
        guard var records = recordsBySurface[surfaceID] else { return }
        var transitioned: [CommandRecord] = []
        for index in records.indices where records[index].state == .running {
            records[index].state = .orphaned
            transitioned.append(records[index])
        }
        recordsBySurface[surfaceID] = records
        for record in transitioned {
            resumeAwaiters(for: record)
        }
    }

    // MARK: - remapSurface

    func remapSurface(old: UUID, new: UUID) {
        if let oldRecords = recordsBySurface.removeValue(forKey: old) {
            let remapped = oldRecords.map { record -> CommandRecord in
                var copy = record
                copy.surfaceID = new
                // The new surfaceID is a different live GhosttySurface
                // with its own scrollback counter -- the old counter
                // captured at start is meaningless against it, so any
                // still-running remapped command forfeits output capture
                // (materializeOutput requires scrollbarTotalAtStart).
                copy.scrollbarTotalAtStart = nil
                return copy
            }
            recordsBySurface[new, default: []].append(contentsOf: remapped)
            trimRing(surfaceID: new)
        }
        if let oldPending = pendingEndsBySurface.removeValue(forKey: old) {
            pendingEndsBySurface[new, default: []].append(contentsOf: oldPending)
        }
    }

    /// Test seam: real implementation resets all in-memory state. Any
    /// still-suspended `awaitCompletion` waiter is resumed with nil
    /// BEFORE the awaiter storage is cleared, so it fails fast instead
    /// of hanging on a continuation nothing will ever resume again.
    func _testReset() {
        for boxes in awaitersByRecordID.values {
            for box in boxes { box.resume(with: nil) }
        }
        recordsBySurface.removeAll()
        pendingEndsBySurface.removeAll()
        awaitersByRecordID.removeAll()
        reader = nil
        now = { Date() }
    }
}

/// Thread-safe exactly-once resume for a single `awaitCompletion` wait,
/// same shape as SessionDaemonClient's SessionDaemonBoundedRaceBridge:
/// `register`/`resume`/`cancel` may be called from any of `waitForRecord`'s
/// three MainActor-or-not call sites, so the internal state is guarded
/// by a lock rather than actor isolation. `@unchecked Sendable` is sound
/// here for the same reason it is on `SessionDaemonBoundedRaceBridge`:
/// every stored property is only ever touched inside `lock`.
private final class CommandAwaitBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var isCancelled = false
    private var continuation: CheckedContinuation<CommandRecord?, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// Returns whether `cancel()` already ran before this call -- the
    /// caller must resume with nil immediately in that case, since
    /// `cancel()` itself found no continuation yet to resume.
    func register(continuation: CheckedContinuation<CommandRecord?, Never>, timeoutTask: Task<Void, Never>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
        self.timeoutTask = timeoutTask
        return isCancelled
    }

    @discardableResult
    func resume(with record: CommandRecord?) -> Bool {
        lock.lock()
        guard !resumed, let continuation else { lock.unlock(); return false }
        resumed = true
        self.continuation = nil
        let task = timeoutTask
        timeoutTask = nil
        lock.unlock()
        task?.cancel()
        continuation.resume(returning: record)
        return true
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let hasRegistered = continuation != nil
        lock.unlock()
        guard hasRegistered else { return }
        resume(with: nil)
    }
}
