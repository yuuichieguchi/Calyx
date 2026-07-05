//
//  SessionCommandSynthesizerTests.swift
//  CalyxTests
//
//  TDD Red Phase for SessionCommandSynthesizer.attachCommand: the shell
//  command string ghostty runs (via `/bin/sh -c`) for a persistent
//  session's surface.
//
//  Coverage:
//  - Basic form: `exec <binary> attach <id> --create --cwd <cwd>` (id is
//    positional, matching the P2 CLI's AttachArgs — see
//    calyx-session/crates/cli/src/cli.rs, which has no --id flag)
//  - cwd containing a space, a single quote, and Japanese characters
//    survives /bin/sh -c intact
//  - `--name` appended when provided, omitted when nil
//  - binaryPath itself containing a space is still exec'd correctly
//  - sessionID itself must also survive /bin/sh -c intact, as defense
//    in depth against a corrupted/malicious persisted
//    SessionRef.sessionID reaching this function
//  - A raw newline (`\n`) OR a CRLF pair (`\r\n`) embedded in
//    cwd/name/sessionID must never be able to break out and inject a
//    second shell statement
//
//  The five "shape" tests (basic form, cwd escaping, name, binaryPath,
//  sessionID metacharacters) verify behavior by actually running the
//  synthesized command through a real `/bin/sh -c` and capturing the
//  argv a stand-in dumper script receives in place of the real
//  calyx-session binary, rather than string-matching
//  SessionCommandSynthesizer's internal escaping shape. This keeps them
//  valid across a change in escaping strategy (e.g.
//  backslash-per-character vs. unconditional single-quote wrapping),
//  since what they check is the property that actually matters: does
//  the original value survive /bin/sh -c parsing intact, as one
//  argument.
//

import XCTest
@testable import Calyx

final class SessionCommandSynthesizerTests: XCTestCase {

    // MARK: - Shared helpers

    private func uniqueTempPath(_ label: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
            .path
    }

    /// Runs `command` via a real `/bin/sh -c`.
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

    // MARK: - Argv capture (execution-based shape verification)

    /// Writes a `#!/bin/sh` script at `scriptPath` that appends each of
    /// its own arguments, one per line, to `outputPath` — stands in for
    /// the real (nonexistent in tests) calyx-session binary so the
    /// ACTUAL argv `/bin/sh -c` hands to the exec'd process can be
    /// captured directly.
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

    private func runAndCaptureArgv(_ command: String, outputPath: String) throws -> [String] {
        try runShC(command)
        return readCapturedArgv(at: outputPath)
    }

    // MARK: - Basic form

    func test_attachCommand_basicForm_includesExecCreateIdCwdInOrder() throws {
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath, sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/Users/dev/repo"
        )
        // Since the session-root-resolution fix round, the command
        // gained a leading `HOME=<root>` env-assignment word ahead of
        // `exec` (see SessionCommandSynthesizerHomeStampTests), so the
        // direct-exec invariant this test protects is now checked as
        // "starts with the env-assignment word, immediately followed by
        // exec" rather than a bare `hasPrefix("exec ")`.
        XCTAssertTrue(command.hasPrefix("HOME=") && command.contains(" exec "),
                     "The command must stamp a leading HOME= env-assignment word, then exec into " +
                     "calyx-session directly, not run it as a plain subcommand")

        let argv = try runAndCaptureArgv(command, outputPath: outputPath)
        XCTAssertEqual(argv, ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/Users/dev/repo"],
                       "attach must receive exactly these positional/flag arguments in order — sessionID " +
                       "is positional (AttachArgs.id has no #[arg(long)]), not a --id flag")
    }

    // MARK: - cwd

    func test_attachCommand_cwdWithSpacesQuoteAndJapanese_survivesShCIntact() throws {
        let cwd = "/Users/dev/My Repo's Folder/日本語"
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath, sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: cwd
        )
        let argv = try runAndCaptureArgv(command, outputPath: outputPath)

        XCTAssertEqual(argv, ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", cwd],
                       "cwd containing spaces, a single quote, and Japanese characters must survive " +
                       "/bin/sh -c parsing byte-for-byte, regardless of the escaping strategy used")
    }

    // MARK: - name presence

    func test_attachCommand_withName_appendsNameArgumentIntact() throws {
        let name = "my session"
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath, sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/Users/dev/repo", name: name
        )
        let argv = try runAndCaptureArgv(command, outputPath: outputPath)

        XCTAssertEqual(
            argv,
            ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/Users/dev/repo", "--name", name],
            "A non-nil name must append --name <name> at the end, surviving /bin/sh -c intact"
        )
    }

    func test_attachCommand_withoutName_omitsNameFlagEntirely() {
        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: "/usr/local/bin/calyx-session",
            sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            cwd: "/Users/dev/repo",
            name: nil
        )

        XCTAssertFalse(command.contains("--name"), "A nil name must not add a --name flag at all")
    }

    // MARK: - binaryPath

    func test_attachCommand_binaryPathWithSpace_isInvokedCorrectly() throws {
        let dirWithSpace = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx dumper dir \(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dirWithSpace, withIntermediateDirectories: true)
        let binaryPath = dirWithSpace + "/calyx-session"
        let outputPath = uniqueTempPath("calyx-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: dirWithSpace)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath, sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV", cwd: "/Users/dev/repo"
        )
        let argv = try runAndCaptureArgv(command, outputPath: outputPath)

        XCTAssertEqual(argv, ["attach", "01ARZ3NDEKTSV4RRFFQ69G5FAV", "--create", "--cwd", "/Users/dev/repo"],
                       "A binaryPath containing a space must still be exec'd correctly as a single path " +
                       "— if escaping were dropped, /bin/sh would split it into two words and exec would " +
                       "fail to find anything, so the dumper script would never run and capture this argv at all")
    }

    // MARK: - sessionID (fix round, item 2)

    func test_attachCommand_sessionIDWithMetaCharacters_survivesShCIntact() throws {
        // Deliberately harmless-if-ever-actually-executed: this test
        // runs the synthesized command for real, so the payload must
        // not itself be a destructive command (e.g. never `rm -rf ...`)
        // even in the hypothetical case that escaping were broken.
        // `touch` with no operand is a no-op usage error; `;`/`#`/space
        // are still representative shell metacharacters.
        let maliciousSessionID = "01ARZ3; touch; #"
        let binaryPath = uniqueTempPath("calyx-session-dumper")
        let outputPath = uniqueTempPath("calyx-argv-capture")
        defer {
            try? FileManager.default.removeItem(atPath: binaryPath)
            try? FileManager.default.removeItem(atPath: outputPath)
        }
        try makeArgvDumperScript(at: binaryPath, outputPath: outputPath)

        let command = SessionCommandSynthesizer.attachCommand(
            binaryPath: binaryPath, sessionID: maliciousSessionID, cwd: "/Users/dev/repo"
        )
        let argv = try runAndCaptureArgv(command, outputPath: outputPath)

        XCTAssertEqual(argv, ["attach", maliciousSessionID, "--create", "--cwd", "/Users/dev/repo"],
                       "sessionID containing shell metacharacters must survive /bin/sh -c parsing intact " +
                       "as a single argument, not be interpreted as separate shell tokens/commands — a " +
                       "freshly generated ULID never needs this, but a corrupted/malicious persisted " +
                       "value must not be able to inject shell metacharacters into the synthesized command")
    }

    // MARK: - Newline / CRLF command-injection regression (final review must-fix)
    //
    // ShellEscape.escape's special-character set has no newline/CR, so a
    // raw newline in cwd/name/sessionID can pass straight through into
    // the command handed to `/bin/sh -c`, where it acts as a statement
    // separator exactly like `;` does — a structural command-injection
    // gap. Verified by actually running the synthesized command through
    // `/bin/sh -c` (neutralized by prefixing with the POSIX no-op
    // builtin `:`, which accepts and discards any arguments and never
    // fails — this avoids depending on whichever way a real, nonexistent
    // `exec` target happens to behave on failure), so a fix using any
    // strategy (backslash-continuation, single-quote wrapping,
    // stripping, ...) satisfies it.
    //
    // The injected payload is a bare path to a small executable script
    // (letters/digits/`/`/`-`/`_`/`.` only), not `echo ...`/`>marker`:
    // ShellEscape.escape's special set includes space AND `<`/`>`, and
    // since escaping applies to the WHOLE cwd/name/sessionID string —
    // injected payload included — anything using those characters gets
    // ITS OWN escaping applied too (`echo PWNED` -> `echo\ PWNED`,
    // `>marker` -> `\>marker`), harmlessly neutralizing the payload
    // itself and silently "disproving" a real vulnerability. A bare
    // script path avoids every character ShellEscape touches: if the
    // separator is not safely contained, `/bin/sh` treats what follows
    // as a fresh statement and directly executes the script (a path
    // starting with `/` with a shebang line needs no separate
    // interpreter word), which creates the marker file as a side
    // effect.
    //
    // CRLF (`\r\n`) gets its own separate coverage rather than being
    // assumed to behave like `\n`: a Swift `Character` collapses an
    // adjacent CR+LF pair into a single extended grapheme cluster (per
    // Unicode's "do not break between a CR and LF" rule), so a
    // Character-by-character `== "\n"` / `== "\r"` check — as opposed
    // to `Substring`/UTF-8-level scanning — can fail to recognize a
    // pure-CRLF payload as containing either, falling through to
    // whatever the plain (non-newline-aware) escaping path does.

    private enum InjectionField: CustomStringConvertible {
        case cwd, name, sessionID
        var description: String {
            switch self {
            case .cwd: return "cwd"
            case .name: return "name"
            case .sessionID: return "sessionID"
            }
        }
    }

    /// Writes a `#!/bin/sh` script that touches `markerPath` when run,
    /// and returns the script's own path — composed only of
    /// letters/digits/`/`/`-`/`.`, none of which `ShellEscape.escape`
    /// treats specially, so embedding this path as the injection
    /// payload can't accidentally neutralize itself the way `echo
    /// PWNED`/`>marker` would.
    private func makeMarkerTouchingScript(markerPath: String) throws -> String {
        let scriptPath = uniqueTempPath("calyx-injection-script")
        let scriptBody = "#!/bin/sh\ntouch \"\(markerPath)\"\n"
        try scriptBody.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        return scriptPath
    }

    private func assertCannotInject(
        separator: String, into field: InjectionField,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let marker = uniqueTempPath("calyx-injection-marker")
        let script = try makeMarkerTouchingScript(markerPath: marker)
        defer {
            try? FileManager.default.removeItem(atPath: marker)
            try? FileManager.default.removeItem(atPath: script)
        }

        let command: String
        switch field {
        case .cwd:
            command = SessionCommandSynthesizer.attachCommand(
                binaryPath: "/usr/local/bin/calyx-session",
                sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                cwd: "/tmp/foo\(separator)\(script)"
            )
        case .name:
            command = SessionCommandSynthesizer.attachCommand(
                binaryPath: "/usr/local/bin/calyx-session",
                sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                cwd: "/Users/dev/repo",
                name: "my-session\(separator)\(script)"
            )
        case .sessionID:
            command = SessionCommandSynthesizer.attachCommand(
                binaryPath: "/usr/local/bin/calyx-session",
                sessionID: "01ARZ3\(separator)\(script)",
                cwd: "/Users/dev/repo"
            )
        }

        try runShC(": " + command)

        let separatorLabel = separator == "\r\n" ? "CRLF" : "a bare newline"
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "\(separatorLabel) embedded in \(field) must not break out and inject a second " +
                       "shell statement — the marker file must never be created",
                       file: file, line: line)
    }

    func test_attachCommand_cwdWithNewline_cannotInjectASecondShellStatement() throws {
        try assertCannotInject(separator: "\n", into: .cwd)
    }

    func test_attachCommand_nameWithNewline_cannotInjectASecondShellStatement() throws {
        try assertCannotInject(separator: "\n", into: .name)
    }

    func test_attachCommand_sessionIDWithNewline_cannotInjectASecondShellStatement() throws {
        try assertCannotInject(separator: "\n", into: .sessionID)
    }

    func test_attachCommand_cwdWithCRLF_cannotInjectASecondShellStatement() throws {
        try assertCannotInject(separator: "\r\n", into: .cwd)
    }

    func test_attachCommand_nameWithCRLF_cannotInjectASecondShellStatement() throws {
        try assertCannotInject(separator: "\r\n", into: .name)
    }

    func test_attachCommand_sessionIDWithCRLF_cannotInjectASecondShellStatement() throws {
        try assertCannotInject(separator: "\r\n", into: .sessionID)
    }

    // MARK: - Combining-character quote-escape regression (final review must-fix)
    //
    // shSafeToken's `token.replacingOccurrences(of: "'", with:
    // "'\\''")` compares `Character`s (extended grapheme clusters). When
    // a literal `'` is immediately followed by a Unicode combining
    // character (e.g. U+0301 COMBINING ACUTE ACCENT — which can arise
    // naturally from NFD normalization, as APFS uses for filenames),
    // Swift fuses `'` + the combining mark into ONE `Character` distinct
    // from the bare `'` `Character`, so `replacingOccurrences` never
    // matches it and the quote goes un-doubled. `/bin/sh` parses raw
    // bytes, not grapheme clusters: it still sees a literal `'` byte
    // right there and closes the quote early, letting whatever follows
    // run as unquoted (and therefore injectable) shell syntax. Verified
    // by actually running the synthesized command through `/bin/sh -c`
    // (neutralized with the same `:` no-op prefix used above), so a fix
    // using any correct approach (Unicode-scalar-level replacement,
    // UTF-8-byte-level replacement, etc.) satisfies this, not just one
    // specific implementation.
    //
    // Unlike the newline/CRLF tests above, the injected payload here
    // does NOT need to avoid ShellEscape.escape's special characters
    // (this vulnerability is in shSafeToken's own single-quote
    // wrapping, not the old shared escaper) — once the quote is broken
    // out of, everything after it is ordinary unquoted shell syntax, so
    // a plain `; touch <marker> #` (space-separated, semicolon- and
    // hash-terminated) behaves exactly as it would typed directly at a
    // shell prompt.

    private func assertApostropheFollowedByCombiningCharacterCannotEscapeQuote(
        into field: InjectionField,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let marker = uniqueTempPath("calyx-injection-marker")
        defer { try? FileManager.default.removeItem(atPath: marker) }
        // U+0301 COMBINING ACUTE ACCENT immediately after the `'`.
        let payload = "'\u{0301}; touch \(marker) #"

        let command: String
        switch field {
        case .cwd:
            command = SessionCommandSynthesizer.attachCommand(
                binaryPath: "/usr/local/bin/calyx-session",
                sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                cwd: "/tmp/x\(payload)"
            )
        case .name:
            command = SessionCommandSynthesizer.attachCommand(
                binaryPath: "/usr/local/bin/calyx-session",
                sessionID: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
                cwd: "/Users/dev/repo",
                name: "my-session\(payload)"
            )
        case .sessionID:
            command = SessionCommandSynthesizer.attachCommand(
                binaryPath: "/usr/local/bin/calyx-session",
                sessionID: "01ARZ3\(payload)",
                cwd: "/Users/dev/repo"
            )
        }

        try runShC(": " + command)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker),
                       "An apostrophe immediately followed by a combining character in \(field) must not " +
                       "be able to break out of the single-quote wrapping and inject a second shell " +
                       "statement — the marker file must never be created",
                       file: file, line: line)
    }

    func test_attachCommand_cwdWithApostropheFollowedByCombiningCharacter_cannotEscapeQuoting() throws {
        try assertApostropheFollowedByCombiningCharacterCannotEscapeQuote(into: .cwd)
    }

    func test_attachCommand_nameWithApostropheFollowedByCombiningCharacter_cannotEscapeQuoting() throws {
        try assertApostropheFollowedByCombiningCharacterCannotEscapeQuote(into: .name)
    }

    func test_attachCommand_sessionIDWithApostropheFollowedByCombiningCharacter_cannotEscapeQuoting() throws {
        try assertApostropheFollowedByCombiningCharacterCannotEscapeQuote(into: .sessionID)
    }
}
