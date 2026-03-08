import AppKit
import GhosttyKit
import OSLog

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.calyx.terminal",
    category: "SettingsWindowController"
)

@MainActor
class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()
    private let opacityLabel = NSTextField(labelWithString: "")
    private let opacitySlider = NSSlider(value: 0.82, minValue: 0.3, maxValue: 1.0, target: nil, action: nil)
    private let clickToMoveCheckbox = NSButton(checkboxWithTitle: "Option+Clickでカーソル移動を有効化", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var lastLoadedOpacity = 0.82
    private var lastLoadedClickToMove = true

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

        let subtitle = NSTextField(labelWithString: "These values are saved to Calyx's dedicated glass preset file.")
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
        let opacityText = NSTextField(labelWithString: "Background opacity")
        opacityText.font = .systemFont(ofSize: 13, weight: .medium)
        opacityText.setContentHuggingPriority(.required, for: .horizontal)
        opacityRow.addArrangedSubview(opacityText)
        opacityRow.addArrangedSubview(opacitySlider)
        opacityRow.addArrangedSubview(opacityLabel)
        root.addArrangedSubview(opacityRow)

        clickToMoveCheckbox.target = self
        clickToMoveCheckbox.action = #selector(fieldDidChange(_:))
        clickToMoveCheckbox.state = .on
        root.addArrangedSubview(clickToMoveCheckbox)

        let clickToMoveNote = NSTextField(wrappingLabelWithString:
            "Note: This feature works best on English prompts. On Japanese or full-width text lines, cursor placement can be offset due to terminal cell-width limitations."
        )
        clickToMoveNote.textColor = .secondaryLabelColor
        clickToMoveNote.font = .systemFont(ofSize: 12)
        clickToMoveNote.maximumNumberOfLines = 3
        root.addArrangedSubview(clickToMoveNote)

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

        loadPresetIntoUI()
    }

    func showSettings() {
        loadPresetIntoUI()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openConfigFile(_ sender: Any?) {
        if let app = GhosttyAppController.shared.app {
            GhosttyFFI.appOpenConfig(app)
        }
    }

    @objc private func opacityDidChange(_ sender: Any?) {
        updateOpacityLabel()
        fieldDidChange(sender)
    }

    @objc private func savePreset(_ sender: Any?) {
        do {
            try savePresetFromUI()
            GhosttyAppController.shared.reloadConfig(soft: false)
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.applyCurrentGhosttyConfigToAllWindows()
            }
            snapshotCurrentAsLoaded()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to Save Settings"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
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

    private func calyxConfigDirectory() throws -> URL {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            throw NSError(domain: "Calyx.Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing bundle identifier"])
        }
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "Calyx.Settings", code: 2, userInfo: [NSLocalizedDescriptionKey: "Application Support directory not found"])
        }
        return appSupport.appendingPathComponent(bundleID, isDirectory: true)
    }

    private func presetFileURL() throws -> URL {
        try calyxConfigDirectory().appendingPathComponent("calyx-glass.conf", isDirectory: false)
    }

    private func loadPresetIntoUI() {
        guard let url = try? presetFileURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            opacitySlider.doubleValue = 0.82
            updateOpacityLabel()
            snapshotCurrentAsLoaded()
            return
        }

        var opacity = 0.82
        var clickToMove = true

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || !trimmed.contains("=") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background-opacity":
                opacity = Double(parts[1]) ?? opacity
            case "cursor-click-to-move":
                clickToMove = NSString(string: parts[1]).boolValue
            default:
                break
            }
        }
        opacitySlider.doubleValue = max(0.3, min(1.0, opacity))
        clickToMoveCheckbox.state = clickToMove ? .on : .off
        updateOpacityLabel()
        snapshotCurrentAsLoaded()
        refreshSaveButtonState()
    }

    private func savePresetFromUI() throws {
        let opacity = max(0.3, min(1.0, opacitySlider.doubleValue))
        let clickToMove = (clickToMoveCheckbox.state == .on)

        let preset = """
        # --- Calyx Glass Preset (managed) ---
        background-opacity = \(String(format: "%.2f", opacity))
        cursor-click-to-move = \(clickToMove ? "true" : "false")
        # --- End Calyx Glass Preset ---
        """

        let fm = FileManager.default
        let dir = try calyxConfigDirectory()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try (preset + "\n").write(to: try presetFileURL(), atomically: true, encoding: .utf8)
    }

    private func snapshotCurrentAsLoaded() {
        lastLoadedOpacity = opacitySlider.doubleValue
        lastLoadedClickToMove = (clickToMoveCheckbox.state == .on)
        refreshSaveButtonState()
    }

    private func hasUnsavedChanges() -> Bool {
        let currentOpacity = opacitySlider.doubleValue
        let currentClickToMove = (clickToMoveCheckbox.state == .on)
        let opacityChanged = abs(currentOpacity - lastLoadedOpacity) > 0.0001
        return opacityChanged || currentClickToMove != lastLoadedClickToMove
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
            loadPresetIntoUI()
            return true
        default:
            return false
        }
    }
}
