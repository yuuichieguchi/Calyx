//
//  ProgressBroker.swift
//  Calyx
//
//  Actor that aggregates LSP work-done progress state: token reservations
//  from `window/workDoneProgress/create` plus the matching
//  `$/progress` notification stream (`begin` / `report` / `end`).
//
//  Spec references:
//    - $/progress:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#progress
//    - window/workDoneProgress/create:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#window_workDoneProgress_create
//    - WorkDoneProgressBegin/Report/End:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#workDoneProgress
//
//  Lifecycle:
//    1. Server asks the client to reserve a token via
//       `window/workDoneProgress/create`. The application layer calls
//       `registerToken(_:)`. At this point the token has no status yet —
//       `status(for:)` returns nil and the token does not appear in
//       `inFlight()`.
//    2. Server sends `$/progress` with kind `begin`. The broker promotes the
//       reservation into a live `ProgressEntry` and `status(for:)` reports
//       `.begin`. Re-registering the token now is a no-op (we never
//       overwrite live state with the placeholder).
//    3. Subsequent `report` notifications update message / percentage /
//       cancellable; the entry keeps the title captured at `begin`.
//    4. An `end` notification moves the entry from in-flight into a small
//       bounded "recently ended" ring (FIFO, max 20 entries). `status(for:)`
//       continues to report `.end` for ended-but-still-retained tokens.
//
//  Progress notifications for tokens that were never registered are silently
//  dropped (the spec leaves this implementation-defined; dropping is the
//  safe default — we never invent state from unverified server traffic).
//

import Foundation

// MARK: - Public value types

/// Coarse status of a tracked progress entry.
enum ProgressStatus: Sendable, Equatable {
    case begin
    case report
    case end
}

/// A single tracked progress entry. Title is captured from the `begin`
/// payload and preserved across subsequent `report` / `end` notifications.
struct ProgressEntry: Sendable, Equatable {
    /// Token this entry was reported under.
    let token: ProgressToken
    /// Coarse status — the kind of the last `$/progress` notification.
    let status: ProgressStatus
    /// Title set at `begin`. May be nil for entries promoted by a
    /// non-begin notification (which the broker rejects, so in practice
    /// this is always non-nil once an entry exists).
    let title: String?
    /// Most recent message text. `nil` until a notification provides one.
    let message: String?
    /// Most recent percentage (0..100). `nil` until a notification provides
    /// one. Stored as `Int?` for ergonomic comparison; the wire type is
    /// `uinteger`, which is non-negative.
    let percentage: Int?
    /// Whether the operation is currently cancellable.
    let cancellable: Bool
}

/// Snapshot of the broker's state at a point in time.
struct ProgressSnapshot: Sendable, Equatable {
    /// Entries whose last notification was `begin` or `report`.
    let inFlight: [ProgressEntry]
    /// Bounded ring of recently-ended entries (oldest first).
    let recentlyEnded: [ProgressEntry]
}

// MARK: - ProgressBroker

actor ProgressBroker {

    /// Internal per-token state. `.reserved` means `registerToken` was called
    /// but no `begin` has arrived yet; `.live` means the broker is tracking
    /// a full `ProgressEntry`.
    private enum TokenState {
        case reserved
        case live(ProgressEntry)
    }

    /// Maximum number of ended entries retained in `recentlyEnded`.
    private static let recentlyEndedCapacity = 20

    private var tokens: [ProgressToken: TokenState] = [:]
    private var recentlyEnded: [ProgressEntry] = []

    init() {}

    // MARK: - Registration

    /// Reserve a progress token. Idempotent: if the token is already
    /// reserved or live, this is a no-op (we never clobber live state).
    func registerToken(_ token: ProgressToken) {
        if tokens[token] != nil {
            return
        }
        tokens[token] = .reserved
    }

    // MARK: - Progress ingestion

    /// Apply a `$/progress` notification's `value` to the token's entry.
    /// Notifications for unknown tokens are silently dropped.
    func handleProgress(token: ProgressToken, value: WorkDoneProgress) {
        guard tokens[token] != nil else {
            // Unregistered token → drop.
            return
        }

        switch value {
        case .begin(let payload):
            let entry = ProgressEntry(
                token: token,
                status: .begin,
                title: payload.title,
                message: payload.message,
                percentage: payload.percentage.map { Int($0) },
                cancellable: payload.cancellable ?? false
            )
            tokens[token] = .live(entry)

        case .report(let payload):
            let existing = currentEntry(for: token)
            let entry = ProgressEntry(
                token: token,
                status: .report,
                // Title is set at begin and preserved across reports.
                title: existing?.title,
                // Per spec: a missing message/percentage means "unchanged".
                message: payload.message ?? existing?.message,
                percentage: payload.percentage.map { Int($0) } ?? existing?.percentage,
                cancellable: payload.cancellable ?? existing?.cancellable ?? false
            )
            tokens[token] = .live(entry)

        case .end(let payload):
            let existing = currentEntry(for: token)
            let entry = ProgressEntry(
                token: token,
                status: .end,
                title: existing?.title,
                message: payload.message ?? existing?.message,
                percentage: existing?.percentage,
                cancellable: false
            )
            tokens[token] = .live(entry)
            appendRecentlyEnded(entry)
        }
    }

    // MARK: - Queries

    /// The coarse status of the last `$/progress` notification for `token`,
    /// or `nil` if the token was never registered or has not yet received
    /// its first notification.
    func status(for token: ProgressToken) -> ProgressStatus? {
        switch tokens[token] {
        case .live(let entry): return entry.status
        case .reserved, .none: return nil
        }
    }

    /// All entries whose last status is `.begin` or `.report`.
    func inFlight() -> [ProgressEntry] {
        return tokens.values.compactMap { state -> ProgressEntry? in
            guard case .live(let entry) = state else { return nil }
            switch entry.status {
            case .begin, .report: return entry
            case .end:            return nil
            }
        }
    }

    /// A full snapshot of broker state at this moment.
    func snapshot() -> ProgressSnapshot {
        return ProgressSnapshot(
            inFlight: inFlight(),
            recentlyEnded: recentlyEnded
        )
    }

    /// Reset all state. Reserved tokens, live entries, and the
    /// recently-ended ring are all cleared.
    func reset() {
        tokens.removeAll()
        recentlyEnded.removeAll()
    }

    // MARK: - Helpers

    private func currentEntry(for token: ProgressToken) -> ProgressEntry? {
        if case .live(let entry) = tokens[token] { return entry }
        return nil
    }

    private func appendRecentlyEnded(_ entry: ProgressEntry) {
        recentlyEnded.append(entry)
        if recentlyEnded.count > Self.recentlyEndedCapacity {
            let overflow = recentlyEnded.count - Self.recentlyEndedCapacity
            recentlyEnded.removeFirst(overflow)
        }
    }
}
