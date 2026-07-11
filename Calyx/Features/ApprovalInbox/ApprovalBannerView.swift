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
//
// Queue navigation: while `model.positionInfo.count > 1`, a Previous/
// Next chevron pair + "N / M" position label (see
// `queueNavigator(positionInfo:)`) renders at the action cluster's
// leading edge, adjacent to the decision buttons -- the browse-then-
// decide loop keeps the mouse in one place; the sequential loop never
// needs the arrows at all thanks to advance-on-decide (see
// ApprovalBannerModel.advanceCursor(pastDisplayed:excluding:)'s own doc
// comment). Drives `ApprovalBannerModel`'s own `selectedRequestID`
// cursor -- a single queued request renders no navigator at all, since
// there is nothing to step to.

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
    /// `displayToolName`'s "Kind · toolName" combination -- used to title
    /// BOTH the main action row's pane-scoped "Always Allow <toolName> in
    /// This Pane" button (see `alwaysAllowButtonTitle` below) and the
    /// cross-actions menu's "Always Allow <toolName> in All Panes" label,
    /// so the two actions read as a parallel This-Pane/All-Panes contrast
    /// naming the same tool. `nil` for an `.mcpTool`-sourced request,
    /// which never shows the menu and keeps the main button's plain
    /// "Always Allow" label (see `alwaysAllowButtonTitle`). Routed through
    /// `ControlCharacterDisplay.render` same as `toolName` above -- it
    /// comes from the same untrusted tool-call provenance.
    private var agentHookToolName: String? {
        guard case .agentHook(let toolName, _, _) = request.source else { return nil }
        return ControlCharacterDisplay.render(toolName)
    }

    /// Stage E: the main action row's middle button's label. For an
    /// `.agentHook`-sourced request, `model.alwaysAllow(id:)` records
    /// PANE-scoped memory (this tool, THIS pane) -- so the label names
    /// the tool and says "This Pane" to contrast with the cross-actions
    /// menu's "Always Allow <toolName> in All Panes" item, which records
    /// CROSS memory instead. For an `.mcpTool`-sourced request the same
    /// button flips the global cockpit auto-approve toggle, so it keeps
    /// the unqualified "Always Allow" label.
    private var alwaysAllowButtonTitle: String {
        guard let agentHookToolName else { return "Always Allow" }
        return "Always Allow \(agentHookToolName) in This Pane"
    }

    private var headerText: String {
        "\(toolName) → \(targetLabel)"
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
                // Queue navigation: leading edge of this action cluster,
                // immediately adjacent to Deny/Always Allow/Allow -- the
                // browse-then-decide loop (glance at each queued
                // command, then click Previous/Next to compare before
                // deciding) keeps the mouse in one place instead of
                // ping-ponging across the banner's full width to a
                // header-area control. The purely sequential loop (just
                // clicking Allow/Deny down the queue) never needs the
                // arrows at all, since advance-on-decide already moves
                // the cursor forward on every decision (see
                // ApprovalBannerModel.advanceCursor(pastDisplayed:
                // excluding:)'s own doc comment). Only shown while more
                // than one request is queued for this window (a single
                // request has nothing to navigate to) -- see
                // ApprovalBannerModel.positionInfo's own doc comment.
                // Single source for the gate: `positionInfo.count`
                // (derived from the same `visibleRequests` model.
                // pendingCountForWindow itself counts), rather than also
                // reading `model.pendingCountForWindow` here.
                if let positionInfo = model.positionInfo, positionInfo.count > 1 {
                    queueNavigator(positionInfo: positionInfo)
                        .padding(.trailing, 8)
                }

                Button("Deny") {
                    model.deny(id: request.id)
                }
                .controlSize(.small)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.denyButton)

                Button(alwaysAllowButtonTitle) {
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
                if let menuToolName = agentHookToolName {
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

    /// Previous/Next chevron pair + "N / M" position label, rendered at
    /// the leading edge of the trailing action `HStack` (see this file's
    /// own header comment for why it sits there, adjacent to Deny/
    /// Always Allow/Allow, rather than up in the header area), shown
    /// only while more than one request is queued for this window (see
    /// the call site's own `positionInfo.count > 1` gate) -- mirrors
    /// `BrowserToolbarView`'s own chevron.left/chevron.right precedent
    /// (Calyx/Views/Browser/BrowserContainerView.swift).
    /// `.buttonStyle(.borderless)` + `.controlSize(.small)` +
    /// `.fixedSize()` keep this content-hugging, same rationale as
    /// `crossActionsMenu`'s own header comment, so it never stretches
    /// the banner's action row. Disabled states are derived directly
    /// from the passed `positionInfo` (`index <= 1` / `index >= count`)
    /// rather than a separate `model.canSelectPrevious`/`canSelectNext`
    /// read -- one source (the same `positionInfo` already used for the
    /// label) for both the label and the chevrons' enabled state, rather
    /// than two independently-computed answers that could in principle
    /// disagree. `canSelectPrevious`/`canSelectNext` stay public on the
    /// model regardless -- `selectNext()`/`selectPrevious()` still guard
    /// on them internally, and CalyxTests/ApprovalInbox/
    /// ApprovalBannerModelTests.swift asserts them directly.
    private func queueNavigator(positionInfo: (index: Int, count: Int)) -> some View {
        HStack(spacing: 8) {
            Button(action: { model.selectPrevious() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(positionInfo.index <= 1)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.previousButton)

            Text("\(positionInfo.index) / \(positionInfo.count)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.ApprovalBanner.positionLabel)

            Button(action: { model.selectNext() }) {
                Image(systemName: "chevron.right")
            }
            .disabled(positionInfo.index >= positionInfo.count)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.nextButton)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
    }

    /// Compact cross-actions menu, shown only for an `.agentHook`-sourced
    /// request (see `agentHookToolName`): two actions that go
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
