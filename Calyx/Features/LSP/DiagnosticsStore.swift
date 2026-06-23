//
//  DiagnosticsStore.swift
//  Calyx
//
//  Actor that holds per-workspace, per-URI diagnostic snapshots produced by
//  LSP `textDocument/publishDiagnostics` notifications, with point-in-time
//  snapshot IDs so MCP clients can pull only the deltas since their last
//  poll.
//
//  Spec reference (publishDiagnostics):
//  https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_publishDiagnostics
//
//  Per-URI versioning:
//    - LSP servers send the absolute set of diagnostics for a URI on each
//      notification. An empty `diagnostics` array means "clear".
//    - When `version` is present, an incoming publish is accepted iff it is
//      strictly newer than the version we already have for that URI. A nil
//      incoming version overwrites unconditionally (the server is telling
//      us "this is current, I'm not versioning"). A nil stored version is
//      always overwritten by anything new.
//
//  Snapshots and diff:
//    - Internally we track a workspace-local monotonic `changeCounter`
//      that bumps on every accepted ingest. Each URI remembers the counter
//      value at its last change (`lastChangedAt`).
//    - `createSnapshot` issues a strictly-monotonic `SnapshotId` and records
//      the current `changeCounter` against it. `diff(since:)` returns the
//      URIs whose `lastChangedAt` is greater than the counter value at the
//      snapshot — that is, all URIs that changed *after* the snapshot was
//      taken. A cleared URI is materialised as an empty diagnostic array
//      in the diff (the store stores the empty array verbatim).
//

import Foundation

// MARK: - Public types

/// Opaque monotonic identifier for a workspace snapshot. Issued by
/// `DiagnosticsStore.createSnapshot(workspaceRoot:)`.
typealias SnapshotId = Int

/// Result of `DiagnosticsStore.diff(workspaceRoot:, since:)`.
struct DiagnosticsDiff: Sendable, Equatable, Codable {
    /// The snapshot id the caller passed in as `since`.
    let snapshotId: SnapshotId
    /// A freshly-issued snapshot id representing "now". Callers should pass
    /// this back as `since` on their next `diff` call to receive only the
    /// next round of deltas.
    let currentSnapshotId: SnapshotId
    /// URIs whose diagnostics changed strictly after `snapshotId`. Cleared
    /// URIs are present with an empty array.
    let changedUris: [DocumentUri: [Diagnostic]]
}

enum DiagnosticsStoreError: Error, Equatable {
    /// The given `SnapshotId` was never issued by `createSnapshot` (or its
    /// workspace has been cleared since).
    case unknownSnapshot(SnapshotId)
}

// MARK: - DiagnosticsStore

actor DiagnosticsStore {

    /// Per-workspace mutable state.
    private struct WorkspaceState {
        /// Last accepted document version for each URI. May be `nil` if the
        /// server's most recent publish for this URI omitted `version`.
        var versions: [DocumentUri: Int?] = [:]
        /// Latest diagnostic list for each URI. Empty array = cleared.
        var diagnostics: [DocumentUri: [Diagnostic]] = [:]
        /// `changeCounter` value at the most recent accepted ingest for
        /// each URI.
        var lastChangedAt: [DocumentUri: Int] = [:]
        /// Workspace-local monotonic counter; bumped on every accepted
        /// ingest.
        var changeCounter: Int = 0
        /// Next snapshot id to issue (workspace-local, strictly monotonic).
        var nextSnapshotId: SnapshotId = 1
        /// Snapshot id → `changeCounter` value at issue time.
        var snapshots: [SnapshotId: Int] = [:]
    }

    private var workspaces: [URL: WorkspaceState] = [:]

    init() {}

    // MARK: - Ingest

    /// Apply a `textDocument/publishDiagnostics` notification.
    func ingest(workspaceRoot: URL, params: PublishDiagnosticsParams) {
        var state = workspaces[workspaceRoot] ?? WorkspaceState()

        let incomingVersion = params.version
        let storedVersion = state.versions[params.uri] ?? nil

        if shouldAccept(incoming: incomingVersion, stored: storedVersion) {
            state.changeCounter += 1
            state.versions[params.uri] = incomingVersion
            state.diagnostics[params.uri] = params.diagnostics
            state.lastChangedAt[params.uri] = state.changeCounter
        }

        workspaces[workspaceRoot] = state
    }

    /// Version-comparison policy for incoming publishes. Returns true iff
    /// the incoming publish should be accepted (overwriting any previous
    /// state for that URI).
    ///
    /// Rules:
    ///   - incoming nil          → accept (server says "this is current")
    ///   - stored   nil          → accept (we have no version to compare)
    ///   - both present, strictly newer → accept
    ///   - both present, equal or older → reject
    private func shouldAccept(incoming: Int?, stored: Int?) -> Bool {
        guard let incoming else { return true }
        guard let stored else { return true }
        return incoming > stored
    }

    // MARK: - Read

    /// Latest diagnostics for `(workspaceRoot, uri)`. Returns an empty array
    /// for unknown workspaces and unknown URIs alike — callers cannot
    /// distinguish "never reported" from "explicitly cleared".
    func diagnostics(workspaceRoot: URL, uri: DocumentUri) -> [Diagnostic] {
        return workspaces[workspaceRoot]?.diagnostics[uri] ?? []
    }

    /// All diagnostics in a workspace, keyed by URI. Returns an empty
    /// dictionary for unknown workspaces.
    func workspaceDiagnostics(workspaceRoot: URL) -> [DocumentUri: [Diagnostic]] {
        return workspaces[workspaceRoot]?.diagnostics ?? [:]
    }

    // MARK: - Snapshots

    /// Allocate a fresh `SnapshotId` representing the workspace's current
    /// state. Strictly monotonic per workspace.
    func createSnapshot(workspaceRoot: URL) -> SnapshotId {
        var state = workspaces[workspaceRoot] ?? WorkspaceState()
        let id = state.nextSnapshotId
        state.nextSnapshotId += 1
        state.snapshots[id] = state.changeCounter
        workspaces[workspaceRoot] = state
        return id
    }

    /// Return the URIs that changed strictly after `snapshotId` was issued.
    /// Throws `unknownSnapshot` if `snapshotId` was never issued (which
    /// includes the case where the workspace has never been touched, or
    /// has been cleared since, or has been pruned by the bookkeeping at
    /// the bottom of this method).
    func diff(workspaceRoot: URL, since snapshotId: SnapshotId) throws -> DiagnosticsDiff {
        guard var state = workspaces[workspaceRoot] else {
            throw DiagnosticsStoreError.unknownSnapshot(snapshotId)
        }
        guard let snapshotCounter = state.snapshots[snapshotId] else {
            throw DiagnosticsStoreError.unknownSnapshot(snapshotId)
        }

        // Materialise the "now" snapshot id so callers can pass it back as
        // `since` next time and pick up where they left off.
        let currentId = state.nextSnapshotId
        state.nextSnapshotId += 1
        state.snapshots[currentId] = state.changeCounter

        // Prune dead history. A well-behaved polling client feeds the just-
        // returned `currentSnapshotId` back as `since` on its next call, so
        // any id ≤ `snapshotId` will never be queried again. Dropping them
        // keeps the snapshot dict from growing unboundedly across a long
        // session.
        state.snapshots = state.snapshots.filter { $0.key > snapshotId }

        // Hard cap defending against a misbehaving client that never
        // advances `since` (e.g., always sends a stale id). When the dict
        // exceeds 64 entries, drop the lowest ids and keep only the most
        // recent 64. Those dropped ids will then surface as
        // `unknownSnapshot` on subsequent diff calls — intentional: the
        // cap defends process memory at the cost of stale clients.
        let cap = 64
        if state.snapshots.count > cap {
            let sortedKeys = state.snapshots.keys.sorted()
            let dropCount = state.snapshots.count - cap
            for key in sortedKeys.prefix(dropCount) {
                state.snapshots.removeValue(forKey: key)
            }
        }

        workspaces[workspaceRoot] = state

        var changed: [DocumentUri: [Diagnostic]] = [:]
        for (uri, changedAt) in state.lastChangedAt where changedAt > snapshotCounter {
            changed[uri] = state.diagnostics[uri] ?? []
        }

        return DiagnosticsDiff(
            snapshotId: snapshotId,
            currentSnapshotId: currentId,
            changedUris: changed
        )
    }

    // MARK: - Testing accessors

    /// Internal accessor for unit tests: number of live snapshot dict
    /// entries for `workspaceRoot`. Not part of the public API and not
    /// intended for production code paths.
    func _snapshotCount(workspaceRoot: URL) -> Int {
        return workspaces[workspaceRoot]?.snapshots.count ?? 0
    }

    // MARK: - Clear

    /// Remove one workspace's state. Snapshots issued for that workspace
    /// become invalid.
    func clear(workspaceRoot: URL) {
        workspaces.removeValue(forKey: workspaceRoot)
    }

    /// Remove every workspace.
    func clearAll() {
        workspaces.removeAll()
    }
}
