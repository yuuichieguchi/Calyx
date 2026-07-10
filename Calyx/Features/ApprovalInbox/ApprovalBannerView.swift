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
//
// Stage E: an `.agentHook`-sourced request (a CLI agent's PreToolUse
// hook call, see `ApprovalRequest.Source`) renders the same Deny/Always
// Allow/Allow row as an `.mcpTool`-sourced one, PLUS a compact
// cross-actions menu (see `crossActionsMenu(toolName:)`) with two
// broader actions. An `.mcpTool`-sourced request renders exactly as
// before -- no menu.

import SwiftUI

struct ApprovalBannerView: View {
    let model: ApprovalBannerModel
    let request: ApprovalRequest

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Routed through `ControlCharacterDisplay.render` same as
    /// `request.displayPayload` below -- `displayToolName` comes from the
    /// same untrusted tool-call provenance as `displayPayload`, so it
    /// must not be able to smuggle a hidden/spoofing payload into the
    /// header just because it's a different field on `ApprovalRequest`.
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

    /// Stage E: the CLI's own tool name alone (e.g. "Bash"), NOT
    /// `displayToolName`'s "Kind · toolName" combination -- used only by
    /// the cross-actions menu's "Always Allow <toolName> in All Panes"
    /// label below. `nil` for an `.mcpTool`-sourced request, which never
    /// shows that menu at all. Routed through `ControlCharacterDisplay.render`
    /// same as `toolName` above -- it comes from the same untrusted
    /// tool-call provenance.
    private var agentHookToolNameForMenu: String? {
        guard case .agentHook(let toolName, _, _) = request.source else { return nil }
        return ControlCharacterDisplay.render(toolName)
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

                // Stage E: only an `.agentHook`-sourced request has a
                // cross-actions menu -- `.mcpTool` renders exactly as
                // before it (no menu at all).
                if let menuToolName = agentHookToolNameForMenu {
                    crossActionsMenu(toolName: menuToolName)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .modifier(RecoveryBarBackgroundModifier(reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.container)
    }

    /// Compact cross-actions menu, shown only for an `.agentHook`-sourced
    /// request (see `agentHookToolNameForMenu`): two actions that go
    /// beyond this single request's own Deny/Always Allow/Allow --
    /// "Allow All Pending" drains every pending request store-wide, and
    /// "Always Allow ... in All Panes" records CROSS Always-Allow memory
    /// for this tool. Kept content-hugging (`.fixedSize()`), same
    /// rationale as `payloadView`'s own header comment, so the menu's
    /// compact ellipsis label never stretches the banner's action row.
    private func crossActionsMenu(toolName: String) -> some View {
        Menu {
            Button("Allow All Pending (\(model.totalPendingCount))") {
                model.allowAllPending()
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowAllPendingItem)

            Button("Always Allow \(toolName) in All Panes") {
                model.alwaysAllowAcrossPanes(id: request.id)
            }
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.alwaysAllowAllPanesItem)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.crossActionsMenu)
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
        Text(ControlCharacterDisplay.render(request.displayPayload))
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.payload)
    }
}
