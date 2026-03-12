import AppKit
import OSLog

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

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
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

        let title = NSTextField(labelWithString: "Terminal Glass")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        root.addArrangedSubview(title)

        let subtitle = NSTextField(labelWithString: "Controls the transparency of the terminal glass effect.")
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
        snapshotCurrentAsLoaded()
        refreshSaveButtonState()
    }

    private func savePresetFromUI() {
        let opacity = max(0.0, min(1.0, opacitySlider.doubleValue))
        UserDefaults.standard.set(opacity, forKey: "terminalGlassOpacity")
        applyOpacityToRunningSurfaces()
    }

    private func applyOpacityToRunningSurfaces() {
        GhosttyAppController.shared.reloadConfig()
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.applyCurrentGhosttyConfigToAllWindows()
        }
    }

    private func snapshotCurrentAsLoaded() {
        lastLoadedOpacity = opacitySlider.doubleValue
        refreshSaveButtonState()
    }

    private func hasUnsavedChanges() -> Bool {
        let currentOpacity = opacitySlider.doubleValue
        let opacityChanged = abs(currentOpacity - lastLoadedOpacity) > 0.0001
        return opacityChanged
    }

    private func refreshSaveButtonState() {
        saveButton.isEnabled = hasUnsavedChanges()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges() else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes before closing?"
        alert.informativeText = "Your Terminal Glass settings have unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            savePreset(nil)
            return !hasUnsavedChanges()
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            loadPresetIntoUI()
            return true
        default:
            UserDefaults.standard.set(lastLoadedOpacity, forKey: "terminalGlassOpacity")
            loadPresetIntoUI()
            return false
        }
    }
}
