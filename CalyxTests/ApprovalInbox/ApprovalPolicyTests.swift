//
//  ApprovalPolicyTests.swift
//  CalyxTests
//
//  TDD Red Phase for ApprovalPolicy: whether a gated Cockpit action must
//  round-trip through the approval inbox before proceeding, gated by
//  CockpitSettings.autoApproveEnabled.
//
//  Coverage:
//  - default (auto-approve off) always requires approval
//  - auto-approve on skips the approval gate
//

import XCTest
@testable import Calyx

@MainActor
final class ApprovalPolicyTests: XCTestCase {

    private let suiteName = "com.calyx.tests.ApprovalPolicyTests"

    override func setUp() {
        super.setUp()
        CockpitSettings._testUseSuite(named: suiteName)
    }

    override func tearDown() {
        CockpitSettings._testTeardownSuite(named: suiteName)
        super.tearDown()
    }

    func test_policy_default_requiresApproval_always() {
        XCTAssertTrue(ApprovalPolicy.requiresApproval(),
                      "Approval must be required by default, when auto-approve is off")
    }

    func test_policy_autoApproveOn_skipsApproval() {
        // Precondition: the isolated suite starts with auto-approve off,
        // same as the default test above -- confirms this test isn't
        // accidentally exercising leftover state from another suite.
        XCTAssertFalse(CockpitSettings.autoApproveEnabled,
                       "Precondition: the fresh isolated suite must start with auto-approve off")

        CockpitSettings.autoApproveEnabled = true

        XCTAssertFalse(ApprovalPolicy.requiresApproval(),
                       "Auto-approve on must skip the approval gate")
    }
}
