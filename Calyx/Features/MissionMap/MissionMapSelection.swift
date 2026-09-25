// MissionMapSelection.swift
// Calyx
//
// Mission Map's selected line. Owned by `CalyxWindowController` rather
// than kept as `MissionMapView` state, because the selected line's
// popover is drawn outside the map's SwiftUI tree (`MissionMapPopoverHost`)
// and a tap on it must clear the selection from there.

import Foundation

@MainActor
@Observable
final class MissionMapSelection {
    var edgeID: UUID?
}
