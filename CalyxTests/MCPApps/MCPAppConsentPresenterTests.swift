//
//  MCPAppConsentPresenterTests.swift
//  CalyxTests
//
//  Covers the seam between MCP Apps consent prompts and the Cockpit
//  approval panel:
//  - MCPAppOpenLinkPolicy.PromptDecision(_ d: ApprovalDecision): maps
//    .allowed -> .open, .allowedForView -> .alwaysForThisView, and every
//    other ApprovalDecision case (a human never granted anything) -> .cancel
//  - MCPAppMessageConsentGate.PromptDecision(_ d: ApprovalDecision): maps
//    .allowed -> .send, .allowedForView -> .alwaysForThisView, and every
//    other case -> .dontSend
//  - ApprovalInboxConsentPresenter.requestConsent(_:timeoutMs:) submits
//    the given ApprovalRequest to its store and resolves once
//    store.decide(id:_:) is called with that request's own id
//  - ApprovalInboxConsentPresenter.expire(requestID:) on an id the store
//    has no pending request for is a no-op: it must not post a change
//    notification or otherwise touch the store
//

import XCTest
@testable import Calyx

final class MCPAppConsentPresenterTests: XCTestCase {

    // MARK: - Fixtures

    private func makeOffer() -> AgentPermissionOffer {
        AgentPermissionOffer(
            label: "Yes, and always allow access to /tmp",
            entryJSON: try! JSONSerialization.data(withJSONObject: ["type": "addDirectories", "directories": ["/tmp"]])
        )
    }

    private func makeAnswers() -> AgentQuestionAnswers {
        let prompt = AgentQuestionPrompt(
            questions: [AgentQuestionPrompt.Question(
                text: "Which shell?", header: nil,
                options: [AgentQuestionPrompt.Option(label: "zsh", description: nil, preview: nil)], multiSelect: false
            )],
            originalToolInputJSON: try! JSONSerialization.data(withJSONObject: ["questions": [["question": "Which shell?", "options": [["label": "zsh"]]]]])
        )
        return AgentQuestionAnswers(prompt: prompt, entries: [.init(answer: .selectedOne("zsh"), notes: nil)])
    }

    /// Every `ApprovalDecision` case, one fixture each -- the table both
    /// `PromptDecision.init(_:)`s are exercised over below.
    private func everyDecision() -> [ApprovalDecision] {
        [
            .allowed,
            .allowedForView,
            .allowedWithPermissions(makeOffer()),
            .denied(.userRejected),
            .interrupted(.chatAboutQuestion),
            .expired,
            .answered(makeAnswers()),
            .dismissed,
        ]
    }

    // MARK: - MCPAppOpenLinkPolicy.PromptDecision(_:)

    func test_openLinkPromptDecision_allowed_isOpen() {
        XCTAssertEqual(MCPAppOpenLinkPolicy.PromptDecision(.allowed), .open)
    }

    func test_openLinkPromptDecision_allowedForView_isAlwaysForThisView() {
        XCTAssertEqual(MCPAppOpenLinkPolicy.PromptDecision(.allowedForView), .alwaysForThisView)
    }

    func test_openLinkPromptDecision_everyOtherDecision_isCancel() {
        for decision in everyDecision() where decision != .allowed && decision != .allowedForView {
            XCTAssertEqual(MCPAppOpenLinkPolicy.PromptDecision(decision), .cancel, "decision=\(decision)")
        }
    }

    // MARK: - MCPAppMessageConsentGate.PromptDecision(_:)

    func test_messagePromptDecision_allowed_isSend() {
        XCTAssertEqual(MCPAppMessageConsentGate.PromptDecision(.allowed), .send)
    }

    func test_messagePromptDecision_allowedForView_isAlwaysForThisView() {
        XCTAssertEqual(MCPAppMessageConsentGate.PromptDecision(.allowedForView), .alwaysForThisView)
    }

    func test_messagePromptDecision_everyOtherDecision_isDontSend() {
        for decision in everyDecision() where decision != .allowed && decision != .allowedForView {
            XCTAssertEqual(MCPAppMessageConsentGate.PromptDecision(decision), .dontSend, "decision=\(decision)")
        }
    }

    // MARK: - ApprovalInboxConsentPresenter

    @MainActor
    private func makeRequest(kind: MCPAppConsentKind = .openLink(URL(string: "https://example.com")!)) -> ApprovalRequest {
        ApprovalRequest(id: UUID(), source: .mcpApp(viewID: UUID(), title: "Notion", kind: kind), targetSurfaceID: nil, payload: "payload", createdAt: Date())
    }

    @MainActor
    func test_requestConsent_submitsToTheStore_andResolvesOnceDecided() async throws {
        let store = ApprovalInboxStore()
        let presenter = ApprovalInboxConsentPresenter(store: store)
        let request = makeRequest()

        let waiter = Task { @MainActor in
            await presenter.requestConsent(request, timeoutMs: 5_000)
        }
        for _ in 0..<50 { await Task.yield() }

        XCTAssertEqual(store.pending.map(\.id), [request.id], "requestConsent must submit the given request to the store")

        store.decide(id: request.id, .allowed)

        let result = await waiter.value
        XCTAssertEqual(result, .allowed, "requestConsent must resolve with whatever decision store.decide(id:_:) was called with")
    }

    @MainActor
    func test_requestConsent_timesOut_resolvesExpired() async throws {
        let store = ApprovalInboxStore()
        let presenter = ApprovalInboxConsentPresenter(store: store)
        let request = makeRequest()

        let result = await presenter.requestConsent(request, timeoutMs: 20)

        XCTAssertEqual(result, .expired)
        XCTAssertTrue(store.pending.isEmpty, "a timed-out request must leave the store's pending queue")
    }

    @MainActor
    func test_expire_unknownRequestID_isNoOp() {
        let store = ApprovalInboxStore()
        let presenter = ApprovalInboxConsentPresenter(store: store)
        let notifyCountBefore = store._testNotifyCount

        presenter.expire(requestID: UUID())

        XCTAssertEqual(store._testNotifyCount, notifyCountBefore,
                       "expire(requestID:) on an id the store has no pending request for must be a no-op -- no change notification, nothing touched")
        XCTAssertTrue(store.pending.isEmpty)
    }

    @MainActor
    func test_expire_pendingRequestID_resolvesItExpired() async throws {
        let store = ApprovalInboxStore()
        let presenter = ApprovalInboxConsentPresenter(store: store)
        let request = makeRequest()

        let waiter = Task { @MainActor in
            await presenter.requestConsent(request, timeoutMs: 5_000)
        }
        for _ in 0..<50 { await Task.yield() }

        presenter.expire(requestID: request.id)

        let result = await waiter.value
        XCTAssertEqual(result, .expired)
        XCTAssertTrue(store.pending.isEmpty)
    }
}
