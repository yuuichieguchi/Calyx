//
//  Completion.swift
//  Calyx
//
//  LSP 3.18 `textDocument/completion` request and response types. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_completion
//
//  Twelve related types live here because they form a single closed family
//  and are only ever used together:
//    - CompletionParams
//    - CompletionContext / CompletionTriggerKind
//    - CompletionList / CompletionItemDefaults
//    - CompletionItem / CompletionItemLabelDetails
//    - CompletionItemKind / CompletionItemTag
//    - InsertTextFormat / InsertTextMode
//    - CompletionResult (union: CompletionItem[] | CompletionList)
//

import Foundation

// MARK: - CompletionTriggerKind

/// How a completion was triggered.
enum CompletionTriggerKind: Int, Sendable, Codable, Equatable, Hashable {
    /// Completion was triggered by typing an identifier (24x7 code complete),
    /// manual invocation (e.g. Ctrl+Space) or via an API.
    case invoked = 1
    /// Completion was triggered by a trigger character specified by the
    /// `triggerCharacters` server capability.
    case triggerCharacter = 2
    /// Completion was re-triggered because the current completion list is
    /// incomplete.
    case triggerForIncompleteCompletions = 3
}

// MARK: - CompletionItemKind

/// The kind of a completion entry.
enum CompletionItemKind: Int, Sendable, Codable, Equatable, Hashable {
    case text = 1
    case method = 2
    case function = 3
    case constructor = 4
    case field = 5
    case variable = 6
    case `class` = 7
    case interface = 8
    case module = 9
    case property = 10
    case unit = 11
    case value = 12
    case `enum` = 13
    case keyword = 14
    case snippet = 15
    case color = 16
    case file = 17
    case reference = 18
    case folder = 19
    case enumMember = 20
    case constant = 21
    case `struct` = 22
    case event = 23
    case `operator` = 24
    case typeParameter = 25
}

// MARK: - CompletionItemTag

/// Completion item tags are extra annotations that tweak the rendering of a
/// completion item.
enum CompletionItemTag: Int, Sendable, Codable, Equatable, Hashable {
    /// Render a completion as obsolete, usually using a strike-out style.
    case deprecated = 1
}

// MARK: - InsertTextFormat

/// Defines whether the insert text in a completion item should be interpreted
/// as plain text or a snippet.
enum InsertTextFormat: Int, Sendable, Codable, Equatable, Hashable {
    /// The primary text to be inserted is treated as a plain string.
    case plainText = 1
    /// The primary text to be inserted is treated as a snippet (with `$1`,
    /// `${1:label}`, etc. tab stops, per LSP snippet syntax).
    case snippet = 2
}

// MARK: - InsertTextMode

/// How whitespace and indentation is handled during insertion of a
/// completion item's text.
enum InsertTextMode: Int, Sendable, Codable, Equatable, Hashable {
    /// The insertion or replace strings are taken as-is. If the value is
    /// multi-line the lines below the cursor will be inserted using the
    /// indentation defined in the string value.
    case asIs = 1
    /// The editor adjusts leading whitespace of new lines so that they
    /// match the indentation up to the cursor of the line for which the
    /// item was requested.
    case adjustIndentation = 2
}

// MARK: - CompletionItemLabelDetails

/// Additional details for a completion item label.
struct CompletionItemLabelDetails: Sendable, Codable, Equatable {
    /// An optional string which is rendered less prominently directly after
    /// `CompletionItem.label`, without any spacing.
    let detail: String?
    /// An optional string which is rendered less prominently after
    /// `CompletionItemLabelDetails.detail`, with a small spacing.
    let description: String?

    init(detail: String? = nil, description: String? = nil) {
        self.detail = detail
        self.description = description
    }
}

// MARK: - CompletionItem

/// A single completion suggestion in the response of `textDocument/completion`.
struct CompletionItem: Sendable, Codable, Equatable {
    /// The label of this completion item.
    let label: String
    /// Additional details for the label.
    let labelDetails: CompletionItemLabelDetails?
    /// The kind of this completion item.
    let kind: CompletionItemKind?
    /// Tags for this completion item.
    let tags: [CompletionItemTag]?
    /// A human-readable string with additional information about this item.
    let detail: String?
    /// A human-readable string that represents a doc-comment.
    let documentation: StringOrMarkupContent?
    /// Indicates if this item is deprecated. Use `tags` instead in 3.15+.
    let deprecated: Bool?
    /// Select this item when showing.
    let preselect: Bool?
    /// A string that should be used when comparing this item with other items.
    let sortText: String?
    /// A string that should be used when filtering a set of completion items.
    let filterText: String?
    /// A string that should be inserted into a document when selecting this
    /// completion. If omitted, `label` is used as the insert text.
    let insertText: String?
    /// The format of the insert text.
    let insertTextFormat: InsertTextFormat?
    /// How whitespace and indentation is handled during insertion of the
    /// completion text.
    let insertTextMode: InsertTextMode?
    /// An edit which is applied when selecting this completion.
    let textEdit: TextEdit?
    /// The edit text used if the completion item is part of a CompletionList
    /// and `CompletionList.itemDefaults.editRange` is provided.
    let textEditText: String?
    /// Additional text edits applied along with the main edit.
    let additionalTextEdits: [TextEdit]?
    /// An optional set of characters that when pressed while this completion
    /// is active will accept it first and then type that character.
    let commitCharacters: [String]?
    /// An optional command that is executed after inserting this completion.
    let command: Command?
    /// A data entry field passed through unchanged from the server to the
    /// client and back, useful for `completionItem/resolve`.
    let data: AnyCodable?

    init(
        label: String,
        labelDetails: CompletionItemLabelDetails? = nil,
        kind: CompletionItemKind? = nil,
        tags: [CompletionItemTag]? = nil,
        detail: String? = nil,
        documentation: StringOrMarkupContent? = nil,
        deprecated: Bool? = nil,
        preselect: Bool? = nil,
        sortText: String? = nil,
        filterText: String? = nil,
        insertText: String? = nil,
        insertTextFormat: InsertTextFormat? = nil,
        insertTextMode: InsertTextMode? = nil,
        textEdit: TextEdit? = nil,
        textEditText: String? = nil,
        additionalTextEdits: [TextEdit]? = nil,
        commitCharacters: [String]? = nil,
        command: Command? = nil,
        data: AnyCodable? = nil
    ) {
        self.label = label
        self.labelDetails = labelDetails
        self.kind = kind
        self.tags = tags
        self.detail = detail
        self.documentation = documentation
        self.deprecated = deprecated
        self.preselect = preselect
        self.sortText = sortText
        self.filterText = filterText
        self.insertText = insertText
        self.insertTextFormat = insertTextFormat
        self.insertTextMode = insertTextMode
        self.textEdit = textEdit
        self.textEditText = textEditText
        self.additionalTextEdits = additionalTextEdits
        self.commitCharacters = commitCharacters
        self.command = command
        self.data = data
    }
}

// MARK: - CompletionItemDefaults

/// Defaults applied to each `CompletionItem` in a `CompletionList`, used to
/// avoid repeating shared properties on every item.
struct CompletionItemDefaults: Sendable, Codable, Equatable {
    /// A default commit character set.
    let commitCharacters: [String]?
    /// A default edit range. Either a single `Range` or
    /// `{ insert: Range, replace: Range }`; carried as `AnyCodable` because
    /// the shape varies and we forward it verbatim to clients.
    let editRange: AnyCodable?
    /// A default insert text format.
    let insertTextFormat: InsertTextFormat?
    /// A default insert text mode.
    let insertTextMode: InsertTextMode?
    /// A default data value.
    let data: AnyCodable?

    init(
        commitCharacters: [String]? = nil,
        editRange: AnyCodable? = nil,
        insertTextFormat: InsertTextFormat? = nil,
        insertTextMode: InsertTextMode? = nil,
        data: AnyCodable? = nil
    ) {
        self.commitCharacters = commitCharacters
        self.editRange = editRange
        self.insertTextFormat = insertTextFormat
        self.insertTextMode = insertTextMode
        self.data = data
    }
}

// MARK: - CompletionList

/// Represents a collection of `CompletionItem`s to be presented in the editor.
struct CompletionList: Sendable, Codable, Equatable {
    /// This list is not complete; further typing should result in recomputing.
    let isIncomplete: Bool
    /// Shared defaults for `items`.
    let itemDefaults: CompletionItemDefaults?
    /// The completion items.
    let items: [CompletionItem]

    init(
        isIncomplete: Bool,
        itemDefaults: CompletionItemDefaults? = nil,
        items: [CompletionItem]
    ) {
        self.isIncomplete = isIncomplete
        self.itemDefaults = itemDefaults
        self.items = items
    }
}

// MARK: - CompletionParams

/// Parameters for the `textDocument/completion` request.
struct CompletionParams: Sendable, Codable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    /// Additional information about the context in which a completion was
    /// triggered.
    let context: CompletionContext?
    let workDoneToken: ProgressToken?
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        position: Position,
        context: CompletionContext? = nil,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.position = position
        self.context = context
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - CompletionContext

/// Contains additional information about the context in which a completion
/// request is triggered.
struct CompletionContext: Sendable, Codable, Equatable {
    /// How the completion was triggered.
    let triggerKind: CompletionTriggerKind
    /// The trigger character (a single character) that has trigger code
    /// complete. Is undefined if `triggerKind != .triggerCharacter`.
    let triggerCharacter: String?

    init(triggerKind: CompletionTriggerKind, triggerCharacter: String? = nil) {
        self.triggerKind = triggerKind
        self.triggerCharacter = triggerCharacter
    }
}

// MARK: - CompletionResult
//
// `textDocument/completion` returns `CompletionItem[] | CompletionList | null`.
// The `null` case is modelled by `Optional<CompletionResult>` at the call site;
// this enum captures only the two non-null shapes.
//
// Discrimination:
//   - JSON array         -> .items
//   - JSON object        -> .list
//
// We decode `.items` first because `CompletionList(from:)` would refuse a raw
// array anyway, and `[CompletionItem](from:)` cleanly rejects an object.

/// Result of `textDocument/completion` (non-null cases).
enum CompletionResult: Sendable, Codable, Equatable {
    case items([CompletionItem])
    case list(CompletionList)

    init(from decoder: any Decoder) throws {
        if let arr = try? [CompletionItem](from: decoder) {
            self = .items(arr)
            return
        }
        let list = try CompletionList(from: decoder)
        self = .list(list)
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .items(let arr):
            try arr.encode(to: encoder)
        case .list(let list):
            try list.encode(to: encoder)
        }
    }
}
