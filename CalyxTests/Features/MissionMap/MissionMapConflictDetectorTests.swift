//
//  MissionMapConflictDetectorTests.swift
//  CalyxTests
//
//  Pins MissionMapConflictDetector.conflicts(in:now:window:), the pure
//  function that turns a flat list of AgentEditedFile records into the
//  deduplicated cross-surface file-conflict pairs Mission Map draws as
//  red edges.
//
//  Coverage:
//  - Two different surfaces editing the same file within the window -> 1
//    conflict
//  - The same edit outside the window -> 0 conflicts
//  - The same surface editing the same file twice -> 0 conflicts (no
//    self-conflict)
//  - Three surfaces sharing one file -> 3 conflicts (every pair once)
//  - Path normalization: a relative and an absolute record of the same
//    file are treated as the same file
//  - surfaceA < surfaceB by uuidString, for deterministic pair ordering
//

import XCTest
@testable import Calyx

final class MissionMapConflictDetectorTests: XCTestCase {

    private func record(
        surfaceID: UUID, path: String, toolName: String = "Write", at: Date
    ) -> AgentEditedFile {
        AgentEditedFile(surfaceID: surfaceID, path: path, toolName: toolName, at: at)
    }

    func test_recentWindow_is300Seconds() {
        XCTAssertEqual(MissionMapConflictDetector.recentWindow, 300)
    }

    func test_twoSurfaces_sameFile_withinWindow_producesOneConflict() {
        let now = Date()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let records = [
            record(surfaceID: surfaceA, path: "/repo/main.swift", at: now.addingTimeInterval(-10)),
            record(surfaceID: surfaceB, path: "/repo/main.swift", at: now.addingTimeInterval(-5)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.file, "/repo/main.swift")
    }

    func test_twoSurfaces_sameFile_outsideWindow_producesNoConflict() {
        let now = Date()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let records = [
            record(surfaceID: surfaceA, path: "/repo/main.swift", at: now.addingTimeInterval(-600)),
            record(surfaceID: surfaceB, path: "/repo/main.swift", at: now.addingTimeInterval(-5)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertTrue(conflicts.isEmpty)
    }

    func test_sameSurface_sameFile_producesNoSelfConflict() {
        let now = Date()
        let surfaceA = UUID()
        let records = [
            record(surfaceID: surfaceA, path: "/repo/main.swift", at: now.addingTimeInterval(-10)),
            record(surfaceID: surfaceA, path: "/repo/main.swift", at: now.addingTimeInterval(-5)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertTrue(conflicts.isEmpty)
    }

    func test_threeSurfaces_sameFile_producesThreeConflicts_onePerPair() {
        let now = Date()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let surfaceC = UUID()
        let records = [
            record(surfaceID: surfaceA, path: "/repo/main.swift", at: now.addingTimeInterval(-30)),
            record(surfaceID: surfaceB, path: "/repo/main.swift", at: now.addingTimeInterval(-20)),
            record(surfaceID: surfaceC, path: "/repo/main.swift", at: now.addingTimeInterval(-10)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertEqual(conflicts.count, 3)
        let pairs = Set(conflicts.map { Set([$0.surfaceA, $0.surfaceB]) })
        XCTAssertEqual(pairs, Set([
            Set([surfaceA, surfaceB]),
            Set([surfaceA, surfaceC]),
            Set([surfaceB, surfaceC]),
        ]))
    }

    /// Repeated edits to the same file by the same pair must still
    /// collapse to exactly one conflict line -- (min, max, path)
    /// dedup, not one line per record.
    func test_twoSurfaces_multipleEditsSameFile_stillProducesOneConflict() {
        let now = Date()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let records = [
            record(surfaceID: surfaceA, path: "/repo/main.swift", at: now.addingTimeInterval(-30)),
            record(surfaceID: surfaceB, path: "/repo/main.swift", at: now.addingTimeInterval(-20)),
            record(surfaceID: surfaceA, path: "/repo/main.swift", at: now.addingTimeInterval(-10)),
            record(surfaceID: surfaceB, path: "/repo/main.swift", at: now.addingTimeInterval(-5)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertEqual(conflicts.count, 1)
    }

    /// surfaceA/surfaceB in the result are ordered deterministically by
    /// uuidString (min, max) regardless of which surface recorded first.
    func test_conflictSurfaceOrdering_isDeterministicByUUIDString() {
        let now = Date()
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        // `higher` records first, so a naive "first seen = A" implementation
        // would get this backwards.
        let records = [
            record(surfaceID: higher, path: "/repo/main.swift", at: now.addingTimeInterval(-10)),
            record(surfaceID: lower, path: "/repo/main.swift", at: now.addingTimeInterval(-5)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.surfaceA, lower)
        XCTAssertEqual(conflicts.first?.surfaceB, higher)
    }

    /// Two records naming the same file through different (but
    /// standardizable) path spellings must still be treated as the same
    /// file -- `(NSString).standardizingPath` collapses "/repo/./a.swift"
    /// and "/repo/sub/../a.swift" to the same normalized form as
    /// "/repo/a.swift".
    func test_pathsThatNormalizeToTheSameFile_stillConflict() {
        let now = Date()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let records = [
            record(surfaceID: surfaceA, path: "/repo/./a.swift", at: now.addingTimeInterval(-10)),
            record(surfaceID: surfaceB, path: "/repo/sub/../a.swift", at: now.addingTimeInterval(-5)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertEqual(conflicts.count, 1,
                       "Both records name /repo/a.swift once their paths are standardized")
    }

    /// Different files edited by different surfaces must not conflict.
    func test_differentFiles_producesNoConflict() {
        let now = Date()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let records = [
            record(surfaceID: surfaceA, path: "/repo/a.swift", at: now.addingTimeInterval(-10)),
            record(surfaceID: surfaceB, path: "/repo/b.swift", at: now.addingTimeInterval(-5)),
        ]

        let conflicts = MissionMapConflictDetector.conflicts(in: records, now: now, window: 300)

        XCTAssertTrue(conflicts.isEmpty)
    }
}
