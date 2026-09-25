// MissionMapEscHint.swift
// Calyx
//
// The "esc to close" hint in Mission Map's bottom-right corner. A click
// on empty map space only clears the selection, so Escape is the way out
// of the map (besides the menu/shortcut toggle); this says so.

import SwiftUI

struct MissionMapEscHint: View {
    /// From the map's bottom and trailing edges.
    static let inset: CGFloat = 16

    var body: some View {
        Text("esc to close")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(Self.inset)
            .allowsHitTesting(false)
            .accessibilityIdentifier(AccessibilityID.MissionMap.escHint)
    }
}
