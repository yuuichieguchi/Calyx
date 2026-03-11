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
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var lastLoadedOpacity = 0.82

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
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/calyx", isDirectory: true)
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

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || !trimmed.contains("=") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "background-opacity":
                opacity = Double(parts[1]) ?? opacity
            default:
                break
            }
        }
        opacitySlider.doubleValue = max(0.3, min(1.0, opacity))
        updateOpacityLabel()
        snapshotCurrentAsLoaded()
        refreshSaveButtonState()
    }

    private func savePresetFromUI() throws {
        let opacity = max(0.3, min(1.0, opacitySlider.doubleValue))

        let fm = FileManager.default
        let dir = try calyxConfigDirectory()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = try presetFileURL()
        let startMarker = "# --- Calyx Glass Preset (managed) ---"
        let endMarker = "# --- End Calyx Glass Preset ---"

        // Preserve non-opacity settings from existing file
        var preservedLines: [String] = []
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            for line in existing.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
                if trimmed.hasPrefix("background-opacity") { continue }
                preservedLines.append(String(line))
            }
        }

        var lines = [startMarker]
        lines.append("background-opacity = \(String(format: "%.2f", opacity))")
        lines.append(contentsOf: preservedLines)
        lines.append(endMarker)

        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
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
            loadPresetIntoUI()
            return true
        default:
            return false
        }
    }
}
