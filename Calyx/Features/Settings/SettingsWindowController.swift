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
    private let persistentSessionsSwitch = NSSwitch()
    private let agentResumeSwitch = NSSwitch()
    private let agentResumeAutoExecuteSwitch = NSSwitch()
    private let historyPersistenceSwitch = NSSwitch()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupContent() {
        guard let window = self.window,
              let contentView = window.contentView else { return }

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            root.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
        ])

        // --- Theme Color Section ---
        let themeTitle = NSTextField(labelWithString: "Theme Color")
        themeTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(themeTitle)

        let themeSubtitle = NSTextField(labelWithString: "Choose a preset or pick a custom color.")
        themeSubtitle.textColor = .secondaryLabelColor
        themeSubtitle.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(themeSubtitle)

        // Preset popup
        let presets = ThemeColorPreset.allCases.filter { $0 != .custom }
        for preset in presets {
            presetPopup.addItem(withTitle: preset.displayName)
        }
        presetPopup.addItem(withTitle: "Custom")
        presetPopup.target = self
        presetPopup.action = #selector(presetDidChange(_:))
        root.addArrangedSubview(row(label: "Preset", control: presetPopup))

        // Color well
        colorWell.color = ThemeColorPreset.original.color
        colorWell.target = self
        colorWell.action = #selector(colorWellDidChange(_:))
        root.addArrangedSubview(row(label: "Color", control: colorWell))

        // Hex field
        hexField.stringValue = ThemeColorPreset.defaultCustomHex
        hexField.placeholderString = "#RRGGBB"
        hexField.target = self
        hexField.action = #selector(hexFieldDidCommit(_:))
        hexField.widthAnchor.constraint(equalToConstant: 100).isActive = true
        root.addArrangedSubview(row(label: "Hex", control: hexField))

        // Separator between Theme Color and Glass
        let themeDivider = NSBox()
        themeDivider.boxType = .separator
        themeDivider.translatesAutoresizingMaskIntoConstraints = false
        themeDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(themeDivider)

        // --- Glass Section ---
        let title = NSTextField(labelWithString: "Glass")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Controls the transparency of the glass effect.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(subtitle)

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
        root.addArrangedSubview(opacityRow)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(divider)

        // --- Scrolling Section ---
        let scrollingTitle = NSTextField(labelWithString: "Scrolling")
        scrollingTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(scrollingTitle)

        let smoothScrollSwitch = NSSwitch()
        smoothScrollSwitch.state = (UserDefaults.standard.object(forKey: "smoothScrollEnabled") as? Bool ?? true) ? .on : .off
        smoothScrollSwitch.target = self
        smoothScrollSwitch.action = #selector(smoothScrollDidChange(_:))
        root.addArrangedSubview(row(label: "Smooth Scrolling", control: smoothScrollSwitch))

        let scrollingDivider = NSBox()
        scrollingDivider.boxType = .separator
        scrollingDivider.translatesAutoresizingMaskIntoConstraints = false
        scrollingDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(scrollingDivider)

        // --- LSP Section ---
        let lspTitle = NSTextField(labelWithString: "LSP Proxy")
        lspTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(lspTitle)

        let lspSubtitle = NSTextField(labelWithString: "Calyx hosts language servers and exposes them to AI agents over MCP. When a server is missing, Calyx can install it automatically.")
        lspSubtitle.textColor = .secondaryLabelColor
        lspSubtitle.font = .systemFont(ofSize: 13)
        lspSubtitle.maximumNumberOfLines = 0
        lspSubtitle.preferredMaxLayoutWidth = 460
        root.addArrangedSubview(lspSubtitle)

        let autoInstallSwitch = NSSwitch()
        autoInstallSwitch.state = LSPSettings.autoInstallEnabled ? .on : .off
        autoInstallSwitch.target = self
        autoInstallSwitch.action = #selector(lspAutoInstallDidChange(_:))
        root.addArrangedSubview(row(label: "Auto-install language servers", control: autoInstallSwitch))

        let requireConfirmSwitch = NSSwitch()
        requireConfirmSwitch.state = LSPSettings.requireInstallConfirmation ? .on : .off
        requireConfirmSwitch.target = self
        requireConfirmSwitch.action = #selector(lspRequireConfirmationDidChange(_:))
        root.addArrangedSubview(row(label: "Confirm before each install step", control: requireConfirmSwitch))

        let lspDivider = NSBox()
        lspDivider.boxType = .separator
        lspDivider.translatesAutoresizingMaskIntoConstraints = false
        lspDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(lspDivider)

        // --- Sessions Section ---
        let sessionsTitle = NSTextField(labelWithString: "Sessions")
        sessionsTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(sessionsTitle)

        let sessionsSubtitle = NSTextField(labelWithString: "Persistent terminal sessions survive a crash or quit and can be reattached later, from this window or from the session browser.")
        sessionsSubtitle.textColor = .secondaryLabelColor
        sessionsSubtitle.font = .systemFont(ofSize: 13)
        sessionsSubtitle.maximumNumberOfLines = 0
        sessionsSubtitle.preferredMaxLayoutWidth = 460
        root.addArrangedSubview(sessionsSubtitle)

        persistentSessionsSwitch.state = SessionSettings.persistentSessionsEnabled ? .on : .off
        persistentSessionsSwitch.target = self
        persistentSessionsSwitch.action = #selector(persistentSessionsDidChange(_:))
        root.addArrangedSubview(row(label: "Enable persistent sessions", control: persistentSessionsSwitch))

        historyPersistenceSwitch.state = SessionSettings.historyPersistenceEnabled ? .on : .off
        historyPersistenceSwitch.target = self
        historyPersistenceSwitch.action = #selector(historyPersistenceDidChange(_:))
        root.addArrangedSubview(row(label: "Persist session history to disk", control: historyPersistenceSwitch))

        agentResumeSwitch.state = SessionSettings.agentResumeEnabled ? .on : .off
        agentResumeSwitch.target = self
        agentResumeSwitch.action = #selector(agentResumeDidChange(_:))
        root.addArrangedSubview(row(label: "Offer to resume agent CLI conversations", control: agentResumeSwitch))

        agentResumeAutoExecuteSwitch.state = SessionSettings.agentResumeAutoExecute ? .on : .off
        agentResumeAutoExecuteSwitch.target = self
        agentResumeAutoExecuteSwitch.action = #selector(agentResumeAutoExecuteDidChange(_:))
        root.addArrangedSubview(row(label: "Auto-execute resume (skip confirmation)", control: agentResumeAutoExecuteSwitch))

        let openBrowserButton = NSButton(
            title: "Open Session Browser", target: self, action: #selector(openSessionBrowser(_:))
        )
        openBrowserButton.bezelStyle = .rounded
        let sessionsActions = NSStackView()
        sessionsActions.orientation = .horizontal
        sessionsActions.addArrangedSubview(openBrowserButton)
        sessionsActions.addArrangedSubview(NSView())
        root.addArrangedSubview(sessionsActions)

        let sessionsDivider = NSBox()
        sessionsDivider.boxType = .separator
        sessionsDivider.translatesAutoresizingMaskIntoConstraints = false
        sessionsDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(sessionsDivider)

        // --- Config Actions ---
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
        root.addArrangedSubview(actions)

        loadPresetIntoUI()
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

    private func row(label: String, control: NSView) -> NSView {
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
