//
//  DiagnosticsStoreBugSpecTests.swift
//  Calyx
//
//  Wave 1 RETROFIT — independent verification tests for the
//  `DiagnosticsStore` snapshot-dict unbounded-growth bug.
//
//  BUG SPEC (the snapshots dict per workspace grew on every `diff()` call
//  without pruning). Post-fix invariants under verification here:
//
//    1. `diff(since: snapshotId)` MUST drop entries with id ≤ snapshotId
//       (those are dead history a polling client has already observed).
//    2. There MUST be a hard cap of ≤ 64 entries even if a misbehaving
//       client never advances its `since` cursor.
//    3. After pruning / capping, the `currentSnapshotId` returned by
//       successive `diff()` calls MUST remain strictly monotonic and
//       collision-free.
//
//  These tests are intentionally written BLIND — without reading the
//  production source under test — to validate the behaviour described by
//  the bug spec independently of the implementation.
//

import XCTest
@testable import Calyx

@MainActor
final class DiagnosticsStoreBugSpecTests: XCTestCase {

    // MARK: - Helpers

    private let workspaceRoot = URL(fileURLWithPath: "/tmp/ws-bugspec")

    private func makeStore() -> DiagnosticsStore {
        return DiagnosticsStore()
    }

    // ====================================================================
    // MARK: - Bug 1: diff() must prune entries with id ≤ since
    // ====================================================================

    /// A well-behaved polling client always feeds the previously returned
    /// `currentSnapshotId` back in as the next `since`. In that case every
    /// previously-issued snapshot id is dead history and must be pruned.
    ///
    /// Across 10 consecutive `diff()` calls the internal snapshot dict
    /// must therefore never accumulate beyond at most 2 entries (the
    /// just-issued current id and at most the immediately preceding one
    /// the prune is comparing against).
    func test_diff_prunesEntriesOlderOrEqualToSince() async throws {
        let store = makeStore()

        // Start with an issued anchor so the first `since` is valid.
        let anchor = await store.createSnapshot(workspaceRoot: workspaceRoot)
        var lastId = anchor

        for iteration in 0..<10 {
            let diff = try await store.diff(workspaceRoot: workspaceRoot, since: lastId)
            lastId = diff.currentSnapshotId

            // After each prune, the dict must hold at most the
            // freshly-issued currentSnapshotId (+1 transient slack).
            let count = await store._snapshotCount(workspaceRoot: workspaceRoot)
            XCTAssertLessThanOrEqual(
                count, 2,
                "after iteration \(iteration), snapshot dict held \(count) entries; " +
                "well-behaved polling must keep this ≤ 2 (prune on diff)"
            )
        }

        // After 10 calls a final sanity check on the resting dict size.
        let finalCount = await store._snapshotCount(workspaceRoot: workspaceRoot)
        XCTAssertLessThanOrEqual(
            finalCount, 2,
            "resting snapshot dict size after 10 advancing diffs must be ≤ 2, got \(finalCount)"
        )
    }

    // ====================================================================
    // MARK: - Bug 2: hard cap at 64 even with a misbehaving client
    // ====================================================================

    /// A misbehaving client that always sends the same stale `since` (here
    /// the literal value 0, which is below the first issued SnapshotId)
    /// must not be able to grow the snapshot dict without bound. The
    /// implementation must clamp it at ≤ 64 entries.
    ///
    /// We use `try?` so the test remains valid regardless of whether the
    /// implementation chooses to treat an unknown `since` as a thrown
    /// `unknownSnapshot` or as a tolerated "from the beginning" sentinel
    /// — either way, the cap on the internal dict is the contract that
    /// must hold after 100 calls.
    func test_diff_isCappedAt64_whenSinceIsZero() async throws {
        let store = makeStore()

        for _ in 0..<100 {
            _ = try? await store.diff(workspaceRoot: workspaceRoot, since: 0)
        }

        let count = await store._snapshotCount(workspaceRoot: workspaceRoot)
        XCTAssertLessThanOrEqual(
            count, 64,
            "snapshot dict grew to \(count) entries after 100 diff(since:0) calls; " +
            "hard cap of 64 was not enforced"
        )
    }

    // ====================================================================
    // MARK: - Bug 3: currentSnapshotId monotonicity & uniqueness survive pruning
    // ====================================================================

    /// Pruning and capping the snapshot dict must not break the
    /// fundamental contract that every `diff()` call returns a strictly
    /// greater (and therefore unique) `currentSnapshotId` than any id
    /// previously issued by the store. If the implementation accidentally
    /// recycled ids while pruning, a polling client could see a `since`
    /// that is ≥ a newly-issued id and silently drop legitimate updates.
    func test_diff_returnsConsistentSnapshotId_afterPruning() async throws {
        let store = makeStore()

        // Establish a starting cursor.
        let anchor = await store.createSnapshot(workspaceRoot: workspaceRoot)
        var lastId = anchor
        var issued: [Int] = [anchor]

        // Drive a mix of "advancing client" diffs (which trigger prune)
        // followed by stale-cursor diffs (which trigger the cap path).
        for _ in 0..<20 {
            let diff = try await store.diff(workspaceRoot: workspaceRoot, since: lastId)
            issued.append(diff.currentSnapshotId)
            lastId = diff.currentSnapshotId
        }
        for _ in 0..<80 {
            // Stale `since` — the value `anchor` is now long-since pruned,
            // so this exercises the cap branch even if the impl ends up
            // throwing here. We capture any returned id that does succeed.
            if let diff = try? await store.diff(workspaceRoot: workspaceRoot, since: anchor) {
                issued.append(diff.currentSnapshotId)
            }
        }

        // Monotonicity: every issued id must be strictly greater than the
        // previous one. This collapses uniqueness into the same check
        // (strictly increasing ⇒ all distinct).
        XCTAssertGreaterThan(
            issued.count, 1,
            "expected to have collected multiple snapshot ids; got \(issued.count)"
        )
        for i in 1..<issued.count {
            XCTAssertGreaterThan(
                issued[i], issued[i - 1],
                "snapshot id at index \(i) (=\(issued[i])) was not strictly greater " +
                "than its predecessor (=\(issued[i - 1])); pruning/capping must not " +
                "break monotonicity"
            )
        }

        // Belt-and-braces uniqueness check.
        XCTAssertEqual(
            Set(issued).count, issued.count,
            "snapshot id collisions detected after pruning/capping"
        )
    }
}
