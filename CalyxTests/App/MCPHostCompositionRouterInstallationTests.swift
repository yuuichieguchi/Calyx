//
//  MCPHostCompositionRouterInstallationTests.swift
//  CalyxTests
//
//  Coverage: K53. `MCPHostComposition.ipcStateDidChange()` decides from
//  `MCPHostComposition.installsCalyxMCPRouter(isServerRunning:runningOperation:)`
//  whether `/calyx-mcp` has the router. The router must already be
//  installed when `IPCActivationChain` announces a running enable (its
//  first `.calyxIPCStateDidChange`, posted before the enable's work
//  starts the server), so the listener never answers `/calyx-mcp` with
//  503 while the enable writes the agent configs. It is cleared only
//  once the server is stopped and no enable is running.
//

import XCTest
@testable import Calyx

@MainActor
final class MCPHostCompositionRouterInstallationTests: XCTestCase {

    func test_enableRunning_serverNotYetStarted_installsRouter() {
        XCTAssertTrue(MCPHostComposition.installsCalyxMCPRouter(isServerRunning: false, runningOperation: .enabling),
                      "the router must be in place before the enable's work starts the listener")
    }

    func test_serverRunning_installsRouter() {
        XCTAssertTrue(MCPHostComposition.installsCalyxMCPRouter(isServerRunning: true, runningOperation: nil))
        XCTAssertTrue(MCPHostComposition.installsCalyxMCPRouter(isServerRunning: true, runningOperation: .enabling))
    }

    func test_disableRunning_serverStillUp_keepsRouter() {
        XCTAssertTrue(MCPHostComposition.installsCalyxMCPRouter(isServerRunning: true, runningOperation: .disabling),
                      "the router stays while the listener still serves")
    }

    func test_serverStopped_noEnableRunning_clearsRouter() {
        XCTAssertFalse(MCPHostComposition.installsCalyxMCPRouter(isServerRunning: false, runningOperation: nil),
                       "disabled (or an enable that failed to start the server): /calyx-mcp answers 503")
        XCTAssertFalse(MCPHostComposition.installsCalyxMCPRouter(isServerRunning: false, runningOperation: .disabling))
    }
}
