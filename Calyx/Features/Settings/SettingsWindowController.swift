import AppKit
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

    private let tabViewController = SettingsTabViewController()

    /// Fixed width for every pane so switching tabs only ever changes the
    /// window's height, matching standard macOS Settings behavior.
    private static let paneWidth: CGFloat = 560
    private static let paneContentInset: CGFloat = 24

    #if DEBUG
    /// Test seam: overrides the root `commandTrackingDidChange(_:)`
    /// resolves against, instead of
    /// `ShellIntegrationInstaller.defaultInstallDirectory` -- same shape
    /// as `AppDelegate._shellIntegrationRootForTesting`. DO NOT use from
    /// production code.
    var _shellIntegrationRootForTesting: URL?
    #endif

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.paneWidth, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        setupContent()
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
                width: Self.paneWidth,
                contentInset: Self.paneContentInset
            )
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
    private struct SectionHeading {
        let title: String?
        let subtitle: String?
    }

    private func sectionHeading(for row: SettingsRow) -> SectionHeading? {
        switch row {
        case .themeColorPreset:
            return SectionHeading(title: "Theme Color", subtitle: "Choose a preset or pick a custom color.")
        case .glassOpacity:
            return SectionHeading(title: "Glass", subtitle: "Controls the transparency of the glass effect.")
        case .smoothScrolling:
            return SectionHeading(title: "Scrolling", subtitle: nil)
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
        case .agentResume:
            return SectionHeading(
                title: "Agent Resume",
                subtitle: "When a persistent session reattaches to a saved AI agent CLI conversation, offer to resume it."
            )
        case .cockpitAutoApprove:
            return SectionHeading(
                title: "Command Approval",
                subtitle: "Applies to agent-initiated pane commands (run, send keys, palette) and to CLI agents' "
                    + "(Claude Code, Codex) tool-call approval requests. Off = ask every time."
            )
        case .commandTracking:
            return SectionHeading(title: "Command Tracking", subtitle: "Changes apply to new terminals only.")
        case .agentHookApproval:
            return SectionHeading(
                title: "Agent Hook Approval",
                subtitle: "Routes CLI agents' (Claude Code, Codex) tool-permission prompts to the Calyx approval banner. Off = agents prompt in their own pane, as before."
            )
        case .openConfigFileFooter:
            return SectionHeading(title: nil, subtitle: nil)
        case .themeColorWell, .themeColorHex, .lspRequireConfirmation,
             .historyPersistence, .agentResumeAutoExecute,
             .openSessionBrowserButton:
            return nil
        }
    }

    private func paneStack(for pane: SettingsPane) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let rowsInPane = SettingsRow.allCases.filter { $0.pane == pane }
        for (index, settingsRow) in rowsInPane.enumerated() {
            if let heading = sectionHeading(for: settingsRow) {
                if index > 0 {
                    stack.addArrangedSubview(sectionDivider())
                }
                if let title = heading.title {
                    stack.addArrangedSubview(sectionTitleLabel(title))
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
        case .smoothScrolling:
            return smoothScrollingRow()
        case .lspAutoInstall:
            return lspAutoInstallRow()
        case .lspRequireConfirmation:
            return lspRequireConfirmationRow()
        case .persistentSessions:
            return persistentSessionsRow()
        case .historyPersistence:
            return historyPersistenceRow()
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
        opacityRow.spacing = 12
        opacityRow.alignment = .centerY
        let opacityText = NSTextField(labelWithString: "Glass opacity")
        opacityText.font = .systemFont(ofSize: 13, weight: .medium)
        opacityText.setContentHuggingPriority(.required, for: .horizontal)
        opacityRow.addArrangedSubview(opacityText)
        opacityRow.addArrangedSubview(opacitySlider)
        opacityRow.addArrangedSubview(opacityLabel)
        return opacityRow
    }

    private func smoothScrollingRow() -> NSView {
        let smoothScrollSwitch = NSSwitch()
        smoothScrollSwitch.setAccessibilityIdentifier(AccessibilityID.Settings.smoothScrollingSwitch)
        smoothScrollSwitch.state = (UserDefaults.standard.object(forKey: "smoothScrollEnabled") as? Bool ?? true) ? .on : .off
        smoothScrollSwitch.target = self
        smoothScrollSwitch.action = #selector(smoothScrollDidChange(_:))
        return controlRow(label: "Smooth Scrolling", control: smoothScrollSwitch)
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

    /// Pure mapping from a Sessions-pane toggle row to the SessionSettings
    /// value it must seed its initial `.state` from. Extracted as its own
    /// function (rather than reading SessionSettings directly inline in
    /// each row builder) because SettingsWindowController.shared's
    /// one-shot, process-lifetime construction makes the seeding behavior
    /// unobservable through the real singleton in a test -- this has none
    /// of that lifetime, so a test can set SessionSettings directly and
    /// call it standalone.
    static func sessionToggleInitialState(for row: SettingsRow) -> Bool {
        switch row {
        case .persistentSessions: return SessionSettings.persistentSessionsEnabled
        case .historyPersistence: return SessionSettings.historyPersistenceEnabled
        case .agentResume: return SessionSettings.agentResumeEnabled
        case .agentResumeAutoExecute: return SessionSettings.agentResumeAutoExecute
        case .cockpitAutoApprove: return CockpitSettings.autoApproveEnabled
        case .commandTracking: return CommandTrackingSettings.trackingEnabled
        case .agentHookApproval: return CockpitSettings.agentHookApprovalEnabled
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

    private func sessionBrowserButtonRow() -> NSView {
        let openBrowserButton = NSButton(
            title: "Open Session Browser", target: self, action: #selector(openSessionBrowser(_:))
        )
        openBrowserButton.bezelStyle = .rounded
        let sessionsActions = NSStackView()
        sessionsActions.orientation = .horizontal
        sessionsActions.addArrangedSubview(openBrowserButton)
        sessionsActions.addArrangedSubview(NSView())
        return sessionsActions
    }

    private func configFileFooterRow() -> NSView {
        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        let openButton = NSButton(title: "Open Config File", target: self, action: #selector(openConfigFile(_:)))
        openButton.bezelStyle = .rounded
        actions.addArrangedSubview(openButton)

        let helpButton = NSButton(title: "", target: self, action: #selector(showConfigHelp(_:)))
        helpButton.bezelStyle = .helpButton
        actions.addArrangedSubview(helpButton)

        actions.addArrangedSubview(NSView())
        return actions
    }

    private func sectionTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        return label
    }

    private func sectionDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
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

    @objc private func smoothScrollDidChange(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "smoothScrollEnabled")
        if !enabled {
            NotificationCenter.default.post(name: .smoothScrollSettingChanged, object: nil)
        }
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
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        let text = NSTextField(labelWithString: label)
        text.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(control)
        return stack
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
/// preferredContentSize on selection: a pane whose content fits within
/// the screen sizes the window exactly to that content (the scroller
/// stays auto-hidden, so this is visually identical to a plain
/// fixed-height view), while a pane taller than the screen's visible
/// height instead caps the window there and reveals the scroller, so
/// its trailing rows stay reachable instead of being clipped below the
/// window with no way to scroll to them.
@MainActor
private final class SettingsPaneContentViewController: NSViewController {

    /// Vertical space reserved for the window's title bar, the Settings
    /// toolbar, and top/bottom margins when a pane's natural content
    /// height must be capped to the screen's visible height.
    private static let verticalChrome: CGFloat = 120
    /// Floor under the height cap so a missing/tiny screen can never
    /// collapse the window to something unusably short.
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
        documentView.layoutSubtreeIfNeeded()
        let naturalHeight = documentView.fittingSize.height
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? naturalHeight) - Self.verticalChrome
        let cappedHeight = max(Self.minimumContentHeight, min(naturalHeight, maxHeight))
        preferredContentSize = NSSize(width: width, height: cappedHeight)
    }

    /// Grow (or shrink) the window to this pane's `preferredContentSize`
    /// height. NSTabViewController sizes each selected pane's view to its
    /// `preferredContentSize`, but when a pane is loaded lazily on tab
    /// selection it reads that size before this controller has computed it
    /// and so leaves the window at the previously shown (shorter) pane's
    /// height: the taller pane's scroll view then overflows the window's
    /// bottom edge, and because its clip view fills that same overflowing
    /// frame there is no scroll range, so the pane's trailing rows are
    /// clipped off-screen with no way to reach them. Matching the window's
    /// content height to the pane here shows the whole pane on any screen
    /// tall enough for it, and leaves the scroll view to scroll only when
    /// the screen-height cap made the window shorter than the content.
    override func viewDidAppear() {
        super.viewDidAppear()
        guard let window = view.window else { return }
        var contentRect = window.contentRect(forFrameRect: window.frame)
        let targetHeight = preferredContentSize.height
        guard abs(contentRect.height - targetHeight) > 0.5 else { return }
        // Keep the title bar fixed and grow/shrink downward: in AppKit's
        // bottom-left window coordinates that means moving the origin by
        // the height delta as the height changes.
        contentRect.origin.y += contentRect.height - targetHeight
        contentRect.size.height = targetHeight
        window.setFrame(window.frameRect(forContentRect: contentRect), display: true, animate: false)
    }
}
