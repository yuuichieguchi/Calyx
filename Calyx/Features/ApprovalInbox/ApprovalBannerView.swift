// ApprovalBannerView.swift
// Calyx
//
// SwiftUI view for the Cockpit approval banner: shown at the top of a
// window's content when `model.current` is non-nil (see
// ApprovalBannerModel's own file header for the full ownership/
// visibility rules). Hosted via `MainContentView.body`'s
// `mainContent.safeAreaInset(edge: .top)`, stacked with RecoveryBarView
// -- see RecoveryBarView's own file header for why neither bar is ever
// made first responder.
//
// `request` is threaded in explicitly (rather than read from
// `model.current` inside `body`) so this view's content is never itself
// optional -- MainContentView already unwraps `model.current` once to
// decide whether to show this view at all.

import SwiftUI

struct ApprovalBannerView: View {
    let model: ApprovalBannerModel
    let request: ApprovalRequest

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Routed through `ControlCharacterDisplay.render` same as
    /// `request.payload` below -- `name` comes from the same untrusted
    /// MCP-tool-call provenance as `payload`, so it must not be able to
    /// smuggle a hidden/spoofing payload into the header just because
    /// it's a different field on `ApprovalRequest`.
    private var toolName: String {
        switch request.source {
        case .mcpTool(let name): return ControlCharacterDisplay.render(name)
        }
    }

    /// Short, human-scannable target label -- the first 8 characters of
    /// the target surface's UUID (enough to disambiguate panes at a
    /// glance without printing a full UUID into the banner), or "this
    /// window" for a window-agnostic (nil targetSurfaceID) request.
    private var targetLabel: String {
        guard let targetSurfaceID = request.targetSurfaceID else { return "this window" }
        return String(targetSurfaceID.uuidString.prefix(8))
    }

    private var headerText: String {
        let pendingCount = model.pendingCountForWindow
        let base = "\(toolName) → \(targetLabel)"
        guard pendingCount > 1 else { return base }
        return base + " (\(pendingCount) pending)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headerText)
                .font(.callout)
                .fontWeight(.semibold)

            ScrollView {
                Text(ControlCharacterDisplay.render(request.payload))
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payload)
            }
            .frame(maxHeight: 120)

            HStack {
                Spacer()

                Button("Deny") {
                    model.deny(id: request.id)
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.denyButton)

                Button("Always Allow") {
                    model.alwaysAllow(id: request.id)
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.alwaysAllowButton)

                Button("Allow") {
                    model.allow(id: request.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowButton)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.container)
    }
}
