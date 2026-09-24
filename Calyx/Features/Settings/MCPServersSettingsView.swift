//
//  MCPServersSettingsView.swift
//  Calyx
//
//  SwiftUI content of Settings > MCP Servers, hosted in the pane's
//  NSStackView by `SettingsWindowController`. Banners for AI Agent IPC
//  being off and for an unreadable config file, then either the empty
//  state or one row per configured server.
//

import SwiftUI

struct MCPServersSettingsView: View {
    @Bindable var model: MCPServerSettingsModel

    @State private var editor: MCPServerEditorSheet.Mode?
    @State private var isImportPresented = false
    @State private var editLoadError: String?

    var body: some View {
        if let registry = model.registry {
            content(registry: registry)
                .sheet(item: $editor) { mode in
                    MCPServerEditorSheet(model: model, mode: mode, existingAliases: Set(registry.servers.map(\.alias.rawValue)))
                }
                .sheet(isPresented: $isImportPresented) {
                    MCPServerImportSheet(model: model, existingAliases: Set(registry.servers.map(\.alias.rawValue)))
                }
        }
    }

    private func content(registry: MCPServerRegistry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if MCPServerRowStatusResolver.ipcOffBannerVisible(ipcEnabled: model.ipcEnabled) {
                banner(
                    "AI Agent IPC is off. Agents cannot reach these servers until it is turned on in the Agents pane.",
                    systemImage: "info.circle",
                    identifier: AccessibilityID.MCPServersSettings.ipcDisabledBanner
                )
            }
            if let loadError = registry.loadError {
                banner(
                    MCPServerSettingsModel.configErrorText(loadError),
                    systemImage: "exclamationmark.triangle",
                    identifier: AccessibilityID.MCPServersSettings.configErrorBanner
                )
            }
            if let editLoadError {
                Text(editLoadError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if registry.servers.isEmpty {
                emptyState
            } else {
                actionButtons
                serverList(registry.servers)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No MCP Servers")
                .font(.system(size: 13, weight: .semibold))
            Text("Add a server, or import the JSON an agent CLI uses for its own MCP servers.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actionButtons
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MCPServersSettings.emptyState)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button("Add Server") { editor = .create }
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.addButton)
            Button("Import JSON") { isImportPresented = true }
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.importButton)
        }
    }

    private func serverList(_ servers: [MCPServerConfig]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(servers.enumerated()), id: \.element.id) { index, config in
                if index > 0 {
                    Divider()
                }
                MCPServerRowView(model: model, config: config) {
                    beginEditing(config)
                }
                .padding(.vertical, 10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MCPServersSettings.list)
    }

    private func banner(_ text: String, systemImage: String, identifier: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// Loads the stored secret values before the edit sheet opens.
    private func beginEditing(_ config: MCPServerConfig) {
        editLoadError = nil
        Task {
            do {
                let draft = try await model.makeEditDraft(for: config)
                editor = .edit(config, draft)
            } catch {
                editLoadError = "Could not open \(config.displayName) for editing: \(MCPServerSettingsModel.describe(error))"
            }
        }
    }
}

/// One configured server: name, alias and transport, the enable switch,
/// the resolver's status and buttons, and the details.
private struct MCPServerRowView: View {
    let model: MCPServerSettingsModel
    let config: MCPServerConfig
    let onEdit: () -> Void

    private var serverID: UUID { config.id.rawValue }

    var body: some View {
        let rowState = model.rowState(for: config)
        let live = model.liveStatus[config.id]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(config.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(config.alias.rawValue) · \(Self.transportSummary(config.transport))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { config.isEnabled },
                    set: { model.setEnabled($0, for: config) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowEnabledSwitch(serverID))
            }
            Text(rowState.statusText)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowStatus(serverID))
            if let live, let signInText = MCPServerRowStatusResolver.signInText(authState: live.authState) {
                Text(signInText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let stderrTail = rowState.stderrTail, !stderrTail.isEmpty {
                Text(stderrTail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rowError = model.rowErrors[config.id] {
                Text(rowError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons(rowState: rowState, connectionState: live?.connectionState)
            if let live, !live.exclusions.isEmpty || live.instructions != nil {
                details(live)
            }
        }
    }

    private func buttons(rowState: MCPServerRowStatusResolver.RowState, connectionState: MCPConnectionState?) -> some View {
        HStack(spacing: 8) {
            if rowState.showRetry {
                Button("Retry") { model.retry(config.id) }
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowRetryButton(serverID))
            }
            if rowState.showSignIn {
                Button("Sign In") { model.signIn(config.id) }
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowSignInButton(serverID))
            }
            if connectionState == .authorizing, model.isSigningIn(config.id) {
                Button("Cancel Sign-In") { model.cancelSignIn(config.id) }
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowCancelSignInButton(serverID))
            }
            if rowState.showSignOut {
                Button("Sign Out") { model.signOut(config.id) }
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowSignOutButton(serverID))
            }
            Spacer()
            Button("Edit", action: onEdit)
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowEditButton(serverID))
            Button("Remove") { model.remove(config.id) }
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.rowRemoveButton(serverID))
        }
    }

    private func details(_ live: MCPServerSettingsModel.LiveStatus) -> some View {
        DisclosureGroup("Details") {
            VStack(alignment: .leading, spacing: 6) {
                if !live.exclusions.isEmpty {
                    Text("Excluded tools")
                        .font(.system(size: 11, weight: .semibold))
                    ForEach(Array(live.exclusions.enumerated()), id: \.offset) { _, exclusion in
                        Text("\(exclusion.upstreamToolName): \(exclusion.reason)")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let instructions = live.instructions {
                    Text("Server instructions")
                        .font(.system(size: 11, weight: .semibold))
                    Text(instructions)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .font(.system(size: 11))
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
