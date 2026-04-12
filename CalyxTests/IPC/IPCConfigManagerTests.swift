import XCTest
@testable import Calyx

final class IPCConfigManagerTests: XCTestCase {

    // MARK: - IPCConfigResult.anySucceeded

    func test_anySucceeded_bothSuccess() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: .success,
            openCode: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_oneSuccess() {
        let result = IPCConfigResult(
            claudeCode: .success,
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_otherSuccess() {
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .success,
            openCode: .skipped(reason: "not installed")
        )
        XCTAssertTrue(result.anySucceeded)
    }

    func test_anySucceeded_noneSuccess() {
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed")
        )
        XCTAssertFalse(result.anySucceeded)
    }

    func test_anySucceeded_failedAndSkipped() {
        let error = NSError(domain: "test", code: 1)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed")
        )
        XCTAssertFalse(result.anySucceeded)
    }

    // MARK: - IPCConfigResult.anySucceeded (openCode axis)

    func test_anySucceeded_onlyOpenCode() {
        // Given: only openCode is .success, others skipped
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .success
        )
        // Then
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when only openCode succeeded")
    }

    func test_anySucceeded_allThreeSkipped() {
        // Given: all three skipped
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .skipped(reason: "not installed")
        )
        // Then
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when all three are skipped")
    }

    func test_anySucceeded_openCodeFailedOthersSkipped() {
        // Given: openCode failed, others skipped
        let error = NSError(domain: "test", code: 2)
        let result = IPCConfigResult(
            claudeCode: .skipped(reason: "not installed"),
            codex: .skipped(reason: "not installed"),
            openCode: .failed(error)
        )
        // Then
        XCTAssertFalse(result.anySucceeded,
                       "anySucceeded should return false when openCode failed and others skipped")
    }

    func test_anySucceeded_openCodeSuccessOthersFailed() {
        // Given: openCode success, others failed
        let error = NSError(domain: "test", code: 3)
        let result = IPCConfigResult(
            claudeCode: .failed(error),
            codex: .failed(error),
            openCode: .success
        )
        // Then
        XCTAssertTrue(result.anySucceeded,
                      "anySucceeded should return true when openCode succeeded despite other failures")
    }

    // MARK: - ConfigStatus pattern matching

    func test_configStatus_success() {
        let status: ConfigStatus = .success
        if case .success = status {
            // pass
        } else {
            XCTFail("Expected .success")
        }
    }

    func test_configStatus_skipped() {
        let status: ConfigStatus = .skipped(reason: "not installed")
        if case .skipped(let reason) = status {
            XCTAssertEqual(reason, "not installed")
        } else {
            XCTFail("Expected .skipped")
        }
    }

    func test_configStatus_failed() {
        let error = NSError(domain: "test", code: 42)
        let status: ConfigStatus = .failed(error)
        if case .failed(let err) = status {
            XCTAssertEqual((err as NSError).code, 42)
        } else {
            XCTFail("Expected .failed")
        }
    }
}
