//
//  SessionSpawnPlannerTests.swift
//  CalyxTests
//
//  TDD Red Phase for SessionSpawnPlanner.plan(for:): whether a new
//  terminal surface launches a plain shell (.passthrough) or a
//  calyx-session-backed persistent shell (.persistent), gated by
//  SessionSettings.persistentSessionsEnabled and the spawn context's
//  origin.
//
//  Coverage:
//  - Disabled -> always .passthrough
//  - Enabled, .tab origin -> .persistent with a ULID-format sessionID
//    and a command matching SessionCommandSynthesizer's contract
//  - Enabled, .quickTerminal origin -> still .passthrough (QuickTerminal
//    panes are excluded from persistent sessions by default)
//  - cwd inheritance priority: inheritedCwd ?? cwd ?? home
//
//  The tests that inspect the synthesized `.persistent` command's cwd
//  (matching-command, and all three cwd-priority tests) run it through
//  a real `/bin/sh -c`, substituting a small argv-dumping stub script
//  for the real calyx-session binary (via an injected
//  SessionBinaryResolverProtocol fake) and comparing the ACTUAL,
//  already-shell-decomposed `--cwd` argument the stub receives against
//  the raw expected string — mirroring SessionCommandSynthesizerTests'
//  approach. This keeps them valid regardless of
//  SessionCommandSynthesizer's escaping strategy (backslash-per-char vs.
//  unconditional single-quote wrapping): what's being verified is
//  "which cwd value did the planner choose", not "what does the
//  escaped string look like".
//

import XCTest
@testable import Calyx

private struct FakeBinaryResolver: SessionBinaryResolverProtocol {
    let path: String?
    func resolve() -> String? { path }
}

final class SessionSpawnPlannerTests: XCTestCase {

    private let settingsSuiteName = "com.calyx.tests.SessionSpawnPlannerTests"

    override func setUp() {
        super.setUp()
        SessionSettings._testUseSuite(named: settingsSuiteName)
    }

    override func tearDown() {
        SessionSettings._testTeardownSuite(named: settingsSuiteName)
        super.tearDown()
    }

    /// A ULID is a 26-character string over Crockford's base32 alphabet
    /// (no I/L/O/U, to avoid visual ambiguity with 1/0).
    private func isValidULID(_ s: String) -> Bool {
        guard s.count == 26 else { return false }
        let crockford = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        return s.allSatisfy { crockford.contains($0) }
    }

    // MARK: - Argv capture (execution-based verification, mirrors
    // SessionCommandSynthesizerTests)

    private func uniqueTempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
    }

    private func makeArgvDumperScript(at scriptPath: String, outputPath: String) throws {
        let body = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\" >> \"\(outputPath)\"; done\n"
        try body.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    private func readCapturedArgv(at outputPath: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: outputPath),
              let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private func runShC(_ command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    /// Plans `context` with a resolver pointed at a fresh argv-dumper
    /// stub (standing in for the real calyx-session binary), runs the
    /// resulting `.persistent` command through a real `/bin/sh -c`, and
    /// returns the fully captured, already-decomposed argv the stub
    /// received. `nil` if `plan(for:)` didn't produce `.persistent` at
    /// all.
    private func capturedArgv(for context: SessionSpawnContext) throws -> (sessionID: String, command: String, argv: [String])? {
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let plan = SessionSpawnPlanner.plan(for: context, resolver: FakeBinaryResolver(path: binaryPath))
        guard case .persistent(let sessionID, let command) = plan else { return nil }

        try runShC(command)
        return (sessionID, command, readCapturedArgv(at: outputPath))
    }

    /// Just the `--cwd` argument's decomposed value, for the
    /// cwd-priority tests below (which only care which cwd the planner
    /// chose, not the rest of argv).
    private func capturedCwdArgument(for context: SessionSpawnContext) throws -> String? {
        guard let (_, _, argv) = try capturedArgv(for: context) else { return nil }
        guard let cwdIndex = argv.firstIndex(of: "--cwd"), argv.indices.contains(cwdIndex + 1) else {
            return nil
        }
        return argv[cwdIndex + 1]
    }

    // MARK: - Disabled

    func test_plan_disabled_alwaysReturnsPassthrough() {
        SessionSettings.persistentSessionsEnabled = false

        let context = SessionSpawnContext(cwd: "/Users/dev/repo")

        XCTAssertEqual(SessionSpawnPlanner.plan(for: context), .passthrough,
                       "With the feature disabled, plan(for:) must always return .passthrough")
    }

    // MARK: - Enabled, .tab origin

    func test_plan_enabledTabOrigin_returnsPersistentWithULIDSessionIDAndMatchingCommand() throws {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/Users/dev/repo", origin: .tab)

        guard let (sessionID, command, argv) = try capturedArgv(for: context) else {
            XCTFail("With persistent sessions enabled, a .tab-origin context must produce .persistent")
            return
        }

        XCTAssertTrue(isValidULID(sessionID), "sessionID must be a 26-character Crockford base32 ULID, got \(sessionID)")
        // Since the session-root-resolution fix round, the command
        // gained a leading `HOME=<root>` env-assignment word ahead of
        // `exec` (see SessionCommandSynthesizerHomeStampTests), so the
        // direct-exec invariant this test protects is now checked as
        // "starts with the env-assignment word, immediately followed by
        // exec" rather than a bare `hasPrefix("exec ")`.
        XCTAssertTrue(command.hasPrefix("HOME=") && command.contains(" exec "),
                     "The synthesized command must stamp a leading HOME= env-assignment word, then exec into " +
                     "calyx-session directly (SessionCommandSynthesizer's contract)")
        XCTAssertEqual(argv, ["attach", sessionID, "--create", "--cwd", "/Users/dev/repo"],
                       "The synthesized command must attach/create the exact sessionID returned alongside " +
                       "it, positionally (matching the P2 CLI's AttachArgs, not a --id flag), and carry the " +
                       "context's cwd intact through /bin/sh -c regardless of the escaping strategy used")
    }

    func test_plan_enabledTabOrigin_distinctCallsProduceDistinctSessionIDs() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/Users/dev/repo")
        // An injected FakeBinaryResolver, exactly like the other tests in
        // this file — plan(for:) only needs resolve() to return non-nil
        // to take the .persistent branch; nothing here executes the
        // path, so it need not point at a real binary. Using the
        // no-argument plan(for:) (the production default resolver) made
        // this test's outcome depend on whether a real calyx-session
        // binary happened to be bundled in the test environment, rather
        // than on the ULID-distinctness behavior it's meant to verify.
        let resolver = FakeBinaryResolver(path: "/dummy/calyx-session")

        guard case .persistent(let firstID, _) = SessionSpawnPlanner.plan(for: context, resolver: resolver),
              case .persistent(let secondID, _) = SessionSpawnPlanner.plan(for: context, resolver: resolver) else {
            XCTFail("Both calls must produce .persistent while the feature is enabled")
            return
        }
        XCTAssertNotEqual(firstID, secondID, "Each new surface must get its own freshly generated session ID")
    }

    // MARK: - Enabled, .quickTerminal origin

    func test_plan_enabledQuickTerminalOrigin_stillReturnsPassthrough() {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/Users/dev/repo", origin: .quickTerminal)

        XCTAssertEqual(SessionSpawnPlanner.plan(for: context), .passthrough,
                       "QuickTerminal panes must default to .passthrough even when the feature is enabled")
    }

    // MARK: - cwd inheritance priority (fix round, item 6)
    //
    // Effective cwd must be `inheritedCwd ?? cwd ?? home`: a new split
    // should land in the directory it was split from (inheritedCwd),
    // even when the tab's own last-persisted pwd (cwd) is stale or
    // absent.

    func test_plan_inheritedCwdAndCwdBothSet_inheritedCwdTakesPriority() throws {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/Users/dev/stale-repo", inheritedCwd: "/Users/dev/split-origin", origin: .tab)

        let cwdArgument = try capturedCwdArgument(for: context)

        XCTAssertEqual(cwdArgument, "/Users/dev/split-origin",
                       "inheritedCwd must take priority over the tab's own (possibly stale) cwd")
    }

    func test_plan_onlyCwdSet_cwdIsUsed() throws {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: "/Users/dev/repo", inheritedCwd: nil, origin: .tab)

        let cwdArgument = try capturedCwdArgument(for: context)

        XCTAssertEqual(cwdArgument, "/Users/dev/repo", "With no inheritedCwd, the tab's own cwd must be used")
    }

    func test_plan_neitherCwdNorInheritedCwdSet_homeDirectoryIsUsed() throws {
        SessionSettings.persistentSessionsEnabled = true
        let context = SessionSpawnContext(cwd: nil, inheritedCwd: nil, origin: .tab)

        let cwdArgument = try capturedCwdArgument(for: context)

        XCTAssertEqual(cwdArgument, NSHomeDirectory(),
                       "With neither cwd nor inheritedCwd set, the effective cwd must fall back to the home directory")
    }
}
