//
//  ApprovalRequestDisplayTests.swift
//  CalyxTests
//
//  TDD Red Phase for ApprovalRequest's display helpers
//  (displayToolName / displayPayload): the single place both the MCP-tool
//  and agent-hook approval sources reduce down to the two strings
//  ApprovalBannerView renders, so the view itself no longer needs to
//  switch over ApprovalRequest.Source.
//
//  Coverage:
//  - .mcpTool: displayToolName is the tool's name; displayPayload is
//    ApprovalRequest.payload, unchanged
//  - .agentHook: displayToolName combines the owning CLI's display label
//    (AgentEntry.displayName(forKind:)) with the tool name;
//    displayPayload is the source's own summary, NOT
//    ApprovalRequest.payload
//  - both helpers return RAW strings -- hostile control/bidi characters
//    in an agent-hook summary must survive unescaped, since escaping for
//    display is ControlCharacterDisplay's job, done later in the view
//

import XCTest
@testable import Calyx

final class ApprovalRequestDisplayTests: XCTestCase {

    // MARK: - Helpers

    private func makeRequest(source: ApprovalRequest.Source, payload: String = "payload") -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: source, targetSurfaceID: nil, payload: payload, createdAt: Date())
    }

    // MARK: - .mcpTool

    func test_displayToolName_mcpTool_isName() {
        let request = makeRequest(source: .mcpTool(name: "pane_run"))

        XCTAssertEqual(request.displayToolName, "pane_run")
    }

    func test_displayPayload_mcpTool_isPayload() {
        let request = makeRequest(source: .mcpTool(name: "pane_run"), payload: "ls -la /tmp")

        XCTAssertEqual(request.displayPayload, "ls -la /tmp")
    }

    // MARK: - .agentHook

    func test_displayToolName_agentHook_combinesAgentLabelAndTool() {
        let claudeRequest = makeRequest(
            source: .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: "ls -la")
        )
        XCTAssertEqual(claudeRequest.displayToolName, "Claude Code · Bash")

        let codexRequest = makeRequest(
            source: .agentHook(toolName: "Write", kind: AgentEntry.codexKind, summary: "/tmp/x.swift")
        )
        XCTAssertEqual(codexRequest.displayToolName, "Codex · Write")
    }

    func test_displayPayload_agentHook_isSummary() {
        let request = makeRequest(
            source: .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: "ls -la /tmp"),
            payload: "{\"command\":\"ls -la /tmp\"}"
        )

        XCTAssertEqual(request.displayPayload, "ls -la /tmp",
                       "displayPayload for .agentHook must be the source's summary, not ApprovalRequest.payload")
    }

    func test_displayPayload_agentHook_hostileControlCharacters_passThroughRaw() {
        let hostileSummary = "\u{202E}rm -rf /\u{0003}"
        let request = makeRequest(
            source: .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: hostileSummary)
        )

        XCTAssertEqual(request.displayPayload, hostileSummary,
                       "displayPayload must return the raw summary unescaped -- escaping for display is " +
                       "ControlCharacterDisplay's job, applied later in the view layer")
    }
}
