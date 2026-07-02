//
//  AgentHookPipelineIntegrationTests.swift
//  CalyxTests
//
//  Mock-less, end-to-end coverage for the full Agent Monitor hook
//  pipeline: calyx-agent-hook (a real /bin/sh script, run as a real
//  child Process) -> a real CalyxMCPServer bound to a real loopback
//  port -> a real AgentRegistry.
//
//  Every individual layer of this pipeline (AgentEvent.decode,
//  CalyxMCPServer.routeAgentEvent, AgentRegistry.handleHookEvent) already
//  has passing unit/mock coverage elsewhere in this test target. This
//  file exists because that layered coverage previously missed a real
//  production failure — ClaudeHooksConfigManager rejecting a dotfiles
//  symlink meant the script was never actually installed where Claude
//  Code could invoke it, which no amount of unit-testing the individual
//  pieces in isolation could catch. See ClaudeHooksConfigManagerTests'
//  dotfiles-fixture tests for the config-write side of that same lesson.
//
//  Coverage:
//  - A real SessionStart hook payload, piped through the real installed
//    script into the real running server, lands in the injected
//    AgentRegistry as an idle entry with the right cwd/session
//  - CALYX_SURFACE_ID unset (a plain, non-Calyx terminal) never reaches
//    the registry
//  - A missing agent-endpoint.json (server not running / not yet
//    started) exits 0 and never reaches the registry
//

import XCTest
@testable import Calyx

@MainActor
final class AgentHookPipelineIntegrationTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private var tempHome: String!
    private var appSupportDir: String!
    private var scriptPath: String!
    private let testToken = "pipeline-test-token"

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
        // A randomized preferred port (IANA dynamic/private range, one
        // per test run) rather than a hardcoded literal like the Round 3
        // review flagged — this test only needs *some* running server
        // (the script reads the actual bound port from
        // agent-endpoint.json at call time), so there's no reason to
        // risk colliding with a fixed port another test file or process
        // on the host might already be holding. `start()`'s own
        // canonical-scan-then-kernel-assigned-fallback still applies on
        // top of this if the randomly chosen port also happens to be
        // taken.
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
    /// `surfaceID` is set as `CALYX_SURFACE_ID` when non-nil; when nil
    /// the variable is left entirely unset, matching a plain
    /// (non-Calyx) terminal invocation.
    @discardableResult
    private func runHookScript(stdinJSON: String, surfaceID: UUID?) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]

        // Inherit the current process's own PATH (falling back to a
        // minimal stock-macOS one only if it's somehow unset) rather than
        // a hardcoded `/usr/bin:/bin:/usr/local/bin`, so the script's
        // `curl`/`sed` calls resolve correctly on hosts where those tools
        // live elsewhere (e.g. Homebrew's `/opt/homebrew/bin` on Apple
        // Silicon) instead of silently depending on this fixed list
        // matching the machine running the test.
        let inheritedPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        var env = ["HOME": tempHome!, "PATH": inheritedPath]
        if let surfaceID {
            env["CALYX_SURFACE_ID"] = surfaceID.uuidString
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

    /// Polls `registry.entries[surfaceID]` for up to `timeout` seconds.
    /// The script's own `curl` call is a real network round-trip through
    /// a real `NWListener`, so the registry update can land a few
    /// milliseconds after the child process itself has already exited —
    /// asserting immediately after `waitUntilExit()` would be flaky.
    private func waitForEntry(surfaceID: UUID, timeout: TimeInterval = 2.0) async -> AgentEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = registry.entries[surfaceID] { return entry }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return registry.entries[surfaceID]
    }

    // MARK: - Happy path

    func test_realHookScript_sessionStart_updatesRegistryViaRealServer() async throws {
        let surfaceID = UUID()
        let stdin = """
        {"session_id":"pipeline-session","cwd":"/Users/dev/pipeline-repo","hook_event_name":"SessionStart"}
        """

        let exitCode = try runHookScript(stdinJSON: stdin, surfaceID: surfaceID)

        XCTAssertEqual(exitCode, 0, "The hook script must always exit 0, even on the happy path")
        let entry = await waitForEntry(surfaceID: surfaceID)
        XCTAssertEqual(entry?.state, .idle,
                       "A real SessionStart POST through the real script+server must register the surface as idle")
        XCTAssertEqual(entry?.cwd, "/Users/dev/pipeline-repo")
        XCTAssertEqual(entry?.sessionID, "pipeline-session")
    }

    // MARK: - CALYX_SURFACE_ID unset (plain terminal)

    func test_realHookScript_surfaceIDUnset_leavesRegistryUntouched() async throws {
        // Sanity: the same stdin payload DOES register an entry when
        // CALYX_SURFACE_ID is set, proving the assertion below is caused
        // by the unset variable and not some other pipeline failure.
        let sanitySurfaceID = UUID()
        let stdin = """
        {"session_id":"sanity-session","cwd":"/Users/dev/repo","hook_event_name":"SessionStart"}
        """
        _ = try runHookScript(stdinJSON: stdin, surfaceID: sanitySurfaceID)
        let sanityEntry = await waitForEntry(surfaceID: sanitySurfaceID)
        XCTAssertNotNil(sanityEntry, "Precondition: the pipeline must register an entry when CALYX_SURFACE_ID is set")

        let exitCode = try runHookScript(stdinJSON: stdin, surfaceID: nil)

        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(registry.entries.count, 1,
                       "A hook invocation with no CALYX_SURFACE_ID must never reach the registry " +
                       "(plain terminal safety) — no entry beyond the sanity one above")
    }

    // MARK: - Missing agent-endpoint.json (server unreachable / not yet started)

    func test_realHookScript_endpointFileMissing_exitsZeroAndLeavesRegistryUntouched() async throws {
        let endpointPath = appSupportDir + "/agent-endpoint.json"
        try FileManager.default.removeItem(atPath: endpointPath)

        let surfaceID = UUID()
        let stdin = """
        {"session_id":"orphan-session","cwd":"/Users/dev/repo","hook_event_name":"SessionStart"}
        """

        let exitCode = try runHookScript(stdinJSON: stdin, surfaceID: surfaceID)

        XCTAssertEqual(exitCode, 0, "A missing agent-endpoint.json must still exit 0 (never break the hook chain)")
        let entry = await waitForEntry(surfaceID: surfaceID, timeout: 0.5)
        XCTAssertNil(entry, "With no agent-endpoint.json to read, the script must never reach the registry")
    }
}
