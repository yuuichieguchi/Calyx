//
//  SurfacePropertyStoreTests.swift
//  CalyxTests
//
//  TDD Red Phase for SurfacePropertyStore: the app-wide per-surface
//  title/cwd tracker backing Cockpit's pane_list.
//
//  Coverage:
//  - a .ghosttySetTitle notification for a registered surface records
//    that surface's title
//  - a .ghosttySetPwd notification for a registered surface records
//    that surface's cwd
//  - a .calyxSurfaceDestroyed notification prunes that surface's
//    recorded title
//  - a notification whose object is a SurfaceView that was never
//    registered anywhere doesn't crash and doesn't disturb a
//    different, already-tracked surface's recorded title
//  - SurfaceRegistry.destroySurface's _testInsert-only (early-return)
//    branch also prunes a recorded title, symmetric with the main
//    destroy path (P3 review F4)
//

import XCTest
@testable import Calyx

@MainActor
final class SurfacePropertyStoreTests: XCTestCase {

    private var store: SurfacePropertyStore!

    override func setUp() {
        super.setUp()
        store = SurfacePropertyStore()
    }

    /// P3 final gate (S1): `store._stopObserving()` undoes each test's
    /// own `startObserving()` call -- without it, every test's
    /// `SurfacePropertyStore` instance stays registered with
    /// `NotificationCenter` for the rest of the test process (a leaked
    /// observer per test method). `SurfaceLocator.shared` is a separate
    /// global singleton that persists across test cases within the same
    /// process too -- without resetting it, a view registered via
    /// `_testInsert` in one test would still resolve in the next test's
    /// lookups.
    override func tearDown() {
        store._stopObserving()
        store = nil
        SurfaceLocator.shared._testReset()
        super.tearDown()
    }

    func test_setTitleNotification_recordsPerSurfaceTitle() {
        let registry = SurfaceRegistry()
        let id = UUID()
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: view, userInfo: ["title": "vim ~/repo"])

        XCTAssertEqual(store.title(for: id), "vim ~/repo",
                       "a .ghosttySetTitle notification for a registered surface must record its per-surface title")
    }

    func test_setPwdNotification_recordsPerSurfacePwd() {
        let registry = SurfaceRegistry()
        let id = UUID()
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetPwd, object: view, userInfo: ["pwd": "/Users/dev/repo"])

        XCTAssertEqual(store.cwd(for: id), "/Users/dev/repo",
                       "a .ghosttySetPwd notification for a registered surface must record its per-surface cwd")
    }

    func test_surfaceDestroyed_prunesEntry() {
        let registry = SurfaceRegistry()
        let id = UUID()
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: view, userInfo: ["title": "vim ~/repo"])
        XCTAssertEqual(store.title(for: id), "vim ~/repo", "precondition: title recorded before destruction")

        NotificationCenter.default.post(name: .calyxSurfaceDestroyed, object: nil, userInfo: ["surfaceID": id])

        XCTAssertNil(store.title(for: id), "a destroyed surface's recorded title must be pruned")
    }

    /// P3 review (F4): `SurfaceRegistry.destroySurface`'s early-return
    /// (`_testInsert`-only) branch must be symmetric with its main
    /// destroy path -- both must post `.calyxSurfaceDestroyed` so
    /// SurfacePropertyStore prunes a `_testInsert`-only surface's
    /// recorded title exactly like a real registry entry's.
    func test_testInsertOnlySurfaceDestroyed_prunesEntry() {
        let registry = SurfaceRegistry()
        let id = UUID()
        let view = SurfaceView(frame: .zero)
        registry._testInsert(view: view, id: id)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: view, userInfo: ["title": "vim ~/repo"])
        XCTAssertEqual(store.title(for: id), "vim ~/repo", "precondition: title recorded before destruction")

        registry.destroySurface(id)

        XCTAssertNil(store.title(for: id),
                     "a _testInsert-only surface's destroy path must also prune its recorded title, " +
                     "symmetric with a real registry entry's destroy path")
    }

    func test_unknownSurfaceView_ignored() {
        let registry = SurfaceRegistry()
        let knownID = UUID()
        let knownView = SurfaceView(frame: .zero)
        registry._testInsert(view: knownView, id: knownID)
        let unregisteredView = SurfaceView(frame: .zero)

        store.startObserving()
        NotificationCenter.default.post(name: .ghosttySetTitle, object: knownView, userInfo: ["title": "known"])
        NotificationCenter.default.post(name: .ghosttySetTitle, object: unregisteredView, userInfo: ["title": "unknown, must be dropped"])

        XCTAssertEqual(store.title(for: knownID), "known",
                       "a notification from an unregistered SurfaceView must not disturb a different, already-tracked surface's recorded title")
    }
}
