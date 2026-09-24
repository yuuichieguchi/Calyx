//
//  AgentHookPermissionResponseTests.swift
//  CalyxTests
//
//  Covers AgentHookPermissionResponse.body(kind:decision:):
//  the PermissionRequest hook stdout body Calyx writes back to a CLI
//  agent to carry a human's approval decision into that CLI's own
//  synchronous permission gate -- shape and field names follow the
//  PermissionRequest hook-response contract both Claude Code and Codex
//  document (hookSpecificOutput.decision.behavior), replacing the older
//  PreToolUse-era hookSpecificOutput.permissionDecision shape entirely.
//
//  Coverage:
//  - claude-code / codex: allowed produces decision.behavior "allow";
//    denied produces decision.behavior "deny" with a non-empty message,
//    claude-code selecting the message from the DenyReason, codex always
//    using deniedMessage regardless of reason
//  - claude-code / codex: expired produces nil for both kinds
//  - claude-code: allowedWithPermissions echoes the offer's entryJSON as
//    the sole element of updatedPermissions; interrupted produces a deny
//    body with interrupt: true and a reason-specific message
//  - grok / pi: flat top-level decision vocabulary; allowedWithPermissions/
//    interrupted/answered are unexpressible and produce a body
//    byte-identical to expired for that kind; codex produces nil for the
//    same three, same as expired
//  - any kind other than claude-code/codex/grok/pi produces nil for
//    every decision
//  - the body never carries any of PermissionRequest's reserved/invalid
//    fields, pinned via an exact key-set assertion
//  - claude-code's .answered body: behavior "allow" plus updatedInput
//    (the original tool_input object plus answers, plus annotations
//    when a question's entry carries notes or a selected preview)
//
//  Bodies are re-parsed with JSONSerialization and asserted field by
//  field -- never by string equality, since key order in the serialized
//  JSON is unspecified.
//

import XCTest
@testable import Calyx

final class AgentHookPermissionResponseTests: XCTestCase {

    // MARK: - Helpers

    private func hookSpecificOutput(_ data: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["hookSpecificOutput"] as? [String: Any])
    }

    private func decisionObject(_ data: Data) throws -> [String: Any] {
        let output = try hookSpecificOutput(data)
        return try XCTUnwrap(output["decision"] as? [String: Any])
    }

    /// Strict JSON-boolean check: `JSONSerialization` bridges a JSON
    /// number to `NSNumber` too, so a plain `as? Bool` cast would also
    /// accept `1`. Mirrors `AgentHookToolCall.strictJSONBool`'s own
    /// `CFGetTypeID` check, computed independently here.
    private func isJSONBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func assertPermissionDecision(
        kind: String,
        decision: ApprovalDecision,
        expectedBehavior: String,
        expectedMessage: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: kind, decision: decision),
            file: file, line: line
        )
        let output = try hookSpecificOutput(data)
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest", file: file, line: line)

        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(decisionObject["behavior"] as? String, expectedBehavior, file: file, line: line)

        if let expectedMessage {
            XCTAssertEqual(decisionObject["message"] as? String, expectedMessage, file: file, line: line)
        }
    }

    // MARK: - claude-code: allowed / denied / expired

    func test_body_claude_allowed_isAllowBehavior() throws {
        try assertPermissionDecision(
            kind: AgentEntry.claudeCodeKind, decision: .allowed, expectedBehavior: "allow", expectedMessage: nil
        )
    }

    func test_body_claude_denied_userRejected_isDenyBehaviorWithClaudeCodeRejectedMessage() throws {
        try assertPermissionDecision(
            kind: AgentEntry.claudeCodeKind, decision: .denied(.userRejected), expectedBehavior: "deny",
            expectedMessage: AgentHookPermissionResponse.claudeCodeRejectedMessage
        )
    }

    func test_body_claude_expired_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .expired),
                    "PermissionRequest has no fallback body for an expired decision -- no output lets " +
                    "Claude Code's own confirmation prompt take over")
    }

    func test_body_claude_dismissed_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .dismissed),
                    "Claude Code's PermissionRequest hook has no vocabulary for \"Calyx does not answer this\" -- " +
                    "a dismissed request must produce no body, exactly like .expired")
    }

    // MARK: - codex: allowed / denied (any reason) / expired

    func test_body_codex_allowed_isAllowBehavior() throws {
        try assertPermissionDecision(
            kind: AgentEntry.codexKind, decision: .allowed, expectedBehavior: "allow", expectedMessage: nil
        )
    }

    func test_body_codex_denied_anyReason_alwaysUsesDeniedMessage() throws {
        try assertPermissionDecision(
            kind: AgentEntry.codexKind, decision: .denied(.userRejected), expectedBehavior: "deny",
            expectedMessage: AgentHookPermissionResponse.deniedMessage
        )
    }

    func test_body_codex_expired_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.codexKind, decision: .expired),
                    "Codex has no fallback body for an expired decision either")
    }

    func test_body_codex_dismissed_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.codexKind, decision: .dismissed),
                    "Codex has no vocabulary for a dismissed request either -- must produce no body, same as .expired")
    }

    // MARK: - claude-code: allowedWithPermissions

    private func makeOffer(entry: [String: Any], label: String) -> AgentPermissionOffer {
        AgentPermissionOffer(label: label, entryJSON: try! JSONSerialization.data(withJSONObject: entry))
    }

    func test_body_claude_allowedWithPermissions_echoesEntryAsSoleUpdatedPermissionsElement() throws {
        let entry: [String: Any] = ["type": "addDirectories", "directories": ["/tmp"], "destination": "session"]
        let offer = makeOffer(entry: entry, label: "Yes, and always allow access to /tmp for this session")

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .allowedWithPermissions(offer))
        )
        let decision = try decisionObject(data)
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual(Set(decision.keys), ["behavior", "updatedPermissions"])

        let updatedPermissions = try XCTUnwrap(decision["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(updatedPermissions.count, 1, "updatedPermissions must contain exactly the one echoed entry")
        XCTAssertEqual(updatedPermissions[0] as NSDictionary, entry as NSDictionary,
                       "the echoed entry must equal the offer's own entryJSON, unknown keys included")
    }

    func test_body_codex_allowedWithPermissions_isNil() {
        let offer = makeOffer(entry: ["type": "addDirectories", "directories": ["/tmp"]], label: "x")
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.codexKind, decision: .allowedWithPermissions(offer)),
                    "codex fails closed on updatedPermissions, same as .expired")
    }

    // MARK: - claude-code: interrupted

    func test_body_claude_interrupted_chatAboutQuestion_isDenyWithChatAboutQuestionMessageAndInterruptTrue() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .interrupted(.chatAboutQuestion))
        )
        let decision = try decisionObject(data)
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, AgentHookPermissionResponse.chatAboutQuestionMessage)
        XCTAssertTrue(isJSONBoolean(decision["interrupt"]), "interrupt must be an actual JSON boolean, not a JSON number")
        XCTAssertEqual(decision["interrupt"] as? Bool, true)
    }

    func test_body_codex_interrupted_isNil() {
        XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.codexKind, decision: .interrupted(.chatAboutQuestion)),
                    "codex fails closed on interrupt, same as .expired")
    }

    // MARK: - grok
    //
    // Grok's PreToolUse decision vocabulary is a flat, top-level
    // `{"decision":"allow"}` / `{"decision":"deny","reason":"..."}`.

    private func grokDecision(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_body_grok_allowed_isFlatAllowDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: .allowed)
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "allow")
        XCTAssertEqual(Set(object.keys), ["decision"])
    }

    func test_body_grok_denied_isFlatDenyDecisionWithReason() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: .denied(.userRejected))
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        XCTAssertEqual(Set(object.keys), ["decision", "reason"])
        XCTAssertEqual(object["reason"] as? String, AgentHookPermissionResponse.deniedMessage)
    }

    func test_body_grok_expired_isADenyDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: .expired)
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        let reason = try XCTUnwrap(object["reason"] as? String)
        XCTAssertFalse(reason.isEmpty)
    }

    func test_body_grok_expired_differsFromTheOtherKinds() {
        for kind in [AgentEntry.claudeCodeKind, AgentEntry.codexKind] {
            XCTAssertNil(AgentHookPermissionResponse.body(kind: kind, decision: .expired),
                         "[\(kind)] answers an expiry with silence")
        }
    }

    /// `.allowedForView` is an MCP Apps-only decision (the "Always Allow
    /// for This View" answer to an `.mcpApp`-sourced request) -- it can
    /// never actually reach `AgentHookPermissionResponse.body(kind:decision:)`,
    /// which only ever answers `.agentHook`/`.agentQuestion`-sourced
    /// requests, but the switch must still handle it exhaustively. It is
    /// mapped like `.expired`: nil for claude-code/codex (no vocabulary
    /// for it, no output), the flat deny body for grok/pi.
    func test_body_allowedForView_isTreatedLikeExpired() throws {
        for kind in [AgentEntry.claudeCodeKind, AgentEntry.codexKind] {
            XCTAssertNil(AgentHookPermissionResponse.body(kind: kind, decision: .allowedForView), "[\(kind)]")
        }
        for kind in [AgentEntry.grokKind, AgentEntry.piKind] {
            let expiredBody = try XCTUnwrap(AgentHookPermissionResponse.body(kind: kind, decision: .expired))
            let allowedForViewBody = try XCTUnwrap(AgentHookPermissionResponse.body(kind: kind, decision: .allowedForView))
            XCTAssertEqual(allowedForViewBody, expiredBody, "[\(kind)] must byte-match .expired's own body")
        }
    }

    func test_body_grok_neverUsesTheClaudeCodeEnvelope() throws {
        for decision in [ApprovalDecision.allowed, .denied(.userRejected), .expired] {
            let data = try XCTUnwrap(
                AgentHookPermissionResponse.body(kind: AgentEntry.grokKind, decision: decision)
            )
            let object = try grokDecision(data)
            XCTAssertNil(object["hookSpecificOutput"])
        }
    }

    func test_body_claudeCodeAndCodex_keepTheirNestedEnvelope() throws {
        for kind in [AgentEntry.claudeCodeKind, AgentEntry.codexKind] {
            let data = try XCTUnwrap(AgentHookPermissionResponse.body(kind: kind, decision: .allowed))
            let object = try grokDecision(data)
            XCTAssertNotNil(object["hookSpecificOutput"])
            XCTAssertNil(object["decision"])
        }
    }

    // MARK: - pi

    func test_body_pi_allowed_isFlatAllowDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.piKind, decision: .allowed)
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "allow")
        XCTAssertEqual(Set(object.keys), ["decision"])
    }

    func test_body_pi_denied_isFlatDenyDecisionWithReason() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.piKind, decision: .denied(.userRejected))
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        XCTAssertEqual(Set(object.keys), ["decision", "reason"])
        let reason = try XCTUnwrap(object["reason"] as? String)
        XCTAssertFalse(reason.isEmpty)
    }

    func test_body_pi_expired_isADenyDecision() throws {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.piKind, decision: .expired)
        )
        let object = try grokDecision(data)

        XCTAssertEqual(object["decision"] as? String, "deny")
        XCTAssertEqual(Set(object.keys), ["decision", "reason"])
    }

    // MARK: - grok / pi: the three unexpressible decisions are byte-identical to .expired

    func test_body_grokAndPi_unexpressibleDecisions_byteIdenticalToExpired() throws {
        let offer = makeOffer(entry: ["type": "addDirectories", "directories": ["/tmp"]], label: "x")
        let answers = makeAnswers()

        for kind in [AgentEntry.grokKind, AgentEntry.piKind] {
            let expiredBody = try XCTUnwrap(AgentHookPermissionResponse.body(kind: kind, decision: .expired))

            let unexpressible: [ApprovalDecision] = [
                .allowedForView, .allowedWithPermissions(offer), .interrupted(.chatAboutQuestion), .answered(answers), .dismissed,
            ]
            for decision in unexpressible {
                let body = try XCTUnwrap(AgentHookPermissionResponse.body(kind: kind, decision: decision), "kind=\(kind)")
                XCTAssertEqual(body, expiredBody, "kind=\(kind) decision=\(decision) must byte-match .expired's own body")
            }
        }
    }

    // MARK: - cliKeepsOwnPrompt(kind:)

    func test_cliKeepsOwnPrompt_trueForClaudeCodeAndCodex_falseForGrokAndPi() {
        XCTAssertTrue(AgentHookPermissionResponse.cliKeepsOwnPrompt(kind: AgentEntry.claudeCodeKind))
        XCTAssertTrue(AgentHookPermissionResponse.cliKeepsOwnPrompt(kind: AgentEntry.codexKind))
        XCTAssertFalse(AgentHookPermissionResponse.cliKeepsOwnPrompt(kind: AgentEntry.grokKind))
        XCTAssertFalse(AgentHookPermissionResponse.cliKeepsOwnPrompt(kind: AgentEntry.piKind))
        XCTAssertFalse(AgentHookPermissionResponse.cliKeepsOwnPrompt(kind: "some-unrecognized-cli"))
    }

    func test_body_codex_unexpressibleDecisions_areNil_sameAsExpired() throws {
        let offer = makeOffer(entry: ["type": "addDirectories", "directories": ["/tmp"]], label: "x")
        let answers = makeAnswers()

        let unexpressible: [ApprovalDecision] = [
            .allowedForView, .allowedWithPermissions(offer), .interrupted(.chatAboutQuestion), .answered(answers), .dismissed,
        ]
        for decision in unexpressible {
            XCTAssertNil(AgentHookPermissionResponse.body(kind: AgentEntry.codexKind, decision: decision))
        }
    }

    // MARK: - unrecognized kind

    func test_body_unknownKind_isNilForAllDecisions() throws {
        let unknownKind = "some-unrecognized-cli"
        let offer = makeOffer(entry: ["type": "addDirectories", "directories": ["/tmp"]], label: "x")

        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .allowed))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .allowedForView))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .denied(.userRejected)))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .expired))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .allowedWithPermissions(offer)))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .interrupted(.chatAboutQuestion)))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .answered(makeAnswers())))
        XCTAssertNil(AgentHookPermissionResponse.body(kind: unknownKind, decision: .dismissed))
    }

    // MARK: - claude-code: .answered (AskUserQuestion)

    private func toolInputValue(_ data: Data) throws -> NSDictionary {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func makeAnswers() -> AgentQuestionAnswers {
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which shell?", "options": [["label": "zsh"], ["label": "bash"]]],
                ["question": "Which editors?", "multiSelect": true,
                 "options": [["label": "vim"], ["label": "emacs"], ["label": "nano"]]],
                ["question": "Anything else?", "options": [["label": "Other"]]],
            ],
        ]
        let originalToolInputJSON = try! JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [
                AgentQuestionPrompt.Question(
                    text: "Which shell?", header: nil,
                    options: [
                        AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "bash", description: nil, preview: nil),
                    ],
                    multiSelect: false
                ),
                AgentQuestionPrompt.Question(
                    text: "Which editors?", header: nil,
                    options: [
                        AgentQuestionPrompt.Option(label: "vim", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "emacs", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "nano", description: nil, preview: nil),
                    ],
                    multiSelect: true
                ),
                AgentQuestionPrompt.Question(
                    text: "Anything else?", header: nil,
                    options: [AgentQuestionPrompt.Option(label: "Other", description: nil, preview: nil)],
                    multiSelect: false
                ),
            ],
            originalToolInputJSON: originalToolInputJSON
        )
        return AgentQuestionAnswers(
            prompt: prompt,
            entries: [
                .init(answer: .selectedOne("zsh"), notes: nil),
                .init(answer: .selectedMany(["vim", "emacs"]), notes: nil),
                .init(answer: .freeText("Please also install ripgrep"), notes: nil),
            ]
        )
    }

    func test_body_claude_answered_isAllowBehaviorWithUpdatedInput() throws {
        let answers = makeAnswers()
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")

        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        XCTAssertEqual(Set(decisionObject.keys), ["behavior", "updatedInput"])
        XCTAssertEqual(decisionObject["behavior"] as? String, "allow")

        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        XCTAssertEqual(Set(updatedInput.keys), ["questions", "answers"],
                       "no question in this fixture carries notes or a previewed selection, so annotations must be absent")

        let questionsValue = try XCTUnwrap(updatedInput["questions"])
        let questionsData = try JSONSerialization.data(withJSONObject: ["questions": questionsValue])
        let originalToolInput = try toolInputValue(answers.prompt.originalToolInputJSON)
        XCTAssertEqual(try toolInputValue(questionsData)["questions"] as? NSArray, originalToolInput["questions"] as? NSArray)

        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        XCTAssertEqual(answersObject, [
            "Which shell?": "zsh",
            "Which editors?": "vim, emacs",
            "Anything else?": "Please also install ripgrep",
        ])
    }

    func test_body_claude_answered_updatedInputKeys_areOriginalToolInputKeysPlusAnswers() throws {
        let toolInput: [String: Any] = [
            "questions": [["question": "Which shell?", "options": [["label": "zsh"]]]],
            "metadata": ["source": "cli"],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil)],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .selectedOne("zsh"), notes: nil)])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])

        XCTAssertEqual(Set(updatedInput.keys), ["questions", "metadata", "answers"])
    }

    func test_body_claude_answered_staleAnswersKeyInToolInput_isOverwrittenNotMerged() throws {
        let toolInput: [String: Any] = [
            "questions": [["question": "Which shell?", "options": [["label": "zsh"]]]],
            "answers": ["stale": "value"],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil)],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .selectedOne("zsh"), notes: nil)])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])

        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])
        XCTAssertEqual(answersObject, ["Which shell?": "zsh"])
        XCTAssertEqual(Set(updatedInput.keys), ["questions", "answers"])
    }

    func test_body_nonClaudeCodeKinds_answered_isNil() {
        let answers = makeAnswers()
        for kind in [AgentEntry.codexKind, AgentEntry.grokKind, AgentEntry.piKind, "some-unrecognized-cli"] {
            if kind == AgentEntry.grokKind || kind == AgentEntry.piKind { continue } // covered by the byte-identical-to-expired tests above
            XCTAssertNil(AgentHookPermissionResponse.body(kind: kind, decision: .answered(answers)),
                        "[\(kind)] .answered must produce no body")
        }
    }

    // MARK: - annotations

    private func makeSingleQuestionAnswers(
        optionPreview: String?, notes: String?, answer: AgentQuestionAnswer = .selectedOne("zsh"),
        preexistingAnnotations: [String: Any]? = nil
    ) -> AgentQuestionAnswers {
        var option: [String: Any] = ["label": "zsh"]
        if let optionPreview { option["preview"] = optionPreview }
        var toolInput: [String: Any] = [
            "questions": [["question": "Which shell?", "options": [option]]],
        ]
        if let preexistingAnnotations {
            toolInput["annotations"] = preexistingAnnotations
        }
        let originalToolInputJSON = try! JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: optionPreview)],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        return AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: answer, notes: notes)])
    }

    private func updatedInput(for answers: AgentQuestionAnswers) throws -> [String: Any] {
        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        return try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
    }

    func test_body_claude_answered_annotations_notesOnly() throws {
        let answers = makeSingleQuestionAnswers(optionPreview: nil, notes: "please double check")
        let input = try updatedInput(for: answers)

        XCTAssertTrue(Set(input.keys).contains("annotations"))
        let annotations = try XCTUnwrap(input["annotations"] as? [String: Any])
        let entry = try XCTUnwrap(annotations["Which shell?"] as? [String: Any])
        XCTAssertEqual(entry as NSDictionary, ["notes": "please double check"] as NSDictionary)
    }

    func test_body_claude_answered_annotations_previewOnly() throws {
        let answers = makeSingleQuestionAnswers(optionPreview: "the current default", notes: nil)
        let input = try updatedInput(for: answers)

        let annotations = try XCTUnwrap(input["annotations"] as? [String: Any])
        let entry = try XCTUnwrap(annotations["Which shell?"] as? [String: Any])
        XCTAssertEqual(entry as NSDictionary, ["preview": "the current default"] as NSDictionary)
    }

    func test_body_claude_answered_annotations_notesAndPreview() throws {
        let answers = makeSingleQuestionAnswers(optionPreview: "the current default", notes: "please double check")
        let input = try updatedInput(for: answers)

        let annotations = try XCTUnwrap(input["annotations"] as? [String: Any])
        let entry = try XCTUnwrap(annotations["Which shell?"] as? [String: Any])
        XCTAssertEqual(entry as NSDictionary, ["notes": "please double check", "preview": "the current default"] as NSDictionary)
    }

    func test_body_claude_answered_annotations_neitherNotesNorPreview_keyAbsent() throws {
        let answers = makeSingleQuestionAnswers(optionPreview: nil, notes: nil)
        let input = try updatedInput(for: answers)

        XCTAssertFalse(Set(input.keys).contains("annotations"),
                       "annotations must be absent entirely when no question contributes anything")
    }

    func test_body_claude_answered_annotations_multiSelectAnswer_neverGetsPreview() throws {
        let answers = makeSingleQuestionAnswers(
            optionPreview: "the current default", notes: nil, answer: .selectedMany(["zsh"])
        )
        let input = try updatedInput(for: answers)

        XCTAssertFalse(Set(input.keys).contains("annotations"),
                       "preview is only ever attached for a .selectedOne answer, never .selectedMany")
    }

    func test_body_claude_answered_annotations_staleAnnotationsKey_isOverwrittenNotMerged() throws {
        let answers = makeSingleQuestionAnswers(
            optionPreview: nil, notes: "please double check", preexistingAnnotations: ["stale": "value"]
        )
        let input = try updatedInput(for: answers)

        let annotations = try XCTUnwrap(input["annotations"] as? [String: Any])
        XCTAssertNil(annotations["stale"], "the stale pre-existing annotations key must be gone")
        XCTAssertEqual(Set(annotations.keys), ["Which shell?"])
    }

    // MARK: - selectedLabelsAnswerValue (claude-code's multi-select answer encoding)

    func test_selectedLabelsAnswerValue_plainLabels_joinsWithCommaSpace() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue(["zsh", "bash"]), "zsh, bash")
    }

    func test_selectedLabelsAnswerValue_singlePlainLabel_returnsItself() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue(["zsh"]), "zsh")
    }

    func test_selectedLabelsAnswerValue_labelContainingCommaSpace_isJSONQuoted() {
        XCTAssertEqual(
            AgentHookPermissionResponse.selectedLabelsAnswerValue(["Swift, Rust", "Go"]),
            "\"Swift, Rust\", Go"
        )
    }

    func test_selectedLabelsAnswerValue_labelContainingDoubleQuote_isJSONQuoted() {
        XCTAssertEqual(
            AgentHookPermissionResponse.selectedLabelsAnswerValue(["Say \"hi\""]),
            "\"Say \\\"hi\\\"\""
        )
    }

    func test_selectedLabelsAnswerValue_oneElementMultiSelectAnswer_labelContainingCommaSpace_isQuotedAlone() {
        XCTAssertEqual(
            AgentHookPermissionResponse.selectedLabelsAnswerValue(["Swift, Rust"]),
            "\"Swift, Rust\""
        )
    }

    func test_selectedLabelsAnswerValue_labelContainingSlash_isNotEscaped() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue(["a/b"]), "a/b")
    }

    func test_selectedLabelsAnswerValue_emptyArray_returnsEmptyString() {
        XCTAssertEqual(AgentHookPermissionResponse.selectedLabelsAnswerValue([]), "")
    }

    func test_body_claude_answered_selectedOne_labelContainingCommaSpace_isEmittedRaw() throws {
        let toolInput: [String: Any] = [
            "questions": [["question": "Which pair?", "options": [["label": "Swift, Rust"], ["label": "Go"]]]],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which pair?", header: nil,
                options: [
                    AgentQuestionPrompt.Option(label: "Swift, Rust", description: nil, preview: nil),
                    AgentQuestionPrompt.Option(label: "Go", description: nil, preview: nil),
                ],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .selectedOne("Swift, Rust"), notes: nil)])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(answersObject["Which pair?"], "Swift, Rust")
    }

    func test_body_claude_answered_selectedMany_isEmittedThroughSelectedLabelsAnswerValue() throws {
        let precomputed = AgentHookPermissionResponse.selectedLabelsAnswerValue(["Swift, Rust", "Go"])
        let toolInput: [String: Any] = [
            "questions": [
                ["question": "Which languages?", "multiSelect": true,
                 "options": [["label": "Swift, Rust"], ["label": "Go"]]],
            ],
        ]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [
                AgentQuestionPrompt.Question(
                    text: "Which languages?", header: nil,
                    options: [
                        AgentQuestionPrompt.Option(label: "Swift, Rust", description: nil, preview: nil),
                        AgentQuestionPrompt.Option(label: "Go", description: nil, preview: nil),
                    ],
                    multiSelect: true
                ),
            ],
            originalToolInputJSON: originalToolInputJSON
        )
        let answers = AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .selectedMany(["Swift, Rust", "Go"]), notes: nil)])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(answersObject["Which languages?"], precomputed)
    }

    func test_body_claude_answered_freeText_isEmittedRaw_evenContainingCommaSpace() throws {
        let toolInput: [String: Any] = ["questions": [["question": "Anything else?", "options": [["label": "Other"]]]]]
        let originalToolInputJSON = try JSONSerialization.data(withJSONObject: toolInput)
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Anything else?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "Other", description: nil, preview: nil)],
                multiSelect: false
            )],
            originalToolInputJSON: originalToolInputJSON
        )
        let freeText = "Install ripgrep, then fd"
        let answers = AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .freeText(freeText), notes: nil)])

        let data = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .answered(answers))
        )
        let output = try hookSpecificOutput(data)
        let decisionObject = try XCTUnwrap(output["decision"] as? [String: Any])
        let updatedInput = try XCTUnwrap(decisionObject["updatedInput"] as? [String: Any])
        let answersObject = try XCTUnwrap(updatedInput["answers"] as? [String: String])

        XCTAssertEqual(answersObject["Anything else?"], freeText)
    }

    // MARK: - forbidden fields (PermissionRequest reserved/invalid keys)

    func test_body_neverContainsForbiddenPermissionRequestFields() throws {
        let allowData = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .allowed)
        )
        let allowOutput = try hookSpecificOutput(allowData)
        XCTAssertEqual(Set(allowOutput.keys), ["hookEventName", "decision"])
        let allowDecision = try XCTUnwrap(allowOutput["decision"] as? [String: Any])
        XCTAssertEqual(Set(allowDecision.keys), ["behavior"])

        let denyData = try XCTUnwrap(
            AgentHookPermissionResponse.body(kind: AgentEntry.claudeCodeKind, decision: .denied(.userRejected))
        )
        let denyOutput = try hookSpecificOutput(denyData)
        XCTAssertEqual(Set(denyOutput.keys), ["hookEventName", "decision"])
        let denyDecision = try XCTUnwrap(denyOutput["decision"] as? [String: Any])
        XCTAssertEqual(Set(denyDecision.keys), ["behavior", "message"])
    }
}
