import AppKit
import OSLog
import Security

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "SettingsWindowController"
)

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()
    private let opacityLabel = NSTextField(labelWithString: "")
    private let opacitySlider = NSSlider(value: 0.7, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var lastLoadedOpacity = 0.7
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorWell = NSColorWell()
    private let hexField = NSTextField()
    private var lastLoadedPreset: String = "original"
    private var lastLoadedCustomHex: String = ThemeColorPreset.defaultCustomHex
    private var ipcRandomCheckbox: NSButton?
    private var ipcTokenField: NSTextField?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 650),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

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

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY

        saveButton.target = self
        saveButton.action = #selector(savePreset(_:))
        saveButton.bezelStyle = .rounded
        actions.addArrangedSubview(saveButton)

        let openButton = NSButton(title: "Open Config File", target: self, action: #selector(openConfigFile(_:)))
        openButton.bezelStyle = .rounded
        actions.addArrangedSubview(openButton)

        actions.addArrangedSubview(NSView())
        root.addArrangedSubview(actions)

        // Divider before config info section
        let configDivider = NSBox()
        configDivider.boxType = .separator
        configDivider.translatesAutoresizingMaskIntoConstraints = false
        configDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(configDivider)

        // Config info section
        let configTitle = NSTextField(labelWithString: "Ghostty Config Compatibility")
        configTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        root.addArrangedSubview(configTitle)

        let configSubtitle = NSTextField(wrappingLabelWithString: "Calyx reads ~/.config/ghostty/config. Most settings are hot-reloaded when you save the file.")
        configSubtitle.textColor = .secondaryLabelColor
        configSubtitle.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(configSubtitle)

        let managedLabel = NSTextField(wrappingLabelWithString: "The following keys are managed by Calyx for the Glass UI effect and will be overridden:")
        managedLabel.textColor = .secondaryLabelColor
        managedLabel.font = .systemFont(ofSize: 12)
        root.addArrangedSubview(managedLabel)

        let managedKeysText = GhosttyConfigManager.managedKeys.map { "  • \($0)" }.joined(separator: "\n")
        let managedKeysList = NSTextField(wrappingLabelWithString: managedKeysText)
        managedKeysList.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        managedKeysList.textColor = .tertiaryLabelColor
        root.addArrangedSubview(managedKeysList)

        // --- IPC Section ---
        let ipcDivider = NSBox()
        ipcDivider.boxType = .separator
        ipcDivider.translatesAutoresizingMaskIntoConstraints = false
        ipcDivider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(ipcDivider)

        let ipcTitle = NSTextField(labelWithString: "AI Agent IPC")
        ipcTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(ipcTitle)

        let ipcSubtitle = NSTextField(wrappingLabelWithString: "Controls how AI agents authenticate to the Calyx MCP server.")
        ipcSubtitle.textColor = .secondaryLabelColor
        ipcSubtitle.font = .systemFont(ofSize: 13)
        root.addArrangedSubview(ipcSubtitle)

        // Random token checkbox
        let randomCheckbox = NSButton(
            checkboxWithTitle: "Generate random token on each enable",
            target: self,
            action: #selector(ipcRandomTokenDidChange(_:))
        )
        let randomize = UserDefaults.standard.object(forKey: "ipcRandomToken") as? Bool ?? true
        randomCheckbox.state = randomize ? .on : .off
        self.ipcRandomCheckbox = randomCheckbox
        root.addArrangedSubview(randomCheckbox)

        // Token display row
        let tokenField = NSTextField(string: UserDefaults.standard.string(forKey: "ipcToken") ?? "")
        tokenField.isEditable = false
        tokenField.isSelectable = true
        tokenField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tokenField.textColor = .secondaryLabelColor
        tokenField.placeholderString = "(no token yet)"
        tokenField.lineBreakMode = .byTruncatingMiddle
        tokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        self.ipcTokenField = tokenField

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyIPCToken(_:)))
        copyButton.bezelStyle = .rounded

        let regenButton = NSButton(title: "Regenerate", target: self, action: #selector(regenerateIPCToken(_:)))
        regenButton.bezelStyle = .rounded

        let tokenRow = NSStackView(views: [tokenField, copyButton, regenButton])
        tokenRow.orientation = .horizontal
        tokenRow.spacing = 8
        tokenRow.alignment = .centerY
        root.addArrangedSubview(row(label: "Token", control: tokenRow))

        loadPresetIntoUI()
    }

    /// Checks for unsaved changes before app termination.
    /// Returns `true` to proceed, `false` to cancel termination.
    func confirmTermination() -> Bool {
        guard window?.isVisible == true, hasUnsavedChanges() else { return true }

        let alert = NSAlert()
        alert.messageText = "Save settings before quitting?"
        alert.informativeText = "Your settings have unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            savePresetFromUI()
            snapshotCurrentAsLoaded()
            return true
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": lastLoadedOpacity])
            UserDefaults.standard.set(lastLoadedPreset, forKey: "themeColorPreset")
            UserDefaults.standard.set(lastLoadedCustomHex, forKey: "themeColorCustomHex")
            loadPresetIntoUI()
            GhosttyAppController.shared.reloadConfig()
            return true
        default:
            // Do not revert UserDefaults here (unlike windowShouldClose Cancel).
            // The user wants to keep editing their in-progress changes.
            return false
        }
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
        NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": opacity])
        applyOpacityToRunningSurfaces()
        fieldDidChange(sender)
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
        fieldDidChange(sender)
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
        fieldDidChange(sender)
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
        fieldDidChange(sender)
    }

    @objc private func savePreset(_ sender: Any?) {
        savePresetFromUI()
        snapshotCurrentAsLoaded()
    }

    @objc func reloadConfig() {
        // Ghostty reloads config automatically via file watcher
        // This is a manual trigger if needed
        logger.info("Config reload requested")
    }

    @objc private func fieldDidChange(_ sender: Any?) {
        refreshSaveButtonState()
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

        // Refresh IPC fields
        let ipcRandom = UserDefaults.standard.object(forKey: "ipcRandomToken") as? Bool ?? true
        ipcRandomCheckbox?.state = ipcRandom ? .on : .off
        ipcTokenField?.stringValue = UserDefaults.standard.string(forKey: "ipcToken") ?? ""

        snapshotCurrentAsLoaded()
        refreshSaveButtonState()
    }

    private func savePresetFromUI() {
        // Theme color changes are written to UserDefaults immediately for live preview.
        // Only glass opacity needs explicit persistence here.
        let opacity = max(0.0, min(1.0, opacitySlider.doubleValue))
        UserDefaults.standard.set(opacity, forKey: "terminalGlassOpacity")
        NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": opacity])
        applyOpacityToRunningSurfaces()
    }

    private func applyOpacityToRunningSurfaces() {
        // reloadConfig(soft: false) handles both disk reload and window propagation
        // via ConfigReloadCoordinator with 200ms debounce.
        GhosttyAppController.shared.reloadConfig()
    }

    private func snapshotCurrentAsLoaded() {
        lastLoadedOpacity = opacitySlider.doubleValue
        lastLoadedPreset = UserDefaults.standard.string(forKey: "themeColorPreset") ?? "original"
        lastLoadedCustomHex = UserDefaults.standard.string(forKey: "themeColorCustomHex") ?? ThemeColorPreset.defaultCustomHex
        refreshSaveButtonState()
    }

    private func hasUnsavedChanges() -> Bool {
        let currentOpacity = opacitySlider.doubleValue
        let opacityChanged = abs(currentOpacity - lastLoadedOpacity) > 0.0001
        let currentPreset = UserDefaults.standard.string(forKey: "themeColorPreset") ?? "original"
        let currentCustomHex = UserDefaults.standard.string(forKey: "themeColorCustomHex") ?? ThemeColorPreset.defaultCustomHex
        let themeChanged = currentPreset != lastLoadedPreset || currentCustomHex != lastLoadedCustomHex
        return opacityChanged || themeChanged
    }

    private func refreshSaveButtonState() {
        saveButton.isEnabled = hasUnsavedChanges()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges() else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Your Glass settings have unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            savePreset(nil)
            return !hasUnsavedChanges()
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": lastLoadedOpacity])
            UserDefaults.standard.set(lastLoadedPreset, forKey: "themeColorPreset")
            UserDefaults.standard.set(lastLoadedCustomHex, forKey: "themeColorCustomHex")
            loadPresetIntoUI()
            GhosttyAppController.shared.reloadConfig()
            return true
        default:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            NotificationCenter.default.post(name: .glassOpacityDidChange, object: nil, userInfo: ["opacity": lastLoadedOpacity])
            UserDefaults.standard.set(lastLoadedPreset, forKey: "themeColorPreset")
            UserDefaults.standard.set(lastLoadedCustomHex, forKey: "themeColorCustomHex")
            loadPresetIntoUI()
            GhosttyAppController.shared.reloadConfig()
            return false
        }
    }

    // MARK: - IPC Token Actions

    @objc private func ipcRandomTokenDidChange(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "ipcRandomToken")
    }

    @objc private func copyIPCToken(_ sender: Any?) {
        let token = UserDefaults.standard.string(forKey: "ipcToken") ?? ""
        guard !token.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    @objc private func regenerateIPCToken(_ sender: Any?) {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "ipcToken")
        ipcTokenField?.stringValue = token
    }
}
