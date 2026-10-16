// DiffGlassHostViewWindowTests.swift
// CalyxTests
//
// DiffGlassHostView registers its diff view as the window controller's
// `activeDiffView` when it enters a window and clears that reference when
// it leaves, so change navigation is never routed to a detached view.

import AppKit
import XCTest
@testable import Calyx

@MainActor
final class DiffGlassHostViewWindowTests: XCTestCase {

    func test_leavingWindow_clearsActiveDiffView() throws {
        let surfaceID = UUID()
        let registry = SurfaceRegistry()
        registry._testInsert(view: SurfaceView(frame: .zero), id: surfaceID)
        let tab = Tab(splitTree: SplitTree(leafID: surfaceID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        let contentView = try XCTUnwrap(window.contentView)

        let host = DiffGlassHostView(reduceTransparency: false, glassOpacity: 1)
        contentView.addSubview(host)
        XCTAssertTrue(controller.activeDiffView === host.diffView)

        host.removeFromSuperview()
        XCTAssertNil(controller.activeDiffView)
    }

    func test_leavingWindow_keepsAnotherHostsDiffView() throws {
        let surfaceID = UUID()
        let registry = SurfaceRegistry()
        registry._testInsert(view: SurfaceView(frame: .zero), id: surfaceID)
        let tab = Tab(splitTree: SplitTree(leafID: surfaceID), registry: registry)
        let group = TabGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let session = WindowSession(groups: [group], activeGroupID: group.id)
        let window = CalyxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = CalyxWindowController(window: window, windowSession: session, restoring: true)
        let contentView = try XCTUnwrap(window.contentView)

        let first = DiffGlassHostView(reduceTransparency: false, glassOpacity: 1)
        let second = DiffGlassHostView(reduceTransparency: false, glassOpacity: 1)
        contentView.addSubview(first)
        contentView.addSubview(second)
        XCTAssertTrue(controller.activeDiffView === second.diffView)

        first.removeFromSuperview()
        XCTAssertTrue(controller.activeDiffView === second.diffView)
    }
}
