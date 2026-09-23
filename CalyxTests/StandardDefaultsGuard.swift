//
//  StandardDefaultsGuard.swift
//  CalyxTests
//
//  Shared helpers for asserting a test never writes to
//  UserDefaults.standard. The unit test host is the app itself (bundle
//  id com.calyx.terminal), so UserDefaults.standard is the developer's
//  real defaults domain and may already hold a value for any of these
//  keys from ordinary app use -- a test must never assume the key is
//  absent, only that the test did not change it.
//

import XCTest

extension XCTestCase {

    /// Captures `UserDefaults.standard`'s current value for `key`
    /// before running `body` (passed the captured value, pre-cast to
    /// `Bool?`, so callers can derive a write that always differs from
    /// it), then asserts the raw object under `key` is unchanged
    /// afterward. Compares raw objects (`as? NSObject`), not `as?
    /// Bool`, so a non-Bool value written under `key` is also caught.
    func assertStandardDefaultsUntouched(
        key: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: (_ before: Bool?) -> Void
    ) {
        let before = UserDefaults.standard.object(forKey: key)
        body(before as? Bool)
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? NSObject,
            before as? NSObject,
            "The real .standard defaults domain must never be touched while using an isolated test suite",
            file: file,
            line: line
        )
    }
}

/// Per-test-class tripwire for the same guarantee as
/// `assertStandardDefaultsUntouched(key:_:)`, for a test class whose
/// `.standard` value under `key` must survive an entire test method,
/// not just one isolated block. Create in `setUp()` before switching to
/// the isolated suite, and call `assertUnchanged()` in `tearDown()`
/// after tearing that suite down.
final class StandardDefaultsTripwire {
    private let key: String
    private let before: Any?

    init(key: String) {
        self.key = key
        self.before = UserDefaults.standard.object(forKey: key)
    }

    func assertUnchanged(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            UserDefaults.standard.object(forKey: key) as? NSObject,
            before as? NSObject,
            "A test in this class wrote to the real .standard defaults domain",
            file: file,
            line: line
        )
    }
}
