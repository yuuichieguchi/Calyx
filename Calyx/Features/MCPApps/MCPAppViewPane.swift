//
//  MCPAppViewPane.swift
//  Calyx
//
//  One view's card: a header (title, state, CSP warning, Close), an
//  in-card prompt for consent, and the content area showing either the
//  web view or a status card (loading, waiting for the app, an error with
//  Retry, stopped with Reload and Close, upstream disconnected).
//

import AppKit
import WebKit

@MainActor
final class MCPAppViewPane: NSView {

    static let headerHeight: CGFloat = 28
    /// The prompt text's height limit; a longer text scrolls.
    static let maxPromptTextHeight: CGFloat = 120

    let viewID: UUID
    var onClose: (() -> Void)?
    var onReload: (() -> Void)?
    /// Called when the appearance, the card's size, or the content area's
    /// height (a prompt shows or hides) changes (host context inputs).
    var onEnvironmentChange: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let header = NSStackView()
    private let promptArea = NSStackView()
    private let contentArea = NSView()
    private let statusCard = NSStackView()
    private let statusMessage = NSTextField(wrappingLabelWithString: "")
    private let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    private let cardCloseButton = NSButton(title: "Close", target: nil, action: nil)
    private let borderLayerWidth: CGFloat
    private(set) weak var webView: WKWebView?
    private var promptContinuation: CheckedContinuation<MCPAppMessageConsentGate.PromptDecision, Never>?
    private weak var promptText: MCPAppPromptTextView?

    init(viewID: UUID, prefersBorder: Bool?) {
        self.viewID = viewID
        self.borderLayerWidth = MCPAppDockLayout.borderWidth(prefersBorder: prefersBorder)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = borderLayerWidth
        layer?.borderColor = NSColor.separatorColor.cgColor
        buildHeader()
        buildPrompt()
        buildStatusCard()
        let stack = NSStackView(views: [header, promptArea, contentArea])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        contentArea.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            promptArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
            contentArea.widthAnchor.constraint(equalTo: stack.widthAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEnvironmentChange?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        promptText?.wrapWidth = promptTextWidth
        if changed { onEnvironmentChange?() }
    }

    // MARK: - Content

    /// The height of the card above the content area (the web view or the
    /// status card): the header, and the prompt while it shows. The prompt's
    /// height is its fitting height, which the card's stack gives it.
    var contentTopInset: CGFloat {
        Self.headerHeight + (promptArea.isHidden ? 0 : promptArea.fittingSize.height)
    }

    func setWebView(_ webView: WKWebView?) {
        self.webView?.removeFromSuperview()
        self.webView = webView
        guard let webView else {
            showStatusCard()
            return
        }
        webView.setAccessibilityIdentifier(AccessibilityID.MCPApps.viewWeb(viewID))
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            webView.topAnchor.constraint(equalTo: contentArea.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])
    }

    func update(snapshot: MCPAppViewSnapshot, droppedCSPEntries: [(raw: String, reason: String)]) {
        titleLabel.stringValue = snapshot.title
        stateLabel.stringValue = Self.stateText(snapshot.status)
        warningLabel.isHidden = droppedCSPEntries.isEmpty
        warningLabel.stringValue = droppedCSPEntries.isEmpty ? "" :
            "Ignored CSP entries: " + droppedCSPEntries.map { "\($0.raw) (\($0.reason))" }.joined(separator: "; ")
        warningLabel.toolTip = warningLabel.stringValue

        // A mounted view stays visible while waiting, live, finished or
        // disconnected (the header carries the state); every other state,
        // and any state without a web view, shows the status card.
        let showsWebView: Bool
        switch snapshot.status {
        case .waitingForApp, .live, .completed, .cancelled, .upstreamDisconnected:
            showsWebView = webView != nil
        case .loadingResource, .resourceError, .readFailed, .stopped:
            showsWebView = false
        }
        if showsWebView {
            showWebView()
        } else {
            statusMessage.stringValue = Self.cardText(snapshot.status)
            reloadButton.isHidden = !Self.offersReload(snapshot.status)
            cardCloseButton.isHidden = !Self.offersCardClose(snapshot.status)
            showStatusCard()
        }
    }

    // MARK: - Prompts

    /// Asks whether to send a `ui/message`. Resolves as `.dontSend` if the
    /// prompt is dismissed because the view goes away or its document
    /// unloads.
    func promptForMessage(preview: String) async -> MCPAppMessageConsentGate.PromptDecision {
        resolvePrompt(.dontSend)
        return await withCheckedContinuation { continuation in
            promptContinuation = continuation
            showPrompt(
                message: "The app wants to send this message to the pane:\n\(preview)",
                buttons: [
                    ("Send", AccessibilityID.MCPApps.promptPrimaryButton, { [weak self] in self?.resolvePrompt(.send) }),
                    ("Always for This View", AccessibilityID.MCPApps.promptAllowForViewButton, { [weak self] in self?.resolvePrompt(.alwaysForThisView) }),
                    ("Don't Send", AccessibilityID.MCPApps.promptCancelButton, { [weak self] in self?.resolvePrompt(.dontSend) }),
                ]
            )
        }
    }

    /// Asks whether to open a link: a lead line, then the whole link in the
    /// prompt's text view. Resolves as `.cancel` if the prompt is dismissed
    /// because the view goes away or its document unloads.
    func promptForLink(_ url: URL) async -> MCPAppOpenLinkPolicy.PromptDecision {
        resolvePrompt(.dontSend)
        let decision = await withCheckedContinuation { continuation in
            promptContinuation = continuation
            showPrompt(
                message: "The app wants to open this link:\n\(url.absoluteString)",
                buttons: [
                    ("Open", AccessibilityID.MCPApps.promptPrimaryButton, { [weak self] in self?.resolvePrompt(.send) }),
                    ("Always Allow for This View", AccessibilityID.MCPApps.promptAllowForViewButton, { [weak self] in self?.resolvePrompt(.alwaysForThisView) }),
                    ("Cancel", AccessibilityID.MCPApps.promptCancelButton, { [weak self] in self?.resolvePrompt(.dontSend) }),
                ]
            )
        }
        switch decision {
        case .send: return .open
        case .alwaysForThisView: return .alwaysForThisView
        case .dontSend: return .cancel
        }
    }

    /// A pane-less `ui/message`: nothing to send to, only Copy.
    func showCopyOnly(text: String) {
        resolvePrompt(.dontSend)
        showPrompt(
            message: "The app wants to send a message, but this view has no pane. Copy it instead.",
            buttons: [
                ("Copy", AccessibilityID.MCPApps.promptCopyButton, { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    self?.hidePrompt()
                }),
                ("Dismiss", AccessibilityID.MCPApps.promptCancelButton, { [weak self] in self?.hidePrompt() }),
            ]
        )
    }

    /// Resolves a waiting Send or Open prompt as `.dontSend` and hides it.
    /// A copy-only prompt, which waits for nothing, stays.
    func denyWaitingPrompt() {
        resolvePrompt(.dontSend)
    }

    /// Dismisses any prompt; a waiting one resolves as `.dontSend`.
    func dismissPrompt() {
        resolvePrompt(.dontSend)
        hidePrompt()
    }

    // MARK: - Private

    private func buildHeader() {
        header.orientation = .horizontal
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        header.setAccessibilityElement(true)
        header.setAccessibilityRole(.group)
        header.setAccessibilityIdentifier(AccessibilityID.MCPApps.viewHeader(viewID))
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.setAccessibilityIdentifier(AccessibilityID.MCPApps.viewStateLabel(viewID))
        warningLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byTruncatingTail
        warningLabel.isHidden = true
        warningLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        closeButton.bezelStyle = .inline
        closeButton.controlSize = .small
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setAccessibilityIdentifier(AccessibilityID.MCPApps.viewCloseButton(viewID))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        [titleLabel, stateLabel, warningLabel, spacer, closeButton].forEach { header.addArrangedSubview($0) }
    }

    private func buildPrompt() {
        promptArea.orientation = .vertical
        promptArea.alignment = .leading
        promptArea.spacing = 6
        promptArea.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        promptArea.isHidden = true
        promptArea.setAccessibilityElement(true)
        promptArea.setAccessibilityRole(.group)
        promptArea.setAccessibilityIdentifier(AccessibilityID.MCPApps.promptContainer)
    }

    private func buildStatusCard() {
        statusCard.orientation = .vertical
        statusCard.alignment = .centerX
        statusCard.spacing = 8
        statusCard.translatesAutoresizingMaskIntoConstraints = false
        statusMessage.alignment = .center
        statusMessage.textColor = .secondaryLabelColor
        reloadButton.target = self
        reloadButton.action = #selector(reloadClicked)
        reloadButton.setAccessibilityIdentifier(AccessibilityID.MCPApps.viewReloadButton(viewID))
        cardCloseButton.target = self
        cardCloseButton.action = #selector(closeClicked)
        let buttons = NSStackView(views: [reloadButton, cardCloseButton])
        buttons.orientation = .horizontal
        statusCard.addArrangedSubview(statusMessage)
        statusCard.addArrangedSubview(buttons)
        contentArea.addSubview(statusCard)
        NSLayoutConstraint.activate([
            statusCard.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            statusCard.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor),
            statusCard.widthAnchor.constraint(lessThanOrEqualTo: contentArea.widthAnchor, constant: -24),
        ])
    }

    private func showWebView() {
        statusCard.isHidden = true
        webView?.isHidden = false
    }

    private func showStatusCard() {
        statusCard.isHidden = false
        webView?.isHidden = true
    }

    private func showPrompt(message: String, buttons: [(title: String, identifier: String, action: () -> Void)]) {
        promptArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        addPromptText(message)
        let row = NSStackView()
        row.orientation = .horizontal
        for button in buttons {
            let control = MCPAppActionButton(title: button.title, action: button.action)
            control.setAccessibilityIdentifier(button.identifier)
            row.addArrangedSubview(control)
        }
        promptArea.addArrangedSubview(row)
        promptArea.isHidden = false
        onEnvironmentChange?()
    }

    /// Adds the prompt's text, whole, in an `MCPAppPromptTextView` wrapping
    /// at the prompt area's inner width. The scroll view joins `promptArea`
    /// before its constraint is activated, because a constraint between
    /// views with no common ancestor raises.
    private func addPromptText(_ message: String) {
        let scrollView = MCPAppPromptTextView(text: message, maxHeight: Self.maxPromptTextHeight)
        scrollView.wrapWidth = promptTextWidth
        promptArea.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: promptArea.widthAnchor, constant: -promptInsets).isActive = true
        promptText = scrollView
    }

    private var promptInsets: CGFloat { promptArea.edgeInsets.left + promptArea.edgeInsets.right }

    /// The prompt text's width: the card's width less the prompt's insets.
    private var promptTextWidth: CGFloat { max(bounds.width - promptInsets, 0) }

    private func hidePrompt() {
        guard !promptArea.isHidden else { return }
        promptArea.isHidden = true
        promptArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        onEnvironmentChange?()
    }

    private func resolvePrompt(_ decision: MCPAppMessageConsentGate.PromptDecision) {
        guard let continuation = promptContinuation else { return }
        promptContinuation = nil
        hidePrompt()
        continuation.resume(returning: decision)
    }

    @objc private func closeClicked() { onClose?() }
    @objc private func reloadClicked() { onReload?() }

    private static func stateText(_ status: MCPAppViewStatus) -> String {
        switch status {
        case .loadingResource: return "Loading"
        case .resourceError(let reason): return reason
        case .readFailed(let reason): return reason
        case .waitingForApp: return "Waiting for app"
        case .live: return "Running"
        case .stopped: return "The view stopped"
        case .upstreamDisconnected: return "Server disconnected"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }

    private static func cardText(_ status: MCPAppViewStatus) -> String {
        switch status {
        case .loadingResource: return "Loading the app…"
        case .resourceError(let reason): return "This app cannot be shown. \(reason)"
        case .readFailed(let reason): return "The app could not be loaded. \(reason)"
        case .waitingForApp: return "Waiting for the app to start…"
        case .stopped: return "The view stopped. Reload it, or close it."
        case .upstreamDisconnected: return "The MCP server is disconnected. The app will work again once it reconnects."
        case .live, .completed, .cancelled: return ""
        }
    }

    private static func offersReload(_ status: MCPAppViewStatus) -> Bool {
        switch status {
        case .readFailed, .stopped, .waitingForApp: return true
        default: return false
        }
    }

    private static func offersCardClose(_ status: MCPAppViewStatus) -> Bool {
        switch status {
        case .resourceError, .readFailed, .stopped: return true
        default: return false
        }
    }
}

/// A prompt's text: a read-only, selectable text view that wraps at
/// `wrapWidth` and scrolls once it is taller than `maxHeight`.
///
/// The intrinsic height is the text's height laid out at `wrapWidth`, capped
/// at `maxHeight`. It is measured with its own TextKit 1 objects, so it is
/// correct before the scroll view is laid out: the card reports the prompt's
/// height to the view (host context) as soon as the prompt shows. Above
/// `maxHeight` a vertical scroller may narrow the text, which only makes it
/// taller, so the capped height stays `maxHeight`.
///
/// The clip view is flipped, so the text stays anchored at its first line
/// when it grows taller (an unflipped clip view keeps its bounds origin at
/// the document's bottom edge). The text view starts at zero size like the
/// clip view, so its width autoresizes to the clip view's width.
@MainActor
final class MCPAppPromptTextView: NSScrollView {
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let maxHeight: CGFloat

    /// The width the text wraps at: the scroll view's width once laid out.
    var wrapWidth: CGFloat = 0 {
        didSet {
            if wrapWidth != oldValue { invalidateIntrinsicContentSize() }
        }
    }

    init(text: String, maxHeight: CGFloat) {
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        contentView = MCPAppFlippedClipView()
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        translatesAutoresizingMaskIntoConstraints = false

        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = Self.font
        textView.textContainerInset = .zero
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: min(max(Self.textHeight(textView.string, width: wrapWidth), 1), maxHeight))
    }

    private static let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    /// `text`'s height laid out at `width` with the text view's font and
    /// zero line fragment padding.
    private static func textHeight(_ text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(width, 0), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }
}

/// A clip view whose origin is its top-left corner.
@MainActor
private final class MCPAppFlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// A push button running a closure.
@MainActor
final class MCPAppActionButton: NSButton {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(run)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
