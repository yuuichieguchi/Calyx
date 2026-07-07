// TabReorderUITests.swift
// CalyxUITests
//
// UI tests for tab drag-reorder in both the tab bar and sidebar.

import XCTest

final class TabReorderUITests: CalyxUITestCase {

    // MARK: - Helpers

    // Position-ordered tab lookup.
    //
    // The tab rows expose their `calyx.*.tab.<UUID>` identifier (via
    // `.accessibilityElement(children: .contain)`) but NOT their
    // `.accessibilityValue` index: XCUITest surfaces a container element's
    // identifier and label, but not its `AXValue`, so the previous
    // value-based index lookup returned nothing. Instead, resolve a tab's
    // ordinal position from the on-screen geometry of the identifier-bearing
    // elements: left-to-right (minX) for the horizontal tab bar,
    // top-to-bottom (minY) for the vertical sidebar list.
    private static let uuidPattern =
        "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"

    /// Tab-bar tab elements (identifier `calyx.tabBar.tab.<UUID>`, no
    /// `.closeButton` suffix) sorted left-to-right by frame.
    private func tabBarTabsByPosition() -> [XCUIElement] {
        let predicate = NSPredicate(format: "identifier MATCHES %@",
                                    "calyx\\.tabBar\\.tab\\.\(Self.uuidPattern)")
        let query = app.descendants(matching: .any).matching(predicate)
        return (0..<query.count)
            .map { query.element(boundBy: $0) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Sidebar tab elements (identifier `calyx.sidebar.tab.<UUID>`) sorted
    /// top-to-bottom by frame.
    private func sidebarTabsByPosition() -> [XCUIElement] {
        let predicate = NSPredicate(format: "identifier MATCHES %@",
                                    "calyx\\.sidebar\\.tab\\.\(Self.uuidPattern)")
        let query = app.descendants(matching: .any).matching(predicate)
        return (0..<query.count)
            .map { query.element(boundBy: $0) }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func tabBarTab(atIndex index: Int) -> XCUIElement? {
        let tabs = tabBarTabsByPosition()
        return index < tabs.count ? tabs[index] : nil
    }

    private func sidebarTab(atIndex index: Int) -> XCUIElement? {
        let tabs = sidebarTabsByPosition()
        return index < tabs.count ? tabs[index] : nil
    }

    /// Reads the identifier of the tab-bar tab at a given ordinal position.
    private func tabBarTabIdentifier(atIndex index: Int) -> String? {
        tabBarTab(atIndex: index)?.identifier
    }

    /// Reads the identifier of the sidebar tab at a given ordinal position.
    private func sidebarTabIdentifier(atIndex index: Int) -> String? {
        sidebarTab(atIndex: index)?.identifier
    }

    /// Creates `count` additional tabs (beyond the initial one) and waits for them to appear.
    private func createTabs(count: Int) {
        for _ in 0..<count {
            createNewTabViaMenu()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    // MARK: - Tab Bar Reorder

    func test_dragTabBarTab_reordersCorrectly() {
        // Arrange: create 3 tabs total (1 initial + 2 new)
        createTabs(count: 2)
        XCTAssertEqual(countTabBarTabs(), 3, "Should have 3 tabs before drag")

        // Capture the identifier of the tab currently at index 0
        guard let firstTabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should exist")
        }
        let originalFirstTabID = firstTabElement.identifier

        // Also capture the tab at index 2 to know the drag target position
        guard let thirdTabElement = tabBarTab(atIndex: 2) else {
            return XCTFail("Tab at index 2 should exist")
        }

        // Act: drag the first tab to the right, past the third tab
        firstTabElement.press(forDuration: 0.2, thenDragTo: thirdTabElement)

        // Allow the reorder animation to settle
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: the tab that was originally first should no longer be at index 0
        let newFirstTabID = tabBarTabIdentifier(atIndex: 0)
        XCTAssertNotNil(newFirstTabID, "A tab should exist at index 0 after reorder")
        XCTAssertNotEqual(
            newFirstTabID, originalFirstTabID,
            "After dragging the first tab past the third, a different tab should now occupy index 0"
        )

        // The original first tab should now be at index 1 or 2
        let tabAtIndex1 = tabBarTabIdentifier(atIndex: 1)
        let tabAtIndex2 = tabBarTabIdentifier(atIndex: 2)
        let originalTabMoved = (tabAtIndex1 == originalFirstTabID) || (tabAtIndex2 == originalFirstTabID)
        XCTAssertTrue(
            originalTabMoved,
            "The original first tab should have moved to index 1 or 2"
        )
    }

    // MARK: - Sidebar Reorder

    func test_dragSidebarTab_reordersCorrectly() {
        // Arrange: create 3 tabs total
        createTabs(count: 2)
        XCTAssertEqual(countTabBarTabs(), 3, "Should have 3 tabs before toggling sidebar")

        // The sidebar is shown by default (WindowSession.showSidebar
        // defaults to true), so its tab rows are already on screen. Do NOT
        // call toggleSidebarViaMenu() here: that would CLOSE the sidebar and
        // hide the very rows this test drags. Just let it settle.
        Thread.sleep(forTimeInterval: 1.0)

        // Find the sidebar tab at index 0
        guard let firstSidebarTab = sidebarTab(atIndex: 0) else {
            return XCTFail("Sidebar tab at index 0 should exist")
        }
        let originalFirstSidebarID = firstSidebarTab.identifier

        // Find the sidebar tab at index 2
        guard let thirdSidebarTab = sidebarTab(atIndex: 2) else {
            return XCTFail("Sidebar tab at index 2 should exist")
        }

        // Act: drag the first sidebar tab down past the third
        firstSidebarTab.press(forDuration: 0.2, thenDragTo: thirdSidebarTab)

        // Allow the reorder animation to settle
        Thread.sleep(forTimeInterval: 1.0)

        // Assert: the tab that was originally at index 0 should no longer be there
        let newFirstSidebarID = sidebarTabIdentifier(atIndex: 0)
        XCTAssertNotNil(newFirstSidebarID, "A sidebar tab should exist at index 0 after reorder")
        XCTAssertNotEqual(
            newFirstSidebarID, originalFirstSidebarID,
            "After dragging the first sidebar tab past the third, a different tab should now occupy index 0"
        )

        // The original first tab should now be at a later index
        let sidebarTabAt1 = sidebarTabIdentifier(atIndex: 1)
        let sidebarTabAt2 = sidebarTabIdentifier(atIndex: 2)
        let originalSidebarTabMoved = (sidebarTabAt1 == originalFirstSidebarID) || (sidebarTabAt2 == originalFirstSidebarID)
        XCTAssertTrue(
            originalSidebarTabMoved,
            "The original first sidebar tab should have moved to index 1 or 2"
        )
    }

    // MARK: - Tap After Drag

    func test_tapStillWorksAfterDrag() {
        // Arrange: create 2 tabs total
        createTabs(count: 1)
        XCTAssertEqual(countTabBarTabs(), 2, "Should have 2 tabs")

        // Find the tab at index 0
        guard let firstTabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should exist")
        }
        let tabID = firstTabElement.identifier

        // Act: perform a very short press-and-drag (within the 5pt minimumDistance threshold)
        // This should not trigger a reorder; instead the tab should remain tappable.
        // We drag to a nearby coordinate offset (2pt right, 0pt down) which is < minimumDistance.
        let startCoordinate = firstTabElement.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let nearbyCoordinate = startCoordinate.withOffset(CGVector(dx: 2, dy: 0))
        startCoordinate.press(forDuration: 0.1, thenDragTo: nearbyCoordinate)

        Thread.sleep(forTimeInterval: 0.5)

        // Assert: the tab should still be at the same index (no reorder occurred)
        let tabAfterDrag = tabBarTabIdentifier(atIndex: 0)
        XCTAssertEqual(
            tabAfterDrag, tabID,
            "Tab should remain at index 0 after a sub-threshold drag"
        )

        // Verify the tab is still tappable by clicking it
        guard let tabElement = tabBarTab(atIndex: 0) else {
            return XCTFail("Tab at index 0 should still exist")
        }
        XCTAssertTrue(tabElement.isHittable, "Tab should be hittable after a sub-threshold drag")
        tabElement.click()

        Thread.sleep(forTimeInterval: 0.5)

        // The tab should still exist and be at the same position
        let tabAfterClick = tabBarTabIdentifier(atIndex: 0)
        XCTAssertEqual(
            tabAfterClick, tabID,
            "Tab should remain at index 0 after clicking"
        )
    }
}
