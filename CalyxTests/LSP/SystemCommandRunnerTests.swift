//
//  SystemCommandRunnerTests.swift
//  CalyxTests
//
//  Regression coverage for `SystemCommandRunner` — the production
//  `LSPCommandRunner` that drives `Process` to invoke real binaries
//  (`which`, `npm`, `rustup`, language-server entry points, …).
//
//  The primary concern here is the historical deadlock pattern where
//  a child's stdout overruns the ~16-64KB macOS pipe buffer while the
//  parent sits on `process.waitUntilExit()` before draining the pipe,
//  causing both sides to wait on each other forever. This file's
//  large-output test pins the fix.
//

import XCTest
@testable import Calyx

final class SystemCommandRunnerTests: XCTestCase {

    // ====================================================================
    // MARK: - Deadlock regression
    // ====================================================================

    /// Spawns `/usr/bin/seq 1 100000` (~588KB of stdout) and asserts the
    /// runner completes within a hard watchdog deadline. If the runner
    /// ever reverts to the naive pattern of `waitUntilExit()` *before*
    /// draining the pipe, the child will block writing to a full pipe
    /// and the parent will block waiting for the child to exit — this
    /// test will then trip the expectation timeout instead of hanging
    /// the whole bundle.
    func test_run_drainsLargeStdout_withoutDeadlock() throws {
        let seqPath = "/usr/bin/seq"
        guard FileManager.default.fileExists(atPath: seqPath) else {
            throw XCTSkip("/usr/bin/seq is not present on this host")
        }

        let done = expectation(description: "run() returned within deadline")
        let box = ResultBox()

        Task.detached {
            let runner = SystemCommandRunner()
            do {
                let result = try await runner.run(
                    executable: seqPath,
                    arguments: ["1", "100000"],
                    workingDirectory: nil,
                    environment: nil
                )
                box.set(.success(result))
            } catch {
                box.set(.failure(error))
            }
            done.fulfill()
        }

        // 10s is generous — the happy path completes in well under a
        // second on commodity hardware. A real deadlock would never
        // resolve, so any failure here means the deadlock returned.
        wait(for: [done], timeout: 10.0)

        let result = try unwrapResult(box)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stderr, "")
        // Sanity-check the payload bypassed the pipe-buffer ceiling.
        XCTAssertGreaterThan(
            result.stdout.utf8.count,
            128 * 1024,
            "expected >128KB of stdout to prove the pipe was drained past the buffer limit"
        )
        XCTAssertTrue(result.stdout.hasPrefix("1\n"), "stdout should start with '1\\n'")
        XCTAssertTrue(result.stdout.hasSuffix("100000\n"), "stdout should end with '100000\\n'")
    }

    // ====================================================================
    // MARK: - Stderr capture
    // ====================================================================

    /// Confirms stderr is captured (and stdout left empty) when the
    /// child writes only to file descriptor 2. Guards against the
    /// concurrent-drain refactor accidentally swapping the two pipes.
    func test_run_capturesStderr_independentOfStdout() throws {
        let shPath = "/bin/sh"
        guard FileManager.default.fileExists(atPath: shPath) else {
            throw XCTSkip("/bin/sh is not present on this host")
        }

        let done = expectation(description: "run() returned within deadline")
        let box = ResultBox()

        Task.detached {
            let runner = SystemCommandRunner()
            do {
                let result = try await runner.run(
                    executable: shPath,
                    arguments: ["-c", "printf 'hello-err' 1>&2; exit 3"],
                    workingDirectory: nil,
                    environment: nil
                )
                box.set(.success(result))
            } catch {
                box.set(.failure(error))
            }
            done.fulfill()
        }

        wait(for: [done], timeout: 5.0)

        let result = try unwrapResult(box)
        XCTAssertEqual(result.exitCode, 3)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "hello-err")
    }

    // ====================================================================
    // MARK: - Helpers
    // ====================================================================

    private func unwrapResult(_ box: ResultBox) throws -> CommandResult {
        let value = box.snapshot()
        switch value {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        case .none:
            XCTFail("run() never produced a result within the deadline")
            throw CocoaError(.featureUnsupported)
        }
    }
}

/// Tiny synchronisation helper so the detached `Task` and the
/// `XCTestCase` body can exchange a single `Result` without tripping
/// Swift 6 strict-concurrency diagnostics. Locks are sufficient — there
/// is no contention here beyond the one writer / one reader.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<CommandResult, Error>?

    func set(_ value: Result<CommandResult, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }

    func snapshot() -> Result<CommandResult, Error>? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
