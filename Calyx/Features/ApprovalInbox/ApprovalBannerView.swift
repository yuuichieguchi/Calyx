// ApprovalBannerView.swift
// Calyx
//
// SwiftUI view for the Cockpit approval banner: shown when
// `model.current` is non-nil (see ApprovalBannerModel's own file header
// for the full ownership/visibility rules), hosted by the floating
// approval panel's `ApprovalPanelContentView.body` (`ApprovalPanelWindow`,
// Calyx/Features/ApprovalInbox/) -- an independent window, not a strip
// of the terminal window's own content.
//
// `request` is threaded in explicitly (rather than read from
// `model.current` inside `body`) so this view's content is never itself
// optional -- MainContentView already unwraps `model.current` once to
// decide whether to show this view at all.
//
// A macOS-notification-style shell, at `ApprovalPanelArranger.fixedWidth`
// or, for a request wanting inline option rows (`ApprovalRequest.
// prefersWideApprovalPanel`), `wideWidth`: the app icon on the left, a
// leading column (header row, a 1-2-line body, and any source-specific
// extras) in the middle, and a fixed-width trailing column holding one
// primary action button and an "Options" pull-down menu
// (`ApprovalActionColumn`) listing every choice the CLI offers beyond
// that primary action -- one `HStack(alignment: .center, spacing: 10)`
// (icon, then a `switch` over `request.source`), all sharing the same
// outer padding/`container` identifier applied once below the `switch`
// -- never more than one `container`-identified element per render.
//
// - `.mcpTool` (Calyx's own pane_run approval): entirely inline here --
//   `toolLeftColumn` (header row + tappable body + expanded payload) and
//   an `ApprovalActionColumn` whose primary is "Allow" and whose menu
//   lists "Always Allow"/"Deny".
// - `.agentHook` (a CLI agent's own PermissionRequest-gated tool call):
//   the SAME `toolLeftColumn` (its body is the hook call's own
//   `summary`, `ApprovalRequest.displayPayload` already picks the right
//   field per source) beside an `ApprovalActionColumn` fed by
//   `agentHookPrimaryButton`/`agentHookMenuItems(toolName:offers:)`, this
//   file's own "Yes" primary button and its menu items (one row per
//   `AgentHookOffers.permissionUpdates` offer, Calyx's own pane-scoped
//   Always-Allow row only when the CLI sent none of its own, "No").
// - `.mcpApp` (an MCP Apps view's `ui/open-link`/`ui/message` consent
//   prompt): the SAME `toolLeftColumn` (its body is the URL, the folded
//   message preview, or the copy-only explanation) beside an
//   `ApprovalActionColumn` fed by `mcpAppPrimaryButton(kind:)`/
//   `mcpAppMenuItems(kind:)`: "Open"/"Send"/"Copy" primary; the menu
//   lists "Always Allow for This View" and "Cancel"/"Don't Send" for a
//   link/message, and only "Dismiss" for a pane-less copy.
// - `.agentQuestion` (Claude Code's AskUserQuestion): `AgentQuestionBannerView`
//   renders its OWN full two-column row (it owns `AgentQuestionFormState`
//   and the free-text fields' focus state, which a stateless provider
//   cannot safely expose to a separate render pass -- see that view's
//   own file header), taking this shell's `headerRow` as its `header`
//   parameter so the tool/target label and queue navigator still read
//   identically across every source. The app icon sits in this shell's
//   own root `HStack`, to the left of that two-column row, same as the
//   other sources.
//
// `AgentQuestionBannerView` is given `.id(request.id)`, so a different
// request tears its whole subtree (and `form`) down and creates a fresh
// one -- this shell keeps no request-specific `@State` of its own at
// all: the tap-to-pin-expanded body toggle shared by `.mcpTool`/
// `.agentHook`/`.mcpApp` lives in `ExpandableBodyText` instead, reset by that same
// `.id(request.id)`. The dismiss button (`isPanelHovered`, its
// show-on-hover state) lives in `ApprovalPanelContentView`, not here --
// see that file's own header for why. Every action routes through plain
// closures into `model`.
//
// Queue navigation: while `model.positionInfo.count > 1`, a Previous/
// Next chevron pair + "N / M" position label (see
// `queueNavigator(positionInfo:)`) renders on the header row -- the
// browse-then-decide loop (glance at each queued command, then click
// Previous/Next to compare before deciding) keeps the mouse in one
// place; the sequential loop never needs the arrows at all thanks to
// advance-on-decide (see ApprovalBannerModel.advanceCursor(
// pastDisplayed:excluding:)'s own doc comment). Drives
// `ApprovalBannerModel`'s own `selectedRequestID` cursor -- a single
// queued request renders no navigator at all, since there is nothing to
// step to.

import SwiftUI
import AppKit

struct ApprovalBannerView: View {
    let model: ApprovalBannerModel
    let request: ApprovalRequest
    /// The designated host window's active tab title, for a
    /// window-agnostic (nil `targetSurfaceID`) request's header (see
    /// `targetLabel`'s own doc comment). Already rendered through
    /// `ControlCharacterDisplay.render` by the caller
    /// (`ApprovalPanelContentView.glassWrapped(request:)`).
    let hostWindowTitle: String
    /// The owning tab's `displayTitle` for a surface-targeted request
    /// (see `targetLabel`'s own doc comment), nil if no open window owns
    /// the surface -- supplied by `ApprovalPanelContentView.
    /// glassWrapped(request:)`, itself threaded from `ApprovalPanelController`'s
    /// own init. RAW, unescaped: `targetLabel` renders it through
    /// `ControlCharacterDisplay.render` itself, same as `toolName`.
    let targetTabTitle: (UUID) -> String?

    /// Routed through `ControlCharacterDisplay.render` same as
    /// `request.displayPayload` below -- `displayToolName` comes from the
    /// same untrusted tool-call provenance as `displayPayload`, so it
    /// must not be able to smuggle a hidden/spoofing payload into the
    /// header just because it's a different field on `ApprovalRequest`.
    private var toolName: String {
        ControlCharacterDisplay.render(request.displayToolName)
    }

    /// The owning tab's own `displayTitle` for a surface-targeted
    /// request (`targetTabTitle(targetSurfaceID)`, routed through
    /// `ControlCharacterDisplay.render` here, same as `toolName`),
    /// falling back to the first 8 characters of the target surface's
    /// UUID when no open window owns it, OR when the owning tab's title
    /// renders as an empty string (a tab title can be set to "" via OSC;
    /// an empty header label is worse than the UUID fallback, so an
    /// empty rendered title is treated the same as "no title at all")
    /// (enough to disambiguate panes at a glance without printing a full
    /// UUID into the banner) -- or the designated host window's own
    /// active tab title for a window-agnostic (nil targetSurfaceID)
    /// request (e.g. `palette_execute`, which carries no target pane at
    /// all). `targetTabTitle(targetSurfaceID)` reads the owning `Tab`'s
    /// own `displayTitle`, itself `@Observable`, during body evaluation,
    /// so SwiftUI tracks that read directly and re-renders this view on
    /// rename -- the same mechanism `ApprovalPanelContentView
    /// .glassWrapped(request:)`'s own doc comment describes for the host
    /// window title.
    private var targetLabel: String {
        guard let targetSurfaceID = request.targetSurfaceID else { return hostWindowTitle }
        if let title = targetTabTitle(targetSurfaceID) {
            let rendered = ControlCharacterDisplay.render(title)
            if !rendered.isEmpty { return rendered }
        }
        return String(targetSurfaceID.uuidString.prefix(8))
    }

    private var headerText: String {
        "\(toolName) → \(targetLabel)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            appIcon
            switch request.source {
            case .mcpTool:
                toolLeftColumn
                ApprovalActionColumn(primary: AnyView(mcpPrimaryButton)) { mcpMenuItems }

            case .agentHook(let toolName, _, _, let offers):
                toolLeftColumn
                ApprovalActionColumn(primary: AnyView(agentHookPrimaryButton)) {
                    agentHookMenuItems(toolName: toolName, offers: offers)
                }

            case .mcpApp(_, _, let kind):
                toolLeftColumn
                ApprovalActionColumn(primary: AnyView(mcpAppPrimaryButton(kind: kind))) {
                    mcpAppMenuItems(kind: kind)
                }

            case .agentQuestion(_, let prompt):
                AgentQuestionBannerView(
                    prompt: prompt,
                    onAnswer: { answers in model.answer(id: request.id, answers: answers) },
                    onChatAboutQuestion: { model.chatAboutQuestion(id: request.id) },
                    onTextFieldRemoved: { model.restoreTerminalFocusAfterInput(targetSurfaceID: request.targetSurfaceID) },
                    header: AnyView(headerRow)
                )
                .id(request.id)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ApprovalBanner.container)
    }

    /// The app icon, matching a macOS notification banner's own leading
    /// icon -- shared by every `request.source` case, including
    /// `.agentQuestion` (whose own two-column row renders only the
    /// middle/trailing columns; this shell supplies the icon for it too).
    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: 40, height: 40)
            .accessibilityHidden(true)
    }

    // MARK: - `.mcpTool`/`.agentHook`/`.mcpApp`: shared left column

    /// `headerRow`, the tappable 2-line body (`request.displayPayload`
    /// -- `payload` for `.mcpTool`, the hook call's own `summary` for
    /// `.agentHook`, `MCPAppConsentKind.displayText` for `.mcpApp`), and
    /// the tap-to-pin-expanded payload
    /// (`ExpandableBodyText`, shared with `AgentQuestionBannerView`'s own
    /// question text).
    private var toolLeftColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            headerRow
            ExpandableBodyText(
                text: ControlCharacterDisplay.render(request.displayPayload),
                collapsedFont: .system(size: 12),
                collapsedIdentifier: AccessibilityID.ApprovalBanner.payload,
                expandedFont: .system(.callout, design: .monospaced),
                collapsedForegroundIsSecondary: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - `.mcpTool`: primary button + menu items

    private var mcpPrimaryButton: some View {
        Button("Allow") { model.allow(id: request.id) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowButton)
    }

    @ViewBuilder
    private var mcpMenuItems: some View {
        Button(Self.menuRowTitle("Always Allow")) { model.alwaysAllow(id: request.id) }
        Button(Self.menuRowTitle("Deny")) { model.deny(id: request.id) }
    }

    // MARK: - `.agentHook`: primary button + menu items

    /// Primary: "Yes". Unlike `mcpPrimaryButton`/`mcpMenuItems`, this
    /// source's action column also needs `toolName`/`offers` (both carried
    /// by `request.source` itself, unpacked at the `.agentHook` switch
    /// case), which is why the menu half below is a function rather than
    /// a plain computed property.
    private var agentHookPrimaryButton: some View {
        Button("Yes") { model.allow(id: request.id) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowButton)
    }

    /// Menu, mirroring the CLI's own dialog order: one row per
    /// `AgentHookOffers.permissionUpdates` always-allow suggestion
    /// (already labeled by `AgentPermissionOffer.label(for:)`), Calyx's
    /// own pane-scoped Always-Allow row only when the CLI doesn't already
    /// own persisting that choice itself (`offers.cliOwnsPersistence`),
    /// "No". See `AgentHookOffers.cliOwnsPersistence`'s own doc comment
    /// for why that flag is what decides whether Calyx's row renders.
    @ViewBuilder
    private func agentHookMenuItems(toolName: String, offers: AgentHookOffers) -> some View {
        ForEach(Array(offers.permissionUpdates.enumerated()), id: \.offset) { _, offer in
            Button(Self.menuRowTitle(offer.label)) {
                model.allowWithPermissions(id: request.id, offer: offer)
            }
        }

        if !offers.cliOwnsPersistence {
            Button(Self.menuRowTitle("Always Allow \(toolName) in This Pane")) {
                model.alwaysAllow(id: request.id)
            }
        }

        Button(Self.menuRowTitle("No")) {
            model.deny(id: request.id)
        }
    }

    // MARK: - `.mcpApp`: primary button + menu items

    /// Primary: "Open" for a link, "Send" for a message, "Copy" for a
    /// pane-less message -- all `model.allow(id:)`, which the runtime maps
    /// to opening, sending, or writing the pasteboard.
    private func mcpAppPrimaryButton(kind: MCPAppConsentKind) -> some View {
        let title: String
        switch kind {
        case .openLink: title = "Open"
        case .sendMessage: title = "Send"
        case .copyMessage: title = "Copy"
        }
        return Button(title) { model.allow(id: request.id) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.allowButton)
    }

    /// Menu: "Always Allow for This View" (`model.allowForView(id:)`) and
    /// "Cancel"/"Don't Send" (`model.deny(id:)`) for a link/message; only
    /// "Dismiss" (`model.deny(id:)`) for a pane-less copy, which has no
    /// view-scoped allowance to offer.
    @ViewBuilder
    private func mcpAppMenuItems(kind: MCPAppConsentKind) -> some View {
        switch kind {
        case .openLink:
            Button(Self.menuRowTitle("Always Allow for This View")) { model.allowForView(id: request.id) }
            Button(Self.menuRowTitle("Cancel")) { model.deny(id: request.id) }
        case .sendMessage:
            Button(Self.menuRowTitle("Always Allow for This View")) { model.allowForView(id: request.id) }
            Button(Self.menuRowTitle("Don't Send")) { model.deny(id: request.id) }
        case .copyMessage:
            Button(Self.menuRowTitle("Dismiss")) { model.deny(id: request.id) }
        }
    }

    // MARK: - Header row (shared by every source)

    /// `headerText` (the tool name/target label), then the queue
    /// navigator when more than one request is queued for this window.
    /// Truncates at the END, matching a macOS notification title -- the
    /// tool name always survives, only the (already-disambiguating,
    /// prefix-visible) target label loses its tail when the row is too
    /// narrow.
    private var headerRow: some View {
        HStack {
            Text(headerText)
                .font(.system(size: 13, weight: .bold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let positionInfo = model.positionInfo, positionInfo.count > 1 {
                queueNavigator(positionInfo: positionInfo)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }

    /// Previous/Next chevron pair + "N / M" position label, rendered by
    /// `headerRow` trailing `headerText`. Shown only while more than one
    /// request is queued for this window (see the call site's own
    /// `positionInfo.count > 1` gate) -- mirrors `BrowserToolbarView`'s
    /// own chevron.left/chevron.right precedent
    /// (Calyx/Views/Browser/BrowserContainerView.swift). The label
    /// itself is a `Menu` wrapping the same "N / M" `Text`, listing this
    /// window's queued requests oldest-first (see
    /// `queueMenuItems`); clicking a row jumps straight to that request
    /// via `model.select(id:)`.
    ///
    /// That same "N / M" text is ALSO set as the `Menu`'s own
    /// `.accessibilityLabel`: on macOS SwiftUI collapses a `Menu` into a
    /// single pop-up element that surfaces neither the identifier nor
    /// the text of the views inside its label closure (field-verified --
    /// an XCUITest lookup for `AccessibilityID.ApprovalBanner.
    /// positionLabel` matched no element of any type while that
    /// identifier sat only on the inner `Text`), so the explicit label
    /// is what carries the position into the accessibility tree at all.
    /// The inner `Text` keeps that identifier, which the collapse leaves
    /// inert. `.buttonStyle(.borderless)` on the chevrons +
    /// `.menuStyle(.borderlessButton)` on the `Menu` + `.controlSize(
    /// .small)` + `.fixedSize()` throughout keep this content-hugging, so
    /// it never stretches the banner's header row. Disabled states are
    /// derived directly from the passed `positionInfo` (`index <= 1` /
    /// `index >= count`) rather than a separate `model.
    /// canSelectPrevious`/`canSelectNext` read -- one source (the same
    /// `positionInfo` already used for the label) for both the label and
    /// the chevrons' enabled state, rather than two independently-
    /// computed answers that could in principle disagree.
    /// `canSelectPrevious`/`canSelectNext` stay public on the model
    /// regardless -- `selectNext()`/`selectPrevious()` still guard on
    /// them internally, and CalyxTests/ApprovalInbox/
    /// ApprovalBannerModelTests.swift asserts them directly.
    private func queueNavigator(positionInfo: (index: Int, count: Int)) -> some View {
        HStack(spacing: 8) {
            Button(action: { model.selectPrevious() }) {
                Image(systemName: "chevron.left")
            }
            .disabled(positionInfo.index <= 1)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.previousButton)

            Menu {
                queueMenuItems
            } label: {
                Text("\(positionInfo.index) / \(positionInfo.count)")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityID.ApprovalBanner.positionLabel)
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.queueMenu)
            .accessibilityLabel(Text("\(positionInfo.index) / \(positionInfo.count)"))

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

    /// The queue preview menu's rows: one clickable
    /// `queueEntryLabel(_:)` per request `model.queueEntries` reports,
    /// oldest-first, with every entry listed. `NSMenu` scrolls a menu
    /// whose items do not fit on screen, so even a long backlog stays
    /// operable. No cap trimming the list from the front is applied:
    /// with the cursor past such a cap, neither the current row (the one
    /// carrying "▸") nor its neighbors would be drawn at all, leaving
    /// nothing in the menu to jump to them by -- and a backlog that
    /// large is exactly when this list is worth more than the chevrons.
    @ViewBuilder
    private var queueMenuItems: some View {
        ForEach(model.queueEntries) { entry in
            Button(queueEntryLabel(entry)) {
                model.select(id: entry.id)
            }
        }
    }

    /// A queue preview menu row's label: `"N. <rendered previewLine>"`,
    /// prefixed with "▸ " for the entry matching the currently displayed
    /// request, so the current page reads clearly at a glance among the
    /// rest of this window's backlog. `ControlCharacterDisplay.render`
    /// on `previewLine`, same untrusted-provenance caveat as `toolName`/
    /// `payloadText` above. Any literal newline the rendered text still
    /// carries folds to a space here: an `NSMenuItem` draws a newline in
    /// its title as a real line break, turning one row into a multi-line
    /// one. The only literal newline `render` can return is its own
    /// truncation suffix's leading one -- every C0 control in the input,
    /// U+000A included, comes back as caret notation, and line/paragraph
    /// separators come back as `<U+XXXX>` tokens.
    /// The finished row is fitted to `menuRowWidth` by
    /// `fittedToMenuWidth(_:)` rather than left as wide as its character
    /// count happens to draw -- the width cap must apply to the WHOLE
    /// prefixed row ("N. "/"▸ " included), so this does its own render+
    /// fold+fit rather than delegating to `menuRowTitle(_:)` (which fits
    /// its argument alone, before any prefix a caller might add).
    private func queueEntryLabel(_ entry: ApprovalBannerModel.QueueEntry) -> String {
        let rendered = ControlCharacterDisplay.render(entry.previewLine).replacingOccurrences(of: "\n", with: " ")
        let label = "\(entry.position). \(rendered)"
        let row = entry.isCurrent ? "▸ \(label)" : label
        return Self.fittedToMenuWidth(row)
    }

    /// Every "Options" pull-down's own row title -- claude-code-choice
    /// labels, permission-suggestion labels, question option labels/
    /// descriptions -- goes through this: `ControlCharacterDisplay.
    /// render`, fold any literal newline to a space (an `NSMenuItem`
    /// draws one as a real line break), then `fittedToMenuWidth(_:)`.
    /// Shared by `AgentQuestionBannerView` (in the same module, so
    /// `ApprovalBannerView.menuRowTitle(_:)` is a plain cross-file call,
    /// no protocol needed) as well as this file's own `.mcpTool`/
    /// `.agentHook`/`.mcpApp` menu items.
    static func menuRowTitle(_ text: String) -> String {
        let rendered = ControlCharacterDisplay.render(text).replacingOccurrences(of: "\n", with: " ")
        return fittedToMenuWidth(rendered)
    }

    /// The width, in points, a menu row is bounded to. A character count
    /// bounds how wide a row DRAWS only for one script: the same count is
    /// roughly 560pt of ASCII and roughly 1040pt of CJK, so the menu's
    /// width swung with whatever the payload happened to contain.
    /// Measuring in points is what actually bounds it.
    private static let menuRowWidth: CGFloat = 450

    /// Elides `row` in the MIDDLE until it draws within `menuRowWidth` in
    /// the menu font, keeping its tail: the end of a path or a command is
    /// usually what distinguishes one queued request (or choice) from
    /// another, and a trailing ellipsis drops exactly that. Binary search
    /// for the widest kept-`Character` count that fits, appending whole
    /// `Character`s only so a grapheme cluster is never split.
    private static func fittedToMenuWidth(_ row: String) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        func width(_ text: String) -> CGFloat { text.size(withAttributes: attributes).width }
        guard width(row) > menuRowWidth else { return row }

        let characters = Array(row)
        func elided(keeping keptCount: Int) -> String {
            let headCount = (keptCount + 1) / 2
            return String(characters.prefix(headCount)) + "…" + String(characters.suffix(keptCount - headCount))
        }

        var low = 0
        var high = characters.count - 1
        while low < high {
            let candidate = (low + high + 1) / 2
            if width(elided(keeping: candidate)) <= menuRowWidth {
                low = candidate
            } else {
                high = candidate - 1
            }
        }
        return elided(keeping: low)
    }
}

/// The notification shell's own trailing column, shared by every
/// `request.source` case: a primary action (optional -- `nil` renders
/// no button at all, only the menu, e.g. an `.agentQuestion` whose
/// single-select click already confirms without a separate confirm
/// step) above an "Options" pull-down listing every other choice, both
/// `.buttonStyle(.bordered)` -- a native notification never emphasizes
/// one action over the other. `.frame(maxWidth: .infinity)` on both
/// controls, inside a column fixed to `width`, is what keeps them the
/// same width as each other -- `.fixedSize()` would defeat that by
/// letting each control hug its own content instead. The root shell's
/// own `HStack(alignment: .center)` centers this column vertically
/// against the body.
struct ApprovalActionColumn<Items: View>: View {
    static var width: CGFloat { 80 }

    let primary: AnyView?
    @ViewBuilder let menuItems: () -> Items

    var body: some View {
        VStack(spacing: 6) {
            if let primary {
                primary
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            Menu {
                menuItems()
            } label: {
                Text("Options")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier(AccessibilityID.ApprovalBanner.optionsMenu)
            .accessibilityLabel(Text("Options"))
        }
        .frame(width: Self.width)
    }
}
