//
//  MCPServerImportSheet.swift
//  Calyx
//
//  JSON import sheet of Settings > MCP Servers. The pasted text is parsed
//  by `MCPServersJSONImporter` on every change; the preview lists each
//  server with the alias it would get, and a server whose alias is
//  already taken is replaced, renamed or skipped as chosen.
//

import SwiftUI

/// One row of the import preview.
struct MCPServerImportPreviewItem: Equatable {
    let name: String?
    /// nil when the server has no name to derive one from; the registry
    /// assigns an id-based alias on import.
    let candidateAlias: String?
    let transport: MCPServerTransportConfig
    /// The alias is taken by a registered server or an earlier server of
    /// the same import.
    let conflicts: Bool
    let unresolvedVariables: [String]
    let ignoredKeys: [String]

    /// Candidate aliases follow `MCPServerRegistry.importServers(_:conflictPolicy:)`.
    static func items(for imported: [MCPImportedServer], existingAliases: Set<String>) -> [MCPServerImportPreviewItem] {
        var taken = existingAliases
        return imported.map { server in
            let candidate = server.name.flatMap(MCPServerAliasDeriver.derive(fromDisplayName:))
            let conflicts = candidate.map { taken.contains($0) } ?? false
            if let candidate {
                taken.insert(candidate)
            }
            return MCPServerImportPreviewItem(
                name: server.name,
                candidateAlias: candidate,
                transport: server.transport,
                conflicts: conflicts,
                unresolvedVariables: server.unresolvedVariables,
                ignoredKeys: server.ignoredKeys
            )
        }
    }
}

struct MCPServerImportSheet: View {
    let model: MCPServerSettingsModel
    let existingAliases: Set<String>
    /// Ends the sheet's presentation; the presenter supplies it.
    let close: @MainActor () -> Void

    @State private var text = ""
    @State private var imported: [MCPImportedServer] = []
    @State private var parseError: String?
    @State private var conflictPolicy: MCPImportConflictPolicy = .rename
    @State private var importError: String?
    @State private var isImporting = false

    private var previewItems: [MCPServerImportPreviewItem] {
        MCPServerImportPreviewItem.items(for: imported, existingAliases: existingAliases)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import MCP Servers")
                .font(.system(size: 15, weight: .semibold))
            Text("Paste an agent CLI's MCP server JSON: {\"mcpServers\": {...}}, a map of servers, or one server. ${VAR} references are filled in from Calyx's environment.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MCPServerImportTextView(text: $text)
                .frame(minHeight: 140)
                .border(Color.secondary.opacity(0.4))
                .onChange(of: text) { _, newText in
                    parse(newText)
                }
            if let parseError {
                Text(parseError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.importParseError)
            }
            if !imported.isEmpty {
                preview
            }
            if let importError {
                Text(importError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Import", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(imported.isEmpty || isImporting)
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.importConfirmButton)
            }
        }
        .padding(16)
        .frame(width: 520)
        .frame(minHeight: 420)
    }

    private var preview: some View {
        let items = previewItems
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        previewRow(item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            if items.contains(where: \.conflicts) {
                Picker("When an alias is taken", selection: $conflictPolicy) {
                    Text("Replace").tag(MCPImportConflictPolicy.replace)
                    Text("Rename").tag(MCPImportConflictPolicy.rename)
                    Text("Skip").tag(MCPImportConflictPolicy.skip)
                }
                .pickerStyle(.segmented)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MCPServersSettings.importPreview)
    }

    private func previewRow(_ item: MCPServerImportPreviewItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.name ?? "Unnamed server")
                    .font(.system(size: 12, weight: .semibold))
                Text(item.candidateAlias.map { "alias \($0)" } ?? "alias assigned on import")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if item.conflicts {
                    Text("alias taken")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Text(Self.transportSummary(item.transport))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !item.unresolvedVariables.isEmpty {
                Text("Not in the environment, kept as written: \(item.unresolvedVariables.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.ignoredKeys.isEmpty {
                Text("Ignored keys: \(item.ignoredKeys.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func parse(_ newText: String) {
        importError = nil
        guard !newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            imported = []
            parseError = nil
            return
        }
        do {
            imported = try MCPServersJSONImporter.parse(newText, environment: ProcessInfo.processInfo.environment)
            parseError = nil
        } catch {
            imported = []
            parseError = MCPServerSettingsModel.describe(error)
        }
    }

    private func confirm() {
        importError = nil
        isImporting = true
        let servers = imported
        let policy = conflictPolicy
        Task {
            do {
                _ = try await model.importServers(servers, conflictPolicy: policy)
                close()
            } catch {
                importError = MCPServerSettingsModel.describe(error)
                isImporting = false
            }
        }
    }

    private static func transportSummary(_ transport: MCPServerTransportConfig) -> String {
        switch transport {
        case .stdio(let command, let args, let envNames, _):
            let commandLine = ([command] + args).joined(separator: " ")
            return envNames.isEmpty ? commandLine : "\(commandLine)  env: \(envNames.joined(separator: ", "))"
        case .http(let url, let headerNames, let hint):
            let kind = hint == .legacySSE ? "HTTP+SSE" : "HTTP"
            return headerNames.isEmpty ? "\(kind) \(url)" : "\(kind) \(url)  headers: \(headerNames.joined(separator: ", "))"
        }
    }
}
