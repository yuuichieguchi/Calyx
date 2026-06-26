//
//  SystemCommandRunnerPATHBugSpecTests.swift
//  CalyxTests
//
//  Regression tests covering the PATH-augmentation gap in
//  `SystemCommandRunner.augmentedPATH()`. The current implementation
//  hardcodes a fixed list of canonical bin dirs (`/opt/homebrew/bin`,
//  `~/.cargo/bin`, `~/.npm-global/bin`, `~/go/bin`, `~/.ghcup/bin`,
//  `~/.opam/default/bin`, `/usr/local/share/dotnet`, `/usr/local/go/bin`)
//  and appends `ProcessInfo.processInfo.environment["PATH"]` at the tail.
//
//  Because a Finder-launched macOS app inherits only the launchd PATH
//  (`/usr/bin:/bin:/usr/sbin:/sbin`), this strategy misses any directory
//  exposed by the user's login shell (`.zshrc` / `.bashrc`) but NOT
//  present in the hardcoded list. Concretely, version managers such as
//  NVM, asdf, pyenv, mise, volta, and rbenv install binaries under
//  `~/<manager>/...` paths that the user adds to `$PATH` from a shell
//  rc file. The most painful real-world case: `pyright-langserver`
//  installed via `npm i -g` under `~/.nvm/versions/node/<v>/bin/` is
//  invisible to `SystemCommandRunner.locate(...)`, so Python LSP
//  startup silently fails on a fresh machine launched from Finder.
//
//  The intended fix routes PATH through the user's login shell:
//    `$SHELL -lc 'echo $PATH'`
//  so any directory the user exported from their rc file is inherited
//  automatically.
//
//  Both tests below MUST FAIL against the current hardcoded
//  implementation (Red phase). After the fix lands they will pass.
//

import XCTest
@testable import Calyx

final class SystemCommandRunnerPATHBugSpecTests: XCTestCase {

    // MARK: - Helpers

    /// Returns the user's login shell path. Falls back to `/bin/zsh`
    /// when `$SHELL` is unset (as can happen under some CI launchers).
    private func loginShellPath() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Spawns `<shell> -lc 'echo $PATH'` synchronously and returns the
    /// trimmed stdout. The login shell sources `.zprofile` / `.zshrc`
    /// (or the bash equivalents), so the resulting `$PATH` reflects
    /// every directory the user has configured from their dotfiles —
    /// including version-manager bin dirs that the hardcoded list in
    /// `augmentedPATH()` cannot anticipate.
    private func loginShellPATH() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShellPath())
        process.arguments = ["-lc", "echo $PATH"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits a `:`-joined PATH into entries, discarding empties.
    private func pathEntries(_ joined: String) -> [String] {
        joined.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Bug: login-shell PATH not inherited

    /// `augmentedPATH()` must surface every directory exposed by the
    /// user's login shell, not just the hardcoded canonical list.
    ///
    /// Given: the login shell (`$SHELL -lc 'echo $PATH'`) exposes some
    ///   set of directories `S` after sourcing the user's rc files.
    /// When: we read `SystemCommandRunner.augmentedPATH()`.
    /// Then: every directory in `S` must appear somewhere in the
    ///   augmented PATH. Currently fails because the production code
    ///   only consults the launchd-inherited `PATH`, missing entries
    ///   added by `.zshrc` / `.bashrc` such as
    ///   `~/.nvm/versions/node/<v>/bin`.
    func test_augmentedPATH_includesLoginShellPATH_whenAvailable() throws {
        let loginPATH = try loginShellPATH()
        guard !loginPATH.isEmpty else {
            throw XCTSkip(
                "Login shell '\(loginShellPath())' returned an empty PATH; "
                + "cannot validate inheritance on this machine."
            )
        }

        let augmented = SystemCommandRunner.augmentedPATH()
        let augmentedEntries = Set(pathEntries(augmented))
        let loginEntries = pathEntries(loginPATH)

        // Identify any login-shell PATH entry missing from augmentedPATH.
        // We expect this to be non-empty on hosts that configure version
        // managers (NVM, asdf, pyenv, mise, volta, rbenv, ...) from a
        // shell rc file — exactly the case that motivated this spec.
        let missing = loginEntries.filter { !augmentedEntries.contains($0) }

        XCTAssertTrue(
            missing.isEmpty,
            "augmentedPATH() is missing \(missing.count) directories that "
            + "the login shell (\(loginShellPath())) exposes via $PATH. "
            + "First few missing: \(missing.prefix(5).joined(separator: ", ")). "
            + "This breaks resolution of tools installed by version managers "
            + "(NVM, asdf, pyenv, mise, volta, rbenv) when Calyx is launched "
            + "from Finder/Dock and inherits only the minimal launchd PATH. "
            + "Fix: route augmentedPATH() through `$SHELL -lc 'echo $PATH'` "
            + "so rc-file PATH exports are inherited."
        )
    }

    // MARK: - Bug: NVM-installed binaries unfindable

    /// End-to-end coverage of the NVM gap: if the host machine has
    /// `~/.nvm/versions/node/<version>/bin/pyright-langserver` installed
    /// (a common setup — Pyright is published as an npm package), then
    /// `SystemCommandRunner().locate("pyright-langserver")` must return
    /// a URL pointing into that NVM bin directory.
    ///
    /// When NVM/pyright is absent, the test skips with a message that
    /// names the coverage gap, so a future install automatically
    /// re-activates the assertion.
    func test_locate_findsNVMInstalledBinary_whenPresent() async throws {
        let home = NSHomeDirectory()
        let nvmRoot = "\(home)/.nvm/versions/node"
        let fm = FileManager.default

        guard
            let versionDirs = try? fm.contentsOfDirectory(atPath: nvmRoot),
            !versionDirs.isEmpty
        else {
            throw XCTSkip(
                "NVM/pyright not present; skipping NVM-PATH coverage test. "
                + "Coverage gap: when ~/.nvm/versions/node/<v>/bin/pyright-langserver "
                + "exists, SystemCommandRunner.locate(...) must return a URL into "
                + "that NVM bin dir. Currently augmentedPATH() ignores ~/.nvm/... "
                + "entirely. Install NVM + `npm i -g pyright` to activate this test."
            )
        }

        // Collect every NVM bin dir that actually contains the binary.
        let candidateBinDirs: [String] = versionDirs.compactMap { version in
            let binDir = "\(nvmRoot)/\(version)/bin"
            let executable = "\(binDir)/pyright-langserver"
            return fm.isExecutableFile(atPath: executable) ? binDir : nil
        }

        guard !candidateBinDirs.isEmpty else {
            throw XCTSkip(
                "NVM/pyright not present; skipping NVM-PATH coverage test. "
                + "Coverage gap: when ~/.nvm/versions/node/<v>/bin/pyright-langserver "
                + "exists, SystemCommandRunner.locate(...) must return a URL into "
                + "that NVM bin dir. Currently augmentedPATH() ignores ~/.nvm/... "
                + "entirely. Found NVM node versions \(versionDirs) but none ship "
                + "pyright-langserver; run `npm i -g pyright` under at least one "
                + "to activate this test."
            )
        }

        let runner = SystemCommandRunner()
        let resolved = await runner.locate("pyright-langserver")

        XCTAssertNotNil(
            resolved,
            "SystemCommandRunner.locate(\"pyright-langserver\") returned nil "
            + "even though the binary exists at: "
            + candidateBinDirs.map { "\($0)/pyright-langserver" }.joined(separator: ", ")
            + ". augmentedPATH() must include NVM bin dirs — likely by routing "
            + "through `$SHELL -lc 'echo $PATH'`."
        )

        guard let url = resolved else { return }
        let resolvedPath = url.path
        let matchesNVM = candidateBinDirs.contains { binDir in
            resolvedPath == "\(binDir)/pyright-langserver"
        }
        XCTAssertTrue(
            matchesNVM,
            "locate() resolved pyright-langserver to '\(resolvedPath)', but the "
            + "NVM-installed copy at one of \(candidateBinDirs) should have been "
            + "found first (or at least be reachable). Verify augmentedPATH() "
            + "inherits the login-shell PATH."
        )
    }
}
