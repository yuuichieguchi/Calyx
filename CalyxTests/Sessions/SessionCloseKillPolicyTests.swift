//
//  SessionCloseKillPolicyTests.swift
//  CalyxTests
//
//  TDD Red Phase for SessionCloseKillPolicy.shouldKill: the fix-round
//  extraction of "should tearing down this surface also kill its
//  calyx-session" into a single pure decision, after a review found the
//  kill call reachable from two unsafe reentrant destroySurface paths
//  (performReconnect self-killing the session being reconnected to, and
//  windowWillClose/quit killing every persistent session — see
//  SessionCloseKillPolicy.swift's header comment for the full story).
//
//  Coverage: the full 2^3 = 8-row truth table for
//  shouldKill(hasSession:isTerminating:isReconnectSwap:). Only the row
//  with hasSession=true, isTerminating=false, isReconnectSwap=false (a
//  genuine explicit close with a session present) must be true.
//

import XCTest
@testable import Calyx

final class SessionCloseKillPolicyTests: XCTestCase {

    private struct Row {
        let hasSession: Bool
        let isTerminating: Bool
        let isReconnectSwap: Bool
        let expected: Bool
        let label: String
    }

    private let truthTable: [Row] = [
        Row(hasSession: false, isTerminating: false, isReconnectSwap: false, expected: false,
            label: "no session, ordinary close"),
        Row(hasSession: false, isTerminating: true, isReconnectSwap: false, expected: false,
            label: "no session, quitting"),
        Row(hasSession: false, isTerminating: false, isReconnectSwap: true, expected: false,
            label: "no session, reconnect swap"),
        Row(hasSession: false, isTerminating: true, isReconnectSwap: true, expected: false,
            label: "no session, quitting + reconnect swap"),
        Row(hasSession: true, isTerminating: true, isReconnectSwap: false, expected: false,
            label: "session present, quitting — must detach, not kill"),
        Row(hasSession: true, isTerminating: true, isReconnectSwap: true, expected: false,
            label: "session present, quitting + reconnect swap"),
        Row(hasSession: true, isTerminating: false, isReconnectSwap: true, expected: false,
            label: "session present, reconnect swap — must not self-kill the session being reconnected to"),
        Row(hasSession: true, isTerminating: false, isReconnectSwap: false, expected: true,
            label: "session present, genuine explicit close — must kill"),
    ]

    func test_shouldKill_fullTruthTable() {
        for row in truthTable {
            XCTAssertEqual(
                SessionCloseKillPolicy.shouldKill(
                    hasSession: row.hasSession,
                    isTerminating: row.isTerminating,
                    isReconnectSwap: row.isReconnectSwap
                ),
                row.expected,
                "[\(row.label)] hasSession=\(row.hasSession) isTerminating=\(row.isTerminating) " +
                "isReconnectSwap=\(row.isReconnectSwap) must yield \(row.expected)"
            )
        }
    }
}
