// UsageIngestMonitor.swift
// Calyx
//
// What the app knows about the usage route at run time: the credential the
// route accepts right now, and what the last requests were answered with.

import Foundation
import Observation

// MARK: - UsageIngestMonitor

/// What the Settings pane and the Usage window show about reception.
@MainActor @Observable
final class UsageIngestMonitor {
    /// The refusals an exporter can cause; the only ones kept.
    enum ExporterRejection: Equatable {
        case unauthorized, tooLarge, undecodable, unavailable

        /// nil for a refusal that is not from an exporter (`foreignOrigin`, `noBody`).
        init?(_ rejection: UsageIngestRejection) {
            switch rejection {
            case .unauthorized: self = .unauthorized
            case .tooLarge: self = .tooLarge
            case .undecodable: self = .undecodable
            case .unavailable: self = .unavailable
            case .foreignOrigin, .noBody: return nil
            }
        }
    }

    struct Rejection: Equatable {
        let reason: ExporterRejection
        let at: Date
    }

    static let shared = UsageIngestMonitor()

    /// When the route last accepted an export (stored or dropped).
    private(set) var lastAcceptedAt: Date?
    /// The last refusal an exporter can cause.
    private(set) var lastRejection: Rejection?

    init() {}

    /// Records one verdict of the route: nil for an accepted request.
    /// Only refusals an exporter can cause are kept (`unauthorized`,
    /// `tooLarge`, `undecodable`, `unavailable`); a request with an
    /// `Origin` header or without a body is not from Claude Code and
    /// changes nothing here.
    func note(_ rejection: UsageIngestRejection?, at date: Date) {
        guard let rejection else {
            lastAcceptedAt = date
            return
        }
        guard let reason = ExporterRejection(rejection) else { return }
        lastRejection = Rejection(reason: reason, at: date)
    }
}

// MARK: - UsageIngestCredentialHolder

/// The credential the route accepts right now.
@MainActor
final class UsageIngestCredentialHolder {
    static let shared = UsageIngestCredentialHolder()

    private(set) var credential: UsageIngestCredential?
    /// The server start generation the token was last renewed for.
    private(set) var lastRotatedGeneration: Int?

    init() {}

    func set(_ credential: UsageIngestCredential?) {
        self.credential = credential
    }

    /// Loads the credential file of `directory` and holds what it found.
    ///
    /// - `create: true` reads the file, or writes a new token when it is
    ///   missing or unusable (`UsageIngestCredentialStore.loadOrCreate`).
    /// - `create: false` creates nothing: no usable file holds nil.
    ///
    /// The file work runs on the usage file queue (`UsageFileWork`), off
    /// the main actor and the concurrency pool (`loadOrCreate` may wait
    /// for a file lock). A load that throws leaves the held credential as it
    /// was and the error reaches the caller.
    ///
    /// `rotateForGeneration` (with `create: true`) renews the token when
    /// it differs from the generation last renewed for: one renewal per
    /// server start whose IPC token rotated, idempotent across reconcile
    /// re-runs for the same start (G5, C-D19). nil never renews. The
    /// generation is recorded only after the renewal succeeded.
    ///
    /// Whether to renew is decided before the `await`, and the generation
    /// recorded after it. Nothing here stops two concurrent loads for the
    /// same generation from both renewing; only `UsageTelemetryActivation`'s
    /// single-flight `reconcile()`, the sole production caller, prevents it.
    ///
    /// `makeToken` makes a new token; production uses the default
    /// (`SecureRandomTokenGenerator`), tests inject failures.
    @discardableResult
    func load(
        create: Bool,
        directory: String,
        rotateForGeneration: Int? = nil,
        makeToken: @escaping @Sendable () throws -> String = { try SecureRandomTokenGenerator().makeToken() }
    ) async throws -> UsageIngestCredential? {
        let rotate = create && rotateForGeneration != nil && rotateForGeneration != lastRotatedGeneration
        let loaded = try await Self.readCredential(
            create: create, directory: directory, replaceExisting: rotate, makeToken: makeToken)
        credential = loaded
        if rotate { lastRotatedGeneration = rotateForGeneration }
        return loaded
    }

    private nonisolated static func readCredential(
        create: Bool, directory: String, replaceExisting: Bool,
        makeToken: @escaping @Sendable () throws -> String
    ) async throws -> UsageIngestCredential? {
        try await UsageFileWork.run {
            guard create else { return UsageIngestCredentialStore.read(directory: directory) }
            return try UsageIngestCredentialStore.loadOrCreate(
                directory: directory, makeToken: makeToken,
                replaceExisting: replaceExisting)
        }
    }
}
