//
//  MissionMapPopoverWindowRectTests.swift
//  CalyxTests
//
//  Pins MissionMapPopoverPlacement.windowRect(contentRect:scrollOffset:mapFrame:):
//  a rect in the map's scroll content, moved into the coordinate space
//  the map's frame is measured in (content origin = map origin - scroll
//  offset), size unchanged.
//

import XCTest
@testable import Calyx

final class MissionMapPopoverWindowRectTests: XCTestCase {

    private let contentRect = CGRect(x: 120, y: 300, width: 320, height: 80)

    /// Unscrolled, map at the window origin: unchanged.
    func test_windowRect_unscrolledMapAtOrigin_isUnchanged() {
        let rect = MissionMapPopoverPlacement.windowRect(
            contentRect: contentRect, scrollOffset: .zero, mapFrame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        XCTAssertEqual(rect, contentRect)
    }

    /// Map inset at (200, 28) and scrolled down 150: x 120+200 = 320,
    /// y 300+28-150 = 178.
    func test_windowRect_insetAndScrolled_addsMapOriginAndSubtractsOffset() {
        let rect = MissionMapPopoverPlacement.windowRect(
            contentRect: contentRect,
            scrollOffset: CGPoint(x: 0, y: 150),
            mapFrame: CGRect(x: 200, y: 28, width: 800, height: 600)
        )
        XCTAssertEqual(rect, CGRect(x: 320, y: 178, width: 320, height: 80))
    }
}
