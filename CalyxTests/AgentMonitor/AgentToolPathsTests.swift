//
//  AgentToolPathsTests.swift
//  CalyxTests
//
//  Pins every AgentToolPaths path property's production branch
//  (testRoot == nil) to exactly the string it has always resolved to.
//  This test process is itself the unit-test host, so
//  CalyxPathRoot.testRoot (the zero-argument seam every property also
//  offers) is always non-nil here -- the explicit `testRoot:` overload
//  on each property is what makes production's own formula directly
//  testable regardless. Also covers the testRoot-non-nil branch, and
//  that every path nests beneath testRoot's own directory tree the same
//  way it nests beneath NSHomeDirectory() in production.
//

import XCTest
@testable import Calyx

final class AgentToolPathsTests: XCTestCase {

    // MARK: - Production parity (testRoot == nil)

    func test_claudeConfigDirectory_productionRoot() {
        XCTAssertEqual(AgentToolPaths.claudeConfigDirectory(testRoot: nil), NSHomeDirectory() + "/.claude")
    }

    func test_claudeConfigPath_productionRoot() {
        XCTAssertEqual(AgentToolPaths.claudeConfigPath(testRoot: nil), NSHomeDirectory() + "/.claude.json")
    }

    func test_claudeSettingsPath_productionRoot() {
        XCTAssertEqual(AgentToolPaths.claudeSettingsPath(testRoot: nil), NSHomeDirectory() + "/.claude/settings.json")
    }

    func test_codexConfigDirectory_productionRoot() {
        XCTAssertEqual(AgentToolPaths.codexConfigDirectory(testRoot: nil), NSHomeDirectory() + "/.codex")
    }

    func test_openCodeConfigDirectory_productionRoot() {
        XCTAssertEqual(AgentToolPaths.openCodeConfigDirectory(testRoot: nil), NSHomeDirectory() + "/.config/opencode")
    }

    func test_grokConfigDirectory_productionRoot() {
        XCTAssertEqual(AgentToolPaths.grokConfigDirectory(testRoot: nil), NSHomeDirectory() + "/.grok")
    }

    func test_piConfigDirectory_productionRoot() {
        XCTAssertEqual(AgentToolPaths.piConfigDirectory(testRoot: nil), NSHomeDirectory() + "/.pi/agent")
    }

    func test_hermesConfigDirectory_productionRoot() {
        XCTAssertEqual(AgentToolPaths.hermesConfigDirectory(testRoot: nil), NSHomeDirectory() + "/.hermes")
    }

    func test_hermesConfigPath_productionRoot() {
        XCTAssertEqual(AgentToolPaths.hermesConfigPath(testRoot: nil), NSHomeDirectory() + "/.hermes/config.yaml")
    }

    // MARK: - testRoot override

    func test_claudeConfigDirectory_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.claudeConfigDirectory(testRoot: "/tmp/root"), "/tmp/root/.claude")
    }

    func test_claudeConfigPath_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.claudeConfigPath(testRoot: "/tmp/root"), "/tmp/root/.claude.json")
    }

    func test_claudeSettingsPath_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.claudeSettingsPath(testRoot: "/tmp/root"), "/tmp/root/.claude/settings.json")
    }

    func test_codexConfigDirectory_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.codexConfigDirectory(testRoot: "/tmp/root"), "/tmp/root/.codex")
    }

    func test_openCodeConfigDirectory_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.openCodeConfigDirectory(testRoot: "/tmp/root"), "/tmp/root/.config/opencode")
    }

    func test_grokConfigDirectory_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.grokConfigDirectory(testRoot: "/tmp/root"), "/tmp/root/.grok")
    }

    func test_piConfigDirectory_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.piConfigDirectory(testRoot: "/tmp/root"), "/tmp/root/.pi/agent")
    }

    func test_hermesConfigDirectory_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.hermesConfigDirectory(testRoot: "/tmp/root"), "/tmp/root/.hermes")
    }

    func test_hermesConfigPath_withTestRoot() {
        XCTAssertEqual(AgentToolPaths.hermesConfigPath(testRoot: "/tmp/root"), "/tmp/root/.hermes/config.yaml")
    }

    // MARK: - Zero-argument properties delegate to CalyxPathRoot.testRoot

    func test_zeroArgumentProperties_matchExplicitCurrentTestRoot() {
        // This test PROCESS is itself the unit-test host, so
        // CalyxPathRoot.testRoot is always non-nil here -- confirming the
        // zero-argument property equals the explicit call with that same
        // value pins the delegation itself, independent of what the
        // current seam happens to resolve to.
        XCTAssertEqual(AgentToolPaths.claudeConfigDirectory,
                       AgentToolPaths.claudeConfigDirectory(testRoot: CalyxPathRoot.testRoot))
        XCTAssertEqual(AgentToolPaths.hermesConfigPath,
                       AgentToolPaths.hermesConfigPath(testRoot: CalyxPathRoot.testRoot))
    }
}
