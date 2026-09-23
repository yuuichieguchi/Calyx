// PaneCLIExec.swift
// CalyxUITests
//
// Shared pane-command-injection helpers for the E2E suites added
// alongside SessionPersistenceE2ETests (E2E-1/E2E-2/E2E-3). Mirrors
// `BrowserScriptingUITests.terminalExec`'s already-established
// pattern (a real command run by a live pane, not a `Process` spawned
// by the test runner) rather than inventing a new one; kept here
// instead of promoted onto `CalyxUITestCase` itself or merged into
// `BrowserScriptingUITests`'s own private copy, since both of those
// files are outside this task's assigned scope.
//
// The command itself is never pasted or typed directly. It is written
// (via a throwing `try`, never `try?`, so a write failure surfaces as
// an `XCTFail` instead of a silent no-op and a timeout) to a script
// file under `FileManager.default.temporaryDirectory` -- the TEST
// RUNNER's own sandboxed container tmp, which the runner process can
// write to (unlike `/tmp`, which the sandboxed runner cannot write to
// -- field-verified: a `try?` write to `/tmp` failed silently there)
// and which the pane's unsandboxed shell can still read by its
// absolute path. Only the short line `sh <scriptPath>` is entered
// into the pane, and it is entered via `app.typeText`, not a paste:
// a paste long/slow enough that it is still being delivered when
// Return arrives lands that Return inside the bracketed paste, so the
// command is never executed (field-verified: even the short `sh
// '<path>'` line, entered as a paste, was swallowed this way on a
// loaded machine). `app.typeText` delivers keystrokes in order with
// no bracketed-paste framing, so Return always arrives after the text
// it terminates.
//
// The typed line carries NO quote character around `<scriptPath>`: a
// typed `'` is delivered by pressing whatever physical key produces
// `'` under the OS's ACTIVE keyboard layout at the moment `typeText`
// runs, not a fixed keycode, so under a non-US layout it is delivered
// as a different character entirely (field-verified: `sh '<path>`
// arrived in the pane as `sh ;Su/Users/...`, and the mangled `sh`
// argument then started an interactive shell instead of running the
// script). `FileManager.default.temporaryDirectory` is OS-generated
// and can contain `_` (observed in both an unsandboxed runner's
// `/var/folders/.../T` path and a sandboxed container path derived
// from a system username), so every path passed to `typePaneScript`
// below is asserted (via `XCTFail`, not `precondition`, so a violation
// reports as a normal test failure rather than aborting the process)
// to contain only `[A-Za-z0-9/._-]` before it is typed -- this guard
// exists to catch a character that would require quoting (a space or
// a shell metacharacter), never `_`, which this typed line handles
// directly via `app.typeText` rather than through `typeIntoPane`. The
// layout-invariant character-set constraint on a typed line (which
// does exclude `_` and `'`) applies only to `typeIntoPane`, used for
// literal command text, not to `typePaneScript`'s own `sh <path>`
// line.
//
// Rationale for running a command in a live pane at all, instead of
// spawning `calyx-session` as an out-of-process `Process` from inside
// the test runner: `SessionPersistenceE2ETests.swift`'s header
// comment establishes that the `CalyxUITests` runner is itself
// App-Sandboxed and cannot open a new unix-domain-socket connection to
// the daemon, so a `calyx-session` child spawned directly by the
// runner can never reach it. Routing the same CLI calls through a
// real pane (an already-running, unsandboxed child process of
// Calyx.app) is the same workaround `BrowserScriptingUITests` already
// uses for the `calyx` CLI.
//
// CRITICAL, field-verified constraint (found running this suite, not
// assumed): a command pasted into a pane does NOT inherit Calyx.app's
// own `HOME` override. Ghostty execs every surface's command via
// `login -flp <system-username> ...` (confirmed via `ps aux` on a live
// run), which resets the shell's environment against the REAL system
// user, independent of whatever `HOME` `app.launchEnvironment` set on
// Calyx.app's own process. A bare `calyx-session <subcommand>` typed
// into a pane therefore falls back to resolving `$HOME` fresh inside
// that reset shell -- the developer's REAL home, not this test's
// isolated one -- and silently operates against the real daemon
// instead. `SessionCommandSynthesizer.attachCommand`'s own doc comment
// (Calyx/Features/Sessions/SessionCommandSynthesizer.swift:74-140)
// independently confirms this exact failure mode was already
// field-verified for Calyx's OWN internal session commands, which is
// why that function no longer relies on an env override and instead
// bakes explicit `--runtime-dir`/`--state-dir` flags into the command
// string at Swift level before ghostty ever execs it. Every pane
// command this suite issues MUST do the same -- see
// `calyxSessionRootFlags(homeDir:)` below -- never a bare
// `calyx-session <subcommand>` with no flags.
import XCTest

extension CalyxUITestCase {

    /// Path to a pre-built `calyx-session` binary, resolved the same
    /// way `SessionPersistenceE2ETests` resolves it: from the
    /// `CALYX_SESSION_BIN` environment variable this test process
    /// itself was launched with (supplied by the `/e2e-test` skill
    /// invocation, or a `cargo build --release` step run ahead of the
    /// UI test bundle -- a test-runner-phase concern, not this file's).
    /// Read here (the TEST RUNNER's own environment) so a caller can
    /// interpolate it into a command run in a pane. Unlike the
    /// binary PATH itself (a fixed location, unaffected by which HOME
    /// resolves), the session ROOT a pane-executed command targets is
    /// NOT safe to leave implicit -- see this file's header and
    /// `calyxSessionRootFlags(homeDir:)`.
    static var builtSessionBinaryPath: String {
        ProcessInfo.processInfo.environment["CALYX_SESSION_BIN"] ?? ""
    }

    /// `--runtime-dir <homeDir>/.calyx/run --state-dir <homeDir>/.calyx/
    /// state`, matching `SessionCommandSynthesizer.attachCommand`'s own
    /// composed paths exactly (`<root>/.calyx/{run,state}`). MUST be
    /// appended to every `calyx-session` invocation run in a pane
    /// (see this file's header) so it resolves against this test's own
    /// isolated `homeDir` regardless of what `login` resets the pane's
    /// shell environment to.
    func calyxSessionRootFlags(homeDir: String) -> String {
        "--runtime-dir \(homeDir)/.calyx/run --state-dir \(homeDir)/.calyx/state"
    }

    /// Types `sh <scriptPath>\n` into the frontmost pane directly via
    /// `app.typeText`, with no quoting around `scriptPath` (see this
    /// file's header for why a typed quote character is layout-dependent
    /// and must never be used). Fails the test via `XCTFail` -- without
    /// typing anything -- if `scriptPath` contains a character requiring
    /// quoting: a space or any character outside `[A-Za-z0-9/._-]`.
    private func typePaneScript(_ scriptPath: String) {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-")
        guard scriptPath.unicodeScalars.allSatisfy(allowed.contains) else {
            XCTFail("pane script path contains a character requiring quoting: \(scriptPath)")
            return
        }
        app.typeText("sh \(scriptPath)\n")
    }

    /// Types `line` (literal command text, not a script path -- a
    /// script path is typed by `typePaneScript`/`terminalExec` under
    /// their own path guard) into the frontmost pane via `app.typeText`.
    /// Fails the test via `XCTFail` -- without typing anything -- if
    /// `line` contains a character outside `ABCDEFGHIJKLMNOPQRSTUVWXYZ
    /// abcdefghijklmnopqrstuvwxyz0123456789 /.;-\n`: `app.typeText`
    /// presses the key that produces each character under the test
    /// runner's keyboard layout, and the pane translates that key under
    /// its own layout, so a character whose key position differs
    /// between the two layouts arrives in the pane as a different
    /// character. This set is what has arrived intact between the
    /// runner's ABC layout and the pane's layout in recorded runs;
    /// `_` and `'` are not in it because they arrived as other
    /// characters (`_` as `=`, `'` as `;`).
    func typeIntoPane(_ line: String) {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 /.;-\n")
        guard line.unicodeScalars.allSatisfy(allowed.contains) else {
            XCTFail("pane text contains a character that is not layout-invariant: \(line.debugDescription)")
            return
        }
        app.typeText(line)
    }

    /// Writes `command` (with its stdout+stderr redirected to a fresh
    /// `/tmp` output file the pane's shell -- unsandboxed -- can write
    /// to and this sandboxed runner can still read) to a script file
    /// under the runner's own container tmp (see this file's header),
    /// types `sh <scriptPath>` followed by Return into the frontmost
    /// pane (via `typePaneScript`, no quoting), and polls the output
    /// file until it has content
    /// (or a bounded number of attempts elapse), returning the trimmed
    /// content. Mirrors `BrowserScriptingUITests.terminalExec`, which
    /// applies the same path guard to its own script path before
    /// typing it.
    func paneExec(_ command: String, counter: inout Int, timeoutAttempts: Int = 20) -> String {
        counter += 1
        let pid = ProcessInfo.processInfo.processIdentifier
        let outFile = "/tmp/calyx-e2e-\(pid)-\(counter).txt"
        let scriptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-e2e-\(pid)-\(counter).sh").path
        try? FileManager.default.removeItem(atPath: outFile)
        do {
            try "\(command) > \(outFile) 2>&1\n".write(toFile: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("failed to write pane script \(scriptFile): \(error)")
        }

        Thread.sleep(forTimeInterval: 1)
        typePaneScript(scriptFile)

        for _ in 0..<timeoutAttempts {
            Thread.sleep(forTimeInterval: 0.5)
            if FileManager.default.fileExists(atPath: outFile),
               let content = try? String(contentsOfFile: outFile, encoding: .utf8),
               !content.isEmpty {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (try? String(contentsOfFile: outFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no output)"
    }

    /// Types `sh <scriptPath>` followed by Return into the frontmost
    /// pane (via `typePaneScript`, no quoting), like `paneExec`, but
    /// does NOT redirect output to a file
    /// or wait for one to appear -- for injecting a command whose own
    /// output this caller doesn't need to read back (e.g. a
    /// long-running foreground command used only to keep a pane "busy",
    /// or a fire-and-forget administrative command whose effect is
    /// verified through the daemon ledger instead). Unlike `paneExec`,
    /// this never blocks waiting on the command to produce output, so
    /// it is safe to use for a command that runs indefinitely. Since
    /// this function takes no counter parameter (unlike `paneExec`),
    /// the script filename is disambiguated with a UUID rather than a
    /// shared mutable counter (which would be concurrency-unsafe
    /// global state).
    func panePasteAndReturn(_ command: String) {
        let scriptFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("calyx-e2e-\(ProcessInfo.processInfo.processIdentifier)-cmd-\(UUID().uuidString).sh")
            .path
        do {
            try "\(command)\n".write(toFile: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            XCTFail("failed to write pane script \(scriptFile): \(error)")
        }

        Thread.sleep(forTimeInterval: 1)
        typePaneScript(scriptFile)
    }
}
