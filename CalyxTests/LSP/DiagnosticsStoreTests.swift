//
//  DiagnosticsStoreTests.swift
//  Calyx
//
//  Tests for the `DiagnosticsStore` actor that holds per-workspace, per-URI
//  diagnostic snapshots produced by LSP `textDocument/publishDiagnostics`
//  notifications. Supports point-in-time snapshot IDs so that MCP clients
//  can pull only the deltas since their last poll.
//
//  Spec references:
//    - publishDiagnostics:
//      https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_publishDiagnostics
//      Servers send the absolute set of diagnostics for a URI on each
//      notification (so a publish with an empty array means "clear"). When a
//      `version` is present, the client should ignore the notification if it
//      is older than the document version the client currently believes is
//      authoritative for that URI.
//
//  Behaviour under test:
//    - `ingest` stores the diagnostics for (workspaceRoot, uri).
//    - Newer-or-equal `version` overwrites; strictly older `version` is
//      ignored. A nil version on the incoming params overwrites
//      unconditionally (no version means "current").
//    - `diagnostics(workspaceRoot:, uri:)` returns the latest list.
//    - `workspaceDiagnostics(workspaceRoot:)` returns URI → diagnostics.
//    - `createSnapshot(workspaceRoot:)` allocates a strictly-monotonic
//      `SnapshotId`.
//    - `diff(workspaceRoot:, since:)` returns the URIs whose diagnostics
//      changed (added, modified, or cleared) after the snapshot was taken.
//      A URI that has been cleared appears with an empty array.
//    - `diff` throws `.unknownSnapshot` for never-issued snapshot IDs.
//    - Diagnostics are siloed per workspaceRoot.
//    - `clear(workspaceRoot:)` removes one workspace; others remain.
//    - `clearAll()` removes everything.
//
//  TDD phase: RED. `DiagnosticsStore`, `DiagnosticsDiff`,
//  `DiagnosticsStoreError`, `SnapshotId`, and `PublishDiagnosticsParams`
//  do not exist yet. This file is expected to fail to compile until the
//  swift-specialist creates `Calyx/Features/LSP/DiagnosticsStore.swift`
//  (and the matching `PublishDiagnosticsParams.swift`).
//

import XCTest
@testable import Calyx

@MainActor
final class DiagnosticsStoreTests: XCTestCase {

    // MARK: - Helpers

    private let workspaceA = URL(fileURLWithPath: "/tmp/ws-a")
    private let workspaceB = URL(fileURLWithPath: "/tmp/ws-b")

    private func makeStore() -> DiagnosticsStore {
        return DiagnosticsStore()
    }

    private func diag(_ message: String, line: Int = 0) -> Diagnostic {
        return Diagnostic(
            range: LSPRange(
                start: Position(line: line, character: 0),
                end:   Position(line: line, character: 1)
            ),
            severity: .error,
            message: message
        )
    }

    private func params(
        uri: DocumentUri,
        version: Int?,
        diagnostics: [Diagnostic]
    ) -> PublishDiagnosticsParams {
        return PublishDiagnosticsParams(
            uri: uri,
            version: version,
            diagnostics: diagnostics
        )
    }

    // ====================================================================
    // MARK: - Ingest + read
    // ====================================================================

    func test_ingest_storesDiagnosticsForUri() async {
        let store = makeStore()
        let uri: DocumentUri = "file:///tmp/ws-a/Foo.swift"
        let d = diag("nope")

        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [d]))

        let got = await store.diagnostics(workspaceRoot: workspaceA, uri: uri)
        XCTAssertEqual(got, [d])
    }

    func test_workspaceDiagnostics_returnsAllUrisInThatWorkspace() async {
        let store = makeStore()
        let u1: DocumentUri = "file:///tmp/ws-a/One.swift"
        let u2: DocumentUri = "file:///tmp/ws-a/Two.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: u1, version: 1, diagnostics: [diag("a")]))
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: u2, version: 1, diagnostics: [diag("b")]))

        let map = await store.workspaceDiagnostics(workspaceRoot: workspaceA)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map[u1], [diag("a")])
        XCTAssertEqual(map[u2], [diag("b")])
    }

    // ====================================================================
    // MARK: - Versioning
    // ====================================================================

    func test_ingest_newerVersionOverwrites() async {
        let store = makeStore()
        let uri: DocumentUri = "file:///tmp/ws-a/Foo.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("v1")]))
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 2, diagnostics: [diag("v2")]))

        let got = await store.diagnostics(workspaceRoot: workspaceA, uri: uri)
        XCTAssertEqual(got, [diag("v2")])
    }

    func test_ingest_olderVersionIsIgnored() async {
        let store = makeStore()
        let uri: DocumentUri = "file:///tmp/ws-a/Foo.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 5, diagnostics: [diag("current")]))
        // Late-arriving stale notification.
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("stale")]))

        let got = await store.diagnostics(workspaceRoot: workspaceA, uri: uri)
        XCTAssertEqual(got, [diag("current")], "older-version publish must be ignored")
    }

    // ====================================================================
    // MARK: - Workspace isolation
    // ====================================================================

    func test_workspaces_areIsolated() async {
        let store = makeStore()
        let uri: DocumentUri = "file:///shared/Path.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("A")]))
        await store.ingest(workspaceRoot: workspaceB, params: params(uri: uri, version: 1, diagnostics: [diag("B")]))

        let a = await store.diagnostics(workspaceRoot: workspaceA, uri: uri)
        let b = await store.diagnostics(workspaceRoot: workspaceB, uri: uri)
        XCTAssertEqual(a, [diag("A")])
        XCTAssertEqual(b, [diag("B")])
    }

    // ====================================================================
    // MARK: - Snapshots + diff
    // ====================================================================

    func test_createSnapshot_returnsMonotonicId() async {
        let store = makeStore()
        let s1 = await store.createSnapshot(workspaceRoot: workspaceA)
        let s2 = await store.createSnapshot(workspaceRoot: workspaceA)
        let s3 = await store.createSnapshot(workspaceRoot: workspaceA)
        XCTAssertLessThan(s1, s2)
        XCTAssertLessThan(s2, s3)
    }

    func test_diff_newUriAfterSnapshot_appearsInChangedUris() async throws {
        let store = makeStore()
        let s0 = await store.createSnapshot(workspaceRoot: workspaceA)

        let uri: DocumentUri = "file:///tmp/ws-a/New.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("new")]))

        let diff = try await store.diff(workspaceRoot: workspaceA, since: s0)
        XCTAssertEqual(diff.snapshotId, s0)
        XCTAssertGreaterThanOrEqual(diff.currentSnapshotId, s0)
        XCTAssertEqual(diff.changedUris.count, 1)
        XCTAssertEqual(diff.changedUris[uri], [diag("new")])
    }

    func test_diff_modifiedUriAppears() async throws {
        let store = makeStore()
        let uri: DocumentUri = "file:///tmp/ws-a/Mod.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("initial")]))

        let s0 = await store.createSnapshot(workspaceRoot: workspaceA)

        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 2, diagnostics: [diag("updated")]))

        let diff = try await store.diff(workspaceRoot: workspaceA, since: s0)
        XCTAssertEqual(diff.changedUris[uri], [diag("updated")])
    }

    func test_diff_clearedUriAppearsAsEmptyArray() async throws {
        let store = makeStore()
        let uri: DocumentUri = "file:///tmp/ws-a/Cleared.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("bad")]))

        let s0 = await store.createSnapshot(workspaceRoot: workspaceA)

        // Server sends an empty list = cleared.
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 2, diagnostics: []))

        let diff = try await store.diff(workspaceRoot: workspaceA, since: s0)
        XCTAssertNotNil(diff.changedUris[uri], "cleared URI must be present in diff")
        XCTAssertEqual(diff.changedUris[uri], [])
    }

    func test_diff_noChangesSinceSnapshot_returnsEmpty() async throws {
        let store = makeStore()
        await store.ingest(workspaceRoot: workspaceA, params: params(
            uri: "file:///tmp/ws-a/Stable.swift",
            version: 1,
            diagnostics: [diag("hold")]
        ))
        let s0 = await store.createSnapshot(workspaceRoot: workspaceA)

        let diff = try await store.diff(workspaceRoot: workspaceA, since: s0)
        XCTAssertTrue(diff.changedUris.isEmpty)
    }

    func test_diff_unknownSnapshotId_throwsUnknownSnapshot() async {
        let store = makeStore()
        do {
            _ = try await store.diff(workspaceRoot: workspaceA, since: 999_999)
            XCTFail("expected unknownSnapshot to throw")
        } catch let e as DiagnosticsStoreError {
            XCTAssertEqual(e, .unknownSnapshot(999_999))
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // ====================================================================
    // MARK: - Snapshot dict pruning + hard cap
    // ====================================================================

    /// A well-behaved polling client always feeds back the previously
    /// returned `currentSnapshotId`. In that case, every previous id is
    /// dead history and must be pruned from the internal snapshot dict so
    /// it does not grow without bound over a long session.
    func test_diff_prunesSnapshotsOlderThanSince() async throws {
        let store = makeStore()
        let anchor = await store.createSnapshot(workspaceRoot: workspaceA)
        var lastId = anchor
        for _ in 0..<5 {
            let diff = try await store.diff(workspaceRoot: workspaceA, since: lastId)
            lastId = diff.currentSnapshotId
        }

        // After each diff, the prune drops every id ≤ `since`, leaving
        // only the freshly-issued currentSnapshotId. The dict should
        // therefore hold at most that one entry — and certainly nothing
        // close to the number of diff calls we made.
        let count = await store._snapshotCount(workspaceRoot: workspaceA)
        XCTAssertLessThanOrEqual(
            count, 2,
            "well-behaved polling must not let the snapshot dict accumulate"
        )

        // And the original anchor must no longer be referenced — diffing
        // against it must surface `unknownSnapshot`.
        do {
            _ = try await store.diff(workspaceRoot: workspaceA, since: anchor)
            XCTFail("expected stale anchor snapshot id to have been pruned")
        } catch DiagnosticsStoreError.unknownSnapshot {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A misbehaving client that never advances `since` would otherwise
    /// inflate the snapshot dict forever. The hard cap (64) must clamp
    /// the dict size even when the per-call prune does nothing useful.
    ///
    /// We simulate "since always points at the very first id" by inflating
    /// the dict with `createSnapshot` (which by design does not prune),
    /// then firing diff calls that anchor at the earliest id. The literal
    /// id 0 was never issued, so we use the actual earliest as a proxy.
    func test_diff_isCappedAt64WhenSinceIsAlwaysZero() async throws {
        let store = makeStore()
        let anchor = await store.createSnapshot(workspaceRoot: workspaceA)
        for _ in 0..<100 {
            _ = await store.createSnapshot(workspaceRoot: workspaceA)
        }
        // Now ~101 snapshot ids are sitting in the dict, all ≥ `anchor`.
        for _ in 0..<100 {
            _ = try? await store.diff(workspaceRoot: workspaceA, since: anchor)
        }
        let count = await store._snapshotCount(workspaceRoot: workspaceA)
        XCTAssertLessThanOrEqual(
            count, 64,
            "snapshot dict must be capped at 64 entries"
        )
    }

    // ====================================================================
    // MARK: - Clear
    // ====================================================================

    func test_clear_removesOnlyThatWorkspace() async {
        let store = makeStore()
        let uri: DocumentUri = "file:///shared/Path.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("A")]))
        await store.ingest(workspaceRoot: workspaceB, params: params(uri: uri, version: 1, diagnostics: [diag("B")]))

        await store.clear(workspaceRoot: workspaceA)

        let a = await store.diagnostics(workspaceRoot: workspaceA, uri: uri)
        let b = await store.diagnostics(workspaceRoot: workspaceB, uri: uri)
        XCTAssertTrue(a.isEmpty)
        XCTAssertEqual(b, [diag("B")])
    }

    func test_clearAll_removesEverything() async {
        let store = makeStore()
        let uri: DocumentUri = "file:///shared/Path.swift"
        await store.ingest(workspaceRoot: workspaceA, params: params(uri: uri, version: 1, diagnostics: [diag("A")]))
        await store.ingest(workspaceRoot: workspaceB, params: params(uri: uri, version: 1, diagnostics: [diag("B")]))

        await store.clearAll()

        let a = await store.diagnostics(workspaceRoot: workspaceA, uri: uri)
        let b = await store.diagnostics(workspaceRoot: workspaceB, uri: uri)
        XCTAssertTrue(a.isEmpty)
        XCTAssertTrue(b.isEmpty)
    }
}
