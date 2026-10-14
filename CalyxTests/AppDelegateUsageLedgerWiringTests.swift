//
//  AppDelegateUsageLedgerWiringTests.swift
//  CalyxTests
//
//  Pins AppDelegate.startUsageLedger(server:ledger:), the one place the
//  usage ledger is connected to the app. It installs the server's usage
//  bridge, so a `usage_report` call through /mcp reads that ledger,
//  answers "tracking is off" exactly while the ledger's own switch is
//  off, and resolves `session_id: "current"` through the registry the
//  server holds at call time.
//
//  An export posted to the usage route is the one source of a publish:
//  the route hands it to the GIVEN ledger, whose publish carries the
//  session's totals. An accepted hook event reads and publishes nothing.
//  The startup catch-up settles the sessions the store already heard, at
//  a priority no higher than utility.
//
//  The whole path is driven for real: authenticated requests are routed
//  by a test server into a test ledger over a store in a per-test
//  temporary directory. The shared server, the shared ledger, ~/.claude
//  and Application Support are never involved, and the usage setting is
//  pointed at a test suite so that a wiring mistake reaching the shared
//  ledger would find tracking off.
//
//  R3b: it also installs the usage route's endpoint on that server
//  (`server.usageIngest`), forwarding exports to `ledger.ingestExport`,
//  accepting the credential held by the holder it is given, and noting
//  every verdict in the monitor it is given; it loads that credential
//  from the directory it is given (a per-test directory here, never
//  Application Support), syncs the tracking flag, and starts a catch-up.
//
//  R4b: `startUsageLedger` no longer loads the credential or syncs the
//  tracking flag itself: its startup task awaits ONE reconcile of the
//  telemetry activation it is given (which does both), then catches up.
//  It also requests a reconcile on every `.calyxIPCStateDidChange`.
//  Every test here gives it a per-test activation (never `.shared`):
//  inputs "tracking as the ledger says, IPC on, server not running", so
//  the target is `.untouched` (sync, load creating) with tracking on and
//  `.removed` (fake remove, sync, load without creating) with tracking
//  off, which is what the startup did before R4b; its effects reach this
//  test's ledger and holder and never a settings file.
//
//  R5b: the bridge it installs answers `usage_report` from
//  `ledger.tokenReports`: a fixture export posted to the usage route
//  appears in the tool's rows and totals.
//
//  WAITING. A test waits for a publish that must happen through an
//  expectation (bound: UsageWiringFixture.waitSeconds, reached only on
//  failure). Before asserting what was or was not published it calls
//  `settle`, which closes the ledger behind every task started so far
//  (`close()` waits for settles and pending publishes).
//

import XCTest
@testable import Calyx

@MainActor
final class AppDelegateUsageLedgerWiringTests: XCTestCase {

    private typealias Fixture = UsageWiringFixture
    private typealias Entry = UsagePublishRecorder.Entry

    private let sessionA = UsageWiringFixture.sessionA
    private let sessionB = UsageWiringFixture.sessionB
    private let testToken = "test-token-usage-wiring"
    private let settingsSuiteName = "com.calyx.tests.AppDelegateUsageLedgerWiringTests"

    private var fixture: UsageWiringFixture!
    private var server: CalyxMCPServer!
    private var recorder: UsagePublishRecorder!
    private var ledgers: [UsageLedger] = []
    private var holderStorage: UsageIngestCredentialHolder?
    private var monitorStorage: UsageIngestMonitor?
    /// The startup work of every `start`, awaited before the directories
    /// are removed, so none of it can run after the teardown.
    private var startups: [Task<Void, Never>] = []
    /// Kept alive for the whole test: the app delegate holds its
    /// notification observer, which holds the activation weakly.
    private var appDelegates: [AppDelegate] = []
    private var activations: [UsageTelemetryActivation] = []

    override func setUp() async throws {
        try await super.setUp()
        UsageTrackingSettings._testUseSuite(named: settingsSuiteName)
        fixture = try UsageWiringFixture.make(label: "AppDelegateUsageLedgerWiringTests")
        server = CalyxMCPServer(agentEndpointDirectory: fixture.basePath + "/agent-endpoint")
        server.agentRegistry = AgentRegistry()
        server._testSetToken(testToken)
        recorder = UsagePublishRecorder()
        holderStorage = UsageIngestCredentialHolder()
        monitorStorage = UsageIngestMonitor()
    }

    override func tearDown() async throws {
        server?.usageIngest = nil
        await awaitStartups()
        startups = []
        appDelegates = []
        activations = []
        server?.stop()
        server = nil
        await fixture?.shutDown(ledgers)
        ledgers = []
        fixture = nil
        recorder = nil
        holderStorage = nil
        monitorStorage = nil
        UsageTrackingSettings._testTeardownSuite(named: settingsSuiteName)
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeLedger() -> UsageLedger {
        let ledger = fixture.makeLedger(recorder: recorder)
        ledgers.append(ledger)
        return ledger
    }

    /// The directory the credential is loaded from: under the fixture,
    /// never Application Support.
    private var credentialDirectory: String { fixture.basePath + "/credential" }

    /// The activation `start` gives the launch: tracking as the ledger
    /// says, IPC on, server not running; effects over this test's ledger,
    /// holder and credential directory, and a remove that touches no file.
    private func makeActivation(_ ledger: UsageLedger, holder: UsageIngestCredentialHolder) -> UsageTelemetryActivation {
        let credentialDirectory = self.credentialDirectory
        let activation = UsageTelemetryActivation(
            inputs: UsageTelemetryActivation.Inputs(
                trackingOn: { ledger.isTracking },
                ipcEnabled: { true },
                serverPort: { nil },
                mayTouchAgentFiles: { true },
                rotationGeneration: { nil }),
            effects: UsageTelemetryActivation.Effects(
                syncTracking: { await ledger.syncTracking() },
                loadCredential: { create, rotateForGeneration in
                    try await holder.load(create: create, directory: credentialDirectory, rotateForGeneration: rotateForGeneration)
                },
                install: { port in
                    XCTFail("the server never runs in these tests: nothing may be installed")
                    return .installed(port: port)
                },
                remove: { .removed }),
            onStatusChange: {})
        activations.append(activation)
        return activation
    }

    /// Wires `ledger` to this test's server through a new app delegate,
    /// as the launch does with the shared pair, with this test's holder,
    /// monitor and activation (by default `makeActivation`, whose loader
    /// owns this test's credential directory).
    ///
    /// The startup task it returns is never discarded: it is kept in
    /// `startups`, and `awaitStartups()` (called by `settle` and by
    /// tearDown) waits for it. Since R4b it runs `activation.reconcile()`
    /// before its ledger work, so its ledger tasks may not exist yet when
    /// `start` returns.
    private func start(_ ledger: UsageLedger, activation: UsageTelemetryActivation? = nil) {
        guard let holder = holderStorage, let monitor = monitorStorage else {
            XCTFail("Fixture error: no holder or monitor")
            return
        }
        let appDelegate = AppDelegate()
        appDelegates.append(appDelegate)
        let startup = appDelegate.startUsageLedger(
            server: server, ledger: ledger, credentialHolder: holder, ingestMonitor: monitor,
            activation: activation ?? makeActivation(ledger, holder: holder))
        startups.append(startup)
    }

    /// Waits for the startup work of every `start` so far.
    private func awaitStartups() async {
        for startup in startups {
            await startup.value
        }
    }

    /// A Claude-shaped hook event naming `sessionID`'s synthetic transcript.
    /// `surfaceID` names the pane the event comes from; a new one each
    /// time when nil.
    private func eventRequest(
        _ event: String, _ sessionID: String, kind: String? = nil, surfaceID: UUID? = nil
    ) throws -> HTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": event,
            "cwd": "/work/repo/sub",
            "session_id": sessionID,
            "transcript_path": fixture.mainPath(sessionID),
        ])
        var headers = [
            "Authorization": "Bearer \(testToken)", "X-Calyx-Surface-ID": (surfaceID ?? UUID()).uuidString,
        ]
        if let kind { headers["X-Calyx-Agent-Kind"] = kind }
        return HTTPRequest(method: "POST", path: "/agent-event", headers: headers, body: body)
    }

    /// Waits until the ledger has published at least `count` times; fails
    /// the test after UsageWiringFixture.waitSeconds.
    private func waitForPublishes(_ count: Int) async {
        let published = expectation(description: "the ledger published \(count) time(s)")
        recorder.expect(count: count, fulfilling: published)
        await fulfillment(of: [published], timeout: Fixture.waitSeconds)
    }

    /// Waits for every startup task first (only then has each queued its
    /// ledger work), then closes the ledger behind everything started.
    private func settle(_ ledger: UsageLedger) async {
        await awaitStartups()
        await fixture.closeBehindEverythingStarted(ledger, in: self)
    }

    /// run1's totals by Claude Code's own count (`expected-cost-state.json`,
    /// one model): what its last export carries, cumulative from its start.
    private let run1Totals = UsageTokenTotals(input: 24, output: 2_114, cacheRead: 176_467, cacheCreation: 51_986)

    /// Creates the database with tracking from the epoch, so a captured
    /// export (whose times are fixed) counts in full.
    private func seedStoreFromTheEpoch() async throws {
        let seeded = try UsageStore(directory: fixture.storeURL, now: UsageTestClock(Date(timeIntervalSince1970: 0)).now)
        await seeded.close()
    }

    /// Writes the credential, starts `ledger`, and loads the credential into
    /// the holder itself (deterministic whichever load runs first).
    private func startWithACredential(_ ledger: UsageLedger) async throws -> UsageIngestCredential {
        let holder = try theHolder()
        let credential = try writeCredential()
        start(ledger)
        _ = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertEqual(holder.credential, credential, "Fixture error")
        return credential
    }

    // MARK: - Publishing from an export (R5a)

    // The posted export is the only source of a publish; the startup
    // catch-up may settle the session too, but its totals are the same,
    // so they are not published again.
    func test_exportPostedToTheRoute_isPublishedByTheGivenLedger_withTheSessionsTotals() async throws {
        try await seedStoreFromTheEpoch()
        let body = try XCTUnwrap(try UsageTelemetryFixtures.exports(run: "run1").last)
        let session = try XCTUnwrap(Set(try UsageTelemetryFixtures.rawTokenPoints(in: body).map(\.sessionID)).first)
        XCTAssertEqual(
            try UsageTelemetryFixtures.expectedTotals(run: "run1")["claude-sonnet-5-5"],
            ["input": 24, "output": 2_114, "cacheRead": 176_467, "cacheCreation": 51_986], "Fixture error")
        let ledger = makeLedger()
        let credential = try await startWithACredential(ledger)

        let response = await server.route(request: usageRequest(body, token: credential.token))

        XCTAssertEqual(response.statusCode, 200)
        await waitForPublishes(1)
        await settle(ledger)
        XCTAssertEqual(recorder.entries, [Entry(sessionID: session, totals: run1Totals)])
    }

    // Every export reaches the ledger, not only the first: two sessions,
    // one publish each.
    func test_everyExportReachesTheLedger_notOnlyTheFirst() async throws {
        try await seedStoreFromTheEpoch()
        let ledger = makeLedger()
        let credential = try await startWithACredential(ledger)

        let first = await server.route(request: usageRequest(
            try Fixture.exportBody(sessionA, input: 10), token: credential.token))
        let second = await server.route(request: usageRequest(
            try Fixture.exportBody(sessionB, input: 7, seconds: 11), token: credential.token))

        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(second.statusCode, 200)
        await waitForPublishes(2)
        await settle(ledger)
        XCTAssertEqual(
            Set(recorder.entries.map { "\($0.sessionID): \(String(describing: $0.totals))" }),
            Set([Entry(sessionID: sessionA, totals: Fixture.inputTotals(10)),
                 Entry(sessionID: sessionB, totals: Fixture.inputTotals(7))]
                .map { "\($0.sessionID): \(String(describing: $0.totals))" }))
        XCTAssertEqual(recorder.entries.count, 2)
    }

    // A hook event reads nothing: with a transcript on disk and
    // tracking on, an accepted event publishes nothing and stores nothing.
    func test_claudeCodeEvent_isAccepted_butReadsAndPublishesNothing() async throws {
        try fixture.write([Fixture.transcriptLine()], to: fixture.mainPath(sessionA))
        let ledger = makeLedger()
        start(ledger)

        let response = await server.route(request: try eventRequest("Stop", sessionA))

        XCTAssertEqual(response.statusCode, 204)
        await settle(ledger)
        XCTAssertEqual(recorder.entries, [])
        XCTAssertEqual(recorder.settlePriorities, [])
    }

    // MARK: - The catch-up at start

    /// An earlier run of the app heard `sessionA` through an export and
    /// closed its ledger.
    private func storeSessionAFromAnEarlierRun() async throws {
        let earlier = makeLedger()
        let outcome = await earlier.ingestExport(
            try Fixture.exportBody(sessionA, input: 10), receivedAtNs: Fixture.exportTimeNs())
        XCTAssertEqual(outcome, .stored, "Fixture error")
        await earlier.waitUntilIdle()
        await earlier.close()
        XCTAssertEqual(recorder.entries, [Entry(sessionID: sessionA, totals: Fixture.inputTotals(10))], "Fixture error")
    }

    // No export is sent, so the catch-up is the only source of settles: it
    // settles the one stored session once, at utility priority or lower,
    // and publishes its totals into the new ledger's seam.
    // Nothing awaits its task (the startup task is awaited only by
    // `settle`, after the priorities were read), so nothing raises it.
    func test_startUsageLedger_catchUpSettlesAStoredSession_atUtilityPriorityOrLower() async throws {
        try await storeSessionAFromAnEarlierRun()
        XCTAssertGreaterThan(
            Task.currentPriority, .utility,
            "Fixture error: the caller must run above utility, or an inherited priority would pass")
        let seedSettles = recorder.settlePriorities.count
        let ledger = makeLedger()

        start(ledger)

        let settled = expectation(description: "the startup catch-up settled the stored session")
        recorder.expectSettles(count: seedSettles + 1, fulfilling: settled)
        await fulfillment(of: [settled], timeout: Fixture.waitSeconds)
        let priorities = Array(recorder.settlePriorities.dropFirst(seedSettles))
        await settle(ledger)
        XCTAssertEqual(priorities.count, 1)
        for priority in priorities {
            XCTAssertLessThanOrEqual(priority, .utility)
        }
        XCTAssertEqual(recorder.settlePriorities.count, seedSettles + 1, "one settle of the one stored session")
        // A new ledger has published nothing yet, so the catch-up's settle
        // publishes the stored totals once: the card shows them after a
        // relaunch without waiting for the next export.
        XCTAssertEqual(recorder.entries, [
            Entry(sessionID: sessionA, totals: Fixture.inputTotals(10)),
            Entry(sessionID: sessionA, totals: Fixture.inputTotals(10)),
        ])
    }

    // MARK: - Tracking off

    // Tracking is off throughout: the route's export is dropped, nothing
    // is published or created.
    func test_trackingOff_anExport_isDropped_publishesNothing_andCreatesNothing() async throws {
        fixture.tracking.set(false)
        let ledger = makeLedger()
        let credential = try writeCredential()
        let before = fixture.everyPath()
        start(ledger)
        _ = try await theHolder().load(create: false, directory: credentialDirectory)

        let response = await server.route(request: usageRequest(
            try Fixture.exportBody(sessionA, input: 10), token: credential.token))

        // A dropped export is accepted like a stored one (200, "{}").
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        await settle(ledger)
        XCTAssertEqual(recorder.entries, [])
        XCTAssertEqual(fixture.everyPath(), before)
    }

    // Wiring happens once at launch, with tracking possibly off; the
    // route must already reach the ledger when the user turns it on. The
    // switch's own sync (the activation's, done here directly) restarts
    // tracking before the export is received.
    func test_trackingTurnedOnAfterStart_theNextExportIsPublished() async throws {
        try await seedStoreFromTheEpoch()
        fixture.tracking.set(false)
        let ledger = makeLedger()
        let credential = try await startWithACredential(ledger)
        await awaitStartups()

        fixture.tracking.set(true)
        await ledger.syncTracking()
        let response = await server.route(request: usageRequest(
            try Fixture.exportBody(sessionA, input: 10), token: credential.token))

        XCTAssertEqual(response.statusCode, 200)
        await waitForPublishes(1)
        await settle(ledger)
        XCTAssertEqual(recorder.entries, [Entry(sessionID: sessionA, totals: Fixture.inputTotals(10))])
    }

    // MARK: - The usage_report tool

    /// Calls `usage_report` through the server's /mcp route from `surfaceID`.
    private func usageReport(
        _ arguments: [String: Any], from surfaceID: UUID? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> (text: String, isError: Bool) {
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "usage_report", "arguments": arguments],
        ] as [String: Any])
        var headers = ["Authorization": "Bearer \(testToken)", "Content-Type": "application/json"]
        if let surfaceID { headers["X-Calyx-Surface-ID"] = surfaceID.uuidString }
        let response = await server.route(
            request: HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: body))
        XCTAssertEqual(response.statusCode, 200, file: file, line: line)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(response.body, file: file, line: line))
                as? [String: Any], file: file, line: line)
        let result = try XCTUnwrap(json["result"] as? [String: Any], "\(json)", file: file, line: line)
        let text = try XCTUnwrap(
            (result["content"] as? [[String: Any]])?.first?["text"] as? String, file: file, line: line)
        return (text, try XCTUnwrap(result["isError"] as? Bool, file: file, line: line))
    }

    private func object(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text, file: file, line: line)
    }

    private func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    // Tracking is off, so nothing is read whatever the schedule.
    func test_startUsageLedger_installsAUsageBridgeOnTheGivenServer() {
        XCTAssertNil(server.usageBridge, "Fixture error: a new server has no usage bridge")
        fixture.tracking.set(false)

        start(makeLedger())

        XCTAssertNotNil(server.usageBridge)
    }

    // R5b: the bridge reads `ledger.tokenReports`. The database is created
    // first with tracking from the epoch, so run1's last export, posted to
    // the usage route, is stored in full. Pane A's hook event names the
    // export's session, pane B's another session. The route answers only
    // once the export is committed (`ingestExport`, r3b contract C), so
    // the store holds it before the tool is called; `settle` comes last
    // and only closes the ledger behind every task started. Neither
    // session has a transcript, so the tool's catch-up only finds them
    // missing and adds no unreported row.
    //
    // The registry is replaced AFTER `startUsageLedger`: `current` must be
    // looked up in whatever registry the server holds at call time. The
    // usage setting in the test suite is never written (so it reads off):
    // only the ledger's own switch decides.
    func test_usageReport_reportsTheStoredExport_andCurrentIsTheCallingPanesSession() async throws {
        let holder = try theHolder()
        let seeded = try UsageStore(directory: fixture.storeURL, now: UsageTestClock(Date(timeIntervalSince1970: 0)).now)
        await seeded.close()
        let credential = try writeCredential()
        let body = try XCTUnwrap(try UsageTelemetryFixtures.exports(run: "run1").last)
        let exportSessions = Set(try UsageTelemetryFixtures.rawTokenPoints(in: body).map(\.sessionID))
        XCTAssertEqual(exportSessions.count, 1, "Fixture error: run1 is one session")
        let exportSession = try XCTUnwrap(exportSessions.first)
        XCTAssertNotEqual(exportSession, sessionB, "Fixture error")
        let expected = try UsageTelemetryFixtures.expectedTotals(run: "run1")
        let ledger = makeLedger()
        start(ledger)
        server.agentRegistry = AgentRegistry()
        _ = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertEqual(holder.credential, credential, "Fixture error")
        let paneA = UUID()
        let paneB = UUID()

        let posted = await server.route(request: usageRequest(body, token: credential.token))
        let eventA = await server.route(request: try eventRequest("Stop", exportSession, surfaceID: paneA))
        let eventB = await server.route(request: try eventRequest("Stop", sessionB, surfaceID: paneB))
        XCTAssertEqual(posted.statusCode, 200, "Fixture error")
        XCTAssertEqual(eventA.statusCode, 204)
        XCTAssertEqual(eventB.statusCode, 204)
        XCTAssertFalse(UsageTrackingSettings.enabled, "Fixture error: the suite's setting is off")

        let byModel = try await usageReport(["group_by": ["model"]])
        let fromPaneA = try await usageReport(["session_id": "current", "group_by": ["session"]], from: paneA)
        let fromPaneB = try await usageReport(["session_id": "current", "group_by": [String]()], from: paneB)
        await settle(ledger)

        XCTAssertFalse(byModel.isError, byModel.text)
        let all = try object(byModel.text)
        let rows = try XCTUnwrap(all["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["unreported"] as? Bool }, [Bool?](repeating: false, count: rows.count))
        let reported = UsageTelemetryFixtures.sumByModel(rows.flatMap { row -> [(String, String, Int64)] in
            let model = (row["key"] as? [String: Any])?["model"] as? String ?? ""
            return [
                (model, "input", number(row["input_tokens"]) ?? Int64.min),
                (model, "output", number(row["output_tokens"]) ?? Int64.min),
                (model, "cacheRead", number(row["cache_read_tokens"]) ?? Int64.min),
                (model, "cacheCreation", number(row["cache_creation_tokens"]) ?? Int64.min),
            ]
        })
        XCTAssertEqual(reported, expected)
        let totals = try XCTUnwrap(all["totals"] as? [String: Any])
        let expectedSum = { (kind: String) -> Int64 in expected.values.reduce(0) { $0 &+ ($1[kind] ?? 0) } }
        XCTAssertEqual(number(totals["input_tokens"]), expectedSum("input"))
        XCTAssertEqual(number(totals["output_tokens"]), expectedSum("output"))
        XCTAssertEqual(number(totals["cache_read_tokens"]), expectedSum("cacheRead"))
        XCTAssertEqual(number(totals["cache_creation_tokens"]), expectedSum("cacheCreation"))
        let unreported = try XCTUnwrap(totals["unreported"] as? [String: Any])
        for name in ["input_tokens", "cache_read_tokens", "cache_creation_tokens", "output_tokens"] {
            XCTAssertEqual(number(unreported[name]), 0, name)
        }
        XCTAssertEqual(all["time_zone"] as? String, Calendar.current.timeZone.identifier)

        XCTAssertFalse(fromPaneA.isError, fromPaneA.text)
        let a = try object(fromPaneA.text)
        let aRows = try XCTUnwrap(a["rows"] as? [[String: Any]])
        XCTAssertEqual(aRows.map { ($0["key"] as? [String: Any])?["session"] as? String }, [exportSession])
        XCTAssertEqual(number((a["totals"] as? [String: Any])?["output_tokens"]), expectedSum("output"))

        XCTAssertFalse(fromPaneB.isError, fromPaneB.text)
        let b = try object(fromPaneB.text)
        XCTAssertEqual(number(b["row_count"]), 0)
        let bTotals = try XCTUnwrap(b["totals"] as? [String: Any])
        XCTAssertEqual(number(bTotals["output_tokens"]), 0)
        XCTAssertTrue(bTotals["last_timestamp"] is NSNull)
    }

    // The pane's agent row knows no session: `current` cannot be resolved.
    func test_usageReport_currentFromAPaneWithoutASession_isAToolError() async throws {
        let ledger = makeLedger()
        start(ledger)

        let result = try await usageReport(["session_id": "current"], from: UUID())

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "No agent session is known for the calling pane.")
    }

    // The ledger's switch is off while the app's setting (in the test
    // suite) is on: the bridge answers from the ledger, never from the
    // setting. Tracking is off throughout, so nothing is read or created.
    func test_usageReport_trackingOff_isTheTrackingOffToolError_whateverTheSettingSays() async throws {
        try fixture.write([Fixture.transcriptLine()], to: fixture.mainPath(sessionA))
        fixture.tracking.set(false)
        UsageTrackingSettings.enabled = true
        let ledger = makeLedger()
        let before = fixture.everyPath()
        start(ledger)

        let result = try await usageReport(["group_by": ["model"]])

        XCTAssertTrue(result.isError)
        XCTAssertEqual(result.text, "Usage tracking is off. Turn on Settings > Agents > Usage Tracking.")
        await settle(ledger)
        XCTAssertEqual(fixture.everyPath(), before)
    }

    // Wired once at launch; the tool follows the ledger's switch at each
    // call. No session is stored, so whichever schedule the reconcile
    // takes, a successful call reports no rows.
    func test_usageReport_followsTheLedgersTrackingAtEachCall() async throws {
        fixture.tracking.set(false)
        let ledger = makeLedger()
        start(ledger)

        let off = try await usageReport([:])
        fixture.tracking.set(true)
        let on = try await usageReport([:])
        fixture.tracking.set(false)
        let offAgain = try await usageReport([:])

        XCTAssertTrue(off.isError)
        XCTAssertFalse(on.isError, on.text)
        XCTAssertEqual(number(try object(on.text)["row_count"]), 0)
        XCTAssertTrue(offAgain.isError)
        XCTAssertEqual(offAgain.text, "Usage tracking is off. Turn on Settings > Agents > Usage Tracking.")
    }

    // MARK: - The usage route (R3b)

    private func theHolder() throws -> UsageIngestCredentialHolder {
        try XCTUnwrap(holderStorage, "Fixture error: no holder")
    }

    private func theMonitor() throws -> UsageIngestMonitor {
        try XCTUnwrap(monitorStorage, "Fixture error: no monitor")
    }

    /// A usage token written by hand (64 lowercase hex characters).
    private let usageToken = String(repeating: "0123456789abcdef", count: 4)

    /// Writes the credential file the launch will find.
    private func writeCredential() throws -> UsageIngestCredential {
        let token = usageToken
        return try UsageIngestCredentialStore.loadOrCreate(directory: credentialDirectory, makeToken: { token })
    }

    private func usageRequest(_ body: Data, token: String) -> HTTPRequest {
        HTTPRequest(
            method: "POST", path: HTTPParser.usageMetricsPath,
            headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"], body: body)
    }

    // Tracking is off: nothing is read or created whatever the schedule.
    func test_startUsageLedger_installsTheUsageEndpointOnTheGivenServer() {
        XCTAssertNil(server.usageIngest, "Fixture error: a new server has no usage endpoint")
        fixture.tracking.set(false)

        start(makeLedger())

        XCTAssertNotNil(server.usageIngest)
    }

    // The database is created first with tracking from the epoch, so the
    // export (received at the endpoint's real clock) counts in full. The
    // test loads the credential itself after `start`, which sets the same
    // holder deterministically whichever load runs first. The session has
    // no transcript, so its settles and the catch-up only find it missing.
    func test_fixtureExportPostedToTheRoute_endsUpInTheLedgersTokenReports() async throws {
        let holder = try theHolder()
        let monitor = try theMonitor()
        let seeded = try UsageStore(directory: fixture.storeURL, now: UsageTestClock(Date(timeIntervalSince1970: 0)).now)
        await seeded.close()
        let credential = try writeCredential()
        let body = try XCTUnwrap(try UsageTelemetryFixtures.exports(run: "run1").last)
        let ledger = makeLedger()
        start(ledger)
        let loaded = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertEqual(loaded, credential, "Fixture error")
        XCTAssertEqual(holder.credential, credential)

        let before = Date()
        let response = await server.route(request: usageRequest(body, token: credential.token))
        let after = Date()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, Data("{}".utf8))
        let accepted = try XCTUnwrap(monitor.lastAcceptedAt, "the monitor records the accepted time")
        XCTAssertGreaterThanOrEqual(accepted, before)
        XCTAssertLessThanOrEqual(accepted, after)
        XCTAssertNil(monitor.lastRejection)

        let results = try await ledger.tokenReports([UsageTokenQuery(groupBy: [.model])], calendar: Fixture.utc)
        let rows = try XCTUnwrap(results.first)
        XCTAssertEqual(rows.filter(\.isUnreported), [])
        let totals = UsageTelemetryFixtures.sumByModel(rows.flatMap { row -> [(String, String, Int64)] in
            let model = row.key.first.flatMap { $0 } ?? ""
            return [(model, "input", row.inputTokens), (model, "output", row.outputTokens),
                    (model, "cacheRead", row.cacheReadTokens), (model, "cacheCreation", row.cacheCreationTokens)]
        })
        XCTAssertEqual(totals, try UsageTelemetryFixtures.expectedTotals(run: "run1"))
        await settle(ledger)
    }

    // Tracking is off, so the launch loads without creating: there is no
    // credential, and the route refuses every token.
    func test_withoutACredential_theSameRequestIsUnauthorized_andNothingIsCreated() async throws {
        let holder = try theHolder()
        let monitor = try theMonitor()
        fixture.tracking.set(false)
        let body = try XCTUnwrap(try UsageTelemetryFixtures.exports(run: "run1").last)
        let ledger = makeLedger()
        let before = fixture.everyPath()
        start(ledger)
        let loaded = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertNil(loaded)
        XCTAssertNil(holder.credential)

        let response = await server.route(request: usageRequest(body, token: usageToken))

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertEqual(monitor.lastRejection?.reason, .unauthorized)
        XCTAssertNil(monitor.lastAcceptedAt)
        await settle(ledger)
        XCTAssertEqual(fixture.everyPath(), before, "with tracking off nothing is created")
    }

    // MARK: - UsageIngestCredentialHolder

    func test_holder_loadWithCreate_writesTheCredential_andHoldsIt() async throws {
        let holder = try theHolder()
        let loaded = try await holder.load(create: true, directory: credentialDirectory)

        let credential = try XCTUnwrap(loaded)
        XCTAssertEqual(holder.credential, credential)
        XCTAssertEqual(UsageIngestCredentialStore.read(directory: credentialDirectory), credential)
        XCTAssertEqual(credential.token.count, 64)
    }

    func test_holder_loadWithoutCreate_readsAnExistingCredential() async throws {
        let holder = try theHolder()
        let credential = try writeCredential()

        let loaded = try await holder.load(create: false, directory: credentialDirectory)

        XCTAssertEqual(loaded, credential)
        XCTAssertEqual(holder.credential, credential)
    }

    func test_holder_loadWithoutCreate_withoutAFile_holdsNothing_andCreatesNothing() async throws {
        let holder = try theHolder()
        holder.set(UsageIngestCredential(token: usageToken, headersFilePath: "/nonexistent/x"))

        let loaded = try await holder.load(create: false, directory: credentialDirectory)

        XCTAssertNil(loaded)
        XCTAssertNil(holder.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialDirectory))
    }

    // A load that throws (the headers path is occupied by a directory)
    // leaves the held credential as it was and rethrows.
    func test_holder_loadThatThrows_keepsTheCredential_andRethrows() async throws {
        let holder = try theHolder()
        let credential = try writeCredential()
        let loaded = try await holder.load(create: false, directory: credentialDirectory)
        XCTAssertEqual(loaded, credential, "Fixture error")
        let path = UsageIngestCredentialStore.headersFilePath(directory: credentialDirectory)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)

        do {
            _ = try await holder.load(create: true, directory: credentialDirectory)
            XCTFail("a load whose headers path is a directory must throw")
        } catch {
            XCTAssertEqual(holder.credential, credential)
        }
    }

    func test_holder_set_replacesTheCredential() throws {
        let holder = try theHolder()
        let credential = UsageIngestCredential(token: usageToken, headersFilePath: "/nonexistent/x")
        XCTAssertNil(holder.credential)
        holder.set(credential)
        XCTAssertEqual(holder.credential, credential)
        holder.set(nil)
        XCTAssertNil(holder.credential)
    }

    // MARK: - UsageIngestMonitor

    func test_monitor_acceptedRequest_recordsItsTime() throws {
        let monitor = try theMonitor()
        let date = Date(timeIntervalSince1970: 1_000)
        monitor.note(nil, at: date)
        XCTAssertEqual(monitor.lastAcceptedAt, date)
        XCTAssertNil(monitor.lastRejection)
    }

    func test_monitor_keepsTheRefusalsAnExporterCanCause() throws {
        let monitor = try theMonitor()
        let reasons: [UsageIngestRejection] = [.unauthorized, .tooLarge, .undecodable, .unavailable]
        for (offset, reason) in reasons.enumerated() {
            let date = Date(timeIntervalSince1970: 2_000 + Double(offset))
            monitor.note(reason, at: date)
            let stored = try XCTUnwrap(UsageIngestMonitor.ExporterRejection(reason), "\(reason)")
            XCTAssertEqual(monitor.lastRejection, UsageIngestMonitor.Rejection(reason: stored, at: date), "\(reason)")
        }
        XCTAssertNil(monitor.lastAcceptedAt)
    }

    func test_monitor_ignoresAForeignOriginAndAMissingBody() throws {
        let monitor = try theMonitor()
        let accepted = Date(timeIntervalSince1970: 1_000)
        let refused = Date(timeIntervalSince1970: 1_001)
        monitor.note(nil, at: accepted)
        monitor.note(.unauthorized, at: refused)

        monitor.note(.foreignOrigin, at: Date(timeIntervalSince1970: 1_002))
        monitor.note(.noBody, at: Date(timeIntervalSince1970: 1_003))

        XCTAssertEqual(monitor.lastAcceptedAt, accepted)
        XCTAssertEqual(monitor.lastRejection, UsageIngestMonitor.Rejection(reason: .unauthorized, at: refused))
    }

    // MARK: - The telemetry activation (R4b)

    private let waitSeconds: TimeInterval = 30

    /// A per-test activation over fakes, kept alive for the test.
    private func fakeActivation(
        _ inputs: UsageTelemetryFakeInputs, _ effects: UsageTelemetryFakeEffects,
        _ counter: UsageTelemetryStatusChangeCounter
    ) -> UsageTelemetryActivation {
        let activation = UsageTelemetryActivation(
            inputs: inputs.inputs, effects: effects.effects, onStatusChange: counter.onStatusChange)
        activations.append(activation)
        return activation
    }

    // The startup task returns only after exactly one reconcile ran.
    func test_startUsageLedger_awaitsExactlyOneReconcile() async throws {
        fixture.tracking.set(false)
        let inputs = UsageTelemetryFakeInputs()
        inputs.trackingOn = false
        let effects = UsageTelemetryFakeEffects()
        let counter = UsageTelemetryStatusChangeCounter()
        let activation = fakeActivation(inputs, effects, counter)

        start(makeLedger(), activation: activation)
        await awaitStartups()

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(effects.calls, [.remove, .syncTracking, .loadCredential(create: false)])
        XCTAssertEqual(activation.status, .removed)
    }

    // The startup no longer loads the credential or syncs tracking on
    // its own: with an activation that may not touch agent files, nothing
    // is loaded or created, even with tracking on.
    func test_startUsageLedger_loadsNoCredentialItself_onlyThroughTheActivation() async throws {
        let holder = try theHolder()
        let inputs = UsageTelemetryFakeInputs()
        inputs.mayTouchAgentFiles = false
        let effects = UsageTelemetryFakeEffects()
        let counter = UsageTelemetryStatusChangeCounter()
        let activation = fakeActivation(inputs, effects, counter)
        let ledger = makeLedger()

        start(ledger, activation: activation)
        await awaitStartups()

        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(effects.calls, [])
        XCTAssertNil(holder.credential)
        XCTAssertFalse(FileManager.default.fileExists(atPath: credentialDirectory))
        await settle(ledger)
    }

    // A posted `.calyxIPCStateDidChange` requests another reconcile,
    // which reads the inputs afresh.
    func test_ipcStateDidChange_requestsAnotherReconcile() async throws {
        fixture.tracking.set(false)
        let inputs = UsageTelemetryFakeInputs()
        inputs.trackingOn = false
        let effects = UsageTelemetryFakeEffects()
        let counter = UsageTelemetryStatusChangeCounter()
        let activation = fakeActivation(inputs, effects, counter)
        start(makeLedger(), activation: activation)
        await awaitStartups()
        XCTAssertEqual(counter.count, 1, "Fixture error")

        inputs.trackingOn = true
        inputs.serverPort = 41830
        let second = expectation(description: "a second reconcile ran")
        counter.expect(2, fulfilling: second)
        NotificationCenter.default.post(name: .calyxIPCStateDidChange, object: nil)
        await fulfillment(of: [second], timeout: waitSeconds)

        XCTAssertEqual(
            effects.calls,
            [.remove, .syncTracking, .loadCredential(create: false),
             .syncTracking, .loadCredential(create: true),
             .install(port: 41830)])
        XCTAssertEqual(activation.status, .installed(port: 41830))
    }

    // MARK: - UsageIngestMonitor.ExporterRejection (R4b)

    func test_exporterRejection_mapsTheFourRefusalsAnExporterCanCause() {
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.unauthorized), .unauthorized)
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.tooLarge), .tooLarge)
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.undecodable), .undecodable)
        XCTAssertEqual(UsageIngestMonitor.ExporterRejection(.unavailable), .unavailable)
    }

    func test_exporterRejection_isNilForWhatNoExporterCauses() {
        XCTAssertNil(UsageIngestMonitor.ExporterRejection(.foreignOrigin))
        XCTAssertNil(UsageIngestMonitor.ExporterRejection(.noBody))
    }

    // The stored reason has the narrowed type (a compile-time pin).
    func test_rejectionReason_isAnExporterRejection() throws {
        let monitor = try theMonitor()
        monitor.note(.tooLarge, at: Date(timeIntervalSince1970: 3_000))
        let reason: UsageIngestMonitor.ExporterRejection? = monitor.lastRejection?.reason
        XCTAssertEqual(reason, .tooLarge)
    }
}
