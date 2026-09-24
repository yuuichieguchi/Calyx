//
//  MCPAppDockLayoutTests.swift
//  CalyxTests
//
//  MCPAppDockLayout is the pure geometry behind inline placement
//  (contract v2 §11.10, K55, K67): the dock sits to the right of the
//  terminal, separated by a 1pt divider, and is bounded like a split pane.
//  Its default width is 40% of the leaf width. For a leaf width W, each
//  side keeps at least m = max(50pt, 0.1 * W) when W >= 2 * 50 + 1, and
//  m = 0.1 * W below that, and m is at least 6pt (twice the divider hit
//  expansion, K71) when W - 1 >= 12; a requested dock width is clamped to
//  [m, W - 1 - m]. Every leaf width gets a split (the dock is never
//  hidden). `mode` is a String, not an enum (§11.10 signature).
//
//  containerDimensions per mode (§11.10, K60). contentTopInset is the
//  card's height above its content area (the header, and the prompt while
//  it shows):
//    inline:     width = dockSize.width, height = max(0, dockSize.height - contentTopInset),
//                maxWidth/maxHeight = nil (a fixed size; the view fills it)
//    fullscreen: width = tabTerminalRect.width,
//                height = tabTerminalRect.height - contentTopInset,
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
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 320)

        XCTAssertEqual(result.terminalRect, CGRect(x: 10, y: 20, width: 479, height: 600))
        XCTAssertEqual(result.dividerRect, CGRect(x: 489, y: 20, width: 1, height: 600))
        XCTAssertEqual(result.dockRect, CGRect(x: 490, y: 20, width: 320, height: 600))
    }

    func test_split_terminalDividerAndDock_partitionTheLeafWidthExactly() {
        let leaf = CGRect(x: 0, y: 0, width: 640, height: 300)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 200)

        XCTAssertEqual(result.terminalRect.width + result.dividerRect.width + result.dockRect.width, leaf.width, accuracy: 0.01)
        XCTAssertEqual(result.terminalRect.maxX, result.dividerRect.minX)
        XCTAssertEqual(result.dividerRect.maxX, result.dockRect.minX)
        XCTAssertEqual(result.dockRect.maxX, leaf.maxX)
        for rect in [result.terminalRect, result.dividerRect, result.dockRect] {
            XCTAssertEqual(rect.minY, leaf.minY)
            XCTAssertEqual(rect.height, leaf.height, "every part spans the leaf's full height")
        }
    }

    func test_split_requestWithinTheLimits_isHonoredExactly() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 250)

        XCTAssertEqual(result.dockRect.width, 250, accuracy: 0.01)
    }

    // MARK: - Default width

    func test_defaultDockWidth_is40PercentOfTheLeafWidth() {
        XCTAssertEqual(MCPAppDockLayout.defaultDockWidth(leafWidth: 800), 320, accuracy: 0.01)
        XCTAssertEqual(MCPAppDockLayout.defaultDockWidth(leafWidth: 1000), 400, accuracy: 0.01)
    }

    func test_defaultDockWidth_isWithinTheSplitLimits_andIsHonored() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = MCPAppDockLayout.split(
            leafRect: leaf, dockWidth: MCPAppDockLayout.defaultDockWidth(leafWidth: leaf.width)
        )

        XCTAssertEqual(result.dockRect, CGRect(x: 480, y: 0, width: 320, height: 600))
        XCTAssertEqual(result.terminalRect, CGRect(x: 0, y: 0, width: 479, height: 600))
    }

    // MARK: - Split limits (SplitData.clampRatio [0.1, 0.9] and minSize 50)

    func test_wideRequest_stopsWhereTheTerminalKeepsTenPercent() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        // m = max(50, 0.1 * 800) = 80; the dock is at most 800 - 1 - 80.
        let upToTheLimit = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 719)
        XCTAssertEqual(upToTheLimit.dockRect.width, 719, accuracy: 0.01)
        XCTAssertEqual(upToTheLimit.terminalRect.width, 80, accuracy: 0.01)

        let beyondTheLimit = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 790)
        XCTAssertEqual(beyondTheLimit.dockRect.width, 719, accuracy: 0.01)
        XCTAssertEqual(beyondTheLimit.terminalRect.width, 80, accuracy: 0.01)
    }

    func test_narrowRequest_isRaisedToTenPercentOfTheLeaf() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 40)

        XCTAssertEqual(result.dockRect.width, 80, accuracy: 0.01)
        XCTAssertEqual(result.terminalRect.width, 719, accuracy: 0.01)
    }

    func test_bothSidesKeep50pt_whenTenPercentIsLess() {
        let leaf = CGRect(x: 0, y: 0, width: 400, height: 600)
        // m = max(50, 40) = 50.
        let narrow = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 10)
        XCTAssertEqual(narrow.dockRect.width, 50, accuracy: 0.01)
        XCTAssertEqual(narrow.terminalRect.width, 349, accuracy: 0.01)

        let wide = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 390)
        XCTAssertEqual(wide.dockRect.width, 349, accuracy: 0.01)
        XCTAssertEqual(wide.terminalRect.width, 50, accuracy: 0.01)
    }

    func test_negativeRequest_givesTheLowerLimit() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: -50)

        XCTAssertEqual(result.dockRect.width, 80, accuracy: 0.01)
        XCTAssertEqual(result.terminalRect.width, 719, accuracy: 0.01)
    }

    func test_dockWidthRequestPastTheLeafsRightEdge_isHeldAtTheLowerLimit() {
        let leaf = CGRect(x: 0, y: 0, width: 800, height: 600)
        let requested = MCPAppDockLayout.dockWidth(forDividerRatio: 1.2, leafWidth: leaf.width)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: requested)

        XCTAssertEqual(result.dockRect.width, 80, accuracy: 0.01)
        XCTAssertEqual(result.dockRect.maxX, leaf.maxX)
    }

    func test_clampedDockWidth_matchesTheSplit() {
        XCTAssertEqual(MCPAppDockLayout.clampedDockWidth(900, leafWidth: 800), 719, accuracy: 0.01)
        XCTAssertEqual(MCPAppDockLayout.clampedDockWidth(-10, leafWidth: 800), 80, accuracy: 0.01)
        XCTAssertEqual(MCPAppDockLayout.clampedDockWidth(300, leafWidth: 800), 300, accuracy: 0.01)
        XCTAssertEqual(MCPAppDockLayout.clampedDockWidth(300, leafWidth: 200), 149, accuracy: 0.01)
    }

    // MARK: - Narrow leaves keep the dock

    func test_200ptLeaf_stillShowsADock() {
        let leaf = CGRect(x: 0, y: 0, width: 200, height: 600)
        let result = MCPAppDockLayout.split(
            leafRect: leaf, dockWidth: MCPAppDockLayout.defaultDockWidth(leafWidth: leaf.width)
        )

        XCTAssertEqual(result.dockRect, CGRect(x: 120, y: 0, width: 80, height: 600))
        XCTAssertEqual(result.dividerRect, CGRect(x: 119, y: 0, width: 1, height: 600))
        XCTAssertEqual(result.terminalRect, CGRect(x: 0, y: 0, width: 119, height: 600))
        // m = 50: the dock is limited to [50, 149].
        XCTAssertEqual(MCPAppDockLayout.split(leafRect: leaf, dockWidth: 300).dockRect.width, 149, accuracy: 0.01)
        XCTAssertEqual(MCPAppDockLayout.split(leafRect: leaf, dockWidth: 10).dockRect.width, 50, accuracy: 0.01)
    }

    func test_101ptLeaf_isTheNarrowestWithThe50ptFloor() {
        let leaf = CGRect(x: 0, y: 0, width: 101, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 10)

        XCTAssertEqual(result.dockRect.width, 50, accuracy: 0.01)
        XCTAssertEqual(result.terminalRect.width, 50, accuracy: 0.01)
    }

    func test_60ptLeaf_splitsProportionally_withoutThe50ptFloor() {
        let leaf = CGRect(x: 0, y: 0, width: 60, height: 600)
        // Narrower than 2 * 50 + 1: m = 0.1 * 60 = 6, the dock is limited to [6, 53].
        let byDefault = MCPAppDockLayout.split(
            leafRect: leaf, dockWidth: MCPAppDockLayout.defaultDockWidth(leafWidth: leaf.width)
        )
        XCTAssertEqual(byDefault.dockRect.width, 24, accuracy: 0.01)
        XCTAssertEqual(byDefault.terminalRect.width, 35, accuracy: 0.01)
        XCTAssertEqual(byDefault.dividerRect.width, 1)

        let wide = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 60)
        XCTAssertEqual(wide.dockRect.width, 53, accuracy: 0.01)
        XCTAssertEqual(wide.terminalRect.width, 6, accuracy: 0.01)

        let narrow = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 0)
        XCTAssertEqual(narrow.dockRect.width, 6, accuracy: 0.01)
        XCTAssertEqual(narrow.terminalRect.width, 53, accuracy: 0.01)
    }

    func test_50ptLeaf_keepsTwiceTheDividerHitExpansionOnEachSide() {
        let leaf = CGRect(x: 0, y: 0, width: 50, height: 600)
        // 0.1 * 50 = 5 is less than 2 * 3 = 6, so each side keeps 6pt and
        // the dock divider's hit area stays clear of the neighbouring
        // split divider's: the dock is limited to [6, 43].
        let wide = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 50)
        XCTAssertEqual(wide.dockRect.width, 43, accuracy: 0.01)
        XCTAssertEqual(wide.terminalRect.width, 6, accuracy: 0.01)

        let narrow = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 0)
        XCTAssertEqual(narrow.dockRect.width, 6, accuracy: 0.01)
        XCTAssertEqual(narrow.terminalRect.width, 43, accuracy: 0.01)
    }

    func test_splitPartsNeverHaveANegativeWidth_inALeafNarrowerThanTheDivider() {
        let leaf = CGRect(x: 0, y: 0, width: 1, height: 600)
        let result = MCPAppDockLayout.split(leafRect: leaf, dockWidth: 5)

        for rect in [result.terminalRect, result.dividerRect, result.dockRect] {
            XCTAssertGreaterThanOrEqual(rect.width, 0)
        }
    }

    /// `split` cannot pass a negative width (`CGRect.width` is the
    /// standardized, non-negative width), but `clampedDockWidth` is also
    /// called directly with a leaf width.
    func test_clampedDockWidth_ofANegativeLeafWidth_isZero() {
        XCTAssertEqual(MCPAppDockLayout.clampedDockWidth(-5, leafWidth: -10), 0)
        XCTAssertEqual(MCPAppDockLayout.clampedDockWidth(5, leafWidth: -10), 0)
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
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), contentTopInset: 28
        )

        XCTAssertEqual(dims.width, 320)
        XCTAssertEqual(dims.height, 572, "the dock height minus the card header")
        XCTAssertNil(dims.maxWidth, "inline reports a fixed size, not a maximum")
        XCTAssertNil(dims.maxHeight)
    }

    func test_containerDimensions_inline_neverReportsANegativeHeight() {
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "inline", dockSize: CGSize(width: 320, height: 10), windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), contentTopInset: 28
        )

        XCTAssertEqual(dims.height, 0, "a card shorter than its header reports 0, not -18")
    }

    func test_containerDimensions_unknownMode_behavesLikeInline() {
        let dims = MCPAppDockLayout.containerDimensions(
            mode: "teleport", dockSize: CGSize(width: 320, height: 600), windowSize: CGSize(width: 1200, height: 800),
            tabTerminalRect: CGRect(x: 0, y: 0, width: 1200, height: 760), contentTopInset: 28
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
            windowSize: CGSize(width: 1200, height: 800), tabTerminalRect: tabTerminalRect, contentTopInset: 40
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
            windowSize: smallWindow, tabTerminalRect: .zero, contentTopInset: 40
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
            windowSize: largeWindow, tabTerminalRect: .zero, contentTopInset: 40
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
