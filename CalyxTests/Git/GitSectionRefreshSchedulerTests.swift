// GitSectionRefreshSchedulerTests.swift
// CalyxTests
//
// One fetch at a time per section: what a request arriving mid-fetch does
// to the one in flight, and what hiding the sidebar does to both.

import Foundation
import Testing
@testable import Calyx

/// A fetch the test decides when to let finish.
@MainActor
private final class FetchGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume()
        }
    }
}

@MainActor
private final class FetchRecorder {
    private(set) var started: [(repoID: String, scope: GitSectionFetchScope)] = []
    private(set) var finished: [(repoID: String, scope: GitSectionFetchScope)] = []
    private(set) var cancelled: [(repoID: String, scope: GitSectionFetchScope)] = []
    private(set) var peakConcurrency = 0
    private var running = 0

    func begin(_ repoID: String, _ scope: GitSectionFetchScope) {
        started.append((repoID, scope))
        running += 1
        peakConcurrency = max(peakConcurrency, running)
    }

    func end(_ repoID: String, _ scope: GitSectionFetchScope, wasCancelled: Bool) {
        running -= 1
        finished.append((repoID, scope))
        if wasCancelled {
            cancelled.append((repoID, scope))
        }
    }

    func startedScopes(for repoID: String) -> [GitSectionFetchScope] {
        started.filter { $0.repoID == repoID }.map(\.scope)
    }

    func finishedScopes(for repoID: String) -> [GitSectionFetchScope] {
        finished.filter { $0.repoID == repoID }.map(\.scope)
    }
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
}

@MainActor
struct GitSectionRefreshSchedulerTests {
    private func makeScheduler(
        recorder: FetchRecorder,
        gate: FetchGate
    ) -> GitSectionRefreshScheduler {
        GitSectionRefreshScheduler { repoID, scope in
            recorder.begin(repoID, scope)
            await gate.wait()
            recorder.end(repoID, scope, wasCancelled: Task.isCancelled)
        }
    }

    @Test func test_schedule_keepsAWiderFetchWhenANarrowerRequestArrives() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let run = scheduler.schedule(repoID: "A", scope: .statusAndLog)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        #expect(recorder.startedScopes(for: "A") == [.statusAndLog])

        // A working-tree event asks for status while the history fetch is
        // still running.
        scheduler.schedule(repoID: "A", scope: .status)
        gate.open()
        await run?.value

        #expect(recorder.finishedScopes(for: "A") == [.statusAndLog, .status])
        #expect(recorder.cancelled.isEmpty)
    }

    @Test func test_schedule_mergesEveryRequestThatArrivesDuringOneFetch() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let run = scheduler.schedule(repoID: "A", scope: .status)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        scheduler.schedule(repoID: "A", scope: .log)
        scheduler.schedule(repoID: "A", scope: .moreCommits)
        gate.open()
        await run?.value

        #expect(recorder.finishedScopes(for: "A") == [
            .status,
            GitSectionFetchScope(includesLog: true, loadsMoreCommits: true),
        ])
    }

    @Test func test_schedule_runsOneFetchAtATimeForOneSection() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        // A refresh replaces a section's commit list and a load-more
        // appends to it, so the two must never be in flight together.
        let run = scheduler.schedule(repoID: "A", scope: .statusAndLog)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        scheduler.schedule(repoID: "A", scope: .moreCommits)
        gate.open()
        await run?.value

        #expect(recorder.peakConcurrency == 1)
        #expect(recorder.finishedScopes(for: "A") == [.statusAndLog, .moreCommits])
    }

    @Test func test_schedule_runsSectionsInParallel() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let first = scheduler.schedule(repoID: "A", scope: .status)
        let second = scheduler.schedule(repoID: "B", scope: .status)
        try await waitUntil { recorder.started.count == 2 }
        gate.open()
        await first?.value
        await second?.value

        #expect(recorder.peakConcurrency == 2)
    }

    @Test func test_cancelAll_cancelsTheFetchInFlightAndDropsWhatWasQueued() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let run = scheduler.schedule(repoID: "A", scope: .statusAndLog)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        scheduler.schedule(repoID: "A", scope: .status)

        scheduler.cancelAll()
        gate.open()
        await run?.value

        #expect(recorder.cancelled.map(\.scope) == [.statusAndLog])
        #expect(recorder.startedScopes(for: "A") == [.statusAndLog])
    }

    @Test func test_schedule_startsAFreshRunAfterTheQueueDrains() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)
        gate.open()

        await scheduler.schedule(repoID: "A", scope: .status)?.value
        await scheduler.schedule(repoID: "A", scope: .log)?.value

        #expect(recorder.finishedScopes(for: "A") == [.status, .log])
    }

    @Test func test_schedule_ignoresAnEmptyScope() async {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)
        gate.open()

        #expect(scheduler.schedule(repoID: "A", scope: GitSectionFetchScope()) == nil)
        #expect(recorder.started.isEmpty)
    }

    // MARK: - isLoadingMoreCommits

    @Test func test_isLoadingMoreCommits_isFalseBeforeAnythingIsScheduled() {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)
    }

    @Test func test_isLoadingMoreCommits_isTrueWhileAPageIsInFlightAndFalseAfter() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let run = scheduler.schedule(repoID: "A", scope: .moreCommits)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == true)
        #expect(scheduler.isLoadingMoreCommits(repoID: "B") == false)

        gate.open()
        await run?.value

        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)
    }

    @Test func test_isLoadingMoreCommits_isTrueWhileAPageIsQueuedBehindARefresh() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let run = scheduler.schedule(repoID: "A", scope: .statusAndLog)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)

        scheduler.schedule(repoID: "A", scope: .moreCommits)
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == true)

        gate.open()
        await run?.value

        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)
    }

    @Test func test_isLoadingMoreCommits_isFalseForARunningLogFetch() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let run = scheduler.schedule(repoID: "A", scope: .log)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }

        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)

        gate.open()
        await run?.value
    }

    @Test func test_isLoadingMoreCommits_isFalseAfterCancelAllWithAPageInFlight() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let scheduler = makeScheduler(recorder: recorder, gate: gate)

        let run = scheduler.schedule(repoID: "A", scope: .moreCommits)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == true)

        scheduler.cancelAll()
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)

        gate.open()
        await run?.value
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)
    }

    @Test func test_isLoadingMoreCommits_aCancelledRunFinishingLaterKeepsANewerPageInFlight() async throws {
        let recorder = FetchRecorder()
        let firstGate = FetchGate()
        let secondGate = FetchGate()
        var gates = [firstGate, secondGate]
        let scheduler = GitSectionRefreshScheduler { repoID, scope in
            let gate = gates.removeFirst()
            recorder.begin(repoID, scope)
            await gate.wait()
            recorder.end(repoID, scope, wasCancelled: Task.isCancelled)
        }

        let cancelledRun = scheduler.schedule(repoID: "A", scope: .moreCommits)
        try await waitUntil { recorder.startedScopes(for: "A").count == 1 }
        scheduler.cancelAll()

        // The sidebar comes back and asks for a page while the abandoned
        // fetch is still unwinding.
        let newerRun = scheduler.schedule(repoID: "A", scope: .moreCommits)
        try await waitUntil { recorder.startedScopes(for: "A").count == 2 }

        firstGate.open()
        await cancelledRun?.value
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == true)

        secondGate.open()
        await newerRun?.value
        #expect(scheduler.isLoadingMoreCommits(repoID: "A") == false)
    }
}
