//
//  SessionRefTests.swift
//  CalyxTests
//
//  TDD Red Phase for SessionRef.isValidULID: the restore-path guard
//  that rejects a persisted SessionRef.sessionID that isn't shaped like
//  a genuine ULID, before it ever reaches calyx-session attach.
//

import XCTest
@testable import Calyx

final class SessionRefTests: XCTestCase {

    func test_isValidULID_acceptsWellFormedULID() {
        XCTAssertTrue(SessionRef.isValidULID("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
                     "A genuine 26-character Crockford base32 ULID must be accepted")
    }

    func test_isValidULID_rejectsTooShort() {
        XCTAssertFalse(SessionRef.isValidULID("01ARZ3NDEKTSV4RRFFQ69G5FA"), "25 characters must be rejected")
    }

    func test_isValidULID_rejectsTooLong() {
        XCTAssertFalse(SessionRef.isValidULID("01ARZ3NDEKTSV4RRFFQ69G5FAVX"), "27 characters must be rejected")
    }

    func test_isValidULID_rejectsCharactersOutsideCrockfordAlphabet() {
        // 'I', 'L', 'O', 'U' are deliberately excluded from Crockford's
        // base32 alphabet (visual ambiguity with 1/1/0/V) and must be
        // rejected even though the length is correct.
        XCTAssertFalse(SessionRef.isValidULID("01ARZ3NDEKTSV4RRFFQ69G5FAI"), "'I' is not in the ULID alphabet")
        XCTAssertFalse(SessionRef.isValidULID("01ARZ3NDEKTSV4RRFFQ69G5FAL"), "'L' is not in the ULID alphabet")
        XCTAssertFalse(SessionRef.isValidULID("01ARZ3NDEKTSV4RRFFQ69G5FAO"), "'O' is not in the ULID alphabet")
        XCTAssertFalse(SessionRef.isValidULID("01ARZ3NDEKTSV4RRFFQ69G5FAU"), "'U' is not in the ULID alphabet")
    }

    func test_isValidULID_rejectsEmptyString() {
        XCTAssertFalse(SessionRef.isValidULID(""))
    }

    func test_isValidULID_rejectsArbitraryGarbageOfWrongShape() {
        XCTAssertFalse(SessionRef.isValidULID("not-a-ulid-at-all-26-chars"))
    }
}
