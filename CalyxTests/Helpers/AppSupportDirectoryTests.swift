//
//  AppSupportDirectoryTests.swift
//  CalyxTests
//
//  Pins AppSupportDirectory.path(testRoot:)'s production branch
//  (testRoot == nil) to exactly the string it has always resolved to --
//  the one place CalyxPathRoot.testRoot is threaded through, so a
//  future change to the redirect can never silently change what a real,
//  non-test launch resolves to. This test process is itself the unit-
//  test host, so CalyxPathRoot.testRoot (the zero-argument seam) is
//  always non-nil here -- the explicit `testRoot: nil` overload is what
//  makes production's own formula directly testable regardless.
//

import XCTest
@testable import Calyx

final class AppSupportDirectoryTests: XCTestCase {

    func test_path_productionRoot_matchesTheRealApplicationSupportDirectory() {
        let fm = FileManager.default
        let expected = (fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true))
            .appendingPathComponent("Calyx", isDirectory: true)
            .path

        XCTAssertEqual(AppSupportDirectory.path(testRoot: nil), expected,
                       "With no CalyxPathRoot.testRoot override, path(testRoot:) must resolve to exactly " +
                       "the same string production has always used")
    }

    func test_path_withTestRoot_resolvesBeneathIt() {
        XCTAssertEqual(AppSupportDirectory.path(testRoot: "/tmp/some-root"), "/tmp/some-root/Calyx")
    }

    func test_locksPath_isAlwaysPathPlusLocks() {
        XCTAssertEqual(AppSupportDirectory.locksPath, AppSupportDirectory.path + "/locks")
    }
}
