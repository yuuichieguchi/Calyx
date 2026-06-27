//
//  CodeAction.swift
//  Calyx
//
//  LSP 3.18 textDocument/codeAction parameter & response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_codeAction
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeAction
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionContext
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionKind
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#codeActionTriggerKind
//

import Foundation

// MARK: - CodeActionTriggerKind

/// The reason why code actions were requested. Spec values: 1 = Invoked,
/// 2 = Automatic. Decoding rejects unknown raw values rather than silently
/// degrading.
enum CodeActionTriggerKind: Int, Sendable, Codable, Equatable, Hashable {
    case invoked = 1
    case automatic = 2

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        guard let value = CodeActionTriggerKind(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown CodeActionTriggerKind raw value: \(raw)"
            ))
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}

// MARK: - CodeActionKind

/// The kind of a code action. Per spec this is an OPEN string enum: servers
/// may ship custom kinds (e.g. `"rust.expandMacro"`), so we model it as a
/// `RawRepresentable` wrapper around `String` rather than a closed `enum`.
///
/// Encoded form: a bare JSON string equal to `rawValue`.
struct CodeActionKind: RawRepresentable, Sendable, Codable, Equatable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Codable: encode/decode as a bare JSON string. RawRepresentable would
    // synthesise this, but we spell it out so the contract is explicit.
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // Spec-defined well-known kinds.
    static let empty = CodeActionKind(rawValue: "")
    static let quickFix = CodeActionKind(rawValue: "quickfix")
    static let refactor = CodeActionKind(rawValue: "refactor")
    static let refactorExtract = CodeActionKind(rawValue: "refactor.extract")
    static let refactorInline = CodeActionKind(rawValue: "refactor.inline")
    static let refactorRewrite = CodeActionKind(rawValue: "refactor.rewrite")
    static let source = CodeActionKind(rawValue: "source")
    static let sourceOrganizeImports = CodeActionKind(rawValue: "source.organizeImports")
    static let sourceFixAll = CodeActionKind(rawValue: "source.fixAll")
}

// MARK: - CodeActionContext

/// Contains additional diagnostic information about the context in which a
/// code action is run.
struct CodeActionContext: Sendable, Codable, Equatable {
    /// An array of diagnostics known on the client side overlapping the range
    /// provided to the `textDocument/codeAction` request.
    let diagnostics: [Diagnostic]
    /// Requested kind of actions to return. Actions of these kinds are filtered
    /// by the server.
    let only: [CodeActionKind]?
    /// The reason why code actions were requested.
    let triggerKind: CodeActionTriggerKind?

    init(
        diagnostics: [Diagnostic],
        only: [CodeActionKind]? = nil,
        triggerKind: CodeActionTriggerKind? = nil
    ) {
        self.diagnostics = diagnostics
        self.only = only
        self.triggerKind = triggerKind
    }
}

// MARK: - CodeActionParams

/// Parameters for the `textDocument/codeAction` request.
struct CodeActionParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let range: LSPRange
    let context: CodeActionContext
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        range: LSPRange,
        context: CodeActionContext,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.range = range
        self.context = context
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - CodeActionDisabled

/// Marker indicating that the action is shown but cannot be applied right
/// now. The `reason` is surfaced to the user.
struct CodeActionDisabled: Sendable, Codable, Equatable {
    let reason: String

    init(reason: String) {
        self.reason = reason
    }
}

// MARK: - CodeAction

/// A code action represents a change that can be performed in code (e.g. to
/// fix a problem or to refactor code). Only `title` is required.
struct CodeAction: Sendable, Codable, Equatable {
    /// A short, human-readable, title for this code action.
    let title: String
    /// The kind of the code action. Used to filter code actions.
    let kind: CodeActionKind?
    /// The diagnostics that this code action resolves.
    let diagnostics: [Diagnostic]?
    /// Marks this as a preferred action; clients pick it for "auto-fix" UI.
    let isPreferred: Bool?
    /// Marks that the code action cannot currently be applied.
    let disabled: CodeActionDisabled?
    /// The workspace edit this code action performs.
    let edit: WorkspaceEdit?
    /// A command this code action executes. If a code action provides an
    /// edit and a command, the edit is applied first, then the command.
    let command: Command?
    /// A data entry field that is preserved on a code action between
    /// `textDocument/codeAction` and `codeAction/resolve`.
    let data: AnyCodable?

    init(
        title: String,
        kind: CodeActionKind? = nil,
        diagnostics: [Diagnostic]? = nil,
        isPreferred: Bool? = nil,
        disabled: CodeActionDisabled? = nil,
        edit: WorkspaceEdit? = nil,
        command: Command? = nil,
        data: AnyCodable? = nil
    ) {
        self.title = title
        self.kind = kind
        self.diagnostics = diagnostics
        self.isPreferred = isPreferred
        self.disabled = disabled
        self.edit = edit
        self.command = command
        self.data = data
    }
}

// MARK: - CodeActionItem (union: Command | CodeAction)
//
// The result of `textDocument/codeAction` is `(Command | CodeAction)[] | null`.
// The two variants share the `command` key but use it with different types:
//   - `Command.command`     is a STRING (required).
//   - `CodeAction.command`  is a `Command` OBJECT (optional).
// A purely key-based discriminator misclassifies a `CodeAction` that has only
// `{ title, command: { ... } }` as a bare `Command`, then fails the inner
// decode because the value at `command` is an object, not a string.
//
// We resolve this by trying `Command` first: its required `command: String`
// makes the object form fail fast. On any `DecodingError`, we fall through to
// `CodeAction`. This ordering is safe because every valid `Command` payload
// is INVALID as a `CodeAction` only when… actually it isn't — `CodeAction`
// also accepts `command` as an optional `Command` object. To avoid wrongly
// preferring `.command` when both decode, we also short-circuit to
// `CodeAction` when CodeAction-only keys are present (cheap structural cue).

enum CodeActionItem: Sendable, Codable, Equatable {
    case command(Command)
    case action(CodeAction)

    private enum DiscriminatorKey: String, CodingKey {
        case edit
        case kind
        case diagnostics
        case disabled
        case isPreferred
        case data
    }

    init(from decoder: any Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKey.self)
        let hasActionOnlyKey =
            probe.contains(.edit) ||
            probe.contains(.kind) ||
            probe.contains(.diagnostics) ||
            probe.contains(.disabled) ||
            probe.contains(.isPreferred) ||
            probe.contains(.data)
        if hasActionOnlyKey {
            // Unambiguously a CodeAction.
            self = .action(try CodeAction(from: decoder))
            return
        }
        // No CodeAction-only key. Try `Command` first: its required
        // `command: String` forces a fast failure when `command` is an
        // object (the CodeAction-with-only-title-and-command shape).
        do {
            let c = try Command(from: decoder)
            self = .command(c)
        } catch is DecodingError {
            self = .action(try CodeAction(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .command(let c):
            try c.encode(to: encoder)
        case .action(let a):
            try a.encode(to: encoder)
        }
    }
}

// MARK: - CodeActionItemList (filters nulls in streaming partial results)
//
// `textDocument/codeAction` is `(Command | CodeAction)[] | null`, but servers
// implementing `partialResultToken` may also emit individual `null` elements
// inside the array as they stream partial chunks. A naive `[CodeActionItem]`
// decode crashes on those nulls because `CodeActionItem` is not optional.
//
// `CodeActionItemList` wraps the array and filters `null` entries during
// enumeration, returning only the well-formed items. Encoding emits the
// inner items as a plain JSON array.

struct CodeActionItemList: Sendable, Codable, Equatable {
    let items: [CodeActionItem]

    init(items: [CodeActionItem]) {
        self.items = items
    }

    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var collected: [CodeActionItem] = []
        if let count = container.count {
            collected.reserveCapacity(count)
        }
        while !container.isAtEnd {
            if try container.decodeNil() {
                // Skip null entries (streaming partial-result chunks).
                continue
            }
            let item = try container.decode(CodeActionItem.self)
            collected.append(item)
        }
        self.items = collected
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        for item in items {
            try container.encode(item)
        }
    }
}
