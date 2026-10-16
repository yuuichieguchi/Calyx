// DiffBlockAlignmentTests.swift
// CalyxTests
//
// DiffBlockAlignment.padding (plan addendum 2 §4): per block, the summed
// left heights vs the summed right heights; the shorter side's last row of
// the block gets the difference. Differences within the tolerance (0.5)
// produce no pad.

import CoreGraphics
import Foundation
import Testing
@testable import Calyx

@Suite("DiffBlockAlignment.padding")
struct DiffBlockAlignmentTests {

    private typealias Pad = DiffBlockAlignment.Pad

    @Test func equalHeights_noPads() {
        let pads = DiffBlockAlignment.padding(blocks: [0..<1, 1..<3, 3..<4],
                                              leftHeights: [20, 20, 40, 20],
                                              rightHeights: [20, 40, 20, 20])
        #expect(pads == [])
    }

    @Test func singleRowBlock_leftTaller_padsRight() {
        let pads = DiffBlockAlignment.padding(blocks: [0..<1, 1..<2, 2..<3],
                                              leftHeights: [20, 60, 20],
                                              rightHeights: [20, 20, 20])
        #expect(pads == [Pad(row: 1, side: .right, pad: 40)])
    }

    @Test func singleRowBlock_rightTaller_padsLeft() {
        let pads = DiffBlockAlignment.padding(blocks: [0..<1],
                                              leftHeights: [20],
                                              rightHeights: [80])
        #expect(pads == [Pad(row: 0, side: .left, pad: 60)])
    }

    /// Block 1..<4: left 20+40+20 = 80, right 20+20+20 = 60 -> right row 3 gets 20.
    @Test func multiRowBlock_sumsCompared_padOnShorterSidesLastRow() {
        let pads = DiffBlockAlignment.padding(blocks: [0..<1, 1..<4],
                                              leftHeights: [20, 20, 40, 20],
                                              rightHeights: [20, 20, 20, 20])
        #expect(pads == [Pad(row: 3, side: .right, pad: 20)])
    }

    @Test func differenceWithinTolerance_noPad() {
        let pads = DiffBlockAlignment.padding(blocks: [0..<1],
                                              leftHeights: [20.3],
                                              rightHeights: [20])
        #expect(pads == [])
    }

    @Test func explicitTolerance_isRespected() {
        let pads = DiffBlockAlignment.padding(blocks: [0..<1],
                                              leftHeights: [22],
                                              rightHeights: [20],
                                              tolerance: 5)
        #expect(pads == [])
    }

    /// Blocks: [0] equal | [1..<3] left 40 vs right 60 -> left row 2 pad 20 |
    /// [3] equal | [4] left 60 vs right 20 -> right row 4 pad 40.
    @Test func mixedBlocks_onePadPerUnequalBlock_inBlockOrder() {
        let pads = DiffBlockAlignment.padding(blocks: [0..<1, 1..<3, 3..<4, 4..<5],
                                              leftHeights: [20, 20, 20, 20, 60],
                                              rightHeights: [20, 40, 20, 20, 20])
        #expect(pads == [Pad(row: 2, side: .left, pad: 20), Pad(row: 4, side: .right, pad: 40)])
    }

    @Test func noBlocks_noPads() {
        #expect(DiffBlockAlignment.padding(blocks: [], leftHeights: [], rightHeights: []) == [])
    }
}
