//
//  MCPAppMessageDeliveryTests.swift
//  CalyxTests
//
//  ui/message delivery (plan §9, decision "ui/message の同意") must use the
//  SAME Return rule as pane_run (MCPCockpitBridge.handlePaneRun, L409:
//  `doubleReturn = agentRegistry.entries[surfaceID] != nil`), through the
//  same CockpitAppAccessing.sendCommand seam MCPCockpitBridgeTests already
//  drives -- no CLI-name branching, ever. Persistent-session herdr
//  TUI-attach tabs deliver through a separate injectable seam (herdr
//  0.8.0's pane.send_text/send_keys/send_input) but obey the identical
//  Return rule. Consent is a per-message dock prompt (Send / Always for
//  this view / Don't Send); "Always" lasts only as long as the view
//  itself, and a pending prompt resolves -32000 the moment the view goes
//  away. A pane-less invocation gets Copy only, never a Send path, and
//  always resolves -32000.
//

import os
import XCTest
@testable import Calyx

// MARK: - Fakes

@MainActor
private final class FakeCockpitAccessForDelivery: CockpitAppAccessing {
    private(set) var recordedCommand: String?
    private(set) var recordedSurfaceID: UUID?
    private(set) var recordedDoubleReturn: Bool?
    var sendCommandError: Error?

    func listPanes() -> [CockpitPaneInfo] { [] }
    func paneExists(_ id: UUID) -> Bool { true }
    func sendCommand(surfaceID: UUID, command: String, doubleReturn: Bool) throws {
        if let sendCommandError { throw sendCommandError }
        recordedSurfaceID = surfaceID
        recordedCommand = command
        recordedDoubleReturn = doubleReturn
    }
    func sendKeys(surfaceID: UUID, text: String) throws {}
    func splitPane(surfaceID: UUID, direction: SplitDirection) throws -> UUID { UUID() }
    func createTab(groupName: String?, cwd: String?) throws -> CockpitNewTab {
        throw CockpitAccessError.appUnavailable
    }
    func availablePaletteCommands() -> [CockpitPaletteCommand] { [] }
    func executePaletteCommand(id: String) throws -> CockpitPaletteCommand {
        throw CockpitAccessError.appUnavailable
    }
}

@MainActor
private final class FakeHerdrPaneInputSending: MCPHerdrPaneInputSending {
    private(set) var recordedPaneID: String?
    private(set) var recordedText: String?
    private(set) var recordedPressReturnTwice: Bool?

    func sendText(paneID: String, text: String, pressReturnTwice: Bool) async throws {
        recordedPaneID = paneID
        recordedText = text
        recordedPressReturnTwice = pressReturnTwice
    }
}

final class MCPAppMessageDeliveryTests: XCTestCase {

    // MARK: - Cockpit path: Return rule parity with pane_run

    @MainActor
    func test_cockpitDelivery_noAgentRegistryEntry_sendsSingleReturn() async throws {
        let access = FakeCockpitAccessForDelivery()
        let surfaceID = UUID()
        let delivery = MCPAppCockpitInputDelivery(access: access, isAgentPane: { _ in false })

        try await delivery.deliverUserMessage("hello", to: surfaceID)

        XCTAssertEqual(access.recordedDoubleReturn, false)
        XCTAssertEqual(access.recordedCommand, "hello")
        XCTAssertEqual(access.recordedSurfaceID, surfaceID)
    }

    @MainActor
    func test_cockpitDelivery_withAgentRegistryEntry_sendsDoubleReturn() async throws {
        let access = FakeCockpitAccessForDelivery()
        let surfaceID = UUID()
        let delivery = MCPAppCockpitInputDelivery(access: access, isAgentPane: { $0 == surfaceID })

        try await delivery.deliverUserMessage("hello", to: surfaceID)

        XCTAssertEqual(access.recordedDoubleReturn, true,
            "a target pane WITH an AgentRegistry entry must get a doubled synthetic Return, matching pane_run exactly")
    }

    @MainActor
    func test_cockpitDelivery_propagatesUnderlyingSendCommandFailure() async {
        let access = FakeCockpitAccessForDelivery()
        access.sendCommandError = CockpitAccessError.appUnavailable
        let delivery = MCPAppCockpitInputDelivery(access: access, isAgentPane: { _ in false })

        do {
            try await delivery.deliverUserMessage("hello", to: UUID())
            XCTFail("expected the sendCommand failure to propagate")
        } catch {}
    }

    // MARK: - Herdr path: same Return rule, different transport

    @MainActor
    func test_herdrDelivery_notAnAgentPane_pressReturnTwiceIsFalse() async throws {
        let herdrInput = FakeHerdrPaneInputSending()
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/tmp/herdr.sock", paneID: "herdr-pane-1")
        let delivery = MCPAppHerdrInputDelivery(herdrInput: herdrInput, isAgentPane: { _ in false })

        try await delivery.deliverUserMessage("hello", to: ref, surfaceID: surfaceID)

        XCTAssertEqual(herdrInput.recordedPressReturnTwice, false)
        XCTAssertEqual(herdrInput.recordedPaneID, ref.paneID)
        XCTAssertEqual(herdrInput.recordedText, "hello")
    }

    @MainActor
    func test_herdrDelivery_isAgentPane_pressReturnTwiceIsTrue() async throws {
        let herdrInput = FakeHerdrPaneInputSending()
        let surfaceID = UUID()
        let ref = HerdrPaneRef(socketPath: "/tmp/herdr.sock", paneID: "herdr-pane-1")
        let delivery = MCPAppHerdrInputDelivery(herdrInput: herdrInput, isAgentPane: { $0 == surfaceID })

        try await delivery.deliverUserMessage("hello", to: ref, surfaceID: surfaceID)

        XCTAssertEqual(herdrInput.recordedPressReturnTwice, true,
            "the herdr seam must apply the identical Return rule as the cockpit seam -- no CLI-name branching")
    }

    @MainActor
    func test_herdrDelivery_nilSurfaceID_pressReturnTwiceIsFalse() async throws {
        // A herdr TUI-attach tab may have no surfaceID at all; that must
        // not crash isAgentPane and must fall back to a single Return.
        let herdrInput = FakeHerdrPaneInputSending()
        let ref = HerdrPaneRef(socketPath: "/tmp/herdr.sock", paneID: "herdr-pane-1")
        let delivery = MCPAppHerdrInputDelivery(herdrInput: herdrInput, isAgentPane: { _ in true })

        try await delivery.deliverUserMessage("hello", to: ref, surfaceID: nil)

        XCTAssertEqual(herdrInput.recordedPressReturnTwice, false)
    }

    // MARK: - HerdrSocketPaneSending: two socket calls, pane.send_text then pane.send_keys

    private final class CallRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [(method: String, params: [String: AnyCodable])] = []
        func record(_ method: String, _ params: [String: AnyCodable]) {
            lock.lock(); defer { lock.unlock() }
            calls.append((method, params))
        }
    }

    func test_herdrSocketPaneSending_singleReturn_sendsTextThenOneReturnKey() async throws {
        let recorder = CallRecorder()
        let sending = HerdrSocketPaneSending(send: { method, params in
            recorder.record(method, params)
        })

        try await sending.sendText(paneID: "w1:p1", text: "hello", pressReturnTwice: false)

        XCTAssertEqual(recorder.calls.map(\.method), ["pane.send_text", "pane.send_keys"],
            "pane.send_text must be sent before pane.send_keys")
        XCTAssertEqual(recorder.calls[0].params["pane_id"]?.stringValue, "w1:p1")
        XCTAssertEqual(recorder.calls[0].params["text"]?.stringValue, "hello")
        let keys = recorder.calls[1].params["keys"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(keys, ["Return"])
    }

    func test_herdrSocketPaneSending_doubleReturn_sendsTextThenTwoReturnKeysInOneCall() async throws {
        let recorder = CallRecorder()
        let sending = HerdrSocketPaneSending(send: { method, params in
            recorder.record(method, params)
        })

        try await sending.sendText(paneID: "w1:p1", text: "hello", pressReturnTwice: true)

        XCTAssertEqual(recorder.calls.map(\.method), ["pane.send_text", "pane.send_keys"])
        let keys = recorder.calls[1].params["keys"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(keys, ["Return", "Return"], "double Return is one pane.send_keys call with two entries, not two calls")
    }

    // MARK: - Route selection: herdr headers present -> herdr, absent -> cockpit

    func test_deliveryRoute_withHerdrPaneRef_choosesHerdr() {
        let ref = HerdrPaneRef(socketPath: "/tmp/herdr.sock", paneID: "herdr-pane-1")
        let surfaceID = UUID()

        let route = MCPAppMessageDeliveryRoute.choose(surfaceID: surfaceID, herdrRef: ref)

        XCTAssertEqual(route, .herdr(ref))
    }

    func test_deliveryRoute_withoutHerdrPaneRef_choosesCockpit() {
        let surfaceID = UUID()

        let route = MCPAppMessageDeliveryRoute.choose(surfaceID: surfaceID, herdrRef: nil)

        XCTAssertEqual(route, .cockpit(surfaceID: surfaceID))
    }

    func test_deliveryRoute_bothNil_choosesCopyOnly() {
        let route = MCPAppMessageDeliveryRoute.choose(surfaceID: nil, herdrRef: nil)

        XCTAssertEqual(route, .copyOnly)
    }

    func test_deliveryRoute_bothPresent_herdrTakesPriority() {
        let ref = HerdrPaneRef(socketPath: "/tmp/herdr.sock", paneID: "herdr-pane-1")
        let surfaceID = UUID()

        let route = MCPAppMessageDeliveryRoute.choose(surfaceID: surfaceID, herdrRef: ref)

        XCTAssertEqual(route, .herdr(ref), "herdr must win when both a surfaceID and a herdr pane ref are present")
    }

    // MARK: - Consent: per-message prompt, Always lasts only for the view's lifetime

    @MainActor
    func test_consentGate_defaultRequiresPromptForEveryMessage() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()

        XCTAssertTrue(gate.requiresPrompt(viewID: viewID))
    }

    @MainActor
    func test_consentGate_alwaysForThisView_skipsPromptForSubsequentMessages() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()

        gate.recordAlways(viewID: viewID)

        XCTAssertFalse(gate.requiresPrompt(viewID: viewID))
    }

    @MainActor
    func test_consentGate_alwaysForOneView_doesNotAffectAnotherView() {
        let gate = MCPAppMessageConsentGate()
        let viewA = UUID()
        let viewB = UUID()

        gate.recordAlways(viewID: viewA)

        XCTAssertFalse(gate.requiresPrompt(viewID: viewA))
        XCTAssertTrue(gate.requiresPrompt(viewID: viewB))
    }

    @MainActor
    func test_consentGate_viewWasRemoved_clearsAlwaysApproval() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()
        gate.recordAlways(viewID: viewID)
        XCTAssertFalse(gate.requiresPrompt(viewID: viewID))

        gate.viewWasRemoved(viewID: viewID)

        XCTAssertTrue(gate.requiresPrompt(viewID: viewID),
            "\"Always\" must last only as long as the view -- a fresh view (even reusing the same tool) starts unapproved")
    }

    // beginRequest(hasPane: true) is the only declared way to enter the
    // pending state (§11.6: "それ以外 -> nil を返し内部で pending を開始");
    // there is no separate begin-pending seam.

    @MainActor
    func test_consentGate_pendingPrompt_viewWasRemoved_endsThePendingRequest() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()
        _ = gate.beginRequest(viewID: viewID, hasPane: true)

        gate.viewWasRemoved(viewID: viewID)

        XCTAssertFalse(gate.isPending(viewID: viewID))
    }

    @MainActor
    func test_consentGate_cancelPendingPrompt_endsThePendingRequest_andKeepsAlwaysApproval() {
        let gate = MCPAppMessageConsentGate()
        let pendingViewID = UUID()
        let approvedViewID = UUID()
        _ = gate.beginRequest(viewID: pendingViewID, hasPane: true)
        gate.recordAlways(viewID: approvedViewID)

        gate.cancelPendingPrompt(viewID: pendingViewID)
        gate.cancelPendingPrompt(viewID: approvedViewID)

        XCTAssertFalse(gate.isPending(viewID: pendingViewID))
        XCTAssertFalse(gate.requiresPrompt(viewID: approvedViewID), "a document unloading (Reload) keeps the view's approval")
    }

    @MainActor
    func test_consentGate_pendingPrompt_userSendsExplicitly_resolvesSend() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()
        _ = gate.beginRequest(viewID: viewID, hasPane: true)

        let outcome = gate.resolvePendingPrompt(viewID: viewID, decision: .send)

        XCTAssertEqual(outcome, .send)
        XCTAssertFalse(gate.isPending(viewID: viewID))
    }

    @MainActor
    func test_consentGate_pendingPrompt_userChoosesAlways_resolvesSendAndRecordsAlways() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()
        _ = gate.beginRequest(viewID: viewID, hasPane: true)

        let outcome = gate.resolvePendingPrompt(viewID: viewID, decision: .alwaysForThisView)

        XCTAssertEqual(outcome, .send)
        XCTAssertFalse(gate.requiresPrompt(viewID: viewID), "\"Always\" must be recorded immediately on resolution")
    }

    @MainActor
    func test_consentGate_pendingPrompt_userDeclines_resolvesDontSend() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()
        _ = gate.beginRequest(viewID: viewID, hasPane: true)

        let outcome = gate.resolvePendingPrompt(viewID: viewID, decision: .dontSend)

        XCTAssertEqual(outcome, .dontSend)
    }

    @MainActor
    func test_consentGate_noPane_neverRegistersAPendingPrompt_isCopyOnlyOutcome() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()

        let outcome = gate.beginRequest(viewID: viewID, hasPane: false)

        XCTAssertEqual(outcome, .noPaneCopyOnly)
        XCTAssertFalse(gate.isPending(viewID: viewID), "a pane-less request must resolve immediately, never register a pending prompt")
    }

    @MainActor
    func test_consentGate_hasPane_alreadyAlwaysApproved_beginRequestResolvesSendWithoutPrompt() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()
        gate.recordAlways(viewID: viewID)

        let outcome = gate.beginRequest(viewID: viewID, hasPane: true)

        XCTAssertEqual(outcome, .send)
        XCTAssertFalse(gate.isPending(viewID: viewID))
    }

    @MainActor
    func test_consentGate_hasPane_notYetApproved_beginRequestRegistersPendingPrompt_returnsNil() {
        let gate = MCPAppMessageConsentGate()
        let viewID = UUID()

        let outcome = gate.beginRequest(viewID: viewID, hasPane: true)

        XCTAssertNil(outcome, "a fresh, not-yet-approved request must register as pending, not resolve synchronously")
        XCTAssertTrue(gate.isPending(viewID: viewID))
    }

    // MARK: - A message whose image cannot be written reaches the view as -32000

    func test_messageSending_imageWriteFailure_isMinus32000_andNothingDelivered() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("calyx-mcp-apps-blocker-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let delivered = OSAllocatedUnfairLock(initialState: false)

        let result = await MCPAppMessageSending.send(
            [.text("caption"), .image(base64: "aGVsbG8=", mimeType: "image/png")],
            imageDirectory: blocker.appendingPathComponent("images")
        ) { _ in
            delivered.withLock { $0 = true }
        }

        guard case .failure(let error) = result else { return XCTFail("expected -32000, got \(result)") }
        XCTAssertEqual(error.code, -32000)
        XCTAssertFalse(delivered.withLock { $0 }, "nothing is delivered when the message cannot be prepared")
    }
}
