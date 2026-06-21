//
//  WorkDoneProgress.swift
//  Calyx
//
//  LSP 3.18 WorkDoneProgressBegin / Report / End. See:
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgress
//
//  Servers report progress for long-running operations using `$/progress`
//  notifications whose `value` is one of three shapes discriminated by the
//  `kind` field:
//      "begin"  → WorkDoneProgressBegin   (mandatory `title`)
//      "report" → WorkDoneProgressReport
//      "end"    → WorkDoneProgressEnd
//

import Foundation

// MARK: - Begin

/// Reports the beginning of a work-done progress. The `title` is mandatory
/// and should be brief — clients render it prominently.
struct WorkDoneProgressBegin: Sendable, Codable, Equatable, Hashable {
    /// Always the literal string `"begin"`.
    let kind: String
    /// Mandatory title of the progress operation.
    let title: String
    /// Controls if a cancel button should be shown.
    let cancellable: Bool?
    /// Optional, more detailed associated progress message.
    let message: String?
    /// Optional progress percentage to display (0-100).
    let percentage: UInt?

    init(
        title: String,
        cancellable: Bool? = nil,
        message: String? = nil,
        percentage: UInt? = nil
    ) {
        self.kind = "begin"
        self.title = title
        self.cancellable = cancellable
        self.message = message
        self.percentage = percentage
    }
}

// MARK: - Report

/// Reporting progress is done using the `kind = "report"` payload.
struct WorkDoneProgressReport: Sendable, Codable, Equatable, Hashable {
    /// Always the literal string `"report"`.
    let kind: String
    /// Cancellability of the operation may change mid-flight.
    let cancellable: Bool?
    /// Optional message replacing the previous one.
    let message: String?
    /// Optional progress percentage (0-100). Clients are free to ignore.
    let percentage: UInt?

    init(
        cancellable: Bool? = nil,
        message: String? = nil,
        percentage: UInt? = nil
    ) {
        self.kind = "report"
        self.cancellable = cancellable
        self.message = message
        self.percentage = percentage
    }
}

// MARK: - End

/// Signals the end of progress reporting.
struct WorkDoneProgressEnd: Sendable, Codable, Equatable, Hashable {
    /// Always the literal string `"end"`.
    let kind: String
    /// Optional final message.
    let message: String?

    init(message: String? = nil) {
        self.kind = "end"
        self.message = message
    }
}

// MARK: - WorkDoneProgress union

/// A kind-discriminated three-way enum over the `WorkDoneProgress` variants.
enum WorkDoneProgress: Sendable, Codable, Equatable, Hashable {
    case begin(WorkDoneProgressBegin)
    case report(WorkDoneProgressReport)
    case end(WorkDoneProgressEnd)

    private enum DiscriminatorKey: String, CodingKey {
        case kind
    }

    init(from decoder: any Decoder) throws {
        let probe = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try probe.decode(String.self, forKey: .kind)
        switch kind {
        case "begin":
            self = .begin(try WorkDoneProgressBegin(from: decoder))
        case "report":
            self = .report(try WorkDoneProgressReport(from: decoder))
        case "end":
            self = .end(try WorkDoneProgressEnd(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: probe,
                debugDescription: "Unknown WorkDoneProgress kind '\(kind)'."
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .begin(let payload):
            try payload.encode(to: encoder)
        case .report(let payload):
            try payload.encode(to: encoder)
        case .end(let payload):
            try payload.encode(to: encoder)
        }
    }
}
