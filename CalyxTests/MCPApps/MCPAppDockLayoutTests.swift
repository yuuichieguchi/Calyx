//
//  MCPAppDockLayoutTests.swift
//  CalyxTests
//
//  MCPAppDockLayout is the pure geometry behind inline placement
//  (contract v2 §11.10): the terminal keeps at least max(120pt, 6 rows),
//  the dock never exceeds 60% of the leaf height, and size-changed
//  requests are clamped to the same budget. `mode` is a String, not an
//  enum (§11.10 signature).
//
//  containerDimensions per mode (§11.10, pinned verbatim):
//    inline:     width = leafRect.width, height = nil,
//                maxWidth = leafRect.width, maxHeight = leafRect.height * 0.6
//    fullscreen: width = tabTerminalRect.width,
//                height = tabTerminalRect.height - headerHeight,
//                maxWidth/maxHeight = the same values
//    pip:        width = min(480, windowSize.width / 2),
//                height = min(360, windowSize.height / 2),
//                maxWidth/maxHeight = the same values
//    any other string behaves like "inline".
//

import XCTest
@testable import Calyx

final class MCPAppDockLayoutTests: XCTestCase {

    // MARK: - Terminal minimum

    func test_terminalRect_neverShrinksBelow120pt_whenRowHeightIsSmall() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 300)
        // rowHeight small enough that 6 rows < 120pt, so the 120pt floor governs.
        let result = MCPAppDockLayout.split(leafRect: leaf, dockHeight: 250, rowHeight: 10)

        XCTAssertGreaterThanOrEqual(result.terminalRect.height, 120)
    }

    func test_terminalRect_neverShrinksBelow6Rows_whenRowHeightIsLarge() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 300)
        // rowHeight large enough that 6 rows > 120pt, so the 6-row floor governs.
        let result = MCPAppDockLayout.split(leafRect: leaf, dockHeight: 250, rowHeight: 30)

        XCTAssertGreaterThanOrEqual(result.terminalRect.height, 180, "6 rows * 30pt = 180pt must be respected over the 120pt floor")
    }

    // MARK: - Dock maximum

    func test_dockRect_neverExceeds60PercentOfLeafHeight() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 300)
        // Ask for a dock far larger than 60% of 300 (180).
        let result = MCPAppDockLayout.split(leafRect: leaf, dockHeight: 290, rowHeight: 20)

        XCTAssertLessThanOrEqual(result.dockRect.height, 180)
    }

    func test_terminalAndDockRects_partitionLeafHeightExactly() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockHeight: 100, rowHeight: 20)

        XCTAssertEqual(result.terminalRect.height + result.dockRect.height, leaf.height, accuracy: 0.01)
        XCTAssertEqual(result.terminalRect.width, leaf.width)
        XCTAssertEqual(result.dockRect.width, leaf.width)
    }

    func test_dockRequestedWithinBudget_isHonoredExactly() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 300)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockHeight: 100, rowHeight: 20)

        XCTAssertEqual(result.dockRect.height, 100, accuracy: 0.01)
    }

    // MARK: - containerDimensions per display mode

    func test_containerDimensions_inline_widthAndMaxWidthEqualLeafWidth_maxHeightIs60Percent() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 300)
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "inline", leafRect: leaf, windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), headerHeight: 40
        )

        XCTAssertEqual(dims.width, leaf.width)
        XCTAssertEqual(dims.maxWidth, leaf.width)
        XCTAssertEqual(dims.maxHeight ?? .nan, Double(leaf.height * 0.6), accuracy: 0.01)
        XCTAssertNil(dims.height, "inline reports width + maxHeight, not a fixed height")
    }

    func test_containerDimensions_unknownMode_behavesLikeInline() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 300)
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "teleport", leafRect: leaf, windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), headerHeight: 40
        )

        XCTAssertEqual(dims.width, leaf.width)
        XCTAssertEqual(dims.maxWidth, leaf.width)
        XCTAssertEqual(dims.maxHeight ?? .nan, Double(leaf.height * 0.6), accuracy: 0.01)
        XCTAssertNil(dims.height)
    }

    func test_containerDimensions_fullscreen_isTabTerminalAreaMinusHeader_maxEqualsFixed() {
        let tabTerminalRect = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "fullscreen", leafRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            windowSize: CGSize(width: 1200, height: 800), tabTerminalRect: tabTerminalRect, headerHeight: 40
        )

        XCTAssertEqual(dims.width, 1200)
        XCTAssertEqual(dims.height, 760, "tab terminal area height minus the 40pt header")
        XCTAssertEqual(dims.maxWidth, dims.width, "fullscreen's maxWidth/maxHeight equal its fixed width/height")
        XCTAssertEqual(dims.maxHeight, dims.height)
    }

    func test_containerDimensions_pip_capsAtWindowHalfOr480x360_widthHeightEqualMax() {
        let smallWindow = CGSize(width: 600, height: 400)
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "pip", leafRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            windowSize: smallWindow, tabTerminalRect: .zero, headerHeight: 40
        )

        XCTAssertEqual(dims.width, 300, "min(480, 600/2) = 300")
        XCTAssertEqual(dims.height, 200, "min(360, 400/2) = 200")
        XCTAssertEqual(dims.maxWidth, dims.width)
        XCTAssertEqual(dims.maxHeight, dims.height)
    }

    func test_containerDimensions_pip_largeWindow_capsAt480x360() {
        let largeWindow = CGSize(width: 2000, height: 1400)
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "pip", leafRect: CGRect(x: 0, y: 0, width: 400, height: 300),
            windowSize: largeWindow, tabTerminalRect: .zero, headerHeight: 40
        )

        XCTAssertEqual(dims.width, 480)
        XCTAssertEqual(dims.height, 360)
        XCTAssertEqual(dims.maxWidth, 480)
        XCTAssertEqual(dims.maxHeight, 360)
    }

    // MARK: - size-changed clamped

    func test_sizeChanged_requestWithinBudget_isHonored() {
        let clamped = MCPAppDockLayout.clampSizeChanged(requestedHeight: 100, leafHeight: 300)
        XCTAssertEqual(clamped, 100, accuracy: 0.01)
    }

    func test_sizeChanged_requestOverBudget_isClampedTo60Percent() {
        let clamped = MCPAppDockLayout.clampSizeChanged(requestedHeight: 1000, leafHeight: 300)
        XCTAssertEqual(clamped, 180, accuracy: 0.01)
    }

    func test_sizeChanged_negativeRequest_isClampedToZero() {
        let clamped = MCPAppDockLayout.clampSizeChanged(requestedHeight: -50, leafHeight: 300)
        XCTAssertEqual(clamped, 0, accuracy: 0.01)
    }

    // MARK: - Border widths

    func test_borderWidth_prefersBorderTrue_isNonZero() {
        XCTAssertGreaterThan(MCPAppDockLayout.borderWidth(prefersBorder: true), 0)
    }

    func test_borderWidth_prefersBorderFalse_isZero() {
        XCTAssertEqual(MCPAppDockLayout.borderWidth(prefersBorder: false), 0)
    }

    func test_borderWidth_prefersBorderOmitted_usesCalyxDefault() {
        // Omitted prefersBorder must use the Calyx default border, i.e. behave
        // identically to `true`, not to `false`.
        XCTAssertEqual(MCPAppDockLayout.borderWidth(prefersBorder: nil), MCPAppDockLayout.borderWidth(prefersBorder: true))
    }
}
