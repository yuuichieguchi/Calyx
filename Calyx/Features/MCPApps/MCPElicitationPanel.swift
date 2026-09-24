//
//  MCPElicitationPanel.swift
//  Calyx
//
//  Shows an upstream MCP server's elicitation in an `MCPPromptPanelWindow`
//  titled with the server's name.
//
//  Form mode turns each property of `requestedSchema` (string, number,
//  integer, boolean, and a string `enum` or `oneOf` of `const` values)
//  into a field, in property-name order, and answers Accept with the
//  entered values, Decline, or Cancel. A property of any other type is
//  listed as unsupported; when it is required, Accept stays disabled.
//
//  URL mode shows the URL. Open opens it in the browser and answers
//  Accept; the panel then stays up with Done until the user closes it or
//  the client calls `dismiss(_:)` on `notifications/elicitation/complete`.
//  Decline and Cancel answer before anything is opened. A URL that does
//  not parse, or whose scheme `MCPAppOpenLinkPolicy` does not allow, is
//  shown with only Decline and Cancel.
//
//  Cancelling the task awaiting `present(_:)` answers Cancel and closes
//  the panel.
//

import AppKit
import Observation
import SwiftUI

@MainActor
final class MCPElicitationPanel: MCPElicitationPresenting {

    private struct Presentation {
        let panel: MCPPromptPanelWindow
        /// Nil once answered (URL mode stays up after Open).
        var continuation: CheckedContinuation<MCPElicitationResponse, Never>?
    }

    private let windowForSurface: @MainActor (UUID) -> NSWindow?
    private var presentations: [MCPElicitationID: Presentation] = [:]

    /// `windowForSurface` is the window that shows the pane, when known.
    init(windowForSurface: @escaping @MainActor (UUID) -> NSWindow?) {
        self.windowForSurface = windowForSurface
    }

    func present(_ request: MCPElicitationRequest) async -> MCPElicitationResponse {
        let id = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                show(request, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.answer(id, .cancel, close: true)
            }
        }
    }

    func dismiss(_ id: MCPElicitationID) {
        answer(id, .cancel, close: true)
    }

    private func show(_ request: MCPElicitationRequest, continuation: CheckedContinuation<MCPElicitationResponse, Never>) {
        let id = request.id
        let content: MCPElicitationContent
        switch request.mode {
        case .form(let message, let schema):
            let form = MCPElicitationForm(schema: schema)
            content = MCPElicitationContent(
                serverName: request.serverContext.displayName,
                message: message,
                body: .form(form),
                onAccept: { [weak self] in self?.answer(id, .accept(content: form.content()), close: true) },
                onDecline: { [weak self] in self?.answer(id, .decline, close: true) },
                onCancel: { [weak self] in self?.answer(id, .cancel, close: true) },
                onOpenURL: nil,
                onDone: nil
            )
        case .url(let message, let text):
            let state = MCPElicitationURLState(text: text)
            var onOpenURL: (@MainActor () -> Void)?
            if let url = state.url {
                onOpenURL = { [weak self] in self?.openURL(url, id: id) }
            }
            content = MCPElicitationContent(
                serverName: request.serverContext.displayName,
                message: message,
                body: .url(state),
                onAccept: nil,
                onDecline: { [weak self] in self?.answer(id, .decline, close: true) },
                onCancel: { [weak self] in self?.answer(id, .cancel, close: true) },
                onOpenURL: onOpenURL,
                onDone: { [weak self] in self?.close(id) }
            )
        }
        let panel = MCPPromptPanelWindow(rootView: MCPElicitationView(content: content))
        panel.title = "\(request.serverContext.displayName) request"
        presentations[id] = Presentation(panel: panel, continuation: continuation)
        panel.show(over: request.surfaceID.flatMap(windowForSurface))
    }

    /// Opens the URL and answers Accept; the panel stays up with Done.
    private func openURL(_ url: URL, id: MCPElicitationID) {
        NSWorkspace.shared.open(url)
        answer(id, .accept(content: [:]), close: false)
    }

    /// Resumes the pending answer, if still pending, and closes the panel
    /// when `close`.
    private func answer(_ id: MCPElicitationID, _ response: MCPElicitationResponse, close: Bool) {
        guard var presentation = presentations[id] else { return }
        presentation.continuation?.resume(returning: response)
        presentation.continuation = nil
        presentations[id] = presentation
        if close {
            self.close(id)
        }
    }

    private func close(_ id: MCPElicitationID) {
        guard let presentation = presentations.removeValue(forKey: id) else { return }
        presentation.continuation?.resume(returning: .cancel)
        presentation.panel.dismiss()
    }
}

// MARK: - Form

/// One property of `requestedSchema` as a field.
@MainActor @Observable
final class MCPElicitationField: Identifiable {
    enum Kind: Equatable {
        case text
        case number(integer: Bool)
        case boolean
        /// `(value, title)` pairs.
        case choice([MCPElicitationChoice])
        case unsupported(type: String)
    }

    let name: String
    let title: String
    let detail: String?
    let isRequired: Bool
    let kind: Kind
    var text: String
    var isOn: Bool
    var choice: String?

    nonisolated let id: String

    init(name: String, schema: [String: AnyCodable], isRequired: Bool) {
        self.id = name
        self.name = name
        self.title = schema["title"]?.stringValue ?? name
        self.detail = schema["description"]?.stringValue
        self.isRequired = isRequired
        let defaultValue = schema["default"]
        let type = schema["type"]?.stringValue
        let choices = Self.choices(in: schema)
        switch type {
        case "string" where !choices.isEmpty:
            kind = .choice(choices)
        case "string":
            kind = .text
        case "number":
            kind = .number(integer: false)
        case "integer":
            kind = .number(integer: true)
        case "boolean":
            kind = .boolean
        default:
            kind = .unsupported(type: type ?? "untyped")
        }
        // The schema's `default`, when it has one, prefills the field.
        text = defaultValue?.stringValue
            ?? defaultValue?.intValue.map { String($0) }
            ?? defaultValue?.doubleValue.map { String($0) }
            ?? ""
        isOn = defaultValue?.boolValue == true
        choice = defaultValue?.stringValue
    }

    /// The field's JSON value; nil when empty or not parseable.
    var value: AnyCodable? {
        switch kind {
        case .text:
            return text.isEmpty ? nil : AnyCodable(text)
        case .number(let integer):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if integer {
                return Int(trimmed).map { AnyCodable($0) }
            }
            return Double(trimmed).map { AnyCodable($0) }
        case .boolean:
            return AnyCodable(isOn)
        case .choice:
            return choice.map { AnyCodable($0) }
        case .unsupported:
            return nil
        }
    }

    /// A required field needs a value; an optional number field that has
    /// text must parse.
    var isValid: Bool {
        if case .number = kind, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            return value != nil
        }
        return !isRequired || value != nil
    }

    private static func choices(in schema: [String: AnyCodable]) -> [MCPElicitationChoice] {
        if let values = schema["enum"]?.arrayValue {
            let titles = schema["enumNames"]?.arrayValue
            return values.enumerated().compactMap { index, value in
                guard let text = value.stringValue else { return nil }
                let title = titles.flatMap { index < $0.count ? $0[index].stringValue : nil }
                return MCPElicitationChoice(value: text, title: title ?? text)
            }
        }
        if let options = schema["oneOf"]?.arrayValue {
            return options.compactMap { option in
                guard let value = option["const"]?.stringValue else { return nil }
                return MCPElicitationChoice(value: value, title: option["title"]?.stringValue ?? value)
            }
        }
        return []
    }
}

struct MCPElicitationChoice: Equatable, Hashable {
    let value: String
    let title: String
}

/// The fields of a form-mode elicitation.
@MainActor @Observable
final class MCPElicitationForm {
    let fields: [MCPElicitationField]

    init(schema: MCPElicitRequestedSchema?) {
        let required = Set(schema?.required ?? [])
        let properties = schema?.properties ?? [:]
        fields = properties.keys.sorted().compactMap { name in
            guard let property = properties[name]?.objectValue else { return nil }
            return MCPElicitationField(name: name, schema: property, isRequired: required.contains(name))
        }
    }

    var canAccept: Bool { fields.allSatisfy(\.isValid) }

    /// The accepted content: every field that has a value.
    func content() -> [String: AnyCodable] {
        var content: [String: AnyCodable] = [:]
        for field in fields {
            if let value = field.value {
                content[field.name] = value
            }
        }
        return content
    }
}

/// The URL of a URL-mode elicitation and whether it has been opened.
@MainActor @Observable
final class MCPElicitationURLState {
    let text: String
    /// Nil when `text` is not a URL or its scheme is one
    /// `MCPAppOpenLinkPolicy` does not open.
    let url: URL?
    var isOpened = false

    init(text: String) {
        self.text = text
        self.url = URL(string: text).flatMap { MCPAppOpenLinkPolicy.isAllowedScheme($0) ? $0 : nil }
    }
}

// MARK: - View

struct MCPElicitationContent {
    enum Body {
        case form(MCPElicitationForm)
        case url(MCPElicitationURLState)
    }

    let serverName: String
    let message: String
    let body: Body
    let onAccept: (@MainActor () -> Void)?
    let onDecline: @MainActor () -> Void
    let onCancel: @MainActor () -> Void
    let onOpenURL: (@MainActor () -> Void)?
    let onDone: (@MainActor () -> Void)?
}

struct MCPElicitationView: View {
    let content: MCPElicitationContent

    var body: some View {
        MCPPromptCard {
            Text("\(content.serverName) asks")
                .font(.system(size: 13, weight: .semibold))
            Text(content.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            switch content.body {
            case .form(let form):
                MCPElicitationFormFields(form: form)
                buttons(acceptEnabled: form.canAccept)
            case .url(let state):
                MCPElicitationURLBody(state: state, content: content)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.MCPApps.elicitationContainer)
    }

    private func buttons(acceptEnabled: Bool) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { content.onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Decline") { content.onDecline() }
                .accessibilityIdentifier(AccessibilityID.MCPApps.elicitationDeclineButton)
            if let onAccept = content.onAccept {
                Button("Accept") { onAccept() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!acceptEnabled)
                    .accessibilityIdentifier(AccessibilityID.MCPApps.elicitationAcceptButton)
            }
        }
    }
}

private struct MCPElicitationFormFields: View {
    let form: MCPElicitationForm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(form.fields) { field in
                MCPElicitationFieldRow(field: field)
            }
        }
    }
}

private struct MCPElicitationFieldRow: View {
    @Bindable var field: MCPElicitationField

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch field.kind {
            case .text:
                TextField(label, text: $field.text)
                    .textFieldStyle(.roundedBorder)
            case .number(let integer):
                TextField(label, text: $field.text, prompt: Text(integer ? "Whole number" : "Number"))
                    .textFieldStyle(.roundedBorder)
            case .boolean:
                Toggle(label, isOn: $field.isOn)
            case .choice(let choices):
                Picker(label, selection: $field.choice) {
                    Text("Choose").tag(String?.none)
                    ForEach(choices, id: \.self) { choice in
                        Text(choice.title).tag(Optional(choice.value))
                    }
                }
            case .unsupported(let type):
                Text("\(label): fields of type \(type) are not supported")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let detail = field.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var label: String {
        field.isRequired ? "\(field.title) (required)" : field.title
    }
}

private struct MCPElicitationURLBody: View {
    let state: MCPElicitationURLState
    let content: MCPElicitationContent

    var body: some View {
        Text(state.text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        if state.url == nil {
            Text("This is not a valid URL, so Calyx cannot open it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        HStack {
            Spacer()
            if state.isOpened {
                Button("Done") { content.onDone?() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { content.onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Decline") { content.onDecline() }
                    .accessibilityIdentifier(AccessibilityID.MCPApps.elicitationDeclineButton)
                if let onOpenURL = content.onOpenURL {
                    Button("Open") {
                        state.isOpened = true
                        onOpenURL()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AccessibilityID.MCPApps.elicitationAcceptButton)
                }
            }
        }
    }
}
