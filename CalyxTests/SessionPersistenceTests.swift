import XCTest
@testable import Calyx

final class SessionPersistenceTests: XCTestCase {

    // MARK: - Existing Tests (Phase 4/5)

    func test_encode_decode_roundtrip() throws {
        let tab1 = TabSnapshot(id: UUID(), title: "Tab 1", pwd: "/home", splitTree: SplitTree(leafID: UUID()))
        let tab2 = TabSnapshot(id: UUID(), title: "Tab 2", pwd: nil, splitTree: SplitTree())
        let group = TabGroupSnapshot(id: UUID(), name: "Default", tabs: [tab1, tab2], activeTabID: tab1.id)
        let window = WindowSnapshot(id: UUID(), frame: CGRect(x: 100, y: 100, width: 800, height: 600), groups: [group], activeGroupID: group.id)
        let snapshot = SessionSnapshot(windows: [window])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, SessionSnapshot.currentSchemaVersion)
        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.windows[0].groups.count, 1)
        XCTAssertEqual(decoded.windows[0].groups[0].tabs.count, 2)
        XCTAssertEqual(decoded.windows[0].groups[0].tabs[0].title, "Tab 1")
        XCTAssertEqual(decoded.windows[0].groups[0].tabs[0].pwd, "/home")
        XCTAssertEqual(decoded.windows[0].groups[0].tabs[1].pwd, nil)
    }

    func test_corrupt_json_fails_gracefully() {
        let corrupt = Data("not json".utf8)
        let result = try? JSONDecoder().decode(SessionSnapshot.self, from: corrupt)
        XCTAssertNil(result, "Corrupt JSON should fail to decode")
    }

    func test_schema_version_preserved() throws {
        let snapshot = SessionSnapshot(schemaVersion: 42, windows: [])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 42)
    }

    func test_empty_snapshot_roundtrip() throws {
        let snapshot = SessionSnapshot(windows: [])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(decoded.windows.count, 0)
    }

    func test_window_frame_clamped_to_screen() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: -100, y: -50, width: 800, height: 600),
            groups: [],
            activeGroupID: nil
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = window.clampedToScreen(screenFrame: screen)

        XCTAssertGreaterThanOrEqual(clamped.frame.origin.x, 0)
        XCTAssertGreaterThanOrEqual(clamped.frame.origin.y, 0)
    }

    func test_window_frame_min_size() {
        let window = WindowSnapshot(
            frame: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = window.clampedToScreen(screenFrame: screen)

        XCTAssertGreaterThanOrEqual(clamped.frame.width, 400)
        XCTAssertGreaterThanOrEqual(clamped.frame.height, 300)
    }

    func test_snapshot_equality() {
        let id = UUID()
        let a = SessionSnapshot(windows: [WindowSnapshot(id: id)])
        let b = SessionSnapshot(windows: [WindowSnapshot(id: id)])
        XCTAssertEqual(a, b)
    }

    // MARK: - Phase 6: Schema v3 — WindowSnapshot gains showSidebar

    /// WindowSnapshot should now have a showSidebar property.
    /// This test creates a WindowSnapshot with showSidebar=false and verifies the value is stored.
    func test_v3_windowSnapshot_includes_showSidebar() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            groups: [],
            activeGroupID: nil,
            showSidebar: false
        )

        XCTAssertFalse(window.showSidebar, "showSidebar should be false when explicitly set")
    }

    /// TabGroupSnapshot should now have an isCollapsed property.
    /// This test creates a TabGroupSnapshot with isCollapsed=true and verifies the value is stored.
    func test_v3_tabGroupSnapshot_includes_isCollapsed() {
        let group = TabGroupSnapshot(
            id: UUID(),
            name: "Test",
            color: "blue",
            tabs: [],
            activeTabID: nil,
            isCollapsed: true
        )

        XCTAssertTrue(group.isCollapsed, "isCollapsed should be true when explicitly set")
    }


    /// A full encode-decode roundtrip should preserve both showSidebar and isCollapsed.
    func test_v3_roundtrip_preserves_showSidebar_and_isCollapsed() throws {
        let tab = TabSnapshot(id: UUID(), title: "Tab", pwd: "/tmp", splitTree: SplitTree(leafID: UUID()))
        let group = TabGroupSnapshot(
            id: UUID(),
            name: "Collapsed Group",
            color: "red",
            tabs: [tab],
            activeTabID: tab.id,
            isCollapsed: true
        )
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 50, y: 50, width: 1200, height: 800),
            groups: [group],
            activeGroupID: group.id,
            showSidebar: false
        )
        let snapshot = SessionSnapshot(windows: [window])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.windows[0].showSidebar, false, "showSidebar should survive roundtrip")
        XCTAssertEqual(decoded.windows[0].groups[0].isCollapsed, true, "isCollapsed should survive roundtrip")
    }

    // MARK: - Phase 6: Backward Compatibility (v2 JSON without new fields)

    /// v2 JSON that lacks showSidebar should decode with default value of true.
    func test_v2_json_decodes_with_default_showSidebar_true() throws {
        // Simulate v2 JSON: no "showSidebar" key in the window object
        let v2JSON = """
        {
            "schemaVersion": 2,
            "windows": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "frame": [[0, 0], [800, 600]],
                    "groups": [],
                    "activeGroupID": null
                }
            ]
        }
        """
        let data = Data(v2JSON.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.windows[0].showSidebar, true, "Missing showSidebar should default to true for v2 compat")
    }

    /// v2 JSON that lacks isCollapsed should decode with default value of false.
    func test_v2_json_decodes_with_default_isCollapsed_false() throws {
        // Simulate v2 JSON: no "isCollapsed" key in the group object
        let v2JSON = """
        {
            "schemaVersion": 2,
            "windows": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "frame": [[0, 0], [800, 600]],
                    "groups": [
                        {
                            "id": "00000000-0000-0000-0000-000000000002",
                            "name": "Default",
                            "tabs": [],
                            "activeTabID": null
                        }
                    ],
                    "activeGroupID": null
                }
            ]
        }
        """
        let data = Data(v2JSON.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.windows[0].groups.count, 1)
        XCTAssertEqual(decoded.windows[0].groups[0].isCollapsed, false, "Missing isCollapsed should default to false for v2 compat")
    }

    // MARK: - Phase 6: Migration Pipeline

    /// SessionSnapshot.migrate should update schemaVersion to currentSchemaVersion.
    func test_migrate_updates_schema_version() {
        let oldSnapshot = SessionSnapshot(schemaVersion: 1, windows: [])
        let migrated = SessionSnapshot.migrate(oldSnapshot)

        XCTAssertEqual(migrated.schemaVersion, SessionSnapshot.currentSchemaVersion,
                       "Migration should update schema version to current")
    }

    // MARK: - Phase 6: Reverse Conversions

    /// TabGroup(snapshot:) should create a TabGroup from a TabGroupSnapshot,
    /// preserving id, name, color, isCollapsed, tabs, and activeTabID.
    @MainActor
    func test_tabGroup_from_snapshot() {
        let tabID = UUID()
        let tabSnap = TabSnapshot(id: tabID, title: "Shell", pwd: "/home/user", splitTree: SplitTree(leafID: UUID()))
        let groupID = UUID()
        let groupSnap = TabGroupSnapshot(
            id: groupID,
            name: "Work",
            color: "green",
            tabs: [tabSnap],
            activeTabID: tabID,
            isCollapsed: true
        )

        let group = TabGroup(snapshot: groupSnap)

        XCTAssertEqual(group.id, groupID, "Group ID should match snapshot")
        XCTAssertEqual(group.name, "Work", "Group name should match snapshot")
        XCTAssertEqual(group.color, .green, "Group color should match snapshot")
        XCTAssertEqual(group.isCollapsed, true, "Group isCollapsed should match snapshot")
        XCTAssertEqual(group.tabs.count, 1, "Group should have 1 tab")
        XCTAssertEqual(group.tabs[0].id, tabID, "Tab ID should match snapshot")
        XCTAssertEqual(group.tabs[0].title, "Shell", "Tab title should match snapshot")
        XCTAssertEqual(group.activeTabID, tabID, "Active tab ID should match snapshot")
    }

    /// WindowSession(snapshot:) should create a WindowSession from a WindowSnapshot,
    /// preserving id, groups, activeGroupID, and showSidebar.
    @MainActor
    func test_windowSession_from_snapshot() {
        let tabSnap = TabSnapshot(id: UUID(), title: "Tab", pwd: "/tmp", splitTree: SplitTree())
        let groupID = UUID()
        let groupSnap = TabGroupSnapshot(
            id: groupID,
            name: "Dev",
            color: "purple",
            tabs: [tabSnap],
            activeTabID: tabSnap.id,
            isCollapsed: false
        )
        let windowID = UUID()
        let windowSnap = WindowSnapshot(
            id: windowID,
            frame: CGRect(x: 100, y: 200, width: 1024, height: 768),
            groups: [groupSnap],
            activeGroupID: groupID,
            showSidebar: false
        )

        let session = WindowSession(snapshot: windowSnap)

        XCTAssertEqual(session.id, windowID, "Window ID should match snapshot")
        XCTAssertEqual(session.groups.count, 1, "Window should have 1 group")
        XCTAssertEqual(session.groups[0].id, groupID, "Group ID should match snapshot")
        XCTAssertEqual(session.activeGroupID, groupID, "Active group ID should match snapshot")
        XCTAssertEqual(session.showSidebar, false, "showSidebar should match snapshot")
    }

    // MARK: - Phase 6: Forward Conversions Updated

    /// TabGroup.snapshot() should include isCollapsed in the resulting TabGroupSnapshot.
    @MainActor
    func test_tabGroup_snapshot_includes_isCollapsed() {
        let group = TabGroup(name: "Collapsed", color: .red, isCollapsed: true)
        let snap = group.snapshot()

        XCTAssertEqual(snap.isCollapsed, true, "Snapshot should capture isCollapsed=true")

        let group2 = TabGroup(name: "Open", color: .blue, isCollapsed: false)
        let snap2 = group2.snapshot()

        XCTAssertEqual(snap2.isCollapsed, false, "Snapshot should capture isCollapsed=false")
    }

    /// WindowSession.snapshot() should include showSidebar in the resulting WindowSnapshot.
    @MainActor
    func test_windowSnapshot_includes_showSidebar() {
        let session = WindowSession(showSidebar: false)
        let snap = session.snapshot()

        XCTAssertEqual(snap.showSidebar, false, "Snapshot should capture showSidebar=false")

        let session2 = WindowSession(showSidebar: true)
        let snap2 = session2.snapshot()

        XCTAssertEqual(snap2.showSidebar, true, "Snapshot should capture showSidebar=true")
    }

    // MARK: - Phase 6: SplitTree.remapLeafIDs

    /// remapLeafIDs should replace a single leaf's UUID when it appears in the mapping.
    func test_remapLeafIDs_single_leaf() {
        let oldID = UUID()
        let newID = UUID()
        let tree = SplitTree(leafID: oldID)

        let remapped = tree.remapLeafIDs([oldID: newID])

        let leaves = remapped.allLeafIDs()
        XCTAssertEqual(leaves, [newID], "Single leaf should be remapped to new ID")
    }

    /// remapLeafIDs should replace leaf UUIDs in nested splits while preserving tree structure.
    func test_remapLeafIDs_nested_splits() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let newID1 = UUID()
        let newID2 = UUID()
        let newID3 = UUID()

        // Build a tree: split(split(id1, id2), id3)
        let innerSplit = SplitData(direction: .horizontal, ratio: 0.5, first: .leaf(id: id1), second: .leaf(id: id2))
        let outerSplit = SplitData(direction: .vertical, ratio: 0.6, first: .split(innerSplit), second: .leaf(id: id3))
        let tree = SplitTree(root: .split(outerSplit), focusedLeafID: id1)

        let remapped = tree.remapLeafIDs([id1: newID1, id2: newID2, id3: newID3])

        let leaves = remapped.allLeafIDs()
        XCTAssertEqual(leaves.count, 3, "Remapped tree should still have 3 leaves")
        XCTAssertTrue(leaves.contains(newID1), "id1 should be remapped to newID1")
        XCTAssertTrue(leaves.contains(newID2), "id2 should be remapped to newID2")
        XCTAssertTrue(leaves.contains(newID3), "id3 should be remapped to newID3")
        XCTAssertFalse(leaves.contains(id1), "Old id1 should not remain")
        XCTAssertFalse(leaves.contains(id2), "Old id2 should not remain")
        XCTAssertFalse(leaves.contains(id3), "Old id3 should not remain")

        // Verify structure is preserved: root is a vertical split at ratio 0.6
        if case .split(let data) = remapped.root {
            XCTAssertEqual(data.direction, .vertical, "Outer split direction should be preserved")
            XCTAssertEqual(data.ratio, 0.6, accuracy: 0.001, "Outer split ratio should be preserved")

            if case .split(let inner) = data.first {
                XCTAssertEqual(inner.direction, .horizontal, "Inner split direction should be preserved")
                XCTAssertEqual(inner.ratio, 0.5, accuracy: 0.001, "Inner split ratio should be preserved")
            } else {
                XCTFail("First child of outer split should still be a split node")
            }
        } else {
            XCTFail("Root should still be a split node")
        }
    }

    /// remapLeafIDs should update focusedLeafID when it appears in the mapping.
    func test_remapLeafIDs_updates_focusedLeafID() {
        let oldFocused = UUID()
        let newFocused = UUID()
        let otherID = UUID()

        let split = SplitData(direction: .horizontal, ratio: 0.5, first: .leaf(id: oldFocused), second: .leaf(id: otherID))
        let tree = SplitTree(root: .split(split), focusedLeafID: oldFocused)

        let remapped = tree.remapLeafIDs([oldFocused: newFocused])

        XCTAssertEqual(remapped.focusedLeafID, newFocused, "focusedLeafID should be updated when it is in the mapping")
    }

    /// remapLeafIDs on an empty tree should return an empty tree.
    func test_remapLeafIDs_empty_tree() {
        let tree = SplitTree()

        let remapped = tree.remapLeafIDs([UUID(): UUID()])

        XCTAssertTrue(remapped.isEmpty, "Empty tree should remain empty after remapping")
        XCTAssertNil(remapped.focusedLeafID, "Empty tree should have nil focusedLeafID")
    }

    /// Leaf IDs not present in the mapping should remain unchanged.
    func test_remapLeafIDs_unmapped_ids_unchanged() {
        let keepID = UUID()
        let changeID = UUID()
        let newID = UUID()

        let split = SplitData(direction: .vertical, ratio: 0.5, first: .leaf(id: keepID), second: .leaf(id: changeID))
        let tree = SplitTree(root: .split(split), focusedLeafID: keepID)

        let remapped = tree.remapLeafIDs([changeID: newID])

        let leaves = remapped.allLeafIDs()
        XCTAssertTrue(leaves.contains(keepID), "Unmapped leaf ID should be unchanged")
        XCTAssertTrue(leaves.contains(newID), "Mapped leaf ID should be remapped")
        XCTAssertFalse(leaves.contains(changeID), "Old mapped leaf ID should not remain")
        XCTAssertEqual(remapped.focusedLeafID, keepID, "focusedLeafID should stay unchanged when not in mapping")
    }

    // MARK: - Phase 6: clampedToScreen Improvement

    /// When a window frame is completely off-screen (no intersection with screen),
    /// clampedToScreen should center the window on the screen.
    func test_clampedToScreen_centers_when_fully_offscreen() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 5000, y: 5000, width: 800, height: 600),
            groups: [],
            activeGroupID: nil
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = window.clampedToScreen(screenFrame: screen)

        // When fully off-screen, the window should be centered on the screen
        let expectedX = (1920 - 800) / 2.0
        let expectedY = (1080 - 600) / 2.0

        XCTAssertEqual(clamped.frame.origin.x, expectedX, accuracy: 1.0,
                       "Fully off-screen window should be centered horizontally")
        XCTAssertEqual(clamped.frame.origin.y, expectedY, accuracy: 1.0,
                       "Fully off-screen window should be centered vertically")
        XCTAssertEqual(clamped.frame.size.width, 800, "Width should be preserved")
        XCTAssertEqual(clamped.frame.size.height, 600, "Height should be preserved")
    }

    /// A partially off-screen window should still be clamped (not centered),
    /// just brought back into view at the nearest edge.
    func test_clampedToScreen_still_clamps_partially_offscreen() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: -100, y: -50, width: 800, height: 600),
            groups: [],
            activeGroupID: nil
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let clamped = window.clampedToScreen(screenFrame: screen)

        // Partially off-screen should clamp to edges, not center
        XCTAssertGreaterThanOrEqual(clamped.frame.origin.x, 0,
                                    "Partially off-screen should clamp x to screen edge")
        XCTAssertGreaterThanOrEqual(clamped.frame.origin.y, 0,
                                    "Partially off-screen should clamp y to screen edge")
        // Should NOT be centered — it should be at the edge
        let centeredX = (1920 - 800) / 2.0
        XCTAssertNotEqual(clamped.frame.origin.x, centeredX,
                          "Partially off-screen should not be centered, just clamped")
    }

    // MARK: - Phase 6: SessionPersistenceActor Path

    /// The save path should be ~/.calyx/sessions.json (not Application Support).
    /// Will fail: sessionSavePath() does not exist yet on SessionPersistenceActor.
    func test_persistence_actor_save_path() async {
        let actor = SessionPersistenceActor()
        let savePath = await actor.sessionSavePath()

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let expectedPath = homeDir.appendingPathComponent(".calyx/sessions.json").path

        XCTAssertEqual(savePath.path, expectedPath,
                       "Save path should be ~/.calyx/sessions.json")
    }

    /// The actor should expose a method to migrate from the legacy Application Support path.
    /// Will fail: migrateFromLegacyPath() does not exist yet on SessionPersistenceActor.
    func test_persistence_actor_migrate_from_legacy_path() async {
        let actor = SessionPersistenceActor()
        // This method should exist; we just verify it doesn't crash and returns a boolean
        let didMigrate = await actor.migrateFromLegacyPath()

        // Without a legacy file present, migration should return false
        XCTAssertFalse(didMigrate, "Migration should return false when no legacy file exists")
    }

    // MARK: - Schema v4 — WindowSnapshot gains sidebarWidth

    /// A full encode-decode roundtrip should preserve sidebarWidth.
    func test_v4_windowSnapshot_roundtrip_preserves_sidebarWidth() throws {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            groups: [],
            activeGroupID: nil,
            showSidebar: true,
            sidebarWidth: 300
        )

        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(WindowSnapshot.self, from: data)

        XCTAssertEqual(decoded.sidebarWidth, 300, accuracy: 0.001,
                       "sidebarWidth should survive encode-decode roundtrip")
    }

    /// v3 JSON without "sidebarWidth" key should decode with default value of 220.
    func test_v3_json_decodes_with_default_sidebarWidth_220() throws {
        let v3JSON = """
        {
            "schemaVersion": 3,
            "windows": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "frame": [[0, 0], [800, 600]],
                    "groups": [],
                    "activeGroupID": null,
                    "showSidebar": true
                }
            ]
        }
        """
        let data = Data(v3JSON.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertEqual(decoded.windows[0].sidebarWidth, 220, accuracy: 0.001,
                       "Missing sidebarWidth should default to 220 for v3 backward compat")
    }

    /// sidebarWidth values outside valid range [200, 500] should be clamped on decode.
    func test_sidebarWidth_clamped_on_decode() throws {
        // Helper to build a single-window JSON with a given sidebarWidth
        func windowJSON(sidebarWidth: Int) -> String {
            return """
            {
                "schemaVersion": 4,
                "windows": [
                    {
                        "id": "00000000-0000-0000-0000-000000000001",
                        "frame": [[0, 0], [800, 600]],
                        "groups": [],
                        "activeGroupID": null,
                        "showSidebar": true,
                        "sidebarWidth": \(sidebarWidth)
                    }
                ]
            }
            """
        }

        // 0 should be clamped to minSidebarWidth (200)
        let zeroData = Data(windowJSON(sidebarWidth: 0).utf8)
        let zeroDecoded = try JSONDecoder().decode(SessionSnapshot.self, from: zeroData)
        XCTAssertEqual(zeroDecoded.windows[0].sidebarWidth, 200, accuracy: 0.001,
                       "sidebarWidth of 0 should be clamped to 200")

        // 9999 should be clamped to maxSidebarWidth (500)
        let bigData = Data(windowJSON(sidebarWidth: 9999).utf8)
        let bigDecoded = try JSONDecoder().decode(SessionSnapshot.self, from: bigData)
        XCTAssertEqual(bigDecoded.windows[0].sidebarWidth, 500, accuracy: 0.001,
                       "sidebarWidth of 9999 should be clamped to 500")

        // -100 should be clamped to minSidebarWidth (200)
        let negData = Data(windowJSON(sidebarWidth: -100).utf8)
        let negDecoded = try JSONDecoder().decode(SessionSnapshot.self, from: negData)
        XCTAssertEqual(negDecoded.windows[0].sidebarWidth, 200, accuracy: 0.001,
                       "sidebarWidth of -100 should be clamped to 200")
    }

    /// WindowSession with sidebarWidth=350 should produce a snapshot with sidebarWidth=350.
    @MainActor
    func test_windowSession_snapshot_includes_sidebarWidth() {
        let session = WindowSession(showSidebar: true)
        session.sidebarWidth = 350

        let snap = session.snapshot()

        XCTAssertEqual(snap.sidebarWidth, 350, accuracy: 0.001,
                       "Snapshot should capture sidebarWidth from WindowSession")
    }

    /// Legacy sessions saved with minSidebarWidth=150 should be clamped up to 200.
    func test_sidebarWidth_legacy150_clamped_to_200() throws {
        let json = """
        {
            "schemaVersion": 4,
            "windows": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "frame": [[0, 0], [800, 600]],
                    "groups": [],
                    "activeGroupID": null,
                    "showSidebar": true,
                    "sidebarWidth": 150
                }
            ]
        }
        """
        let data = Data(json.utf8)
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        XCTAssertEqual(snapshot.windows[0].sidebarWidth, 200, accuracy: 0.001,
                       "Legacy sidebarWidth of 150 should be clamped to new minimum of 200")
    }

    // MARK: - Tab titleOverride Persistence

    /// TabSnapshot with titleOverride should survive encode-decode roundtrip.
    func test_tabSnapshot_roundtrip_preserves_titleOverride() throws {
        let original = TabSnapshot(
            id: UUID(),
            title: "Terminal",
            titleOverride: "Custom Name",
            pwd: "/tmp",
            splitTree: SplitTree()
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: data)

        XCTAssertEqual(decoded.titleOverride, "Custom Name",
                       "titleOverride should survive encode-decode roundtrip")
    }

    /// Old v4 JSON without titleOverride key should decode with nil titleOverride.
    func test_v4_json_without_titleOverride_decodes_as_nil() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","title":"Tab","pwd":"/tmp","splitTree":{"leafID":"00000000-0000-0000-0000-000000000002"}}
        """
        let decoded = try JSONDecoder().decode(TabSnapshot.self, from: json.data(using: .utf8)!)

        XCTAssertNil(decoded.titleOverride,
                     "Old JSON without titleOverride should decode as nil for backward compatibility")
    }

    /// Tab.snapshot() should include titleOverride in the resulting TabSnapshot.
    @MainActor
    func test_tab_snapshot_includes_titleOverride() {
        let tab = Tab(title: "Terminal")
        tab.titleOverride = "Server 1"

        let snapshot = tab.snapshot()!

        XCTAssertEqual(snapshot.titleOverride, "Server 1",
                       "Tab.snapshot() should capture titleOverride")
    }

    /// Tab(snapshot:) should restore titleOverride from a TabSnapshot.
    @MainActor
    func test_tab_from_snapshot_restores_titleOverride() {
        let snapshot = TabSnapshot(
            id: UUID(),
            title: "Terminal",
            titleOverride: "My Tab",
            pwd: nil,
            splitTree: SplitTree()
        )

        let tab = Tab(snapshot: snapshot)

        XCTAssertEqual(tab.titleOverride, "My Tab",
                       "Tab(snapshot:) should restore titleOverride from the snapshot")
    }

    // MARK: - Schema v5 — WindowSnapshot gains isFullScreen

    /// currentSchemaVersion should be 5 for the v5 schema that introduces isFullScreen.
    func test_v5_schema_version_is_5() {
        XCTAssertEqual(SessionSnapshot.currentSchemaVersion, 5,
                       "Schema version should be 5 after isFullScreen addition")
    }

    /// WindowSnapshot should expose an isFullScreen property that stores the
    /// value passed to the initializer.
    func test_v5_windowSnapshot_includes_isFullScreen() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            groups: [],
            activeGroupID: nil,
            showSidebar: true,
            sidebarWidth: SidebarLayout.defaultWidth,
            isFullScreen: true
        )

        XCTAssertTrue(window.isFullScreen,
                      "isFullScreen should be true when explicitly set to true")
    }

    /// A full encode-decode roundtrip should preserve isFullScreen = true.
    func test_v5_windowSnapshot_roundtrip_preserves_isFullScreen() throws {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            groups: [],
            activeGroupID: nil,
            showSidebar: true,
            sidebarWidth: 280,
            isFullScreen: true
        )

        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(WindowSnapshot.self, from: data)

        XCTAssertTrue(decoded.isFullScreen,
                      "isFullScreen = true should survive encode-decode roundtrip")
    }

    /// A full encode-decode roundtrip should preserve isFullScreen = false.
    func test_v5_windowSnapshot_roundtrip_preserves_isFullScreen_false() throws {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            groups: [],
            activeGroupID: nil,
            showSidebar: true,
            sidebarWidth: 280,
            isFullScreen: false
        )

        let data = try JSONEncoder().encode(window)
        let decoded = try JSONDecoder().decode(WindowSnapshot.self, from: data)

        XCTAssertFalse(decoded.isFullScreen,
                       "isFullScreen = false should survive encode-decode roundtrip")
    }

    /// v4 JSON that lacks isFullScreen should decode with default value of false.
    func test_v4_json_decodes_with_default_isFullScreen_false() throws {
        // Simulate v4 JSON: no "isFullScreen" key in the window object
        let v4JSON = """
        {
            "schemaVersion": 4,
            "windows": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "frame": [[0, 0], [800, 600]],
                    "groups": [],
                    "activeGroupID": null,
                    "showSidebar": true,
                    "sidebarWidth": 220
                }
            ]
        }
        """
        let data = Data(v4JSON.utf8)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.windows.count, 1)
        XCTAssertFalse(decoded.windows[0].isFullScreen,
                       "Missing isFullScreen should default to false for v4 backward compat")
    }

    /// When the frame partially intersects the screen, clampedToScreen must
    /// preserve isFullScreen through the clamping branch.
    func test_clampedToScreen_preserves_isFullScreen_on_intersect_branch() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: -50, y: -50, width: 800, height: 600),
            groups: [],
            activeGroupID: nil,
            showSidebar: true,
            sidebarWidth: SidebarLayout.defaultWidth,
            isFullScreen: true
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let clamped = window.clampedToScreen(screenFrame: screen)

        XCTAssertTrue(clamped.isFullScreen,
                      "clampedToScreen must preserve isFullScreen on the intersect branch")
    }

    /// When the frame does not intersect the screen at all, clampedToScreen
    /// must still preserve isFullScreen through the center-on-screen branch.
    func test_clampedToScreen_preserves_isFullScreen_on_no_intersect_branch() {
        let window = WindowSnapshot(
            id: UUID(),
            frame: CGRect(x: 5000, y: 5000, width: 800, height: 600),
            groups: [],
            activeGroupID: nil,
            showSidebar: true,
            sidebarWidth: SidebarLayout.defaultWidth,
            isFullScreen: true
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let clamped = window.clampedToScreen(screenFrame: screen)

        XCTAssertTrue(clamped.isFullScreen,
                      "clampedToScreen must preserve isFullScreen on the no-intersect (center) branch")
    }
}
