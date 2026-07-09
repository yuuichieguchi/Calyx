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
    /// `request.payload` below -- `displayToolName` comes from the same
    /// untrusted tool-call provenance as `payload`, so it must not be
    /// able to smuggle a hidden/spoofing payload into the header just
    /// because it's a different field on `ApprovalRequest`.
    private var toolName: String {
        ControlCharacterDisplay.render(request.displayToolName)
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
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerText)
                    .font(.callout)
                    .fontWeight(.semibold)

                payloadView
            }

            Spacer(minLength: 16)

            HStack {
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
        .padding(.vertical, 6)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.container)
    }

    /// Content-hugging payload: a one-line command must never reserve
    /// blank space (a ScrollView is normally GREEDY -- it claims its
    /// full proposed height even when its content is a single short
    /// line, which is what made the banner a mostly-blank band before
    /// this fix). `.fixedSize(vertical: true)` makes the ScrollView
    /// report its CONTENT height upward into this view's parent instead
    /// of the proposed one, so a one-line payload renders one line tall;
    /// `.frame(maxHeight: 120)`, applied BEFORE `.fixedSize` (so it
    /// clamps what content height gets reported), caps that at ~120pt so
    /// a long payload (bounded at 2000 characters by
    /// `ControlCharacterDisplay.render`'s own cap) still scrolls instead
    /// of growing the banner unbounded. Deliberately not
    /// `ViewThatFits(in: .vertical)` (an earlier attempt): a `.frame(
    /// maxHeight:)` wrapping the whole `ViewThatFits` proposes that same
    /// ~120pt height to WHICHEVER branch is chosen, including a
    /// plain-text branch -- floating a short line inside a still-120pt
    /// box instead of shrinking to it.
    private var payloadView: some View {
        ScrollView(.vertical) { payloadText }
            .frame(maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var payloadText: some View {
        Text(ControlCharacterDisplay.render(request.payload))
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payload)
    }
}
