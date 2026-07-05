//
//  SessionSurfaceMapTests.swift
//  CalyxTests
//
//  TDD Red Phase for SessionSurfaceMap: the bidirectional
//  session-ID <-> surface-UUID registry used to resolve
//  reconnect/routing by calyx-session ID.
//
//  Coverage:
//  - register() makes both directions resolvable
//  - unregister() removes both directions
//  - replaceSurface(old:new:) re-points a session's registration to a
//    fresh surface UUID and clears the old surface's reverse entry
//  - Registering a second surface under the same sessionID overwrites
//    the first (last write wins), and the first surface's reverse
//    lookup no longer resolves
//  - Unknown ids resolve to nil on both directions
//

import XCTest
@testable import Calyx

@MainActor
final class SessionSurfaceMapTests: XCTestCase {

    private var map: SessionSurfaceMap!

    override func setUp() {
        super.setUp()
        // A fresh instance per test — never touch `.shared`, which other
        // suites (e.g. CalyxMCPServer's session-routing tests) may also
        // read via the server's default.
        map = SessionSurfaceMap()
    }

    override func tearDown() {
        map = nil
        super.tearDown()
    }

    // MARK: - register / resolve

    func test_register_makesBothDirectionsResolvable() {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()

        map.register(sessionID: sessionID, surfaceID: surfaceID)

        XCTAssertEqual(map.surfaceID(for: sessionID), surfaceID,
                       "surfaceID(for:) must resolve the surface registered for this sessionID")
        XCTAssertEqual(map.sessionID(for: surfaceID), sessionID,
                       "sessionID(for:) must resolve the sessionID registered for this surfaceID")
    }

    // MARK: - unregister

    func test_unregister_removesBothDirections() {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let surfaceID = UUID()
        map.register(sessionID: sessionID, surfaceID: surfaceID)

        map.unregister(sessionID: sessionID)

        XCTAssertNil(map.surfaceID(for: sessionID), "unregister must remove the forward mapping")
        XCTAssertNil(map.sessionID(for: surfaceID), "unregister must also remove the reverse mapping")
    }

    // MARK: - replaceSurface

    func test_replaceSurface_repointsSessionToNewSurface_clearsOldReverseEntry() {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let oldSurfaceID = UUID()
        let newSurfaceID = UUID()
        map.register(sessionID: sessionID, surfaceID: oldSurfaceID)

        map.replaceSurface(old: oldSurfaceID, new: newSurfaceID)

        XCTAssertEqual(map.surfaceID(for: sessionID), newSurfaceID,
                       "After replaceSurface, the sessionID must resolve to the new surface")
        XCTAssertEqual(map.sessionID(for: newSurfaceID), sessionID,
                       "The new surface must resolve back to the same sessionID")
        XCTAssertNil(map.sessionID(for: oldSurfaceID),
                     "The old surface's reverse entry must be cleared once replaced — it no longer exists")
    }

    // MARK: - double registration overwrite convention

    func test_registerSameSessionIDTwice_overwritesPreviousSurface_oldSurfaceNoLongerResolves() {
        let sessionID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
        let firstSurfaceID = UUID()
        let secondSurfaceID = UUID()

        map.register(sessionID: sessionID, surfaceID: firstSurfaceID)
        map.register(sessionID: sessionID, surfaceID: secondSurfaceID)

        XCTAssertEqual(map.surfaceID(for: sessionID), secondSurfaceID,
                       "Registering the same sessionID again must overwrite with the newest surface (last write wins)")
        XCTAssertNil(map.sessionID(for: firstSurfaceID),
                     "The first surface's reverse entry must not survive being superseded by the second registration")
        XCTAssertEqual(map.sessionID(for: secondSurfaceID), sessionID)
    }

    // MARK: - unknown ids

    func test_unknownSessionIDAndSurfaceID_resolveToNil() {
        XCTAssertNil(map.surfaceID(for: "never-registered"))
        XCTAssertNil(map.sessionID(for: UUID()))
    }
}
