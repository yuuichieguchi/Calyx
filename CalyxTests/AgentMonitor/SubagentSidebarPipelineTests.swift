//
//  SubagentSidebarPipelineTests.swift
//  CalyxTests
//
//  Raises the manual GUI checklist (items 3 through 10) into automated
//  coverage, wherever the check does not genuinely require looking at
//  pixels. Driven the same way as AgentHookPipelineIntegrationTests: a
//  real /bin/sh calyx-agent-hook script, run as a real child Process,
//  piping real captured stdin JSON into a real CalyxMCPServer bound to
//  a real loopback port, landing in a real AgentRegistry (and its
//  SubagentRegistry). Assertions are made on AgentSidebarRows.build's
//  own output -- what the sidebar actually renders -- rather than on
//  any view.
//
//  Claude Code and Grok payload shapes below are the exact field names,
//  event values, and (where given) IDs captured from real CLI runs.
//  Session/cwd strings the capture didn't pin to a specific value follow
//  this test target's own existing placeholder convention (e.g.
//  "parent-session"), matching AgentHookPipelineIntegrationTests.
//
//  Coverage:
//  - Claude Code: PreToolUse(Agent) -> SubagentStart(Explore) ->
//    PreToolUse(Bash, child-scoped) -> SubagentStop, asserting the row
//    list at every step
//  - Grok: the full 7-event capture, including the parent-keyed
//    subagent_start and the proof that it resolves to the SAME child as
//    the session-keyed events around it (not a second, orphaned one),
//    the parent staying .working throughout, and the child's own
//    session_end neither resurrecting the child nor settling the parent
//  - Three concurrent Claude Code children: count, children(of:) order
//    under expansion, and independent retirement
//  - A child-scoped PermissionRequest (Grok's real notification /
//    permission_prompt shape, scoped to one child's own session)
//    blocking the parent and only that one child
//  - A pane with no children at all renders identically to
//    AgentSidebarRows.build fed a hardcoded empty child closure
//  - Force-quit: handlePaneCommandFinished's pane-exit settle sweeps
//    every child, and a late child event for that now-.done surface
//    creates nothing
//  - Codex: a session-mismatched SessionEnd AgentStateResolver rejects
//    for the parent row must not clear a live child, and -- separately
//    -- an ACCEPTED, same-session Stop must not clear one either, since
//    an accepted Stop no longer retires children at all
//  - A child-scoped PreToolUse carrying tool_input.command reaches the
//    child row AgentSidebarRows.build renders with that command as its
//    lastToolSummary
//  - The real captured Claude Code sequence (two concurrent children,
//    a parent-scoped Stop while both are still mid-flight, then each
//    child's own PostToolUse/SubagentStop): the row list at every step
//    never drops the two children across the Stop, and each retires
//    only on its own SubagentStop
//

import XCTest
@testable import Calyx

@MainActor
final class SubagentSidebarPipelineTests: XCTestCase {

    // MARK: - Properties

    private var server: CalyxMCPServer!
    private var registry: AgentRegistry!
    private var tempHome: String!
    private var appSupportDir: String!
    private var scriptPath: String!
    private let testToken = "subagent-sidebar-test-token"

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

    // MARK: - Helpers (mirrors AgentHookPipelineIntegrationTests)

    @discardableResult
    private func runHookScript(stdinJSON: String, surfaceID: UUID?, kindArgument: String? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        var arguments: [String] = [scriptPath]
        if let kindArgument {
            arguments.append(kindArgument)
        }
        process.arguments = arguments

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

    /// Polls `registry.subagentRegistry.children(of:)` until `predicate`
    /// is satisfied or `timeout` elapses, returning `nil` on timeout --
    /// the same nil-on-no-match contract as `waitForEntry`, so a caller
    /// asserting an absence (e.g. "this agentID is gone") can tell a real
    /// negative apart from a network delay by using a deliberately short
    /// timeout, exactly as `AgentHookPipelineIntegrationTests` already
    /// does for its own absence assertions.
    private func waitForChildren(
        of parentSurfaceID: UUID,
        timeout: TimeInterval = 2.0,
        matching predicate: @escaping ([SubagentEntry]) -> Bool
    ) async -> [SubagentEntry]? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let children = registry.subagentRegistry.children(of: parentSurfaceID)
            if predicate(children) { return children }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let children = registry.subagentRegistry.children(of: parentSurfaceID)
        return predicate(children) ? children : nil
    }

    /// Builds the exact row list `AgentStatusView.content`'s `ForEach`
    /// renders, from the live registry.
    private func rows(expanded: Set<UUID>) -> [AgentSidebarRows.Row] {
        AgentSidebarRows.build(
            entries: registry.sortedEntries,
            children: { registry.subagentRegistry.children(of: $0) },
            expanded: expanded
        )
    }

    // MARK: - Claude Code: the full captured sequence, row list at every step

    /// Replays the exact 4-event Claude Code capture verbatim: one
    /// `Task` launching an `Explore` subagent that runs one `Bash`
    /// command, every event sharing the parent's own `session_id`.
    func test_claudeCode_subagentSequence_rowListAtEachStep() async throws {
        let surfaceID = UUID()
        let sessionID = "parent-session"
        let cwd = "/Users/dev/repo"
        let agentID = "a5bfac2e378042079"

        // Event 1: PreToolUse, no agent_id, no agent_type, tool_name "Agent".
        let event1 = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"PreToolUse","tool_name":"Agent"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event1, surfaceID: surfaceID), 0)
        let afterEvent1 = await waitForEntry(surfaceID: surfaceID)
        XCTAssertEqual(afterEvent1?.state, .working, "Precondition: the parent's own Agent PreToolUse creates the row")
        XCTAssertEqual(afterEvent1?.kind, AgentEntry.claudeCodeKind)

        let rowsAfterEvent1 = rows(expanded: [surfaceID])
        XCTAssertEqual(rowsAfterEvent1.count, 1, "No child exists yet: one parent row only")
        guard case .parent(_, let childCount1, _) = rowsAfterEvent1[0] else {
            return XCTFail("Row 0 must be the parent")
        }
        XCTAssertEqual(childCount1, 0, "After event 1: childCount 0")

        // Event 2: SubagentStart, agent_id present, agent_type "Explore", no tool_name.
        let event2 = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStart",\
        "agent_id":"\(agentID)","agent_type":"Explore"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event2, surfaceID: surfaceID), 0)
        let childrenAfterEvent2 = await waitForChildren(of: surfaceID) { $0.count == 1 }
        XCTAssertEqual(childrenAfterEvent2?.count, 1, "After event 2: one child must exist")

        let collapsedAfterEvent2 = rows(expanded: [])
        XCTAssertEqual(collapsedAfterEvent2.count, 1, "Collapsed: only the parent row, even with a child present")
        guard case .parent(let parentEntry2, let childCount2, let isExpanded2) = collapsedAfterEvent2[0] else {
            return XCTFail("Row 0 must be the parent")
        }
        XCTAssertEqual(childCount2, 1, "After event 2: childCount 1")
        XCTAssertFalse(isExpanded2)
        XCTAssertEqual(parentEntry2.state, .working, "SubagentStart maps to no state; the parent stays as event 1 left it")

        let expandedAfterEvent2 = rows(expanded: [surfaceID])
        XCTAssertEqual(expandedAfterEvent2.count, 2, "Expanded: the parent row plus its one child row")
        guard case .parent = expandedAfterEvent2[0] else {
            return XCTFail("Row 0 must still be the parent")
        }
        guard case .child(let child2) = expandedAfterEvent2[1] else {
            return XCTFail("Row 1 must be the child, directly after its parent")
        }
        XCTAssertEqual(child2.agentID, agentID)
        XCTAssertEqual(child2.agentType, "Explore")

        // Event 3: PreToolUse inside the child, tool_name "Bash".
        let event3 = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"PreToolUse",\
        "agent_id":"\(agentID)","agent_type":"Explore","tool_name":"Bash"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event3, surfaceID: surfaceID), 0)
        let childrenAfterEvent3 = await waitForChildren(of: surfaceID) { $0.first?.lastToolName == "Bash" }
        XCTAssertEqual(childrenAfterEvent3?.first?.lastToolName, "Bash", "After event 3: the child's lastToolName is Bash")

        let expandedAfterEvent3 = rows(expanded: [surfaceID])
        guard case .child(let child3) = expandedAfterEvent3[safe: 1] else {
            return XCTFail("Row 1 must still be the child row")
        }
        XCTAssertEqual(child3.lastToolName, "Bash")

        // Event 4: SubagentStop, agent_id present, agent_type "Explore", no tool_name.
        let event4 = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStop",\
        "agent_id":"\(agentID)","agent_type":"Explore"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event4, surfaceID: surfaceID), 0)
        let childrenAfterEvent4 = await waitForChildren(of: surfaceID) { $0.isEmpty }
        XCTAssertEqual(childrenAfterEvent4?.isEmpty, true, "After event 4: no children remain")

        let rowsAfterEvent4 = rows(expanded: [surfaceID])
        XCTAssertEqual(rowsAfterEvent4.count, 1, "Back to one parent row with no child rows, even while still expanded")
        guard case .parent(_, let childCount4, _) = rowsAfterEvent4[0] else {
            return XCTFail("Row 0 must be the parent")
        }
        XCTAssertEqual(childCount4, 0, "After event 4: childCount 0")
    }

    // MARK: - Grok: the full captured 7-event sequence

    /// Replays the exact 7-event Grok capture verbatim, including the
    /// real parent and child session IDs the capture pinned. Proves
    /// events 2 and 3 resolve to ONE child (the bug the real capture
    /// exposed: `subagent_start` alone carries the PARENT's
    /// `sessionId`), that the parent stays `.working` for the child's
    /// whole run, that the child is gone after event 5, and that the
    /// child's own `session_end` (event 6) neither resurrects it nor
    /// settles the parent -- only the parent's own `session_end`
    /// (event 7) does that.
    func test_grok_subagentSequence_oneChildAndParentStaysWorking() async throws {
        let surfaceID = UUID()
        let parentSessionID = "01a02092-04e6-73a1-9d04-e1bd11dcd4fa"
        let childSessionID = "01a02092-1cc5-7e53-be01-6b4de101b378"

        // Event 1: pre_tool_use (parent), toolName "spawn_subagent".
        let event1 = """
        {"hookEventName":"pre_tool_use","sessionId":"\(parentSessionID)","toolName":"spawn_subagent"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event1, surfaceID: surfaceID, kindArgument: "grok"), 0)
        let afterEvent1 = await waitForEntry(surfaceID: surfaceID)
        XCTAssertEqual(afterEvent1?.state, .working, "Precondition: the parent's own pre_tool_use creates the row")
        XCTAssertEqual(afterEvent1?.kind, AgentEntry.grokKind)
        let lastEventAtAfterEvent1 = try XCTUnwrap(afterEvent1?.lastEventAt)

        // Event 2: subagent_start, sessionId is the PARENT's, subagentId names the child.
        let event2 = """
        {"hookEventName":"subagent_start","sessionId":"\(parentSessionID)",\
        "subagentId":"\(childSessionID)","subagentType":"general-purpose"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event2, surfaceID: surfaceID, kindArgument: "grok"), 0)
        let childrenAfterEvent2 = await waitForChildren(of: surfaceID) { $0.count == 1 }
        XCTAssertEqual(childrenAfterEvent2?.count, 1, "After event 2: one child, keyed by the child's own session id")
        XCTAssertEqual(childrenAfterEvent2?.first?.agentID, childSessionID)

        // Event 3: pre_tool_use (child), sessionId is the CHILD's own, no subagentId.
        let event3 = """
        {"hookEventName":"pre_tool_use","sessionId":"\(childSessionID)",\
        "subagentType":"general-purpose","toolName":"run_terminal_command"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event3, surfaceID: surfaceID, kindArgument: "grok"), 0)
        let childrenAfterEvent3 = await waitForChildren(of: surfaceID) { $0.first?.lastToolName == "run_terminal_command" }
        // The one-child proof: count stays 1 AND the tool name from event 3
        // landed on the SAME child event 2 created -- if subagent_start's
        // parent-keyed sessionId had instead minted a phantom child keyed
        // to the parent, event 3 would either create a SECOND child (count
        // 2) or update nothing at all (lastToolName staying nil), never
        // this.
        XCTAssertEqual(childrenAfterEvent3?.count, 1, "Events 2 and 3 must resolve to exactly one child, not two")
        XCTAssertEqual(childrenAfterEvent3?.first?.agentID, childSessionID)
        XCTAssertEqual(childrenAfterEvent3?.first?.lastToolName, "run_terminal_command")
        XCTAssertEqual(childrenAfterEvent3?.first?.state, .working)
        let parentAfterEvent3 = try XCTUnwrap(registry.entries[surfaceID])
        XCTAssertEqual(parentAfterEvent3.state, .working, "The parent row stays .working while the child runs")

        // Event 4: pre_tool_use (parent again), toolName "get_command_or_subagent_output".
        let event4 = """
        {"hookEventName":"pre_tool_use","sessionId":"\(parentSessionID)",\
        "toolName":"get_command_or_subagent_output"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event4, surfaceID: surfaceID, kindArgument: "grok"), 0)
        let afterEvent4 = await waitForEntry(surfaceID: surfaceID) { $0.lastEventAt > lastEventAtAfterEvent1 }
        XCTAssertEqual(afterEvent4?.state, .working)
        let lastEventAtAfterEvent4 = try XCTUnwrap(afterEvent4?.lastEventAt)
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1, "Event 4 must not touch the child")

        // Event 5: subagent_stop, sessionId and subagentId both the child's.
        let event5 = """
        {"hookEventName":"subagent_stop","sessionId":"\(childSessionID)",\
        "subagentId":"\(childSessionID)","subagentType":"general-purpose"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event5, surfaceID: surfaceID, kindArgument: "grok"), 0)
        let childrenAfterEvent5 = await waitForChildren(of: surfaceID) { $0.isEmpty }
        XCTAssertEqual(childrenAfterEvent5?.isEmpty, true, "After event 5: the child is gone")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "The child stopping must not settle the parent")

        // Event 6: session_end for the CHILD's own session (sessionId child, no subagentId).
        let event6 = """
        {"hookEventName":"session_end","sessionId":"\(childSessionID)","subagentType":"general-purpose"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event6, surfaceID: surfaceID, kindArgument: "grok"), 0)
        // Event 6 is a genuine no-op on both stores: nothing to poll for
        // positively, so this asserts the absence of the two things it
        // must NOT do, over a short timeout rather than the full default.
        let resurrectedChild = await waitForChildren(of: surfaceID, timeout: 0.5) { !$0.isEmpty }
        XCTAssertNil(resurrectedChild, "The child's own session_end must not resurrect a child row")
        let settledByEvent6 = await waitForEntry(surfaceID: surfaceID, timeout: 0.5) { $0.state == .done }
        XCTAssertNil(settledByEvent6, "The child's own session_end must not settle the parent")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .working, "The parent must still be .working after event 6")

        // Event 7: session_end for the PARENT's own session.
        let event7 = """
        {"hookEventName":"session_end","sessionId":"\(parentSessionID)"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event7, surfaceID: surfaceID, kindArgument: "grok"), 0)
        let afterEvent7 = await waitForEntry(surfaceID: surfaceID) { $0.state == .done }
        XCTAssertEqual(afterEvent7?.state, .done, "Only the parent's own session_end settles the parent")
        XCTAssertGreaterThan(try XCTUnwrap(afterEvent7?.lastEventAt), lastEventAtAfterEvent4)
    }

    // MARK: - Three concurrent Claude Code children

    /// Three `Task` calls in parallel: `childCount` reaches 3, expanded
    /// rows appear after their parent in `children(of:)`'s sorted-by-
    /// agentID order regardless of arrival order, none appear when
    /// collapsed, and each child retires independently until the
    /// chevron condition (`childCount > 0`) goes false.
    func test_claudeCode_threeConcurrentChildren_orderAndIndependentRetirement() async throws {
        let surfaceID = UUID()
        let sessionID = "parent-session"
        let cwd = "/Users/dev/repo"

        let sessionStart = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SessionStart"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sessionStart, surfaceID: surfaceID), 0)
        _ = await waitForEntry(surfaceID: surfaceID)

        // Sent out of sorted order deliberately, so an order assertion
        // below cannot pass by coincidence of send order.
        func subagentStart(_ agentID: String) -> String {
            """
            {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStart",\
            "agent_id":"\(agentID)","agent_type":"Explore"}
            """
        }
        for agentID in ["agent-c", "agent-a", "agent-b"] {
            XCTAssertEqual(try runHookScript(stdinJSON: subagentStart(agentID), surfaceID: surfaceID), 0)
        }
        let childrenAfterAll = await waitForChildren(of: surfaceID) { $0.count == 3 }
        XCTAssertEqual(childrenAfterAll?.count, 3, "childCount must reach 3")

        let collapsed = rows(expanded: [])
        XCTAssertEqual(collapsed.count, 1, "Collapsed: only the parent row appears")
        guard case .parent(_, let childCount, let isExpanded) = collapsed[0] else {
            return XCTFail("Row 0 must be the parent")
        }
        XCTAssertEqual(childCount, 3)
        XCTAssertFalse(isExpanded)

        let expanded = rows(expanded: [surfaceID])
        XCTAssertEqual(expanded.count, 4, "Expanded: the parent row plus 3 child rows")
        let childIDsInOrder: [String] = expanded.dropFirst().compactMap { row in
            if case .child(let child) = row { return child.agentID }
            return nil
        }
        XCTAssertEqual(childIDsInOrder, ["agent-a", "agent-b", "agent-c"],
                       "Expanded child rows must appear in children(of:)'s sorted-by-agentID order, " +
                       "not send order")

        // Retire agent-a first.
        let stopA = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStop",\
        "agent_id":"agent-a","agent_type":"Explore"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: stopA, surfaceID: surfaceID), 0)
        let childrenAfterA = await waitForChildren(of: surfaceID) { $0.count == 2 }
        XCTAssertEqual(childrenAfterA?.map(\.agentID).sorted(), ["agent-b", "agent-c"],
                       "Exactly agent-b and agent-c remain, independent of agent-a's own retirement")

        // Retire agent-b next.
        let stopB = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStop",\
        "agent_id":"agent-b","agent_type":"Explore"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: stopB, surfaceID: surfaceID), 0)
        let childrenAfterB = await waitForChildren(of: surfaceID) { $0.count == 1 }
        XCTAssertEqual(childrenAfterB?.map(\.agentID), ["agent-c"], "Only agent-c remains")

        let rowsBeforeLast = rows(expanded: [surfaceID])
        guard case .parent(_, let childCountBeforeLast, _) = rowsBeforeLast[0] else {
            return XCTFail("Row 0 must be the parent")
        }
        XCTAssertEqual(childCountBeforeLast, 1, "The chevron condition (childCount > 0) still holds with one child left")

        // Retire agent-c last.
        let stopC = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStop",\
        "agent_id":"agent-c","agent_type":"Explore"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: stopC, surfaceID: surfaceID), 0)
        let childrenAfterC = await waitForChildren(of: surfaceID) { $0.isEmpty }
        XCTAssertEqual(childrenAfterC?.isEmpty, true)

        let rowsAfterLast = rows(expanded: [surfaceID])
        XCTAssertEqual(rowsAfterLast.count, 1, "The chevron condition goes false: no child rows, even while expanded")
        guard case .parent(_, let childCountAfterLast, _) = rowsAfterLast[0] else {
            return XCTFail("Row 0 must be the parent")
        }
        XCTAssertEqual(childCountAfterLast, 0)
    }

    // MARK: - A child-scoped PermissionRequest blocks the parent and only that child

    /// Grok's real `notification` / `notificationType: "permission_prompt"`
    /// shape (`GrokHooksConfigManager` installs `Notification`'s hook
    /// matcher as exactly `"permission_prompt"`, and
    /// `AgentEventGrokDecodeTests` pins that this notificationType alone
    /// -- never the message -- decides `PermissionRequest`), scoped to one
    /// child's own session per the same child-identity rule event 3 in
    /// the 7-event capture already exercises (child-scoped events carry
    /// the child's own `sessionId`, no `subagentId`). Asserts the parent
    /// row goes `.blocked`, that one child goes `.blocked` too, and that
    /// its sibling is left in its own, different state.
    func test_grok_childScopedPermissionRequest_blocksParentAndOnlyThatChild() async throws {
        let surfaceID = UUID()
        let parentSessionID = "parent-session-perm"
        let child1SessionID = "child-session-1"
        let child2SessionID = "child-session-2"

        let parentStart = """
        {"hookEventName":"pre_tool_use","sessionId":"\(parentSessionID)","toolName":"spawn_subagent"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: parentStart, surfaceID: surfaceID, kindArgument: "grok"), 0)
        _ = await waitForEntry(surfaceID: surfaceID)

        func subagentStart(sessionID: String) -> String {
            """
            {"hookEventName":"subagent_start","sessionId":"\(parentSessionID)",\
            "subagentId":"\(sessionID)","subagentType":"general-purpose"}
            """
        }
        XCTAssertEqual(
            try runHookScript(stdinJSON: subagentStart(sessionID: child1SessionID), surfaceID: surfaceID, kindArgument: "grok"),
            0
        )
        XCTAssertEqual(
            try runHookScript(stdinJSON: subagentStart(sessionID: child2SessionID), surfaceID: surfaceID, kindArgument: "grok"),
            0
        )
        let childrenAfterStarts = await waitForChildren(of: surfaceID) { $0.count == 2 }
        XCTAssertEqual(childrenAfterStarts?.count, 2, "Precondition: both children exist, both .working")
        XCTAssertTrue(childrenAfterStarts?.allSatisfy { $0.state == .working } ?? false)

        // Child-scoped permission prompt: sessionId is child1's own, no
        // subagentId -- the same identity rule the Grok capture's own
        // child-scoped events (2 and 3 in the other test) already follow.
        let permissionPrompt = """
        {"hookEventName":"notification","sessionId":"\(child1SessionID)",\
        "subagentType":"general-purpose","notificationType":"permission_prompt"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: permissionPrompt, surfaceID: surfaceID, kindArgument: "grok"), 0)

        let afterPrompt = await waitForEntry(surfaceID: surfaceID) { $0.state == .blocked }
        XCTAssertEqual(afterPrompt?.state, .blocked, "The parent row must go .blocked")

        let children = registry.subagentRegistry.children(of: surfaceID)
        let blockedChild = children.first { $0.agentID == child1SessionID }
        let otherChild = children.first { $0.agentID == child2SessionID }
        XCTAssertEqual(blockedChild?.state, .blocked, "Only the child the prompt named goes .blocked")
        XCTAssertEqual(otherChild?.state, .working, "The sibling child is left in its own, unrelated state")
    }

    // MARK: - No children at all: identical to a hardcoded empty child store

    /// A pane whose CLI reports no children (pi, hermes, herdr) must
    /// produce a row list identical to the same entries fed a hardcoded
    /// empty child closure: same count, same order, every childCount
    /// zero, no `.child` rows. `AgentSidebarRows.Row` is not `Equatable`,
    /// so both lists are mapped to a comparable tuple shape before
    /// comparison.
    func test_noChildrenAtAll_rowListIdenticalToHardcodedEmptyChildStore() async throws {
        let surfaceA = UUID()
        let surfaceB = UUID()

        let sessionStartA = """
        {"session_id":"session-a","cwd":"/Users/dev/repo-a","hook_event_name":"SessionStart"}
        """
        let sessionStartB = """
        {"session_id":"session-b","cwd":"/Users/dev/repo-b","hook_event_name":"SessionStart"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sessionStartA, surfaceID: surfaceA), 0)
        XCTAssertEqual(try runHookScript(stdinJSON: sessionStartB, surfaceID: surfaceB), 0)
        _ = await waitForEntry(surfaceID: surfaceA)
        _ = await waitForEntry(surfaceID: surfaceB)
        XCTAssertEqual(registry.entries.count, 2, "Precondition: both rows exist, neither has ever been sent a child event")

        func fingerprint(_ row: AgentSidebarRows.Row) -> String {
            switch row {
            case .parent(let entry, let childCount, let isExpanded):
                return "parent:\(entry.surfaceID):\(childCount):\(isExpanded)"
            case .child(let child):
                return "child:\(child.id)"
            }
        }

        let expanded: Set<UUID> = [surfaceA, surfaceB]
        let realRows = AgentSidebarRows.build(
            entries: registry.sortedEntries,
            children: { registry.subagentRegistry.children(of: $0) },
            expanded: expanded
        )
        let hardcodedEmptyRows = AgentSidebarRows.build(
            entries: registry.sortedEntries,
            children: { _ in [] },
            expanded: expanded
        )

        XCTAssertEqual(realRows.count, 2, "No child was ever reported: two parent rows, no child rows")
        XCTAssertEqual(realRows.map(fingerprint), hardcodedEmptyRows.map(fingerprint),
                       "A pane a CLI never reports children for must render exactly as it did " +
                       "before this feature: identical to AgentSidebarRows.build fed an empty child store")
        for row in realRows {
            guard case .parent(_, let childCount, _) = row else {
                return XCTFail("No row may be a .child row when nothing ever reported a child")
            }
            XCTAssertEqual(childCount, 0)
        }
    }

    // MARK: - Force-quit: pane-exit settle sweeps children; a late child event creates nothing

    /// `handlePaneCommandFinished`'s pane-exit signal settles the row and
    /// sweeps every child of it (mirroring `AgentRegistry.apply`'s own
    /// `.write` case: `row.state == .done` triggers
    /// `subagentRegistry.handleSurfaceDestroyed`). A late child event
    /// delivered afterward, for the same now-`.done` surface, must create
    /// nothing: `AgentRegistry.handleHookEvent`'s own guard only tracks a
    /// child under a live (non-`.done`) row.
    func test_forceQuit_paneExitSweepsChildren_lateChildEventCreatesNothing() async throws {
        let surfaceID = UUID()
        let sessionID = "parent-session"
        let cwd = "/Users/dev/repo"

        let sessionStart = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SessionStart"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sessionStart, surfaceID: surfaceID), 0)
        _ = await waitForEntry(surfaceID: surfaceID)

        func subagentStart(_ agentID: String) -> String {
            """
            {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStart",\
            "agent_id":"\(agentID)","agent_type":"Explore"}
            """
        }
        XCTAssertEqual(try runHookScript(stdinJSON: subagentStart("agent-x"), surfaceID: surfaceID), 0)
        XCTAssertEqual(try runHookScript(stdinJSON: subagentStart("agent-y"), surfaceID: surfaceID), 0)
        let childrenBeforeQuit = await waitForChildren(of: surfaceID) { $0.count == 2 }
        XCTAssertEqual(childrenBeforeQuit?.count, 2, "Precondition: two children showing before the force-quit")

        let didSettle = registry.handlePaneCommandFinished(surfaceID: surfaceID)

        XCTAssertTrue(didSettle, "The pane-exit signal must settle the row")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done)
        XCTAssertTrue(registry.subagentRegistry.children(of: surfaceID).isEmpty,
                      "No child may outlive the row it belonged to")

        // Sanity barrier: a live-parent+child flow on a second surface,
        // proving the pipeline is up and would have delivered the late
        // event below had the .done guard not dropped it.
        let sanitySurfaceID = UUID()
        let sanitySessionStart = """
        {"session_id":"sanity-session","cwd":"\(cwd)","hook_event_name":"SessionStart"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sanitySessionStart, surfaceID: sanitySurfaceID), 0)
        _ = await waitForEntry(surfaceID: sanitySurfaceID)
        let sanitySubagentStart = """
        {"session_id":"sanity-session","cwd":"\(cwd)","hook_event_name":"SubagentStart",\
        "agent_id":"sanity-agent","agent_type":"Explore"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sanitySubagentStart, surfaceID: sanitySurfaceID), 0)
        let sanityChildren = await waitForChildren(of: sanitySurfaceID) { $0.count == 1 }
        XCTAssertEqual(sanityChildren?.count, 1,
                       "Precondition: the pipeline is up and does deliver a child event when a live row exists")

        // Late child event for the now-.done surface.
        let lateSubagentStart = subagentStart("agent-late")
        XCTAssertEqual(try runHookScript(stdinJSON: lateSubagentStart, surfaceID: surfaceID), 0)

        let lateChild = await waitForChildren(of: surfaceID, timeout: 0.5) { !$0.isEmpty }
        XCTAssertNil(lateChild, "A child is only ever tracked under a live row: a late event for a .done surface creates nothing")
        XCTAssertEqual(registry.entries[surfaceID]?.state, .done, "The already-settled row must not be revived")
    }

    // MARK: - Codex: a session-mismatched parent-scoped SessionEnd must not clear a live child; neither must an accepted Stop

    /// Codex's `agent_id` field is present ONLY on `SubagentStart` /
    /// `SubagentStop` -- see `AgentEvent.agentID`'s own doc comment.
    /// Every other Codex hook event, `Stop` and `SessionEnd` included,
    /// carries no `agent_id` at all, so `AgentRegistry.handleHookEvent`
    /// forwards it to no child at all: only a subagent-scoped event
    /// ever reaches `SubagentRegistry.handleHookEvent`, and whether a
    /// non-subagent `SessionEnd` retires the surface's children is
    /// decided entirely by `AgentStateResolver.resolveHook`
    /// (`AgentResolution.retiresChildren`), gated on that same event
    /// having been accepted for the parent row.
    ///
    /// A `SessionEnd` for a DIFFERENT session than the row's own is
    /// exactly the case `AgentStateResolver.resolveHookRow`'s
    /// session-mismatch guard rejects for a non-`.done` row (`SessionEnd`
    /// is absent from `forwardMovingEventNames`): the parent row must
    /// stay untouched, and so must the child underneath it. Because
    /// Codex's own subsequent `SubagentStop` is the only event that
    /// could ever clear this child, and it carries the SAME `agent_id`
    /// this test's `SubagentStart` reported, the child must keep
    /// lingering for the rest of the run rather than be wiped out from
    /// under a row the resolver never touched.
    func test_codex_rejectedMismatchedSessionSessionEnd_doesNotClearLiveChild() async throws {
        let surfaceID = UUID()
        let sessionID = "codex-parent-session"
        let otherSessionID = "codex-other-session"
        let cwd = "/Users/dev/codex-repo"
        let agentID = "codex-sub-1"

        let sessionStartStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SessionStart"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sessionStartStdin, surfaceID: surfaceID, kindArgument: "codex"), 0)
        let parentBefore = await waitForEntry(surfaceID: surfaceID)
        XCTAssertEqual(parentBefore?.state, .idle, "Precondition: SessionStart registers the row as idle")
        XCTAssertEqual(parentBefore?.sessionID, sessionID)

        // Codex's real SubagentStart shape: agent_id and agent_type
        // present, no tool_name.
        let subagentStartStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStart",\
        "agent_id":"\(agentID)","agent_type":"general-purpose"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: subagentStartStdin, surfaceID: surfaceID, kindArgument: "codex"), 0)
        let childrenAfterStart = await waitForChildren(of: surfaceID) { $0.count == 1 }
        XCTAssertEqual(childrenAfterStart?.count, 1, "Precondition: the real SubagentStart POST creates the child")

        // Codex's real SessionEnd shape: session_id and hook_event_name
        // only, no agent_id -- for a session that does NOT match the
        // row's own.
        let mismatchedSessionEndStdin = """
        {"session_id":"\(otherSessionID)","cwd":"\(cwd)","hook_event_name":"SessionEnd"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: mismatchedSessionEndStdin, surfaceID: surfaceID, kindArgument: "codex"), 0)

        // Give the real network round-trip a moment to land, the same
        // way the rest of this file's helpers do, then assert against
        // the live, settled state rather than the polling helper's own
        // return value -- this call is expected to resolve to an empty
        // array if the defect is present, so racing to catch it "in the
        // middle" would only make this test flaky.
        _ = await waitForChildren(of: surfaceID, timeout: 2.0) { $0.isEmpty }

        let parentAfter = registry.entries[surfaceID]
        XCTAssertEqual(parentAfter?.sessionID, sessionID,
                       "Precondition: the resolver must actually reject the mismatched SessionEnd, leaving " +
                       "the parent row's own sessionID untouched -- otherwise this test proves nothing " +
                       "about the rejected case")
        XCTAssertEqual(parentAfter?.state, .idle, "Precondition: the mismatched SessionEnd must not change the row's state")

        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "A session-mismatched SessionEnd AgentStateResolver rejected for the parent row " +
                       "must not clear the child a real Codex SubagentStart reported -- Codex never " +
                       "re-sends agent_id on Stop/SessionEnd, so nothing else will ever recreate this " +
                       "child once it is wiped out from under a row the resolver left alone")
    }

    /// The plain fact, separate from the rejected case above: an
    /// ACCEPTED, same-session `Stop` no longer clears a live child
    /// either -- the parent row still settles to `.idle`, but the child
    /// Codex's own `SubagentStart` reported keeps lingering until its
    /// own `SubagentStop`, `SessionEnd`, `SessionStart`, or the pane
    /// itself exits.
    func test_codex_acceptedSameSessionStop_doesNotClearLiveChild() async throws {
        let surfaceID = UUID()
        let sessionID = "codex-parent-session-stop"
        let cwd = "/Users/dev/codex-repo"
        let agentID = "codex-sub-2"

        let sessionStartStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SessionStart"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sessionStartStdin, surfaceID: surfaceID, kindArgument: "codex"), 0)
        let afterSessionStart = await waitForEntry(surfaceID: surfaceID)
        XCTAssertEqual(afterSessionStart?.state, .idle, "Precondition: SessionStart registers the row as idle")
        let sessionStartLastEventAt = try XCTUnwrap(afterSessionStart?.lastEventAt)

        let subagentStartStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"SubagentStart",\
        "agent_id":"\(agentID)","agent_type":"general-purpose"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: subagentStartStdin, surfaceID: surfaceID, kindArgument: "codex"), 0)
        let childrenAfterStart = await waitForChildren(of: surfaceID) { $0.count == 1 }
        XCTAssertEqual(childrenAfterStart?.count, 1, "Precondition: the real SubagentStart POST creates the child")

        // Codex's real Stop shape: session_id and hook_event_name only,
        // no agent_id -- for the SAME session as the row's own, so
        // AgentStateResolver accepts it and settles the row.
        let sameSessionStopStdin = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"Stop"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: sameSessionStopStdin, surfaceID: surfaceID, kindArgument: "codex"), 0)

        // The row is already .idle from SessionStart, so a predicate
        // matching `state == .idle` alone would trivially match BEFORE
        // the Stop POST even lands -- wait for lastEventAt to actually
        // advance past SessionStart's own timestamp instead, the same
        // pattern AgentHookPipelineIntegrationTests uses for this exact
        // reason.
        let parentAfterStop = await waitForEntry(surfaceID: surfaceID) { $0.lastEventAt > sessionStartLastEventAt }
        XCTAssertNotNil(parentAfterStop, "Precondition: the Stop POST must actually land and advance lastEventAt")
        XCTAssertEqual(parentAfterStop?.state, .idle, "Precondition: the accepted, same-session Stop settles the row")

        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 1,
                       "An accepted, same-session Stop must no longer clear the child a real Codex " +
                       "SubagentStart reported")
    }

    // MARK: - The real captured Claude Code sequence: children never drop across the parent's own Stop

    /// Replays the exact captured Claude Code hook sequence this bug was
    /// found from: two `SubagentStart`s, a parent-scoped `Stop` fired
    /// while BOTH children are still mid-flight, then each child's own
    /// `PostToolUse` followed by its own `SubagentStop`. Asserts on
    /// `AgentSidebarRows.build`'s own output at every step that the two
    /// child rows never disappear -- in particular across the parent's
    /// own `Stop` -- and that each retires only on its own `SubagentStop`.
    func test_claudeCode_capturedSequence_childrenSurviveParentStop_retireOnlyOnOwnSubagentStop() async throws {
        let surfaceID = UUID()
        let sessionID = "parent-session"
        let cwd = "/Users/dev/repo"
        let agentID1 = "ad6adb00000000000000000000000000"
        let agentID2 = "ae0d2000000000000000000000000000"

        func hook(_ name: String, agentID: String? = nil, toolName: String? = nil) -> String {
            var fields = ["\"session_id\":\"\(sessionID)\"", "\"cwd\":\"\(cwd)\"", "\"hook_event_name\":\"\(name)\""]
            if let agentID { fields.append("\"agent_id\":\"\(agentID)\"") }
            if let toolName { fields.append("\"tool_name\":\"\(toolName)\"") }
            return "{\(fields.joined(separator: ","))}"
        }

        // A child is only ever tracked under a live parent row -- register
        // one first, mirroring the real capture's own PreToolUse(Agent)
        // that precedes the first SubagentStart.
        XCTAssertEqual(try runHookScript(stdinJSON: hook("PreToolUse", toolName: "Agent"), surfaceID: surfaceID), 0)
        _ = await waitForEntry(surfaceID: surfaceID)

        // SubagentStart for both children.
        XCTAssertEqual(try runHookScript(stdinJSON: hook("SubagentStart", agentID: agentID1), surfaceID: surfaceID), 0)
        XCTAssertEqual(try runHookScript(stdinJSON: hook("SubagentStart", agentID: agentID2), surfaceID: surfaceID), 0)
        let childrenAfterBothStarts = await waitForChildren(of: surfaceID) { $0.count == 2 }
        XCTAssertEqual(childrenAfterBothStarts?.count, 2, "Precondition: both children exist before the parent's own Stop")

        // PreToolUse inside child 1, then the parent-scoped Stop while
        // both children are still mid-flight -- the exact ordering the
        // real capture showed (21:38:29 SubagentStart child1, 21:38:31
        // PreToolUse child1, 21:38:32 parent Stop with both children
        // still running).
        XCTAssertEqual(try runHookScript(stdinJSON: hook("PreToolUse", agentID: agentID1, toolName: "Bash"), surfaceID: surfaceID), 0)
        _ = await waitForChildren(of: surfaceID) { $0.first { $0.agentID == agentID1 }?.lastToolName == "Bash" }

        XCTAssertEqual(try runHookScript(stdinJSON: hook("Stop"), surfaceID: surfaceID), 0)
        let parentAfterStop = await waitForEntry(surfaceID: surfaceID) { $0.state == .idle }
        XCTAssertEqual(parentAfterStop?.state, .idle, "Precondition: the parent's own Stop settled the row to .idle")

        let rowsAfterParentStop = rows(expanded: [surfaceID])
        let childRowsAfterParentStop = rowsAfterParentStop.compactMap { row -> SubagentEntry? in
            if case .child(let child) = row { return child }
            return nil
        }
        XCTAssertEqual(childRowsAfterParentStop.count, 2,
                       "The two child rows must NOT disappear across the parent's own Stop -- the CLI " +
                       "itself still reports them running past its own turn ending")

        // Both children keep progressing after the parent's Stop.
        XCTAssertEqual(try runHookScript(stdinJSON: hook("PreToolUse", agentID: agentID2, toolName: "Bash"), surfaceID: surfaceID), 0)
        _ = await waitForChildren(of: surfaceID) { $0.first { $0.agentID == agentID2 }?.lastToolName == "Bash" }
        XCTAssertEqual(registry.subagentRegistry.children(of: surfaceID).count, 2,
                       "Both children must still be present while progressing after the parent's own Stop")

        XCTAssertEqual(try runHookScript(stdinJSON: hook("PostToolUse", agentID: agentID1, toolName: "Read"), surfaceID: surfaceID), 0)
        XCTAssertEqual(try runHookScript(stdinJSON: hook("PostToolUse", agentID: agentID2, toolName: "Read"), surfaceID: surfaceID), 0)
        let childrenAfterBothPostToolUse = await waitForChildren(of: surfaceID) {
            $0.allSatisfy { $0.lastToolName == "Read" }
        }
        XCTAssertEqual(childrenAfterBothPostToolUse?.count, 2,
                       "PostToolUse for both children must not retire either one")

        // Each child retires only on its own SubagentStop.
        XCTAssertEqual(try runHookScript(stdinJSON: hook("SubagentStop", agentID: agentID1), surfaceID: surfaceID), 0)
        let childrenAfterFirstStop = await waitForChildren(of: surfaceID) { $0.count == 1 }
        XCTAssertEqual(childrenAfterFirstStop?.map(\.agentID), [agentID2],
                       "Only agentID1's own SubagentStop retires it -- agentID2 must remain")

        XCTAssertEqual(try runHookScript(stdinJSON: hook("SubagentStop", agentID: agentID2), surfaceID: surfaceID), 0)
        let childrenAfterSecondStop = await waitForChildren(of: surfaceID) { $0.isEmpty }
        XCTAssertEqual(childrenAfterSecondStop?.isEmpty, true, "agentID2's own SubagentStop retires the last child")

        let finalRows = rows(expanded: [surfaceID])
        XCTAssertEqual(finalRows.count, 1, "Back to one parent row with no child rows")
    }

    // MARK: - Claude Code: a child-scoped tool call's own tool_input

    /// A child-scoped `PreToolUse` carrying `tool_input.command` must
    /// reach the rendered child row as `lastToolSummary`, so the sidebar
    /// shows the command rather than the bare tool name. The parent's
    /// own `Agent` `PreToolUse` runs first because a child is only ever
    /// tracked under a live parent row.
    func test_claudeCode_childScopedPreToolUseWithToolInput_childRowCarriesTheCommand() async throws {
        let surfaceID = UUID()
        let sessionID = "parent-session"
        let cwd = "/Users/dev/repo"
        let agentID = "a5bfac2e378042079"
        let command = "git status --short"

        let parentEvent = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"PreToolUse","tool_name":"Agent"}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: parentEvent, surfaceID: surfaceID), 0)
        let parentEntry = await waitForEntry(surfaceID: surfaceID)
        XCTAssertEqual(parentEntry?.state, .working, "Precondition: the parent's own Agent PreToolUse creates the row")

        let event = """
        {"session_id":"\(sessionID)","cwd":"\(cwd)","hook_event_name":"PreToolUse",\
        "agent_id":"\(agentID)","agent_type":"Explore","tool_name":"Bash",\
        "tool_input":{"command":"\(command)"}}
        """
        XCTAssertEqual(try runHookScript(stdinJSON: event, surfaceID: surfaceID), 0)

        let children = await waitForChildren(of: surfaceID) { $0.first?.lastToolSummary == command }
        XCTAssertEqual(children?.count, 1)

        let rendered = rows(expanded: [surfaceID])
        XCTAssertEqual(rendered.count, 2, "The parent row plus its one child row")
        guard case .child(let child) = rendered[safe: 1] else {
            return XCTFail("Row 1 must be the child row")
        }
        XCTAssertEqual(child.agentID, agentID)
        XCTAssertEqual(child.lastToolName, "Bash")
        XCTAssertEqual(child.lastToolSummary, command,
                       "The command travels the whole path: hook script stdin, POST /agent-event, " +
                       "AgentEvent.decode, SubagentRegistry, AgentSidebarRows.build")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
