//
//  MCPAppMessageConsentGate.swift
//  Calyx
//
//  Per-message consent for `ui/message`. Every message asks by default
//  (the view is third-party HTML); "Always for this view" lasts as long
//  as the view: a Reload keeps it, the view's removal forgets it.
//  Independent of the Cockpit auto-approve setting.
//

import Foundation

@MainActor
final class MCPAppMessageConsentGate {
    /// The user's choice in the consent prompt (the approval panel, see
    /// `PromptDecision.init(_:)` in MCPAppConsentPresenter.swift).
    enum PromptDecision: Sendable, Equatable { case send, alwaysForThisView, dontSend }
    enum PromptOutcome: Sendable, Equatable { case send, dontSend }
    enum BeginOutcome: Sendable, Equatable { case noPaneCopyOnly, send }

    private var alwaysApproved: Set<UUID> = []
    private var pending: Set<UUID> = []

    init() {}

    func requiresPrompt(viewID: UUID) -> Bool {
        !alwaysApproved.contains(viewID)
    }

    func recordAlways(viewID: UUID) {
        alwaysApproved.insert(viewID)
    }

    /// `.noPaneCopyOnly` without a pane, `.send` when already approved for
    /// the view, otherwise nil with the request pending until
    /// `resolvePendingPrompt`, `cancelPendingPrompt` or `viewWasRemoved`.
    func beginRequest(viewID: UUID, hasPane: Bool) -> BeginOutcome? {
        guard hasPane else { return .noPaneCopyOnly }
        guard requiresPrompt(viewID: viewID) else { return .send }
        pending.insert(viewID)
        return nil
    }

    func isPending(viewID: UUID) -> Bool {
        pending.contains(viewID)
    }

    func resolvePendingPrompt(viewID: UUID, decision: PromptDecision) -> PromptOutcome {
        pending.remove(viewID)
        switch decision {
        case .send:
            return .send
        case .alwaysForThisView:
            recordAlways(viewID: viewID)
            return .send
        case .dontSend:
            return .dontSend
        }
    }

    /// Ends the pending request of a document that is unloading; the
    /// view's approval stays.
    func cancelPendingPrompt(viewID: UUID) {
        pending.remove(viewID)
    }

    /// Forgets the approval and any pending request of a view the store
    /// no longer has.
    func viewWasRemoved(viewID: UUID) {
        alwaysApproved.remove(viewID)
        pending.remove(viewID)
    }
}
