//
//  StdioLSPTransportPATHBugSpecTests.swift
//  CalyxTests
//
//  Regression test covering the PATH-augmentation gap in
//  `StdioLSPTransport.ensureSpawned()`. A Finder-launched Calyx
//  inherits the minimal launchd PATH (`/usr/bin:/bin:/usr/sbin:/sbin`),
//  so a bare-name executable like `pyright-langserver` (installed
//  under `~/.nvm/versions/node/<v>/bin/`) is invisible to the
//  `/usr/bin/env` shim that the transport uses for bare-name lookup.
//  Meanwhile `SystemCommandRunner.locate(...)` DOES apply
//  `augmentedPATH()` (login-shell + canonical safety net), so the
//  startup bridge happily confirms "pyright installed" right before
//  the transport spawn fails with exit code 127 — a confusing dual
//  mismatch.
//
//  The fix is to route the transport's child spawn through
//  `SystemCommandRunner.augmentedEnvironment(base: environment)` so
//  the same PATH augmentation applies in both code paths.
//
//  This test MUST FAIL against the current implementation (Red phase)
//  because the transport spawns the child with the caller-supplied
//  environment verbatim — without augmenting PATH — so the child
//  exits 127, the stdin pipe closes, and `send` throws
//  `transportClosed`. After the fix it will PASS.
//

import XCTest
import Darwin
@testable import Calyx

@MainActor
final class StdioLSPTransportPATHBugSpecTests: XCTestCase {

    // MARK: - Setup

    override class func setUp() {
        super.setUp()
        // Foundation usually sets SO_NOSIGPIPE on its pipe FDs, but
        // the host process can still receive SIGPIPE during a write
        // race with a child that closed stdin. Ignore it so the test
        // runner doesn't crash if the bug manifests as EPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - Helpers

    /// Returns a path to a `pyright-langserver` binary installed under
    /// `~/.nvm/versions/node/<version>/bin/` on this machine, or nil
    /// when no such installation exists. The bin DIRECTORY is the gap
    /// we care about: it is NOT in the launchd-minimal PATH that a
    /// Finder-launched app inherits, but IT IS in `augmentedPATH()`
    /// (surfaced by the login shell — see SystemCommandRunner). When
    /// the test routes around `augmentedEnvironment` (current code),
    /// `/usr/bin/env pyright-langserver` cannot find the binary and
    /// the child exits 127.
    private func locateNVMPyrightLangserverBinDir() -> String? {
        let home = NSHomeDirectory()
        let nvmRoot = "\(home)/.nvm/versions/node"
        let fm = FileManager.default
        guard let versionDirs = try? fm.contentsOfDirectory(atPath: nvmRoot) else {
            return nil
        }
        for version in versionDirs {
            let binDir = "\(nvmRoot)/\(version)/bin"
            let executable = "\(binDir)/pyright-langserver"
            if fm.isExecutableFile(atPath: executable) {
                return binDir
            }
        }
        return nil
    }

    // MARK: - Bug: transport spawn ignores augmentedPATH()

    /// Given: `pyright-langserver` is installed under
    ///   `~/.nvm/versions/node/<v>/bin/` and that directory appears in
    ///   `SystemCommandRunner.augmentedPATH()` (via the login shell)
    ///   but is absent from the minimal PATH we hand to the transport
    ///   (mimicking a Finder/Dock launch on a fresh machine).
    /// When: we construct `StdioLSPTransport(executable: "pyright-langserver",
    ///   arguments: ["--stdio"], environment: ["PATH": minimalLaunchdPATH])`
    ///   and call `send(...)` (which triggers `ensureSpawned()`),
    ///   then briefly wait for the child to exit if it can't find the
    ///   binary, and call `send(...)` a second time.
    /// Then: neither `send` call must throw `transportClosed`. The
    ///   transport must augment the child's PATH the same way
    ///   `SystemCommandRunner` does, so the bare-name executable
    ///   resolves and the child stays alive. Currently fails because
    ///   the transport uses the caller-supplied environment verbatim:
    ///   `/usr/bin/env pyright-langserver` cannot find the binary,
    ///   exits 127, the stdin pipe closes, and the second `send` (or
    ///   sometimes the first, depending on timing) throws
    ///   `LSPClientError.transportClosed`.
    func test_send_finds_bareNameExecutable_viaAugmentedPATH() async throws {
        guard let nvmBinDir = locateNVMPyrightLangserverBinDir() else {
            throw XCTSkip(
                "NVM-installed pyright-langserver not present on this machine; "
                + "skipping transport PATH-augmentation coverage. "
                + "Coverage gap: when ~/.nvm/versions/node/<v>/bin/pyright-langserver "
                + "exists, StdioLSPTransport must spawn it successfully even when "
                + "the inherited PATH is the launchd minimum "
                + "(/usr/bin:/bin:/usr/sbin:/sbin) — i.e., the transport must "
                + "augment PATH the same way SystemCommandRunner does. "
                + "Install NVM + `npm i -g pyright` to activate this test."
            )
        }

        // Sanity: confirm `augmentedPATH()` actually surfaces the NVM
        // bin dir. If it doesn't, the test is meaningless on this host
        // (the unrelated `SystemCommandRunner` PATH gap would mask the
        // transport gap), so skip with a precise diagnostic.
        let augmented = SystemCommandRunner.augmentedPATH()
        let augmentedEntries = Set(
            augmented.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        )
        guard augmentedEntries.contains(nvmBinDir) else {
            throw XCTSkip(
                "SystemCommandRunner.augmentedPATH() does not currently expose "
                + "'\(nvmBinDir)' on this machine, so the transport-side PATH "
                + "augmentation cannot be validated here. Fix the "
                + "SystemCommandRunner login-shell-PATH gap first "
                + "(SystemCommandRunnerPATHBugSpecTests), then re-run."
            )
        }

        // Simulate a Finder/Dock launch: hand the transport the
        // minimal launchd PATH. With the bug, the transport will
        // forward this verbatim to `/usr/bin/env`, which cannot find
        // `pyright-langserver` and exits 127. After the GREEN fix,
        // the transport will overlay `augmentedPATH()` and the spawn
        // succeeds.
        let minimalLaunchdPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
        let env: [String: String] = ["PATH": minimalLaunchdPATH]

        let transport = StdioLSPTransport(
            executable: "pyright-langserver",
            // `--stdio` is the canonical LSP entrypoint; it keeps the
            // child alive waiting on stdin so we have a stable target
            // to write to. We tear it down in `defer`.
            arguments: ["--stdio"],
            environment: env
        )
        // Ensure the LSP child is reaped even if assertions fail.
        let transportRef = transport
        defer { Task.detached { await transportRef.close() } }

        // First send forces `ensureSpawned()`. If the bug is live the
        // child exits 127 immediately and stdin closes; the write
        // might complete (bytes accepted into the pipe buffer before
        // env tears down) or might already throw — both outcomes are
        // possible due to the spawn-vs-write race.
        var firstSendError: Error?
        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8))
        } catch {
            firstSendError = error
        }

        // Give a failed `/usr/bin/env` child enough wall-clock time to
        // exit and tear down the pipes before we probe again. A
        // healthy `pyright-langserver --stdio` will still be alive.
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        // Second send: if the child exited the stdin write returns
        // EPIPE / EBADF and `writeNonBlocking` throws
        // `LSPClientError.transportClosed`. A live LSP child happily
        // accepts the bytes.
        var secondSendError: Error?
        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":2,"method":"shutdown"}"#.utf8))
        } catch {
            secondSendError = error
        }

        // Capture any stderr the child produced so the failure
        // message names the actual symptom (env's "No such file or
        // directory" message is the canonical 127 fingerprint).
        let stderrTail = await transport.recentStderr()
        let stderrSnippet = String(data: stderrTail.prefix(512), encoding: .utf8) ?? ""

        // The crux of the spec: NEITHER send should throw
        // `transportClosed`. After the GREEN fix that routes through
        // `SystemCommandRunner.augmentedEnvironment(base:)`, the
        // child stays alive and both sends succeed.
        if let err = firstSendError {
            XCTFail(
                """
                First send threw \(err) instead of succeeding. \
                Expected the transport to augment PATH via \
                SystemCommandRunner.augmentedEnvironment(base:) so the \
                bare-name executable 'pyright-langserver' (present in \
                augmentedPATH at '\(nvmBinDir)') resolves under the \
                /usr/bin/env shim, even when the caller-supplied \
                environment carries only the minimal launchd PATH \
                '\(minimalLaunchdPATH)'. Child stderr tail: \
                \(stderrSnippet.isEmpty ? "<empty>" : stderrSnippet)
                """
            )
        }
        if let err = secondSendError {
            if let lspErr = err as? LSPClientError, case .transportClosed = lspErr {
                XCTFail(
                    """
                    Second send threw LSPClientError.transportClosed, \
                    indicating the spawned child exited (almost \
                    certainly 127 from `/usr/bin/env: \
                    pyright-langserver: No such file or directory`). \
                    The transport must overlay augmentedPATH() onto \
                    the child environment so bare-name binaries \
                    installed under version-manager bin dirs (NVM at \
                    '\(nvmBinDir)') resolve under a Finder-launched \
                    Calyx. Fix: route the spawn through \
                    SystemCommandRunner.augmentedEnvironment(base: environment) \
                    in StdioLSPTransport.ensureSpawned(). Child stderr \
                    tail: \(stderrSnippet.isEmpty ? "<empty>" : stderrSnippet)
                    """
                )
            } else {
                XCTFail(
                    """
                    Second send threw an unexpected error \(err). \
                    Expected the LSP child to remain alive and accept \
                    the write. Child stderr tail: \
                    \(stderrSnippet.isEmpty ? "<empty>" : stderrSnippet)
                    """
                )
            }
        }
    }
}
