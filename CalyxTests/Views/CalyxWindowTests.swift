//
//  CalyxWindowTests.swift
//  CalyxTests
//
//  Tests for the pure helper `CalyxWindow.shouldPerformZoom(pointInWindow:windowSize:titleBarHeight:trafficLightFrames:)`
//  used by Issue #26's double-click-to-zoom feature.
//
//  The helper must:
//  - Report true when the point is inside the title bar region and NOT on a traffic light button.
//  - Report false when the point is below the title bar region (not inside it).
//  - Report false when the point is inside ANY of the traffic light frames
//    (Close, Minimize, Zoom buttons).
//  - Treat the bottom edge of the title bar (y == windowSize.height - titleBarHeight)
//    as INCLUSIVE — i.e. still inside the title bar.
//  - When passed an empty traffic-light-frames array, only check the title-bar
//    region and return true for any point inside it.
//
//  Coordinate system: AppKit window coordinates with flipped == false, so the
//  y axis increases upward and the title bar occupies the top of the window.
//
//  These tests target a static helper that does NOT exist in the codebase yet.
//  They are expected to FAIL compile/run until the TDD Green phase implements
//  `CalyxWindow.shouldPerformZoom`.
//

import AppKit
import XCTest
@testable import Calyx

final class CalyxWindowTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Standard macOS-like traffic light frames in flipped-false window
    /// coordinates for a window of size (1000, 800) with a 28pt title bar.
    ///
    /// Each rect has width 14 and height 14 at y = 780, meaning each button
    /// spans y [780, 794] which is entirely within the title bar region
    /// [772, 800].
    private let standardTrafficLights: [NSRect] = [
        NSRect(x: 20, y: 780, width: 14, height: 14),  // Close
        NSRect(x: 40, y: 780, width: 14, height: 14),  // Minimize
        NSRect(x: 60, y: 780, width: 14, height: 14),  // Zoom
    ]

    private let standardWindowSize = CGSize(width: 1000, height: 800)
    private let standardTitleBarHeight: CGFloat = 28

    // MARK: - Happy Path (Title Bar, Away From Buttons)

    /// A point inside the title bar but away from all three traffic-light
    /// buttons should report true — the window should perform a zoom on
    /// double-click there.
    func test_shouldPerformZoom_true_in_title_bar_away_from_traffic_lights() {
        let point = NSPoint(x: 300, y: 780)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: standardTrafficLights
        )

        XCTAssertTrue(
            result,
            "A click inside the title bar but away from traffic lights should zoom"
        )
    }

    // MARK: - Below Title Bar

    /// A point with y far below the title bar region should return false.
    func test_shouldPerformZoom_false_below_title_bar() {
        let point = NSPoint(x: 300, y: 500)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: standardTrafficLights
        )

        XCTAssertFalse(
            result,
            "A click below the title bar region should not trigger zoom"
        )
    }

    // MARK: - On Traffic Light Buttons

    /// A point inside the Close button should return false — the click belongs
    /// to AppKit's button handling, not window zoom.
    func test_shouldPerformZoom_false_on_close_button() {
        let point = NSPoint(x: 27, y: 787)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: standardTrafficLights
        )

        XCTAssertFalse(
            result,
            "A click on the Close button must not trigger zoom"
        )
    }

    /// A point inside the Minimize button should return false.
    func test_shouldPerformZoom_false_on_minimize_button() {
        let point = NSPoint(x: 47, y: 787)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: standardTrafficLights
        )

        XCTAssertFalse(
            result,
            "A click on the Minimize button must not trigger zoom"
        )
    }

    /// A point inside the Zoom button should return false — AppKit's Zoom
    /// button already handles its own click, we must not double-dispatch.
    func test_shouldPerformZoom_false_on_zoom_button() {
        let point = NSPoint(x: 67, y: 787)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: standardTrafficLights
        )

        XCTAssertFalse(
            result,
            "A click on the Zoom button must not trigger zoom"
        )
    }

    // MARK: - Title Bar Boundary (Inclusive Lower Edge)

    /// A point exactly on the lower edge of the title bar
    /// (y == windowSize.height - titleBarHeight) must be treated as INSIDE
    /// the title bar and return true.
    func test_shouldPerformZoom_true_on_title_bar_boundary() {
        // 800 - 28 = 772 — exactly on the boundary, should still zoom
        let point = NSPoint(x: 300, y: 772)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: standardTrafficLights
        )

        XCTAssertTrue(
            result,
            "The lower edge of the title bar should be inclusive (y == height - titleBarHeight → inside)"
        )
    }

    /// A point just below the title bar boundary must NOT be treated as inside
    /// the title bar.
    func test_shouldPerformZoom_false_just_below_boundary() {
        let point = NSPoint(x: 300, y: 771.9)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: standardTrafficLights
        )

        XCTAssertFalse(
            result,
            "A point 0.1 below the title bar boundary should be outside the title bar"
        )
    }

    // MARK: - Empty Traffic-Light Array

    /// When the traffic-light-frame array is empty (e.g. during window setup
    /// before the buttons are laid out), every point inside the title bar
    /// should zoom since no exclusion applies.
    func test_shouldPerformZoom_empty_traffic_lights() {
        let point = NSPoint(x: 30, y: 790)

        let result = CalyxWindow.shouldPerformZoom(
            pointInWindow: point,
            windowSize: standardWindowSize,
            titleBarHeight: standardTitleBarHeight,
            trafficLightFrames: []
        )

        XCTAssertTrue(
            result,
            "With no traffic-light exclusion, any point in the title bar should zoom"
        )
    }
}
