// MissionMapSelection.swift
// Calyx
//
// Mission Map's selection: one line OR one card, never both. Owned by
// `CalyxWindowController` rather than kept as `MissionMapView` state,
// because the selected line's popover is drawn outside the map's SwiftUI
// tree (`MissionMapPopoverHost`) and its close button must clear the
// selection from there.

import Foundation

/// What is selected on Mission Map.
enum MissionMapSelectionTarget: Equatable, Sendable {
    /// A line, by edge id; its popover is shown.
    case edge(UUID)
    /// A card, by card (leaf surface) id; drawn highlighted.
    case card(UUID)
}

@MainActor
@Observable
final class MissionMapSelection {
    private(set) var target: MissionMapSelectionTarget?

    /// The selected line, if the selection is a line.
    var edgeID: UUID? {
        guard case .edge(let id) = target else { return nil }
        return id
    }

    /// The selected card, if the selection is a card.
    var cardID: UUID? {
        guard case .card(let id) = target else { return nil }
        return id
    }

    /// Selects a line, replacing any selected card.
    func selectEdge(_ id: UUID) {
        target = .edge(id)
    }

    /// Selects a card, replacing any selected line.
    func selectCard(_ id: UUID) {
        target = .card(id)
    }

    func clear() {
        target = nil
    }

    /// Clears the selection if its target is no longer on the map -- a
    /// selected card whose pane closed, a selected line that expired --
    /// so Escape never spends a press on an invisible selection. Returns
    /// whether it cleared.
    @discardableResult
    func prune(cards: Set<UUID>, edges: Set<UUID>) -> Bool {
        let present: Bool
        switch target {
        case nil: return false
        case .edge(let id): present = edges.contains(id)
        case .card(let id): present = cards.contains(id)
        }
        guard !present else { return false }
        target = nil
        return true
    }
}

/// The ids of what can be selected on the map right now, reported so a
/// selection whose target left can be pruned
/// (`MissionMapSelection.prune(cards:edges:)`).
struct MissionMapSelectableIDs: Equatable, Sendable {
    let cards: Set<UUID>
    let edges: Set<UUID>
}
