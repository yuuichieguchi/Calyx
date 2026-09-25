//
//  MCPAppConsentPresenter.swift
//  Calyx
//
//  Where an MCP Apps view's consent prompt (`ui/open-link`, `ui/message`,
//  and a pane-less view's copy-only message) is shown: the Cockpit
//  approval panel. The runtime builds an `.mcpApp`-sourced
//  `ApprovalRequest` and hands it to its environment's presenter; the
//  presenter submits it to an `ApprovalInboxStore` (the app's own
//  `.shared` one, whose panel `AppDelegate` renders on every change) and
//  waits for the human's decision. The two `PromptDecision` mappers turn
//  that decision back into the runtime's own open-link/message outcomes:
//  only `.allowed` and `.allowedForView` grant anything.
//

import Foundation

@MainActor
protocol MCPAppConsentPresenting: AnyObject {
    /// Shows `request` and resolves with the human's decision, or
    /// `.expired` once `timeoutMs` passes or `expire(requestID:)` is
    /// called for it.
    func requestConsent(_ request: ApprovalRequest, timeoutMs: Int) async -> ApprovalDecision
    /// Withdraws a still-pending request, resolving it `.expired`. A
    /// no-op for an id that is not pending.
    func expire(requestID: UUID)
}

@MainActor
final class ApprovalInboxConsentPresenter: MCPAppConsentPresenting {
    private let store: ApprovalInboxStore

    init(store: ApprovalInboxStore) {
        self.store = store
    }

    /// `awaitDecisionHonoringCancellation`: a grant racing the awaiting
    /// Task's cancellation is demoted to `.expired`, so a view whose
    /// handler is gone never acts on it.
    func requestConsent(_ request: ApprovalRequest, timeoutMs: Int) async -> ApprovalDecision {
        store.submit(request)
        return await store.awaitDecisionHonoringCancellation(id: request.id, timeoutMs: timeoutMs)
    }

    func expire(requestID: UUID) {
        store.decide(id: requestID, .expired)
    }
}

extension MCPAppOpenLinkPolicy.PromptDecision {
    /// `.allowed` opens, `.allowedForView` opens and remembers the view;
    /// every other decision (denied, dismissed, expired, ...) grants
    /// nothing and cancels.
    init(_ decision: ApprovalDecision) {
        switch decision {
        case .allowed:
            self = .open
        case .allowedForView:
            self = .alwaysForThisView
        case .allowedWithPermissions, .denied, .interrupted, .expired, .answered, .dismissed:
            self = .cancel
        }
    }
}

extension MCPAppMessageConsentGate.PromptDecision {
    /// `.allowed` sends, `.allowedForView` sends and remembers the view;
    /// every other decision (denied, dismissed, expired, ...) grants
    /// nothing and does not send.
    init(_ decision: ApprovalDecision) {
        switch decision {
        case .allowed:
            self = .send
        case .allowedForView:
            self = .alwaysForThisView
        case .allowedWithPermissions, .denied, .interrupted, .expired, .answered, .dismissed:
            self = .dontSend
        }
    }
}
