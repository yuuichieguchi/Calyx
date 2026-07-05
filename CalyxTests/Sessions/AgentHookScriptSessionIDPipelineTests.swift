//
//  AgentHookScriptSessionIDPipelineTests.swift
//  CalyxTests
//
//  TDD Red Phase (fix round, item 5) — mock-less, end-to-end coverage
//  mirroring AgentHookPipelineIntegrationTests.swift: a real
//  calyx-agent-hook script, run as a real child Process, POSTing into a
//  real running CalyxMCPServer. This isolates the one remaining gap in
//  the persistent-session pane hook path: CalyxMCPServer's
//  /agent-event routing already resolves a calyx-session ID via
//  SessionSurfaceMap (see CalyxMCPServerSessionRoutingTests), and the
//  script's header value already prefers CALYX_SESSION_ID (see
//  AgentHookScriptSessionIDTests) — but the script's own fail-open
//  guard still only checks CALYX_SURFACE_ID, so a pane that somehow has
//  only CALYX_SESSION_ID set exits before ever sending anything.
//
//  Coverage:
//  - With only CALYX_SESSION_ID set (CALYX_SURFACE_ID left completely
//    unset), the script must still exit 0 (fail-open is preserved
//    either way) AND must actually attempt the POST, landing a
//    registry entry keyed by the surface SessionSurfaceMap resolves
//    the session ID to
//

import XCTest
@testable import Calyx

@MainActor
final class AgentHookScriptSessionIDPipelineTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private var tempHome: String!
    private var appSupportDir: String!
    private var scriptPath: String!
    private let testToken = "session-id-pipeline-test-token"

    // MARK: - Lifecycle

    override func setUp() async throws {
        try await super.setUp()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        appSupportDir = tempHome + "/Library/Application Support/Calyx"
        try FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)

        registry = AgentRegistry()
        server = CalyxMCPServer()
        server.agentRegistry = registry
        server.agentEndpointDirectory = appSupportDir
        // Isolated instance — never touch .shared, which other suites read.
        server.sessionSurfaceMap = SessionSurfaceMap()
        try server.start(token: testToken, preferredPort: Int.random(in: 49_152...65_000))

        scriptPath = try AgentHookScript.install(toDirectory: appSupportDir + "/bin")
    }

    override func tearDown() {
        server.stop()
        server = nil
        registry = nil
        if let tempHome {
            try? FileManager.default.removeItem(atPath: tempHome)
        }
        tempHome = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Runs the installed `calyx-agent-hook` script as a real child
    /// process (`/bin/sh <script>`), piping `stdinJSON` to its stdin.
    /// `sessionID` (when non-nil) sets `CALYX_SESSION_ID` alone —
    /// `CALYX_SURFACE_ID` is deliberately left completely unset, unlike
    /// every real production invocation (which always has
    /// CALYX_SURFACE_ID set), specifically to isolate whether the
    /// guard's own fail-open condition still depends on it.
    @discardableResult
    private func runHookScript(stdinJSON: String, sessionID: String?) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]

        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        var env = ["HOME": tempHome!, "PATH": inheritedPath]
        if let sessionID {
            env["CALYX_SESSION_ID"] = sessionID
        }
        process.environment = env

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(Data(stdinJSON.utf8))
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Polls `registry.entries[surfaceID]` for up to `timeout` seconds
    /// — the script's own `curl` call is a real network round-trip, so
    /// the registry update can land a few milliseconds after the child
    /// process itself has already exited.
    private func waitForEntry(surfaceID: UUID, timeout: TimeInterval = 2.0) async -> AgentEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = registry.entries[surfaceID] { return entry }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return registry.entries[surfaceID]
    }

    // MARK: - Only CALYX_SESSION_ID set

    func test_realHookScript_onlyCalyxSessionIDSet_stillExitsZeroAndForwardsEvent() async throws {
        let calyxSessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let resolvedSurfaceID = UUID()
        server.sessionSurfaceMap.register(sessionID: calyxSessionID, surfaceID: resolvedSurfaceID)

        let stdin = """
        {"session_id":"pipeline-session","cwd":"/Users/dev/pipeline-repo","hook_event_name":"SessionStart"}
        """

        let exitCode = try runHookScript(stdinJSON: stdin, sessionID: calyxSessionID)

        XCTAssertEqual(exitCode, 0, "The hook script must always exit 0, with only CALYX_SESSION_ID set or otherwise")

        let entry = await waitForEntry(surfaceID: resolvedSurfaceID)
        XCTAssertNotNil(entry,
                        "With only CALYX_SESSION_ID set, the script must still attempt the POST — the " +
                        "current guard (which only checks CALYX_SURFACE_ID) exits before ever sending " +
                        "anything, so no entry lands under the resolved surface")
        XCTAssertEqual(entry?.cwd, "/Users/dev/pipeline-repo")
    }

    // MARK: - Non-regression: both unset still exits 0 without forwarding

    func test_realHookScript_neitherSurfaceIDNorSessionIDSet_exitsZeroWithoutForwarding() async throws {
        let stdin = """
        {"session_id":"orphan-session","cwd":"/Users/dev/repo","hook_event_name":"SessionStart"}
        """

        let exitCode = try runHookScript(stdinJSON: stdin, sessionID: nil)

        XCTAssertEqual(exitCode, 0)
        XCTAssertTrue(registry.entries.isEmpty,
                     "With neither CALYX_SURFACE_ID nor CALYX_SESSION_ID set, nothing must be forwarded")
    }
}
