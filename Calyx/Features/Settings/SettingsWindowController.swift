import AppKit
import Observation
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "SettingsWindowController"
)

@MainActor
class SettingsWindowController: NSWindowController {

    static let shared = SettingsWindowController()
    private let opacityLabel = NSTextField(labelWithString: "")
    private let opacitySlider = NSSlider(value: 0.7, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorWell = NSColorWell()
    private let hexField = NSTextField()
    /// The AI Agent IPC row's three controls -- stored so
    /// updateAgentIPCRow() can update them after construction. This pane
    /// is built once in init(), so a control not held here could never be
    /// updated again afterward.
    private let agentIPCSwitch = NSSwitch()
    private let agentIPCRefreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let agentIPCStatusLabel = NSTextField(wrappingLabelWithString: "")
    /// The Usage Tracking row's status line, kept current by
    /// `updateUsageTrackingStatus()` (see `usageTrackingRow()`).
    private let usageTrackingStatusLabel = SettingsLayout.statusLabel()
    /// The row's reception status over this controller's inputs (and its
    /// DEBUG seams); it calls `updateUsageTrackingStatus()` whenever the
    /// text may have changed. `weak`, not `unowned`: nothing here may be
    /// able to trap, also if this controller stops being a singleton. A
    /// closure run after the controller is gone reads neutral values (no
    /// server, the shared activation and monitor) and updates nothing.
    private lazy var usageTelemetryStatusFeed = UsageTelemetryStatusFeed(
        inputs: UsageTelemetryStatusFeed.Inputs(
            trackingOn: { UsageTrackingSettings.enabled },
            ipcEnabled: { IPCSettings.enabled },
            serverRunning: { [weak self] in self?.usageServerRunning ?? false },
            activation: { [weak self] in self?.usageTelemetryActivation ?? .shared },
            monitor: { [weak self] in self?.usageIngestMonitor ?? .shared }),
        onChange: { [weak self] in self?.updateUsageTrackingStatus() })
    /// State behind the MCP Apps pane (`SettingsPane.mcpServers`), shared by every instance and
    /// held by the type so the composition root configures it at launch
    /// without creating the Settings window. Empty until
    /// `configureMCPServers(_:)`.
    static let mcpServerSettingsModel = MCPServerSettingsModel()

    var mcpServerSettingsModel: MCPServerSettingsModel { Self.mcpServerSettingsModel }

    private let tabViewController = SettingsTabViewController()
    /// One content controller per pane, so a pane whose content changes
    /// after construction can have its size measured again.
    private var paneViewControllers: [SettingsPane: SettingsPaneContentViewController] = [:]

    #if DEBUG
    /// Test seam: overrides the root `commandTrackingDidChange(_:)`
    /// resolves against, instead of
    /// `ShellIntegrationInstaller.defaultInstallDirectory` -- same shape
    /// as `AppDelegate._shellIntegrationRootForTesting`. DO NOT use from
    /// production code.
    var _shellIntegrationRootForTesting: URL?

    /// Test seam: the activation the Usage Tracking row reconciles and
    /// shows, instead of `UsageTelemetryActivation.shared`. DO NOT use
    /// from production code.
    var _usageTelemetryActivationForTesting: UsageTelemetryActivation?

    /// Test seam: the monitor the Usage Tracking row shows, instead of
    /// `UsageIngestMonitor.shared`. Setting it moves the feed's
    /// observation to it (the previous one stops). DO NOT use from
    /// production code.
    var _usageIngestMonitorForTesting: UsageIngestMonitor? {
        didSet {
            usageTelemetryStatusFeed.monitorDidChange()
            updateUsageTrackingStatus()
        }
    }

    /// Test seam: whether the Usage Tracking row takes the IPC server as
    /// running, instead of `CalyxMCPServer.shared.isRunning`. DO NOT use
    /// from production code.
    var _usageServerRunningForTesting: Bool?

    /// Test seam: what `ipcWakeDidChange(_:)` runs to release the
    /// waiting `/ipc-wake` polls when the switch is turned off, instead
    /// of `CalyxMCPServer.shared.ipcWakeCoordinator.releaseAllWaiters()`.
    /// DO NOT use from production code.
    var _ipcWakeReleaseForTesting: (@MainActor () -> Void)?

    /// Test seam: what `ipcWakeDidChange(_:)` runs to re-evaluate the
    /// waiting `/ipc-wake` polls when the switch is turned on, instead
    /// of `CalyxMCPServer.shared.ipcWakeCoordinator.reevaluateAllWaiters()`.
    /// DO NOT use from production code.
    var _ipcWakeReevaluateForTesting: (@MainActor () -> Void)?
    #endif

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.paneWidth, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        // IPC may have changed while no Settings window existed to observe it.
        mcpServerSettingsModel.refreshIPCEnabled()
        setupContent()

        // Settings is AppKit, so @Observable does not drive it. Chain
        // in-flight transitions (including the launch-time auto-enable,
        // which can run before this window has ever been shown) post
        // this so an already-open (or later-opened) Settings window's
        // row always reflects the live state.
        NotificationCenter.default.addObserver(
            self, selector: #selector(agentIPCStateDidChange),
            name: .calyxIPCStateDidChange, object: nil
        )
        // Arms the feed's observers (status, IPC state, monitor values).
        _ = usageTelemetryStatusFeed
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupContent() {
        tabViewController.tabStyle = .toolbar
        // Standard macOS Settings behavior: the window's title tracks the
        // selected pane, so mirror NSTabViewController's own selection
        // callback into the window's title bar.
        tabViewController.onTabSelectionChange = { [weak self] tabViewItem in
            guard let title = tabViewItem?.label else { return }
            self?.window?.title = title
        }

        for pane in SettingsPane.allCases {
            let paneViewController = SettingsPaneContentViewController(
                contentStack: paneStack(for: pane),
                width: SettingsLayout.paneWidth,
                contentInset: SettingsLayout.paneContentInset
            )
            paneViewControllers[pane] = paneViewController
            let tabItem = NSTabViewItem(viewController: paneViewController)
            tabItem.label = pane.title
            tabItem.image = NSImage(systemSymbolName: pane.icon, accessibilityDescription: pane.title)
            tabViewController.addTabViewItem(tabItem)
        }

        window?.contentViewController = tabViewController
        window?.title = SettingsPane.allCases.first?.title ?? "Settings"

        loadPresetIntoUI()
    }

    // MARK: - Pane construction (driven by SettingsRow.pane)

    /// A heading rendered immediately before the row that starts a new
    /// visual group within a pane. Rows with no heading continue the
    /// previous group.
    struct SectionHeading {
        let title: String?
        let subtitle: String?
    }

    static func sectionHeading(for row: SettingsRow) -> SectionHeading? {
        switch row {
        case .themeColorPreset:
            return SectionHeading(title: "Theme Color", subtitle: "Choose a preset or pick a custom color.")
        case .glassOpacity:
            return SectionHeading(title: "Glass", subtitle: "Controls the transparency of the glass effect.")
        case .smoothScrolling:
            return SectionHeading(title: "Scrolling", subtitle: nil)
        case .gitDiffPreviewTab:
            return SectionHeading(
                title: "Changes",
                subtitle: "Open diffs from the Changes sidebar in a single reusable preview tab. Double-click, comment, or Keep Open to keep a diff tab."
            )
        case .lspAutoInstall:
            return SectionHeading(
                title: "Auto-Install",
                subtitle: "Calyx hosts language servers and exposes them to AI agents over MCP. When a server is missing, Calyx can install it automatically."
            )
        case .persistentSessions:
            return SectionHeading(
                title: "Persistence",
                subtitle: "Persistent terminal sessions survive a crash or quit and can be reattached later, from this window or from the session browser."
            )
        case .agentIPC:
            return SectionHeading(
                title: "AI Agent IPC",
                subtitle: "Connects installed agent CLIs to Calyx over MCP."
            )
        case .agentResume:
            return SectionHeading(
                title: "Agent Resume",
                subtitle: "When a persistent session reattaches to a saved AI agent CLI conversation, offer to resume it."
            )
        case .cockpitAutoApprove:
            return SectionHeading(
                title: "Command Approval",
                subtitle: "Applies to agent-initiated pane commands (run, send keys, palette) and to CLI agents' "
                    + "(Claude Code, Codex, Grok, pi) tool-call approval requests. Off = ask every time."
            )
        case .commandTracking:
            return SectionHeading(title: "Command Tracking", subtitle: "Changes apply to new terminals only.")
        case .agentHookApproval:
            return SectionHeading(
                title: "Agent Hook Approval",
                subtitle: "Routes Claude Code and Codex permission prompts, all always-approve Grok tool calls, and every pi tool call to the Calyx approval banner. Off = agents decide alone, and pi, which has no prompt of its own, just runs the call."
            )
        case .usageTracking:
            return SectionHeading(
                title: "Usage Tracking",
                subtitle: "Records Claude Code token usage per model and effort, as counted by Claude Code itself. "
                    + "While this is on, Calyx adds telemetry settings to ~/.claude/settings.json so that Claude "
                    + "Code on this Mac sends its token counts to Calyx. Only numbers and labels are stored, never "
                    + "conversation text. Needs AI Agent IPC."
            )
        case .mcpServers:
            return SectionHeading(
                title: "MCP Apps",
                subtitle: "MCP servers whose tools show interactive apps next to the agent that calls them."
            )
        case .openConfigFileFooter:
            return SectionHeading(title: nil, subtitle: nil)
        case .glassOpacityCells, .themeColorWell, .themeColorHex, .lspRequireConfirmation,
             .historyPersistence, .ipcWake, .agentResumeAutoExecute,
             .openSessionBrowserButton:
            return nil
        }
    }

    private func paneStack(for pane: SettingsPane) -> NSStackView {
        let stack = SettingsLayout.column()
        stack.translatesAutoresizingMaskIntoConstraints = false

        let rowsInPane = SettingsRow.allCases.filter { $0.pane == pane }
        for (index, settingsRow) in rowsInPane.enumerated() {
            if let heading = Self.sectionHeading(for: settingsRow) {
                if index > 0 {
                    stack.addArrangedSubview(SettingsLayout.sectionDivider())
                }
                if let title = heading.title {
                    stack.addArrangedSubview(SettingsLayout.sectionTitleLabel(title))
                }
                if let subtitle = heading.subtitle {
                    stack.addArrangedSubview(SettingsLabelFactory.descriptionLabel(subtitle))
                }
            }
            stack.addArrangedSubview(contentView(for: settingsRow))
        }
        return stack
    }

    private func contentView(for settingsRow: SettingsRow) -> NSView {
        switch settingsRow {
        case .themeColorPreset:
            return themeColorPresetRow()
        case .themeColorWell:
            return controlRow(label: "Color", control: colorWell)
        case .themeColorHex:
            return themeColorHexRow()
        case .glassOpacity:
            return glassOpacityRow()
        case .glassOpacityCells:
            return glassOpacityCellsRow()
        case .smoothScrolling:
            return smoothScrollingRow()
        case .gitDiffPreviewTab:
            return gitDiffPreviewTabRow()
        case .lspAutoInstall:
            return lspAutoInstallRow()
        case .lspRequireConfirmation:
            return lspRequireConfirmationRow()
        case .persistentSessions:
            return persistentSessionsRow()
        case .historyPersistence:
            return historyPersistenceRow()
        case .agentIPC:
            return agentIPCRow()
        case .ipcWake:
            return ipcWakeRow()
        case .agentResume:
            return agentResumeRow()
        case .agentResumeAutoExecute:
            return agentResumeAutoExecuteRow()
        case .cockpitAutoApprove:
            return cockpitAutoApproveRow()
        case .commandTracking:
            return commandTrackingRow()
        case .agentHookApproval:
            return agentHookApprovalRow()
        case .usageTracking:
            return usageTrackingRow()
        case .mcpServers:
            return mcpServersRow()
        case .openSessionBrowserButton:
            return sessionBrowserButtonRow()
        case .openConfigFileFooter:
            return configFileFooterRow()
        }
    }

    private func themeColorPresetRow() -> NSView {
        let presets = ThemeColorPreset.allCases.filter { $0 != .custom }
        for preset in presets {
            presetPopup.addItem(withTitle: preset.displayName)
        }
        presetPopup.addItem(withTitle: "Custom")
        presetPopup.target = self
        presetPopup.action = #selector(presetDidChange(_:))
        colorWell.color = ThemeColorPreset.original.color
        colorWell.target = self
        colorWell.action = #selector(colorWellDidChange(_:))
        return controlRow(label: "Preset", control: presetPopup)
    }

    private func themeColorHexRow() -> NSView {
        hexField.stringValue = ThemeColorPreset.defaultCustomHex
        hexField.placeholderString = "#RRGGBB"
        hexField.target = self
        hexField.action = #selector(hexFieldDidCommit(_:))
        hexField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return controlRow(label: "Hex", control: hexField)
    }

    private func glassOpacityRow() -> NSView {
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityDidChange(_:))
        opacityLabel.alignment = .right
        opacityLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        updateOpacityLabel()

        let opacityRow = NSStackView()
        opacityRow.orientation = .horizontal
        opacityRow.spacing = SettingsLayout.controlSpacing
        opacityRow.alignment = .centerY
        let opacityText = NSTextField(labelWithString: "Glass opacity")
        opacityText.font = .systemFont(ofSize: 13, weight: .medium)
        opacityText.setContentHuggingPriority(.required, for: .horizontal)
        opacityRow.addArrangedSubview(opacityText)
        opacityRow.addArrangedSubview(opacitySlider)
        opacityRow.addArrangedSubview(opacityLabel)
        return opacityRow
    }

    private func glassOpacityCellsRow() -> NSView {
        let cellsSwitch = NSSwitch()
        cellsSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.glassOpacityCellsSwitch)
        cellsSwitch.state = Self.sessionToggleInitialState(for: .glassOpacityCells) ? .on : .off
        cellsSwitch.target = self
        cellsSwitch.action = #selector(glassOpacityCellsDidChange(_:))
        return controlRow(label: "Apply opacity to cell backgrounds", control: cellsSwitch)
    }

    private func smoothScrollingRow() -> NSView {
        let smoothScrollSwitch = NSSwitch()
        smoothScrollSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.smoothScrollingSwitch)
        smoothScrollSwitch.state = (UserDefaults.standard.object(forKey: "smoothScrollEnabled") as? Bool ?? true) ? .on : .off
        smoothScrollSwitch.target = self
        smoothScrollSwitch.action = #selector(smoothScrollDidChange(_:))
        return controlRow(label: "Smooth Scrolling", control: smoothScrollSwitch)
    }

    /// Toggle for `CalyxWindowController.gitDiffPreviewTabEnabledKey`;
    /// absent key reads as ON, matching `openDiffTab(source:pinned:)`.
    private func gitDiffPreviewTabRow() -> NSView {
        let previewSwitch = NSSwitch()
        previewSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.gitDiffPreviewTabSwitch)
        previewSwitch.state = (UserDefaults.standard.object(forKey: CalyxWindowController.gitDiffPreviewTabEnabledKey) as? Bool ?? true) ? .on : .off
        previewSwitch.target = self
        previewSwitch.action = #selector(gitDiffPreviewTabDidChange(_:))
        return controlRow(label: "Open diffs in a preview tab", control: previewSwitch)
    }

    private func lspAutoInstallRow() -> NSView {
        let autoInstallSwitch = NSSwitch()
        autoInstallSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.lspAutoInstallSwitch)
        autoInstallSwitch.state = LSPSettings.autoInstallEnabled ? .on : .off
        autoInstallSwitch.target = self
        autoInstallSwitch.action = #selector(lspAutoInstallDidChange(_:))
        return controlRow(label: "Auto-install language servers", control: autoInstallSwitch)
    }

    private func lspRequireConfirmationRow() -> NSView {
        let requireConfirmSwitch = NSSwitch()
        requireConfirmSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.lspRequireConfirmationSwitch)
        requireConfirmSwitch.state = LSPSettings.requireInstallConfirmation ? .on : .off
        requireConfirmSwitch.target = self
        requireConfirmSwitch.action = #selector(lspRequireConfirmationDidChange(_:))
        return controlRow(label: "Confirm before each install step", control: requireConfirmSwitch)
    }

    /// Pure mapping from a toggle row to the value its switch's initial
    /// `.state` must be seeded from. Despite the `session` prefix left over
    /// from this function's original scope, it now covers toggle rows
    /// across multiple panes, each backed by its own store: SessionSettings
    /// for the session rows, CockpitSettings for cockpitAutoApprove and
    /// agentHookApproval, CommandTrackingSettings for commandTracking,
    /// UsageTrackingSettings for usageTracking, IPCWakeSettings for
    /// ipcWake, and UserDefaults.standard directly for
    /// glassOpacityCells (it has no dedicated settings type). Extracted as its own function (rather than
    /// reading each backing store directly inline in each row builder)
    /// because SettingsWindowController.shared's one-shot, process-lifetime
    /// construction makes the seeding behavior unobservable through the
    /// real singleton in a test -- this has none of that lifetime, so a
    /// test can set the backing store directly and call it standalone.
    /// `.agentIPC` is deliberately absent (falls through to `default`):
    /// `updateAgentIPCRow()` is that row's only initialization path, via
    /// `AgentIPCRowResolver`, not this function.
    static func sessionToggleInitialState(for row: SettingsRow) -> Bool {
        switch row {
        case .persistentSessions: return SessionSettings.persistentSessionsEnabled
        case .historyPersistence: return SessionSettings.historyPersistenceEnabled
        case .agentResume: return SessionSettings.agentResumeEnabled
        case .agentResumeAutoExecute: return SessionSettings.agentResumeAutoExecute
        case .cockpitAutoApprove: return CockpitSettings.autoApproveEnabled
        case .commandTracking: return CommandTrackingSettings.trackingEnabled
        case .agentHookApproval: return CockpitSettings.agentHookApprovalEnabled
        case .usageTracking: return UsageTrackingSettings.enabled
        case .ipcWake: return IPCWakeSettings.enabled
        case .glassOpacityCells: return UserDefaults.standard.bool(forKey: "terminalGlassOpacityCells")
        default: return false
        }
    }

    private func persistentSessionsRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.persistentSessionsSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .persistentSessions) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(persistentSessionsDidChange(_:))
        return controlRow(label: "Enable persistent sessions", control: toggleSwitch)
    }

    private func historyPersistenceRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.historyPersistenceSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .historyPersistence) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(historyPersistenceDidChange(_:))
        return controlRow(label: "Persist session history to disk", control: toggleSwitch)
    }

    /// Three stacked rows, matching every other section in this pane
    /// (heading + `controlRow(label:control:)`): the enable switch, the
    /// status text, and a `sessionBrowserButtonRow()`-shaped Refresh
    /// button row. The switch mirrors `IPCSettings.enabled` (the
    /// setting, never the live server); flipping it and pressing Refresh
    /// both run through `IPCActivationChain.shared` so a rapid pair of
    /// toggles lands in order. All visible state comes from
    /// `AgentIPCRowResolver.resolve`, re-applied by `updateAgentIPCRow()`
    /// on every `.calyxIPCStateDidChange` notification.
    private func agentIPCRow() -> NSView {
        agentIPCSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.agentIPCSwitch)
        agentIPCSwitch.target = self
        agentIPCSwitch.action = #selector(agentIPCSwitchDidChange(_:))

        agentIPCRefreshButton.bezelStyle = .rounded
        agentIPCRefreshButton.setAccessibilityIdentifier(AccessibilityID.Settings.agentIPCRefreshButton)
        agentIPCRefreshButton.target = self
        agentIPCRefreshButton.action = #selector(agentIPCRefreshButtonPressed(_:))

        agentIPCStatusLabel.setAccessibilityIdentifier(AccessibilityID.Settings.agentIPCStatusLabel)
        agentIPCStatusLabel.font = SettingsLayout.statusFont
        agentIPCStatusLabel.preferredMaxLayoutWidth = SettingsLayout.contentWidth

        let column = SettingsLayout.column([
            controlRow(label: "Enable AI Agent IPC", control: agentIPCSwitch),
            agentIPCStatusLabel,
            SettingsLayout.buttonRow([agentIPCRefreshButton]),
        ])

        updateAgentIPCRow()
        return column
    }

    private func agentResumeRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.agentResumeSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .agentResume) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(agentResumeDidChange(_:))
        return controlRow(label: "Offer to resume agent CLI conversations", control: toggleSwitch)
    }

    private func agentResumeAutoExecuteRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.agentResumeAutoExecuteSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .agentResumeAutoExecute) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(agentResumeAutoExecuteDidChange(_:))
        return controlRow(label: "Auto-execute resume (skip confirmation)", control: toggleSwitch)
    }

    private func cockpitAutoApproveRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.cockpitAutoApproveSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .cockpitAutoApprove) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(cockpitAutoApproveDidChange(_:))
        return controlRow(label: "Auto-approve agent commands", control: toggleSwitch)
    }

    private func commandTrackingRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.commandTrackingSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .commandTracking) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(commandTrackingDidChange(_:))
        return controlRow(label: "Track shell commands", control: toggleSwitch)
    }

    private func agentHookApprovalRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.agentHookApprovalSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .agentHookApproval) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(agentHookApprovalDidChange(_:))
        return controlRow(label: "Show agent tool prompts in the approval banner", control: toggleSwitch)
    }

    private func ipcWakeRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.ipcWakeSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .ipcWake) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(ipcWakeDidChange(_:))
        return controlRow(label: "Wake Claude Code on IPC messages", control: toggleSwitch)
    }

    private func usageTrackingRow() -> NSView {
        let toggleSwitch = NSSwitch()
        toggleSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.usageTrackingSwitch)
        toggleSwitch.state = Self.sessionToggleInitialState(for: .usageTracking) ? .on : .off
        toggleSwitch.target = self
        toggleSwitch.action = #selector(usageTrackingDidChange(_:))

        usageTrackingStatusLabel.setAccessibilityIdentifier(AccessibilityID.Settings.usageTrackingStatusLabel)

        let column = SettingsLayout.column([
            controlRow(label: "Track Claude Code usage", control: toggleSwitch),
            usageTrackingStatusLabel,
        ])
        updateUsageTrackingStatus()
        return column
    }

    // MARK: Usage Tracking status

    private var usageTelemetryActivation: UsageTelemetryActivation {
        #if DEBUG
        return _usageTelemetryActivationForTesting ?? .shared
        #else
        return .shared
        #endif
    }

    private var usageIngestMonitor: UsageIngestMonitor {
        #if DEBUG
        return _usageIngestMonitorForTesting ?? .shared
        #else
        return .shared
        #endif
    }

    private var usageServerRunning: Bool {
        #if DEBUG
        return _usageServerRunningForTesting ?? CalyxMCPServer.shared.isRunning
        #else
        return CalyxMCPServer.shared.isRunning
        #endif
    }

    /// Applies the feed's text (`UsageTelemetryStatusResolver`) to the
    /// row's status label; hidden while the text is empty. Called when the
    /// pane is built, when the switch changes, and by the feed on
    /// `.calyxIPCStateDidChange`, on `.calyxUsageTelemetryStatusDidChange`
    /// (after every reconcile run of the shared activation), and when the
    /// monitor's values change.
    private func updateUsageTrackingStatus() {
        let text = usageTelemetryStatusFeed.text
        usageTrackingStatusLabel.isHidden = text.isEmpty
        usageTrackingStatusLabel.attributedStringValue = SettingsLayout.statusText(text)
    }

    /// The whole MCP Apps pane below its heading, built from the same
    /// `SettingsLayout` metrics as every other pane. Its content follows
    /// `mcpServerSettingsModel`; each change measures the pane again so
    /// the window height keeps following the content.
    private func mcpServersRow() -> NSView {
        MCPServersSettingsView(model: mcpServerSettingsModel) { [weak self] in
            self?.paneViewControllers[.mcpServers]?.contentDidChange()
        }
    }

    /// Gives the MCP Apps pane its registry, connections, catalog,
    /// secret store and actions. Does not create the Settings window.
    static func configureMCPServers(_ dependencies: MCPServerSettingsModel.Dependencies) {
        mcpServerSettingsModel.configure(dependencies)
    }

    private func sessionBrowserButtonRow() -> NSView {
        SettingsLayout.buttonRow([
            SettingsLayout.button("Open Session Browser", target: self, action: #selector(openSessionBrowser(_:))),
        ])
    }

    private func configFileFooterRow() -> NSView {
        let openButton = SettingsLayout.button("Open Config File", target: self, action: #selector(openConfigFile(_:)))
        let helpButton = NSButton(title: "", target: self, action: #selector(showConfigHelp(_:)))
        helpButton.bezelStyle = .helpButton
        return SettingsLayout.buttonRow([openButton, helpButton])
    }

    func showSettings() {
        loadPresetIntoUI()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openConfigFile(_ sender: Any?) {
        var opener = SystemConfigFileOpener()
        let result = ConfigFileOpener.openConfigFile(using: &opener)

        switch result {
        case .opened, .createdAndOpened:
            break // Success
        case .error(let error):
            showConfigFileError(error, opener: opener)
        }
    }

    private func showConfigFileError(_ error: ConfigFileOpenError, opener: SystemConfigFileOpener) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not open config file"

        let rawPath = opener.configOpenPath()
        let hasPath = !rawPath.isEmpty

        switch error {
        case .emptyPath:
            alert.informativeText = "Could not determine the config file path."
        case .isDirectory:
            alert.informativeText = "The config path points to a directory, not a file."
        case .isSymlink:
            alert.informativeText = "The config path is a symbolic link. For security, Calyx will not follow symlinks."
        case .createFailed(let message):
            alert.informativeText = "Failed to create config file: \(message)"
        case .openFailed:
            alert.informativeText = "The file exists but could not be opened."
        }

        if hasPath {
            alert.addButton(withTitle: "Reveal in Finder")
            alert.addButton(withTitle: "Copy Path")
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "OK")
        }

        let response = alert.runModal()

        guard hasPath else { return }
        let fileURL = URL(fileURLWithPath: rawPath)

        switch response {
        case .alertFirstButtonReturn:
            opener.revealInFinder(url: fileURL)
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rawPath, forType: .string)
        default:
            break
        }
    }

    @objc private func opacityDidChange(_ sender: Any?) {
        updateOpacityLabel()
        let opacity = max(0.0, min(1.0, opacitySlider.doubleValue))
        UserDefaults.standard.set(opacity, forKey: "terminalGlassOpacity")
        applyOpacityToRunningSurfaces()
    }

    @objc private func glassOpacityCellsDidChange(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: "terminalGlassOpacityCells")
        applyOpacityToRunningSurfaces()
    }

    @objc private func smoothScrollDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "smoothScrollEnabled")
        if !enabled {
            NotificationCenter.default.post(name: .smoothScrollSettingChanged, object: nil)
        }
    }

    /// Read on each `openDiffTab` call, so no notification is needed.
    @objc private func gitDiffPreviewTabDidChange(_ sender: NSSwitch) {
        UserDefaults.standard.set(sender.state == .on, forKey: CalyxWindowController.gitDiffPreviewTabEnabledKey)
    }

    @objc private func lspAutoInstallDidChange(_ sender: NSSwitch) {
        LSPSettings.autoInstallEnabled = (sender.state == .on)
    }

    @objc private func lspRequireConfirmationDidChange(_ sender: NSSwitch) {
        LSPSettings.requireInstallConfirmation = (sender.state == .on)
    }

    @objc private func persistentSessionsDidChange(_ sender: NSSwitch) {
        SessionSettings.persistentSessionsEnabled = (sender.state == .on)
    }

    @objc private func historyPersistenceDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        Task {
            await HistoryPersistenceToggleCoordinator.historyPersistenceEnabledDidChange(enabled)
        }
    }

    @objc private func agentResumeDidChange(_ sender: NSSwitch) {
        SessionSettings.agentResumeEnabled = (sender.state == .on)
    }

    @objc private func agentResumeAutoExecuteDidChange(_ sender: NSSwitch) {
        SessionSettings.agentResumeAutoExecute = (sender.state == .on)
    }

    @objc private func cockpitAutoApproveDidChange(_ sender: NSSwitch) {
        CockpitSettings.autoApproveEnabled = (sender.state == .on)
    }

    /// Flipping ON installs+applies immediately (new panes only --
    /// already-running shells keep whatever hooks/env they already
    /// loaded). Flipping OFF only stops future env injection
    /// (`CalyxShellIntegrationEnvironment.remove`); the `/command-event`
    /// endpoint itself keeps accepting so an already-running pane's
    /// hooks don't half-die mid-session.
    @objc private func commandTrackingDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        CommandTrackingSettings.trackingEnabled = enabled
        #if DEBUG
        let root = _shellIntegrationRootForTesting ?? ShellIntegrationInstaller.defaultInstallDirectory
        #else
        let root = ShellIntegrationInstaller.defaultInstallDirectory
        #endif
        if enabled {
            ShellIntegrationActivation.activateIfPossible(root: root)
        } else {
            CalyxShellIntegrationEnvironment.remove(rootDirectory: root)
        }
    }

    @objc private func agentHookApprovalDidChange(_ sender: NSSwitch) {
        CockpitSettings.agentHookApprovalEnabled = (sender.state == .on)
    }

    /// Writes the setting, then acts once on the waiting `/ipc-wake`
    /// polls. Off: releases every one. With the setting off no check
    /// hands out a wake, so a hook process still long-polling would
    /// otherwise sit there until the poll's timeout; releasing answers
    /// it 204 at once, and the route answers later polls 204 without
    /// registering them. On: re-evaluates every one, so a poll that
    /// registered just before the setting went off, and whose peer got
    /// a message while it was off, is woken now instead of at the next
    /// message or its timeout. A pane with no poll at that moment
    /// becomes wakeable from its next turn end or session start.
    @objc private func ipcWakeDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        IPCWakeSettings.enabled = enabled
        if enabled {
            #if DEBUG
            if let reevaluate = _ipcWakeReevaluateForTesting {
                reevaluate()
                return
            }
            #endif
            CalyxMCPServer.shared.ipcWakeCoordinator.reevaluateAllWaiters()
            return
        }
        #if DEBUG
        if let release = _ipcWakeReleaseForTesting {
            release()
            return
        }
        #endif
        CalyxMCPServer.shared.ipcWakeCoordinator.releaseAllWaiters()
    }

    /// Writes the setting, refreshes the status line and requests a
    /// reconcile of the telemetry activation (after the setting is
    /// written), which syncs the ledger's tracking flag and writes or
    /// removes Calyx's block in Claude Code's settings file. Nothing else:
    /// turning tracking on restarts tracking, so there is nothing earlier
    /// to catch up, and turning it off keeps the stored data.
    @objc private func usageTrackingDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        UsageTrackingSettings.enabled = enabled
        updateUsageTrackingStatus()
        let activation = usageTelemetryActivation
        Task {
            await activation.reconcile()
        }
    }

    /// Writes the setting and refreshes the row unconditionally -- the
    /// setting itself always reflects what the user asked for, even when
    /// the activation below is skipped -- then runs enable/disable
    /// through the shared chain so a rapid pair of toggles still lands
    /// in order. `IPCActivationCoordinator.enable()`/`disable()` already
    /// serialize themselves through `IPCActivationChain.shared`, which
    /// also records the outcome and posts `.calyxIPCStateDidChange`
    /// itself before its in-flight flag drops -- wrapping this call in a
    /// second `chain.run()` would deadlock (the inner `run()` would
    /// await the very outer `Task` it is nested inside), and
    /// re-recording or re-posting here would be redundant with what the
    /// chain already does.
    ///
    /// Guarded by `LaunchEnvironmentPolicy.mayPerformAgentIPCActivation()`:
    /// without it, a `--uitesting` launch that forgot
    /// `--calyx-path-root=` would activate against the developer's real
    /// `~/.claude.json` / `~/.codex/config.toml` / `~/.grok/config.toml`
    /// / OpenCode config the moment an E2E test flips this switch. See
    /// that predicate's own doc comment.
    @objc private func agentIPCSwitchDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        IPCSettings.enabled = enabled
        updateAgentIPCRow()
        mcpServerSettingsModel.refreshIPCEnabled()
        guard LaunchEnvironmentPolicy.mayPerformAgentIPCActivation() else { return }
        Task {
            if enabled {
                _ = await IPCActivationCoordinator().enable()
            } else {
                _ = await IPCActivationCoordinator().disable()
            }
        }
    }

    /// Re-runs enable() through the shared chain -- never disable(), even
    /// though the setting could in principle be off: `agentIPCRow()`
    /// disables this button whenever `AgentIPCRowResolver` reports the
    /// setting off (`refreshEnabled` requires `settingEnabled`), so this
    /// only ever fires while the setting is already on. See
    /// `agentIPCSwitchDidChange` above for why no extra recording or
    /// posting happens here, and for why this is guarded the same way.
    @objc private func agentIPCRefreshButtonPressed(_ sender: NSButton) {
        guard LaunchEnvironmentPolicy.mayPerformAgentIPCActivation() else { return }
        Task {
            _ = await IPCActivationCoordinator().enable()
        }
    }

    /// Re-applies `AgentIPCRowResolver.resolve` to the row's three
    /// stored controls. Called after construction and on every
    /// `.calyxIPCStateDidChange` notification -- including one posted
    /// while the launch-time auto-activation is still running, before
    /// this window has ever been shown, so opening Settings mid-launch
    /// still shows the correct in-flight state.
    private func updateAgentIPCRow() {
        let inFlight: AgentIPCRowResolver.InFlight
        switch IPCActivationChain.shared.runningOperation {
        case .enabling:
            inFlight = .enabling
        case .disabling:
            inFlight = .disabling
        case nil:
            inFlight = .none
        }
        let state = AgentIPCRowResolver.resolve(
            settingEnabled: IPCSettings.enabled,
            inFlight: inFlight,
            lastActivation: IPCActivationChain.shared.lastActivation
        )
        agentIPCSwitch.state = state.switchOn ? .on : .off
        agentIPCSwitch.isEnabled = state.switchEnabled
        agentIPCRefreshButton.isEnabled = state.refreshEnabled
        agentIPCStatusLabel.isHidden = Self.statusLabelIsHidden(for: state)
        agentIPCStatusLabel.attributedStringValue = SettingsLayout.statusText(state.statusText)
    }

    /// Whether the status label should be hidden for a given resolved
    /// row state. Extracted as its own pure function (rather than
    /// inlined in `updateAgentIPCRow()`) because `IPCActivationChain.shared`
    /// is a process-lifetime singleton with no test seam for
    /// `lastActivation` -- same reason this file's Sessions-toggle
    /// initial-state seeding was pulled into
    /// `sessionToggleInitialState(for:)`. `NSStackView.detachesHiddenViews`
    /// defaults to `true`, so hiding this label also collapses the
    /// 18pt gaps on both sides of it, matching every other section's
    /// row spacing when there is no status text yet to show.
    static func statusLabelIsHidden(for state: AgentIPCRowResolver.State) -> Bool {
        state.statusText.isEmpty
    }

    @objc private func agentIPCStateDidChange(_ notification: Notification) {
        updateAgentIPCRow()
        mcpServerSettingsModel.refreshIPCEnabled()
    }

    @objc private func openSessionBrowser(_ sender: Any?) {
        SessionBrowserWindowController.shared.showBrowser()
    }

    @objc private func presetDidChange(_ sender: Any?) {
        let index = presetPopup.indexOfSelectedItem
        let presets = ThemeColorPreset.allCases.filter { $0 != .custom }
        if index < presets.count {
            let preset = presets[index]
            UserDefaults.standard.set(preset.rawValue, forKey: "themeColorPreset")
            colorWell.color = preset.color
            hexField.stringValue = HexColor.toHex(preset.color)
            hexField.textColor = .labelColor
        }
        // If "Custom" selected (last item), just set preset to custom
        else {
            UserDefaults.standard.set("custom", forKey: "themeColorPreset")
        }
        GhosttyAppController.shared.reloadConfig()
    }

    @objc private func colorWellDidChange(_ sender: Any?) {
        let color = colorWell.color
        let hex = HexColor.toHex(color)
        hexField.stringValue = hex
        hexField.textColor = .labelColor
        UserDefaults.standard.set(hex, forKey: "themeColorCustomHex")
        UserDefaults.standard.set("custom", forKey: "themeColorPreset")
        // Update popup to show "Custom"
        presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
        GhosttyAppController.shared.reloadConfig()
    }

    @objc private func hexFieldDidCommit(_ sender: Any?) {
        let text = hexField.stringValue
        if let color = HexColor.parse(text) {
            let normalized = HexColor.toHex(color)
            hexField.stringValue = normalized
            hexField.textColor = .labelColor
            colorWell.color = color
            UserDefaults.standard.set(normalized, forKey: "themeColorCustomHex")
            UserDefaults.standard.set("custom", forKey: "themeColorPreset")
            presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
            GhosttyAppController.shared.reloadConfig()
        } else {
            // Invalid hex - show red text, do NOT write to UserDefaults
            hexField.textColor = .systemRed
        }
    }

    @objc func reloadConfig() {
        // Ghostty reloads config automatically via file watcher
        // This is a manual trigger if needed
        logger.info("Config reload requested")
    }

    private func controlRow(label: String, control: NSView) -> NSView {
        SettingsLayout.controlRow(label: label, control: control)
    }

    private func updateOpacityLabel() {
        opacityLabel.stringValue = String(format: "%.2f", opacitySlider.doubleValue)
    }

    private func loadPresetIntoUI() {
        let opacity = UserDefaults.standard.object(forKey: "terminalGlassOpacity") as? Double ?? 0.7
        opacitySlider.doubleValue = max(0.0, min(1.0, opacity))
        updateOpacityLabel()

        // Load theme color state
        let preset = UserDefaults.standard.string(forKey: "themeColorPreset") ?? "original"
        let customHex = UserDefaults.standard.string(forKey: "themeColorCustomHex") ?? ThemeColorPreset.defaultCustomHex
        let presets = ThemeColorPreset.allCases.filter { $0 != .custom }
        if let idx = presets.firstIndex(where: { $0.rawValue == preset }) {
            presetPopup.selectItem(at: idx)
            colorWell.color = presets[idx].color
            hexField.stringValue = HexColor.toHex(presets[idx].color)
        } else {
            // Custom
            presetPopup.selectItem(at: presetPopup.numberOfItems - 1)
            colorWell.color = HexColor.parse(customHex) ?? ThemeColorPreset.original.color
            hexField.stringValue = customHex
        }
        hexField.textColor = .labelColor
    }

    private func applyOpacityToRunningSurfaces() {
        // reloadConfig(soft: false) handles both disk reload and window propagation
        // via ConfigReloadCoordinator with 200ms debounce.
        GhosttyAppController.shared.reloadConfig()
    }

    @objc private func showConfigHelp(_ sender: NSButton) {
        let controller = GhosttyConfigHelpViewController()
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
}

@MainActor
private final class GhosttyConfigHelpViewController: NSViewController {

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Ghostty Config Compatibility")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(wrappingLabelWithString: "Calyx reads ~/.config/ghostty/config. Most settings are hot-reloaded when you save the file.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.preferredMaxLayoutWidth = 328
        subtitle.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addArrangedSubview(subtitle)

        let managedLabel = NSTextField(wrappingLabelWithString: "The following keys are managed by Calyx for the Glass UI effect and will be overridden:")
        managedLabel.textColor = .secondaryLabelColor
        managedLabel.font = .systemFont(ofSize: 12)
        managedLabel.preferredMaxLayoutWidth = 328
        managedLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addArrangedSubview(managedLabel)

        let managedKeysText = GhosttyConfigManager.managedKeys.map { "  • \($0)" }.joined(separator: "\n")
        let managedKeysList = NSTextField(wrappingLabelWithString: managedKeysText)
        managedKeysList.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        managedKeysList.textColor = .tertiaryLabelColor
        managedKeysList.preferredMaxLayoutWidth = 328
        managedKeysList.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addArrangedSubview(managedKeysList)

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 360),
        ])
        self.view = container
    }
}

/// Exposes NSTabViewController's own NSTabViewDelegate callback
/// (`tabView(_:didSelect:)`, the override point NSTabViewController
/// documents for subclasses reacting to selection changes) as a plain
/// closure, so SettingsWindowController can update the window's title
/// without itself subclassing NSTabViewController.
@MainActor
private final class SettingsTabViewController: NSTabViewController {
    var onTabSelectionChange: ((NSTabViewItem?) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onTabSelectionChange?(tabViewItem)
    }
}

/// Hosts one SettingsPane's content stack at a fixed width, inside a
/// vertically scrolling NSScrollView. NSTabViewController (tabStyle
/// .toolbar) resizes the Settings window to each tab's
/// preferredContentSize on selection: a pane whose content is no taller
/// than `SettingsLayout.maxPaneContentHeight` sizes the window exactly to
/// that content (the scroller stays auto-hidden, so this is visually
/// identical to a plain fixed-height view), while a taller pane stops at
/// that height and reveals the scroller, so its trailing rows are reached
/// by scrolling. The window keeps its top edge, x and width when fitted to
/// a pane, and its bottom edge stays `SettingsLayout.screenBottomMargin`
/// above the bottom of its screen's visible frame.
@MainActor
final class SettingsPaneContentViewController: NSViewController {

    /// Floor under the pane's content height, and under the window height
    /// when the window's top is too close to the screen bottom to fit more,
    /// so the window never collapses to something unusably short.
    private static let minimumContentHeight: CGFloat = 200

    /// The scroll view's document view. Flipped so content starts at the
    /// top and scrolls downward, like every other macOS scroll view,
    /// instead of NSView's default bottom-left-origin coordinate system.
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    private let contentStack: NSStackView
    private let width: CGFloat
    private let contentInset: CGFloat
    private let documentView = FlippedDocumentView()

    init(contentStack: NSStackView, width: CGFloat, contentInset: CGFloat) {
        self.contentStack = contentStack
        self.width = width
        self.contentInset = contentInset
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func loadView() {
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        // Same constraints as the previous fixed-height container: pinned
        // to the document view's edges at `contentInset`, with a fixed
        // width. This alone fully determines the document view's own
        // width (== `width`, matching the scroll view's content width so
        // it never scrolls horizontally) and its height (driven
        // intrinsically by the stack), with no separate width constraint
        // needed between the document view and the scroll view.
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: contentInset),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -contentInset),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: contentInset),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -contentInset),
            contentStack.widthAnchor.constraint(equalToConstant: width - 2 * contentInset),
        ])

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = documentView

        self.view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        measurePreferredContentSize(in: nil)
    }

    /// Measures the pane again after its content changed height, and
    /// resizes the window to it when this pane is the one on screen. A
    /// pane not on screen is measured again by `viewDidAppear()` when its
    /// tab is selected. Does nothing before the view is loaded:
    /// `viewDidLoad()` measures.
    func contentDidChange() {
        guard isViewLoaded else { return }
        measurePreferredContentSize(in: view.window)
        fitWindowToPreferredHeight()
    }

    /// Sets `preferredContentSize` once to the pane's natural height capped
    /// at `SettingsLayout.maxPaneContentHeight`, further limited, when
    /// `window` is given, to the content height of the frame
    /// `fittedWindowFrame` gives that window for it.
    private func measurePreferredContentSize(in window: NSWindow?) {
        documentView.layoutSubtreeIfNeeded()
        let naturalHeight = documentView.fittingSize.height
        var height = max(Self.minimumContentHeight,
                         min(naturalHeight, SettingsLayout.maxPaneContentHeight))
        if let window {
            height = window.contentRect(forFrameRect: fittedFrame(of: window, contentHeight: height)).height
        }
        preferredContentSize = NSSize(width: width, height: height)
    }

    /// Showing the window: when the window is ordered in, NSTabViewController
    /// resizes it to the selected pane's `preferredContentSize` (keeping
    /// the top edge) before `viewDidAppear()`. That size was measured with
    /// no window, so it is limited here for the window's position first;
    /// otherwise that resize would push the bottom edge past the
    /// screen-bottom margin until `viewDidAppear()` corrected it. On a tab
    /// switch `view.window` is still nil here, so this returns without
    /// measuring and `viewDidAppear()` measures instead.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard let window = view.window else { return }
        measurePreferredContentSize(in: window)
    }

    /// Tab switches: the incoming pane is in the window only from here on
    /// (`viewWillAppear()` sees no window then), so it is measured for the
    /// window's position and the window is fitted to it, keeping the top
    /// edge, stopping the bottom edge `SettingsLayout.screenBottomMargin`
    /// above the screen's visible bottom, floored at `minimumContentHeight`.
    /// The measure must come first: NSTabViewController sets the window
    /// back to the pane's `preferredContentSize` after a frame change made
    /// during the switch, so a fit to a size it does not also prefer would
    /// be undone.
    override func viewDidAppear() {
        super.viewDidAppear()
        measurePreferredContentSize(in: view.window)
        fitWindowToPreferredHeight()
    }

    /// The frame for a window currently at `current` fitted to
    /// `targetFrameHeight`: top edge, x and width unchanged, and the height
    /// reduced so the bottom edge stays `bottomMargin` above
    /// `visibleFrame.minY`, but never below `minimumFrameHeight`. A nil
    /// `visibleFrame` (window on no screen) applies no screen limit.
    static func fittedWindowFrame(
        current: NSRect,
        targetFrameHeight: CGFloat,
        minimumFrameHeight: CGFloat,
        visibleFrame: NSRect?,
        bottomMargin: CGFloat
    ) -> NSRect {
        var height = targetFrameHeight
        if let visibleFrame {
            let availableHeight = current.maxY - (visibleFrame.minY + bottomMargin)
            height = max(minimumFrameHeight, min(targetFrameHeight, availableHeight))
        }
        return NSRect(x: current.minX, y: current.maxY - height, width: current.width, height: height)
    }

    /// `window`'s frame fitted to `contentHeight` on the screen it is on.
    private func fittedFrame(of window: NSWindow, contentHeight: CGFloat) -> NSRect {
        let contentRect = window.contentRect(forFrameRect: window.frame)
        func frameHeight(forContentHeight height: CGFloat) -> CGFloat {
            window.frameRect(forContentRect: NSRect(
                x: contentRect.minX, y: contentRect.minY,
                width: contentRect.width, height: height)).height
        }
        return Self.fittedWindowFrame(
            current: window.frame,
            targetFrameHeight: frameHeight(forContentHeight: contentHeight),
            minimumFrameHeight: frameHeight(forContentHeight: Self.minimumContentHeight),
            visibleFrame: window.screen?.visibleFrame,
            bottomMargin: SettingsLayout.screenBottomMargin)
    }

    private func fitWindowToPreferredHeight() {
        guard let window = view.window else { return }
        let fitted = fittedFrame(of: window, contentHeight: preferredContentSize.height)
        let current = window.frame
        let differs = abs(fitted.minX - current.minX) > 0.5
            || abs(fitted.minY - current.minY) > 0.5
            || abs(fitted.width - current.width) > 0.5
            || abs(fitted.height - current.height) > 0.5
        guard differs else { return }
        window.setFrame(fitted, display: true, animate: false)
    }
}
