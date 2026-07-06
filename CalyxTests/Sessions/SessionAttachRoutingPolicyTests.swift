//
//  SessionAttachRoutingPolicyTests.swift
//  CalyxTests
//
//  TDD Red phase for a UX inconsistency: the session browser's "Attach"
//  button always opens a NEW WINDOW, even when a main Calyx window is
//  already available (it should add a tab to it instead, matching the
//  sibling remote-session flow, AppDelegate.spawnRemoteSessionTab) and
//  even when the session is already visibly attached somewhere in this
//  process (it should just focus that pane, not attach a second time).
//
//  SessionAttachRoutingPolicy.decide(isAttachedHere:hasAvailableWindow:)
//  is the single pure decision both cases (and the "open a fresh window"
//  fallback) now go through -- see SessionAttachRoutingPolicy.swift's own
//  header comment for the full rationale, mirroring
//  SessionCloseKillPolicy's identical "single pure predicate instead of
//  each call site separately reasoning about it" precedent.
//
//  Coverage: the full 2^2 = 4-row truth table. Only the (false, false)
//  row (not attached, no window available) yields `.attachAsNewWindow`
//  both against the CURRENT RED-phase stub (which always returns
//  `.attachAsNewWindow`) and the eventual fix -- see that row's comment
//  in the truth table below. The other three rows currently fail.
//

import XCTest
@testable import Calyx

final class SessionAttachRoutingPolicyTests: XCTestCase {

    private struct Row {
        let isAttachedHere: Bool
        let hasAvailableWindow: Bool
        let expected: SessionAttachRoutingPolicy.Decision
        let label: String
    }

    private let truthTable: [Row] = [
        Row(isAttachedHere: true, hasAvailableWindow: true, expected: .focusExistingSurface,
            label: "already attached, window also available -- focus, do not attach a second time"),
        Row(isAttachedHere: true, hasAvailableWindow: false, expected: .focusExistingSurface,
            label: "already attached, no window available -- focus still wins over any attach"),
        Row(isAttachedHere: false, hasAvailableWindow: true, expected: .attachAsTab,
            label: "not attached, window available -- must add a tab to it, not open a second window"),
        // The one row where the RED-phase stub's constant `.attachAsNewWindow`
        // happens to already match: no live surface, and no window to add a
        // tab to, so a fresh window is genuinely the only option.
        Row(isAttachedHere: false, hasAvailableWindow: false, expected: .attachAsNewWindow,
            label: "not attached, no window available -- a fresh window is the only option"),
    ]

    func test_decide_fullTruthTable() {
        for row in truthTable {
            XCTAssertEqual(
                SessionAttachRoutingPolicy.decide(
                    isAttachedHere: row.isAttachedHere, hasAvailableWindow: row.hasAvailableWindow
                ),
                row.expected,
                "[\(row.label)] isAttachedHere=\(row.isAttachedHere) hasAvailableWindow=\(row.hasAvailableWindow) " +
                "must yield \(row.expected)"
            )
        }
    }
}
