//
//  ApprovalRequestDisplayTests.swift
//  CalyxTests
//
//  Covers ApprovalRequest's display helpers
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
//  - .mcpApp: displayToolName is "<title> · Open Link"/"Send Message"/
//    "Copy Message" depending on MCPAppConsentKind; displayPayload is the
//    URL string / the (already newline-folded) preview / a fixed
//    "the app wants to send a message, but this window has no pane"
//    sentence for copyMessage; prefersWideApprovalPanel is always false;
//    isDismissible is always true
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
            source: .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: "ls -la", offers: .none)
        )
        XCTAssertEqual(claudeRequest.displayToolName, "Claude Code · Bash")

        let codexRequest = makeRequest(
            source: .agentHook(toolName: "Write", kind: AgentEntry.codexKind, summary: "/tmp/x.swift", offers: .none)
        )
        XCTAssertEqual(codexRequest.displayToolName, "Codex · Write")
    }

    func test_displayPayload_agentHook_isSummary() {
        let request = makeRequest(
            source: .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: "ls -la /tmp", offers: .none),
            payload: "{\"command\":\"ls -la /tmp\"}"
        )

        XCTAssertEqual(request.displayPayload, "ls -la /tmp",
                       "displayPayload for .agentHook must be the source's summary, not ApprovalRequest.payload")
    }

    func test_displayPayload_agentHook_hostileControlCharacters_passThroughRaw() {
        let hostileSummary = "\u{202E}rm -rf /\u{0003}"
        let request = makeRequest(
            source: .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: hostileSummary, offers: .none)
        )

        XCTAssertEqual(request.displayPayload, hostileSummary,
                       "displayPayload must return the raw summary unescaped -- escaping for display is " +
                       "ControlCharacterDisplay's job, applied later in the view layer")
    }

    // MARK: - .agentQuestion

    private func makePrompt(questionTexts: [String]) -> AgentQuestionPrompt {
        let toolInput: [String: Any] = [
            "questions": questionTexts.map { text in
                ["question": text, "options": [["label": "yes"], ["label": "no"]]]
            },
        ]
        return AgentQuestionPrompt(
            questions: questionTexts.map { text in
                AgentQuestionPrompt.Question(
                    text: text, header: nil,
                    options: [
                        AgentQuestionPrompt.Option(label: "yes", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "no", description: nil, preview: nil),
                    ],
                    multiSelect: false
                )
            },
            originalToolInputJSON: try! JSONSerialization.data(withJSONObject: toolInput)
        )
    }

    func test_displayToolName_agentQuestion_combinesAgentLabelAndQuestionSuffix() {
        let prompt = makePrompt(questionTexts: ["Which shell?"])
        let request = makeRequest(
            source: .agentQuestion(kind: AgentEntry.claudeCodeKind, prompt: prompt)
        )

        XCTAssertEqual(request.displayToolName, "Claude Code · Question",
                       "displayToolName for .agentQuestion must combine the owning CLI's display label " +
                       "with the same middle-dot separator .agentHook uses")
    }

    func test_displayPayload_agentQuestion_isQuestionTextsJoinedByNewline() {
        let prompt = makePrompt(questionTexts: ["Which shell?", "Which editor?"])
        let request = makeRequest(
            source: .agentQuestion(kind: AgentEntry.claudeCodeKind, prompt: prompt)
        )

        XCTAssertEqual(request.displayPayload, "Which shell?\nWhich editor?",
                       "displayPayload for .agentQuestion must join every question's text with a newline")
    }

    func test_previewLine_agentQuestion_multiQuestion_isSingleLineAndTruncatesSameAsOtherSources() {
        let prompt = makePrompt(questionTexts: ["Which shell?", "Which editor?", "Any last preferences?"])
        let request = makeRequest(
            source: .agentQuestion(kind: AgentEntry.claudeCodeKind, prompt: prompt)
        )

        XCTAssertEqual(request.previewLine, "Claude Code · Question: Which shell? Which editor? Any last preferences?",
                       "previewLine must collapse the newline-joined displayPayload into a single space-separated line, " +
                       "the same whitespace-collapsing behavior every other source's previewLine already exercises")
        XCTAssertFalse(request.previewLine.contains("\n"), "previewLine must be single-line")
    }

    // MARK: - prefersWideApprovalPanel

    /// One question per case, covering every combination of
    /// `multiSelect`/option-preview that decides
    /// `AgentQuestionPrompt.Question.wantsInlineOptionList`, and in turn
    /// `ApprovalRequest.prefersWideApprovalPanel`.
    private func makeQuestion(options: [AgentQuestionPrompt.Option], multiSelect: Bool) -> AgentQuestionPrompt.Question {
        AgentQuestionPrompt.Question(text: "Which?", header: nil, options: options, multiSelect: multiSelect)
    }

    private func makeQuestionRequest(questions: [AgentQuestionPrompt.Question]) -> ApprovalRequest {
        let prompt = AgentQuestionPrompt(questions: questions, originalToolInputJSON: Data())
        return makeRequest(source: .agentQuestion(kind: AgentEntry.claudeCodeKind, prompt: prompt))
    }

    func test_prefersWideApprovalPanel_mcpTool_isFalse() {
        let request = makeRequest(source: .mcpTool(name: "pane_run"))

        XCTAssertFalse(request.prefersWideApprovalPanel)
    }

    func test_prefersWideApprovalPanel_agentHook_isFalse() {
        let request = makeRequest(
            source: .agentHook(toolName: "Bash", kind: AgentEntry.claudeCodeKind, summary: "ls", offers: .none)
        )

        XCTAssertFalse(request.prefersWideApprovalPanel)
    }

    func test_prefersWideApprovalPanel_singleSelectNoPreview_isFalse() {
        let question = makeQuestion(
            options: [
                AgentQuestionPrompt.Option(label: "yes", description: nil, preview: nil),
                AgentQuestionPrompt.Option(label: "no", description: nil, preview: nil),
            ],
            multiSelect: false
        )
        let request = makeQuestionRequest(questions: [question])

        XCTAssertFalse(request.prefersWideApprovalPanel)
    }

    func test_prefersWideApprovalPanel_anyOptionCarriesPreview_isTrue() {
        let question = makeQuestion(
            options: [
                AgentQuestionPrompt.Option(label: "yes", description: nil, preview: nil),
                AgentQuestionPrompt.Option(label: "no", description: nil, preview: "```diff\n+x\n```"),
            ],
            multiSelect: false
        )
        let request = makeQuestionRequest(questions: [question])

        XCTAssertTrue(request.prefersWideApprovalPanel)
    }

    func test_prefersWideApprovalPanel_multiSelectWithOptions_isTrue() {
        let question = makeQuestion(
            options: [
                AgentQuestionPrompt.Option(label: "yes", description: nil, preview: nil),
                AgentQuestionPrompt.Option(label: "no", description: nil, preview: nil),
            ],
            multiSelect: true
        )
        let request = makeQuestionRequest(questions: [question])

        XCTAssertTrue(request.prefersWideApprovalPanel)
    }

    func test_prefersWideApprovalPanel_zeroOptionMultiSelect_isFalse() {
        let question = makeQuestion(options: [], multiSelect: true)
        let request = makeQuestionRequest(questions: [question])

        XCTAssertFalse(request.prefersWideApprovalPanel,
                       "a zero-option question has nothing to list inline regardless of multiSelect")
    }

    // MARK: - .mcpApp
    //
    // title is what MCPAppWebViewRuntime resolves as the invocation's
    // serverDisplayName (or the snapshot's own title when there is
    // none) -- an opaque string as far as ApprovalRequest itself is
    // concerned, so these fixtures just pick "Notion".

    func test_displayToolName_mcpApp_openLink_isTitleAndOpenLink() {
        let url = URL(string: "https://example.com/doc")!
        let request = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .openLink(url)))

        XCTAssertEqual(request.displayToolName, "Notion · Open Link")
    }

    func test_displayToolName_mcpApp_sendMessage_isTitleAndSendMessage() {
        let request = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .sendMessage(preview: "hello")))

        XCTAssertEqual(request.displayToolName, "Notion · Send Message")
    }

    func test_displayToolName_mcpApp_copyMessage_isTitleAndCopyMessage() {
        let request = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .copyMessage(text: "hello")))

        XCTAssertEqual(request.displayToolName, "Notion · Copy Message")
    }

    func test_displayPayload_mcpApp_openLink_isTheURLString() {
        let url = URL(string: "https://example.com/doc?x=1&y=2")!
        let request = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .openLink(url)))

        XCTAssertEqual(request.displayPayload, url.absoluteString)
    }

    func test_displayPayload_mcpApp_sendMessage_isThePreviewVerbatim() {
        let request = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .sendMessage(preview: "already folded to one line")))

        XCTAssertEqual(request.displayPayload, "already folded to one line",
                       "displayPayload for .sendMessage is the (already newline-folded) preview, unchanged")
    }

    func test_displayPayload_mcpApp_copyMessage_explainsThereIsNoPaneAndCarriesTheText() {
        let request = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .copyMessage(text: "hello there")))

        XCTAssertEqual(
            request.displayPayload,
            "The app wants to send a message, but this window has no pane. Copy it instead: hello there"
        )
    }

    func test_prefersWideApprovalPanel_mcpApp_isAlwaysFalse() {
        let openLink = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .openLink(URL(string: "https://example.com")!)))
        let sendMessage = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .sendMessage(preview: "hi")))
        let copyMessage = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .copyMessage(text: "hi")))

        XCTAssertFalse(openLink.prefersWideApprovalPanel)
        XCTAssertFalse(sendMessage.prefersWideApprovalPanel)
        XCTAssertFalse(copyMessage.prefersWideApprovalPanel)
    }

    func test_isDismissible_mcpApp_isAlwaysTrue() {
        let openLink = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .openLink(URL(string: "https://example.com")!)))
        let sendMessage = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .sendMessage(preview: "hi")))
        let copyMessage = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .copyMessage(text: "hi")))

        XCTAssertTrue(openLink.isDismissible)
        XCTAssertTrue(sendMessage.isDismissible)
        XCTAssertTrue(copyMessage.isDismissible)
    }

    func test_previewLine_mcpApp_combinesDisplayToolNameAndCompactedPayload() {
        let url = URL(string: "https://example.com/doc")!
        let request = makeRequest(source: .mcpApp(viewID: UUID(), title: "Notion", kind: .openLink(url)))

        XCTAssertEqual(request.previewLine, "Notion · Open Link: https://example.com/doc")
    }

    // MARK: - isDismissible
    //
    // .mcpTool: always dismissible -- the calling MCP agent gets a valid
    // {"status": "dismissed"} either way (MCPCockpitBridge.gate).
    // .agentHook/.agentQuestion: dismissible only for claude-code/codex,
    // whose PermissionRequest hook has a "no output" fallback to lean on
    // (same as .expired); grok/pi have no such fallback -- Calyx's gate
    // is their only prompt -- so neither is ever dismissible.

    private func makeQuestionRequest(kind: String) -> ApprovalRequest {
        let question = makeQuestion(
            options: [AgentQuestionPrompt.Option(label: "yes", description: nil, preview: nil)],
            multiSelect: false
        )
        let prompt = AgentQuestionPrompt(questions: [question], originalToolInputJSON: Data())
        return makeRequest(source: .agentQuestion(kind: kind, prompt: prompt))
    }

    func test_isDismissible_mcpTool_isAlwaysTrue() {
        let request = makeRequest(source: .mcpTool(name: "pane_run"))

        XCTAssertTrue(request.isDismissible)
    }

    func test_isDismissible_agentHook_trueOnlyForClaudeCodeAndCodex() {
        for kind in [AgentEntry.claudeCodeKind, AgentEntry.codexKind] {
            let request = makeRequest(source: .agentHook(toolName: "Bash", kind: kind, summary: "ls", offers: .none))
            XCTAssertTrue(request.isDismissible, "kind=\(kind)")
        }
        for kind in [AgentEntry.grokKind, AgentEntry.piKind] {
            let request = makeRequest(source: .agentHook(toolName: "Bash", kind: kind, summary: "ls", offers: .none))
            XCTAssertFalse(request.isDismissible, "kind=\(kind)")
        }
    }

    func test_isDismissible_agentQuestion_trueOnlyForClaudeCodeAndCodex() {
        for kind in [AgentEntry.claudeCodeKind, AgentEntry.codexKind] {
            XCTAssertTrue(makeQuestionRequest(kind: kind).isDismissible, "kind=\(kind)")
        }
        for kind in [AgentEntry.grokKind, AgentEntry.piKind] {
            XCTAssertFalse(makeQuestionRequest(kind: kind).isDismissible, "kind=\(kind)")
        }
    }
}
