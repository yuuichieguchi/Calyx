//
//  SessionSnapshotV7Tests.swift
//  CalyxTests
//
//  Covers schema v7: TabSnapshot.missionMapCardOffsets, mirroring
//  SessionSnapshotV6Tests's own sessionRefs coverage one field/one
//  schema version up. Mission Map card drag offsets move from
//  MissionMapView's memory-only @State dragOffsets to Tab
//  .missionMapCardOffsets ([UUID: CGSize], leaf-surface-UUID keyed),
//  persisted through TabSnapshot exactly like sessionRefs/herdrPaneRefs.
//
//  Coverage:
//  - TabSnapshot(missionMapCardOffsets:) round-trips through
//    encode/decode
//  - A v6 JSON fixture (no missionMapCardOffsets key anywhere) decodes
//    with missionMapCardOffsets == nil while every other field survives
//    untouched, and Tab(snapshot:) restores an empty
//    missionMapCardOffsets dict from it
//  - A TabSnapshot produced from a Tab with an EMPTY
//    missionMapCardOffsets dict writes NO "missionMapCardOffsets" key at
//    all (nil-when-empty, matching sessionRefs/herdrPaneRefs)
//  - A Tab with two missionMapCardOffsets entries round-trips through
//    snapshot() -> encode -> decode -> Tab(snapshot:) identically
//  - SessionSnapshot.migrate(_:) carries a v6-decoded snapshot to v7
//    (schemaVersion bump only) without losing any window/tab data
//  - Restoring re-keys missionMapCardOffsets through the same
//    Dictionary.remappingKeys(_:) helper sessionRefs/herdrPaneRefs use
//    at the runtime Tab level (there is no TabSnapshot-level
//    equivalent -- see SessionSnapshotV6Tests's own header comment on
//    why `TabSnapshot.remappingSessionRefs(_:)` was removed as dead
//    code). NOTE: this file does not exercise the actual
//    AppDelegate.restoreTabSurfaces / CalyxWindowController
//    .performReconnect call sites that invoke
//    tab.missionMapCardOffsets.remappingKeys(_:) in production -- that
//    integration is out of this file's scope (see
//    AppDelegateRestoreHerdrPaneRefsWiringTests's header comment for
//    why that level of integration test is expensive to build
//    hermetically). This test instead pins the re-keying behavior
//    directly on a Tab's missionMapCardOffsets dictionary, the same
//    shape SessionRefHostRoundTripTests
//    .test_sessionRefsDictionary_remappingKeys_preservesHostAcrossReKey()
//    pins for sessionRefs.
//

import XCTest
@testable import Calyx

@MainActor
final class SessionSnapshotV7Tests: XCTestCase {

    // MARK: - Round trip

    func test_tabSnapshot_withMissionMapCardOffsets_roundTripsThroughEncodeDecode() throws {
        let leafID = UUID()
        let cardOffsets: [UUID: CGSize] = [leafID: CGSize(width: 22, height: -8)]
        let original = TabSnapshot(
            id: UUID(),
            title: "Terminal",
            pwd: "/Users/dev/repo",
            splitTree: SplitTree(leafID: leafID),
            missionMapCardOffsets: cardOffsets
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        XCTAssertEqual(decoded, original, "A TabSnapshot with missionMapCardOffsets must round-trip identically")
        XCTAssertEqual(decoded.missionMapCardOffsets, cardOffsets)
    }

    // MARK: - v6 backward compatibility

    private var v6JSONFixture: String {
        """
        {
            "schemaVersion": 6,
            "windows": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "frame": [[0, 0], [800, 600]],
                    "groups": [
                        {
                            "id": "00000000-0000-0000-0000-000000000010",
                            "name": "Default",
                            "color": "blue",
                            "tabs": [
                                {
                                    "id": "00000000-0000-0000-0000-000000000020",
                                    "title": "Terminal",
                                    "titleOverride": null,
                                    "pwd": "/Users/dev/repo",
                                    "splitTree": {
                                        "focusedLeafID": "00000000-0000-0000-0000-000000000030",
                                        "root": {"leaf": {"id": "00000000-0000-0000-0000-000000000030"}}
                                    },
                                    "browserURL": null
                                }
                            ],
                            "activeTabID": null,
                            "isCollapsed": false
                        }
                    ],
                    "activeGroupID": null,
                    "showSidebar": true,
                    "sidebarWidth": 260,
                    "isFullScreen": false
                }
            ]
        }
        """
    }

    func test_v6JSON_withoutMissionMapCardOffsetsKey_decodesAsNil_preservingOtherFields() throws {
        let data = Data(v6JSONFixture.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 6, "Raw decode must not itself migrate the schema version")

        let tab = try XCTUnwrap(decoded.windows.first?.groups.first?.tabs.first)
        XCTAssertNil(tab.missionMapCardOffsets,
                     "A v6 tab with no missionMapCardOffsets key must decode to nil, not throw or default to [:]")

        // Other fields on the same tab must have survived untouched.
        XCTAssertEqual(tab.id, UUID(uuidString: "00000000-0000-0000-0000-000000000020"))
        XCTAssertEqual(tab.title, "Terminal")
        XCTAssertEqual(tab.pwd, "/Users/dev/repo")
        XCTAssertEqual(tab.splitTree, SplitTree(leafID: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!))

        let restored = Tab(snapshot: tab)
        XCTAssertTrue(restored.missionMapCardOffsets.isEmpty,
                      "Tab(snapshot:) must restore an empty missionMapCardOffsets dict from a nil " +
                      "TabSnapshot.missionMapCardOffsets")
    }

    // MARK: - Nil-when-empty write

    func test_tabSnapshot_fromTabWithEmptyMissionMapCardOffsets_omitsKeyEntirely() throws {
        let tab = Tab(splitTree: SplitTree(leafID: UUID()))
        // tab.missionMapCardOffsets defaults to [:] -- never mutated
        // here, so this exercises the true default, not just an
        // explicitly-reset one.

        let snapshot = try XCTUnwrap(tab.snapshot(), "a .terminal Tab must produce a non-nil TabSnapshot")
        XCTAssertNil(snapshot.missionMapCardOffsets,
                     "Tab.snapshot() must nil-out an empty missionMapCardOffsets dict, mirroring " +
                     "sessionRefs/herdrPaneRefs's own isEmpty ? nil : self pattern")

        let data = try JSONEncoder().encode(snapshot)
        let rawObject = try JSONSerialization.jsonObject(with: data)
        let jsonObject = try XCTUnwrap(rawObject as? [String: Any], "encoded TabSnapshot must decode as a JSON object")

        XCTAssertFalse(jsonObject.keys.contains("missionMapCardOffsets"),
                       "A TabSnapshot encoded from a Tab with empty missionMapCardOffsets must write NO " +
                       "missionMapCardOffsets key at all, not an empty {} value")
    }

    // MARK: - Tab round trip (non-empty)

    func test_tab_withTwoMissionMapCardOffsets_roundTripsThroughSnapshotEncodeDecodeRestore() throws {
        let leafA = UUID()
        let (tree, leafB) = SplitTree(leafID: leafA).insert(at: leafA, direction: .horizontal)
        let offsetA = CGSize(width: 14, height: 3)
        let offsetB = CGSize(width: -19, height: 25)

        let tab = Tab(splitTree: tree)
        tab.setMissionMapCardOffset(offsetA, for: leafA)
        tab.setMissionMapCardOffset(offsetB, for: leafB)

        let snapshot = try XCTUnwrap(tab.snapshot())
        let data = try JSONEncoder().encode(snapshot)
        let decodedSnapshot = try JSONDecoder().decode(TabSnapshot.self, from: data)
        let restored = Tab(snapshot: decodedSnapshot)

        XCTAssertEqual(restored.missionMapCardOffsets, [leafA: offsetA, leafB: offsetB],
                       "A Tab's two missionMapCardOffsets (distinct leaf UUIDs, distinct offsets) must " +
                       "survive snapshot() -> encode -> decode -> Tab(snapshot:) identically")
    }

    // MARK: - migrate v6 -> v7

    func test_migrate_v6ToV7_bumpsSchemaVersionOnly_losesNoWindowOrTabData() throws {
        let data = Data(v6JSONFixture.utf8)
        let decodedV6 = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let migrated = SessionSnapshot.migrate(decodedV6)

        XCTAssertEqual(migrated.schemaVersion, SessionSnapshot.currentSchemaVersion)
        XCTAssertEqual(SessionSnapshot.currentSchemaVersion, 7, "Schema version must be 7 after the missionMapCardOffsets addition")
        XCTAssertEqual(migrated.windows, decodedV6.windows,
                       "migrate(_:) must carry every window/group/tab field through unchanged -- only the " +
                       "schemaVersion number itself changes")
    }

    // MARK: - Re-keying at restore (Dictionary.remappingKeys(_:))

    func test_missionMapCardOffsetsDictionary_remappingKeys_reKeysMappedLeaf_leavesUnmappedLeafAlone() {
        let oldLeafID = UUID()
        let unmappedLeafID = UUID()
        let newLeafID = UUID()
        let mappedOffset = CGSize(width: 30, height: -6)
        let unmappedOffset = CGSize(width: 1, height: 1)

        let original: [UUID: CGSize] = [oldLeafID: mappedOffset, unmappedLeafID: unmappedOffset]

        let remapped = original.remappingKeys([oldLeafID: newLeafID])

        XCTAssertEqual(remapped[newLeafID], mappedOffset,
                       "A key present in the mapping must move to its mapped value")
        XCTAssertNil(remapped[oldLeafID], "The old key must no longer be present once it has been re-keyed")
        XCTAssertEqual(remapped[unmappedLeafID], unmappedOffset,
                       "A key absent from the mapping must be left exactly as it was")
    }
}
