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
//  - SessionStart then Stop settle a codex-kind row at .idle, then a
//    SessionEnd payload for the same session/surface, through the real
//    installed script, settles it to .done -- the receiving side of
//    AgentRegistry's existing SessionEnd -> .done mapping. Whether Codex
//    itself is configured to fire a SessionEnd event at all is pinned
//    separately by CodexHooksConfigManagerTests
//  - A subagent event delivered while the surface already has a live
//    parent row lands as a child in AgentRegistry.subagentRegistry
//    without creating, replacing, or mutating that parent row
//  - A subagent event for a surface with no row at all creates no child
//    and never mints a parent row
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
        server = CalyxMCPServer(agentEndpointDirectory: appSupportDir)
        server.agentRegistry = registry
        // A randomized preferred port (IANA dynamic/private range, one
        // per test run) rather than a hardcoded literal — this test only
        // needs *some* running server (the script reads the actual bound
        // port from agent-endpoint.json at call time), so there's no
        // reason to risk colliding with a fixed port another test file
        // or process on the host might already be holding. `start()`'s
        // own canonical-scan-then-kernel-assigned-fallback still applies
        // on top of this if the randomly chosen port also happens to be
        // taken.
        try await server.start(token: testToken, preferredPort: Int.random(in: 49_152...65_000))

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
    /// process (`/bin/sh <script> [kindArgument]`), piping `stdinJSON` to
    /// its stdin. `surfaceID` is set as `CALYX_SURFACE_ID` when non-nil;
    /// when nil the variable is left entirely unset, matching a plain
    /// (non-Calyx) terminal invocation. `kindArgument`, when non-nil, is
    /// passed as the script's `$1` (e.g. `"codex"`) -- nil matches Claude
    /// Code's own installed hook entry, which invokes the script with no
    /// arguments at all. Mirrors `ApprovalHookPipelineIntegrationTests
    /// .runHookScript`'s identical `kindArgument` parameter.
    @discardableResult
    private func runHookScript(stdinJSON: String, surfaceID: UUID?, kindArgument: String? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        var arguments: [String] = [scriptPath]
        if let kindArgument {
            arguments.append(kindArgument)
        }
        process.arguments = arguments

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

    /// Polls `registry.entries[surfaceID]` for up to `timeout` seconds
    /// until it exists and satisfies `predicate` (defaulting to
    /// always-true, i.e. wait only for the entry to exist). The script's
    /// own `curl` call is a real network round-trip through a real
    /// `NWListener`, so the registry update can land a few milliseconds
    /// after the child process itself has already exited: asserting
    /// immediately after `waitUntilExit()` would be flaky. A non-default
    /// `predicate` is needed whenever a later event in a multi-event
    /// sequence updates an entry that already exists from an earlier
    /// step, since waiting for mere existence would then return
    /// immediately on that earlier step's own state, before the later
    /// event has had any chance to land.
    ///
    /// Returns nil both when no entry ever appears and when an entry
    /// exists but never satisfies `predicate` within `timeout`, so a
    /// caller cannot mistake a stale, non-matching entry left over from
    /// an earlier step for an actual match.
    private func waitForEntry(
        surfaceID: UUID,
        timeout: TimeInterval = 2.0,
        matching predicate: @escaping (AgentEntry) -> Bool = { _ in true }
    ) async -> AgentEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let entry = registry.entries[surfaceID], predicate(entry) { return entry }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let entry = registry.entries[surfaceID], predicate(entry) { return entry }
        return nil
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

    // MARK: - Codex SessionEnd settles an idle row to done

    /// Pins the receiving end of AgentStateResolver.resultingState's SessionEnd
    /// -> .done mapping for a codex-kind row, end to end through the real
    /// installed script: SessionStart then Stop settle the row at .idle,
    /// then a SessionEnd payload shaped like Codex's real hook JSON
    /// (session_id/cwd/hook_event_name/reason) is posted through the real
    /// installed script with the "codex" $1 argument
    /// CodexHooksConfigManager's installed command entries pass, exactly
    /// as ApprovalHookPipelineIntegrationTests' codex-kind coverage
    /// already does for the approval pipeline. Whether Codex's own hook
    /// config is actually written with a SessionEnd entry to fire this
    /// event in the first place is pinned separately by
    /// CodexHooksConfigManagerTests; this test only covers what happens
    /// once that event arrives here.
    func test_realHookScript_codexSessionEnd_settlesIdleRowToDone() async throws {
        let surfaceID = UUID()
        let sessionID = "pipeline-codex-session"
        let cwd = "/Users/dev/pipeline-codex-repo"

        let sessionStartStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SessionStart"}
        """
        let stopStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"Stop"}
        """
        // Codex's SessionEnd payload carries session_id, transcript_path,
        // cwd, hook_event_name, and reason. transcript_path is null here
        // because Codex 0.148.0's embedded schema requires the key but
        // declares its value nullable, so a real payload always includes
        // the key even with no transcript file to point at. reason is
        // present and simply ignored, since AgentEvent.decode models no
        // such field.
        let sessionEndStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SessionEnd","reason":"other","transcript_path":null}
        """

        let startExitCode = try runHookScript(stdinJSON: sessionStartStdin, surfaceID: surfaceID, kindArgument: "codex")
        XCTAssertEqual(startExitCode, 0, "the hook script must always exit 0")
        let afterStart = await waitForEntry(surfaceID: surfaceID)
        XCTAssertEqual(afterStart?.state, .idle, "Precondition: SessionStart must register the row as idle")
        XCTAssertEqual(afterStart?.kind, AgentEntry.codexKind,
                       "Precondition: the codex $1 argument must attribute the row to codex, not claude-code")

        let stopExitCode = try runHookScript(stdinJSON: stopStdin, surfaceID: surfaceID, kindArgument: "codex")
        XCTAssertEqual(stopExitCode, 0, "the hook script must always exit 0")
        // waitForEntry with the default predicate would return immediately
        // here -- the entry already exists (and is already .idle) from the
        // SessionStart step above -- so this instead waits for
        // lastEventAt to advance past that step's own timestamp. Because
        // waitForEntry only returns non-nil once the Stop event has
        // actually landed and advanced lastEventAt, XCTUnwrap below fails
        // the test outright if this Stop POST never lands, rather than
        // silently passing on the SessionStart entry's own unchanged
        // idle state.
        let startLastEventAt = try XCTUnwrap(afterStart?.lastEventAt)
        let stopMatch = await waitForEntry(surfaceID: surfaceID) { $0.lastEventAt > startLastEventAt }
        let afterStop = try XCTUnwrap(
            stopMatch,
            "The Stop POST must land and advance lastEventAt before the SessionEnd step below fires"
        )
        XCTAssertEqual(afterStop.state, .idle,
                       "Precondition: Stop settles the row at idle, matching AgentStateResolver.resultingState's " +
                       "Stop -> .idle mapping; only a subsequent SessionEnd event moves it to .done")

        let endExitCode = try runHookScript(stdinJSON: sessionEndStdin, surfaceID: surfaceID, kindArgument: "codex")

        XCTAssertEqual(endExitCode, 0, "the hook script must always exit 0")
        let afterEnd = await waitForEntry(surfaceID: surfaceID) { $0.state == .done }
        XCTAssertEqual(afterEnd?.state, .done,
                       "A SessionEnd event for the same session on the same surface must settle an idle " +
                       "Codex row to done, exactly like AgentStateResolver.resultingState's " +
                       "SessionEnd -> .done mapping already does for any other kind")
        XCTAssertEqual(afterEnd?.sessionID, sessionID)
        XCTAssertEqual(afterEnd?.kind, AgentEntry.codexKind, "the settled .done row must still be the codex row")
    }

    // MARK: - A subagent event under a live parent row lands as a child, untouched parent

    /// End to end through the real `/bin/sh` hook script, the real
    /// server, and the real registry: a subagent event delivered while
    /// the surface already has a live (non-`.done`) row must land as a
    /// child in `AgentRegistry.subagentRegistry` without creating,
    /// replacing, or mutating the parent row -- mirroring real usage,
    /// where Claude Code always fires a SessionStart for the pane before
    /// any subagent it spawns can fire its own SubagentStart.
    func test_realHookScript_subagentEvent_underLiveParentRow_landsAsChild_parentRowUntouched() async throws {
        let surfaceID = UUID()
        let sessionID = "parent-session"
        let cwd = "/Users/dev/repo"

        let sessionStartStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SessionStart"}
        """
        let startExitCode = try runHookScript(stdinJSON: sessionStartStdin, surfaceID: surfaceID)
        XCTAssertEqual(startExitCode, 0, "the hook script must always exit 0")
        let parentBeforeResult = await waitForEntry(surfaceID: surfaceID)
        let parentBefore = try XCTUnwrap(
            parentBeforeResult,
            "Precondition: the parent must have a live row before the subagent event fires"
        )
        XCTAssertEqual(parentBefore.state, .idle, "Precondition: SessionStart registers the row as idle")

        let subagentStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStart",\
        "agent_id":"sub-001","agent_type":"general-purpose"}
        """
        let subagentExitCode = try runHookScript(stdinJSON: subagentStdin, surfaceID: surfaceID)
        XCTAssertEqual(subagentExitCode, 0, "the hook script must always exit 0")

        // Give the real network round-trip a moment, the same way
        // waitForEntry does for a parent row, but this time polling the
        // subagent store instead.
        let deadline = Date().addingTimeInterval(2.0)
        var children: [SubagentEntry] = []
        while Date() < deadline {
            children = registry.subagentRegistry.children(of: surfaceID)
            if !children.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(children.count, 1, "The real SubagentStart POST must land in the subagent store")
        XCTAssertEqual(children.first?.agentID, "sub-001")
        XCTAssertEqual(children.first?.agentType, "general-purpose")

        let parentAfter = try XCTUnwrap(
            registry.entries[surfaceID],
            "The subagent event must not remove the parent row"
        )
        XCTAssertEqual(parentAfter.sessionID, parentBefore.sessionID,
                       "The subagent event must not replace the parent row's sessionID")
        XCTAssertEqual(parentAfter.cwd, parentBefore.cwd,
                       "The subagent event must not replace the parent row's cwd")
        XCTAssertEqual(parentAfter.kind, parentBefore.kind,
                       "The subagent event must not replace the parent row's kind")
        XCTAssertEqual(registry.entries.count, 1,
                       "The subagent event must not create a second row for this surface")
    }

    // MARK: - A subagent event with no row at all creates no child

    /// Pins the new guard directly, end to end through the real script
    /// and server: a subagent event delivered to a surface with no row
    /// at all -- the CLI's own SessionStart POST has not landed, or
    /// never will -- must create no child. A child is only ever tracked
    /// under a live row; one tracked under a surface with no row would
    /// be invisible (the sidebar only renders children beneath an
    /// existing parent row) and nothing would ever clean it up.
    func test_realHookScript_subagentEvent_surfaceWithNoRowAtAll_createsNoChild() async throws {
        let surfaceID = UUID()
        let stdin = """
        {"session_id":"parent-session","cwd":"/Users/dev/repo","hook_event_name":"SubagentStart",\
        "agent_id":"sub-001","agent_type":"general-purpose"}
        """

        let exitCode = try runHookScript(stdinJSON: stdin, surfaceID: surfaceID)

        XCTAssertEqual(exitCode, 0, "the hook script must always exit 0")

        // Assert an absence over a real network round-trip: run a
        // live-parent+child flow on a second surface first, as a sanity
        // barrier proving the pipeline is actually up and would have
        // delivered the event above had the guard not dropped it.
        let sanitySurfaceID = UUID()
        let sanitySessionStartStdin = """
        {"session_id":"sanity-session","cwd":"/Users/dev/repo","hook_event_name":"SessionStart"}
        """
        _ = try runHookScript(stdinJSON: sanitySessionStartStdin, surfaceID: sanitySurfaceID)
        _ = await waitForEntry(surfaceID: sanitySurfaceID)
        let sanitySubagentStdin = """
        {"session_id":"sanity-session","cwd":"/Users/dev/repo","hook_event_name":"SubagentStart",\
        "agent_id":"sub-sanity","agent_type":"general-purpose"}
        """
        _ = try runHookScript(stdinJSON: sanitySubagentStdin, surfaceID: sanitySurfaceID)
        let sanityDeadline = Date().addingTimeInterval(2.0)
        var sanityChildren: [SubagentEntry] = []
        while Date() < sanityDeadline {
            sanityChildren = registry.subagentRegistry.children(of: sanitySurfaceID)
            if !sanityChildren.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(sanityChildren.count, 1,
                       "Precondition: the pipeline is up and does deliver a child event when a live row exists")

        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                      "A subagent event for a surface with no row at all must create no child")
        XCTAssertNil(registry.entries[surfaceID],
                     "A subagent event alone must never mint a parent row for the surface")
    }
}
