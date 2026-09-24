//
//  MCPServerEditorSheet.swift
//  Calyx
//
//  Add and edit sheet of Settings > MCP Servers. stdio: command, arguments
//  (one per line), env vars with masked values, working directory. HTTP:
//  URL, headers with masked values, the legacy HTTP+SSE hint, the fixed
//  OAuth redirect port, and an optional pre-registered OAuth client. The
//  alias is entered only when adding.
//

import SwiftUI

struct MCPServerEditorSheet: View {

    enum Mode: Identifiable {
        case create
        case edit(MCPServerConfig, MCPServerEditDraft)

        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let config, _): return config.id.rawValue.uuidString
            }
        }
    }

    enum TransportKind: Hashable {
        case stdio
        case http
    }

    enum ClientAuthenticationKind: Hashable {
        case none
        case clientSecretPost
        case clientSecretBasic
    }

    /// One env var or header. Values are shown masked.
    struct NamedValue: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var value: String
    }

    let model: MCPServerSettingsModel
    let mode: Mode
    /// Aliases of the registered servers when the sheet opened.
    let existingAliases: Set<String>

    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var alias = ""
    @State private var transportKind: TransportKind = .stdio
    @State private var command = ""
    @State private var argsText = ""
    @State private var env: [NamedValue] = []
    @State private var cwd = ""
    @State private var url = ""
    @State private var headers: [NamedValue] = []
    @State private var isLegacySSE = false
    @State private var useFixedPort = false
    @State private var clientID = ""
    @State private var clientAuthenticationKind: ClientAuthenticationKind = .none
    @State private var clientSecret = ""
    @State private var saveError: String?
    @State private var isSaving = false

    init(model: MCPServerSettingsModel, mode: Mode, existingAliases: Set<String>) {
        self.model = model
        self.mode = mode
        self.existingAliases = existingAliases
        guard case .edit(_, let draft) = mode else { return }
        _displayName = State(initialValue: draft.displayName)
        switch draft.transport {
        case .stdio(let command, let args, let env, let cwd):
            _transportKind = State(initialValue: .stdio)
            _command = State(initialValue: command)
            _argsText = State(initialValue: args.joined(separator: "\n"))
            _env = State(initialValue: Self.namedValues(env))
            _cwd = State(initialValue: cwd ?? "")
        case .http(let url, let headers, let hint, let useFixedPort):
            _transportKind = State(initialValue: .http)
            _url = State(initialValue: url)
            _headers = State(initialValue: Self.namedValues(headers))
            _isLegacySSE = State(initialValue: hint == .legacySSE)
            _useFixedPort = State(initialValue: useFixedPort)
        }
        _clientID = State(initialValue: draft.authDraft?.preRegisteredClientID ?? "")
        switch draft.authDraft?.clientAuthentication {
        case .clientSecretPost(let secret)?:
            _clientAuthenticationKind = State(initialValue: .clientSecretPost)
            _clientSecret = State(initialValue: secret)
        case .clientSecretBasic(let secret)?:
            _clientAuthenticationKind = State(initialValue: .clientSecretBasic)
            _clientSecret = State(initialValue: secret)
        case .none?, nil:
            break
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                serverSection
                switch transportKind {
                case .stdio:
                    stdioSection
                    namedValuesSection(title: "Environment", addTitle: "Add Variable", values: $env)
                case .http:
                    httpSection
                    namedValuesSection(title: "Headers", addTitle: "Add Header", values: $headers)
                    oauthSection
                }
            }
            .formStyle(.grouped)
            footer
                .padding(16)
        }
        .frame(width: 520, height: 560)
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            TextField("Name", text: $displayName)
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.editorNameField)
            switch mode {
            case .create:
                TextField("Alias", text: $alias, prompt: Text(aliasSuggestion))
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.editorAliasField)
            case .edit(let config, _):
                LabeledContent("Alias", value: config.alias.rawValue)
            }
            Picker("Transport", selection: $transportKind) {
                Text("stdio").tag(TransportKind.stdio)
                Text("HTTP").tag(TransportKind.http)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(AccessibilityID.MCPServersSettings.editorTransportPicker)
        } footer: {
            if case .create = mode {
                Text("The alias prefixes this server's tool names and cannot be changed later: a lowercase letter followed by up to 9 lowercase letters or digits.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stdioSection: some View {
        Section("Command") {
            TextField("Command", text: $command)
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.editorCommandField)
            TextField("Arguments", text: $argsText, prompt: Text("One per line"), axis: .vertical)
                .lineLimit(1...6)
                .accessibilityIdentifier(AccessibilityID.MCPServersSettings.editorArgsField)
            TextField("Working directory", text: $cwd, prompt: Text("Optional"))
        }
    }

    private var httpSection: some View {
        Section("Endpoint") {
            TextField("URL", text: $url)
            Toggle("Legacy HTTP+SSE server", isOn: $isLegacySSE)
        }
    }

    private var oauthSection: some View {
        Section {
            Toggle("Use fixed redirect port \(String(MCPOAuthRedirectConfig.calyxFixedPort))", isOn: $useFixedPort)
            TextField("Client ID", text: $clientID, prompt: Text("Optional, for a pre-registered client"))
            Picker("Client authentication", selection: $clientAuthenticationKind) {
                Text("None").tag(ClientAuthenticationKind.none)
                Text("Client secret (POST)").tag(ClientAuthenticationKind.clientSecretPost)
                Text("Client secret (Basic)").tag(ClientAuthenticationKind.clientSecretBasic)
            }
            if clientAuthenticationKind != .none {
                SecureField("Client secret", text: $clientSecret)
            }
        } header: {
            Text("OAuth")
        } footer: {
            Text("Turn on the fixed port only for an authorization server that requires an exact redirect port.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func namedValuesSection(title: String, addTitle: String, values: Binding<[NamedValue]>) -> some View {
        Section(title) {
            ForEach(values) { $entry in
                HStack {
                    TextField("Name", text: $entry.name)
                        .labelsHidden()
                    SecureField("Value", text: $entry.value)
                        .labelsHidden()
                    Button {
                        values.wrappedValue.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(entry.name)")
                }
            }
            Button(addTitle) {
                values.wrappedValue.append(NamedValue(name: "", value: ""))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = saveError ?? validationMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(saveError == nil ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil || isSaving)
                    .accessibilityIdentifier(AccessibilityID.MCPServersSettings.editorSaveButton)
            }
        }
    }

    // MARK: - Validation and saving

    private var aliasSuggestion: String {
        MCPServerAliasDeriver.derive(fromDisplayName: displayName) ?? "Alias"
    }

    private var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why Save is unavailable, or nil when the fields are complete.
    private var validationMessage: String? {
        if trimmedDisplayName.isEmpty {
            return "Enter a name."
        }
        if case .create = mode {
            guard MCPServerAlias(rawValue: alias) != nil else {
                return "Enter an alias: a lowercase letter followed by up to 9 lowercase letters or digits."
            }
            guard !existingAliases.contains(alias) else {
                return "Another server already uses the alias \"\(alias)\"."
            }
        }
        switch transportKind {
        case .stdio:
            if command.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter a command."
            }
            if let message = Self.namedValuesProblem(env, noun: "environment variable") {
                return message
            }
        case .http:
            guard let parsed = URL(string: url.trimmingCharacters(in: .whitespaces)),
                  let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https", parsed.host != nil else {
                return "Enter an http or https URL."
            }
            if let message = Self.namedValuesProblem(headers, noun: "header") {
                return message
            }
            if clientAuthenticationKind != .none, clientSecret.isEmpty {
                return "Enter the client secret."
            }
        }
        return nil
    }

    private var transportDraft: MCPServerTransportConfigDraft {
        switch transportKind {
        case .stdio:
            let trimmedCwd = cwd.trimmingCharacters(in: .whitespaces)
            return .stdio(
                command: command.trimmingCharacters(in: .whitespaces),
                args: argsText.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
                env: Self.dictionary(env),
                cwd: trimmedCwd.isEmpty ? nil : trimmedCwd
            )
        case .http:
            return .http(
                url: url.trimmingCharacters(in: .whitespaces),
                headers: Self.dictionary(headers),
                hint: isLegacySSE ? .legacySSE : nil,
                useFixedPort: useFixedPort
            )
        }
    }

    private var authDraft: MCPServerAuthConfigDraftValue? {
        guard transportKind == .http else { return nil }
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespaces)
        let clientAuthentication: MCPOAuthClientAuthentication?
        switch clientAuthenticationKind {
        case .none: clientAuthentication = nil
        case .clientSecretPost: clientAuthentication = .clientSecretPost(secret: clientSecret)
        case .clientSecretBasic: clientAuthentication = .clientSecretBasic(secret: clientSecret)
        }
        guard !trimmedClientID.isEmpty || clientAuthentication != nil else { return nil }
        return MCPServerAuthConfigDraftValue(
            preRegisteredClientID: trimmedClientID.isEmpty ? nil : trimmedClientID,
            clientAuthentication: clientAuthentication
        )
    }

    private func save() {
        saveError = nil
        isSaving = true
        let transport = transportDraft
        let auth = authDraft
        let name = trimmedDisplayName
        Task {
            do {
                switch mode {
                case .create:
                    try await model.add(MCPServerCreateDraft(alias: alias, displayName: name, transport: transport, authDraft: auth))
                case .edit(let config, _):
                    try await model.update(config, with: MCPServerEditDraft(displayName: name, transport: transport, authDraft: auth))
                }
                dismiss()
            } catch {
                saveError = MCPServerSettingsModel.describe(error)
                isSaving = false
            }
        }
    }

    private static func namedValues(_ values: [String: String]) -> [NamedValue] {
        values.sorted { $0.key < $1.key }.map { NamedValue(name: $0.key, value: $0.value) }
    }

    private static func dictionary(_ values: [NamedValue]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { ($0.name.trimmingCharacters(in: .whitespaces), $0.value) })
    }

    /// An empty or repeated name.
    private static func namedValuesProblem(_ values: [NamedValue], noun: String) -> String? {
        let names = values.map { $0.name.trimmingCharacters(in: .whitespaces) }
        if names.contains(where: \.isEmpty) {
            return "Enter a name for every \(noun)."
        }
        if Set(names).count != names.count {
            return "Each \(noun) name must be unique."
        }
        return nil
    }
}
