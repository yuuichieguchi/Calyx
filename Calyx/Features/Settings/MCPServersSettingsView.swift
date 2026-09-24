//
//  MCPServersSettingsView.swift
//  Calyx
//
//  Content of Settings > MCP Apps (`SettingsPane.mcpServers`) below its heading, built from the
//  same `SettingsLayout` metrics as every other pane: banners for AI
//  Agent IPC being off and for an unreadable config file, then either
//  the empty state or the Add Server / Import JSON buttons and one row
//  per configured server, rows separated like sections.
//
//  The content follows `MCPServerSettingsModel` through observation
//  tracking and is rebuilt on every change; `onContentChange` then lets
//  the pane measure its height again. The add, edit and import sheets
//  are the SwiftUI sheets, presented as AppKit sheets of the Settings
//  window; each closes through the close action it is given.
//

import AppKit
import Observation
import SwiftUI

@MainActor
final class MCPServersSettingsView: NSView {

    private let model: MCPServerSettingsModel
    private let onContentChange: () -> Void
    private let stack = SettingsLayout.column()

    /// Why the edit sheet could not open, shown until the next attempt.
    private var editLoadError: String?
    /// Rows whose Details are expanded; kept across rebuilds.
    private var expandedDetails: Set<MCPServerID> = []
    /// Targets of the current content's controls. Controls hold their
    /// targets weakly, so the targets live here until the next rebuild.
    private var actionTargets: [MCPServersSettingsAction] = []
    /// Identifies the current observation. A rebuild for a local change
    /// starts a new one, and the change handler of an older one does
    /// nothing, so only one observation is ever armed.
    private var observationGeneration = 0

    init(model: MCPServerSettingsModel, onContentChange: @escaping () -> Void) {
        self.model = model
        self.onContentChange = onContentChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observeModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Observation

    /// Rebuilds the content while tracking every model property it reads,
    /// and rebuilds again on the first change of any of them.
    private func observeModel() {
        observationGeneration += 1
        let generation = observationGeneration
        withObservationTracking {
            rebuild()
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observationGeneration == generation else { return }
                self.observeModel()
                self.onContentChange()
            }
        }
    }

    /// Rebuilds the content outside a model change (a local state change).
    private func rebuildForLocalChange() {
        observeModel()
        onContentChange()
    }

    // MARK: - Content

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        actionTargets.removeAll()

        guard let registry = model.registry else { return }
        if MCPServerRowStatusResolver.ipcOffBannerVisible(ipcEnabled: model.ipcEnabled) {
            stack.addArrangedSubview(banner(
                "AI Agent IPC is off. Agents cannot reach these servers until it is turned on in the Agents pane.",
                symbolName: "info.circle",
                identifier: AccessibilityID.MCPServersSettings.ipcDisabledBanner
            ))
        }
        if let loadError = registry.loadError {
            stack.addArrangedSubview(banner(
                MCPServerSettingsModel.configErrorText(loadError),
                symbolName: "exclamationmark.triangle",
                identifier: AccessibilityID.MCPServersSettings.configErrorBanner
            ))
        }
        if let editLoadError {
            stack.addArrangedSubview(errorLabel(editLoadError))
        }
        let servers = registry.servers
        if servers.isEmpty {
            stack.addArrangedSubview(emptyState())
        } else {
            stack.addArrangedSubview(addAndImportButtons())
            stack.addArrangedSubview(serverList(servers))
        }
    }

    /// The same shape as the AI Agent IPC section's status and Refresh
    /// rows: a status text, then the buttons.
    private func emptyState() -> NSView {
        let message = SettingsLayout.statusLabel()
        message.attributedStringValue = SettingsLayout.statusText(
            "No MCP Apps\nAdd a server, or import the JSON an agent CLI uses for its own MCP servers."
        )
        let column = SettingsLayout.column([message, addAndImportButtons()])
        Self.markContainer(column, identifier: AccessibilityID.MCPServersSettings.emptyState)
        return column
    }

    private func addAndImportButtons() -> NSView {
        let add = button("Add Server", identifier: AccessibilityID.MCPServersSettings.addButton) { [weak self] in
            self?.presentEditor(.create)
        }
        let importJSON = button("Import JSON", identifier: AccessibilityID.MCPServersSettings.importButton) { [weak self] in
            self?.presentImport()
        }
        return SettingsLayout.buttonRow([add, importJSON])
    }

    private func serverList(_ servers: [MCPServerConfig]) -> NSView {
        let list = SettingsLayout.column()
        for (index, config) in servers.enumerated() {
            if index > 0 {
                list.addArrangedSubview(SettingsLayout.sectionDivider())
            }
            list.addArrangedSubview(serverRow(config))
        }
        Self.markContainer(list, identifier: AccessibilityID.MCPServersSettings.list)
        return list
    }

    /// One configured server: the name with the enable switch; the status
    /// with the alias, transport and sign-in state as detail lines; the
    /// stderr tail and the row's error when present; the action buttons;
    /// and the Details disclosure when there is anything to show.
    private func serverRow(_ config: MCPServerConfig) -> NSView {
        let serverID = config.id.rawValue
        let rowState = model.rowState(for: config)
        let live = model.liveStatus[config.id]

        let enabledSwitch = NSSwitch()
        enabledSwitch.state = config.isEnabled ? .on : .off
        enabledSwitch.setAccessibilityIdentifier(AccessibilityID.MCPServersSettings.rowEnabledSwitch(serverID))
        bind(enabledSwitch) { [weak self] control in
            guard let self, let toggle = control as? NSSwitch else { return }
            self.model.setEnabled(toggle.state == .on, for: config)
        }
        let row = SettingsLayout.column([SettingsLayout.controlRow(label: config.displayName, control: enabledSwitch)])

        var statusLines = [rowState.statusText, "\(config.alias.rawValue) · \(Self.transportSummary(config.transport))"]
        if let live, let signInText = MCPServerRowStatusResolver.signInText(authState: live.authState) {
            statusLines.append(signInText)
        }
        let status = SettingsLayout.statusLabel()
        status.attributedStringValue = SettingsLayout.statusText(statusLines.joined(separator: "\n"))
        status.setAccessibilityIdentifier(AccessibilityID.MCPServersSettings.rowStatus(serverID))
        row.addArrangedSubview(status)

        if let stderrTail = rowState.stderrTail, !stderrTail.isEmpty {
            let stderrLabel = SettingsLayout.statusLabel()
            stderrLabel.stringValue = stderrTail
            stderrLabel.font = .monospacedSystemFont(ofSize: SettingsLayout.statusFont.pointSize, weight: .regular)
            stderrLabel.textColor = .secondaryLabelColor
            stderrLabel.isSelectable = true
            row.addArrangedSubview(stderrLabel)
        }
        if let rowError = model.rowErrors[config.id] {
            row.addArrangedSubview(errorLabel(rowError))
        }
        row.addArrangedSubview(rowButtons(config, rowState: rowState, connectionState: live?.connectionState))
        if let live, !live.exclusions.isEmpty || live.instructions != nil {
            row.addArrangedSubview(detailsDisclosure(config.id))
            if expandedDetails.contains(config.id) {
                row.addArrangedSubview(details(live))
            }
        }
        return row
    }

    private func rowButtons(
        _ config: MCPServerConfig,
        rowState: MCPServerRowStatusResolver.RowState,
        connectionState: MCPConnectionState?
    ) -> NSView {
        let serverID = config.id.rawValue
        var buttons: [NSView] = []
        if rowState.showRetry {
            buttons.append(button("Retry", identifier: AccessibilityID.MCPServersSettings.rowRetryButton(serverID)) { [weak self] in
                self?.model.retry(config.id)
            })
        }
        if rowState.showSignIn {
            buttons.append(button("Sign In", identifier: AccessibilityID.MCPServersSettings.rowSignInButton(serverID)) { [weak self] in
                self?.model.signIn(config.id)
            })
        }
        if connectionState == .authorizing, model.isSigningIn(config.id) {
            buttons.append(button(
                "Cancel Sign-In", identifier: AccessibilityID.MCPServersSettings.rowCancelSignInButton(serverID)
            ) { [weak self] in
                self?.model.cancelSignIn(config.id)
            })
        }
        if rowState.showSignOut {
            buttons.append(button("Sign Out", identifier: AccessibilityID.MCPServersSettings.rowSignOutButton(serverID)) { [weak self] in
                self?.model.signOut(config.id)
            })
        }
        buttons.append(button("Edit", identifier: AccessibilityID.MCPServersSettings.rowEditButton(serverID)) { [weak self] in
            self?.beginEditing(config)
        })
        buttons.append(button("Remove", identifier: AccessibilityID.MCPServersSettings.rowRemoveButton(serverID)) { [weak self] in
            self?.model.remove(config.id)
        })
        return SettingsLayout.buttonRow(buttons)
    }

    /// A disclosure triangle labelled "Details", laid out as a label +
    /// control row with the control first.
    private func detailsDisclosure(_ serverID: MCPServerID) -> NSView {
        let disclosure = NSButton(title: "", target: nil, action: nil)
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = expandedDetails.contains(serverID) ? .on : .off
        disclosure.setAccessibilityLabel("Details")
        bind(disclosure) { [weak self] control in
            guard let self, let toggle = control as? NSButton else { return }
            if toggle.state == .on {
                self.expandedDetails.insert(serverID)
            } else {
                self.expandedDetails.remove(serverID)
            }
            self.rebuildForLocalChange()
        }
        let row = NSStackView()
        row.addArrangedSubview(disclosure)
        row.addArrangedSubview(NSTextField(labelWithString: "Details"))
        row.orientation = .horizontal
        row.spacing = SettingsLayout.controlSpacing
        row.alignment = .centerY
        return row
    }

    /// The excluded tools and the server instructions, each a status text
    /// with its title as the first line.
    private func details(_ live: MCPServerSettingsModel.LiveStatus) -> NSView {
        let column = SettingsLayout.column()
        if !live.exclusions.isEmpty {
            let exclusions = SettingsLayout.statusLabel()
            let lines = live.exclusions.map { "\($0.upstreamToolName): \($0.reason)" }
            exclusions.attributedStringValue = SettingsLayout.statusText((["Excluded tools"] + lines).joined(separator: "\n"))
            column.addArrangedSubview(exclusions)
        }
        if let instructions = live.instructions {
            let instructionsLabel = SettingsLayout.statusLabel()
            instructionsLabel.attributedStringValue = SettingsLayout.statusText("Server instructions\n\(instructions)")
            instructionsLabel.isSelectable = true
            column.addArrangedSubview(instructionsLabel)
        }
        return column
    }

    /// A notice above the rows: its symbol, then the wrapping text.
    private func banner(_ text: String, symbolName: String, identifier: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = SettingsLayout.statusLabel()
        label.stringValue = text
        label.preferredMaxLayoutWidth = SettingsLayout.contentWidth - SettingsLayout.controlSpacing - icon.intrinsicContentSize.width
        let row = NSStackView()
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.orientation = .horizontal
        row.spacing = SettingsLayout.controlSpacing
        row.alignment = .top
        Self.markContainer(row, identifier: identifier)
        return row
    }

    private func errorLabel(_ text: String) -> NSTextField {
        let label = SettingsLayout.statusLabel()
        label.stringValue = text
        label.textColor = .systemRed
        return label
    }

    // MARK: - Controls

    private func button(_ title: String, identifier: String, perform: @escaping @MainActor () -> Void) -> NSButton {
        let button = SettingsLayout.button(title, target: nil, action: nil)
        button.setAccessibilityIdentifier(identifier)
        bind(button) { _ in perform() }
        return button
    }

    private func bind(_ control: NSControl, perform: @escaping @MainActor (NSControl) -> Void) {
        let target = MCPServersSettingsAction(perform: perform)
        control.target = target
        control.action = #selector(MCPServersSettingsAction.invoke(_:))
        actionTargets.append(target)
    }

    /// A stack view is not an accessibility element by default, so a
    /// container carrying an identifier is made a group.
    private static func markContainer(_ view: NSView, identifier: String) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityIdentifier(identifier)
    }

    // MARK: - Sheets

    /// Loads the stored secret values before the edit sheet opens.
    private func beginEditing(_ config: MCPServerConfig) {
        editLoadError = nil
        rebuildForLocalChange()
        Task { [weak self] in
            guard let self else { return }
            do {
                let draft = try await self.model.makeEditDraft(for: config)
                self.presentEditor(.edit(config, draft))
            } catch {
                self.editLoadError = "Could not open \(config.displayName) for editing: \(MCPServerSettingsModel.describe(error))"
                self.rebuildForLocalChange()
            }
        }
    }

    private func presentEditor(_ mode: MCPServerEditorSheet.Mode) {
        let model = model
        let existingAliases = registeredAliases()
        presentSheet { close in
            MCPServerEditorSheet(model: model, mode: mode, existingAliases: existingAliases, close: close)
        }
    }

    private func presentImport() {
        let model = model
        let existingAliases = registeredAliases()
        presentSheet { close in
            MCPServerImportSheet(model: model, existingAliases: existingAliases, close: close)
        }
    }

    private func registeredAliases() -> Set<String> {
        Set((model.registry?.servers ?? []).map(\.alias.rawValue))
    }

    /// Presents the sheet `makeSheet` builds as a sheet of the Settings
    /// window, giving it the action that ends the presentation. SwiftUI's
    /// `dismiss` action does not end an AppKit sheet presentation of a
    /// hosting controller, so the sheets close through this action
    /// instead. The edit sheet opens after its secrets load, so the view
    /// may have left the window by then; there is then nothing to present
    /// on.
    private func presentSheet<Sheet: View>(_ makeSheet: (_ close: @escaping @MainActor () -> Void) -> Sheet) {
        guard let presenter = window?.contentViewController else { return }
        let closer = MCPServersSettingsSheetCloser()
        let hostingController = NSHostingController(rootView: makeSheet { closer.close() })
        hostingController.sizingOptions = [.preferredContentSize]
        closer.presented = hostingController
        presenter.presentAsSheet(hostingController)
    }

    private static func transportSummary(_ transport: MCPServerTransportConfig) -> String {
        switch transport {
        case .stdio(let command, _, _, _):
            return "stdio · \(command)"
        case .http(let url, _, let hint):
            return hint == .legacySSE ? "HTTP+SSE · \(url)" : "HTTP · \(url)"
        }
    }
}

/// Ends the sheet presentation of `presented`. Holds it weakly: the
/// presented controller owns the sheet, which owns this object.
@MainActor
private final class MCPServersSettingsSheetCloser {
    weak var presented: NSViewController?

    func close() {
        guard let presented else { return }
        presented.presentingViewController?.dismiss(presented)
    }
}

/// Target of one control of `MCPServersSettingsView`.
@MainActor
private final class MCPServersSettingsAction: NSObject {
    private let perform: @MainActor (NSControl) -> Void

    init(perform: @escaping @MainActor (NSControl) -> Void) {
        self.perform = perform
    }

    @objc func invoke(_ sender: NSControl) {
        perform(sender)
    }
}
