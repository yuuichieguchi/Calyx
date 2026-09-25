//
//  SessionSnapshotV6Tests.swift
//  CalyxTests
//
//  Covers schema v6: TabSnapshot.sessionRefs.
//
//  Coverage:
//  - A TabSnapshot with sessionRefs round-trips through encode/decode
//  - A v5 JSON fixture (no sessionRefs key anywhere) decodes with
//    sessionRefs == nil while every other field survives untouched
//  - SessionSnapshot.migrate(_:) carries a v5-decoded snapshot to v6
//    (schemaVersion bump only) without losing any window/tab data
//
//  TabSnapshot.remappingSessionRefs(_:) and its two tests here were
//  removed: it was a dead, never-called wrapper — restore
//  and reconnect both re-key the runtime Tab.sessionRefs dictionary
//  directly via Dictionary.remappingKeys(_:) (SessionSnapshot.swift),
//  never by reconstructing a whole TabSnapshot mid-flight.
//

import XCTest
@testable import Calyx

final class SessionSnapshotV6Tests: XCTestCase {

    // MARK: - Round trip

    func test_tabSnapshot_withSessionRefs_roundTripsThroughEncodeDecode() throws {
        let leafID = UUID()
        let sessionRefs: [UUID: SessionRef] = [
            leafID: SessionRef(sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", host: nil, agentSessions: ["claude-code": "abc-123"]),
        ]
        let original = TabSnapshot(
            id: UUID(),
            title: "Terminal",
            pwd: "/Users/dev/repo",
            splitTree: SplitTree(leafID: leafID),
            sessionRefs: sessionRefs
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        XCTAssertEqual(decoded, original, "A TabSnapshot with sessionRefs must round-trip identically")
        XCTAssertEqual(decoded.sessionRefs, sessionRefs)
    }

    // MARK: - v5 backward compatibility

    private var v5JSONFixture: String {
        """
        {
            "schemaVersion": 5,
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

    func test_v5JSON_withoutSessionRefsKey_decodesSessionRefsAsNil_preservingOtherFields() throws {
        let data = Data(v5JSONFixture.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 5, "Raw decode must not itself migrate the schema version")

        let tab = try XCTUnwrap(decoded.windows.first?.groups.first?.tabs.first)
        XCTAssertNil(tab.sessionRefs, "A v5 tab with no sessionRefs key must decode to nil, not throw or default to [:]")

        // Other fields on the same tab must have survived untouched.
        XCTAssertEqual(tab.id, UUID(uuidString: "00000000-0000-0000-0000-000000000020"))
        XCTAssertEqual(tab.title, "Terminal")
        XCTAssertEqual(tab.pwd, "/Users/dev/repo")
        XCTAssertEqual(tab.splitTree, SplitTree(leafID: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!))
    }

    // MARK: - migrate v5 -> v6

    func test_migrate_v5ToV6_bumpsSchemaVersionOnly_losesNoWindowOrTabData() throws {
        let data = Data(v5JSONFixture.utf8)
        let decodedV5 = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let migrated = SessionSnapshot.migrate(decodedV5)

        XCTAssertEqual(migrated.schemaVersion, SessionSnapshot.currentSchemaVersion)
        // Schema version 7 as of the missionMapCardOffsets addition
        // (SessionSnapshotV7Tests.swift) -- was 6 when this test was
        // originally written for the sessionRefs addition alone.
        XCTAssertEqual(SessionSnapshot.currentSchemaVersion, 7, "Schema version must be 7 after the missionMapCardOffsets addition")
        XCTAssertEqual(migrated.windows, decodedV5.windows,
                       "migrate(_:) must carry every window/group/tab field through unchanged — only the " +
                       "schemaVersion number itself changes")
    }

    // MARK: - Zoom backward compatibility (GHOSTTY_ACTION_TOGGLE_SPLIT_ZOOM)
    //
    // `SplitTree.zoomedLeafID` (new field; see SplitTreeTests.swift's own
    // "Split Zoom" section for the field-level Codable coverage) must not
    // break decoding of a v6 snapshot written before the zoom feature
    // existed — every real v6 file on disk today has no "zoomedLeafID"
    // key anywhere. Placed here rather than SplitTreeTests.swift because
    // this specifically exercises the field nested inside a full
    // SessionSnapshot, mirroring this file's own v5JSONFixture /
    // test_v5JSON_withoutSessionRefsKey_... shape one schema version up.
    // Mechanical, like this file's own v5 sessionRefs-backward-compat
    // test above: passes today because `zoomedLeafID` is a plain
    // Optional stored property with fully synthesized Codable — there is
    // no "logic" for a stub to fake.

    private var v6JSONFixtureWithoutZoomedLeafID: String {
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
                            "activeTabID": "00000000-0000-0000-0000-000000000020",
                            "isCollapsed": false
                        }
                    ],
                    "activeGroupID": "00000000-0000-0000-0000-000000000010",
                    "showSidebar": true,
                    "sidebarWidth": 260,
                    "isFullScreen": false
                }
            ]
        }
        """
    }

    func test_v6JSON_withoutZoomedLeafIDKey_decodesWithoutThrowing_zoomedLeafIDIsNil() throws {
        let data = Data(v6JSONFixtureWithoutZoomedLeafID.utf8)

        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 6)
        let tab = try XCTUnwrap(decoded.windows.first?.groups.first?.tabs.first)
        XCTAssertEqual(tab.splitTree.allLeafIDs(), [UUID(uuidString: "00000000-0000-0000-0000-000000000030")!],
                       "Precondition: the pre-zoom tab's own splitTree leaf must still decode correctly")
        XCTAssertNil(tab.splitTree.zoomedLeafID,
                    "A v6 snapshot with no zoomedLeafID key anywhere must decode with zoomedLeafID == nil, not throw")
    }
}
