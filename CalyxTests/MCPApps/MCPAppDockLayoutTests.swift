//
//  MCPAppDockLayoutTests.swift
//  CalyxTests
//
//  MCPAppDockLayout is the pure geometry behind inline placement
//  (contract v2 §11.10, K55): the dock sits to the right of the terminal,
//  separated by a 1pt divider. Its default width is 40% of the leaf width;
//  a requested width is capped only so that the terminal keeps at least
//  max(120pt, 40 columns). `mode` is a String, not an enum (§11.10
//  signature).
//
//  containerDimensions per mode (§11.10):
//    inline:     width = dockSize.width, height = max(0, dockSize.height - headerHeight),
//                maxWidth/maxHeight = nil (a fixed size; the view fills it)
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

    // MARK: - Side by side

    func test_split_placesTheTerminalLeft_theDividerBetween_andTheDockRight() {
        let leaf = CGRect(x: 10, y: 20, width: 800, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 320, cellWidth: 8)

        XCTAssertEqual(result.terminalRect, CGRect(x: 10, y: 20, width: 479, height: 600))
        XCTAssertEqual(result.dividerRect, CGRect(x: 489, y: 20, width: 1, height: 600))
        XCTAssertEqual(result.dockRect, CGRect(x: 490, y: 20, width: 320, height: 600))
    }

    func test_split_terminalDividerAndDock_partitionTheLeafWidthExactly() {
        let leaf = CGRect(x: 0, y: 0, width: 640, height: 300)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 200, cellWidth: 7)

        XCTAssertEqual(result.terminalRect.width + result.dividerRect.width + result.dockRect.width, leaf.width, accuracy: 0.01)
        XCTAssertEqual(result.terminalRect.maxX, result.dividerRect.minX)
        XCTAssertEqual(result.dividerRect.maxX, result.dockRect.minX)
        XCTAssertEqual(result.dockRect.maxX, leaf.maxX)
        for rect in [result.terminalRect, result.dividerRect, result.dockRect] {
            XCTAssertEqual(rect.minY, leaf.minY)
            XCTAssertEqual(rect.height, leaf.height, "every part spans the leaf's full height")
        }
    }

    func test_split_requestWithinTheCaps_isHonoredExactly() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 250, cellWidth: 8)

        XCTAssertEqual(result.dockRect.width, 250, accuracy: 0.01)
    }

    // MARK: - Default width

    func test_defaultDockWidth_is40PercentOfTheLeafWidth() {
        XCTAssertEqual(MCPAppDockLayout.defaultDockWidth(leafWidth: 800), 320, accuracy: 0.01)
        XCTAssertEqual(MCPAppDockLayout.defaultDockWidth(leafWidth: 1000), 400, accuracy: 0.01)
    }

    // MARK: - Caps

    func test_wideRequest_isHonoredUpToTheTerminalMinimum() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        // 40 columns * 1pt = 40pt, so the 120pt minimum is the only cap.
        let upToTheMinimum = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 679, cellWidth: 1)
        XCTAssertEqual(upToTheMinimum.dockRect.width, 679, accuracy: 0.01, "800 - 1 divider - 120 terminal")
        XCTAssertEqual(upToTheMinimum.terminalRect.width, 120, accuracy: 0.01)

        let beyondTheMinimum = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 790, cellWidth: 1)
        XCTAssertEqual(beyondTheMinimum.dockRect.width, 679, accuracy: 0.01)
    }

    func test_terminal_keepsAtLeast40Columns_whenColumnsAreWiderThanThePointMinimum() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        // 40 columns * 12pt = 480pt, wider than the 120pt minimum.
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 700, cellWidth: 12)

        XCTAssertEqual(result.terminalRect.width, 480, accuracy: 0.01)
        XCTAssertEqual(result.dockRect.width, 319, accuracy: 0.01, "800 - 480 terminal - 1 divider")
    }

    func test_terminal_keepsAtLeast120pt_whenColumnsAreNarrowerThanThePointMinimum() {
        let leaf = CGRect(x: 0, y: 0, width: 200, height: 600)
        // 40 columns * 2pt = 80pt, narrower than the 120pt minimum.
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 100, cellWidth: 2)

        XCTAssertEqual(result.terminalRect.width, 120, accuracy: 0.01)
        XCTAssertEqual(result.dockRect.width, 79, accuracy: 0.01, "200 - 120 terminal - 1 divider")
    }

    func test_dock_isZeroWide_whenTheLeafCannotHoldTheTerminalMinimum() {
        let leaf = CGRect(x: 0, y: 0, width: 100, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 40, cellWidth: 8)

        XCTAssertEqual(result.dockRect.width, 0)
        XCTAssertEqual(result.dockRect.maxX, leaf.maxX)
    }

    func test_negativeRequest_givesAZeroWideDock() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: -50, cellWidth: 8)

        XCTAssertEqual(result.dockRect.width, 0)
        XCTAssertEqual(result.terminalRect.width, 799)
    }

    // MARK: - Divider drag

    func test_dockWidthForDividerRatio_putsTheDocksLeftEdgeUnderTheCursor() {
        XCTAssertEqual(MCPAppDockLayout.dockWidth(forDividerRatio: 0.75, leafWidth: 800), 200, accuracy: 0.01)
        XCTAssertEqual(MCPAppDockLayout.dockWidth(forDividerRatio: 0.5, leafWidth: 640), 320, accuracy: 0.01)
    }

    // MARK: - containerDimensions per display mode

    func test_containerDimensions_inline_isTheDocksFixedSizeBelowTheHeader() {
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "inline", dockSize: CGSize(width: 320, height: 600), windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), headerHeight: 28
        )

        XCTAssertEqual(dims.width, 320)
        XCTAssertEqual(dims.height, 572, "the dock height minus the card header")
        XCTAssertNil(dims.maxWidth, "inline reports a fixed size, not a maximum")
        XCTAssertNil(dims.maxHeight)
    }

    func test_containerDimensions_inline_neverReportsANegativeHeight() {
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "inline", dockSize: CGSize(width: 320, height: 10), windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), headerHeight: 28
        )

        XCTAssertEqual(dims.height, 0, "a card shorter than its header reports 0, not -18")
    }

    func test_containerDimensions_unknownMode_behavesLikeInline() {
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "teleport", dockSize: CGSize(width: 320, height: 600), windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), headerHeight: 28
        )

        XCTAssertEqual(dims.width, 320)
        XCTAssertEqual(dims.height, 572)
        XCTAssertNil(dims.maxWidth)
        XCTAssertNil(dims.maxHeight)
    }

    func test_containerDimensions_fullscreen_isTabTerminalAreaMinusHeader_maxEqualsFixed() {
        let tabTerminalRect = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "fullscreen", dockSize: CGSize(width: 400, height: 300),
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
            mode: "pip", dockSize: CGSize(width: 400, height: 300),
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
            mode: "pip", dockSize: CGSize(width: 400, height: 300),
            windowSize: largeWindow, tabTerminalRect: .zero, headerHeight: 40
        )

        XCTAssertEqual(dims.width, 480)
        XCTAssertEqual(dims.height, 360)
        XCTAssertEqual(dims.maxWidth, 480)
        XCTAssertEqual(dims.maxHeight, 360)
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
