//
//  UsageTelemetryActivationTests.swift
//  CalyxTests
//
//  R4b section B: the reconciler that brings Claude Code's settings file
//  in line with the target, driven with fake inputs and fake effects
//  that record their calls in order (UsageTelemetryActivationFakes).
//  Pins each target's effect sequence exactly, including what must NOT
//  run; each outcome and thrown error to its status; single flight; one
//  `onStatusChange` per run; effects off the main thread.
//
//  WAITING. A run that is held at a gate is observed through an
//  expectation fulfilled by the fake effect (bound: `waitSeconds`,
//  reached only on failure); nothing sleeps.
//

import XCTest
@testable import Calyx

@MainActor
final class UsageTelemetryActivationTests: XCTestCase {

    private typealias Call = UsageTelemetryFakeEffects.Call

    private let waitSeconds: TimeInterval = 30
    private let port = 41830

    private var fakeInputs: UsageTelemetryFakeInputs!
    private var fakeEffects: UsageTelemetryFakeEffects!
    private var counter: UsageTelemetryStatusChangeCounter!
    private var activationStorage: UsageTelemetryActivation?

    override func setUp() async throws {
        try await super.setUp()
        fakeInputs = UsageTelemetryFakeInputs()
        fakeEffects = UsageTelemetryFakeEffects()
        counter = UsageTelemetryStatusChangeCounter()
        activationStorage = UsageTelemetryActivation(
            inputs: fakeInputs.inputs, effects: fakeEffects.effects, onStatusChange: counter.onStatusChange)
    }

    override func tearDown() async throws {
        activationStorage = nil
        fakeInputs = nil
        fakeEffects = nil
        counter = nil
        try await super.tearDown()
    }

    private func activation() throws -> UsageTelemetryActivation {
        try XCTUnwrap(activationStorage, "Fixture error: no activation")
    }

    private func setBothOn(port: Int? = 41830) {
        fakeInputs.trackingOn = true
        fakeInputs.ipcEnabled = true
        fakeInputs.serverPort = port
        fakeInputs.mayTouchAgentFiles = true
    }

    private let boom = UsageTelemetryFakeError(message: "boom")

    /// A Swift error with neither `LocalizedError` nor a bridged domain text.
    private enum PlainError: Error { case brokenPipeline }

    // MARK: - Initial status

    func test_status_startsUnknown_andNothingRunsUntilAsked() throws {
        let activation = try activation()

        XCTAssertEqual(activation.status, .unknown)
        XCTAssertEqual(fakeEffects.calls, [])
        XCTAssertEqual(counter.count, 0)
    }

    // MARK: - Installed

    func test_installed_syncsThenLoadsWithCreateThenInstalls_withThePort() async throws {
        let activation = try activation()
        setBothOn(port: 41830)

        await activation.reconcile()

        XCTAssertEqual(
            fakeEffects.calls,
            [.syncTracking, .loadCredential(create: true), .install(port: 41830)])
        XCTAssertEqual(activation.status, .installed(port: 41830))
    }

    /// G5: install takes only the port (the helper reads the credential file itself).
    func test_installed_installGetsTheTargetPort() async throws {
        let activation = try activation()
        setBothOn(port: 50000)
        fakeEffects.setLoadResult(
            .success(UsageIngestCredential(token: String(repeating: "ab", count: 32), headersFilePath: "/tmp/other path/h.json")))

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls.last, .install(port: 50000))
        XCTAssertEqual(activation.status, .installed(port: 50000))
    }

    // MARK: - G5: usage token rotation generation

    func test_installed_rotationGeneration_isPassedToLoadCredential() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        fakeInputs.rotationGeneration = 3

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.syncTracking, .loadCredential(create: true), .install(port: 41830)])
        XCTAssertEqual(fakeEffects.loadGenerations, [3])
        XCTAssertEqual(activation.status, .installed(port: 41830))
    }

    func test_installed_noRotation_passesNilToLoadCredential() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        fakeInputs.rotationGeneration = nil

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.loadGenerations, [nil])
    }

    // Spec note 23(d): only the install path renews; a pending rotation
    // generation never reaches the remove or untouched (syncAndLoad) loads.

    func test_removed_trackingOff_passesNilGeneration_evenWithARotation() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        fakeInputs.trackingOn = false
        fakeInputs.rotationGeneration = 5

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(fakeEffects.loadGenerations, [nil])
    }

    func test_removed_ipcOff_passesNilGeneration_evenWithARotation() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        fakeInputs.ipcEnabled = false
        fakeInputs.rotationGeneration = 5

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(fakeEffects.loadGenerations, [nil])
    }

    func test_untouched_syncAndLoad_passesNilGeneration_evenWithARotation() async throws {
        let activation = try activation()
        setBothOn(port: nil)
        fakeInputs.rotationGeneration = 5

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(fakeEffects.loadGenerations, [nil])
    }

    // MARK: - rotationGeneration (production input)

    func test_rotationGeneration_runningAndRotated_isTheGeneration() {
        XCTAssertEqual(UsageTelemetryActivation.rotationGeneration(isRunning: true, rotated: true, generation: 7), 7)
    }

    func test_rotationGeneration_runningButNotRotated_isNil() {
        XCTAssertNil(UsageTelemetryActivation.rotationGeneration(isRunning: true, rotated: false, generation: 7))
    }

    func test_rotationGeneration_notRunning_isNil() {
        XCTAssertNil(UsageTelemetryActivation.rotationGeneration(isRunning: false, rotated: true, generation: 7))
        XCTAssertNil(UsageTelemetryActivation.rotationGeneration(isRunning: false, rotated: false, generation: 7))
    }

    func test_installed_rotationGeneration_isReadEachRun() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        fakeInputs.rotationGeneration = 1
        await activation.reconcile()
        fakeInputs.rotationGeneration = 2
        await activation.reconcile()

        XCTAssertEqual(fakeEffects.loadGenerations, [1, 2])
    }

    func test_installed_blockedOutcome_isBlockedStatus() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setInstallResult(.success(.blocked(keys: ["OTEL_METRICS_EXPORTER", "otelHeadersHelper"])))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .blocked(keys: ["OTEL_METRICS_EXPORTER", "otelHeadersHelper"]))
    }

    func test_installed_claudeNotFoundOutcome_isClaudeNotFoundStatus() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setInstallResult(.success(.claudeNotFound))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .claudeNotFound)
    }

    func test_installed_installThrows_isFailedWithTheErrorsDescription() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setInstallResult(.failure(boom))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .failed("boom"))
    }

    func test_installed_credentialLoadThrows_writesNoBlock_andIsFailed() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setLoadResult(.failure(UsageTelemetryFakeError(message: "lock timed out")))

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(activation.status, .failed("lock timed out"))
    }

    func test_installed_noCredential_writesNoBlock_andIsFailed() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setLoadResult(.success(nil))

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(activation.status, .failed("The credential file was not created."))
    }

    // MARK: - Removed

    func test_removed_trackingOff_removesThenSyncsThenLoadsWithoutCreate() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.trackingOn = false

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(activation.status, .removed)
    }

    func test_removed_ipcOff_removesThenSyncsThenLoadsWithoutCreate() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.ipcEnabled = false

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(activation.status, .removed)
    }

    func test_removed_claudeNotSetUp_isStillRemoved() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.trackingOn = false
        fakeEffects.setRemoveResult(.success(.claudeNotFound))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .removed)
    }

    func test_removed_removeThrows_isFailed_andStillSyncsTracking() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.trackingOn = false
        fakeEffects.setRemoveResult(.failure(boom))

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(activation.status, .failed("boom"))
    }

    func test_removed_credentialLoadThrows_isIgnored() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.ipcEnabled = false
        fakeEffects.setLoadResult(.failure(boom))

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(activation.status, .removed)
    }

    // MARK: - Untouched

    // The server is merely not running: no remove, no install; tracking
    // is synced and the credential loaded (creating it), so exports from
    // sessions already running are accepted as soon as the server is up.
    func test_untouched_serverNotRunning_syncsAndLoadsWithCreate_only_andLeavesTheStatus() async throws {
        let activation = try activation()
        setBothOn(port: nil)

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(activation.status, .unknown)
    }

    func test_untouched_afterAnInstall_keepsTheInstalledStatus_andRemovesNothing() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        await activation.reconcile()
        XCTAssertEqual(activation.status, .installed(port: 41830), "Fixture error")

        fakeInputs.serverPort = nil
        await activation.reconcile()

        XCTAssertEqual(
            fakeEffects.calls,
            [.syncTracking, .loadCredential(create: true), .install(port: 41830),
             .syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(activation.status, .installed(port: 41830))
    }

    func test_untouched_afterAFailure_keepsTheFailedStatus() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setInstallResult(.failure(boom))
        await activation.reconcile()
        XCTAssertEqual(activation.status, .failed("boom"), "Fixture error")

        fakeInputs.serverPort = nil
        await activation.reconcile()

        XCTAssertEqual(activation.status, .failed("boom"))
    }

    // Agent files may not be touched: nothing at all, whatever else holds.
    func test_mayNotTouchAgentFiles_runsNoEffectAtAll() async throws {
        let activation = try activation()
        for (tracking, ipc, port) in [(true, true, Optional(41830)), (false, false, nil), (true, true, nil)] {
            fakeInputs.trackingOn = tracking
            fakeInputs.ipcEnabled = ipc
            fakeInputs.serverPort = port
            fakeInputs.mayTouchAgentFiles = false

            await activation.reconcile()
        }

        XCTAssertEqual(fakeEffects.calls, [])
        XCTAssertEqual(activation.status, .unknown)
    }

    // MARK: - onStatusChange

    func test_onStatusChange_isCalledOncePerRun_whetherOrNotTheStatusChanged() async throws {
        let activation = try activation()
        setBothOn(port: 41830)

        await activation.reconcile()
        XCTAssertEqual(counter.count, 1)
        await activation.reconcile()   // installed again: same status
        XCTAssertEqual(counter.count, 2)
        fakeInputs.serverPort = nil
        await activation.reconcile()   // untouched: status left as it is
        XCTAssertEqual(counter.count, 3)
        fakeInputs.trackingOn = false
        await activation.reconcile()
        XCTAssertEqual(counter.count, 4)
        XCTAssertEqual(activation.status, .removed)
    }

    // MARK: - Inputs are read once per run

    // An input that changes while a run is in progress does not change
    // that run: the port the install uses is the one read at its start.
    func test_aRun_usesTheInputsAsTheyWereWhenItStarted() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        let gate = UsageTelemetryGate()
        fakeEffects.holdSyncTracking(at: gate)
        let syncing = expectation(description: "the run reached syncTracking")
        fakeEffects.expect(1, callsMatching: { $0 == .syncTracking }, fulfilling: syncing)

        let run = Task { await activation.reconcile() }
        await fulfillment(of: [syncing], timeout: waitSeconds)
        fakeInputs.serverPort = 50000
        fakeInputs.trackingOn = false
        gate.open()
        await run.value

        XCTAssertEqual(
            fakeEffects.calls,
            [.syncTracking, .loadCredential(create: true), .install(port: 41830)])
        XCTAssertEqual(activation.status, .installed(port: 41830))
    }

    // MARK: - Effects off the main thread

    func test_effects_neverRunOnTheMainThread() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        await activation.reconcile()
        fakeInputs.trackingOn = false
        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls.count, 6, "Fixture error")
        XCTAssertEqual(fakeEffects.ranOffMain, Array(repeating: true, count: 6))
    }

    // MARK: - Single flight

    // A run is held inside `remove`. Meanwhile the inputs change (both on,
    // server on 50000) and three more callers arrive. Exactly one more
    // run happens, after the first, with the inputs as they are then;
    // every caller returns, and each of the three only after that run.
    func test_singleFlight_threeCallsDuringARun_causeExactlyOneMoreRun_withFreshInputs() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.trackingOn = false
        let gate = UsageTelemetryGate()
        fakeEffects.holdRemove(at: gate)
        let removing = expectation(description: "the first run reached remove")
        fakeEffects.expect(1, callsMatching: { $0 == .remove }, fulfilling: removing)

        let first = Task { await activation.reconcile() }
        await fulfillment(of: [removing], timeout: waitSeconds)
        fakeInputs.trackingOn = true
        fakeInputs.serverPort = 50000

        let effects = try XCTUnwrap(fakeEffects)
        let late = (0..<3).map { _ in
            Task { () -> Int in
                await activation.reconcile()
                return effects.calls.count
            }
        }
        // Enqueued after the three callers on the main actor, so each of
        // them has called `reconcile()` before the first run can go on.
        let opener = Task { gate.open() }
        await opener.value
        await first.value
        var seenOnReturn: [Int] = []
        for caller in late {
            seenOnReturn.append(await caller.value)
        }

        XCTAssertEqual(
            fakeEffects.calls,
            [.remove, .syncTracking, .loadCredential(create: false),
             .syncTracking, .loadCredential(create: true), .install(port: 50000)])
        XCTAssertEqual(seenOnReturn, [6, 6, 6], "each later caller returns only after the run that started after its call")
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(activation.status, .installed(port: 50000))
    }

    // Calls that do not overlap each make their own run.
    func test_sequentialCalls_eachRun() async throws {
        let activation = try activation()
        setBothOn(port: nil)

        await activation.reconcile()
        await activation.reconcile()

        XCTAssertEqual(
            fakeEffects.calls,
            [.syncTracking, .loadCredential(create: true), .syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(counter.count, 2)
    }

    // A caller that arrives while the follow-up run is in progress makes
    // one run more after it.
    func test_singleFlight_aCallDuringTheFollowUpRun_causesAThirdRun() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.ipcEnabled = false
        let gate = UsageTelemetryGate()
        fakeEffects.holdRemove(at: gate)
        let firstRemove = expectation(description: "run 1 reached remove")
        fakeEffects.expect(1, callsMatching: { $0 == .remove }, fulfilling: firstRemove)
        let secondRemove = expectation(description: "run 2 reached remove")
        fakeEffects.expect(2, callsMatching: { $0 == .remove }, fulfilling: secondRemove)

        let first = Task { await activation.reconcile() }
        await fulfillment(of: [firstRemove], timeout: waitSeconds)
        let second = Task { await activation.reconcile() }
        // Run 2 is held as well, once the gate is replaced.
        let gate2 = UsageTelemetryGate()
        let opener = Task {
            self.fakeEffects.holdRemove(at: gate2)
            gate.open()
        }
        await opener.value
        await fulfillment(of: [secondRemove], timeout: waitSeconds)
        fakeInputs.ipcEnabled = true
        fakeInputs.serverPort = 41830
        let third = Task { await activation.reconcile() }
        let opener2 = Task { gate2.open() }
        await opener2.value
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(
            fakeEffects.calls,
            [.remove, .syncTracking, .loadCredential(create: false),
             .remove, .syncTracking, .loadCredential(create: false),
             .syncTracking, .loadCredential(create: true), .install(port: 41830)])
        XCTAssertEqual(counter.count, 3)
    }

    // MARK: - The text of `.failed` (contract: errorDescription, else an
    // NSError's localizedDescription, else String(describing:))

    func test_failed_configFileError_usesItsErrorDescription() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setInstallResult(.failure(ConfigFileError.invalidJSON))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .failed("The config file contains invalid JSON"))
    }

    func test_failed_configFileErrorWithAReason_usesItsErrorDescription() async throws {
        let activation = try activation()
        setBothOn()
        fakeInputs.trackingOn = false
        fakeEffects.setRemoveResult(.failure(ConfigFileError.writeFailed("disk full")))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .failed("Failed to write config file: disk full"))
    }

    func test_failed_posixNSError_usesItsLocalizedDescription() async throws {
        let activation = try activation()
        setBothOn()
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        XCTAssertNotEqual(error.localizedDescription, String(describing: error), "Fixture error: the two must differ")
        fakeEffects.setLoadResult(.failure(error))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .failed(error.localizedDescription))
    }

    func test_failed_plainSwiftError_usesStringDescribing() async throws {
        let activation = try activation()
        setBothOn()
        fakeEffects.setInstallResult(.failure(PlainError.brokenPipeline))

        await activation.reconcile()

        XCTAssertEqual(activation.status, .failed("brokenPipeline"))
    }

    // MARK: - Untouched with a failing credential load

    func test_untouched_credentialLoadThrows_leavesTheStatus_andRunsNoInstallOrRemove() async throws {
        let activation = try activation()
        setBothOn(port: 41830)
        await activation.reconcile()
        XCTAssertEqual(activation.status, .installed(port: 41830), "Fixture error")

        fakeInputs.serverPort = nil
        fakeEffects.setLoadResult(.failure(boom))
        await activation.reconcile()

        XCTAssertEqual(
            fakeEffects.calls,
            [.syncTracking, .loadCredential(create: true), .install(port: 41830),
             .syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(activation.status, .installed(port: 41830))
        XCTAssertEqual(counter.count, 2)
    }

    func test_untouched_credentialLoadThrows_fromUnknown_staysUnknown() async throws {
        let activation = try activation()
        setBothOn(port: nil)
        fakeEffects.setLoadResult(.failure(boom))

        await activation.reconcile()

        XCTAssertEqual(fakeEffects.calls, [.syncTracking, .loadCredential(create: true)])
        XCTAssertEqual(activation.status, .unknown)
    }
}
