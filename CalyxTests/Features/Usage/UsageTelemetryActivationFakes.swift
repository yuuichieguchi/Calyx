//
//  UsageTelemetryActivationFakes.swift
//  CalyxTests
//
//  Fakes for UsageTelemetryActivation (R4b): inputs a test changes at
//  will, and effects that record every call in order, answer what the
//  test configured, and can be held at a gate (a latch that stays open
//  once opened) so a run can be observed while it is in progress.
//  Nothing here touches a file.
//

import Foundation
import os
import XCTest
@testable import Calyx

/// An error whose `String(describing:)` and `localizedDescription` are
/// the same text, so a status built from either reads `message`.
struct UsageTelemetryFakeError: LocalizedError, CustomStringConvertible, Sendable {
    let message: String
    var description: String { message }
    var errorDescription: String? { message }
}

/// What the reconciler reads; every value can be changed between and
/// during runs.
@MainActor final class UsageTelemetryFakeInputs {
    var trackingOn = true
    var ipcEnabled = true
    var serverPort: Int? = 41830
    var mayTouchAgentFiles = true
    /// G5: the server start generation whose IPC token rotated, or nil.
    var rotationGeneration: Int?

    var inputs: UsageTelemetryActivation.Inputs {
        UsageTelemetryActivation.Inputs(
            trackingOn: { self.trackingOn },
            ipcEnabled: { self.ipcEnabled },
            serverPort: { self.serverPort },
            mayTouchAgentFiles: { self.mayTouchAgentFiles },
            rotationGeneration: { self.rotationGeneration })
    }
}

/// A latch: `wait()` returns once `open()` was called, before or after.
final class UsageTelemetryGate: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Effects that record their calls.
final class UsageTelemetryFakeEffects: Sendable {
    enum Call: Equatable, Sendable {
        case syncTracking
        case loadCredential(create: Bool)
        case install(port: Int)
        case remove
    }

    // Holds `any Error` values (an NSError is not Sendable); only ever
    // touched under the lock.
    private struct State {
        var calls: [Call] = []
        /// One entry per `loadCredential` call: its `rotateForGeneration`.
        var loadGenerations: [Int?] = []
        var offMain: [Bool] = []
        var loadResult: Result<UsageIngestCredential?, any Error> = .success(
            UsageIngestCredential(
                token: String(repeating: "0123456789abcdef", count: 4),
                headersFilePath: UsageTelemetryFakeEffects.headersFilePath))
        var installResult: Result<ClaudeUsageTelemetryConfigManager.Outcome, any Error>?
        var removeResult: Result<ClaudeUsageTelemetryConfigManager.Outcome, any Error> = .success(.removed)
        var syncGate: UsageTelemetryGate?
        var removeGate: UsageTelemetryGate?
        var waits: [(count: Int, matching: @Sendable (Call) -> Bool, expectation: XCTestExpectation)] = []
    }

    /// The headers file path of the credential the fake loads by default.
    static let headersFilePath = "/nonexistent/calyx-tests/usage-otel-credential.json"

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var calls: [Call] { state.withLockUnchecked { $0.calls } }
    /// G5: the `rotateForGeneration` argument of every `loadCredential` call, in order.
    var loadGenerations: [Int?] { state.withLockUnchecked { $0.loadGenerations } }
    /// One entry per call: whether it ran off the main thread.
    var ranOffMain: [Bool] { state.withLockUnchecked { $0.offMain } }

    func setLoadResult(_ result: Result<UsageIngestCredential?, any Error>) {
        state.withLockUnchecked { $0.loadResult = result }
    }
    /// nil (the default): an install answers `.installed(port:)` for the port it was given.
    func setInstallResult(_ result: Result<ClaudeUsageTelemetryConfigManager.Outcome, any Error>?) {
        state.withLockUnchecked { $0.installResult = result }
    }
    func setRemoveResult(_ result: Result<ClaudeUsageTelemetryConfigManager.Outcome, any Error>) {
        state.withLockUnchecked { $0.removeResult = result }
    }
    /// Every `syncTracking` call waits for `gate` (after it was recorded).
    func holdSyncTracking(at gate: UsageTelemetryGate?) {
        state.withLockUnchecked { $0.syncGate = gate }
    }
    /// Every `remove` call waits for `gate` (after it was recorded).
    func holdRemove(at gate: UsageTelemetryGate?) {
        state.withLockUnchecked { $0.removeGate = gate }
    }

    /// Fulfils `expectation` once `count` recorded calls match `matching`.
    func expect(
        _ count: Int, callsMatching matching: @escaping @Sendable (Call) -> Bool, fulfilling expectation: XCTestExpectation
    ) {
        let reached = state.withLockUnchecked { state -> Bool in
            if state.calls.filter(matching).count >= count { return true }
            state.waits.append((count, matching, expectation))
            return false
        }
        if reached { expectation.fulfill() }
    }

    private func record(_ call: Call) {
        let offMain = pthread_main_np() == 0
        let due = state.withLockUnchecked { state -> [XCTestExpectation] in
            state.calls.append(call)
            state.offMain.append(offMain)
            let calls = state.calls
            let due = state.waits.filter { calls.filter($0.matching).count >= $0.count }
            state.waits.removeAll { calls.filter($0.matching).count >= $0.count }
            return due.map(\.expectation)
        }
        for expectation in due { expectation.fulfill() }
    }

    var effects: UsageTelemetryActivation.Effects {
        UsageTelemetryActivation.Effects(
            syncTracking: { [self] in
                record(.syncTracking)
                if let gate = state.withLockUnchecked({ $0.syncGate }) { await gate.wait() }
            },
            loadCredential: { [self] create, rotateForGeneration in
                state.withLockUnchecked { $0.loadGenerations.append(rotateForGeneration) }
                record(.loadCredential(create: create))
                return try state.withLockUnchecked { $0.loadResult }.get()
            },
            install: { [self] port in
                record(.install(port: port))
                guard let result = state.withLockUnchecked({ $0.installResult }) else { return .installed(port: port) }
                return try result.get()
            },
            remove: { [self] in
                record(.remove)
                if let gate = state.withLockUnchecked({ $0.removeGate }) { await gate.wait() }
                return try state.withLockUnchecked { $0.removeResult }.get()
            })
    }
}

/// Counts `onStatusChange` calls and fulfils expectations at given counts.
@MainActor final class UsageTelemetryStatusChangeCounter {
    private(set) var count = 0
    private var waits: [(count: Int, expectation: XCTestExpectation)] = []

    func expect(_ count: Int, fulfilling expectation: XCTestExpectation) {
        if self.count >= count {
            expectation.fulfill()
        } else {
            waits.append((count, expectation))
        }
    }

    func note() {
        count += 1
        let current = count
        for wait in waits where wait.count <= current { wait.expectation.fulfill() }
        waits.removeAll { $0.count <= current }
    }

    var onStatusChange: @MainActor () -> Void {
        { [weak self] in self?.note() }
    }
}
