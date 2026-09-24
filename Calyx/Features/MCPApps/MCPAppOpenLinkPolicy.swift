//
//  MCPAppOpenLinkPolicy.swift
//  Calyx
//
//  Which URLs `ui/open-link` may open, and which views may open them
//  without a prompt. Every link prompts by default (the view is
//  third-party HTML); "Always Allow for This View" lasts as long as the
//  view: a Reload keeps it, the view's removal forgets it.
//

import Foundation

@MainActor
final class MCPAppOpenLinkPolicy {
    /// The user's choice in the open-link prompt (the approval panel, see
    /// `PromptDecision.init(_:)` in MCPAppConsentPresenter.swift).
    enum PromptDecision: Sendable, Equatable { case open, alwaysForThisView, cancel }

    private nonisolated static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    private var alwaysAllowed: Set<UUID> = []

    init() {}

    nonisolated static func isAllowedScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }

    func requiresPrompt(viewID: UUID) -> Bool {
        !alwaysAllowed.contains(viewID)
    }

    func recordAlways(viewID: UUID) {
        alwaysAllowed.insert(viewID)
    }

    /// Forgets the allowance of a view the store no longer has.
    func viewWasRemoved(viewID: UUID) {
        alwaysAllowed.remove(viewID)
    }
}
