//
//  PullDiagnostics.swift
//  Calyx
//
//  LSP 3.18 Pull Diagnostics feature cluster. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_diagnostic
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspace_diagnostic
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#documentDiagnosticReport
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workspaceDiagnosticReport
//

import Foundation

// MARK: - DocumentDiagnosticParams

/// Parameters of the `textDocument/diagnostic` request.
struct DocumentDiagnosticParams: Sendable, Codable, Equatable {
    /// The text document.
    let textDocument: TextDocumentIdentifier
    /// The additional identifier provided during registration.
    let identifier: String?
    /// The result id of a previous response if provided.
    let previousResultId: String?
    /// An optional token that a server can use to report work done progress.
    let workDoneToken: ProgressToken?
    /// An optional token that a server can use to report partial results
    /// (e.g. streaming) to the client.
    let partialResultToken: ProgressToken?

    init(
        textDocument: TextDocumentIdentifier,
        identifier: String? = nil,
        previousResultId: String? = nil,
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.textDocument = textDocument
        self.identifier = identifier
        self.previousResultId = previousResultId
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - DocumentDiagnosticReportKind

/// The document diagnostic report kinds, used as a discriminator on the
/// concrete report types.
enum DocumentDiagnosticReportKind: String, Sendable, Codable, Equatable {
    /// A diagnostic report with a full set of problems.
    case full
    /// A report indicating that the last returned report is still accurate.
    case unchanged
}

// MARK: - RelatedFullDocumentDiagnosticReport

/// A full document diagnostic report optionally containing diagnostics for
/// related documents.
struct RelatedFullDocumentDiagnosticReport: Sendable, Codable, Equatable {
    /// A document diagnostic report indicating diagnostic information.
    /// Always `.full` for this concrete type.
    let kind: DocumentDiagnosticReportKind
    /// An optional result id. If provided it will be sent on the next
    /// diagnostic request for the same document.
    let resultId: String?
    /// The actual items.
    let items: [Diagnostic]
    /// Diagnostics of related documents. This information is useful in
    /// programming languages where code in a file A can generate diagnostics
    /// in a file B which A depends on.
    let relatedDocuments: [DocumentUri: RelatedDocumentDiagnosticReport]?

    init(
        resultId: String? = nil,
        items: [Diagnostic],
        relatedDocuments: [DocumentUri: RelatedDocumentDiagnosticReport]? = nil
    ) {
        self.kind = .full
        self.resultId = resultId
        self.items = items
        self.relatedDocuments = relatedDocuments
    }
}

// MARK: - RelatedUnchangedDocumentDiagnosticReport

/// An unchanged document diagnostic report. Optionally references related
/// reports for documents whose diagnostics did change.
struct RelatedUnchangedDocumentDiagnosticReport: Sendable, Codable, Equatable {
    /// Always `.unchanged` for this concrete type.
    let kind: DocumentDiagnosticReportKind
    /// A result id which will be sent on the next diagnostic request for
    /// the same document.
    let resultId: String
    /// Diagnostics of related documents.
    let relatedDocuments: [DocumentUri: RelatedDocumentDiagnosticReport]?

    init(
        resultId: String,
        relatedDocuments: [DocumentUri: RelatedDocumentDiagnosticReport]? = nil
    ) {
        self.kind = .unchanged
        self.resultId = resultId
        self.relatedDocuments = relatedDocuments
    }
}

// MARK: - RelatedDocumentDiagnosticReport

/// A union of either a full or unchanged diagnostic report for a related
/// document. Discriminated by the `kind` JSON field. The "related" form is
/// flatter than `(Related)?(Full|Unchanged)DocumentDiagnosticReport` because
/// the spec does not allow further nesting of `relatedDocuments` here.
enum RelatedDocumentDiagnosticReport: Sendable, Codable, Equatable {
    case full(resultId: String?, items: [Diagnostic])
    case unchanged(resultId: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case resultId
        case items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(DocumentDiagnosticReportKind.self, forKey: .kind)
        switch kind {
        case .full:
            let resultId = try container.decodeIfPresent(String.self, forKey: .resultId)
            let items = try container.decode([Diagnostic].self, forKey: .items)
            self = .full(resultId: resultId, items: items)
        case .unchanged:
            let resultId = try container.decode(String.self, forKey: .resultId)
            self = .unchanged(resultId: resultId)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .full(let resultId, let items):
            try container.encode(DocumentDiagnosticReportKind.full, forKey: .kind)
            try container.encodeIfPresent(resultId, forKey: .resultId)
            try container.encode(items, forKey: .items)
        case .unchanged(let resultId):
            try container.encode(DocumentDiagnosticReportKind.unchanged, forKey: .kind)
            try container.encode(resultId, forKey: .resultId)
        }
    }
}

// MARK: - DocumentDiagnosticReport

/// The result of a `textDocument/diagnostic` request. Either a full report
/// or an unchanged-since-previous report, discriminated by the `kind` field.
enum DocumentDiagnosticReport: Sendable, Codable, Equatable {
    case full(RelatedFullDocumentDiagnosticReport)
    case unchanged(RelatedUnchangedDocumentDiagnosticReport)

    private enum DiscriminatorKey: String, CodingKey {
        case kind
    }

    init(from decoder: any Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try probe.decode(DocumentDiagnosticReportKind.self, forKey: .kind)
        switch kind {
        case .full:
            self = .full(try RelatedFullDocumentDiagnosticReport(from: decoder))
        case .unchanged:
            self = .unchanged(try RelatedUnchangedDocumentDiagnosticReport(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .full(let r):
            try r.encode(to: encoder)
        case .unchanged(let r):
            try r.encode(to: encoder)
        }
    }
}

// MARK: - PreviousResultId

/// A previous result id in a workspace pull-diagnostics request.
struct PreviousResultId: Sendable, Codable, Equatable {
    /// The URI for which the client knows a result id.
    let uri: DocumentUri
    /// The value of the previous result id.
    let value: String

    init(uri: DocumentUri, value: String) {
        self.uri = uri
        self.value = value
    }
}

// MARK: - WorkspaceDiagnosticParams

/// Parameters of the `workspace/diagnostic` request.
struct WorkspaceDiagnosticParams: Sendable, Codable, Equatable {
    /// The additional identifier provided during registration.
    let identifier: String?
    /// The currently known diagnostic reports with their previous result ids.
    let previousResultIds: [PreviousResultId]
    /// An optional token that a server can use to report work done progress.
    let workDoneToken: ProgressToken?
    /// An optional token that a server can use to report partial results.
    let partialResultToken: ProgressToken?

    init(
        identifier: String? = nil,
        previousResultIds: [PreviousResultId],
        workDoneToken: ProgressToken? = nil,
        partialResultToken: ProgressToken? = nil
    ) {
        self.identifier = identifier
        self.previousResultIds = previousResultIds
        self.workDoneToken = workDoneToken
        self.partialResultToken = partialResultToken
    }
}

// MARK: - WorkspaceFullDocumentDiagnosticReport

/// A full document diagnostic report for a workspace diagnostic result.
struct WorkspaceFullDocumentDiagnosticReport: Sendable, Codable, Equatable {
    /// Always `.full` for this concrete type.
    let kind: DocumentDiagnosticReportKind
    /// The URI for which diagnostic information is reported.
    let uri: DocumentUri
    /// The version number for which the diagnostics are reported. If the
    /// document is not marked as open, `nil` can be provided.
    let version: Int?
    /// An optional result id.
    let resultId: String?
    /// The actual items.
    let items: [Diagnostic]

    init(
        uri: DocumentUri,
        version: Int? = nil,
        resultId: String? = nil,
        items: [Diagnostic]
    ) {
        self.kind = .full
        self.uri = uri
        self.version = version
        self.resultId = resultId
        self.items = items
    }
}

// MARK: - WorkspaceUnchangedDocumentDiagnosticReport

/// An unchanged document diagnostic report for a workspace diagnostic result.
struct WorkspaceUnchangedDocumentDiagnosticReport: Sendable, Codable, Equatable {
    /// Always `.unchanged` for this concrete type.
    let kind: DocumentDiagnosticReportKind
    /// The URI for which diagnostic information is reported.
    let uri: DocumentUri
    /// The version number for which the diagnostics are reported.
    let version: Int?
    /// A result id which will be sent on the next diagnostic request for
    /// the same document.
    let resultId: String

    init(
        uri: DocumentUri,
        version: Int? = nil,
        resultId: String
    ) {
        self.kind = .unchanged
        self.uri = uri
        self.version = version
        self.resultId = resultId
    }
}

// MARK: - WorkspaceDocumentDiagnosticReport

/// A union of either a full or unchanged workspace document diagnostic
/// report. Discriminated by the `kind` field.
enum WorkspaceDocumentDiagnosticReport: Sendable, Codable, Equatable {
    case full(WorkspaceFullDocumentDiagnosticReport)
    case unchanged(WorkspaceUnchangedDocumentDiagnosticReport)

    private enum DiscriminatorKey: String, CodingKey {
        case kind
    }

    init(from decoder: any Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try probe.decode(DocumentDiagnosticReportKind.self, forKey: .kind)
        switch kind {
        case .full:
            self = .full(try WorkspaceFullDocumentDiagnosticReport(from: decoder))
        case .unchanged:
            self = .unchanged(try WorkspaceUnchangedDocumentDiagnosticReport(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .full(let r):
            try r.encode(to: encoder)
        case .unchanged(let r):
            try r.encode(to: encoder)
        }
    }
}

// MARK: - WorkspaceDiagnosticReport

/// A workspace diagnostic report, returned in response to a
/// `workspace/diagnostic` request.
struct WorkspaceDiagnosticReport: Sendable, Codable, Equatable {
    let items: [WorkspaceDocumentDiagnosticReport]

    init(items: [WorkspaceDocumentDiagnosticReport]) {
        self.items = items
    }
}
