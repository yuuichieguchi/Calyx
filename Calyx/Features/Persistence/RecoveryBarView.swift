// RecoveryBarView.swift
// Calyx
//
// Chrome-style in-app "your previous session was preserved" bar,
// shown at the top of a window's content when `model.showRecoveryBar`
// is true (see RecoveryBarModel's own file header for the full
// design-decision writeup). Hosted as the first child of
// MainContentView's top-level VStack, above the tab bar/pane content --
// never intercepts first responder/keyboard focus, since neither the
// bar nor its buttons are ever made first responder by any code path.

import SwiftUI

struct RecoveryBarView: View {
    let model: RecoveryBarModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Your previous session was preserved.")
                .font(.callout)

            Spacer()

            Button("Restore") {
                model.restore()
            }
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.restoreButton)

            Button("Dismiss") {
                model.dismiss()
            }
            .accessibilityIdentifier(AccessibilityID.RecoveryBar.dismissButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.RecoveryBar.container)
    }
}
